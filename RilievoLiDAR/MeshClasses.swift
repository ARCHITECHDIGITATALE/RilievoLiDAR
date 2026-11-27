import Foundation
import UIKit
import ARKit
import simd

/// Classi di ARKit (ARMeshClassification) per ogni triangolo della mesh.
enum MeshClass {
    static let none: UInt8 = 0
    static let wall: UInt8 = 1
    static let floor: UInt8 = 2
    static let ceiling: UInt8 = 3
    static let table: UInt8 = 4
    static let seat: UInt8 = 5
    static let window: UInt8 = 6
    static let door: UInt8 = 7

    static let fileName = "classi.bin"

    /// Triangoli che fanno parte dei muri nella pianta (non arredi, porte, finestre, pavimento, soffitto).
    static func isWall(_ c: UInt8) -> Bool { c == wall || c == none }
    static func isFurniture(_ c: UInt8) -> Bool { c == table || c == seat }

    /// Legge la classe di ogni faccia di un blocco di ARKit (vuoto se la classificazione non è attiva).
    static func read(_ geometry: ARMeshGeometry) -> [UInt8] {
        guard let src = geometry.classification else { return [] }
        let base = src.buffer.contents()
        var out = [UInt8](repeating: 0, count: src.count)
        for i in 0..<src.count {
            out[i] = base.advanced(by: src.offset + src.stride * i).assumingMemoryBound(to: UInt8.self).pointee
        }
        return out
    }

    static func save(_ classes: [UInt8], meshFolder: URL) {
        let url = meshFolder.appendingPathComponent(fileName)
        if classes.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else {
            try? Data(classes).write(to: url)
        }
    }

    static func load(meshFolder: URL, faceCount: Int) -> [UInt8] {
        guard let data = try? Data(contentsOf: meshFolder.appendingPathComponent(fileName)),
              data.count == faceCount else { return [] }
        return [UInt8](data)
    }
}

/// Indice spaziale delle classi della mesh originale di ARKit: serve a riportarle sulla mesh finale
/// (che è stata pulita, chiusa nei buchi e suddivisa, quindi ha triangoli diversi).
struct FaceClassIndex {
    private var cells: [SIMD3<Int32>: SIMD8<UInt16>] = [:]
    private let cell: Float = 0.05

    init?(_ mesh: MeshData) {
        let fCount = mesh.indices.count / 3
        guard mesh.faceClasses.count == fCount, fCount > 0 else { return nil }
        for f in 0..<fCount {
            let c = Int(mesh.faceClasses[f])
            if c > 7 { continue }
            let p = (mesh.vertices[Int(mesh.indices[f * 3])] + mesh.vertices[Int(mesh.indices[f * 3 + 1])]
                     + mesh.vertices[Int(mesh.indices[f * 3 + 2])]) / 3
            let k = key(p)
            var v = cells[k] ?? SIMD8<UInt16>()
            if v[c] < UInt16.max { v[c] += 1 }
            cells[k] = v
        }
    }

    private func key(_ p: SIMD3<Float>) -> SIMD3<Int32> {
        SIMD3<Int32>(Int32((p.x / cell).rounded(.down)), Int32((p.y / cell).rounded(.down)), Int32((p.z / cell).rounded(.down)))
    }

    /// Classe più frequente attorno al punto (0 se non ci sono informazioni).
    func classify(_ p: SIMD3<Float>) -> UInt8 {
        let k = key(p)
        var sum = SIMD8<UInt32>()
        for dz in -1...1 {
            for dy in -1...1 {
                for dx in -1...1 {
                    if let v = cells[k &+ SIMD3<Int32>(Int32(dx), Int32(dy), Int32(dz))] {
                        sum &+= SIMD8<UInt32>(truncatingIfNeeded: v)
                    }
                }
            }
        }
        var best: UInt8 = 0
        var bestCount: UInt32 = 0
        for c in 1..<8 where sum[c] > bestCount {
            best = UInt8(c)
            bestCount = sum[c]
        }
        return bestCount > 0 ? best : 0
    }

    func classify(vertices: [SIMD3<Float>], indices: [UInt32], floorY: Float?) -> [UInt8] {
        let fCount = indices.count / 3
        var out = [UInt8](repeating: 0, count: fCount)
        for f in 0..<fCount {
            let a = vertices[Int(indices[f * 3])], b = vertices[Int(indices[f * 3 + 1])], c = vertices[Int(indices[f * 3 + 2])]
            var cls = classify((a + b + c) / 3)
            // Pavimento ricostruito sotto i mobili: nessuna classe vicina, ma è pavimento
            if cls == 0, let fy = floorY {
                let n = simd_cross(b - a, c - a)
                let l = simd_length(n)
                if l > 1e-10, n.y / l > 0.9, abs((a.y + b.y + c.y) / 3 - fy) < 0.03 { cls = MeshClass.floor }
            }
            out[f] = cls
        }
        return out
    }
}

