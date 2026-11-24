import Foundation
import simd

/// Chiude i buchi del pavimento (sotto sedie, tavoli, mobili): il LiDAR non vede il pavimento coperto,
/// ma sappiamo che c'è. Si trova il piano del pavimento, se ne disegna l'impronta su una griglia vista
/// dall'alto e si riempiono le zone vuote circondate da pavimento.
extension MeshCleanup {

    static func fillFloor(_ mesh: MeshData, cell: Float = 0.04) -> (mesh: MeshData, floorY: Float?) {
        let V = mesh.vertices
        let I = mesh.indices
        let fCount = I.count / 3
        guard fCount > 100 else { return (mesh, nil) }

        // 1. Facce orizzontali rivolte verso l'alto
        var upFaces: [(Int, Float, Float)] = []   // faccia, quota baricentro, area
        var minY = Float.greatestFiniteMagnitude
        for f in 0..<fCount {
            let a = V[Int(I[f * 3])], b = V[Int(I[f * 3 + 1])], c = V[Int(I[f * 3 + 2])]
            let cr = simd_cross(b - a, c - a)
            let len = simd_length(cr)
            if len < 1e-10 { continue }
            if cr.y / len < 0.9 { continue }
            let cy = (a.y + b.y + c.y) / 3
            upFaces.append((f, cy, len * 0.5))
            minY = min(minY, cy)
        }
        guard !upFaces.isEmpty else { return (mesh, nil) }

        // 2. Quota del pavimento: la fascia di 1 cm con più area orizzontale nei 60 cm più bassi
        var bins = [Float](repeating: 0, count: 61)
        for (_, y, area) in upFaces where y - minY < 0.6 {
            bins[min(60, Int((y - minY) / 0.01))] += area
        }
        guard let best = bins.indices.max(by: { bins[$0] < bins[$1] }), bins[best] > 0.3 else { return (mesh, nil) }
        let approx = minY + (Float(best) + 0.5) * 0.01
        var wy: Float = 0
        var wa: Float = 0
        for (_, y, area) in upFaces where abs(y - approx) < 0.02 {
            wy += y * area
            wa += area
        }
        guard wa > 1.0 else { return (mesh, nil) }   // almeno 1 m² di pavimento visto
        let floorY = wy / wa

        let floorFaces = upFaces.filter { abs($0.1 - floorY) < 0.04 }.map { $0.0 }
        var lo = SIMD2<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD2<Float>(repeating: -.greatestFiniteMagnitude)
        for f in floorFaces {
            for j in 0..<3 {
                let p = V[Int(I[f * 3 + j])]
                lo = simd_min(lo, SIMD2<Float>(p.x, p.z))
                hi = simd_max(hi, SIMD2<Float>(p.x, p.z))
            }
        }
        // Griglia con un bordo di celle vuote tutto attorno
        let pad = 2
        let w = Int(((hi.x - lo.x) / cell).rounded(.up)) + 2 * pad + 1
        let h = Int(((hi.y - lo.y) / cell).rounded(.up)) + 2 * pad + 1
        guard w > 4, h > 4, w * h < 600 * 600 else { return (mesh, floorY) }
        let origin = lo - Float(pad) * cell
        func cellOf(_ x: Float, _ z: Float) -> (Int, Int) {
            (Int(((x - origin.x) / cell).rounded(.down)), Int(((z - origin.y) / cell).rounded(.down)))
        }

        // 3. Impronta del pavimento visto
        var covered = [Bool](repeating: false, count: w * h)
        for f in floorFaces {
            let p0 = V[Int(I[f * 3])], p1 = V[Int(I[f * 3 + 1])], p2 = V[Int(I[f * 3 + 2])]
            let a = SIMD2<Float>(p0.x, p0.z), b = SIMD2<Float>(p1.x, p1.z), c = SIMD2<Float>(p2.x, p2.z)
            let (x0, z0) = cellOf(min(a.x, b.x, c.x), min(a.y, b.y, c.y))
            let (x1, z1) = cellOf(max(a.x, b.x, c.x), max(a.y, b.y, c.y))
            let area = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
            if abs(area) < 1e-10 || max(0, z0) > min(h - 1, z1) || max(0, x0) > min(w - 1, x1) { continue }
            for gz in max(0, z0)...min(h - 1, z1) {
                for gx in max(0, x0)...min(w - 1, x1) {
                    let px = origin.x + (Float(gx) + 0.5) * cell
                    let pz = origin.y + (Float(gz) + 0.5) * cell
                    // Centro cella dentro il triangolo (con tolleranza di mezza cella)
                    let w0 = ((b.x - px) * (c.y - pz) - (b.y - pz) * (c.x - px)) / area
                    let w1 = ((c.x - px) * (a.y - pz) - (c.y - pz) * (a.x - px)) / area
                    let w2 = 1 - w0 - w1
                    let tol: Float = -0.25
                    if w0 >= tol && w1 >= tol && w2 >= tol { covered[gz * w + gx] = true }
                }
            }
        }

        // 4. Buchi chiusi: celle vuote non raggiungibili dal bordo della griglia
        var outside = [Bool](repeating: false, count: w * h)
        var stack: [Int] = []
        for x in 0..<w {
            stack.append(x)
            stack.append((h - 1) * w + x)
        }
        for z in 0..<h {
            stack.append(z * w)
            stack.append(z * w + w - 1)
        }
        while let i = stack.popLast() {
            if outside[i] || covered[i] { continue }
            outside[i] = true
            let x = i % w, z = i / w
            if x > 0 { stack.append(i - 1) }
            if x < w - 1 { stack.append(i + 1) }
            if z > 0 { stack.append(i - w) }
            if z < h - 1 { stack.append(i + w) }
        }

        // 5. Rientranze strette aperte su un lato (chiusura morfologica, raggio ~24 cm)
        func dilate(_ src: [Bool], _ r: Int) -> [Bool] {
            var tmp = [Bool](repeating: false, count: w * h)
            for z in 0..<h {
                for x in 0..<w where src[z * w + x] {
                    for xx in max(0, x - r)...min(w - 1, x + r) { tmp[z * w + xx] = true }
                }
            }
            var out = [Bool](repeating: false, count: w * h)
            for z in 0..<h {
                for x in 0..<w where tmp[z * w + x] {
                    for zz in max(0, z - r)...min(h - 1, z + r) { out[zz * w + x] = true }
                }
            }
            return out
        }
        func erode(_ src: [Bool], _ r: Int) -> [Bool] {
            let inv = src.map { !$0 }
            return dilate(inv, r).map { !$0 }
        }
        let closed = erode(dilate(covered, 6), 6)

        var fill = [Bool](repeating: false, count: w * h)
        var filledCount = 0
        for i in 0..<(w * h) where !covered[i] && (!outside[i] || closed[i]) {
            fill[i] = true
            filledCount += 1
        }
        guard filledCount > 0 else { return (mesh, floorY) }
        // Un giro di celle di sovrapposizione col pavimento esistente: niente fessure ai bordi
        var grown = fill
        for z in 1..<(h - 1) {
            for x in 1..<(w - 1) where !fill[z * w + x] && covered[z * w + x] {
                let i = z * w + x
                if fill[i - 1] || fill[i + 1] || fill[i - w] || fill[i + w] { grown[i] = true }
            }
        }

        // 6. Quadratini di pavimento (leggermente sotto, così il pavimento vero resta sopra)
        var out = mesh
        var corner = [Int: UInt32]()
        let y = floorY - 0.003
        func vertex(_ gx: Int, _ gz: Int) -> UInt32 {
            let key = gz * (w + 1) + gx
            if let v = corner[key] { return v }
            let v = UInt32(out.vertices.count)
            out.vertices.append(SIMD3<Float>(origin.x + Float(gx) * cell, y, origin.y + Float(gz) * cell))
            corner[key] = v
            return v
        }
        for z in 0..<h {
            for x in 0..<w where grown[z * w + x] {
                let a = vertex(x, z), b = vertex(x, z + 1), c = vertex(x + 1, z + 1), d = vertex(x + 1, z)
                out.indices.append(contentsOf: [a, b, c, a, c, d])   // normale verso l'alto
            }
        }
        return (out, floorY)
    }
}
