import Foundation
import RoomPlan
import UIKit
import simd

// MARK: - Dati della pianta (coordinate in metri, X a destra, Y verso "nord" = -Z del mondo)

struct PlanSegment {
    enum Kind { case wall, door, window, opening }
    var kind: Kind
    var a: SIMD2<Float>
    var b: SIMD2<Float>
    var width: Float
    var height: Float
    var bottom: Float      // quota dal pavimento (parapetto per le finestre)
}

struct PlanObject {
    var name: String
    var corners: [SIMD2<Float>]
    var size: SIMD3<Float>  // larghezza, altezza, profondità
    var center: SIMD2<Float>
}

struct RoomPlanData {
    var name: String
    var walls: [PlanSegment]
    var doors: [PlanSegment]
    var windows: [PlanSegment]
    var openings: [PlanSegment]
    var objects: [PlanObject]
    var area: Float
    var perimeter: Float
    var height: Float
    var center: SIMD2<Float>
    var path: [SIMD2<Float>]   // percorso dell'operatore

    var allPoints: [SIMD2<Float>] {
        var pts: [SIMD2<Float>] = []
        for s in walls + doors + windows + openings {
            pts.append(s.a)
            pts.append(s.b)
        }
        for o in objects { pts.append(contentsOf: o.corners) }
        pts.append(contentsOf: path)
        return pts
    }
}

struct PhotoMarker {
    var number: Int
    var point: SIMD2<Float>
    var dir: SIMD2<Float>? = nil      // direzione di ripresa in pianta
    var target: SIMD2<Float>? = nil   // punto inquadrato in pianta
    var width: Float? = nil
    var height: Float? = nil
}

enum PlanBuilder {
    static let objectNames: [String: String] = [
        "storage": "Mobile", "refrigerator": "Frigorifero", "stove": "Piano cottura",
        "bed": "Letto", "sink": "Lavello", "washerDryer": "Lavatrice", "toilet": "WC",
        "bathtub": "Vasca", "oven": "Forno", "dishwasher": "Lavastoviglie", "table": "Tavolo",
        "sofa": "Divano", "chair": "Sedia", "fireplace": "Camino", "television": "TV",
        "stairs": "Scale"
    ]

    static func plan(_ p: SIMD3<Float>) -> SIMD2<Float> {
        SIMD2<Float>(p.x, -p.z)
    }

    static func data(for room: CapturedRoom, name: String, path: [Float] = []) -> RoomPlanData {
        let wallBottoms = room.walls.map { $0.transform.columns.3.y - $0.dimensions.y / 2 }
        let floorY: Float = room.floors.first?.transform.columns.3.y ?? (wallBottoms.min() ?? 0)

        func segment(_ s: CapturedRoom.Surface, _ kind: PlanSegment.Kind) -> PlanSegment {
            let t = s.transform
            let c = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
            var dir = SIMD3<Float>(t.columns.0.x, 0, t.columns.0.z)
            dir = simd_length(dir) < 1e-5 ? SIMD3<Float>(1, 0, 0) : simd_normalize(dir)
            let half = s.dimensions.x / 2
            return PlanSegment(kind: kind,
                               a: plan(c - dir * half),
                               b: plan(c + dir * half),
                               width: s.dimensions.x,
                               height: s.dimensions.y,
                               bottom: max(0, c.y - s.dimensions.y / 2 - floorY))
        }

        let walls = room.walls.map { segment($0, .wall) }
        let doors = room.doors.map { segment($0, .door) }
        let windows = room.windows.map { segment($0, .window) }
        let openings = room.openings.map { segment($0, .opening) }

        func planObject(_ o: CapturedRoom.Object) -> PlanObject {
            let t: simd_float4x4 = o.transform
            let c = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
            let halfX: Float = o.dimensions.x / 2
            let halfZ: Float = o.dimensions.z / 2
            let ax: SIMD3<Float> = SIMD3<Float>(t.columns.0.x, t.columns.0.y, t.columns.0.z) * halfX
            let az: SIMD3<Float> = SIMD3<Float>(t.columns.2.x, t.columns.2.y, t.columns.2.z) * halfZ
            let p0: SIMD3<Float> = c - ax - az
            let p1: SIMD3<Float> = c + ax - az
            let p2: SIMD3<Float> = c + ax + az
            let p3: SIMD3<Float> = c - ax + az
            let corners: [SIMD2<Float>] = [plan(p0), plan(p1), plan(p2), plan(p3)]
            let key = String(describing: o.category)
            let label: String = objectNames[key] ?? key
            return PlanObject(name: label, corners: corners, size: o.dimensions, center: plan(c))
        }
        let objects: [PlanObject] = room.objects.map(planObject)

        var area: Float = 0
        if let floor = room.floors.first {
            let pts = floor.polygonCorners
            if pts.count >= 3 {
                var sxy: Float = 0
                var sxz: Float = 0
                for i in 0..<pts.count {
                    let p = pts[i]
                    let q = pts[(i + 1) % pts.count]
                    sxy += p.x * q.y - q.x * p.y
                    sxz += p.x * q.z - q.x * p.z
                }
                area = max(abs(sxy), abs(sxz)) / 2
            } else {
                area = floor.dimensions.x * max(floor.dimensions.y, floor.dimensions.z)
            }
        }

        let perimeter = walls.reduce(0) { $0 + $1.width }
        let height = walls.map { $0.height }.max() ?? 0
        var center = SIMD2<Float>(0, 0)
        if !walls.isEmpty {
            for w in walls { center += (w.a + w.b) / 2 }
            center /= Float(walls.count)
        }

        return RoomPlanData(name: name, walls: walls, doors: doors, windows: windows, openings: openings,
                            objects: objects, area: area, perimeter: perimeter, height: height, center: center,
                            path: planPath(path))
    }

