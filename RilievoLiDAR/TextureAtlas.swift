import Foundation
import UIKit
import SceneKit
import ImageIO
import UniformTypeIdentifiers
import CoreImage
import simd

// MARK: - Pulizia della mesh

enum MeshCleanup {
    /// Unisce i vertici coincidenti tra i blocchi di ARKit, toglie triangoli degeneri e frammenti volanti.
    static func clean(_ mesh: MeshData, weldTolerance: Float = 0.001, minComponentFaces: Int = 40) -> MeshData {
        var map = [SIMD3<Int32>: UInt32]()
        map.reserveCapacity(mesh.vertices.count)
        var remap = [UInt32](repeating: 0, count: mesh.vertices.count)
        var vertices: [SIMD3<Float>] = []
        vertices.reserveCapacity(mesh.vertices.count)
        for (i, v) in mesh.vertices.enumerated() {
            let q = SIMD3<Int32>(Int32((v.x / weldTolerance).rounded()),
                                 Int32((v.y / weldTolerance).rounded()),
                                 Int32((v.z / weldTolerance).rounded()))
            if let existing = map[q] {
                remap[i] = existing
            } else {
                let n = UInt32(vertices.count)
                map[q] = n
                remap[i] = n
                vertices.append(v)
            }
        }

        var faces: [UInt32] = []
        faces.reserveCapacity(mesh.indices.count)
        var t = 0
        while t + 2 < mesh.indices.count {
            let a = remap[Int(mesh.indices[t])]
            let b = remap[Int(mesh.indices[t + 1])]
            let c = remap[Int(mesh.indices[t + 2])]
            t += 3
            if a == b || b == c || a == c { continue }
            let area = simd_length(simd_cross(vertices[Int(b)] - vertices[Int(a)], vertices[Int(c)] - vertices[Int(a)]))
            if area < 1e-9 { continue }
            faces.append(a)
            faces.append(b)
            faces.append(c)
        }

        // Componenti connesse: si scartano i frammenti piccoli (rumore, riflessi, vetri).
        var parent = [Int32](0..<Int32(vertices.count))
        func find(_ x: Int32) -> Int32 {
            var r = x
            while parent[Int(r)] != r { r = parent[Int(r)] }
            var y = x
            while parent[Int(y)] != r {
                let next = parent[Int(y)]
                parent[Int(y)] = r
                y = next
            }
            return r
        }
        func union(_ a: Int32, _ b: Int32) {
            let ra = find(a)
            let rb = find(b)
            if ra != rb { parent[Int(ra)] = rb }
        }
        var f = 0
        while f + 2 < faces.count {
            union(Int32(faces[f]), Int32(faces[f + 1]))
            union(Int32(faces[f]), Int32(faces[f + 2]))
            f += 3
        }
        var count = [Int32: Int]()
        f = 0
        while f + 2 < faces.count {
            count[find(Int32(faces[f])), default: 0] += 1
            f += 3
        }
        var kept: [UInt32] = []
        kept.reserveCapacity(faces.count)
        f = 0
        while f + 2 < faces.count {
            if (count[find(Int32(faces[f]))] ?? 0) >= minComponentFaces {
                kept.append(faces[f])
                kept.append(faces[f + 1])
                kept.append(faces[f + 2])
            }
            f += 3
        }
        if kept.count < faces.count / 2 { kept = faces } // sicurezza: non svuotare la mesh

        // Compatta i vertici usati
        var used = [Int32](repeating: -1, count: vertices.count)
        var outV: [SIMD3<Float>] = []
        var outI: [UInt32] = []
        outI.reserveCapacity(kept.count)
        for i in kept {
            if used[Int(i)] < 0 {
                used[Int(i)] = Int32(outV.count)
                outV.append(vertices[Int(i)])
            }
            outI.append(UInt32(used[Int(i)]))
        }
        return MeshData(vertices: outV, indices: outI)
    }

    /// Per ogni triangolo, i (fino a 3) triangoli che condividono un lato; -1 se assente.
    static func faceNeighbors(_ indices: [UInt32]) -> [Int32] {
        let fCount = indices.count / 3
        var neighbors = [Int32](repeating: -1, count: fCount * 3)
        var edges = [UInt64: Int32]()
        edges.reserveCapacity(fCount * 2)
        func addNeighbor(_ f: Int, _ g: Int32) {
            for k in 0..<3 where neighbors[f * 3 + k] < 0 {
                neighbors[f * 3 + k] = g
                return
            }
        }
        for f in 0..<fCount {
            for k in 0..<3 {
                let a = indices[f * 3 + k]
                let b = indices[f * 3 + (k + 1) % 3]
                let key = (UInt64(min(a, b)) << 32) | UInt64(max(a, b))
                if let other = edges[key] {
                    addNeighbor(f, other)
                    addNeighbor(Int(other), Int32(f))
                } else {
                    edges[key] = Int32(f)
                }
            }
        }
        return neighbors
    }
}

