import SwiftUI
import ARKit
import RealityKit
import CoreImage
import Metal

/// Mesh LiDAR in coordinate mondo, estratta dagli ARMeshAnchor.
struct MeshData {
    var vertices: [SIMD3<Float>] = []
    var indices: [UInt32] = []

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
        }
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
    private var keyframes: [KeyframeRecord] = []
    private var meshFolder: URL?
    private let ioQueue = DispatchQueue(label: "rilievo.keyframes")
    private let ciContext = CIContext()

    @MainActor
    func attach(_ arView: ARView) {
        session = arView.session
        arView.session.delegate = self
        arView.debugOptions.insert(.showSceneUnderstanding)
        arView.session.run(MeshScanner.makeConfiguration())
    }

    static func makeConfiguration() -> ARWorldTrackingConfiguration {
        let config = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        return config
    }

    var currentFrame: ARFrame? { session?.currentFrame }

    func start(meshFolder folder: URL) {
        guard let session else { return }
        let fm = FileManager.default
        try? fm.removeItem(at: folder)
        try? fm.createDirectory(at: folder.appendingPathComponent("export/foto", isDirectory: true),
                                withIntermediateDirectories: true)
        try? fm.createDirectory(at: folder.appendingPathComponent("depth", isDirectory: true),
                                withIntermediateDirectories: true)
        meshFolder = folder
        keyframes = []
        keyframeCount = 0
        lastTransform = nil
        lastTime = 0
        busy = false
        progress = 0
        session.run(MeshScanner.makeConfiguration(), options: [.resetTracking, .removeExistingAnchors])
        isRecording = true
        phase = .scanning
    }

    func shutdown() {
        isRecording = false
        session?.pause()
    }

    // MARK: ARSessionDelegate (chiamato sul thread principale)

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard isRecording, !paused, !busy, let folder = meshFolder, keyframes.count < maxKeyframes else { return }
        guard case .normal = frame.camera.trackingState else { return }

        let t = frame.camera.transform
        if let last = lastTransform {
            if frame.timestamp - lastTime < 0.5 { return }
            let moved = simd_distance(t.translation, last.translation)
            let f1 = -SIMD3<Float>(t.columns.2.x, t.columns.2.y, t.columns.2.z)
            let f0 = -SIMD3<Float>(last.columns.2.x, last.columns.2.y, last.columns.2.z)
            let angle = acos(max(-1, min(1, simd_dot(f0, f1)))) * 180 / Float.pi
            if moved < 0.2 && angle < 12 { return }
        }

        busy = true
        lastTime = frame.timestamp
        lastTransform = t

        let index = keyframes.count
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
                }
                self.busy = false
            }
        }
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

        let anchors = session.currentFrame?.anchors.compactMap { $0 as? ARMeshAnchor } ?? []
        let mesh = MeshData.from(anchors)
        session.pause()

        // Aspetta che l'ultimo fotogramma sia stato scritto su disco.
        ioQueue.async {
            DispatchQueue.main.async {
                let frames = self.keyframes
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let info = try MeshExporter.export(mesh: mesh, keyframes: frames, folder: folder) { p, text in
                            DispatchQueue.main.async {
                                self.progress = p
                                self.statusText = text
                            }
                        }
                        DispatchQueue.main.async {
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

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        scanner.attach(view)
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
}

// MARK: - Schermata di scansione mesh

struct MeshScanView: View {
    let projectID: UUID
    @EnvironmentObject var store: ProjectStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var scanner = MeshScanner()

    @State private var showNote = false
    @State private var noteText = ""
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
                    if scanner.phase == .scanning {
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
        .alert("Nota per la foto", isPresented: $showNote) {
            TextField("Nota (facoltativa)", text: $noteText)
            Button("Salva") {
                saveNote()
                scanner.paused = false
            }
            Button("Salta", role: .cancel) {
                scanner.paused = false
            }
        } message: {
            Text("La registrazione è in pausa: tieni l'iPad fermo, riprende dopo la nota.")
        }
    }

    @ViewBuilder
    private var panel: some View {
        switch scanner.phase {
        case .ready:
            Text("Muoviti lentamente a 1–2 m dalle superfici. La mesh si disegna sullo schermo; l'app salva in automatico le foto per la texture.")
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
        store.update(projectID) { $0.photos.append(record) }
        pendingPhotoID = record.id
        noteText = ""
        showNote = true
    }

    private func saveNote() {
        guard let id = pendingPhotoID else { return }
        let text = noteText
        store.update(projectID) { p in
            if let i = p.photos.firstIndex(where: { $0.id == id }) { p.photos[i].note = text }
        }
    }
}
