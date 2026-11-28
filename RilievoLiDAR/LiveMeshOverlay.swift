import ARKit
import SceneKit
import UIKit
import simd

/// Posa di una foto già salvata, per sapere quali zone della mesh sono coperte.
struct CamPose {
    let worldToCam: simd_float4x4
    let position: SIMD3<Float>
    let fx: Float
    let fy: Float
    let cx: Float
    let cy: Float
    let width: Float
    let height: Float

    init(_ kf: KeyframeRecord) {
        let t = simd_float4x4(floatArray: kf.transform)
        worldToCam = t.inverse
        position = t.translation
        fx = kf.intrinsics[0]
        fy = kf.intrinsics[4]
        cx = kf.intrinsics[6]
        cy = kf.intrinsics[7]
        width = Float(kf.width)
        height = Float(kf.height)
    }

    /// Il punto è ripreso da questa foto: davanti, a distanza utile, dentro l'inquadratura e ben orientato.
    @inline(__always)
    func sees(_ p: SIMD3<Float>, normal n: SIMD3<Float>) -> Bool {
        let toCam = position - p
        let dist = simd_length(toCam)
        if dist < 0.15 || dist > 4 { return false }
        if simd_dot(n, toCam / dist) < 0.2 { return false }
        let c = worldToCam * SIMD4<Float>(p.x, p.y, p.z, 1)
        let z = -c.z
        if z < 0.1 { return false }
        let u = fx * c.x / z + cx
        let v = fy * (-c.y) / z + cy
        let mx = width * 0.03
        let my = height * 0.03
        return u > mx && v > my && u < width - mx && v < height - my
    }
}

/// Copia dei dati di un blocco di mesh di ARKit (i buffer originali cambiano durante la scansione).
private struct MeshChunk {
    var vertices: [SIMD3<Float>] = []   // coordinate locali del blocco
    var normals: [SIMD3<Float>] = []
    var faces: [UInt32] = []
    var transform = matrix_identity_float4x4

    init(_ anchor: ARMeshAnchor) {
        let g = anchor.geometry
        transform = anchor.transform
        vertices = MeshChunk.read3(g.vertices)
        normals = MeshChunk.read3(g.normals)
        let f = g.faces
        let base = f.buffer.contents()
        let total = f.count * f.indexCountPerPrimitive
        faces.reserveCapacity(total)
        for i in 0..<total {
            if f.bytesPerIndex == 4 {
                faces.append(base.advanced(by: i * 4).assumingMemoryBound(to: UInt32.self).pointee)
            } else {
                faces.append(UInt32(base.advanced(by: i * 2).assumingMemoryBound(to: UInt16.self).pointee))
            }
        }
    }

    static func read3(_ s: ARGeometrySource) -> [SIMD3<Float>] {
        var out: [SIMD3<Float>] = []
        out.reserveCapacity(s.count)
        let base = s.buffer.contents()
        for i in 0..<s.count {
            let p = base.advanced(by: s.offset + s.stride * i).assumingMemoryBound(to: Float.self)
            out.append(SIMD3<Float>(p[0], p[1], p[2]))
        }
        return out
    }

