import Foundation
import simd

/// Mappa di profondità LiDAR salvata durante la scansione (per la ricostruzione finale).
struct DepthFrameRecord: Codable {
    var file: String           // relativo alla cartella mesh: profondità Float32 seguita da affidabilità UInt8
    var width: Int
    var height: Int
    var intrinsics: [Float]    // fx, fy, cx, cy alla risoluzione della mappa di profondità
    var transform: [Float]     // camera -> mondo, 4x4 colonna per colonna
}

/// Volume TSDF sparso a blocchi 8×8×8: media le misure di profondità di tutti i fotogrammi.
final class TSDFVolume {
    let voxel: Float
    let trunc: Float
    private(set) var blocks: [SIMD3<Int32>: Int] = [:]
    private var tsdf: [Float] = []
    private var weight: [Float] = []

    init(voxel: Float) {
        self.voxel = voxel
        self.trunc = voxel * 3
    }

    var voxelCount: Int { tsdf.count }

    @inline(__always) private static func split(_ v: SIMD3<Int32>) -> (SIMD3<Int32>, Int) {
        let b = SIMD3<Int32>(v.x >> 3, v.y >> 3, v.z >> 3)
        let l = Int(v.x & 7) + Int(v.y & 7) * 8 + Int(v.z & 7) * 64
        return (b, l)
    }

    private func slot(_ b: SIMD3<Int32>) -> Int {
        if let s = blocks[b] { return s }
        let s = blocks.count
        blocks[b] = s
        tsdf.append(contentsOf: repeatElement(1, count: 512))
        weight.append(contentsOf: repeatElement(0, count: 512))
        return s
    }

    /// Integra una mappa di profondità: aggiorna i voxel vicini alla superficie lungo ogni raggio.
    func integrate(depth: UnsafeBufferPointer<Float>, confidence: UnsafeBufferPointer<UInt8>?,
                   width w: Int, height h: Int, fx: Float, fy: Float, cx: Float, cy: Float,
                   camToWorld: simd_float4x4, pixelStep: Int) {
        let C = camToWorld.translation
        var lastBlock = SIMD3<Int32>(Int32.min, Int32.min, Int32.min)
        var lastSlot = 0
        let step = voxel * 0.75
        var v = 0
        while v < h {
            var u = 0
            while u < w {
                defer { u += pixelStep }
                let d = depth[v * w + u]
                if !(d > 0.2 && d < 4.5) { continue }
                var nw: Float = 1
                if let confidence {
                    let c = confidence[v * w + u]
                    if c == 0 { continue }
                    nw = c >= 2 ? 1 : 0.3
                }
                nw /= max(0.7, d)   // le misure lontane sono più rumorose
                let pc = SIMD4<Float>((Float(u) - cx) / fx * d, -(Float(v) - cy) / fy * d, -d, 1)
                let pw4 = camToWorld * pc
                let P = SIMD3<Float>(pw4.x, pw4.y, pw4.z)
                let ray = P - C
                let ts = simd_length(ray)
                if ts < 1e-4 { continue }
                let r = ray / ts
                var s = -trunc
                while s <= trunc {
                    let q = P + r * s
                    s += step
                    let vi = SIMD3<Int32>(Int32((q.x / voxel).rounded(.down)),
                                          Int32((q.y / voxel).rounded(.down)),
                                          Int32((q.z / voxel).rounded(.down)))
                    let (b, li) = TSDFVolume.split(vi)
                    let sl: Int
                    if b == lastBlock {
                        sl = lastSlot
                    } else {
                        sl = slot(b)
                        lastBlock = b
                        lastSlot = sl
                    }
                    let center = (SIMD3<Float>(Float(vi.x), Float(vi.y), Float(vi.z)) + 0.5) * voxel
                    let tv = simd_dot(center - C, r)
                    let sdf = max(-1, min(1, (ts - tv) / trunc))
                    let idx = sl * 512 + li
                    let w0 = weight[idx]
                    tsdf[idx] = (tsdf[idx] * w0 + sdf * nw) / (w0 + nw)
                    weight[idx] = min(w0 + nw, 80)
                }
            }
            v += pixelStep
        }
    }

    @inline(__always) private func value(_ v: SIMD3<Int32>, minWeight: Float) -> Float? {
        let (b, l) = TSDFVolume.split(v)
        guard let s = blocks[b] else { return nil }
        let i = s * 512 + l
        return weight[i] >= minWeight ? tsdf[i] : nil
    }

