import SwiftUI
import SceneKit
import UIKit
import simd

// MARK: - Annotazioni salvate (misure, aree, note, scala)

struct SavedMeasure: Codable, Identifiable {
    var id: UUID
    var kind: String          // "linea" oppure "area"
    var points: [[Float]]

    var vectors: [SIMD3<Float>] {
        points.compactMap { $0.count == 3 ? SIMD3<Float>($0[0], $0[1], $0[2]) : nil }
    }
}

struct SavedNote: Codable, Identifiable {
    var id: UUID
    var text: String
    var point: [Float]
}

struct SavedAnnotations: Codable {
    var scale: Float
    var measures: [SavedMeasure]
    var notes: [SavedNote]

    static let empty = SavedAnnotations(scale: 1, measures: [], notes: [])
}

enum Geo {
    static func length(_ p: [SIMD3<Float>]) -> Float {
        guard p.count > 1 else { return 0 }
        var s: Float = 0
        for i in 1..<p.count { s += simd_distance(p[i - 1], p[i]) }
        return s
    }

    /// Vettore area (metodo di Newell): lunghezza = area del poligono 3D.
    static func areaVector(_ p: [SIMD3<Float>]) -> SIMD3<Float> {
        guard p.count > 2 else { return SIMD3<Float>(0, 0, 0) }
        var n = SIMD3<Float>(0, 0, 0)
        for i in 0..<p.count { n += simd_cross(p[i], p[(i + 1) % p.count]) }
        return n / 2
    }

    static func area(_ p: [SIMD3<Float>]) -> Float { simd_length(areaVector(p)) }

    /// Area proiettata in pianta.
    static func planArea(_ p: [SIMD3<Float>]) -> Float { abs(areaVector(p).y) }

    static func centroid(_ p: [SIMD3<Float>]) -> SIMD3<Float> {
        guard !p.isEmpty else { return SIMD3<Float>(0, 0, 0) }
        var s = SIMD3<Float>(0, 0, 0)
        for v in p { s += v }
        return s / Float(p.count)
    }

    static func array(_ v: SIMD3<Float>) -> [Float] { [v.x, v.y, v.z] }
}

// MARK: - Geometria della mesh letta dall'anteprima

struct MeshGeometry {
    var vertices: [SIMD3<Float>]
    var colors: [SIMD3<Float>]
    var indices: [UInt32]
    /// Classe ARKit per faccia (vuoto se non disponibile).
    var classes: [UInt8] = []

    static func load(from scene: SCNScene) -> MeshGeometry? {
        var found: SCNGeometry?
        scene.rootNode.enumerateHierarchy { node, stop in
            if let g = node.geometry, g.elements.first?.primitiveType == .triangles {
                found = g
                stop.pointee = true
            }
        }
        guard let g = found,
              let vs = g.sources(for: .vertex).first,
              let element = g.elements.first else { return nil }
        let vertices = read3(vs)
        let colors = g.sources(for: .color).first.map { read3($0) } ?? []

        var indices: [UInt32] = []
        let count = element.primitiveCount * 3
        indices.reserveCapacity(count)
        let bytes = element.bytesPerIndex
        element.data.withUnsafeBytes { raw in
            for i in 0..<count {
                switch bytes {
                case 4: indices.append(raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self))
                case 2: indices.append(UInt32(raw.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self)))
                default: indices.append(UInt32(raw.loadUnaligned(fromByteOffset: i, as: UInt8.self)))
                }
            }
        }
        return MeshGeometry(vertices: vertices,
                            colors: colors.count == vertices.count ? colors : [],
                            indices: indices)
    }

    static func read3(_ s: SCNGeometrySource) -> [SIMD3<Float>] {
        var out: [SIMD3<Float>] = []
        out.reserveCapacity(s.vectorCount)
        let stride = s.dataStride
        let offset = s.dataOffset
        let bpc = s.bytesPerComponent
        s.data.withUnsafeBytes { raw in
            for i in 0..<s.vectorCount {
                let o = offset + i * stride
                if s.usesFloatComponents && bpc == 4 {
                    out.append(SIMD3<Float>(raw.loadUnaligned(fromByteOffset: o, as: Float.self),
                                            raw.loadUnaligned(fromByteOffset: o + 4, as: Float.self),
                                            raw.loadUnaligned(fromByteOffset: o + 8, as: Float.self)))
                } else if s.usesFloatComponents && bpc == 8 {
                    out.append(SIMD3<Float>(Float(raw.loadUnaligned(fromByteOffset: o, as: Double.self)),
                                            Float(raw.loadUnaligned(fromByteOffset: o + 8, as: Double.self)),
                                            Float(raw.loadUnaligned(fromByteOffset: o + 16, as: Double.self))))
                } else if !s.usesFloatComponents && bpc == 1 {
                    out.append(SIMD3<Float>(Float(raw.loadUnaligned(fromByteOffset: o, as: UInt8.self)) / 255,
                                            Float(raw.loadUnaligned(fromByteOffset: o + 1, as: UInt8.self)) / 255,
                                            Float(raw.loadUnaligned(fromByteOffset: o + 2, as: UInt8.self)) / 255))
                }
            }
        }
        return out
    }

    /// Sezione orizzontale alla quota h: segmenti dove i triangoli tagliano il piano.
    func section(at h: Float) -> [(SIMD3<Float>, SIMD3<Float>)] {
        var segments: [(SIMD3<Float>, SIMD3<Float>)] = []
        var t = 0
        while t + 2 < indices.count {
            let a = vertices[Int(indices[t])]
            let b = vertices[Int(indices[t + 1])]
            let c = vertices[Int(indices[t + 2])]
            t += 3
            let da = a.y - h
            let db = b.y - h
            let dc = c.y - h
            if (da > 0 && db > 0 && dc > 0) || (da < 0 && db < 0 && dc < 0) { continue }
            var pts: [SIMD3<Float>] = []
            if (da > 0) != (db > 0) { pts.append(a + (b - a) * (da / (da - db))) }
            if (db > 0) != (dc > 0) { pts.append(b + (c - b) * (db / (db - dc))) }
            if (dc > 0) != (da > 0) { pts.append(c + (a - c) * (dc / (dc - da))) }
            if pts.count >= 2 { segments.append((pts[0], pts[1])) }
        }
        return segments
    }

    /// PLY binario con colori per vertice (CloudCompare, MeshLab, Recap, Blender).
    func writePLY(to url: URL) throws {
        var data = Data()
        data.reserveCapacity(vertices.count * 15 + indices.count / 3 * 13 + 400)
        let header = """
        ply
        format binary_little_endian 1.0
        comment Rilievo LiDAR - unita metri, asse Y verso l'alto
        element vertex \(vertices.count)
        property float x
        property float y
        property float z
        property uchar red
        property uchar green
        property uchar blue
        element face \(indices.count / 3)
        property list uchar int vertex_indices
        end_header

        """
        data.append(header.data(using: .ascii) ?? Data())

        func appendFloat(_ v: Float) {
            var bits = v.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        func appendInt32(_ v: Int32) {
            var x = v.littleEndian
            withUnsafeBytes(of: &x) { data.append(contentsOf: $0) }
        }
        func byte(_ f: Float) -> UInt8 { UInt8(max(0, min(255, (f * 255).rounded()))) }

        for (i, v) in vertices.enumerated() {
            appendFloat(v.x)
            appendFloat(v.y)
            appendFloat(v.z)
            let c = i < colors.count ? colors[i] : SIMD3<Float>(0.7, 0.7, 0.7)
            data.append(byte(c.x))
            data.append(byte(c.y))
            data.append(byte(c.z))
        }
        var t = 0
        while t + 2 < indices.count {
            data.append(UInt8(3))
            appendInt32(Int32(indices[t]))
            appendInt32(Int32(indices[t + 1]))
            appendInt32(Int32(indices[t + 2]))
            t += 3
        }
        try data.write(to: url)
    }
}

