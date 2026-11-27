import SwiftUI
import UIKit
import ARKit
import simd

// MARK: - Dati di ripresa di una foto (posizione, direzione, punto inquadrato)

enum PhotoAim {
    /// Direzione (avanti) della fotocamera e punto inquadrato al centro della foto, se c'è la profondità.
    static func from(frame: ARFrame) -> (direction: [Float], target: [Float]?) {
        let t = frame.camera.transform
        let fwd = -SIMD3<Float>(t.columns.2.x, t.columns.2.y, t.columns.2.z)
        var target: [Float]? = nil
        if let depth = (frame.smoothedSceneDepth ?? frame.sceneDepth)?.depthMap {
            CVPixelBufferLockBaseAddress(depth, .readOnly)
            let w = CVPixelBufferGetWidth(depth)
            let h = CVPixelBufferGetHeight(depth)
            if let base = CVPixelBufferGetBaseAddress(depth) {
                let row = base.advanced(by: (h / 2) * CVPixelBufferGetBytesPerRow(depth))
                let d = row.assumingMemoryBound(to: Float32.self)[w / 2]
                if d > 0.1 && d < 10 {
                    let p = t * SIMD4<Float>(0, 0, -d, 1)
                    target = [p.x, p.y, p.z]
                }
            }
            CVPixelBufferUnlockBaseAddress(depth, .readOnly)
        }
        return ([fwd.x, fwd.y, fwd.z], target)
    }

    static func parseMeters(_ s: String) -> Float? {
        let clean = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let v = Float(clean), v > 0 else { return nil }
        return v
    }

    static func text(_ v: Float?) -> String {
        guard let v else { return "" }
        return Fmt.m(v)
    }
}

extension PhotoRecord {
    /// "Cucina · piano 1°" (vuoto se non indicati).
    var placeText: String? {
        let r = (room ?? "").trimmingCharacters(in: .whitespaces)
        let l = (level ?? "").trimmingCharacters(in: .whitespaces)
        switch (r.isEmpty, l.isEmpty) {
        case (false, false): return "\(r) · piano \(l)"
        case (false, true): return r
        case (true, false): return "Piano \(l)"
        default: return nil
        }
    }

    /// Testo breve per la galleria: vano e nota.
    var caption: String {
        [placeText, note.isEmpty ? nil : note].compactMap { $0 }.joined(separator: " – ")
    }

    /// "L 3,20 × H 2,70" se la foto ha misure.
    var measuresText: String? {
        switch (width, height) {
        case let (w?, h?): return "L \(Fmt.m(w)) × H \(Fmt.m(h)) m"
        case let (w?, nil): return "L \(Fmt.m(w)) m"
        case let (nil, h?): return "H \(Fmt.m(h)) m"
        default: return nil
        }
    }
}

// MARK: - Segnaposto foto nella pianta

extension PhotoMarker {
    /// Costruisce il segnaposto in coordinate di pianta (metri) con la funzione di proiezione data.
    static func from(number: Int, record r: PhotoRecord, plan: (SIMD3<Float>) -> SIMD2<Float>) -> PhotoMarker? {
        guard r.position.count == 3 else { return nil }
        let pos = SIMD3<Float>(r.position[0], r.position[1], r.position[2])
        var m = PhotoMarker(number: number, point: plan(pos))
        if let d = r.direction, d.count == 3 {
            let fwd = SIMD3<Float>(d[0], d[1], d[2])
            let v = plan(pos + fwd) - m.point
            // Foto verso il pavimento o il soffitto: niente direzione in pianta
            if simd_length(v) > 0.3 { m.dir = simd_normalize(v) }
        }
        if let t = r.target, t.count == 3 { m.target = plan(SIMD3<Float>(t[0], t[1], t[2])) }
        m.width = r.width
        m.height = r.height
        return m
    }
}

enum PhotoMarkerDrawing {
    static let red = UIColor(red: 0.91, green: 0.13, blue: 0.16, alpha: 1)
    static let blue = UIColor(red: 0.05, green: 0.3, blue: 0.85, alpha: 1)