    static func planPath(_ flat: [Float]) -> [SIMD2<Float>] {
        var out: [SIMD2<Float>] = []
        var i = 0
        while i + 2 < flat.count {
            out.append(plan(SIMD3<Float>(flat[i], flat[i + 1], flat[i + 2])))
            i += 3
        }
        return out
    }
}

// MARK: - PDF

enum PlanPDF {
    static let page = CGRect(x: 0, y: 0, width: 842, height: 595) // A4 orizzontale

    static func font(_ size: CGFloat, bold: Bool) -> UIFont {
        bold ? UIFont.boldSystemFont(ofSize: size) : UIFont.systemFont(ofSize: size)
    }

    static func drawText(_ text: String, at point: CGPoint, size: CGFloat, bold: Bool = false,
                         color: UIColor = .black) {
        let attr: [NSAttributedString.Key: Any] = [.font: font(size, bold: bold), .foregroundColor: color]
        NSAttributedString(string: text, attributes: attr).draw(at: point)
    }

    static func drawText(_ text: String, in rect: CGRect, size: CGFloat, color: UIColor = .black) {
        let attr: [NSAttributedString.Key: Any] = [.font: font(size, bold: false), .foregroundColor: color]
        NSAttributedString(string: text, attributes: attr).draw(in: rect)
    }

    static func drawCentered(_ text: String, at center: CGPoint, angle: CGFloat, size: CGFloat,
                             bold: Bool = false, color: UIColor = .black, in cg: CGContext) {
        let attr: [NSAttributedString.Key: Any] = [.font: font(size, bold: bold), .foregroundColor: color]
        let str = NSAttributedString(string: text, attributes: attr)
        let sz = str.size()
        cg.saveGState()
        cg.translateBy(x: center.x, y: center.y)
        cg.rotate(by: angle)
        str.draw(at: CGPoint(x: -sz.width / 2, y: -sz.height / 2))
        cg.restoreGState()
    }

    static func render(projectName: String, rooms: [RoomPlanData], markers: [PhotoMarker],
                       photos: [(number: Int, record: PhotoRecord)], projectFolder: URL, to url: URL) throws {
        let renderer = UIGraphicsPDFRenderer(bounds: page)
        try renderer.writePDF(to: url) { ctx in
            ctx.beginPage()
            drawPlan(ctx.cgContext, title: projectName, rooms: rooms, markers: markers)

            ctx.beginPage()
            let cursor = PDFCursor(ctx)
            drawTables(cursor, title: projectName, rooms: rooms)

            drawPhotos(ctx, photos: photos, folder: projectFolder)
        }
    }