// MARK: - Modello del visualizzatore

final class MeshViewerModel: ObservableObject {
    enum Tool: String, CaseIterable, Identifiable {
        case naviga = "Naviga"
        case righello = "Righello"
        case area = "Area"
        case nota = "Nota"
        case sezione = "Sezione"
        case ritaglia = "Ritaglia"
        case tour = "Tour"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .naviga: return "hand.draw"
            case .righello: return "ruler"
            case .area: return "skew"
            case .nota: return "text.bubble"
            case .sezione: return "square.split.1x2"
            case .ritaglia: return "crop"
            case .tour: return "figure.walk"
            }
        }
    }

    enum ViewPreset: String, CaseIterable, Identifiable {
        case prospettiva = "3D (prospettiva)"
        case fronte = "Fronte"
        case retro = "Retro"
        case sinistra = "Sinistra"
        case destra = "Destra"
        case alto = "Dall'alto"
        case basso = "Dal basso"

        var id: String { rawValue }
    }

    static let meshMask = 1
    static let helperMask = 2
    static let photoMask = 4

    @Published var tool: Tool = .naviga {
        didSet { toolChanged(from: oldValue) }
    }
    @Published var annotations = SavedAnnotations.empty
    @Published var currentPoints: [SIMD3<Float>] = []
    @Published var showPath = false {
        didSet { pathRoot.isHidden = !showPath }
    }
    @Published var showGrid = false {
        didSet { gridRoot.isHidden = !showGrid }
    }
    @Published var topView = false {
        didSet {
            if tool != .tour { scnView?.pointOfView = topView ? topCamera : orbitCamera }
        }
    }
    /// Mesh monocolore bianca con ombreggiatura invece dei colori delle foto.
    @Published var whiteMesh = UserDefaults.standard.object(forKey: "meshWhite") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(whiteMesh, forKey: "meshWhite")
            applyMeshStyle()
        }
    }
    /// Proiezione ortogonale (senza prospettiva) della vista 3D.
    @Published var orthographic = false {
        didSet { applyProjection() }
    }
    /// Ritaglio applicato e scatola in modifica.
    @Published private(set) var crop: CropBox?
    @Published var draftCrop = CropBox(center: .zero, size: .one, yaw: 0, keepInside: true) {
        didSet { if tool == .ritaglia { updateCropNode() } }
    }
    @Published var cropError: String?
    @Published var sectionHeight: Float = 0
    /// Con lo strumento Sezione il modello viene tagliato alla quota scelta (sparisce ciò che sta sopra).
    @Published var cutModel = true {
        didSet { applyCut() }
    }
    @Published var sectionCount = 0
    @Published var tourIndex = 0
    @Published var playing = false
    @Published var photoOverlay = false
    @Published var overlayOpacity: Double = 0.6
    @Published var tourImage: UIImage?
    @Published var askNote = false
    @Published var askCalibration = false
    @Published var shareItem: ShareItem?

    let meshFolder: URL
    let scene: SCNScene?
    let keyframes: [KeyframeRecord]
    /// Mesh completa e mesh visibile (dopo il ritaglio).
    let fullGeometry: MeshGeometry?
    /// Mesh con atlante di texture (scansioni nuove); nil per le scansioni vecchie.
    private let textured: TexturedMesh?
    private let atlasImages: [UIImage]
    private(set) var geometry: MeshGeometry?
    private(set) var minP = SIMD3<Float>(0, 0, 0)
    private(set) var maxP = SIMD3<Float>(1, 1, 1)
    private var markerSize: Float = 0.02

    private let annotationRoot = SCNNode()
    private let pathRoot = SCNNode()
    private let gridRoot = SCNNode()
    private let sectionRoot = SCNNode()
    private let cropRoot = SCNNode()
    private var colorNode: SCNNode?
    private var whiteNode: SCNNode?
    private let orbitCamera: SCNNode
    private let topCamera = SCNNode()
    private let tourCamera = SCNNode()
    private var sectionSegments: [(SIMD3<Float>, SIMD3<Float>)] = []
    private var timer: Timer?
    weak var scnView: SCNView?

    var notePoint: SIMD3<Float>?
    var calibrationTarget: SavedMeasure?

    var scale: Float { annotations.scale }

    init(meshFolder: URL) {
        self.meshFolder = meshFolder
        let loaded = try? SCNScene(url: meshFolder.appendingPathComponent("preview.scn"), options: nil)
        scene = loaded
        keyframes = KeyframeStore.load(meshFolder: meshFolder)
        let full = loaded.flatMap { MeshGeometry.load(from: $0) }
        fullGeometry = full
        let tex = TexturedMesh.load(meshFolder: meshFolder)
        let images = tex.map { TexturedMesh.loadPages(meshFolder: meshFolder, count: $0.pageCount) } ?? []
        textured = images.isEmpty ? nil : tex
        atlasImages = images
        let savedCrop = CropBox.load(meshFolder)
        var visible = full
        var appliedCrop: CropBox? = nil
        if let full, let savedCrop {
            let g = full.cropped(savedCrop)
            if !g.isEmpty {
                visible = g
                appliedCrop = savedCrop
            }
        }
        geometry = visible

        if let camera = loaded?.rootNode.childNode(withName: "camera", recursively: true) {
            orbitCamera = camera
        } else {
            let node = SCNNode()
            node.camera = SCNCamera()
            orbitCamera = node
        }

        crop = appliedCrop
        if let g = fullGeometry, let first = g.vertices.first {
            var lo = first
            var hi = first
            for v in g.vertices {
                lo = simd_min(lo, v)
                hi = simd_max(hi, v)
            }
            minP = lo
            maxP = hi
        }
        if maxP.y - minP.y < 0.05 { maxP.y = minP.y + 0.05 }
        let size = simd_distance(minP, maxP)
        markerSize = min(max(size * 0.004, 0.008), 0.05)
        let floor = geometry.map { MeshPlanExport.floorY($0.vertices, fallback: minP.y) } ?? minP.y
        sectionHeight = min(max(floor + MeshPlanExport.sectionAboveFloor, minP.y), maxP.y)

        guard let loaded else { return }
        let root = loaded.rootNode
        root.enumerateHierarchy { node, stop in
            if let g = node.geometry, g.elements.first?.primitiveType == .triangles {
                colorNode = node
                stop.pointee = true
            }
        }
        if let g = geometry, let colorNode {
            let node = SCNNode(geometry: g.whiteGeometry())
            node.categoryBitMask = MeshViewerModel.meshMask
            colorNode.parent?.addChildNode(node)
            whiteNode = node
        }
        if textured != nil || crop != nil { show(geometry, crop: crop) }
        applyMeshStyle()
        draftCrop = crop ?? CropBox.around(min: minP, max: maxP)
        for node in [annotationRoot, pathRoot, gridRoot, sectionRoot, cropRoot] { root.addChildNode(node) }
        setupCameras(size: size)
        root.addChildNode(topCamera)
        root.addChildNode(tourCamera)
        buildPath()
        pathRoot.isHidden = !showPath
        buildGrid()
        gridRoot.isHidden = true
        annotations = MeshViewerModel.loadAnnotations(meshFolder)
        rebuildAnnotations()
    }

    private func applyMeshStyle() {
        guard whiteNode != nil else { return }
        whiteNode?.isHidden = !whiteMesh
        colorNode?.isHidden = whiteMesh
    }

    func attach(_ view: SCNView) {
        scnView = view
        view.pointOfView = orbitCamera
        let c = (minP + maxP) / 2
        view.defaultCameraController.target = SCNVector3(c.x, c.y, c.z)
    }

    /// Aggiorna la mesh visibile: con texture se disponibile, altrimenti colori per vertice.
    private func show(_ g: MeshGeometry?, crop box: CropBox?) {
        if let tex = textured {
            let t = box.map { tex.cropped($0) } ?? tex
            if let geo = t.scnGeometry(images: atlasImages) { colorNode?.geometry = geo }
        } else if let g, !g.isEmpty {
            colorNode?.geometry = g.coloredGeometry()
        }
        if let g, !g.isEmpty { whiteNode?.geometry = g.whiteGeometry() }
        applyCut()
    }

    // MARK: Taglio del modello alla quota della sezione

    private static let cutModifier = """
    #pragma arguments
    float cutHeight;
    float cutEnabled;
    #pragma body
    if (cutEnabled > 0.5) {
        float4 worldPos = scn_frame.inverseViewTransform * float4(_surface.position, 1.0);
        if (worldPos.y > cutHeight) {
            discard_fragment();
        }
    }
    """

    /// Aggiorna il taglio su tutte le superfici della mesh (veloce: si può chiamare mentre si trascina il cursore).
    func applyCut() {
        let enabled = tool == .sezione && cutModel
        for node in [colorNode, whiteNode].compactMap({ $0 }) {
            for m in node.geometry?.materials ?? [] {
                if m.shaderModifiers?[.surface] == nil {
                    m.shaderModifiers = [.surface: MeshViewerModel.cutModifier]
                }
                m.setValue(NSNumber(value: sectionHeight), forKey: "cutHeight")
                m.setValue(NSNumber(value: enabled ? 1.0 : 0.0), forKey: "cutEnabled")
            }
        }
    }

    // MARK: Proiezione e viste

    private func applyProjection() {
        guard let camera = orbitCamera.camera else { return }
        camera.usesOrthographicProjection = orthographic
        camera.orthographicScale = Double(max(simd_distance(minP, maxP), 1) * 0.55)
    }

    func setView(_ preset: ViewPreset) {
        if tool == .tour { tool = .naviga }
        if topView { topView = false }
        let center = (minP + maxP) / 2
        let dist = max(simd_distance(minP, maxP), 1) * 1.3
        var up = SIMD3<Float>(0, 1, 0)
        let dir: SIMD3<Float>
        switch preset {
        case .prospettiva: dir = simd_normalize(SIMD3<Float>(0.55, 0.6, 0.85))
        case .fronte: dir = SIMD3<Float>(0, 0, 1)
        case .retro: dir = SIMD3<Float>(0, 0, -1)
        case .sinistra: dir = SIMD3<Float>(-1, 0, 0)
        case .destra: dir = SIMD3<Float>(1, 0, 0)
        case .alto:
            dir = SIMD3<Float>(0, 1, 0)
            up = SIMD3<Float>(0, 0, -1)
        case .basso:
            dir = SIMD3<Float>(0, -1, 0)
            up = SIMD3<Float>(0, 0, 1)
        }
        orbitCamera.simdPosition = center + dir * dist
        orbitCamera.simdLook(at: center, up: up, localFront: SIMD3<Float>(0, 0, -1))
        scnView?.pointOfView = orbitCamera
        scnView?.defaultCameraController.target = SCNVector3(center.x, center.y, center.z)
        orthographic = preset != .prospettiva
    }

    // MARK: Ritaglio

    var cropExtent: SIMD3<Float> { simd_max(maxP - minP, SIMD3<Float>(repeating: 0.1)) }

    private func enterCrop() {
        cropError = nil
        draftCrop = crop ?? CropBox.around(min: minP, max: maxP)
        show(fullGeometry, crop: nil)
        updateCropNode()
    }

    private func exitCrop() {
        for child in cropRoot.childNodes { child.removeFromParentNode() }
        show(geometry, crop: crop)
    }

    private func updateCropNode() {
        for child in cropRoot.childNodes { child.removeFromParentNode() }
        let b = draftCrop
        let tint: UIColor = b.keepInside ? .systemIndigo : .systemRed
        let box = SCNBox(width: CGFloat(b.size.x), height: CGFloat(b.size.y), length: CGFloat(b.size.z), chamferRadius: 0)
        let fill = SCNMaterial()
        fill.diffuse.contents = tint.withAlphaComponent(0.22)
        fill.lightingModel = .constant
        fill.isDoubleSided = true
        fill.writesToDepthBuffer = false
        box.materials = [fill]
        let node = SCNNode(geometry: box)
        node.simdPosition = b.center
        node.eulerAngles.y = b.yawRadians
        node.renderingOrder = 50

        // Spigoli della scatola
        let h = b.size / 2
        var corners: [SCNVector3] = []
        for x in [-h.x, h.x] {
            for y in [-h.y, h.y] {
                for z in [-h.z, h.z] { corners.append(SCNVector3(x, y, z)) }
            }
        }
        let edges: [(Int, Int)] = [(0, 1), (2, 3), (4, 5), (6, 7), (0, 2), (1, 3),
                                   (4, 6), (5, 7), (0, 4), (1, 5), (2, 6), (3, 7)]
        var verts: [SCNVector3] = []
        for e in edges {
            verts.append(corners[e.0])
            verts.append(corners[e.1])
        }
        node.addChildNode(MeshViewerModel.lines(verts, color: tint))
        cropRoot.addChildNode(node)
        cropRoot.enumerateHierarchy { n, _ in n.categoryBitMask = MeshViewerModel.helperMask }
    }

    func resetDraftCrop() {
        let keep = draftCrop.keepInside
        var box = CropBox.around(min: minP, max: maxP)
        box.keepInside = keep
        draftCrop = box
    }

    func applyCrop() {
        guard let full = fullGeometry else { return }
        let g = full.cropped(draftCrop)
        guard !g.isEmpty else {
            cropError = "Il ritaglio eliminerebbe tutta la mesh: allarga la scatola o cambia modalità."
            return
        }
        crop = draftCrop
        draftCrop.save(meshFolder)
        geometry = g
        cropError = nil
        tool = .naviga
    }

    func removeCrop() {
        CropBox.remove(meshFolder)
        crop = nil
        geometry = fullGeometry
        resetDraftCrop()
        if tool != .ritaglia { show(geometry, crop: nil) }
    }

    // MARK: Telecamere

    private func setupCameras(size: Float) {
        let center = (minP + maxP) / 2
        let top = SCNCamera()
        top.usesOrthographicProjection = true
        top.orthographicScale = Double(max(maxP.x - minP.x, maxP.z - minP.z) * 0.6)
        top.zNear = 0.01
        top.zFar = Double(size * 10 + 20)
        topCamera.camera = top
        topCamera.simdPosition = SIMD3<Float>(center.x, maxP.y + size + 2, center.z)
        topCamera.simdLook(at: center, up: SIMD3<Float>(0, 0, -1), localFront: SIMD3<Float>(0, 0, -1))

        let tour = SCNCamera()
        tour.zNear = 0.02
        tour.zFar = Double(size * 10 + 20)
        tourCamera.camera = tour
    }

    private func toolChanged(from old: Tool) {
        if old == .ritaglia && tool != .ritaglia { exitCrop() }
        if tool == .ritaglia && old != .ritaglia { enterCrop() }
        if old == .tour && tool != .tour { exitTour() }
        if tool == .tour && old != .tour { enterTour() }
        if tool == .sezione { updateSection() } else if old == .sezione { clearSection() }
        if !currentPoints.isEmpty && tool != .righello && tool != .area {
            currentPoints = []
            rebuildAnnotations()
        }
    }

    // MARK: Percorso e griglia

    private func buildPath() {
        let points = keyframes.map { simd_float4x4(floatArray: $0.transform).translation }
        if points.count > 1 {
            for i in 1..<points.count {
                let seg = MeshViewerModel.cylinder(from: points[i - 1], to: points[i],
                                                   radius: CGFloat(markerSize * 0.35), color: .systemOrange)
                seg.categoryBitMask = MeshViewerModel.helperMask
                pathRoot.addChildNode(seg)
            }
        }
        for (i, kf) in keyframes.enumerated() {
            let color: UIColor = i == 0 ? .systemGreen : (i == keyframes.count - 1 ? .systemRed : .systemOrange)
            let s = MeshViewerModel.sphere(at: points[i], radius: CGFloat(markerSize * 1.6), color: color)
            s.name = "kf_\(kf.index)"
            s.categoryBitMask = MeshViewerModel.photoMask
            pathRoot.addChildNode(s)
        }
    }

    private func buildGrid() {
        let x0 = floor(minP.x)
        let x1 = ceil(maxP.x)
        let z0 = floor(minP.z)
        let z1 = ceil(maxP.z)
        let y = minP.y + 0.002
        var verts: [SCNVector3] = []
        var x = x0
        while x <= x1 {
            verts.append(SCNVector3(x, y, z0))
            verts.append(SCNVector3(x, y, z1))
            x += 1
        }
        var z = z0
        while z <= z1 {
            verts.append(SCNVector3(x0, y, z))
            verts.append(SCNVector3(x1, y, z))
            z += 1
        }
        let node = MeshViewerModel.lines(verts, color: UIColor.systemBlue.withAlphaComponent(0.5))
        node.categoryBitMask = MeshViewerModel.helperMask
        gridRoot.addChildNode(node)
    }

    // MARK: Tocchi

    func handleTap(at point: CGPoint, in view: SCNView) {
        switch tool {
        case .ritaglia:
            return
        case .naviga, .tour, .sezione:
            guard showPath else { return }
            let hits = view.hitTest(point, options: [
                SCNHitTestOption.categoryBitMask: MeshViewerModel.photoMask,
                SCNHitTestOption.searchMode: SCNHitTestSearchMode.closest.rawValue
            ])
            if let name = hits.first?.node.name, name.hasPrefix("kf_"),
               let index = Int(name.dropFirst(3)),
               let position = keyframes.firstIndex(where: { $0.index == index }) {
                tourIndex = position
                if tool == .tour { applyTourCamera() } else { tool = .tour }
            }
        case .righello, .area:
            guard let p = meshPoint(at: point, in: view) else { return }
            currentPoints.append(p)
            rebuildAnnotations()
        case .nota:
            guard let p = meshPoint(at: point, in: view) else { return }
            notePoint = p
            askNote = true
        }
    }

    private func meshPoint(at point: CGPoint, in view: SCNView) -> SIMD3<Float>? {
        let hits = view.hitTest(point, options: [
            SCNHitTestOption.categoryBitMask: MeshViewerModel.meshMask,
            SCNHitTestOption.searchMode: SCNHitTestSearchMode.closest.rawValue,
            SCNHitTestOption.ignoreHiddenNodes: true
        ])
        guard let w = hits.first?.worldCoordinates else { return nil }
        return SIMD3<Float>(Float(w.x), Float(w.y), Float(w.z))
    }

    // MARK: Misure e note

    var currentValueText: String {
        if tool == .area {
            guard currentPoints.count >= 3 else { return "Punti: \(currentPoints.count) (minimo 3)" }
            return "Area \(Fmt.m(Geo.area(currentPoints) * scale * scale)) m²"
        }
        guard currentPoints.count >= 2 else { return "Punti: \(currentPoints.count) (minimo 2)" }
        return "Totale \(Fmt.m(Geo.length(currentPoints) * scale)) m"
    }

    func valueText(_ m: SavedMeasure) -> String {
        MeshPlanExport.valueText(m, scale: scale)
    }

    func undoPoint() {
        guard !currentPoints.isEmpty else { return }
        currentPoints.removeLast()
        rebuildAnnotations()
    }

    func finishCurrent() {
        let isArea = tool == .area
        guard currentPoints.count >= (isArea ? 3 : 2) else { return }
        annotations.measures.append(SavedMeasure(id: UUID(), kind: isArea ? "area" : "linea",
                                                 points: currentPoints.map { Geo.array($0) }))
        currentPoints = []
        saveAnnotations()
        rebuildAnnotations()
    }

    func deleteMeasure(_ id: UUID) {
        annotations.measures.removeAll { $0.id == id }
        saveAnnotations()
        rebuildAnnotations()
    }

    func addNote(_ text: String) {
        guard let p = notePoint else { return }
        notePoint = nil
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        annotations.notes.append(SavedNote(id: UUID(), text: clean, point: Geo.array(p)))
        saveAnnotations()
        rebuildAnnotations()
    }

    func deleteNote(_ id: UUID) {
        annotations.notes.removeAll { $0.id == id }
        saveAnnotations()
        rebuildAnnotations()
    }

    /// Corregge tutte le misure in base a una lunghezza reale nota.
    func calibrate(realLength: Float) {
        guard let m = calibrationTarget else { return }
        calibrationTarget = nil
        let measured = Geo.length(m.vectors)
        guard measured > 0.001, realLength > 0 else { return }
        annotations.scale = realLength / measured
        saveAnnotations()
        rebuildAnnotations()
    }

    func resetScale() {
        annotations.scale = 1
        saveAnnotations()
        rebuildAnnotations()
    }

    private func rebuildAnnotations() {
        for child in annotationRoot.childNodes { child.removeFromParentNode() }
        let r = CGFloat(markerSize)

        for (n, m) in annotations.measures.enumerated() {
            let p = m.vectors
            let isArea = m.kind == "area"
            let color: UIColor = isArea ? .systemTeal : .systemYellow
            for v in p { annotationRoot.addChildNode(MeshViewerModel.sphere(at: v, radius: r, color: color)) }
            if p.count > 1 {
                for i in 1..<p.count {
                    annotationRoot.addChildNode(MeshViewerModel.cylinder(from: p[i - 1], to: p[i], radius: r * 0.4, color: color))
                }
                if isArea {
                    annotationRoot.addChildNode(MeshViewerModel.cylinder(from: p[p.count - 1], to: p[0], radius: r * 0.4, color: color))
                }
            }
            let value = isArea ? "\(Fmt.m(Geo.area(p) * scale * scale)) m²" : "\(Fmt.m(Geo.length(p) * scale)) m"
            annotationRoot.addChildNode(label("\(n + 1): \(value)", at: Geo.centroid(p)))
        }

        for (n, note) in annotations.notes.enumerated() where note.point.count == 3 {
            let p = SIMD3<Float>(note.point[0], note.point[1], note.point[2])
            annotationRoot.addChildNode(MeshViewerModel.sphere(at: p, radius: r * 1.3, color: .systemBlue))
            let short = note.text.count > 30 ? String(note.text.prefix(30)) + "…" : note.text
            annotationRoot.addChildNode(label("N\(n + 1) \(short)", at: p))
        }

        if !currentPoints.isEmpty {
            for v in currentPoints {
                annotationRoot.addChildNode(MeshViewerModel.sphere(at: v, radius: r, color: .white))
            }
            if currentPoints.count > 1 {
                for i in 1..<currentPoints.count {
                    annotationRoot.addChildNode(MeshViewerModel.cylinder(from: currentPoints[i - 1], to: currentPoints[i],
                                                                         radius: r * 0.4, color: .white))
                }
            }
        }

        annotationRoot.enumerateHierarchy { node, _ in node.categoryBitMask = MeshViewerModel.helperMask }
    }

    private func label(_ text: String, at p: SIMD3<Float>) -> SCNNode {
        let geometry = SCNText(string: text, extrusionDepth: 0)
        geometry.font = UIFont.boldSystemFont(ofSize: 1)
        geometry.flatness = 0.05
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.white
        material.lightingModel = .constant
        material.readsFromDepthBuffer = false
        geometry.materials = [material]
        let node = SCNNode(geometry: geometry)
        let (tmin, tmax) = geometry.boundingBox
        node.pivot = SCNMatrix4MakeTranslation((tmin.x + tmax.x) / 2, (tmin.y + tmax.y) / 2, 0)
        let s = markerSize * 4
        node.scale = SCNVector3(s, s, s)
        node.simdPosition = p + SIMD3<Float>(0, markerSize * 4, 0)
        node.constraints = [SCNBillboardConstraint()]
        node.renderingOrder = 100
        return node
    }

    // MARK: Salvataggio

    static func loadAnnotations(_ folder: URL) -> SavedAnnotations {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("annotazioni.json")),
              let a = try? JSONDecoder().decode(SavedAnnotations.self, from: data) else { return .empty }
        return a
    }

    private func saveAnnotations() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(annotations) {
            try? data.write(to: meshFolder.appendingPathComponent("annotazioni.json"), options: .atomic)
        }
        // Copia leggibile dentro la cartella esportata (finisce nello ZIP)
        var csv = "\u{FEFF}Tipo;N.;Valore;Punti (x y z, metri)\n"
        for (i, m) in annotations.measures.enumerated() {
            let pts = m.vectors.map { "\(Fmt.m($0.x * scale)) \(Fmt.m($0.y * scale)) \(Fmt.m($0.z * scale))" }
                .joined(separator: " | ")
            csv += "\(m.kind == "area" ? "Area" : "Misura");\(i + 1);\(valueText(m));\(pts)\n"
        }
        for (i, n) in annotations.notes.enumerated() where n.point.count == 3 {
            let text = n.text.replacingOccurrences(of: ";", with: ",")
            csv += "Nota;\(i + 1);\(text);\(Fmt.m(n.point[0])) \(Fmt.m(n.point[1])) \(Fmt.m(n.point[2]))\n"
        }
        if scale != 1 { csv += "Scala;;\(String(format: "%.4f", scale));calibrata su una misura nota\n" }
        try? csv.write(to: meshFolder.appendingPathComponent("export/misure_mesh.csv"), atomically: true, encoding: .utf8)
    }

    // MARK: Sezione orizzontale

    func updateSection() {
        clearSection()
        guard let g = geometry else { return }
        let segments = g.section(at: sectionHeight)
        sectionSegments = segments
        sectionCount = segments.count

        var verts: [SCNVector3] = []
        verts.reserveCapacity(segments.count * 2)
        for s in segments {
            verts.append(SCNVector3(s.0.x, s.0.y, s.0.z))
            verts.append(SCNVector3(s.1.x, s.1.y, s.1.z))
        }
        if !verts.isEmpty {
            sectionRoot.addChildNode(MeshViewerModel.lines(verts, color: .systemRed))
        }
        let plane = SCNPlane(width: CGFloat(maxP.x - minP.x + 1), height: CGFloat(maxP.z - minP.z + 1))
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.systemRed.withAlphaComponent(0.07)
        material.lightingModel = .constant
        material.isDoubleSided = true
        material.writesToDepthBuffer = false
        plane.materials = [material]
        let planeNode = SCNNode(geometry: plane)
        planeNode.eulerAngles.x = -Float.pi / 2
        planeNode.simdPosition = SIMD3<Float>((minP.x + maxP.x) / 2, sectionHeight, (minP.z + maxP.z) / 2)
        sectionRoot.addChildNode(planeNode)
        sectionRoot.enumerateHierarchy { node, _ in node.categoryBitMask = MeshViewerModel.helperMask }
        applyCut()
    }

    private func clearSection() {
        for child in sectionRoot.childNodes { child.removeFromParentNode() }
        applyCut()
    }

    func exportSectionDXF() {
        let s = MeshPlanExport.dxf(segments: sectionSegments, annotations: annotations, keyframes: keyframes)
        let quota = String(format: "%.2f", sectionHeight - minP.y).replacingOccurrences(of: ".", with: ",")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Sezione_quota_\(quota)m.dxf")
        do {
            try s.write(to: url, atomically: true, encoding: .ascii)
            shareItem = ShareItem(url: url)
        } catch {
            print("DXF non salvato: \(error)")
        }
    }

    // MARK: Tour lungo il percorso

    private func enterTour() {
        guard !keyframes.isEmpty else { return }
        tourIndex = min(max(tourIndex, 0), keyframes.count - 1)
        scnView?.pointOfView = tourCamera
        applyTourCamera()
    }

    private func exitTour() {
        stopPlaying()
        scnView?.pointOfView = topView ? topCamera : orbitCamera
    }

    func applyTourCamera() {
        guard keyframes.indices.contains(tourIndex), let camera = tourCamera.camera else { return }
        let kf = keyframes[tourIndex]
        let t = simd_float4x4(floatArray: kf.transform)
        let orientation = KeyframeStore.orientation(for: kf)
        var angle: Float = 0
        switch orientation {
        case .right: angle = Float.pi / 2
        case .left: angle = -Float.pi / 2
        case .down: angle = Float.pi
        default: angle = 0
        }
        tourCamera.simdTransform = t * simd_float4x4(simd_quatf(angle: angle, axis: SIMD3<Float>(0, 0, 1)))

        let rotated = orientation == .right || orientation == .left
        let w = Float(kf.width)
        let h = Float(kf.height)
        let fx = kf.intrinsics[0]
        let fy = kf.intrinsics[4]
        let dispW = rotated ? h : w
        let dispH = rotated ? w : h
        let focalX = rotated ? fy : fx
        let focalY = rotated ? fx : fy
        let viewSize = scnView?.bounds.size ?? CGSize(width: 4, height: 3)
        let viewAspect = Float(viewSize.width / max(viewSize.height, 1))
        if viewAspect >= dispW / dispH {
            camera.projectionDirection = .vertical
            camera.fieldOfView = CGFloat(2 * atan(dispH / 2 / focalY) * 180 / Float.pi)
        } else {
            camera.projectionDirection = .horizontal
            camera.fieldOfView = CGFloat(2 * atan(dispW / 2 / focalX) * 180 / Float.pi)
        }
        scnView?.pointOfView = tourCamera

        let url = meshFolder.appendingPathComponent("export").appendingPathComponent(kf.image)
        if let cg = ImageUtils.thumbnail(at: url, maxPixel: 1280) {
            tourImage = UIImage(cgImage: cg, scale: 1, orientation: orientation)
        } else {
            tourImage = nil
        }
    }

    func step(_ delta: Int) {
        guard !keyframes.isEmpty else { return }
        let next = tourIndex + delta
        if next < 0 || next >= keyframes.count {
            stopPlaying()
            return
        }
        tourIndex = next
        applyTourCamera()
    }

    func togglePlay() {
        if playing {
            stopPlaying()
        } else {
            if tourIndex >= keyframes.count - 1 { tourIndex = 0 }
            playing = true
            timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
                self?.step(1)
            }
        }
    }

    func stopPlaying() {
        timer?.invalidate()
        timer = nil
        playing = false
    }

    // MARK: Schermata

    func screenshot() {
        guard let view = scnView else { return }
        let image = view.snapshot()
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Vista_\(f.string(from: Date())).png")
        if let data = image.pngData(), (try? data.write(to: url)) != nil {
            shareItem = ShareItem(url: url)
        }
    }

    var sizeText: String {
        let d = (maxP - minP) * scale
        return "Ingombro \(Fmt.m(d.x)) × \(Fmt.m(d.z)) m, altezza \(Fmt.m(d.y)) m"
    }

    // MARK: Geometrie di supporto

    static func sphere(at p: SIMD3<Float>, radius: CGFloat, color: UIColor) -> SCNNode {
        let g = SCNSphere(radius: radius)
        let m = SCNMaterial()
        m.diffuse.contents = color
        m.lightingModel = .constant
        g.materials = [m]
        let n = SCNNode(geometry: g)
        n.simdPosition = p
        return n
    }

    static func cylinder(from a: SIMD3<Float>, to b: SIMD3<Float>, radius: CGFloat, color: UIColor) -> SCNNode {
        let length = simd_distance(a, b)
        let g = SCNCylinder(radius: radius, height: CGFloat(max(length, 0.0001)))
        let m = SCNMaterial()
        m.diffuse.contents = color
        m.lightingModel = .constant
        g.materials = [m]
        let n = SCNNode(geometry: g)
        n.simdPosition = (a + b) / 2
        if length > 0.0001 {
            let dir = (b - a) / length
            let up: SIMD3<Float> = abs(dir.y) > 0.99 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 1, 0)
            n.simdLook(at: b, up: up, localFront: SIMD3<Float>(0, 1, 0))
        }
        return n
    }

    static func lines(_ verts: [SCNVector3], color: UIColor) -> SCNNode {
        let indices = (0..<UInt32(verts.count)).map { $0 }
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: verts)],
                                   elements: [SCNGeometryElement(indices: indices, primitiveType: .line)])
        let m = SCNMaterial()
        m.diffuse.contents = color
        m.lightingModel = .constant
        m.readsFromDepthBuffer = false
        geometry.materials = [m]
        let node = SCNNode(geometry: geometry)
        node.renderingOrder = 50
        return node
    }
}