    /// Estrae la superficie (passaggio per lo zero) con il metodo "surface nets": mesh liscia e senza buchi tra i blocchi.
    func extractMesh(minWeight: Float, progress: (Double) -> Void) -> MeshData {
        var cubeVertex = [SIMD3<Int32>: UInt32]()
        var vertices: [SIMD3<Float>] = []
        let corner: [SIMD3<Int32>] = [
            SIMD3<Int32>(0, 0, 0), SIMD3<Int32>(1, 0, 0), SIMD3<Int32>(0, 1, 0), SIMD3<Int32>(1, 1, 0),
            SIMD3<Int32>(0, 0, 1), SIMD3<Int32>(1, 0, 1), SIMD3<Int32>(0, 1, 1), SIMD3<Int32>(1, 1, 1)
        ]
        var edges: [(Int, Int)] = []
        for i in 0..<8 {
            for bit in [1, 2, 4] where i & bit == 0 { edges.append((i, i | bit)) }
        }
        let blockList = Array(blocks.keys)

        // 1. Un vertice per ogni cubo attraversato dalla superficie
        for (n, b) in blockList.enumerated() {
            if n % 2000 == 0 { progress(0.5 * Double(n) / Double(max(blockList.count, 1))) }
            let base = b &* 8
            for lz in Int32(0)..<8 {
                for ly in Int32(0)..<8 {
                    for lx in Int32(0)..<8 {
                        let v = base &+ SIMD3<Int32>(lx, ly, lz)
                        guard let v0 = value(v, minWeight: minWeight), abs(v0) < 0.7 else { continue }
                        var vals = SIMD8<Float>()
                        var ok = true
                        var neg = false
                        var pos = false
                        for c in 0..<8 {
                            guard let x = c == 0 ? v0 : value(v &+ corner[c], minWeight: minWeight) else {
                                ok = false
                                break
                            }
                            vals[c] = x
                            if x < 0 { neg = true } else { pos = true }
                        }
                        if !ok || !(neg && pos) { continue }
                        var sum = SIMD3<Float>(0, 0, 0)
                        var cnt: Float = 0
                        for (a, c) in edges where (vals[a] < 0) != (vals[c] < 0) {
                            let t = vals[a] / (vals[a] - vals[c])
                            let pa = SIMD3<Float>(Float(corner[a].x), Float(corner[a].y), Float(corner[a].z))
                            let pb = SIMD3<Float>(Float(corner[c].x), Float(corner[c].y), Float(corner[c].z))
                            sum += pa + (pb - pa) * t
                            cnt += 1
                        }
                        let local = sum / max(cnt, 1)
                        let p = (SIMD3<Float>(Float(v.x), Float(v.y), Float(v.z)) + 0.5 + local) * voxel
                        cubeVertex[v] = UInt32(vertices.count)
                        vertices.append(p)
                    }
                }
            }
        }

        // 2. Un quadrilatero per ogni lato della griglia attraversato dalla superficie
        let axes: [SIMD3<Int32>] = [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)]
        // Cubi attorno al lato, in ordine antiorario visto dalla direzione dell'asse
        let around: [[SIMD3<Int32>]] = [
            [SIMD3(0, -1, -1), SIMD3(0, 0, -1), SIMD3(0, 0, 0), SIMD3(0, -1, 0)],
            [SIMD3(-1, 0, -1), SIMD3(-1, 0, 0), SIMD3(0, 0, 0), SIMD3(0, 0, -1)],
            [SIMD3(-1, -1, 0), SIMD3(0, -1, 0), SIMD3(0, 0, 0), SIMD3(-1, 0, 0)]
        ]
        var indices: [UInt32] = []
        for (n, b) in blockList.enumerated() {
            if n % 2000 == 0 { progress(0.5 + 0.5 * Double(n) / Double(max(blockList.count, 1))) }
            let base = b &* 8
            for lz in Int32(0)..<8 {
                for ly in Int32(0)..<8 {
                    for lx in Int32(0)..<8 {
                        let v = base &+ SIMD3<Int32>(lx, ly, lz)
                        guard let a = value(v, minWeight: minWeight), abs(a) < 0.7 else { continue }
                        for ax in 0..<3 {
                            guard let c = value(v &+ axes[ax], minWeight: minWeight), (a < 0) != (c < 0) else { continue }
                            var q: [UInt32] = []
                            for o in around[ax] {
                                guard let vi = cubeVertex[v &+ o] else { break }
                                q.append(vi)
                            }
                            if q.count < 4 { continue }
                            if a >= 0 { q.reverse() }   // normale verso lo spazio libero
                            indices.append(contentsOf: [q[0], q[1], q[2], q[0], q[2], q[3]])
                        }
                    }
                }
            }
        }
        return MeshData(vertices: vertices, indices: indices)
    }
}