    /// Primo muro incontrato dal raggio di ripresa: punto e direzione del muro.
    static func rayHit(from o: SIMD2<Float>, dir d: SIMD2<Float>,
                       segments: [(SIMD2<Float>, SIMD2<Float>)], maxDist: Float = 15) -> (SIMD2<Float>, SIMD2<Float>)? {
        var best: Float = maxDist
        var hit: (SIMD2<Float>, SIMD2<Float>)?
        for (a, b) in segments {
            let e = b - a
            let den = d.x * e.y - d.y * e.x
            if abs(den) < 1e-8 { continue }
            let ao = a - o
            let t = (ao.x * e.y - ao.y * e.x) / den
            let u = (ao.x * d.y - ao.y * d.x) / den
            if t > 0.05 && t < best && u >= 0 && u <= 1 {
                best = t
                let len = simd_length(e)
                hit = (o + d * t, len > 1e-6 ? e / len : SIMD2<Float>(-d.y, d.x))
            }
        }
        return hit
    }

    /// Disegna coni di ripresa, quote delle note e pallini numerati.
    /// pageScale = punti di pagina per metro.
    static func draw(_ markers: [PhotoMarker], segments: [(SIMD2<Float>, SIMD2<Float>)],
                     toPage: (SIMD2<Float>) -> CGPoint, pageScale: CGFloat, in cg: CGContext) {
        // 1. Coni di visuale (sotto a tutto)
        for m in markers {
            guard let d = m.dir else { continue }
            let c = toPage(m.point)
            let tip = toPage(m.point + d)
            var v = CGVector(dx: tip.x - c.x, dy: tip.y - c.y)
            let l = max(sqrt(v.dx * v.dx + v.dy * v.dy), 0.001)
            v = CGVector(dx: v.dx / l, dy: v.dy / l)
            let len: CGFloat = 24
            let half: CGFloat = 0.5   // circa ±29°
            func rot(_ a: CGFloat) -> CGPoint {
                CGPoint(x: c.x + (v.dx * cos(a) - v.dy * sin(a)) * len, y: c.y + (v.dx * sin(a) + v.dy * cos(a)) * len)
            }
            cg.saveGState()
            cg.move(to: c)
            cg.addLine(to: rot(-half))
            cg.addQuadCurve(to: rot(half), control: CGPoint(x: c.x + v.dx * len * 1.15, y: c.y + v.dy * len * 1.15))
            cg.closePath()
            cg.setFillColor(red.withAlphaComponent(0.28).cgColor)
            cg.setStrokeColor(red.cgColor)
            cg.setLineWidth(0.8)
            cg.drawPath(using: .fillStroke)
            cg.restoreGState()
        }

        // 2. Misure scritte nella nota, sul muro inquadrato
        for m in markers where m.width != nil || m.height != nil {
            var at: SIMD2<Float>?
            var wallDir: SIMD2<Float>?
            if let d = m.dir, let h = rayHit(from: m.point, dir: d, segments: segments) {
                at = h.0
                wallDir = h.1
            } else if let t = m.target {
                at = t
                if let d = m.dir { wallDir = SIMD2<Float>(-d.y, d.x) }
            }
            guard let p = at else { continue }
            let hp = toPage(p)
            // Linea tratteggiata dal punto di ripresa al muro
            cg.saveGState()
            cg.setStrokeColor(red.withAlphaComponent(0.7).cgColor)
            cg.setLineWidth(0.5)
            cg.setLineDash(phase: 0, lengths: [2, 2])
            cg.move(to: toPage(m.point))
            cg.addLine(to: hp)
            cg.strokePath()
            cg.restoreGState()

            var labelPoint = hp
            if let w = m.width, let wd = wallDir {
                let a = toPage(p - wd * (w / 2))
                let b = toPage(p + wd * (w / 2))
                var n = CGVector(dx: -(b.y - a.y), dy: b.x - a.x)
                let nl = max(sqrt(n.dx * n.dx + n.dy * n.dy), 0.001)
                n = CGVector(dx: n.dx / nl * 4, dy: n.dy / nl * 4)
                cg.saveGState()
                cg.setStrokeColor(blue.cgColor)
                cg.setLineWidth(1.3)
                cg.move(to: a)
                cg.addLine(to: b)
                for e in [a, b] {
                    cg.move(to: CGPoint(x: e.x - n.dx, y: e.y - n.dy))
                    cg.addLine(to: CGPoint(x: e.x + n.dx, y: e.y + n.dy))
                }
                cg.strokePath()
                cg.restoreGState()
                // Etichetta dal lato del punto di ripresa
                let cp = toPage(m.point)
                let side: CGFloat = ((cp.x - hp.x) * n.dx + (cp.y - hp.y) * n.dy) >= 0 ? 1 : -1
                labelPoint = CGPoint(x: hp.x + n.dx * 2.6 * side, y: hp.y + n.dy * 2.6 * side)
            }
            var parts: [String] = []
            if let w = m.width { parts.append("L \(Fmt.m(w))") }
            if let h = m.height { parts.append("H \(Fmt.m(h))") }
            let text = "\(m.number): " + parts.joined(separator: " × ")
            let attr: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 7), .foregroundColor: blue]
            let str = NSAttributedString(string: text, attributes: attr)
            let sz = str.size()
            let box = CGRect(x: labelPoint.x - sz.width / 2 - 2, y: labelPoint.y - sz.height / 2 - 1,
                             width: sz.width + 4, height: sz.height + 2)
            cg.saveGState()
            cg.setFillColor(UIColor.white.withAlphaComponent(0.85).cgColor)
            cg.fill(box)
            cg.restoreGState()
            str.draw(at: CGPoint(x: box.minX + 2, y: box.minY + 1))
        }

        // 3. Pallini numerati ad alto contrasto (contorno scuro + bordo bianco + rosso)
        for m in markers {
            let c = toPage(m.point)
            let r: CGFloat = 7
            cg.saveGState()
            cg.setFillColor(UIColor.black.withAlphaComponent(0.75).cgColor)
            cg.fillEllipse(in: CGRect(x: c.x - r - 1.8, y: c.y - r - 1.8, width: 2 * r + 3.6, height: 2 * r + 3.6))
            cg.setFillColor(UIColor.white.cgColor)
            cg.fillEllipse(in: CGRect(x: c.x - r - 1.3, y: c.y - r - 1.3, width: 2 * r + 2.6, height: 2 * r + 2.6))
            cg.setFillColor(red.cgColor)
            cg.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            cg.restoreGState()
            PlanPDF.drawCentered("\(m.number)", at: c, angle: 0, size: 7, bold: true, color: .white, in: cg)
        }
    }
}

