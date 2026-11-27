import Foundation
import simd
import SceneKit
import UIKit

/// Texturizza la mesh LiDAR con i fotogrammi salvati ed esporta OBJ + MTL + foto + pose camera.
enum MeshExporter {

    struct Cam {
        let index: Int
        let imageFile: String
        let worldToCam: simd_float4x4
        let position: SIMD3<Float>
        let fx: Float
        let fy: Float
        let cx: Float
        let cy: Float
        let width: Float
        let height: Float
        let depth: [Float]?
        let dw: Int
        let dh: Int

        /// Proietta un punto del mondo sull'immagine: (u, v, profondità) in pixel.
        func project(_ p: SIMD3<Float>) -> SIMD3<Float>? {
            let c = worldToCam * SIMD4<Float>(p.x, p.y, p.z, 1)
            let z = -c.z
            if z < 0.05 { return nil }
            let u = fx * c.x / z + cx
            let v = fy * (-c.y) / z + cy
            if u < 2 || v < 2 || u > width - 2 || v > height - 2 { return nil }
            return SIMD3<Float>(u, v, z)
        }

        func depthAt(u: Float, v: Float) -> Float? {
            guard let depth, dw > 0, dh > 0 else { return nil }
            let x = Int(u / width * Float(dw))
            let y = Int(v / height * Float(dh))
            guard x >= 0, y >= 0, x < dw, y < dh else { return nil }
            let d = depth[y * dw + x]
            return d > 0 ? d : nil
        }
    }

    static func export(mesh: MeshData, keyframes: [KeyframeRecord], folder: URL, fused: Bool = false,
                       progress: (Double, String) -> Void) throws -> MeshInfo {
        let exportDir = folder.appendingPathComponent("export", isDirectory: true)
        try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)

        // Classi ARKit della mesh originale (per riportarle sulla mesh finale)
        let classIndex = FaceClassIndex(mesh)
        progress(0.01, "Pulizia della mesh…")
        // La mesh di ARKit è già levigata: rifinitura leggera e solo buchi piccoli.
        // Sulla mesh di ARKit si tengono anche i pezzetti piccoli (vetri smerigliati) e i bordi.
        let refined = MeshCleanup.refine(MeshCleanup.clean(mesh, minComponentFaces: fused ? 40 : 6),
                                         smoothIterations: fused ? 8 : 2,
                                         maxHolePerimeter: fused ? 3 : 7,
                                         fringePasses: fused ? 2 : 0)
        // Pavimento sotto i mobili (dove il LiDAR non vede)
        let (withFloor, floorY) = MeshCleanup.fillFloor(refined)
        let clean = MeshCleanup.subdivideLong(withFloor, maxEdge: 0.06, passes: 3)
        let V = clean.vertices
        let I = clean.indices
        let vCount = V.count
        let fCount = I.count / 3
        guard fCount > 0 else {
            throw ExportError("Nessuna superficie rilevata. Riprova muovendoti più lentamente e inquadrando le superfici da vicino.")
        }

        // 1. Fotogrammi
        progress(0.02, "Lettura delle foto…")
        var cams: [Cam] = []
        for kf in keyframes {
            var depth: [Float]? = nil
            if let file = kf.depth, let data = try? Data(contentsOf: folder.appendingPathComponent(file)) {
                depth = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            }
            let t = simd_float4x4(floatArray: kf.transform)
            cams.append(Cam(index: kf.index, imageFile: kf.image, worldToCam: t.inverse, position: t.translation,
                            fx: kf.intrinsics[0], fy: kf.intrinsics[4], cx: kf.intrinsics[6], cy: kf.intrinsics[7],
                            width: Float(kf.width), height: Float(kf.height),
                            depth: depth, dw: kf.depthWidth, dh: kf.depthHeight))
        }