    static func drawPlan(_ cg: CGContext, title: String, rooms: [RoomPlanData], markers: [PhotoMarker]) {
        drawText(title, at: CGPoint(x: 40, y: 24), size: 16, bold: true)
        drawText("Pianta da rilievo LiDAR – \(Fmt.date(Date())) – misure in metri", at: CGPoint(x: 40, y: 46), size: 9,
                 color: .darkGray)

        let pts = rooms.flatMap { $0.allPoints } + markers.map { $0.point }
        guard let first = pts.first else { return }
        var minP = first
        var maxP = first
        for p in pts {
            minP = simd_min(minP, p)
            maxP = simd_max(maxP, p)
        }
        let box = CGRect(x: 50, y: 80, width: page.width - 100, height: page.height - 140)
        let bw = max(CGFloat(maxP.x - minP.x), 0.5)
        let bh = max(CGFloat(maxP.y - minP.y), 0.5)
        let s = min(box.width / bw, box.height / bh)
        let ox = box.minX + (box.width - bw * s) / 2
        let oy = box.minY + (box.height - bh * s) / 2

        func toPage(_ p: SIMD2<Float>) -> CGPoint {
            CGPoint(x: ox + CGFloat(p.x - minP.x) * s, y: oy + CGFloat(maxP.y - p.y) * s)
        }

        func stroke(_ a: SIMD2<Float>, _ b: SIMD2<Float>, width: CGFloat, color: UIColor, dash: [CGFloat] = []) {
            cg.saveGState()
            cg.setStrokeColor(color.cgColor)
            cg.setLineWidth(width)
            cg.setLineCap(.butt)
            if !dash.isEmpty { cg.setLineDash(phase: 0, lengths: dash) }
            cg.move(to: toPage(a))
            cg.addLine(to: toPage(b))
            cg.strokePath()
            cg.restoreGState()
        }

        func label(_ text: String, for seg: PlanSegment, offset: CGFloat, size: CGFloat, color: UIColor) {
            let pa = toPage(seg.a)
            let pb = toPage(seg.b)
            let dx = pb.x - pa.x
            let dy = pb.y - pa.y
            let len = max(sqrt(dx * dx + dy * dy), 0.001)
            var angle = atan2(dy, dx)
            if angle > .pi / 2 { angle -= .pi } else if angle < -.pi / 2 { angle += .pi }
            let mid = CGPoint(x: (pa.x + pb.x) / 2 - dy / len * offset, y: (pa.y + pb.y) / 2 + dx / len * offset)
            drawCentered(text, at: mid, angle: angle, size: size, color: color, in: cg)
        }

        let brown = UIColor(red: 0.55, green: 0.33, blue: 0.1, alpha: 1)
        let blue = UIColor(red: 0.1, green: 0.35, blue: 0.85, alpha: 1)

        for room in rooms {
            // Arredi
            for o in room.objects {
                cg.saveGState()
                cg.setStrokeColor(UIColor.gray.cgColor)
                cg.setLineWidth(0.6)
                if let f = o.corners.first {
                    cg.move(to: toPage(f))
                    for c in o.corners.dropFirst() { cg.addLine(to: toPage(c)) }
                    cg.closePath()
                    cg.strokePath()
                }
                cg.restoreGState()
                drawCentered(o.name, at: toPage(o.center), angle: 0, size: 6, color: .gray, in: cg)
            }
            // Muri
            for w in room.walls {
                stroke(w.a, w.b, width: 3, color: .black)
                label(Fmt.m(w.width), for: w, offset: 9, size: 7, color: .black)
            }
            // Porte, finestre, aperture
            for d in room.doors {
                stroke(d.a, d.b, width: 5, color: .white)
                stroke(d.a, d.b, width: 1.5, color: brown)
                label("P \(Fmt.m(d.width))×\(Fmt.m(d.height))", for: d, offset: -9, size: 6, color: brown)
            }
            for w in room.windows {
                stroke(w.a, w.b, width: 5, color: .white)
                stroke(w.a, w.b, width: 2, color: blue)
                label("F \(Fmt.m(w.width))×\(Fmt.m(w.height)) p.\(Fmt.m(w.bottom))", for: w, offset: -9, size: 6, color: blue)
            }
            for o in room.openings {
                stroke(o.a, o.b, width: 5, color: .white)
                stroke(o.a, o.b, width: 1, color: .gray, dash: [3, 2])
                label("A \(Fmt.m(o.width))", for: o, offset: -9, size: 6, color: .gray)
            }
            // Nome e superficie
            let c = toPage(room.center)
            drawCentered(room.name, at: CGPoint(x: c.x, y: c.y - 6), angle: 0, size: 9, bold: true, in: cg)
            drawCentered("\(Fmt.m(room.area)) m² – h \(Fmt.m(room.height))", at: CGPoint(x: c.x, y: c.y + 6),
                         angle: 0, size: 7, color: .darkGray, in: cg)
        }

        // Percorso dell'operatore
        let orange = UIColor.systemOrange
        for room in rooms where room.path.count > 1 {
            cg.saveGState()
            cg.setStrokeColor(orange.cgColor)
            cg.setLineWidth(1)
            cg.setLineDash(phase: 0, lengths: [4, 3])
            cg.move(to: toPage(room.path[0]))
            for p in room.path.dropFirst() { cg.addLine(to: toPage(p)) }
            cg.strokePath()
            cg.restoreGState()
            let start = toPage(room.path[0])
            cg.saveGState()
            cg.setFillColor(orange.cgColor)
            cg.fillEllipse(in: CGRect(x: start.x - 3, y: start.y - 3, width: 6, height: 6))
            cg.restoreGState()
        }

        // Punti di ripresa delle foto: direzione, misure della nota, numero
        let wallSegments = rooms.flatMap { r in r.walls.map { ($0.a, $0.b) } }
        PhotoMarkerDrawing.draw(markers, segments: wallSegments, toPage: toPage, pageScale: s, in: cg)

        // Scala grafica
        let meters: CGFloat = s >= 25 ? 1 : (s >= 6 ? 5 : 10)
        let barY = page.height - 36
        cg.saveGState()
        cg.setStrokeColor(UIColor.black.cgColor)
        cg.setLineWidth(1.5)
        cg.move(to: CGPoint(x: 50, y: barY))
        cg.addLine(to: CGPoint(x: 50 + meters * s, y: barY))
        cg.move(to: CGPoint(x: 50, y: barY - 4))
        cg.addLine(to: CGPoint(x: 50, y: barY + 4))
        cg.move(to: CGPoint(x: 50 + meters * s, y: barY - 4))
        cg.addLine(to: CGPoint(x: 50 + meters * s, y: barY + 4))
        cg.strokePath()
        cg.restoreGState()
        drawText("\(Int(meters)) m", at: CGPoint(x: 56 + meters * s, y: barY - 6), size: 8)
        drawText("P = porta   F = finestra (p. = parapetto)   A = apertura   ● = foto con direzione di ripresa   blu = misure delle note   - - - = percorso",
                 at: CGPoint(x: 200, y: barY - 6), size: 7, color: .darkGray)
    }