// MARK: - Modulo nota foto (più righe + misure)

struct PhotoNoteForm: View {
    @Binding var note: String
    @Binding var width: String
    @Binding var height: String
    @Binding var room: String
    @Binding var level: String
    let message: String
    let onSave: () -> Void
    let onSkip: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("Vano")
                        TextField("es. Cucina", text: $room)
                            .multilineTextAlignment(.trailing)
                    }
                    HStack {
                        Text("Piano")
                        TextField("es. Terra, 1°", text: $level)
                            .multilineTextAlignment(.trailing)
                    }
                } header: {
                    Text("Dove")
                } footer: {
                    Text("Vano e piano restano proposti per le foto successive.")
                }
                Section {
                    TextField("Nota (es. parete nord, finestra bagno…)", text: $note, axis: .vertical)
                        .lineLimit(3...8)
                } footer: {
                    Text(message)
                }
                Section {
                    HStack {
                        Text("Larghezza")
                        TextField("metri", text: $width)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                        Text("m").foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Altezza")
                        TextField("metri", text: $height)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                        Text("m").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Misure (facoltative)")
                } footer: {
                    Text("Nella pianta la quota viene disegnata sul muro verso cui puntava la foto.")
                }
            }
            .navigationTitle("Nota per la foto")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Salta") {
                        onSkip()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salva") {
                        onSave()
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
