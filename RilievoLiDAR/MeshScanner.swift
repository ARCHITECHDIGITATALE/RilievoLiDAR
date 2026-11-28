import SwiftUI
import ARKit
import AVFoundation
import SceneKit
import CoreImage
import Metal

/// Mesh LiDAR in coordinate mondo, estratta dagli ARMeshAnchor.
struct MeshData {
    var vertices: [SIMD3<Float>] = []
    var indices: [UInt32] = []
    /// Classe ARKit di ogni faccia (muro, pavimento, porta, finestra…); vuoto se non disponibile.
    var faceClasses: [UInt8] = []

    static func from(_ anchors: [ARMeshAnchor]) -> MeshData {
        var mesh = MeshData()
        for anchor in anchors {
            let geometry = anchor.geometry
            let offset = UInt32(mesh.vertices.count)

            let vs = geometry.vertices
            let vBase = vs.buffer.contents()
            for i in 0..<vs.count {
                let ptr = vBase.advanced(by: vs.offset + vs.stride * i).assumingMemoryBound(to: Float.self)
                let local = SIMD4<Float>(ptr[0], ptr[1], ptr[2], 1)
                let w = anchor.transform * local
                mesh.vertices.append(SIMD3<Float>(w.x, w.y, w.z))
            }

            let faces = geometry.faces
            let fBase = faces.buffer.contents()
            let perFace = faces.indexCountPerPrimitive
            let total = faces.count * perFace
            for i in 0..<total {
                let index: UInt32
                if faces.bytesPerIndex == 4 {
                    index = fBase.advanced(by: i * 4).assumingMemoryBound(to: UInt32.self).pointee
                } else {
                    index = UInt32(fBase.advanced(by: i * 2).assumingMemoryBound(to: UInt16.self).pointee)
                }
                mesh.indices.append(offset + index)
            }
            let cls = MeshClass.read(geometry)
            mesh.faceClasses += cls.count == faces.count ? cls : [UInt8](repeating: 0, count: faces.count)
        }
        if !mesh.faceClasses.contains(where: { $0 != 0 }) { mesh.faceClasses = [] }
        return mesh
    }
}

/// Scansione mesh: ricostruzione LiDAR + fotogrammi con posa per texture e fotogrammetria.
final class MeshScanner: NSObject, ObservableObject, ARSessionDelegate {
    enum Phase { case ready, scanning, processing, done, failed }

    @Published var phase: Phase = .ready
    @Published var keyframeCount = 0
    @Published var progress: Double = 0
    @Published var statusText = ""
    @Published var resultInfo: MeshInfo?
    /// Durante la scrittura di una nota i fotogrammi non vengono registrati.
    @Published var paused = false

    let maxKeyframes = 500

    private var session: ARSession?
    private var isRecording = false
    private var busy = false
    private var lastTime: TimeInterval = 0
    private var lastTransform: simd_float4x4?
    private var prevFrameTransform: simd_float4x4?
    private var prevFrameTime: TimeInterval = 0
    /// Avviso a schermo: rallenta per avere foto nitide.
    @Published var movingTooFast = false
    private var keyframes: [KeyframeRecord] = []
    /// Mappe di profondità per la ricostruzione finale (circa 5 al secondo).
    private var depthFrames: [DepthFrameRecord] = []
    private var lastDepthTime: TimeInterval = 0
    private var depthBusy = false
    let maxDepthFrames = 1800
    private var meshFolder: URL?
    private let ioQueue = DispatchQueue(label: "rilievo.keyframes")
    private let ciContext = CIContext()

    /// Disegno della mesh durante la scansione (griglia bianca + zone da riprendere in fucsia).
    let overlay = LiveMeshOverlay()

    @MainActor
    func attach(_ view: ARSCNView) {
        session = view.session
        view.delegate = overlay
        view.automaticallyUpdatesLighting = false
        view.session.delegate = self
        view.session.run(MeshScanner.makeConfiguration())
    }