// MARK: - Vista SceneKit con tocco

struct SceneMeasureView: UIViewRepresentable {
    let model: MeshViewerModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = model.scene
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.backgroundColor = UIColor.systemGray5
        model.attach(view)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        view.addGestureRecognizer(tap)
        context.coordinator.view = view
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}

    final class Coordinator: NSObject {
        let model: MeshViewerModel
        weak var view: SCNView?

        init(model: MeshViewerModel) {
            self.model = model
        }

        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            guard let view else { return }
            model.handleTap(at: gesture.location(in: view), in: view)
        }
    }
}

// MARK: - Schermata visualizzatore

struct MeshViewerView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: MeshViewerModel
    @State private var noteText = ""
    @State private var calibrationText = ""

    init(projectFolder: URL) {
        _model = StateObject(wrappedValue: MeshViewerModel(
            meshFolder: projectFolder.appendingPathComponent("mesh", isDirectory: true)))
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.scene != nil {
                    VStack(spacing: 0) {
                        viewer
                        panel
                            .padding()
                            .background(.bar)
                    }
                } else {
                    Text("Anteprima non disponibile: esegui una nuova scansione mesh.")
                }
            }
            .navigationTitle("Mesh 3D")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Chiudi") {
                        model.stopPlaying()
                        dismiss()
                    }
                }
            }
            .sheet(item: $model.shareItem) { item in
                ShareSheet(url: item.url)
            }
            .alert("Nuova nota", isPresented: $model.askNote) {
                TextField("Testo della nota", text: $noteText)
                Button("Salva") {
                    model.addNote(noteText)
                    noteText = ""
                }
                Button("Annulla", role: .cancel) { noteText = "" }
            }
            .alert("Calibra la scala", isPresented: $model.askCalibration) {
                TextField("Lunghezza reale in metri", text: $calibrationText)
                    .keyboardType(.decimalPad)
                Button("Applica") {
                    if let v = Float(calibrationText.replacingOccurrences(of: ",", with: ".")) {
                        model.calibrate(realLength: v)
                    }
                    calibrationText = ""
                }
                Button("Annulla", role: .cancel) { calibrationText = "" }
            } message: {
                Text("Inserisci la lunghezza reale di questa misura (es. larghezza di una porta): tutte le misure verranno corrette in proporzione.")
            }
        }
    }

    // MARK: Area 3D con strumenti

    private var viewer: some View {
        ZStack {
            SceneMeasureView(model: model)

            if model.tool == .tour, model.photoOverlay, let image = model.tourImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .opacity(model.overlayOpacity)
                    .allowsHitTesting(false)
            }

            HStack(alignment: .top) {
                VStack(spacing: 6) {
                    ForEach(MeshViewerModel.Tool.allCases) { t in
                        Button {
                            model.tool = t
                        } label: {
                            VStack(spacing: 2) {
                                Image(systemName: t.icon).font(.title3)
                                Text(t.rawValue).font(.caption2)
                            }
                            .frame(width: 70, height: 52)
                            .background(model.tool == t ? Color.accentColor.opacity(0.25) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(6)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))

                Spacer()

                VStack(spacing: 10) {
                    roundButton(model.whiteMesh ? "paintpalette" : "circle.lefthalf.filled", active: model.whiteMesh) {
                        model.whiteMesh.toggle()
                    }
                    roundButton("perspective", active: model.orthographic) { model.orthographic.toggle() }
                    Menu {
                        ForEach(MeshViewerModel.ViewPreset.allCases) { v in
                            Button(v.rawValue) { model.setView(v) }
                        }
                    } label: {
                        Image(systemName: "cube")
                            .font(.title3)
                            .frame(width: 48, height: 48)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    roundButton("map", active: model.topView) { model.topView.toggle() }
                    roundButton("squareshape.split.3x3", active: model.showGrid) { model.showGrid.toggle() }
                    roundButton("point.topleft.down.to.point.bottomright.curvepath", active: model.showPath) {
                        model.showPath.toggle()
                    }
                    roundButton("camera", active: false) { model.screenshot() }
                }
            }
            .padding(10)

            VStack {
                Text(hint)
                    .font(.footnote)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 8)
                Spacer()
            }
            .allowsHitTesting(false)
        }
    }

    private func roundButton(_ icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.title3)
                .frame(width: 48, height: 48)
                .background(active ? Color.accentColor.opacity(0.3) : Color.clear)
                .background(.ultraThinMaterial, in: Circle())
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private var hint: String {
        switch model.tool {
        case .naviga: return "Un dito ruota, due dita spostano, pizzica per lo zoom. Tocca un punto del percorso per il tour."
        case .righello: return "Tocca i punti sulla mesh: la misura somma tutti i tratti"
        case .area: return "Tocca i vertici dell'area sulla mesh, poi \"Chiudi area\""
        case .nota: return "Tocca la mesh nel punto dove vuoi la nota"
        case .sezione: return "Sposta il cursore: il modello viene tagliato a quella quota"
        case .ritaglia: return "Regola la scatola con i cursori, poi tocca Applica"
        case .tour: return "Percorri la scansione dalle posizioni delle foto"
        }
    }

    // MARK: Pannello inferiore

    @ViewBuilder
    private var panel: some View {
        switch model.tool {
        case .naviga:
            VStack(alignment: .leading, spacing: 4) {
                Text(model.sizeText)
                if model.crop != nil {
                    HStack {
                        Label("Ritaglio attivo", systemImage: "crop").font(.caption).foregroundStyle(.secondary)
                        Button("Rimuovi ritaglio") { model.removeCrop() }.font(.caption)
                    }
                }
                scaleRow
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .righello, .area:
            measurePanel
        case .nota:
            notesPanel
        case .sezione:
            sectionPanel
        case .ritaglia:
            cropPanel
        case .tour:
            tourPanel
        }
    }

    @ViewBuilder
    private var scaleRow: some View {
        if model.scale != 1 {
            HStack {
                Text("Scala calibrata: \(String(format: "%.4f", model.scale))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Ripristina") { model.resetScale() }
                    .font(.caption)
            }
        }
    }

    private var measurePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(model.currentValueText).bold()
                Spacer()
                Button("Annulla punto") { model.undoPoint() }
                    .disabled(model.currentPoints.isEmpty)
                Button(model.tool == .area ? "Chiudi area" : "Salva misura") { model.finishCurrent() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.currentPoints.count < (model.tool == .area ? 3 : 2))
            }
            if !model.annotations.measures.isEmpty {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(Array(model.annotations.measures.enumerated()), id: \.element.id) { i, m in
                            HStack {
                                Text("\(i + 1).").bold()
                                Text(m.kind == "area" ? "Area" : "Misura").foregroundStyle(.secondary)
                                Text(model.valueText(m))
                                Spacer()
                                if m.kind == "linea" {
                                    Button("Calibra") {
                                        model.calibrationTarget = m
                                        calibrationText = ""
                                        model.askCalibration = true
                                    }
                                    .font(.caption)
                                }
                                Button(role: .destructive) {
                                    model.deleteMeasure(m.id)
                                } label: {
                                    Image(systemName: "trash")
                                }
                            }
                            .font(.subheadline)
                        }
                    }
                }
                .frame(maxHeight: 140)
            }
            HStack {
                Text("Precisione indicativa ±2–3 cm. Usa \"Calibra\" su una misura nota per correggere la scala.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                scaleRow
            }
        }
    }

    private var notesPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.annotations.notes.isEmpty {
                Text("Nessuna nota. Tocca la mesh per aggiungerne una.")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(Array(model.annotations.notes.enumerated()), id: \.element.id) { i, n in
                            HStack {
                                Text("N\(i + 1)").bold()
                                Text(n.text)
                                Spacer()
                                Button(role: .destructive) {
                                    model.deleteNote(n.id)
                                } label: {
                                    Image(systemName: "trash")
                                }
                            }
                            .font(.subheadline)
                        }
                    }
                }
                .frame(maxHeight: 140)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sectionPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Quota del taglio: \(Fmt.m(model.sectionHeight - model.minP.y)) m dal punto più basso").bold()
                Spacer()
                Text("\(model.sectionCount) segmenti").foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { Double(model.sectionHeight) },
                                  set: {
                                      model.sectionHeight = Float($0)
                                      model.applyCut()
                                  }),
                   in: Double(model.minP.y)...Double(model.maxP.y),
                   onEditingChanged: { editing in
                       if !editing { model.updateSection() }
                   })
            Toggle("Taglia il modello alla quota della sezione", isOn: $model.cutModel)
                .font(.subheadline)
            HStack {
                Text("Consiglio: 1,00–1,20 m per una pianta con porte e finestre.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.exportSectionDXF()
                } label: {
                    Label("Esporta pianta DXF", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.sectionCount == 0)
            }
        }
    }

    private func cropSlider(_ title: String, _ value: Binding<Float>, _ range: ClosedRange<Float>) -> some View {
        let upper = max(range.upperBound, range.lowerBound + 0.01)
        return HStack(spacing: 8) {
            Text(title).font(.caption).frame(width: 92, alignment: .leading)
            Slider(value: Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Float($0) }),
                   in: Double(range.lowerBound)...Double(upper))
            Text(Fmt.m(value.wrappedValue)).font(.caption.monospacedDigit()).frame(width: 46, alignment: .trailing)
        }
    }

    private var cropPanel: some View {
        let lo: SIMD3<Float> = model.minP - SIMD3<Float>(repeating: 1)
        let hi: SIMD3<Float> = model.maxP + SIMD3<Float>(repeating: 1)
        let ext: SIMD3<Float> = model.cropExtent * 1.5
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("Modalità", selection: $model.draftCrop.keepInside) {
                    Text("Tieni dentro (crop in)").tag(true)
                    Text("Togli dentro (crop out)").tag(false)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 380)
                Spacer()
                Button("Ripristina scatola") { model.resetDraftCrop() }
                if model.crop != nil {
                    Button("Rimuovi ritaglio", role: .destructive) { model.removeCrop() }
                }
                Button("Applica") { model.applyCrop() }
                    .buttonStyle(.borderedProminent)
            }
            if let error = model.cropError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack(alignment: .top, spacing: 20) {
                VStack(spacing: 2) {
                    cropSlider("Sposta X", $model.draftCrop.center.x, lo.x...hi.x)
                    cropSlider("Sposta Z", $model.draftCrop.center.z, lo.z...hi.z)
                    cropSlider("Sposta Y", $model.draftCrop.center.y, lo.y...hi.y)
                    cropSlider("Rotazione °", $model.draftCrop.yaw, -180...180)
                }
                VStack(spacing: 2) {
                    cropSlider("Larghezza", $model.draftCrop.size.x, 0.05...ext.x)
                    cropSlider("Profondità", $model.draftCrop.size.z, 0.05...ext.z)
                    cropSlider("Altezza", $model.draftCrop.size.y, 0.05...ext.y)
                }
            }
            Text("Il ritaglio vale anche per sezione, pianta PDF/DXF, PLY e USDZ. Si può rimuovere in ogni momento.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var tourPanel: some View {
        if model.keyframes.isEmpty {
            Text("Nessuna foto con posizione in questa scansione.")
                .foregroundStyle(.secondary)
        } else {
            VStack(spacing: 8) {
                HStack(spacing: 16) {
                    Button { model.step(-1) } label: { Image(systemName: "backward.fill") }
                    Button { model.togglePlay() } label: {
                        Image(systemName: model.playing ? "pause.fill" : "play.fill")
                    }
                    Button { model.step(1) } label: { Image(systemName: "forward.fill") }
                    Text("Foto \(model.tourIndex + 1) di \(model.keyframes.count)")
                        .monospacedDigit()
                    Spacer()
                    Toggle("Sovrapponi foto", isOn: $model.photoOverlay)
                        .fixedSize()
                }
                .font(.title3)
                Slider(value: Binding(get: { Double(model.tourIndex) },
                                      set: {
                                          model.tourIndex = Int($0.rounded())
                                          model.applyTourCamera()
                                      }),
                       in: 0...Double(max(model.keyframes.count - 1, 1)),
                       step: 1)
                if model.photoOverlay {
                    HStack {
                        Text("Trasparenza foto").font(.caption)
                        Slider(value: $model.overlayOpacity, in: 0.1...1)
                    }
                }
            }
        }
    }
}