    static func drawTables(_ cur: PDFCursor, title: String, rooms: [RoomPlanData]) {
        cur.line("\(title) – Tabella delle misure", size: 14, bold: true)
        cur.space(6)
        let totalArea = rooms.reduce(0) { $0 + $1.area }
        cur.line("Superficie totale: \(Fmt.m(totalArea)) m²   –   Stanze: \(rooms.count)", size: 10)
        cur.space(8)

        for room in rooms {
            cur.ensure(80)
            cur.line(room.name, size: 12, bold: true)
            cur.line("Superficie \(Fmt.m(room.area)) m²   Perimetro \(Fmt.m(room.perimeter)) m   Altezza \(Fmt.m(room.height)) m",
                     size: 9)
            cur.space(2)

            if !room.walls.isEmpty {
                cur.row(["Parete", "Lunghezza (m)", "Altezza (m)"], widths: [120, 120, 120], bold: true)
                for (i, w) in room.walls.enumerated() {
                    cur.row(["\(i + 1)", Fmt.m(w.width), Fmt.m(w.height)], widths: [120, 120, 120])
                }
                cur.space(4)
            }
            if !room.doors.isEmpty {
                cur.row(["Porta", "Larghezza (m)", "Altezza (m)"], widths: [120, 120, 120], bold: true)
                for (i, d) in room.doors.enumerated() {
                    cur.row(["\(i + 1)", Fmt.m(d.width), Fmt.m(d.height)], widths: [120, 120, 120])
                }
                cur.space(4)
            }
            if !room.windows.isEmpty {
                cur.row(["Finestra", "Larghezza (m)", "Altezza (m)", "Parapetto (m)"], widths: [120, 120, 120, 120], bold: true)
                for (i, w) in room.windows.enumerated() {
                    cur.row(["\(i + 1)", Fmt.m(w.width), Fmt.m(w.height), Fmt.m(w.bottom)], widths: [120, 120, 120, 120])
                }
                cur.space(4)
            }
            if !room.openings.isEmpty {
                cur.row(["Apertura", "Larghezza (m)", "Altezza (m)"], widths: [120, 120, 120], bold: true)
                for (i, o) in room.openings.enumerated() {
                    cur.row(["\(i + 1)", Fmt.m(o.width), Fmt.m(o.height)], widths: [120, 120, 120])
                }
                cur.space(4)
            }
            if !room.objects.isEmpty {
                cur.row(["Arredo", "Larghezza (m)", "Profondità (m)", "Altezza (m)"], widths: [120, 120, 120, 120], bold: true)
                for o in room.objects {
                    cur.row([o.name, Fmt.m(o.size.x), Fmt.m(o.size.z), Fmt.m(o.size.y)], widths: [120, 120, 120, 120])
                }
            }
            cur.space(14)
        }
    }