    /// Ricostruzione della mesh dalle mappe di profondità (sperimentale, disattivata di default):
    /// sui vetri e con piccoli spostamenti del tracciamento può sdoppiare le superfici.
    static var depthFusionEnabled: Bool { UserDefaults.standard.bool(forKey: "depthFusion") }

    static func makeConfiguration() -> ARWorldTrackingConfiguration {
        let config = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            // Con la classificazione ARKit riconosce muri, pavimento, porte, finestre e arredi
            config.sceneReconstruction = ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)
                ? .meshWithClassification : .mesh
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            config.frameSemantics.insert(.smoothedSceneDepth)
        }
        return config
    }

    var currentFrame: ARFrame? { session?.currentFrame }

    /// Foto con nota: ancoraggio per correggere posizione e direzione a fine scansione.
    private var photoOrigins: [UUID: simd_float4x4] = [:]
    func addPhotoAnchor(_ id: UUID, transform t: simd_float4x4) {
        photoOrigins[id] = t
        session?.add(anchor: ARAnchor(name: "ph_" + id.uuidString, transform: t))
    }

    func start(meshFolder folder: URL) {
        guard let session else { return }
        let fm = FileManager.default
        try? fm.removeItem(at: folder)
        try? fm.createDirectory(at: folder.appendingPathComponent("export/foto", isDirectory: true),
                                withIntermediateDirectories: true)
        try? fm.createDirectory(at: folder.appendingPathComponent("depth", isDirectory: true),
                                withIntermediateDirectories: true)
        try? fm.createDirectory(at: folder.appendingPathComponent("fusione", isDirectory: true),
                                withIntermediateDirectories: true)
        meshFolder = folder
        keyframes = []
        depthFrames = []
        lastDepthTime = 0
        depthBusy = false
        keyframeCount = 0
        lastTransform = nil
        lastTime = 0
        busy = false
        progress = 0
        session.run(MeshScanner.makeConfiguration(), options: [.resetTracking, .removeExistingAnchors])
        overlay.setPoses([], coverage: true)
        // Dopo un attimo di regolazione automatica, esposizione e bilanciamento del bianco restano fissi:
        // tutte le foto hanno lo stesso tono e le pareti non vengono a chiazze.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, self.isRecording else { return }
            MeshScanner.lockCamera(true)
        }
        isRecording = true
        phase = .scanning
    }

    /// Blocca (o sblocca) esposizione e bilanciamento del bianco della fotocamera usata da ARKit.
    /// Fotocamera durante la scansione: bilanciamento del bianco bloccato (colori costanti),
    /// esposizione automatica ma con tempo di scatto massimo 1/100 s (foto non mosse) e leggermente
    /// scurita per non bruciare finestre e pavimenti al sole. Le differenze di luminosità tra le foto
    /// vengono compensate durante l'elaborazione.
    static func lockCamera(_ lock: Bool) {
        guard let device = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if lock {
                if device.isWhiteBalanceModeSupported(.locked) { device.whiteBalanceMode = .locked }
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                    let maxDuration = CMTime(value: 1, timescale: 100)
                    if maxDuration >= device.activeFormat.minExposureDuration
                        && maxDuration <= device.activeFormat.maxExposureDuration {
                        device.activeMaxExposureDuration = maxDuration
                    }
                    device.setExposureTargetBias(max(device.minExposureTargetBias, -0.5), completionHandler: nil)
                }
            } else {
                if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
                device.activeMaxExposureDuration = .invalid
                device.setExposureTargetBias(0, completionHandler: nil)
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    device.whiteBalanceMode = .continuousAutoWhiteBalance
                }
            }
        } catch {
            print("Impostazione fotocamera non riuscita: \(error)")
        }
    }

    func shutdown() {
        MeshScanner.lockCamera(false)
        isRecording = false
        session?.pause()
    }

    // MARK: ARSessionDelegate (chiamato sul thread principale)

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Velocità dell'iPad tra due fotogrammi consecutivi: se si muove troppo la foto è mossa.
        let t = frame.camera.transform
        var tooFast = false
        if let prev = prevFrameTransform {
            let dt = Float(max(frame.timestamp - prevFrameTime, 1e-3))
            let speed = simd_distance(t.translation, prev.translation) / dt
            let f1 = -SIMD3<Float>(t.columns.2.x, t.columns.2.y, t.columns.2.z)
            let f0 = -SIMD3<Float>(prev.columns.2.x, prev.columns.2.y, prev.columns.2.z)
            let turn = acos(max(-1, min(1, simd_dot(f0, f1)))) * 180 / Float.pi / dt
            tooFast = speed > 0.35 || turn > 25
        }
        prevFrameTransform = t
        prevFrameTime = frame.timestamp
        if isRecording && tooFast != movingTooFast { movingTooFast = tooFast }

        var trackingOK = false
        if case .normal = frame.camera.trackingState { trackingOK = true }
        if isRecording, !paused, !tooFast, trackingOK {
            if MeshScanner.depthFusionEnabled { recordDepth(frame) }
        }

        guard isRecording, !paused, !busy, !tooFast, let folder = meshFolder, keyframes.count < maxKeyframes else { return }
        guard trackingOK else { return }

        if let last = lastTransform {
            if frame.timestamp - lastTime < 0.3 { return }
            let moved = simd_distance(t.translation, last.translation)
            let f1 = -SIMD3<Float>(t.columns.2.x, t.columns.2.y, t.columns.2.z)
            let f0 = -SIMD3<Float>(last.columns.2.x, last.columns.2.y, last.columns.2.z)
            let angle = acos(max(-1, min(1, simd_dot(f0, f1)))) * 180 / Float.pi
            if moved < 0.1 && angle < 8 { return }
        }

        busy = true
        lastTime = frame.timestamp
        lastTransform = t

        let index = keyframes.count
        // Ancoraggio nella posizione della foto: ARKit lo sposta insieme alle sue correzioni del
        // tracciamento, così a fine scansione la posizione della foto coincide con la mesh.
        session.add(anchor: ARAnchor(name: "kf_\(index)", transform: t))
        let name = String(format: "kf_%04d", index)

        var depthPayload: Data? = nil
        var dw = 0
        var dh = 0
        if let depthMap = frame.sceneDepth?.depthMap {
            let copy = MeshScanner.copyDepth(depthMap)
            depthPayload = copy.data
            dw = copy.width
            dh = copy.height
        }
        let depthData = depthPayload

        let image = frame.capturedImage
        let record = KeyframeRecord(index: index,
                                    image: "foto/\(name).jpg",
                                    depth: depthData == nil ? nil : "depth/\(name).bin",
                                    width: CVPixelBufferGetWidth(image),
                                    height: CVPixelBufferGetHeight(image),
                                    depthWidth: dw,
                                    depthHeight: dh,
                                    intrinsics: frame.camera.intrinsics.floatArray,
                                    transform: t.floatArray,
                                    timestamp: frame.timestamp)
        let ci = CIImage(cvPixelBuffer: image)
        let context = ciContext

        ioQueue.async {
            let jpegURL = folder.appendingPathComponent("export").appendingPathComponent(record.image)
            let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            let options: [CIImageRepresentationOption: Any] = [
                CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.85
            ]
            var ok = false
            if let data = context.jpegRepresentation(of: ci, colorSpace: space, options: options) {
                ok = (try? data.write(to: jpegURL)) != nil
            }
            if let depthData, let depthFile = record.depth {
                try? depthData.write(to: folder.appendingPathComponent(depthFile))
            }
            let saved = ok
            DispatchQueue.main.async {
                if saved {
                    self.keyframes.append(record)
                    self.keyframeCount = self.keyframes.count
                    self.overlay.setPoses(self.keyframes.map(CamPose.init), coverage: true)
                }
                self.busy = false
            }
        }
    }

    /// Salva la profondità (filtrata da ARKit) e la sua affidabilità per la fusione finale.
    private func recordDepth(_ frame: ARFrame) {
        guard !depthBusy, let folder = meshFolder, depthFrames.count < maxDepthFrames,
              frame.timestamp - lastDepthTime >= 0.2,
              let sceneDepth = frame.smoothedSceneDepth ?? frame.sceneDepth else { return }
        lastDepthTime = frame.timestamp
        depthBusy = true
        let depth = MeshScanner.copyPixels(sceneDepth.depthMap, bytesPerPixel: 4)
        var payload = depth.data
        if let conf = sceneDepth.confidenceMap {
            payload.append(MeshScanner.copyPixels(conf, bytesPerPixel: 1).data)
        }
        let imageW = Float(CVPixelBufferGetWidth(frame.capturedImage))
        let imageH = Float(CVPixelBufferGetHeight(frame.capturedImage))
        let sx = Float(depth.width) / imageW
        let sy = Float(depth.height) / imageH
        let k = frame.camera.intrinsics
        let record = DepthFrameRecord(file: String(format: "fusione/d_%05d.bin", depthFrames.count),
                                      width: depth.width, height: depth.height,
                                      intrinsics: [k[0][0] * sx, k[1][1] * sy, k[2][0] * sx, k[2][1] * sy],
                                      transform: frame.camera.transform.floatArray)
        let data = payload
        ioQueue.async {
            let ok = (try? data.write(to: folder.appendingPathComponent(record.file))) != nil
            DispatchQueue.main.async {
                if ok { self.depthFrames.append(record) }
                self.depthBusy = false
            }
        }
    }

    static func copyPixels(_ buffer: CVPixelBuffer, bytesPerPixel: Int) -> (data: Data, width: Int, height: Int) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        var data = Data(capacity: w * h * bytesPerPixel)
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            for y in 0..<h {
                let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
                data.append(row, count: w * bytesPerPixel)
            }
        }
        return (data, w, h)
    }

    static func copyDepth(_ buffer: CVPixelBuffer) -> (data: Data, width: Int, height: Int) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        var data = Data(capacity: w * h * 4)
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            for y in 0..<h {
                let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
                data.append(row, count: w * 4)
            }
        }
        return (data, w, h)
    }

    // MARK: Fine scansione ed elaborazione

    func stopAndProcess(store: ProjectStore, projectID: UUID) {
        guard phase == .scanning, let session, let folder = meshFolder else { return }
        isRecording = false
        phase = .processing
        statusText = "Raccolta della mesh…"

        let allAnchors = session.currentFrame?.anchors ?? []
        let anchors = allAnchors.compactMap { $0 as? ARMeshAnchor }
        let mesh = MeshData.from(anchors)
        // Posizioni delle foto corrette da ARKit (ancoraggi "kf_N")
        var correctedPoses: [Int: simd_float4x4] = [:]
        var photoDelta: [UUID: simd_float4x4] = [:]
        for a in allAnchors {
            guard let name = a.name else { continue }
            if name.hasPrefix("kf_"), let i = Int(name.dropFirst(3)) { correctedPoses[i] = a.transform }
            if name.hasPrefix("ph_"), let id = UUID(uuidString: String(name.dropFirst(3))), let orig = photoOrigins[id] {
                photoDelta[id] = a.transform * orig.inverse
            }
        }
        if !photoDelta.isEmpty {
            store.update(projectID) { p in
                for i in p.photos.indices {
                    guard let d = photoDelta[p.photos[i].id] else { continue }
                    func move(_ v: [Float]?, w: Float) -> [Float]? {
                        guard let v, v.count == 3 else { return v }
                        let r = d * SIMD4<Float>(v[0], v[1], v[2], w)
                        return [r.x, r.y, r.z]
                    }
                    p.photos[i].position = move(p.photos[i].position, w: 1) ?? p.photos[i].position
                    p.photos[i].direction = move(p.photos[i].direction, w: 0)
                    p.photos[i].target = move(p.photos[i].target, w: 1)
                }
            }
        }
        MeshScanner.lockCamera(false)
        session.pause()

        // Aspetta che l'ultimo fotogramma sia stato scritto su disco.
        ioQueue.async {
            DispatchQueue.main.async {
                let frames: [KeyframeRecord] = self.keyframes.map { kf in
                    var k = kf
                    if let t = correctedPoses[kf.index] { k.transform = t.floatArray }
                    return k
                }
                let depthFrames = self.depthFrames
                let startTime = Date()
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        // 1. Ricostruzione della mesh dalle misure di profondità (come fa Polycam a fine scansione).
                        //    Se non riesce si usa la mesh in tempo reale di ARKit.
                        var source = mesh
                        var fusedCount = 0
                        let fusionShare = MeshScanner.depthFusionEnabled && depthFrames.count >= 10 ? 0.45 : 0
                        if fusionShare > 0,
                           let fused = DepthFusion.fuse(meshFolder: folder, frames: depthFrames, progress: { p, text in
                               DispatchQueue.main.async {
                                   self.progress = p * fusionShare
                                   self.statusText = text
                               }
                           }) {
                            source = DepthFusion.fillGaps(fused: fused, arkit: mesh)
                            fusedCount = depthFrames.count
                        }
                        try? FileManager.default.removeItem(at: folder.appendingPathComponent("fusione"))

                        // 2. Texture dalle foto
                        var info = try MeshExporter.export(mesh: source, keyframes: frames, folder: folder,
                                                           fused: fusedCount > 0) { p, text in
                            DispatchQueue.main.async {
                                self.progress = fusionShare + p * (1 - fusionShare)
                                self.statusText = text
                            }
                        }
                        info.depthFrames = fusedCount
                        info.processingSeconds = Date().timeIntervalSince(startTime)
                        let finalInfo = info
                        DispatchQueue.main.async {
                            let info = finalInfo
                            store.update(projectID) { $0.mesh = info }
                            self.resultInfo = info
                            self.progress = 1
                            self.phase = .done
                        }
                    } catch {
                        let message = error.localizedDescription
                        DispatchQueue.main.async {
                            self.statusText = message
                            self.phase = .failed
                        }
                    }
                }
            }
        }
    }
}