    /// Copertura incrementale: i vertici già coperti restano coperti; quelli scoperti si confrontano
    /// solo con le foto nuove (da `from`) e solo con quelle abbastanza vicine al blocco.
    func coverage(poses: [CamPose], previous: [Bool], from: Int) -> [Bool] {
        let n = vertices.count
        let reuse = previous.count == n
        var covered = reuse ? previous : [Bool](repeating: false, count: n)
        let start = reuse ? min(from, poses.count) : 0
        if start >= poses.count || n == 0 { return covered }

        // Sfera che contiene il blocco, per scartare subito le foto lontane
        var center = SIMD3<Float>(0, 0, 0)
        for v in vertices { center += v }
        center /= Float(n)
        var radius: Float = 0
        for v in vertices { radius = max(radius, simd_distance(v, center)) }
        let c4 = transform * SIMD4<Float>(center.x, center.y, center.z, 1)
        let worldCenter = SIMD3<Float>(c4.x, c4.y, c4.z)
        var relevant: [CamPose] = []
        var k = poses.count - 1
        while k >= start {   // prima le foto più recenti
            if simd_distance(poses[k].position, worldCenter) < radius + 4.1 { relevant.append(poses[k]) }
            k -= 1
        }
        if relevant.isEmpty { return covered }

        let rot = simd_float3x3(SIMD3<Float>(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
                                SIMD3<Float>(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
                                SIMD3<Float>(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z))
        for i in 0..<n where !covered[i] {
            let w4 = transform * SIMD4<Float>(vertices[i].x, vertices[i].y, vertices[i].z, 1)
            let w = SIMD3<Float>(w4.x, w4.y, w4.z)
            let nw = i < normals.count ? simd_normalize(rot * normals[i]) : SIMD3<Float>(0, 1, 0)
            for pose in relevant where pose.sees(w, normal: nw) {
                covered[i] = true
                break
            }
        }
        return covered
    }

    /// Griglia + zone scoperte (nodo principale) e superficie invisibile che nasconde ciò che sta dietro.
    func geometry(covered: [Bool], coverage: Bool) -> (SCNGeometry?, SCNGeometry?) {
        guard !vertices.isEmpty, faces.count >= 3 else { return (nil, nil) }
        var lines: [UInt32] = []
        lines.reserveCapacity(faces.count * 2)
        var fill: [UInt32] = []
        var t = 0
        while t + 2 < faces.count {
            let a = faces[t], b = faces[t + 1], c = faces[t + 2]
            t += 3
            lines.append(contentsOf: [a, b, b, c, c, a])
            if coverage && covered.count == vertices.count {
                var missing = 0
                if !covered[Int(a)] { missing += 1 }
                if !covered[Int(b)] { missing += 1 }
                if !covered[Int(c)] { missing += 1 }
                if missing >= 2 { fill.append(contentsOf: [a, b, c]) }
            }
        }
        let source = SCNGeometrySource(vertices: vertices.map { SCNVector3($0.x, $0.y, $0.z) })
        var elements = [SCNGeometryElement(indices: lines, primitiveType: .line)]
        var materials = [LiveMeshOverlay.wireMaterial]
        if !fill.isEmpty {
            elements.append(SCNGeometryElement(indices: fill, primitiveType: .triangles))
            materials.append(LiveMeshOverlay.fillMaterial)
        }
        let visible = SCNGeometry(sources: [source], elements: elements)
        visible.materials = materials

        // Superficie spostata di poco all'indietro: scrive solo la profondità, così le linee
        // delle superfici nascoste (dietro ai muri) non si vedono.
        var pushed = vertices
        for i in 0..<pushed.count where i < normals.count {
            pushed[i] -= simd_normalize(normals[i]) * 0.012
        }
        let occSource = SCNGeometrySource(vertices: pushed.map { SCNVector3($0.x, $0.y, $0.z) })
        let occluder = SCNGeometry(sources: [occSource], elements: [SCNGeometryElement(indices: faces, primitiveType: .triangles)])
        occluder.materials = [LiveMeshOverlay.occluderMaterial]
        return (visible, occluder)
    }
}

/// Disegno della mesh durante la scansione, nello stile di Polycam:
/// griglia bianca sottile + zone ancora da riprendere in fucsia.
final class LiveMeshOverlay: NSObject, ARSCNViewDelegate {
    /// Fucsia: quasi assente negli ambienti reali, si distingue da muri, legno, cielo e pavimenti.
    static let fillColor = UIColor(red: 1.0, green: 0.16, blue: 0.62, alpha: 1)

    static let wireMaterial: SCNMaterial = {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = UIColor(white: 1, alpha: 0.55)
        m.isDoubleSided = true
        m.writesToDepthBuffer = false
        m.readsFromDepthBuffer = true
        return m
    }()

    static let fillMaterial: SCNMaterial = {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = fillColor.withAlphaComponent(0.42)
        m.isDoubleSided = true
        m.writesToDepthBuffer = false
        m.readsFromDepthBuffer = true
        return m
    }()

    static let occluderMaterial: SCNMaterial = {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.colorBufferWriteMask = []
        m.writesToDepthBuffer = true
        m.readsFromDepthBuffer = true
        m.isDoubleSided = true
        return m
    }()

    private struct Entry {
        weak var node: SCNNode?
        var anchor: ARMeshAnchor
        var dirty = true
        var builtVersion = -1
        var builtAt: TimeInterval = 0
        var building = false
        var covered: [Bool] = []
        var posesChecked = 0
    }

    private let lock = NSLock()
    private var poses: [CamPose] = []
    private var coverage = false
    private var version = 0
    private var entries: [UUID: Entry] = [:]
    private var inFlight = 0
    private let work = DispatchQueue(label: "rilievo.overlay", qos: .userInitiated, attributes: .concurrent)

    /// Aggiorna le foto salvate; coverage = evidenzia le zone non ancora riprese.
    func setPoses(_ newPoses: [CamPose], coverage on: Bool) {
        lock.lock()
        if newPoses.count < poses.count || on != coverage {
            // Nuova scansione: si ricomincia da zero
            for id in entries.keys {
                entries[id]?.covered = []
                entries[id]?.posesChecked = 0
            }
        }
        poses = newPoses
        coverage = on
        version += 1
        lock.unlock()
    }

    func reset() {
        lock.lock()
        entries.removeAll()
        poses = []
        coverage = false
        version += 1
        lock.unlock()
    }

    // MARK: ARSCNViewDelegate (thread di rendering)

    func renderer(_ renderer: SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode? {
        anchor is ARMeshAnchor ? SCNNode() : nil
    }

    func renderer(_ renderer: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor) {
        guard let mesh = anchor as? ARMeshAnchor else { return }
        lock.lock()
        entries[anchor.identifier] = Entry(node: node, anchor: mesh)
        lock.unlock()
    }

    func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
        guard let mesh = anchor as? ARMeshAnchor else { return }
        lock.lock()
        if var e = entries[anchor.identifier] {
            e.anchor = mesh
            e.node = node
            e.dirty = true
            entries[anchor.identifier] = e
        } else {
            entries[anchor.identifier] = Entry(node: node, anchor: mesh)
        }
        lock.unlock()
    }

    func renderer(_ renderer: SCNSceneRenderer, didRemove node: SCNNode, for anchor: ARAnchor) {
        lock.lock()
        entries[anchor.identifier] = nil
        lock.unlock()
    }

    /// Ogni fotogramma ricostruisce pochi blocchi alla volta, così la visualizzazione resta fluida.
    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        let maxInFlight = 3
        guard inFlight < maxInFlight else { return }
        let now = CACurrentMediaTime()
        var candidates: [(UUID, Entry)] = []
        for (id, e) in entries where e.node != nil && !e.building {
            if (e.dirty || e.builtVersion != version) && now - e.builtAt > 0.3 { candidates.append((id, e)) }
        }
        // Prima i blocchi aggiornati da più tempo
        candidates.sort { $0.1.builtAt < $1.1.builtAt }
        for (id, e) in candidates.prefix(maxInFlight - inFlight) {
            guard let node = e.node else { continue }
            let chunk = MeshChunk(e.anchor)
            let posesCopy = poses
            let cov = coverage
            // Se il numero di vertici del blocco è cambiato, la copertura si ricalcola per tutti i vertici
            let previous = e.covered.count == chunk.vertices.count ? e.covered : []
            let from = previous.isEmpty ? 0 : e.posesChecked
            var updated = e
            updated.builtAt = now
            updated.builtVersion = version
            updated.dirty = false
            updated.building = true
            entries[id] = updated
            inFlight += 1
            work.async { [weak self] in
                let covered = cov ? chunk.coverage(poses: posesCopy, previous: previous, from: from)
                                  : [Bool](repeating: true, count: chunk.vertices.count)
                let (visible, occluder) = chunk.geometry(covered: covered, coverage: cov)
                DispatchQueue.main.async {
                    node.geometry = visible
                    node.childNode(withName: "occ", recursively: false)?.removeFromParentNode()
                    if let occluder {
                        let occ = SCNNode(geometry: occluder)
                        occ.name = "occ"
                        occ.renderingOrder = -10
                        node.addChildNode(occ)
                    }
                    guard let self else { return }
                    self.lock.lock()
                    if var cur = self.entries[id] {
                        cur.building = false
                        cur.covered = covered
                        cur.posesChecked = posesCopy.count
                        self.entries[id] = cur
                    }
                    self.inFlight -= 1
                    self.lock.unlock()
                }
            }
        }
    }
}
