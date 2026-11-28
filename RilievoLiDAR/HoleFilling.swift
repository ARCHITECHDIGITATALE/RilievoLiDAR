import Foundation
import simd

/// Chiusura dei buchi, come la fase "Cleaning mesh" di Polycam: vetrate, pannelli e zone viste poco
/// lasciano buchi grandi ma quasi piani; li chiudiamo seguendone il contorno e poi le foto li texturizzano.
extension MeshCleanup {

    /// maxPerimeter in metri; maxDeviation = quanto il contorno può scostarsi da un piano (aperture vere e
    /// bordi esterni non sono piani, quindi non vengono chiusi).
    static func fillHoles(_ vertices: inout [SIMD3<Float>], _ indices: inout [UInt32],
                          maxPerimeter: Float, maxDeviation: Float, floorY: Float? = nil, maxLoop: Int = 1500) {
        let use = edgeUse(indices)
        // Lati di bordo orientati; un vertice può averne più d'uno (contorni irregolari).
        var next = [UInt32: [UInt32]]()
        var t = 0
        while t + 2 < indices.count {
            let tri = [indices[t], indices[t + 1], indices[t + 2]]
            t += 3
            for k in 0..<3 {
                let a = tri[k], b = tri[(k + 1) % 3]
                if use[edgeKey(a, b)] == 1 { next[b, default: []].append(a) }
            }
        }
        var usedEdge = Set<UInt64>()
        var visited = Set<UInt32>()
        for start in next.keys.sorted() where !visited.contains(start) {
            var loop: [UInt32] = []
            var v = start
            var closed = false
            var onLoop = Set<UInt32>()
            while loop.count <= maxLoop {
                loop.append(v)
                onLoop.insert(v)
                guard let outs = next[v],
                      let n = outs.first(where: { !usedEdge.contains((UInt64(v) << 32) | UInt64($0)) && ($0 == start || !onLoop.contains($0)) })
                else { break }
                usedEdge.insert((UInt64(v) << 32) | UInt64(n))
                if n == start {
                    closed = true
                    break
                }
                v = n
            }
            for x in loop { visited.insert(x) }
            guard closed, loop.count >= 3 else { continue }
            let pts = loop.map { vertices[Int($0)] }

            var perimeter: Float = 0
            for i in 0..<pts.count { perimeter += simd_distance(pts[i], pts[(i + 1) % pts.count]) }
            if perimeter > maxPerimeter { continue }

            // Piano medio (metodo di Newell: la normale segue il verso del contorno)
            var normal = SIMD3<Float>(0, 0, 0)
            var center = SIMD3<Float>(0, 0, 0)
            for i in 0..<pts.count {
                let p = pts[i], q = pts[(i + 1) % pts.count]
                normal.x += (p.y - q.y) * (p.z + q.z)
                normal.y += (p.z - q.z) * (p.x + q.x)
                normal.z += (p.x - q.x) * (p.y + q.y)
                center += p
            }
            center /= Float(pts.count)
            let nl = simd_length(normal)
            if nl < 1e-8 { continue }
            normal /= nl
            var deviation: Float = 0
            for p in pts { deviation = max(deviation, abs(simd_dot(p - center, normal))) }
            if deviation > maxDeviation && loop.count > 12 { continue }

            // Aperture verticali che toccano il pavimento o alte più di 1,6 m sono porte e passaggi:
            // restano aperte. Le finestre (con parapetto) si chiudono.
            if abs(normal.y) < 0.5 {
                var minY = Float.greatestFiniteMagnitude
                var maxY = -Float.greatestFiniteMagnitude
                for p in pts {
                    minY = min(minY, p.y)
                    maxY = max(maxY, p.y)
                }
                if maxY - minY > 1.6 { continue }
                if let fy = floorY, minY - fy < 0.2 { continue }
            }

            // Coordinate 2D nel piano, con u × v = normale (il contorno risulta antiorario)
            let helper: SIMD3<Float> = abs(normal.x) < 0.9 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 1, 0)
            let u = simd_normalize(simd_cross(helper, normal))
            let w = simd_cross(normal, u)
            let p2 = pts.map { SIMD2<Float>(simd_dot($0 - center, u), simd_dot($0 - center, w)) }

            if loop.count <= 400, let tris = earClip(p2) {
                for (a, b, c) in tris { indices.append(contentsOf: [loop[a], loop[b], loop[c]]) }
            } else {
                // Contorno troppo irregolare: ventaglio dal centro
                let c = UInt32(vertices.count)
                vertices.append(center)
                for i in 0..<loop.count {
                    indices.append(contentsOf: [loop[i], loop[(i + 1) % loop.count], c])
                }
            }
        }
    }

    /// Triangolazione "ear clipping" di un poligono semplice antiorario. nil se non riesce.
    static func earClip(_ poly: [SIMD2<Float>]) -> [(Int, Int, Int)]? {
        var idx = Array(0..<poly.count)
        var out: [(Int, Int, Int)] = []
        out.reserveCapacity(poly.count)
        func cross(_ o: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var guardCount = 0
        while idx.count > 3 {
            guardCount += 1
            if guardCount > poly.count * poly.count + 10 { return nil }
            var clipped = false
            let n = idx.count
            for i in 0..<n {
                let ia = idx[(i + n - 1) % n], ib = idx[i], ic = idx[(i + 1) % n]
                let a = poly[ia], b = poly[ib], c = poly[ic]
                if cross(a, b, c) <= 1e-10 { continue }   // vertice concavo
                var inside = false
                for j in idx where j != ia && j != ib && j != ic {
                    let p = poly[j]
                    if cross(a, b, p) >= 0 && cross(b, c, p) >= 0 && cross(c, a, p) >= 0 {
                        inside = true
                        break
                    }
                }
                if inside { continue }
                out.append((ia, ib, ic))
                idx.remove(at: i)
                clipped = true
                break
            }
            if !clipped { return nil }
        }
        if idx.count == 3 { out.append((idx[0], idx[1], idx[2])) }
        return out
    }
}
