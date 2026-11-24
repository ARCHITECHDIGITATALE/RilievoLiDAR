import Foundation
import simd

/// Fusione di più foto per ogni punto della texture.
/// Il dettaglio resta quello della foto principale (la più nitida e frontale); il tono di colore diventa
/// la media pesata di tutte le foto che vedono quel punto. Le differenze di luce/esposizione tra le foto
/// si mediano e i bordi tra un pezzo di texture e l'altro spariscono.
enum MultiViewBlend {

    @inline(__always)
    private static func sample(_ px: RGBAPixels, _ x: Float, _ y: Float) -> SIMD3<Float> {
        let fx = max(0, min(Float(px.width) - 1.001, x - 0.5))
        let fy = max(0, min(Float(px.height) - 1.001, y - 0.5))
        let x0 = Int(fx), y0 = Int(fy)
        let tx = fx - Float(x0), ty = fy - Float(y0)
        func at(_ x: Int, _ y: Int) -> SIMD3<Float> {
            let o = (y * px.width + x) * 4
            return SIMD3<Float>(Float(px.data[o]), Float(px.data[o + 1]), Float(px.data[o + 2]))
        }
        let a = at(x0, y0), b = at(x0 + 1, y0), c = at(x0, y0 + 1), d = at(x0 + 1, y0 + 1)
        let sx: Float = 1 - tx
        let sy: Float = 1 - ty
        let top: SIMD3<Float> = a * sx + b * tx
        let bottom: SIMD3<Float> = c * sx + d * tx
        let mixed: SIMD3<Float> = top * sy + bottom * ty
        return mixed / 255
    }

    /// Colore di un punto 3D visto dalla foto k, con il suo peso (0 se non visibile).
    @inline(__always)
    private static func look(_ k: Int, _ p: SIMD3<Float>, _ n: SIMD3<Float>, cams: [MeshExporter.Cam],
                             small: [RGBAPixels?], gains: [SIMD3<Float>]) -> (SIMD3<Float>, Float)? {
        guard let px = small[k] else { return nil }
        let cam = cams[k]
        guard let q = cam.project(p) else { return nil }
        if let d = cam.depthAt(u: q.x, v: q.y), q.z - d > 0.08 { return nil }   // nascosto da un oggetto
        let toCam = cam.position - p
        let dist = max(simd_length(toCam), 0.05)
        let facing = abs(simd_dot(n, toCam / dist))
        if facing < 0.2 { return nil }
        // Sfuma verso i bordi della foto, così una foto che "entra" o "esce" non crea gradini
        let edge = min(min(q.x, cam.width - q.x), min(q.y, cam.height - q.y))
        let feather = max(0, min(1, edge / (0.12 * min(cam.width, cam.height))))
        let w = facing * facing / (dist * dist) * (0.05 + feather)
        let c = sample(px, q.x * Float(px.width) / cam.width, q.y * Float(px.height) / cam.height)
        return (simd_min(c * gains[k], SIMD3<Float>(repeating: 1)), w)
    }