// MARK: - Atlante delle texture

enum TextureAtlas {
    static let pageSize = 4096
    static let maxPages = 3
    static let pad: CGFloat = 4

    struct Result {
        var pages: Int
        var uv: [SIMD2<Float>]   // per angolo di triangolo, origine in alto a sinistra (0…1)
        var page: [UInt8]        // per triangolo
    }

    private struct Chart {
        var cam: Int
        var rect: CGRect          // pixel dell'immagine a piena risoluzione (origine in alto a sinistra)
        var faces: [Int]
        var page = 0
        var x: CGFloat = 0
        var y: CGFloat = 0
    }

    /// Ritaglia dalle foto solo le zone usate e le impacchetta in poche immagini grandi.
    static func build(faceCam: [Int32], faceUV: [SIMD2<Float>], indices: [UInt32],
                      cams: [MeshExporter.Cam], gains: [SIMD3<Float>], exportDir: URL,
                      progress: (Double) -> Void) throws -> Result {
        let fCount = faceCam.count
        var groups = [[Int]](repeating: [], count: cams.count)
        for f in 0..<fCount where faceCam[f] >= 0 { groups[Int(faceCam[f])].append(f) }

        // 1. Isole di triangoli contigui per ogni foto, unite se si sovrappongono
        var charts: [Chart] = []
        for k in 0..<cams.count where !groups[k].isEmpty {
            var local = [UInt32: Int32]()
            var parent: [Int32] = []
            func id(_ v: UInt32) -> Int32 {
                if let i = local[v] { return i }
                let i = Int32(parent.count)
                parent.append(i)
                local[v] = i
                return i
            }
            func find(_ x: Int32) -> Int32 {
                var r = x
                while parent[Int(r)] != r { r = parent[Int(r)] }
                return r
            }
            for f in groups[k] {
                let a = id(indices[f * 3])
                let b = id(indices[f * 3 + 1])
                let c = id(indices[f * 3 + 2])
                let ra = find(a)
                let rb = find(b)
                if ra != rb { parent[Int(ra)] = rb }
                let rc = find(c)
                let rb2 = find(b)
                if rc != rb2 { parent[Int(rc)] = rb2 }
            }
            var byRoot = [Int32: Int]()
            var local_charts: [Chart] = []
            for f in groups[k] {
                let root = find(local[indices[f * 3]]!)
                var minP = faceUV[f * 3]
                var maxP = minP
                for j in 1..<3 {
                    minP = simd_min(minP, faceUV[f * 3 + j])
                    maxP = simd_max(maxP, faceUV[f * 3 + j])
                }
                let r = CGRect(x: CGFloat(minP.x), y: CGFloat(minP.y),
                               width: CGFloat(maxP.x - minP.x), height: CGFloat(maxP.y - minP.y))
                if let i = byRoot[root] {
                    local_charts[i].rect = local_charts[i].rect.union(r)
                    local_charts[i].faces.append(f)
                } else {
                    byRoot[root] = local_charts.count
                    local_charts.append(Chart(cam: k, rect: r, faces: [f]))
                }
            }
            // Unisce i rettangoli vicini o sovrapposti della stessa foto
            var merged = true
            while merged {
                merged = false
                var i = 0
                while i < local_charts.count {
                    var j = i + 1
                    while j < local_charts.count {
                        if local_charts[i].rect.insetBy(dx: -12, dy: -12).intersects(local_charts[j].rect) {
                            local_charts[i].rect = local_charts[i].rect.union(local_charts[j].rect)
                            local_charts[i].faces += local_charts[j].faces
                            local_charts.remove(at: j)
                            merged = true
                        } else {
                            j += 1
                        }
                    }
                    i += 1
                }
            }
            charts += local_charts
        }

        // 2. Scala e impacchettamento a ripiani
        let P = CGFloat(pageSize)
        let maxSide = charts.map { max($0.rect.width, $0.rect.height) }.max() ?? 1
        var s: CGFloat = min(1, (P - 4 * pad - 16) / max(maxSide, 1))
        var pagesUsed = 1
        while true {
            pagesUsed = 1
            var x: CGFloat = 16 + pad   // in alto a sinistra: blocco grigio 16x16 per i triangoli senza foto
            var y: CGFloat = 0
            var shelf: CGFloat = 16
            var ok = true
            let order = charts.indices.sorted { charts[$0].rect.height > charts[$1].rect.height }
            for i in order {
                let w = ceil(charts[i].rect.width * s) + 2 * pad
                let h = ceil(charts[i].rect.height * s) + 2 * pad
                if x + w > P {
                    x = 0
                    y += shelf
                    shelf = 0
                }
                if y + h > P {
                    pagesUsed += 1
                    x = 0
                    y = 0
                    shelf = 0
                    if pagesUsed > maxPages { ok = false; break }
                }
                charts[i].page = pagesUsed - 1
                charts[i].x = x + pad
                charts[i].y = y + pad
                x += w
                shelf = max(shelf, h)
            }
            if ok { break }
            s *= 0.85
        }

        // 3. Coordinate texture
        var uv = [SIMD2<Float>](repeating: SIMD2<Float>(Float(8 / P), Float(8 / P)), count: fCount * 3)
        var page = [UInt8](repeating: 0, count: fCount)
        for c in charts {
            for f in c.faces {
                page[f] = UInt8(c.page)
                for j in 0..<3 {
                    let p = faceUV[f * 3 + j]
                    let ax = c.x + (CGFloat(p.x) - c.rect.minX) * s
                    let ay = c.y + (CGFloat(p.y) - c.rect.minY) * s
                    uv[f * 3 + j] = SIMD2<Float>(Float(ax / P), Float(ay / P))
                }
            }
        }

        // 4. Disegno delle pagine
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        for p in 0..<pagesUsed {
            progress(Double(p) / Double(pagesUsed))
            guard let ctx = CGContext(data: nil, width: pageSize, height: pageSize, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
                throw ExportError("Memoria insufficiente per la texture.")
            }
            ctx.setFillColor(UIColor(white: 0.7, alpha: 1).cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: P, height: P))
            ctx.interpolationQuality = .high
            let onPage = charts.filter { $0.page == p }
            let camsOnPage = Set(onPage.map { $0.cam })
            for k in camsOnPage.sorted() {
                autoreleasepool {
                    let cam = cams[k]
                    let url = exportDir.appendingPathComponent(cam.imageFile)
                    let maxPixel = Int((CGFloat(max(cam.width, cam.height)) * s).rounded(.up))
                    guard let original = ImageUtils.thumbnail(at: url, maxPixel: maxPixel) else { return }
                    let img = ImageUtils.applyGain(original, k < gains.count ? gains[k] : SIMD3<Float>(1, 1, 1))
                    let sx = CGFloat(img.width) / CGFloat(cam.width)
                    let sy = CGFloat(img.height) / CGFloat(cam.height)
                    for c in onPage where c.cam == k {
                        let padFull = pad / s
                        let src = c.rect.insetBy(dx: -padFull, dy: -padFull)
                        let srcPx = CGRect(x: src.minX * sx, y: src.minY * sy,
                                           width: src.width * sx, height: src.height * sy).integral
                            .intersection(CGRect(x: 0, y: 0, width: img.width, height: img.height))
                        guard !srcPx.isEmpty, let crop = img.cropping(to: srcPx) else { continue }
                        // Destinazione in pixel dell'atlante (origine in alto a sinistra)
                        let dx = c.x + (srcPx.minX / sx - c.rect.minX) * s
                        let dy = c.y + (srcPx.minY / sy - c.rect.minY) * s
                        let dw = srcPx.width / sx * s
                        let dh = srcPx.height / sy * s
                        ctx.draw(crop, in: CGRect(x: dx, y: P - dy - dh, width: dw, height: dh))
                    }
                }
            }
            guard let image = ctx.makeImage() else { throw ExportError("Texture non creata.") }
            let url = exportDir.appendingPathComponent("texture_\(p).jpg")
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
                throw ExportError("Texture non salvata.")
            }
            CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
            CGImageDestinationFinalize(dest)
        }
        // Rimuove pagine di scansioni precedenti
        for p in pagesUsed..<(maxPages + 2) {
            try? FileManager.default.removeItem(at: exportDir.appendingPathComponent("texture_\(p).jpg"))
        }
        return Result(pages: pagesUsed, uv: uv, page: page)
    }
}