extension MeshGeometry {
    /// Sezione orizzontale solo dei triangoli che soddisfano il filtro di classe
    /// (senza classi disponibili si usano tutti i triangoli per "muri", nessuno per gli altri).
    func section(at h: Float, where include: (UInt8) -> Bool, defaultIncluded: Bool) -> [(SIMD3<Float>, SIMD3<Float>)] {
        let hasClasses = classes.count == indices.count / 3
        if !hasClasses && !defaultIncluded { return [] }
        var segments: [(SIMD3<Float>, SIMD3<Float>)] = []
        var t = 0
        while t + 2 < indices.count {
            let f = t / 3
            let a = vertices[Int(indices[t])]
            let b = vertices[Int(indices[t + 1])]
            let c = vertices[Int(indices[t + 2])]
            t += 3
            if hasClasses && !include(classes[f]) { continue }
            let da = a.y - h, db = b.y - h, dc = c.y - h
            if (da > 0 && db > 0 && dc > 0) || (da < 0 && db < 0 && dc < 0) { continue }
            var pts: [SIMD3<Float>] = []
            if (da > 0) != (db > 0) { pts.append(a + (b - a) * (da / (da - db))) }
            if (db > 0) != (dc > 0) { pts.append(b + (c - b) * (db / (db - dc))) }
            if (dc > 0) != (da > 0) { pts.append(c + (a - c) * (dc / (dc - da))) }
            if pts.count >= 2 { segments.append((pts[0], pts[1])) }
        }
        return segments
    }
}

// MARK: - Porte e finestre riconosciute

struct MeshOpening {
    var isDoor: Bool
    var a: SIMD2<Float>      // estremi in pianta (metri, già in scala)
    var b: SIMD2<Float>
    var width: Float
    var height: Float
    var bottom: Float        // parapetto (dal pavimento)

    var label: String {
        isDoor ? "P \(Fmt.m(width))×\(Fmt.m(height))"
               : "F \(Fmt.m(width))×\(Fmt.m(height)) p.\(Fmt.m(bottom))"
    }
}

extension MeshPlanExport {
    static func wallSection(_ d: Loaded) -> [(SIMD3<Float>, SIMD3<Float>)] {
        d.geometry.section(at: d.sectionY, where: MeshClass.isWall, defaultIncluded: true)
    }

    static func furnitureSection(_ d: Loaded) -> [(SIMD3<Float>, SIMD3<Float>)] {
        // Gli arredi sono più bassi della quota della pianta: si tagliano a metà della loro altezza tipica
        let h = d.floorY + 0.6
        return d.geometry.section(at: h, where: MeshClass.isFurniture, defaultIncluded: false)
    }