    /// Applica la fusione ai pixel di una pagina dell'atlante (RGBX 8 bit, riga 0 in alto).
    static func apply(to base: UnsafeMutablePointer<UInt8>, bytesPerRow: Int, size: Int,
                      faces: [Int], uv: [SIMD2<Float>], vertices: [SIMD3<Float>], indices: [UInt32],
                      faceCam: [Int32], candCam: [Int32], K: Int,
                      cams: [MeshExporter.Cam], small: [RGBAPixels?], gains: [SIMD3<Float>]) {
        let P = Float(size)
        // 1. A quale triangolo appartiene ogni pixel (passata unica, deterministica)
        var owner = [Int32](repeating: -1, count: size * size)
        for f in faces where faceCam[f] >= 0 {
            let p0 = uv[f * 3] * P, p1 = uv[f * 3 + 1] * P, p2 = uv[f * 3 + 2] * P
            let area = (p1.x - p0.x) * (p2.y - p0.y) - (p1.y - p0.y) * (p2.x - p0.x)
            if abs(area) < 1e-6 { continue }
            let minX = max(0, Int(min(p0.x, p1.x, p2.x).rounded(.down)) - 1)
            let maxX = min(size - 1, Int(max(p0.x, p1.x, p2.x).rounded(.up)) + 1)
            let minY = max(0, Int(min(p0.y, p1.y, p2.y).rounded(.down)) - 1)
            let maxY = min(size - 1, Int(max(p0.y, p1.y, p2.y).rounded(.up)) + 1)
            if minX > maxX || minY > maxY { continue }
            for y in minY...maxY {
                let py = Float(y) + 0.5
                for x in minX...maxX {
                    let m = y * size + x
                    if owner[m] >= 0 { continue }
                    let px = Float(x) + 0.5
                    let w0 = ((p1.x - px) * (p2.y - py) - (p1.y - py) * (p2.x - px)) / area
                    let w1 = ((p2.x - px) * (p0.y - py) - (p2.y - py) * (p0.x - px)) / area
                    let w2 = 1 - w0 - w1
                    if w0 < -0.15 || w1 < -0.15 || w2 < -0.15 { continue }
                    owner[m] = Int32(f)
                }
            }
        }

        // 2. Fusione, in parallelo per bande di righe (ogni pixel è scritto da un solo thread)
        let bands = 32
        owner.withUnsafeBufferPointer { own in
            DispatchQueue.concurrentPerform(iterations: bands) { band in
                let y0 = size * band / bands
                let y1 = size * (band + 1) / bands
                for y in y0..<y1 {
                    let py = Float(y) + 0.5
                    for x in 0..<size {
                        let f = Int(own[y * size + x])
                        if f < 0 { continue }
                        let p0 = uv[f * 3] * P, p1 = uv[f * 3 + 1] * P, p2 = uv[f * 3 + 2] * P
                        let area = (p1.x - p0.x) * (p2.y - p0.y) - (p1.y - p0.y) * (p2.x - p0.x)
                        let px = Float(x) + 0.5
                        var w0 = ((p1.x - px) * (p2.y - py) - (p1.y - py) * (p2.x - px)) / area
                        var w1 = ((p2.x - px) * (p0.y - py) - (p2.y - py) * (p0.x - px)) / area
                        w0 = max(0, min(1, w0))
                        w1 = max(0, min(1 - w0, w1))
                        let w2 = 1 - w0 - w1
                        let a = vertices[Int(indices[f * 3])]
                        let b = vertices[Int(indices[f * 3 + 1])]
                        let c = vertices[Int(indices[f * 3 + 2])]
                        let p = a * w0 + b * w1 + c * w2
                        let cr = simd_cross(b - a, c - a)
                        let cl = simd_length(cr)
                        if cl < 1e-12 { continue }
                        let n = cr / cl

                        let k0 = Int(faceCam[f])
                        guard let primary = look(k0, p, n, cams: cams, small: small, gains: gains) else { continue }
                        var sum = primary.0 * primary.1
                        var wsum = primary.1
                        for j in 0..<K {
                            let k = Int(candCam[f * K + j])
                            if k < 0 { break }
                            if k == k0 { continue }
                            if let s = look(k, p, n, cams: cams, small: small, gains: gains) {
                                sum += s.0 * s.1
                                wsum += s.1
                            }
                        }
                        if wsum <= 0 { continue }
                        let limit = SIMD3<Float>(repeating: 0.15)
                        let off = simd_clamp(sum / wsum - primary.0, -limit, limit) * 255
                        let i = y * bytesPerRow + x * 4
                        base[i] = UInt8(max(0, min(255, Float(base[i]) + off.x)))
                        base[i + 1] = UInt8(max(0, min(255, Float(base[i + 1]) + off.y)))
                        base[i + 2] = UInt8(max(0, min(255, Float(base[i + 2]) + off.z)))
                    }
                }
            }
        }
    }
}