// MARK: - Mesh con texture per il visualizzatore

struct TexturedMesh {
    var positions: [SIMD3<Float>]   // 3 per triangolo
    var uvs: [SIMD2<Float>]         // 3 per triangolo
    var pages: [UInt8]              // 1 per triangolo
    var pageCount: Int

    static let fileName = "textured.bin"
    private static let magic: UInt32 = 0x5254_4D31

    var faceCount: Int { pages.count }

    func save(to url: URL) throws {
        var data = Data()
        func put(_ v: UInt32) {
            var x = v.littleEndian
            withUnsafeBytes(of: &x) { data.append(contentsOf: $0) }
        }
        put(TexturedMesh.magic)
        put(UInt32(faceCount))
        put(UInt32(pageCount))
        put(0)
        data.append(contentsOf: pages)
        var flat = [Float]()
        flat.reserveCapacity(positions.count * 3 + uvs.count * 2)
        for p in positions {
            flat.append(p.x)
            flat.append(p.y)
            flat.append(p.z)
        }
        for t in uvs {
            flat.append(t.x)
            flat.append(t.y)
        }
        flat.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
        try data.write(to: url)
    }

    static func load(meshFolder: URL) -> TexturedMesh? {
        guard let data = try? Data(contentsOf: meshFolder.appendingPathComponent(fileName)), data.count >= 16 else {
            return nil
        }
        return data.withUnsafeBytes { raw -> TexturedMesh? in
            guard raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self) == magic else { return nil }
            let n = Int(raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
            let pageCount = Int(raw.loadUnaligned(fromByteOffset: 8, as: UInt32.self))
            let floatsStart = 16 + n
            guard data.count >= floatsStart + n * 15 * 4 else { return nil }
            let pages = [UInt8](raw[16..<(16 + n)])
            var positions = [SIMD3<Float>]()
            positions.reserveCapacity(n * 3)
            var o = floatsStart
            for _ in 0..<(n * 3) {
                positions.append(SIMD3<Float>(raw.loadUnaligned(fromByteOffset: o, as: Float.self),
                                              raw.loadUnaligned(fromByteOffset: o + 4, as: Float.self),
                                              raw.loadUnaligned(fromByteOffset: o + 8, as: Float.self)))
                o += 12
            }
            var uvs = [SIMD2<Float>]()
            uvs.reserveCapacity(n * 3)
            for _ in 0..<(n * 3) {
                uvs.append(SIMD2<Float>(raw.loadUnaligned(fromByteOffset: o, as: Float.self),
                                        raw.loadUnaligned(fromByteOffset: o + 4, as: Float.self)))
                o += 8
            }
            return TexturedMesh(positions: positions, uvs: uvs, pages: pages, pageCount: pageCount)
        }
    }