    /// Raggruppa i triangoli "porta" e "finestra" vicini e ne ricava larghezza, altezza e posizione.
    static func openings(_ d: Loaded) -> [MeshOpening] {
        let g = d.geometry
        let fCount = g.indices.count / 3
        guard g.classes.count == fCount else { return [] }
        let cellSize: Float = 0.12
        var cellFaces: [SIMD3<Int32>: [Int]] = [:]
        var cellClass: [SIMD3<Int32>: UInt8] = [:]
        for f in 0..<fCount {
            let c = g.classes[f]
            guard c == MeshClass.door || c == MeshClass.window else { continue }
            let p = (g.vertices[Int(g.indices[f * 3])] + g.vertices[Int(g.indices[f * 3 + 1])]
                     + g.vertices[Int(g.indices[f * 3 + 2])]) / 3
            let k = SIMD3<Int32>(Int32((p.x / cellSize).rounded(.down)), Int32((p.y / cellSize).rounded(.down)),
                                 Int32((p.z / cellSize).rounded(.down)))
            // Chiave separata per classe, così porte e finestre vicine non si uniscono
            let kk = SIMD3<Int32>(k.x, k.y, k.z &* 2 &+ (c == MeshClass.door ? 1 : 0))
            cellFaces[kk, default: []].append(f)
            cellClass[kk] = c
        }
        var visited = Set<SIMD3<Int32>>()
        var result: [MeshOpening] = []
        let s = d.scale
        for start in cellFaces.keys where !visited.contains(start) {
            let cls = cellClass[start]!
            let parity = cls == MeshClass.door ? Int32(1) : Int32(0)
            var stack = [start]
            visited.insert(start)
            var faces: [Int] = []
            while let k = stack.popLast() {
                faces += cellFaces[k] ?? []
                let realZ = (k.z &- parity) / 2
                for dz in -1...1 {
                    for dy in -1...1 {
                        for dx in -1...1 {
                            let nz = (realZ &+ Int32(dz)) &* 2 &+ parity
                            let n = SIMD3<Int32>(k.x &+ Int32(dx), k.y &+ Int32(dy), nz)
                            if cellFaces[n] != nil && !visited.contains(n) {
                                visited.insert(n)
                                stack.append(n)
                            }
                        }
                    }
                }
            }
            // Area e punti
            var area: Float = 0
            var pts: [SIMD3<Float>] = []
            for f in faces {
                let a = g.vertices[Int(g.indices[f * 3])], b = g.vertices[Int(g.indices[f * 3 + 1])],
                    c = g.vertices[Int(g.indices[f * 3 + 2])]
                area += simd_length(simd_cross(b - a, c - a)) * 0.5
                pts += [a, b, c]
            }
            if area < 0.2 { continue }
            // Direzione principale in pianta (analisi delle componenti principali)
            let p2 = pts.map { plan($0, s) }
            var mean = SIMD2<Float>(0, 0)
            for p in p2 { mean += p }
            mean /= Float(p2.count)
            var sxx: Float = 0, sxy: Float = 0, syy: Float = 0
            for p in p2 {
                let q = p - mean
                sxx += q.x * q.x
                sxy += q.x * q.y
                syy += q.y * q.y
            }
            let angle = 0.5 * atan2(2 * sxy, sxx - syy)
            let u = SIMD2<Float>(cos(angle), sin(angle))
            var tMin = Float.greatestFiniteMagnitude, tMax = -Float.greatestFiniteMagnitude
            for p in p2 {
                let t = simd_dot(p - mean, u)
                tMin = min(tMin, t)
                tMax = max(tMax, t)
            }
            let width = tMax - tMin
            if width < 0.3 || width > 4 { continue }
            var yMin = Float.greatestFiniteMagnitude, yMax = -Float.greatestFiniteMagnitude
            for p in pts {
                yMin = min(yMin, p.y)
                yMax = max(yMax, p.y)
            }
            let isDoor = cls == MeshClass.door
            result.append(MeshOpening(isDoor: isDoor, a: mean + u * tMin, b: mean + u * tMax, width: width,
                                      height: (yMax - yMin) * s, bottom: max(0, (yMin - d.floorY) * s)))
        }
        return result.sorted { ($0.isDoor ? 0 : 1, $0.a.x) < ($1.isDoor ? 0 : 1, $1.a.x) }
    }

    /// Disegna porte e finestre come aperture nel muro, con l'etichetta delle misure.
    static func drawOpenings(_ openings: [MeshOpening], toPage: (SIMD2<Float>) -> CGPoint, in cg: CGContext) {
        let brown = UIColor(red: 0.55, green: 0.33, blue: 0.1, alpha: 1)
        let blue = UIColor(red: 0.1, green: 0.35, blue: 0.85, alpha: 1)
        for o in openings {
            let pa = toPage(o.a), pb = toPage(o.b)
            let color = o.isDoor ? brown : blue
            cg.saveGState()
            cg.setLineCap(.butt)
            cg.setStrokeColor(UIColor.white.cgColor)
            cg.setLineWidth(5)
            cg.move(to: pa)
            cg.addLine(to: pb)
            cg.strokePath()
            cg.setStrokeColor(color.cgColor)
            cg.setLineWidth(o.isDoor ? 1.5 : 2)
            cg.move(to: pa)
            cg.addLine(to: pb)
            cg.strokePath()
            if o.isDoor {
                // Arco di apertura della porta
                let r = hypot(pb.x - pa.x, pb.y - pa.y)
                let a0 = atan2(pb.y - pa.y, pb.x - pa.x)
                cg.setLineWidth(0.5)
                cg.setLineDash(phase: 0, lengths: [2, 2])
                cg.addArc(center: pa, radius: r, startAngle: a0, endAngle: a0 - .pi / 2, clockwise: true)
                cg.strokePath()
            }
            cg.restoreGState()
            let dx = pb.x - pa.x, dy = pb.y - pa.y
            let len = max(hypot(dx, dy), 0.001)
            var angle = atan2(dy, dx)
            if angle > .pi / 2 { angle -= .pi } else if angle < -.pi / 2 { angle += .pi }
            let mid = CGPoint(x: (pa.x + pb.x) / 2 + dy / len * 9, y: (pa.y + pb.y) / 2 - dx / len * 9)
            PlanPDF.drawCentered(o.label, at: mid, angle: angle, size: 6, color: color, in: cg)
        }
    }
}