struct ARViewContainer: UIViewRepresentable {
    let scanner: MeshScanner

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        scanner.attach(view)
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}

// MARK: - Schermata di scansione mesh

struct MeshScanView: View {
    let projectID: UUID
    @EnvironmentObject var store: ProjectStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var scanner = MeshScanner()

    @State private var showNote = false
    @AppStorage("depthFusion") private var depthFusion = false
    @State private var noteText = ""
    @State private var widthText = ""
    @State private var heightText = ""
    @State private var roomText = ""
    @State private var levelText = ""
    @AppStorage("lastPhotoRoom") private var lastRoom = ""
    @AppStorage("lastPhotoLevel") private var lastLevel = ""
    @State private var pendingPhotoID: UUID?

    var body: some View {
        ZStack {
            ARViewContainer(scanner: scanner)
                .ignoresSafeArea()

            VStack {
                HStack {
                    Button {
                        scanner.shutdown()
                        dismiss()
                    } label: {
                        Label("Chiudi", systemImage: "xmark")
                    }
                    .disabled(scanner.phase == .processing)
                    Spacer()
                    TorchButton()
                        .padding(.trailing, 12)
                    if scanner.phase == .scanning {
                        if scanner.movingTooFast && !scanner.paused {
                            Label("Rallenta", systemImage: "tortoise.fill")
                                .font(.subheadline.bold())
                                .foregroundStyle(.orange)
                        }
                        Text(scanner.paused ? "In pausa" : "Fotogrammi: \(scanner.keyframeCount)/\(scanner.maxKeyframes)")
                            .font(.subheadline.monospacedDigit())
                    }
                }
                .padding(12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding()

                Spacer()

                VStack(spacing: 10) {
                    panel
                }
                .padding()
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                .padding()
            }
        }
        .sheet(isPresented: $showNote, onDismiss: { scanner.paused = false }) {
            PhotoNoteForm(note: $noteText, width: $widthText, height: $heightText,
                          room: $roomText, level: $levelText,
                          message: "La registrazione è in pausa: riprende quando chiudi la nota.",
                          onSave: { saveNote() }, onSkip: {})
        }
    }

    @ViewBuilder
    private var panel: some View {
        switch scanner.phase {
        case .ready:
            Toggle(isOn: $depthFusion) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ricostruzione dalla profondità (sperimentale)")
                    Text("Superfici più lisce, ma su vetri e grate può sdoppiare o bucare. Di solito meglio spenta.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 520)
            Text("Muoviti lentamente a 1–2 m dalle superfici. La griglia bianca è la mesh; durante la scansione le zone in fucsia non sono ancora riprese dalle foto: passaci sopra finché diventano bianche.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button {
                store.update(projectID) { $0.mesh = nil }
                scanner.start(meshFolder: store.folder(for: projectID).appendingPathComponent("mesh", isDirectory: true))
            } label: {
                Label("Avvia scansione mesh", systemImage: "record.circle")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        case .scanning:
            HStack(spacing: 16) {
                Button {
                    takePhoto()
                } label: {
                    Label("Foto con nota", systemImage: "camera.fill")
                }
                .buttonStyle(.bordered)

                Button(role: .destructive) {
                    scanner.stopAndProcess(store: store, projectID: projectID)
                } label: {
                    Label("Termina", systemImage: "stop.circle.fill")
                }
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(LiveMeshOverlay.fillColor))
                    .frame(width: 14, height: 14)
                Text("Zone ancora da riprendere: passaci sopra lentamente finché diventano bianche")
                    .font(.caption)
            }
        case .processing:
            ProgressView(value: scanner.progress) {
                Text(scanner.statusText)
            }
            .frame(maxWidth: 400)
            Text("Non chiudere l'app durante l'elaborazione.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .done:
            if let info = scanner.resultInfo {
                Text("Mesh pronta: \(info.faces) triangoli, \(info.keyframes) foto.")
                Text("\(info.sourceText) · elaborazione \(Int((info.processingSeconds ?? 0).rounded())) s · texture \(Int(((info.textureScale ?? 1) * 100).rounded()))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Chiudi") { dismiss() }
                .buttonStyle(.borderedProminent)
        case .failed:
            Text(scanner.statusText)
                .foregroundStyle(.red)
            Button("Chiudi") { dismiss() }
                .buttonStyle(.bordered)
        }
    }

    private func takePhoto() {
        guard let frame = scanner.currentFrame,
              let record = PhotoSaver.save(frame: frame, projectFolder: store.folder(for: projectID), source: "mesh")
        else { return }
        scanner.paused = true
        scanner.addPhotoAnchor(record.id, transform: frame.camera.transform)
        store.update(projectID) { $0.photos.append(record) }
        pendingPhotoID = record.id
        noteText = ""
        widthText = ""
        roomText = lastRoom
        levelText = lastLevel
        heightText = ""
        showNote = true
    }

    private func saveNote() {
        guard let id = pendingPhotoID else { return }
        let text = noteText
        let w = PhotoAim.parseMeters(widthText)
        let h = PhotoAim.parseMeters(heightText)
        let room = roomText.trimmingCharacters(in: .whitespaces)
        let level = levelText.trimmingCharacters(in: .whitespaces)
        lastRoom = room
        lastLevel = level
        store.update(projectID) { p in
            if let i = p.photos.firstIndex(where: { $0.id == id }) {
                p.photos[i].note = text
                p.photos[i].width = w
                p.photos[i].height = h
                p.photos[i].room = room.isEmpty ? nil : room
                p.photos[i].level = level.isEmpty ? nil : level
            }
        }
    }
}
