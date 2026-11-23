import Foundation
import simd

/// Rifinitura della mesh ricostruita: toglie le frange, chiude i buchi piccoli e leviga
/// (bordi senza scalini, superfici senza il "rumore" della griglia).
extension MeshCleanup {

    @inline(__always) static func edgeKey(_ a: UInt32, _ b: UInt32) -> UInt64 {
        (UInt64(min(a, b)) << 32) | UInt64(max(a, b))
    }

    static func refine(_ mesh: MeshData, smoothIterations: Int = 8, maxHoleEdges: Int = 48) -> MeshData {
        var indices = removeFringe(mesh.indices, passes: 2)
        var vertices = mesh.vertices
        fillSmallHoles(&vertices, &indices, maxEdges: maxHoleEdges)
        vertices = taubinSmooth(vertices, indices, iterations: smoothIterations)
        return compact(vertices, indices)
    }

    /// Conta quante facce usano ogni lato.
    static func edgeUse(_ indices: [UInt32]) -> [UInt64: Int32] {
        var use = [UInt64: Int32]()
        use.reserveCapacity(indices.count)
        var t = 0
        while t + 2 < indices.count {
            let a = indices[t], b = indices[t + 1], c = indices[t + 2]
            use[edgeKey(a, b), default: 0] += 1
            use[edgeKey(b, c), default: 0] += 1
            use[edgeKey(c, a), default: 0] += 1
            t += 3
        }
        return use
    }

    /// Toglie i triangoli "a dente" sui bordi (due o tre lati liberi): sono gli scalini frastagliati.
    static func removeFringe(_ input: [UInt32], passes: Int) -> [UInt32] {
        var indices = input
        for _ in 0..<passes {
            let use = edgeUse(indices)
            var out: [UInt32] = []
            out.reserveCapacity(indices.count)
            var t = 0
            while t + 2 < indices.count {
                let a = indices[t], b = indices[t + 1], c = indices[t + 2]
                t += 3
                var free = 0
                if use[edgeKey(a, b)] == 1 { free += 1 }
                if use[edgeKey(b, c)] == 1 { free += 1 }
                if use[edgeKey(c, a)] == 1 { free += 1 }
                if free < 2 { out.append(contentsOf: [a, b, c]) }
            }
            if out.count == indices.count { break }
            indices = out
        }
        return indices
    }

    /// Chiude i buchi con contorno corto (aggiunge un vertice al centro e un ventaglio di triangoli).
    static func fillSmallHoles(_ vertices: inout [SIMD3<Float>], _ indices: inout [UInt32], maxEdges: Int) {
        let use = edgeUse(indices)
        // Lati di bordo orientati come nella faccia; il buco si percorre al contrario.
        var next = [UInt32: UInt32]()
        var bad = Set<UInt32>()
        var t = 0
        while t + 2 < indices.count {
            let tri = [indices[t], indices[t + 1], indices[t + 2]]
            t += 3
            for k in 0..<3 {
                let a = tri[k], b = tri[(k + 1) % 3]
                if use[edgeKey(a, b)] == 1 {
                    if next[b] != nil { bad.insert(b) }   // vertice non manifold: si evita
                    next[b] = a
                }
            }
        }
        var visited = Set<UInt32>()
        for start in next.keys where !visited.contains(start) && !bad.contains(start) {
            var loop: [UInt32] = []
            var v = start
            var closed = false
            while loop.count <= maxEdges {
                if visited.contains(v) || bad.contains(v) { break }
                visited.insert(v)
                loop.append(v)
                guard let n = next[v] else { break }
                if n == start {
                    closed = true
                    break
                }
                v = n
            }
            guard closed, loop.count >= 3, loop.count <= maxEdges else { continue }
            var center = SIMD3<Float>(0, 0, 0)
            for i in loop { center += vertices[Int(i)] }
            center /= Float(loop.count)
            let c = UInt32(vertices.count)
            vertices.append(center)
            for i in 0..<loop.count {
                indices.append(contentsOf: [loop[i], loop[(i + 1) % loop.count], c])
            }
        }
    }

    /// Levigatura di Taubin (non restringe il modello). Sui bordi si usano solo i vicini di bordo,
    /// così i contorni frastagliati diventano linee morbide.
    static func taubinSmooth(_ input: [SIMD3<Float>], _ indices: [UInt32], iterations: Int) -> [SIMD3<Float>] {
        let n = input.count
        guard n > 0, iterations > 0 else { return input }
        let use = edgeUse(indices)
        var interior = [[UInt32]](repeating: [], count: n)
        var boundary = [[UInt32]](repeating: [], count: n)
        for (key, count) in use {
            let a = UInt32(truncatingIfNeeded: key >> 32)
            let b = UInt32(truncatingIfNeeded: key & 0xFFFF_FFFF)
            interior[Int(a)].append(b)
            interior[Int(b)].append(a)
            if count == 1 {
                boundary[Int(a)].append(b)
                boundary[Int(b)].append(a)
            }
        }
        var v = input
        func step(_ factor: Float) {
            var out = v
            for i in 0..<n {
                let nb = boundary[i].isEmpty ? interior[i] : boundary[i]
                if nb.isEmpty { continue }
                var avg = SIMD3<Float>(0, 0, 0)
                for j in nb { avg += v[Int(j)] }
                avg /= Float(nb.count)
                out[i] = v[i] + factor * (avg - v[i])
            }
            v = out
        }
        for _ in 0..<iterations {
            step(0.5)
            step(-0.53)
        }
        return v
    }

    static func compact(_ vertices: [SIMD3<Float>], _ indices: [UInt32]) -> MeshData {
        var used = [Int32](repeating: -1, count: vertices.count)
        var outV: [SIMD3<Float>] = []
        var outI: [UInt32] = []
        outI.reserveCapacity(indices.count)
        for i in indices {
            if used[Int(i)] < 0 {
                used[Int(i)] = Int32(outV.count)
                outV.append(vertices[Int(i)])
            }
            outI.append(UInt32(used[Int(i)]))
        }
        return MeshData(vertices: outV, indices: outI)
    }
}