    static func drawPhotos(_ ctx: UIGraphicsPDFRendererContext, photos: [(number: Int, record: PhotoRecord)], folder: URL) {
        guard !photos.isEmpty else { return }
        let colWidth: CGFloat = 360
        let imageBox: CGFloat = 400
        for (i, item) in photos.enumerated() {
            let column = i % 2
            if column == 0 {
                ctx.beginPage()
                drawText("Foto del rilievo", at: CGPoint(x: 40, y: 20), size: 12, bold: true)
            }
            let x: CGFloat = 40 + CGFloat(column) * (colWidth + 42)
            let y: CGFloat = 46
            if let image = UIImage(contentsOfFile: folder.appendingPathComponent(item.record.file).path) {
                let scale = min(colWidth / image.size.width, imageBox / image.size.height)
                let w = image.size.width * scale
                let h = image.size.height * scale
                image.draw(in: CGRect(x: x + (colWidth - w) / 2, y: y, width: w, height: h))
            }
            drawText("Foto \(item.number) – \(Fmt.date(item.record.date))", at: CGPoint(x: x, y: y + imageBox + 8),
                     size: 9, bold: true)
            var note = item.record.note.isEmpty ? "(nessuna nota)" : item.record.note
            if let m = item.record.measuresText { note = m + "\n" + note }
            drawText(note, in: CGRect(x: x, y: y + imageBox + 24, width: colWidth, height: 90), size: 9)
        }
    }
}

/// Posizione corrente del testo nelle pagine di tabella, con cambio pagina automatico.
final class PDFCursor {
    let ctx: UIGraphicsPDFRendererContext
    var y: CGFloat = 40

    init(_ ctx: UIGraphicsPDFRendererContext) {
        self.ctx = ctx
    }

    func ensure(_ h: CGFloat) {
        if y + h > PlanPDF.page.height - 36 {
            ctx.beginPage()
            y = 40
        }
    }

    func space(_ h: CGFloat) { y += h }

    func line(_ text: String, size: CGFloat, bold: Bool = false) {
        ensure(size + 6)
        PlanPDF.drawText(text, at: CGPoint(x: 40, y: y), size: size, bold: bold)
        y += size + 6
    }

    func row(_ cols: [String], widths: [CGFloat], bold: Bool = false) {
        ensure(14)
        var x: CGFloat = 50
        for (i, c) in cols.enumerated() {
            PlanPDF.drawText(c, at: CGPoint(x: x, y: y), size: 9, bold: bold)
            x += i < widths.count ? widths[i] : 100
        }
        y += 14
    }
}

// MARK: - DXF (AutoCAD R12, metri)

