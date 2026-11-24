import Foundation
import simd

/// Livellamento delle cuciture: dove due foto diverse si toccano, calcola una correzione di colore
/// che le rende uguali sul bordo e la sfuma gradualmente dentro ciascun pezzo di texture.
enum SeamLeveling {

    /// Restituisce una correzione di colore (0…1) per ogni angolo di triangolo.
    static func solve(faceCam: [Int32], faceUV: [SIMD2<Float>], indices: [UInt32], vertexCount: Int,
                      cams: [MeshExporter.Cam], small: [RGBAPixels?], gains: [SIMD3<Float>],
                      iterations: Int = 90) -> [SIMD3<Float>] {
        let fCount = faceCam.count
        var cornerOffset = [SIMD3<Float>](repeating: SIMD3<Float>(0, 0, 0), count: fCount * 3)

        // 1. Una variabile per ogni coppia (vertice, foto) usata
        var varIndex = [UInt64: Int32]()
        varIndex.reserveCapacity(vertexCount + vertexCount / 4)
        var color: [SIMD3<Float>] = []
        var vertexOf: [Int32] = []
        var cornerVar = [Int32](repeating: -1, count: fCount * 3)
        for f in 0..<fCount where faceCam[f] >= 0 {
            let k = Int(faceCam[f])
            guard let px = small[k] else { continue }
            let cam = cams[k]
            for j in 0..<3 {
                let v = indices[f * 3 + j]
                let key = (UInt64(v) << 20) | UInt64(k)
                if let idx = varIndex[key] {
                    cornerVar[f * 3 + j] = idx
                    continue
                }
                let uv = faceUV[f * 3 + j]
                let x = min(px.width - 1, max(0, Int(uv.x * Float(px.width) / cam.width)))
                let y = min(px.height - 1, max(0, Int(uv.y * Float(px.height) / cam.height)))
                let o = (y * px.width + x) * 4
                let raw = SIMD3<Float>(Float(px.data[o]), Float(px.data[o + 1]), Float(px.data[o + 2])) / 255
                let idx = Int32(color.count)
                varIndex[key] = idx
                color.append(simd_min(raw * gains[k], SIMD3<Float>(repeating: 1)))
                vertexOf.append(Int32(v))
                cornerVar[f * 3 + j] = idx
            }
        }
        let n = color.count
        guard n > 0 else { return cornerOffset }

        // 2. Vicini: stessa foto lungo i lati (levigatura), stesso vertice con foto diverse (cucitura)
        var smoothPairs: [(Int32, Int32)] = []
        smoothPairs.reserveCapacity(fCount * 3)
        for f in 0..<fCount {
            let a = cornerVar[f * 3], b = cornerVar[f * 3 + 1], c = cornerVar[f * 3 + 2]
            if a < 0 || b < 0 || c < 0 { continue }
            smoothPairs.append((a, b))
            smoothPairs.append((b, c))
            smoothPairs.append((c, a))
        }
        var byVertex = [Int32: [Int32]]()
        for i in 0..<n { byVertex[vertexOf[i], default: []].append(Int32(i)) }
        var seamPairs: [(Int32, Int32)] = []
        for (_, list) in byVertex where list.count > 1 {
            for i in 0..<list.count {
                for j in (i + 1)..<list.count { seamPairs.append((list[i], list[j])) }
            }
        }
        if seamPairs.isEmpty { return cornerOffset }
        let smooth = csr(n, smoothPairs)
        let seam = csr(n, seamPairs)

        // 3. Gauss-Seidel: sulle cuciture i colori corretti devono coincidere, dentro i pezzi la correzione varia piano
        var g = [SIMD3<Float>](repeating: SIMD3<Float>(0, 0, 0), count: n)
        let seamWeight: Float = 3
        for _ in 0..<iterations {
            for a in 0..<n {
                var sum = SIMD3<Float>(0, 0, 0)
                var w: Float = 0.002   // tende a zero dove non serve correggere
                var e = Int(smooth.offsets[a])
                let eEnd = Int(smooth.offsets[a + 1])
                while e < eEnd {
                    sum += g[Int(smooth.adj[e])]
                    w += 1
                    e += 1
                }
                e = Int(seam.offsets[a])
                let sEnd = Int(seam.offsets[a + 1])
                while e < sEnd {
                    let b = Int(seam.adj[e])
                    sum += (color[b] + g[b] - color[a]) * seamWeight
                    w += seamWeight
                    e += 1
                }
                g[a] = simd_clamp(sum / w, SIMD3<Float>(repeating: -0.35), SIMD3<Float>(repeating: 0.35))
            }
        }

        for i in 0..<(fCount * 3) where cornerVar[i] >= 0 {
            cornerOffset[i] = g[Int(cornerVar[i])]
        }
        return cornerOffset
    }