enum DepthFusion {
    /// Riempie i buchi della mesh ricostruita (vetri, specchi, zone viste poco) con i triangoli
    /// della mesh in tempo reale di ARKit che cadono dove la ricostruzione non ha superficie.
    static func fillGaps(fused: MeshData, arkit: MeshData, cell: Float = 0.04) -> MeshData {
        guard !arkit.indices.isEmpty else { return fused }
        func key(_ p: SIMD3<Float>) -> SIMD3<Int32> {
            SIMD3<Int32>(Int32((p.x / cell).rounded(.down)), Int32((p.y / cell).rounded(.down)),
                         Int32((p.z / cell).rounded(.down)))
        }
        var occupied = Set<SIMD3<Int32>>()
        occupied.reserveCapacity(fused.vertices.count)
        for v in fused.vertices { occupied.insert(key(v)) }
        var out = fused
        var remap = [Int32](repeating: -1, count: arkit.vertices.count)
        var t = 0
        while t + 2 < arkit.indices.count {
            let ia = Int(arkit.indices[t]), ib = Int(arkit.indices[t + 1]), ic = Int(arkit.indices[t + 2])
            t += 3
            let centroid = (arkit.vertices[ia] + arkit.vertices[ib] + arkit.vertices[ic]) / 3
            let k = key(centroid)
            var covered = false
            search: for dz in -1...1 {
                for dy in -1...1 {
                    for dx in -1...1 where occupied.contains(k &+ SIMD3<Int32>(Int32(dx), Int32(dy), Int32(dz))) {
                        covered = true
                        break search
                    }
                }
            }
            if covered { continue }
            for i in [ia, ib, ic] {
                if remap[i] < 0 {
                    remap[i] = Int32(out.vertices.count)
                    out.vertices.append(arkit.vertices[i])
                }
                out.indices.append(UInt32(remap[i]))
            }
        }
        return out
    }

    /// Ricostruisce la mesh fondendo tutte le mappe di profondità registrate.
    static func fuse(meshFolder: URL, frames: [DepthFrameRecord], voxel: Float = 0.02,
                     progress: (Double, String) -> Void) -> MeshData? {
        guard frames.count >= 10 else { return nil }
        let volume = TSDFVolume(voxel: voxel)
        for (i, f) in frames.enumerated() {
            if i % 10 == 0 {
                progress(0.75 * Double(i) / Double(frames.count), "Fusione delle misure di profondità…")
            }
            autoreleasepool {
                guard let data = try? Data(contentsOf: meshFolder.appendingPathComponent(f.file)) else { return }
                let n = f.width * f.height
                guard data.count >= n * 4, f.intrinsics.count >= 4 else { return }
                let depth: [Float] = data.withUnsafeBytes { raw in
                    (0..<n).map { raw.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) }
                }
                let conf: [UInt8]? = data.count >= n * 5 ? [UInt8](data[(n * 4)..<(n * 5)]) : nil
                let pose = simd_float4x4(floatArray: f.transform)
                depth.withUnsafeBufferPointer { dp in
                    if let conf {
                        conf.withUnsafeBufferPointer { cp in
                            volume.integrate(depth: dp, confidence: cp, width: f.width, height: f.height,
                                             fx: f.intrinsics[0], fy: f.intrinsics[1],
                                             cx: f.intrinsics[2], cy: f.intrinsics[3],
                                             camToWorld: pose, pixelStep: 2)
                        }
                    } else {
                        volume.integrate(depth: dp, confidence: nil, width: f.width, height: f.height,
                                         fx: f.intrinsics[0], fy: f.intrinsics[1],
                                         cx: f.intrinsics[2], cy: f.intrinsics[3],
                                         camToWorld: pose, pixelStep: 2)
                    }
                }
            }
        }
        let mesh = volume.extractMesh(minWeight: 1.2) { p in
            progress(0.75 + 0.25 * p, "Estrazione della superficie…")
        }
        return mesh.indices.count >= 3 * 2000 ? mesh : nil
    }
}