enum PlanDXF {
    static func make(rooms: [RoomPlanData], markers: [PhotoMarker]) -> String {
        var s = "0\nSECTION\n2\nENTITIES\n"

        func f(_ v: Float) -> String { String(format: "%.4f", v) }

        func line(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ layer: String) {
            s += "0\nLINE\n8\n\(layer)\n10\n\(f(a.x))\n20\n\(f(a.y))\n30\n0.0\n11\n\(f(b.x))\n21\n\(f(b.y))\n31\n0.0\n"
        }

        func text(_ t: String, _ p: SIMD2<Float>, height: Float, angle: Float, _ layer: String) {
            s += "0\nTEXT\n8\n\(layer)\n10\n\(f(p.x))\n20\n\(f(p.y))\n30\n0.0\n40\n\(f(height))\n1\n\(t)\n50\n\(f(angle))\n72\n1\n11\n\(f(p.x))\n21\n\(f(p.y))\n31\n0.0\n"
        }

        func circle(_ c: SIMD2<Float>, _ r: Float, _ layer: String) {
            s += "0\nCIRCLE\n8\n\(layer)\n10\n\(f(c.x))\n20\n\(f(c.y))\n30\n0.0\n40\n\(f(r))\n"
        }

        func segmentLabel(_ seg: PlanSegment, _ t: String, offset: Float, _ layer: String) {
            let d = seg.b - seg.a
            let len = max(simd_length(d), 0.0001)
            let n = SIMD2<Float>(-d.y, d.x) / len
            var angle = atan2(d.y, d.x) * 180 / Float.pi
            if angle > 90 { angle -= 180 } else if angle < -90 { angle += 180 }
            text(t, (seg.a + seg.b) / 2 + n * offset, height: 0.08, angle: angle, layer)
        }

        for room in rooms {
            for w in room.walls {
                line(w.a, w.b, "MURI")
                segmentLabel(w, f2(w.width), offset: 0.12, "QUOTE")
            }
            for d in room.doors {
                line(d.a, d.b, "PORTE")
                segmentLabel(d, "P \(f2(d.width))x\(f2(d.height))", offset: -0.12, "PORTE")
            }
            for w in room.windows {
                line(w.a, w.b, "FINESTRE")
                segmentLabel(w, "F \(f2(w.width))x\(f2(w.height)) p.\(f2(w.bottom))", offset: -0.12, "FINESTRE")
            }
            for o in room.openings {
                line(o.a, o.b, "APERTURE")
                segmentLabel(o, "A \(f2(o.width))", offset: -0.12, "APERTURE")
            }
            for o in room.objects {
                for i in 0..<o.corners.count {
                    line(o.corners[i], o.corners[(i + 1) % o.corners.count], "ARREDI")
                }
                text(ascii(o.name), o.center, height: 0.06, angle: 0, "ARREDI")
            }
            if room.path.count > 1 {
                for i in 1..<room.path.count { line(room.path[i - 1], room.path[i], "PERCORSO") }
                circle(room.path[0], 0.05, "PERCORSO")
            }
            text(ascii(room.name), room.center + SIMD2<Float>(0, 0.1), height: 0.14, angle: 0, "STANZE")
            text("\(f2(room.area)) m2 - h \(f2(room.height))", room.center - SIMD2<Float>(0, 0.12),
                 height: 0.09, angle: 0, "STANZE")
        }
        for m in markers {
            circle(m.point, 0.12, "FOTO")
            text("\(m.number)", m.point, height: 0.1, angle: 0, "FOTO")
        }

        s += "0\nENDSEC\n0\nEOF\n"
        return s
    }

    static func f2(_ v: Float) -> String { String(format: "%.2f", v) }

    /// Il DXF R12 accetta solo caratteri ASCII.
    static func ascii(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive], locale: Locale(identifier: "it_IT"))
        return String(folded.unicodeScalars.filter { $0.isASCII }.map { Character($0) })
    }
}

// MARK: - CSV (Excel italiano: separatore ; e virgola decimale)

enum MeasuresCSV {
    static func make(rooms: [RoomPlanData]) -> String {
        var s = "\u{FEFF}Stanza;Elemento;N.;Larghezza (m);Altezza (m);Profondità (m);Parapetto (m);Superficie (m²);Perimetro (m)\n"
        for room in rooms {
            s += "\(room.name);Stanza;;;\(Fmt.m(room.height));;;\(Fmt.m(room.area));\(Fmt.m(room.perimeter))\n"
            for (i, w) in room.walls.enumerated() {
                s += "\(room.name);Parete;\(i + 1);\(Fmt.m(w.width));\(Fmt.m(w.height));;;;\n"
            }
            for (i, d) in room.doors.enumerated() {
                s += "\(room.name);Porta;\(i + 1);\(Fmt.m(d.width));\(Fmt.m(d.height));;;;\n"
            }
            for (i, w) in room.windows.enumerated() {
                s += "\(room.name);Finestra;\(i + 1);\(Fmt.m(w.width));\(Fmt.m(w.height));;\(Fmt.m(w.bottom));;\n"
            }
            for (i, o) in room.openings.enumerated() {
                s += "\(room.name);Apertura;\(i + 1);\(Fmt.m(o.width));\(Fmt.m(o.height));;;;\n"
            }
            for (i, o) in room.objects.enumerated() {
                s += "\(room.name);\(o.name);\(i + 1);\(Fmt.m(o.size.x));\(Fmt.m(o.size.y));\(Fmt.m(o.size.z));;;\n"
            }
        }
        return s
    }
}