    private static func csr(_ n: Int, _ pairs: [(Int32, Int32)]) -> (offsets: [Int32], adj: [Int32]) {
        var count = [Int32](repeating: 0, count: n + 1)
        for (a, b) in pairs {
            count[Int(a) + 1] += 1
            count[Int(b) + 1] += 1
        }
        for i in 0..<n { count[i + 1] += count[i] }
        var fill = count
        var adj = [Int32](repeating: 0, count: Int(count[n]))
        for (a, b) in pairs {
            adj[Int(fill[Int(a)])] = b
            fill[Int(a)] += 1
            adj[Int(fill[Int(b)])] = a
            fill[Int(b)] += 1
        }
        return (count, adj)
    }

    /// Applica le correzioni ai pixel dell'atlante (RGBX 8 bit, riga 0 in alto), interpolandole nel triangolo.
    static func apply(to base: UnsafeMutablePointer<UInt8>, bytesPerRow: Int, size: Int,
                      faces: [Int], uv: [SIMD2<Float>], offsets: [SIMD3<Float>]) {
        var mask = [UInt8](repeating: 0, count: size * size)
        let P = Float(size)
        for f in faces {
            let o0 = offsets[f * 3], o1 = offsets[f * 3 + 1], o2 = offsets[f * 3 + 2]
            let mag = simd_reduce_max(simd_abs(o0)) + simd_reduce_max(simd_abs(o1)) + simd_reduce_max(simd_abs(o2))
            if mag < 0.004 { continue }
            let p0 = uv[f * 3] * P, p1 = uv[f * 3 + 1] * P, p2 = uv[f * 3 + 2] * P
            let area = (p1.x - p0.x) * (p2.y - p0.y) - (p1.y - p0.y) * (p2.x - p0.x)
            if abs(area) < 1e-6 { continue }
            let minX = max(0, Int((min(p0.x, p1.x, p2.x)).rounded(.down)) - 1)
            let maxX = min(size - 1, Int((max(p0.x, p1.x, p2.x)).rounded(.up)) + 1)
            let minY = max(0, Int((min(p0.y, p1.y, p2.y)).rounded(.down)) - 1)
            let maxY = min(size - 1, Int((max(p0.y, p1.y, p2.y)).rounded(.up)) + 1)
            if minX > maxX || minY > maxY { continue }
            for y in minY...maxY {
                let py = Float(y) + 0.5
                for x in minX...maxX {
                    let px = Float(x) + 0.5
                    let w0 = ((p1.x - px) * (p2.y - py) - (p1.y - py) * (p2.x - px)) / area
                    let w1 = ((p2.x - px) * (p0.y - py) - (p2.y - py) * (p0.x - px)) / area
                    let w2 = 1 - w0 - w1
                    if w0 < -0.08 || w1 < -0.08 || w2 < -0.08 { continue }
                    let m = y * size + x
                    if mask[m] != 0 { continue }
                    mask[m] = 1
                    let off = (o0 * w0 + o1 * w1 + o2 * w2) * 255
                    let i = y * bytesPerRow + x * 4
                    base[i] = UInt8(max(0, min(255, Float(base[i]) + off.x)))
                    base[i + 1] = UInt8(max(0, min(255, Float(base[i + 1]) + off.y)))
                    base[i + 2] = UInt8(max(0, min(255, Float(base[i + 2]) + off.z)))
                }
            }
        }
    }
}