        // Nitidezza di ogni foto (le foto mosse vengono usate solo se non c'è di meglio)
        // e miniature per il bilanciamento dei colori.
        progress(0.03, "Analisi delle foto…")
        var rawSharp = [Float](repeating: 0, count: cams.count)
        var small = [RGBAPixels?](repeating: nil, count: cams.count)
        for k in 0..<cams.count {
            autoreleasepool {
                let url = exportDir.appendingPathComponent(cams[k].imageFile)
                if let img = ImageUtils.thumbnail(at: url, maxPixel: 480), let px = ImageUtils.rgbaPixels(img) {
                    rawSharp[k] = ImageUtils.sharpness(px)
                }
                if let img = ImageUtils.thumbnail(at: url, maxPixel: 256) {
                    small[k] = ImageUtils.rgbaPixels(img)
                }
            }
        }
        let sortedSharp = rawSharp.filter { $0 > 0 }.sorted()
        let medianSharp = sortedSharp.isEmpty ? 1 : max(sortedSharp[sortedSharp.count / 2], 1e-6)
        let sharp: [Float] = rawSharp.map { r in r > 0 ? min(1.2, max(0.3, (r / medianSharp).squareRoot())) : 0.6 }

        // 2. Foto candidate per ogni triangolo (le migliori K)
        let K = 6
        var candCam = [Int32](repeating: -1, count: fCount * K)
        var candScore = [Float](repeating: 0, count: fCount * K)
        let chunks = 64
        let progressLock = NSLock()
        var chunksDone = 0
        candCam.withUnsafeMutableBufferPointer { ccBuf in
        candScore.withUnsafeMutableBufferPointer { csBuf in
        let cc = ccBuf.baseAddress!
        let cs = csBuf.baseAddress!
        DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
        let lo = fCount * chunk / chunks
        let hi = fCount * (chunk + 1) / chunks
        for f in lo..<hi {
            if cams.isEmpty { break }
            let a = V[Int(I[f * 3])]
            let b = V[Int(I[f * 3 + 1])]
            let c = V[Int(I[f * 3 + 2])]
            let cr = simd_cross(b - a, c - a)
            let len = simd_length(cr)
            if len < 1e-10 { continue }
            let n = cr / len
            let centroid = (a + b + c) / 3
            for k in 0..<cams.count {
                let cam = cams[k]
                let toCam = cam.position - centroid
                let dist = simd_length(toCam)
                if dist > 5 || dist < 0.1 { continue }
                let facing = abs(simd_dot(n, toCam / dist))
                if facing < 0.1 { continue }
                guard let pa = cam.project(a), let pb = cam.project(b), let pc = cam.project(c),
                      let pm = cam.project(centroid) else { continue }
                if let d = cam.depthAt(u: pm.x, v: pm.y), pm.z - d > 0.08 { continue } // nascosto da altro
                // Preferisce foto vicine, frontali e con il triangolo lontano dai bordi dell'immagine
                let ux = min(pm.x, cam.width - pm.x) / (cam.width * 0.5)
                let uy = min(pm.y, cam.height - pm.y) / (cam.height * 0.5)
                let border = 0.6 + 0.4 * min(1, min(ux, uy) * 3)
                _ = pa; _ = pb; _ = pc
                // Le viste molto di sbieco valgono poco, ma evitano i bordi senza colore (sedie, scrivania)
                let grazing: Float = facing < 0.3 ? 0.15 : 1
                let score = facing * facing / (dist * dist) * border * sharp[k] * grazing
                // Inserimento ordinato tra le K migliori
                var slot = -1
                for j in 0..<K where score > cs[f * K + j] {
                    slot = j
                    break
                }
                if slot < 0 { continue }
                var j = K - 1
                while j > slot {
                    cc[f * K + j] = cc[f * K + j - 1]
                    cs[f * K + j] = cs[f * K + j - 1]
                    j -= 1
                }
                cc[f * K + slot] = Int32(k)
                cs[f * K + slot] = score
            }
        }
        progressLock.lock()
        chunksDone += 1
        let done = chunksDone
        progressLock.unlock()
        if done % 4 == 0 {
            progress(0.05 + 0.4 * Double(done) / Double(chunks), "Associazione delle foto alla mesh…")
        }
        }
        }
        }

        // 3. Scelta coerente tra triangoli vicini (meno cuciture tra una foto e l'altra)
        progress(0.46, "Uniformità delle texture…")
        var faceCam = [Int32](repeating: -1, count: fCount)
        for f in 0..<fCount { faceCam[f] = candCam[f * K] }
        let neighbors = MeshCleanup.faceNeighbors(I)
        for _ in 0..<16 {
            var next = faceCam
            for f in 0..<fCount where candCam[f * K] >= 0 {
                let best = candScore[f * K]
                var chosen = faceCam[f]
                var chosenValue: Float = -1
                for j in 0..<K {
                    let cam = candCam[f * K + j]
                    if cam < 0 { break }
                    var same: Float = 0
                    for e in 0..<3 {
                        let g = neighbors[f * 3 + e]
                        if g >= 0 && faceCam[Int(g)] == cam { same += 1 }
                    }
                    let value = candScore[f * K + j] / best + 1.5 * same
                    if value > chosenValue {
                        chosenValue = value
                        chosen = cam
                    }
                }
                next[f] = chosen
            }
            faceCam = next
        }

        var faceUV = [SIMD2<Float>](repeating: SIMD2<Float>(0, 0), count: fCount * 3)
        for f in 0..<fCount where faceCam[f] >= 0 {
            let cam = cams[Int(faceCam[f])]
            for j in 0..<3 {
                if let p = cam.project(V[Int(I[f * 3 + j])]) {
                    faceUV[f * 3 + j] = SIMD2<Float>(p.x, p.y)
                } else {
                    faceCam[f] = -1
                }
            }
        }

        // Bilanciamento dell'esposizione: ogni foto viene corretta per avvicinarsi alla media
        // delle altre foto che riprendono gli stessi punti (niente chiazze di tono diverso).
        progress(0.47, "Bilanciamento dei colori tra le foto…")
        var gains = [SIMD3<Float>](repeating: SIMD3<Float>(1, 1, 1), count: cams.count)
        if cams.count > 1 {
            var ks = [Int](repeating: 0, count: K)
            var cols = [SIMD3<Float>](repeating: SIMD3<Float>(0, 0, 0), count: K)
            for _ in 0..<3 {
                var sumRef = [SIMD3<Float>](repeating: SIMD3<Float>(0, 0, 0), count: cams.count)
                var sumOwn = [SIMD3<Float>](repeating: SIMD3<Float>(0, 0, 0), count: cams.count)
                var f = 0
                while f < fCount {
                    defer { f += 2 }
                    let centroid = (V[Int(I[f * 3])] + V[Int(I[f * 3 + 1])] + V[Int(I[f * 3 + 2])]) / 3
                    var m = 0
                    for j in 0..<K {
                        let k = Int(candCam[f * K + j])
                        if k < 0 { break }
                        guard let px = small[k], let q = cams[k].project(centroid) else { continue }
                        let x = min(px.width - 1, max(0, Int(q.x * Float(px.width) / cams[k].width)))
                        let y = min(px.height - 1, max(0, Int(q.y * Float(px.height) / cams[k].height)))
                        let o = (y * px.width + x) * 4
                        let c = SIMD3<Float>(Float(px.data[o]), Float(px.data[o + 1]), Float(px.data[o + 2])) / 255
                        let lum = (c.x + c.y + c.z) / 3
                        if lum < 0.04 || lum > 0.96 { continue }
                        ks[m] = k
                        cols[m] = c
                        m += 1
                    }
                    if m < 2 { continue }
                    var ref = SIMD3<Float>(0, 0, 0)
                    for i in 0..<m { ref += cols[i] * gains[ks[i]] }
                    ref /= Float(m)
                    for i in 0..<m {
                        sumRef[ks[i]] += ref
                        sumOwn[ks[i]] += cols[i]
                    }
                }
                var mean = SIMD3<Float>(0, 0, 0)
                var counted: Float = 0
                for k in 0..<cams.count where sumOwn[k].x > 1 && sumOwn[k].y > 1 && sumOwn[k].z > 1 {
                    let g = sumRef[k] / sumOwn[k]
                    gains[k] = simd_clamp(g, SIMD3<Float>(repeating: 0.6), SIMD3<Float>(repeating: 1.6))
                    mean += gains[k]
                    counted += 1
                }
                if counted > 0 {
                    mean /= counted
                    for k in 0..<cams.count { gains[k] /= mean }
                }
            }
        }

        var groups = [[Int]](repeating: [], count: cams.count)
        var untextured: [Int] = []
        for f in 0..<fCount {
            let k = Int(faceCam[f])
            if k >= 0 { groups[k].append(f) } else { untextured.append(f) }
        }

        // 4. Colori per vertice (per il PLY e i programmi che non leggono le texture)
        progress(0.5, "Colorazione della mesh…")
        var colorSum = [SIMD3<Float>](repeating: SIMD3<Float>(0, 0, 0), count: vCount)
        var colorCount = [Float](repeating: 0, count: vCount)
        for k in 0..<cams.count where !groups[k].isEmpty {
            if k % 5 == 0 {
                progress(0.5 + 0.15 * Double(k) / Double(max(cams.count, 1)), "Colorazione della mesh…")
            }
            let cam = cams[k]
            let url = exportDir.appendingPathComponent(cam.imageFile)
            guard let img = ImageUtils.thumbnail(at: url, maxPixel: 640),
                  let px = ImageUtils.rgbaPixels(img) else { continue }
            let sx = Float(px.width) / cam.width
            let sy = Float(px.height) / cam.height
            for f in groups[k] {
                for j in 0..<3 {
                    let uv = faceUV[f * 3 + j]
                    let x = min(px.width - 1, max(0, Int(uv.x * sx)))
                    let y = min(px.height - 1, max(0, Int(uv.y * sy)))
                    let o = (y * px.width + x) * 4
                    let raw = SIMD3<Float>(Float(px.data[o]), Float(px.data[o + 1]), Float(px.data[o + 2])) / 255
                    let col = simd_min(raw * gains[k], SIMD3<Float>(repeating: 1))
                    let vi = Int(I[f * 3 + j])
                    colorSum[vi] += col
                    colorCount[vi] += 1
                }
            }
        }
        var colors = [SIMD3<Float>](repeating: SIMD3<Float>(0.7, 0.7, 0.7), count: vCount)
        for i in 0..<vCount where colorCount[i] > 0 {
            colors[i] = colorSum[i] / colorCount[i]
        }

        // 5. Atlante delle texture (ritagli delle foto impacchettati in poche immagini)
        progress(0.66, "Creazione delle texture…")
        // Colore per le zone che nessuna foto vede (pavimento sotto i mobili): media del pavimento visto
        var fillColor = SIMD3<Float>(0.7, 0.7, 0.7)
        if let fy = floorY {
            var sum = SIMD3<Float>(0, 0, 0)
            var n: Float = 0
            for i in 0..<vCount where colorCount[i] > 0 && abs(V[i].y - fy) < 0.03 {
                sum += colors[i]
                n += 1
            }
            if n > 50 { fillColor = sum / n }
        }

        // Per la fusione tra foto si usa solo il tono molto sfumato (niente dettagli "fantasma")
        let toneImages: [RGBAPixels?] = small.map { $0.map { ImageUtils.boxBlur($0, radius: 3) } }
        let atlas = try TextureAtlas.build(faceCam: faceCam, faceUV: faceUV, indices: I, cams: cams,
                                           gains: gains, vertices: V, candCam: candCam, K: K, small: toneImages, fillColor: fillColor,
                                           exportDir: exportDir) { p in
            progress(0.66 + 0.16 * p, "Creazione delle texture…")
        }

        // Mesh con texture per il visualizzatore dell'app
        var tPositions: [SIMD3<Float>] = []
        tPositions.reserveCapacity(fCount * 3)
        for i in I { tPositions.append(V[Int(i)]) }
        try TexturedMesh(positions: tPositions, uvs: atlas.uv, pages: atlas.page, pageCount: atlas.pages)
            .save(to: folder.appendingPathComponent(TexturedMesh.fileName))

        // 6. OBJ + MTL
        progress(0.83, "Scrittura del file OBJ…")
        let writer = try TextWriter(url: exportDir.appendingPathComponent("modello.obj"))
        writer.write("# Rilievo LiDAR - mesh texturizzata\n# Unita: metri, asse Y verso l'alto\nmtllib modello.mtl\n")
        for i in 0..<vCount {
            let p = V[i]
            let c = colors[i]
            writer.write(String(format: "v %.4f %.4f %.4f %.3f %.3f %.3f\n", p.x, p.y, p.z, c.x, c.y, c.z))
        }
        for f in 0..<fCount {
            for j in 0..<3 {
                let uv = atlas.uv[f * 3 + j]
                writer.write(String(format: "vt %.6f %.6f\n", uv.x, 1 - uv.y))
            }
        }
        var mtl = "# Materiali: atlanti di texture ricavati dalle foto\n"
        for p in 0..<atlas.pages {
            mtl += "newmtl texture_\(p)\nKa 1 1 1\nKd 1 1 1\nKs 0 0 0\nd 1\nillum 1\nmap_Kd texture_\(p).jpg\n\n"
            writer.write("usemtl texture_\(p)\n")
            for f in 0..<fCount where Int(atlas.page[f]) == p {
                let vt = f * 3 + 1
                writer.write("f \(Int(I[f * 3]) + 1)/\(vt) \(Int(I[f * 3 + 1]) + 1)/\(vt + 1) \(Int(I[f * 3 + 2]) + 1)/\(vt + 2)\n")
            }
        }
        writer.close()
        try mtl.write(to: exportDir.appendingPathComponent("modello.mtl"), atomically: true, encoding: .utf8)

        // 5. Pose delle camere per la fotogrammetria
        progress(0.9, "Salvataggio delle posizioni delle foto…")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        try encoder.encode(keyframes).write(to: exportDir.appendingPathComponent("camere.json"))

        var csv = "foto;x;y;z;qx;qy;qz;qw;fx;fy;cx;cy;larghezza;altezza\n"
        for kf in keyframes {
            let t = simd_float4x4(floatArray: kf.transform)
            let rot = simd_float3x3(columns: (SIMD3<Float>(t.columns.0.x, t.columns.0.y, t.columns.0.z),
                                              SIMD3<Float>(t.columns.1.x, t.columns.1.y, t.columns.1.z),
                                              SIMD3<Float>(t.columns.2.x, t.columns.2.y, t.columns.2.z)))
            let q = simd_quatf(rot)
            let p = t.translation
            let values: [Float] = [p.x, p.y, p.z, q.imag.x, q.imag.y, q.imag.z, q.real,
                                   kf.intrinsics[0], kf.intrinsics[4], kf.intrinsics[6], kf.intrinsics[7]]
            let fields = values.map { String(format: "%.6f", $0) }.joined(separator: ";")
            csv += "\(kf.image);\(fields);\(kf.width);\(kf.height)\n"
        }
        try csv.write(to: exportDir.appendingPathComponent("camere.csv"), atomically: true, encoding: .utf8)
        // Percorso dell'operatore come polilinea
        if keyframes.count > 1 {
            var path = "# Percorso dell'operatore durante la scansione (posizioni delle foto)\n"
            for kf in keyframes {
                let p = simd_float4x4(floatArray: kf.transform).translation
                path += String(format: "v %.4f %.4f %.4f\n", p.x, p.y, p.z)
            }
            path += "l " + (1...keyframes.count).map { String($0) }.joined(separator: " ") + "\n"
            try path.write(to: exportDir.appendingPathComponent("percorso.obj"), atomically: true, encoding: .utf8)
        }
        try readme.write(to: exportDir.appendingPathComponent("LEGGIMI.txt"), atomically: true, encoding: .utf8)

        // 6. Anteprima per l'app
        progress(0.96, "Preparazione dell'anteprima 3D…")
        MeshClass.save(classIndex?.classify(vertices: V, indices: I, floorY: floorY) ?? [], meshFolder: folder)
        writePreview(vertices: V, indices: I, colors: colors,
                     to: folder.appendingPathComponent("preview.scn"))

        progress(1, "Completato")
        var info = MeshInfo(date: Date(), keyframes: keyframes.count, faces: fCount,
                            texturedFaces: fCount - untextured.count)
        info.textureScale = atlas.scale
        return info
    }

    static func writePreview(vertices: [SIMD3<Float>], indices: [UInt32], colors: [SIMD3<Float>], to url: URL) {
        let scnVertices = vertices.map { SCNVector3($0.x, $0.y, $0.z) }
        var flat = [Float]()
        flat.reserveCapacity(colors.count * 3)
        for c in colors {
            flat.append(c.x)
            flat.append(c.y)
            flat.append(c.z)
        }
        let colorData = flat.withUnsafeBufferPointer { Data(buffer: $0) }
        let vertexSource = SCNGeometrySource(vertices: scnVertices)
        let colorSource = SCNGeometrySource(data: colorData, semantic: .color, vectorCount: colors.count,
                                            usesFloatComponents: true, componentsPerVector: 3,
                                            bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0,
                                            dataStride: MemoryLayout<Float>.size * 3)
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        let geometry = SCNGeometry(sources: [vertexSource, colorSource], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.isDoubleSided = true
        material.diffuse.contents = UIColor.white
        geometry.materials = [material]

        let scene = SCNScene()
        scene.rootNode.addChildNode(SCNNode(geometry: geometry))

        var minP = SIMD3<Float>(repeating: Float.greatestFiniteMagnitude)
        var maxP = SIMD3<Float>(repeating: -Float.greatestFiniteMagnitude)
        for v in vertices {
            minP = simd_min(minP, v)
            maxP = simd_max(maxP, v)
        }
        let center = (minP + maxP) / 2
        let size = max(simd_length(maxP - minP), 1)
        let camera = SCNCamera()
        camera.zNear = 0.01
        camera.zFar = Double(size * 10)
        let cameraNode = SCNNode()
        cameraNode.name = "camera"
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(center.x, center.y + size * 0.6, center.z + size * 0.8)
        cameraNode.look(at: SCNVector3(center.x, center.y, center.z))
        scene.rootNode.addChildNode(cameraNode)

        _ = scene.write(to: url, options: nil, delegate: nil, progressHandler: nil)
    }

    static let readme = """
    RILIEVO LIDAR - MESH CON FOTO
    =============================

    modello.obj / modello.mtl
      Mesh LiDAR in metri, asse Y verso l'alto, con texture ricavate dalle foto
      (texture_0.jpg, texture_1.jpg...). I vertici contengono anche il colore
      (utile in CloudCompare e MeshLab).
      Blender: File > Import > Wavefront (.obj), poi vista "Material Preview".

    foto/
      Fotogrammi a piena risoluzione scattati durante la scansione.
      Si possono usare per la fotogrammetria (Metashape, RealityScan, Meshroom).

    percorso.obj
      Percorso fatto durante la scansione (linea che unisce le posizioni delle
      foto, nello stesso sistema di riferimento della mesh). Si importa insieme
      a modello.obj in Blender o CloudCompare.

    misure_mesh.csv
      Misure, aree e note fatte nel visualizzatore dell'app (se presenti).

    camere.json / camere.csv
      Posizione e orientamento di ogni foto nello stesso sistema di riferimento
      della mesh (metri). Convenzione ARKit: camera con X a destra, Y in alto,
      Z all'indietro (guarda verso -Z). Le foto sono nell'orientamento del sensore
      (orizzontale). Quaternione qx qy qz qw = rotazione camera -> mondo.
      fx fy cx cy = parametri interni in pixel.
    """
}

/// Scrittura bufferizzata di file di testo grandi.
final class TextWriter {
    private let handle: FileHandle
    private var buffer = ""
    private var pending = 0

    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
    }

    func write(_ s: String) {
        buffer += s
        pending += s.utf8.count
        if pending > 1_000_000 { flush() }
    }

    func flush() {
        if !buffer.isEmpty, let data = buffer.data(using: .utf8) {
            handle.write(data)
        }
        buffer = ""
        pending = 0
    }

    func close() {
        flush()
        try? handle.close()
    }
}