    static func loadPages(meshFolder: URL, count: Int) -> [UIImage] {
        (0..<count).compactMap {
            UIImage(contentsOfFile: meshFolder.appendingPathComponent("export/texture_\($0).jpg").path)
        }
    }

    func cropped(_ box: CropBox) -> TexturedMesh {
        var out = TexturedMesh(positions: [], uvs: [], pages: [], pageCount: pageCount)
        for f in 0..<faceCount {
            let centroid = (positions[f * 3] + positions[f * 3 + 1] + positions[f * 3 + 2]) / 3
            if box.contains(centroid) != box.keepInside { continue }
            out.pages.append(pages[f])
            for j in 0..<3 {
                out.positions.append(positions[f * 3 + j])
                out.uvs.append(uvs[f * 3 + j])
            }
        }
        return out
    }

    func scnGeometry(images: [UIImage]) -> SCNGeometry? {
        guard faceCount > 0, !images.isEmpty else { return nil }
        let vs = SCNGeometrySource(vertices: positions.map { SCNVector3($0.x, $0.y, $0.z) })
        let ts = SCNGeometrySource(textureCoordinates: uvs.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) })
        var elements: [SCNGeometryElement] = []
        var materials: [SCNMaterial] = []
        for p in 0..<min(pageCount, images.count) {
            var idx: [UInt32] = []
            for f in 0..<faceCount where Int(pages[f]) == p {
                idx.append(UInt32(f * 3))
                idx.append(UInt32(f * 3 + 1))
                idx.append(UInt32(f * 3 + 2))
            }
            if idx.isEmpty { continue }
            elements.append(SCNGeometryElement(indices: idx, primitiveType: .triangles))
            let m = SCNMaterial()
            m.lightingModel = .constant
            m.isDoubleSided = true
            m.diffuse.contents = images[p]
            m.diffuse.mipFilter = .linear
            m.diffuse.minificationFilter = .linear
            m.diffuse.magnificationFilter = .linear
            materials.append(m)
        }
        guard !elements.isEmpty else { return nil }
        let g = SCNGeometry(sources: [vs, ts], elements: elements)
        g.materials = materials
        return g
    }
}