// MARK: - Fotogrammi della scansione mesh

enum KeyframeStore {
    static func load(meshFolder: URL) -> [KeyframeRecord] {
        let url = meshFolder.appendingPathComponent("export/camere.json")
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([KeyframeRecord].self, from: data) else { return [] }
        return list
    }

    /// Orientamento per mostrare dritta una foto del sensore, in base a come era tenuto l'iPad.
    static func orientation(for kf: KeyframeRecord) -> UIImage.Orientation {
        let t = simd_float4x4(floatArray: kf.transform)
        let xUp = t.columns.0.y
        let yUp = t.columns.1.y
        if abs(xUp) > abs(yUp) {
            return xUp > 0 ? .left : .right
        }
        return yUp >= 0 ? .up : .down
    }

    static let rotations: [UIImage.Orientation] = [.up, .right, .down, .left]
}

struct KeyframeGalleryView: View {
    let meshFolder: URL
    @State private var keyframes: [KeyframeRecord] = []
    @State private var selected: KeyframeRecord?

    var body: some View {
        ScrollView {
            if keyframes.isEmpty {
                Text("Nessuna foto trovata.")
                    .foregroundStyle(.secondary)
                    .padding()
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                ForEach(Array(keyframes.enumerated()), id: \.element.index) { i, kf in
                    Button {
                        selected = kf
                    } label: {
                        ZStack(alignment: .topLeading) {
                            AsyncThumb(url: meshFolder.appendingPathComponent("export").appendingPathComponent(kf.image),
                                       orientation: KeyframeStore.orientation(for: kf))
                                .frame(height: 120)
                                .frame(maxWidth: .infinity)
                                .clipped()
                            Text("\(i + 1)")
                                .font(.caption.bold())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange, in: Capsule())
                                .padding(4)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .navigationTitle("Foto della scansione")
        .onAppear {
            if keyframes.isEmpty { keyframes = KeyframeStore.load(meshFolder: meshFolder) }
        }
        .sheet(item: $selected) { kf in
            KeyframePhotoView(meshFolder: meshFolder, keyframe: kf, total: keyframes.count)
        }
    }
}

struct AsyncThumb: View {
    let url: URL
    let orientation: UIImage.Orientation
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Color.gray.opacity(0.2)
            }
        }
        .task {
            guard image == nil else { return }
            let u = url
            let o = orientation
            let loaded = await Task.detached(priority: .utility) { () -> UIImage? in
                guard let cg = ImageUtils.thumbnail(at: u, maxPixel: 320) else { return nil }
                return UIImage(cgImage: cg, scale: 1, orientation: o)
            }.value
            image = loaded
        }
    }
}

struct KeyframePhotoView: View {
    let meshFolder: URL
    let keyframe: KeyframeRecord
    let total: Int
    @Environment(\.dismiss) private var dismiss
    @State private var cgImage: CGImage?
    @State private var orientation: UIImage.Orientation = .up
    @State private var shareItem: ShareItem?

    private var fileURL: URL {
        meshFolder.appendingPathComponent("export").appendingPathComponent(keyframe.image)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if let cgImage {
                    Image(uiImage: UIImage(cgImage: cgImage, scale: 1, orientation: orientation))
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    ProgressView()
                }
                let p = simd_float4x4(floatArray: keyframe.transform).translation
                Text("Posizione: x \(Fmt.m(p.x))  y \(Fmt.m(p.y))  z \(Fmt.m(p.z)) m")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding()
            .navigationTitle("Foto \(keyframe.index + 1) di \(total)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Chiudi") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        let list = KeyframeStore.rotations
                        let i = list.firstIndex(of: orientation) ?? 0
                        orientation = list[(i + 1) % list.count]
                    } label: {
                        Image(systemName: "rotate.right")
                    }
                    Button {
                        shareItem = ShareItem(url: fileURL)
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
            .sheet(item: $shareItem) { item in
                ShareSheet(url: item.url)
            }
            .onAppear {
                orientation = KeyframeStore.orientation(for: keyframe)
                if cgImage == nil, let img = UIImage(contentsOfFile: fileURL.path) {
                    cgImage = img.cgImage
                }
            }
        }
    }
}
