import Foundation
import SceneKit
import UIKit
import simd

/// Scatola di ritaglio della mesh (salvata in ritaglio.json, non distruttiva).
struct CropBox: Codable, Equatable {
    var center: SIMD3<Float>
    var size: SIMD3<Float>      // larghezza (x locale), altezza (y), profondità (z locale)
    var yaw: Float              // rotazione attorno all'asse verticale, in gradi
    var keepInside: Bool        // true = tieni dentro (crop in), false = togli dentro (crop out)

    static let fileName = "ritaglio.json"

    /// Scatola iniziale: tutta la mesh con un piccolo margine.
    static func around(min lo: SIMD3<Float>, max hi: SIMD3<Float>) -> CropBox {
        CropBox(center: (lo + hi) / 2, size: simd_max(hi - lo, SIMD3<Float>(repeating: 0.1)) * 1.02,
                yaw: 0, keepInside: true)
    }

    var yawRadians: Float { yaw * .pi / 180 }

    func contains(_ p: SIMD3<Float>) -> Bool {
        let d = p - center
        let a = yawRadians
        let x = d.x * cos(a) - d.z * sin(a)
        let z = d.x * sin(a) + d.z * cos(a)
        let h = size / 2
        return abs(x) <= h.x && abs(d.y) <= h.y && abs(z) <= h.z
    }

    static func load(_ meshFolder: URL) -> CropBox? {
        guard let data = try? Data(contentsOf: meshFolder.appendingPathComponent(fileName)) else { return nil }
        return try? JSONDecoder().decode(CropBox.self, from: data)
    }

    func save(_ meshFolder: URL) {
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: meshFolder.appendingPathComponent(CropBox.fileName), options: .atomic)
        }
    }

    static func remove(_ meshFolder: URL) {
        try? FileManager.default.removeItem(at: meshFolder.appendingPathComponent(fileName))
    }
}

extension MeshGeometry {
    var isEmpty: Bool { indices.count < 3 }

    /// Tiene (o toglie) i triangoli il cui baricentro cade nella scatola.
    func cropped(_ box: CropBox) -> MeshGeometry {
        var remap = [Int32](repeating: -1, count: vertices.count)
        var nv: [SIMD3<Float>] = []
        var nc: [SIMD3<Float>] = []
        var ni: [UInt32] = []
        var nk: [UInt8] = []
        let hasClasses = classes.count == indices.count / 3
        let hasColors = colors.count == vertices.count
        var t = 0
        while t + 2 < indices.count {
            let tri = [Int(indices[t]), Int(indices[t + 1]), Int(indices[t + 2])]
            t += 3
            let centroid = (vertices[tri[0]] + vertices[tri[1]] + vertices[tri[2]]) / 3
            if box.contains(centroid) != box.keepInside { continue }
            if hasClasses { nk.append(classes[t / 3 - 1]) }
            for i in tri {
                if remap[i] < 0 {
                    remap[i] = Int32(nv.count)
                    nv.append(vertices[i])
                    if hasColors { nc.append(colors[i]) }
                }
                ni.append(UInt32(remap[i]))
            }
        }
        return MeshGeometry(vertices: nv, colors: nc, indices: ni, classes: nk)
    }

    /// Geometria con i colori delle foto (come l'anteprima salvata).
    func coloredGeometry() -> SCNGeometry {
        var sources = [SCNGeometrySource(vertices: vertices.map { SCNVector3($0.x, $0.y, $0.z) })]
        if colors.count == vertices.count {
            var flat = [Float]()
            flat.reserveCapacity(colors.count * 3)
            for c in colors {
                flat.append(c.x)
                flat.append(c.y)
                flat.append(c.z)
            }
            let data = flat.withUnsafeBufferPointer { Data(buffer: $0) }
            sources.append(SCNGeometrySource(data: data, semantic: .color, vectorCount: colors.count,
                                             usesFloatComponents: true, componentsPerVector: 3,
                                             bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0,
                                             dataStride: MemoryLayout<Float>.size * 3))
        }
        let geometry = SCNGeometry(sources: sources,
                                   elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.isDoubleSided = true
        material.diffuse.contents = UIColor.white
        geometry.materials = [material]
        return geometry
    }
}
