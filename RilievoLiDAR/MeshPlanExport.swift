import UIKit
import SceneKit
import ModelIO
import SceneKit.ModelIO
import simd

/// Pianta, DXF, misure e modello USDZ ricavati dalla mesh quando non ci sono stanze RoomPlan.
enum MeshPlanExport {

    /// Quota del taglio in pianta sopra il pavimento (porte e finestre restano aperte).
    static let sectionAboveFloor: Float = 1.10

    struct Loaded {
        var geometry: MeshGeometry
        var annotations: SavedAnnotations
        var keyframes: [KeyframeRecord]
        var minP: SIMD3<Float>
        var maxP: SIMD3<Float>
        var floorY: Float

        var scale: Float { annotations.scale }
        var sectionY: Float { min(max(floorY + MeshPlanExport.sectionAboveFloor, minP.y), maxP.y) }
    }

    static func load(meshFolder: URL) throws -> Loaded {
        guard let scene = try? SCNScene(url: meshFolder.appendingPathComponent("preview.scn"), options: nil),
              var g = MeshGeometry.load(from: scene) else {
            throw ExportError("Mesh non trovata: esegui prima una scansione mesh.")
        }
        g.classes = MeshClass.load(meshFolder: meshFolder, faceCount: g.indices.count / 3)
        if let box = CropBox.load(meshFolder) {
            let cropped = g.cropped(box)
            if !cropped.isEmpty { g = cropped }
        }
        guard let first = g.vertices.first else {
            throw ExportError("La mesh è vuota.")
        }
        var lo = first
        var hi = first
        for v in g.vertices {
            lo = simd_min(lo, v)
            hi = simd_max(hi, v)
        }
        return Loaded(geometry: g,
                      annotations: MeshViewerModel.loadAnnotations(meshFolder),
                      keyframes: KeyframeStore.load(meshFolder: meshFolder),
                      minP: lo, maxP: hi,
                      floorY: floorY(g.vertices, fallback: lo.y))
    }

    /// Quota del pavimento: 2° percentile delle altezze (ignora i punti isolati sotto il pavimento).
    static func floorY(_ vertices: [SIMD3<Float>], fallback: Float) -> Float {
        guard !vertices.isEmpty else { return fallback }
        let step = max(1, vertices.count / 20000)
        var ys: [Float] = []
        ys.reserveCapacity(vertices.count / step + 1)
        var i = 0
        while i < vertices.count {
            ys.append(vertices[i].y)
            i += step
        }
        ys.sort()
        return ys[min(ys.count - 1, ys.count / 50)]
    }

    static func plan(_ p: SIMD3<Float>, _ scale: Float) -> SIMD2<Float> {
        SIMD2<Float>(p.x * scale, -p.z * scale)
    }

    static func valueText(_ m: SavedMeasure, scale: Float) -> String {
        let p = m.vectors
        if m.kind == "area" {
            return "\(Fmt.m(Geo.area(p) * scale * scale)) m² (in pianta \(Fmt.m(Geo.planArea(p) * scale * scale)) m²)"
        }
        let total = Fmt.m(Geo.length(p) * scale)
        if p.count == 2 {
            let d = p[1] - p[0]
            let horizontal = simd_length(SIMD2<Float>(d.x, d.z)) * scale
            return "\(total) m (orizz. \(Fmt.m(horizontal)) · vert. \(Fmt.m(abs(d.y) * scale)))"
        }
        return "\(total) m (\(p.count - 1) tratti)"
    }

    // MARK: DXF

    static func dxf(segments: [(SIMD3<Float>, SIMD3<Float>)], annotations: SavedAnnotations,
                    keyframes: [KeyframeRecord], furniture: [(SIMD3<Float>, SIMD3<Float>)] = [],
                    openings: [MeshOpening] = []) -> String {
        let scale = annotations.scale
        var s = "0\nSECTION\n2\nENTITIES\n"
        func f(_ v: Float) -> String { String(format: "%.4f", v) }
        func line(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ layer: String) {
            s += "0\nLINE\n8\n\(layer)\n10\n\(f(a.x))\n20\n\(f(a.y))\n30\n0.0\n11\n\(f(b.x))\n21\n\(f(b.y))\n31\n0.0\n"
        }
        func text(_ t: String, _ p: SIMD2<Float>, _ layer: String) {
            s += "0\nTEXT\n8\n\(layer)\n10\n\(f(p.x))\n20\n\(f(p.y))\n30\n0.0\n40\n0.08\n1\n\(PlanDXF.ascii(t))\n"
        }
        for seg in segments { line(plan(seg.0, scale), plan(seg.1, scale), "SEZIONE") }
        for seg in furniture { line(plan(seg.0, scale), plan(seg.1, scale), "ARREDI") }
        for o in openings {
            let layer = o.isDoor ? "PORTE" : "FINESTRE"
            line(o.a, o.b, layer)
            text(o.label, (o.a + o.b) / 2, layer)
        }
        for (i, m) in annotations.measures.enumerated() {
            let p = m.vectors.map { plan($0, scale) }
            if p.count > 1 {
                for j in 1..<p.count { line(p[j - 1], p[j], "MISURE") }
                if m.kind == "area", let first = p.first, let last = p.last { line(last, first, "MISURE") }
            }
            text("\(i + 1): \(valueText(m, scale: scale))", plan(Geo.centroid(m.vectors), scale), "MISURE")
        }
        for (i, n) in annotations.notes.enumerated() where n.point.count == 3 {
            text("N\(i + 1) \(n.text)", plan(SIMD3<Float>(n.point[0], n.point[1], n.point[2]), scale), "NOTE")
        }
        if keyframes.count > 1 {
            let pts = keyframes.map { plan(simd_float4x4(floatArray: $0.transform).translation, scale) }
            for j in 1..<pts.count { line(pts[j - 1], pts[j], "PERCORSO") }
        }
        s += "0\nENDSEC\n0\nEOF\n"
        return s
    }

    static func dxf(_ d: Loaded) -> String {
        dxf(segments: wallSection(d), annotations: d.annotations, keyframes: d.keyframes,
            furniture: furnitureSection(d), openings: openings(d))
    }

    // MARK: CSV

    static func csv(_ d: Loaded) -> String {
        let s = d.scale
        let size = (d.maxP - d.minP) * s
        var csv = "\u{FEFF}Tipo;N.;Valore;Punti (x y z, metri)\n"
        csv += "Ingombro;;\(Fmt.m(size.x)) × \(Fmt.m(size.z)) m in pianta;\n"
        csv += "Altezza;;\(Fmt.m((d.maxP.y - d.floorY) * s)) m dal pavimento;\n"
        csv += "Quota pianta;;\(Fmt.m(sectionAboveFloor)) m dal pavimento;\n"
        for (i, m) in d.annotations.measures.enumerated() {
            let pts = m.vectors.map { "\(Fmt.m($0.x * s)) \(Fmt.m($0.y * s)) \(Fmt.m($0.z * s))" }
                .joined(separator: " | ")
            csv += "\(m.kind == "area" ? "Area" : "Misura");\(i + 1);\(valueText(m, scale: s));\(pts)\n"
        }
        for (i, n) in d.annotations.notes.enumerated() where n.point.count == 3 {
            let text = n.text.replacingOccurrences(of: ";", with: ",")
            csv += "Nota;\(i + 1);\(text);\(Fmt.m(n.point[0])) \(Fmt.m(n.point[1])) \(Fmt.m(n.point[2]))\n"
        }
        for (i, o) in openings(d).enumerated() {
            csv += "\(o.isDoor ? "Porta" : "Finestra");\(i + 1);\(o.label) m;\n"
        }
        if d.annotations.measures.isEmpty {
            csv += "Nota;;Per altre misure usa Righello e Area nel visualizzatore della mesh;\n"
        }
        if s != 1 { csv += "Scala;;\(String(format: "%.4f", s));calibrata su una misura nota\n" }
        return csv
    }

    // MARK: PDF

    static func pdf(_ d: Loaded, projectName: String, photos: [(number: Int, record: PhotoRecord)],
                    projectFolder: URL, showFloor: Bool = false, to url: URL) throws {
        let segments = wallSection(d)
        let furniture = furnitureSection(d)
        let found = openings(d)
        let scale = d.scale
        let page = PlanPDF.page
        let renderer = UIGraphicsPDFRenderer(bounds: page)
        try renderer.writePDF(to: url) { ctx in
            ctx.beginPage()
            let cg = ctx.cgContext
            PlanPDF.drawText(projectName, at: CGPoint(x: 40, y: 24), size: 16, bold: true)
            PlanPDF.drawText("Pianta dalla mesh LiDAR (sezione a \(Fmt.m(sectionAboveFloor)) m dal pavimento) – \(Fmt.date(Date())) – misure in metri",
                             at: CGPoint(x: 40, y: 46), size: 9, color: .darkGray)

            var pts: [SIMD2<Float>] = []
            for sg in segments {
                pts.append(plan(sg.0, scale))
                pts.append(plan(sg.1, scale))
            }
            if pts.isEmpty {
                pts = [plan(d.minP, scale), plan(d.maxP, scale)]
            }
            var lo = pts[0]
            var hi = pts[0]
            for p in pts {
                lo = simd_min(lo, p)
                hi = simd_max(hi, p)
            }
            let box = CGRect(x: 50, y: 80, width: page.width - 100, height: page.height - 140)
            let bw = max(CGFloat(hi.x - lo.x), 0.5)
            let bh = max(CGFloat(hi.y - lo.y), 0.5)
            let k = min(box.width / bw, box.height / bh)
            let ox = box.minX + (box.width - bw * k) / 2
            let oy = box.minY + (box.height - bh * k) / 2
            func toPage(_ p: SIMD2<Float>) -> CGPoint {
                CGPoint(x: ox + CGFloat(p.x - lo.x) * k, y: oy + CGFloat(hi.y - p.y) * k)
            }
            func stroke(_ a: SIMD2<Float>, _ b: SIMD2<Float>, width: CGFloat, color: UIColor, dash: [CGFloat] = []) {
                cg.saveGState()
                cg.setStrokeColor(color.cgColor)
                cg.setLineWidth(width)
                cg.setLineCap(.round)
                if !dash.isEmpty { cg.setLineDash(phase: 0, lengths: dash) }
                cg.move(to: toPage(a))
                cg.addLine(to: toPage(b))
                cg.strokePath()
                cg.restoreGState()
            }

            // Pavimento della mesh visto dall'alto (immagine sotto alle linee)
            if showFloor, let floor = floorImage(d, lo: lo, hi: hi, pixelsPerMeter: k * 3) {
                cg.saveGState()
                cg.interpolationQuality = .high
                let rect = CGRect(x: ox, y: oy, width: CGFloat(hi.x - lo.x) * k, height: CGFloat(hi.y - lo.y) * k)
                UIImage(cgImage: floor).draw(in: rect)
                cg.restoreGState()
            }

            // Arredi (sedie, tavoli) in grigio chiaro
            if !furniture.isEmpty {
                cg.saveGState()
                cg.setStrokeColor(UIColor(white: 0.6, alpha: 1).cgColor)
                cg.setLineWidth(0.6)
                for sg in furniture {
                    cg.move(to: toPage(plan(sg.0, scale)))
                    cg.addLine(to: toPage(plan(sg.1, scale)))
                }
                cg.strokePath()
                cg.restoreGState()
            }

            // Sezione della mesh (solo muri, se la classificazione è disponibile)
            cg.saveGState()
            cg.setStrokeColor(UIColor.black.cgColor)
            cg.setLineWidth(1.2)
            cg.setLineCap(.round)
            for sg in segments {
                cg.move(to: toPage(plan(sg.0, scale)))
                cg.addLine(to: toPage(plan(sg.1, scale)))
            }
            cg.strokePath()
            cg.restoreGState()

            // Porte e finestre riconosciute
            drawOpenings(found, toPage: toPage, in: cg)

            // Percorso dell'operatore
            if d.keyframes.count > 1 {
                let path = d.keyframes.map { plan(simd_float4x4(floatArray: $0.transform).translation, scale) }
                for j in 1..<path.count {
                    stroke(path[j - 1], path[j], width: 0.8, color: .systemOrange, dash: [4, 3])
                }
            }

            // Misure del visualizzatore
            let measureColor = UIColor(red: 0.85, green: 0.5, blue: 0, alpha: 1)
            for (i, m) in d.annotations.measures.enumerated() {
                let p = m.vectors.map { plan($0, scale) }
                guard p.count > 1 else { continue }
                let color: UIColor = m.kind == "area" ? .systemTeal : measureColor
                for j in 1..<p.count { stroke(p[j - 1], p[j], width: 1.2, color: color) }
                if m.kind == "area", let first = p.first, let last = p.last {
                    stroke(last, first, width: 1.2, color: color)
                }
                let value = m.kind == "area"
                    ? "\(Fmt.m(Geo.area(m.vectors) * scale * scale)) m²"
                    : "\(Fmt.m(Geo.length(m.vectors) * scale)) m"
                PlanPDF.drawCentered("\(i + 1): \(value)", at: toPage(plan(Geo.centroid(m.vectors), scale)),
                                     angle: 0, size: 7, bold: true, color: color, in: cg)
            }

            // Note
            for (i, n) in d.annotations.notes.enumerated() where n.point.count == 3 {
                let c = toPage(plan(SIMD3<Float>(n.point[0], n.point[1], n.point[2]), scale))
                cg.saveGState()
                cg.setFillColor(UIColor.systemBlue.cgColor)
                cg.fillEllipse(in: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8))
                cg.restoreGState()
                PlanPDF.drawText("N\(i + 1)", at: CGPoint(x: c.x + 5, y: c.y - 5), size: 7, bold: true, color: .systemBlue)
            }

            // Foto: direzione di ripresa, misure della nota, numero
            let markers = photos.compactMap { PhotoMarker.from(number: $0.number, record: $0.record, plan: { plan($0, scale) }) }
            let walls = segments.map { (plan($0.0, scale), plan($0.1, scale)) }
            PhotoMarkerDrawing.draw(markers, segments: walls, toPage: toPage, pageScale: k, in: cg)

            // Scala grafica
            let meters: CGFloat = k >= 25 ? 1 : (k >= 6 ? 5 : 10)
            let barY = page.height - 36
            cg.saveGState()
            cg.setStrokeColor(UIColor.black.cgColor)
            cg.setLineWidth(1.5)
            cg.move(to: CGPoint(x: 50, y: barY))
            cg.addLine(to: CGPoint(x: 50 + meters * k, y: barY))
            cg.move(to: CGPoint(x: 50, y: barY - 4))
            cg.addLine(to: CGPoint(x: 50, y: barY + 4))
            cg.move(to: CGPoint(x: 50 + meters * k, y: barY - 4))
            cg.addLine(to: CGPoint(x: 50 + meters * k, y: barY + 4))
            cg.strokePath()
            cg.restoreGState()
            PlanPDF.drawText("\(Int(meters)) m", at: CGPoint(x: 56 + meters * k, y: barY - 6), size: 8)
            PlanPDF.drawLegend(cg, at: CGPoint(x: 200, y: barY), items: [
                (.line, "muri"),
                (.text("P / F"), "porta / finestra"),
                (.photo, "foto e direzione di ripresa"),
                (.blueLine, "misure delle note"),
                (.text("N"), "nota"),
                (.dashed, "percorso di scansione")
            ])

            // Tabella
            ctx.beginPage()
            let cur = PDFCursor(ctx)
            cur.line("\(projectName) – Misure dalla mesh", size: 14, bold: true)
            cur.space(6)
            let size = (d.maxP - d.minP) * scale
            cur.line("Ingombro in pianta \(Fmt.m(size.x)) × \(Fmt.m(size.z)) m   –   Altezza \(Fmt.m((d.maxP.y - d.floorY) * scale)) m",
                     size: 10)
            cur.space(8)
            let doors = found.filter { $0.isDoor }
            let windows = found.filter { !$0.isDoor }
            if !doors.isEmpty {
                cur.row(["Porta", "Larghezza (m)", "Altezza (m)"], widths: [120, 120, 120], bold: true)
                for (i, o) in doors.enumerated() {
                    cur.row(["\(i + 1)", Fmt.m(o.width), Fmt.m(o.height)], widths: [120, 120, 120])
                }
                cur.space(6)
            }
            if !windows.isEmpty {
                cur.row(["Finestra", "Larghezza (m)", "Altezza (m)", "Parapetto (m)"], widths: [120, 120, 120, 120], bold: true)
                for (i, o) in windows.enumerated() {
                    cur.row(["\(i + 1)", Fmt.m(o.width), Fmt.m(o.height), Fmt.m(o.bottom)], widths: [120, 120, 120, 120])
                }
                cur.space(6)
            }
            if !found.isEmpty {
                cur.line("Porte e finestre riconosciute automaticamente dalla mesh: misure indicative, da verificare.", size: 8)
                cur.space(6)
            }
            if d.annotations.measures.isEmpty {
                cur.line("Nessuna misura salvata: usa Righello e Area in \"Visualizza, misura, sezione e tour\".", size: 9)
            } else {
                cur.row(["N.", "Tipo", "Valore"], widths: [40, 80, 500], bold: true)
                for (i, m) in d.annotations.measures.enumerated() {
                    cur.row(["\(i + 1)", m.kind == "area" ? "Area" : "Misura", valueText(m, scale: scale)],
                            widths: [40, 80, 500])
                }
            }
            if !d.annotations.notes.isEmpty {
                cur.space(10)
                cur.row(["N.", "Nota"], widths: [40, 580], bold: true)
                for (i, n) in d.annotations.notes.enumerated() {
                    cur.row(["N\(i + 1)", n.text], widths: [40, 580])
                }
            }
            PlanPDF.drawPhotoTable(cur, photos: photos)
            if scale != 1 {
                cur.space(10)
                cur.line("Scala calibrata: \(String(format: "%.4f", scale))", size: 9)
            }

            PlanPDF.drawPhotos(ctx, photos: photos, folder: projectFolder)
        }
    }

    /// Immagine del pavimento vista dall'alto, dai colori della mesh (zona [lo, hi] della pianta).
    static func floorImage(_ d: Loaded, lo: SIMD2<Float>, hi: SIMD2<Float>, pixelsPerMeter: CGFloat) -> CGImage? {
        let g = d.geometry
        guard g.colors.count == g.vertices.count else { return nil }
        let scale = d.scale
        let wm = CGFloat(hi.x - lo.x), hm = CGFloat(hi.y - lo.y)
        let ppm = min(pixelsPerMeter, 3000 / max(wm, hm, 0.1))
        let w = max(1, Int(wm * ppm)), h = max(1, Int(hm * ppm))
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setShouldAntialias(true)
        func px(_ p: SIMD3<Float>) -> CGPoint {
            let q = plan(p, scale)
            // y della bitmap verso l'alto: nord della pianta in alto come nella pagina
            return CGPoint(x: CGFloat(q.x - lo.x) * ppm, y: CGFloat(q.y - lo.y) * ppm)
        }
        var t = 0
        while t + 2 < g.indices.count {
            let ia = Int(g.indices[t]), ib = Int(g.indices[t + 1]), ic = Int(g.indices[t + 2])
            t += 3
            let a = g.vertices[ia], b = g.vertices[ib], c = g.vertices[ic]
            let cr = simd_cross(b - a, c - a)
            let len = simd_length(cr)
            if len < 1e-10 || abs(cr.y) / len < 0.75 { continue }
            let cy = (a.y + b.y + c.y) / 3
            if abs(cy - d.floorY) > 0.08 { continue }
            let col = (g.colors[ia] + g.colors[ib] + g.colors[ic]) / 3
            ctx.setFillColor(red: CGFloat(col.x), green: CGFloat(col.y), blue: CGFloat(col.z), alpha: 1)
            ctx.setStrokeColor(red: CGFloat(col.x), green: CGFloat(col.y), blue: CGFloat(col.z), alpha: 1)
            ctx.setLineWidth(0.6)
            ctx.move(to: px(a))
            ctx.addLine(to: px(b))
            ctx.addLine(to: px(c))
            ctx.closePath()
            ctx.drawPath(using: .fillStroke)
        }
        return ctx.makeImage()
    }

    // MARK: USDZ

    /// Mesh bianca con ombreggiatura, apribile in Quick Look / AR e nei programmi 3D.
    static func usdz(_ d: Loaded, to url: URL) throws {
        let scene = SCNScene()
        scene.rootNode.addChildNode(SCNNode(geometry: d.geometry.whiteGeometry()))
        if !scene.write(to: url, options: nil, delegate: nil, progressHandler: nil)
            || !FileManager.default.fileExists(atPath: url.path) {
            let asset = MDLAsset(scnScene: scene)
            try asset.export(to: url)
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ExportError("Impossibile creare il file USDZ.")
        }
    }
}

extension MeshGeometry {
    /// Normali per vertice (media delle facce adiacenti) per un'ombreggiatura morbida.
    func vertexNormals() -> [SIMD3<Float>] {
        var normals = [SIMD3<Float>](repeating: SIMD3<Float>(0, 0, 0), count: vertices.count)
        var t = 0
        while t + 2 < indices.count {
            let ia = Int(indices[t])
            let ib = Int(indices[t + 1])
            let ic = Int(indices[t + 2])
            t += 3
            let n = simd_cross(vertices[ib] - vertices[ia], vertices[ic] - vertices[ia])
            normals[ia] += n
            normals[ib] += n
            normals[ic] += n
        }
        for i in 0..<normals.count {
            let l = simd_length(normals[i])
            normals[i] = l > 1e-12 ? normals[i] / l : SIMD3<Float>(0, 1, 0)
        }
        return normals
    }

    /// Geometria monocolore bianca con luci (come un modello in gesso).
    func whiteGeometry() -> SCNGeometry {
        let vs = SCNGeometrySource(vertices: vertices.map { SCNVector3($0.x, $0.y, $0.z) })
        let ns = SCNGeometrySource(normals: vertexNormals().map { SCNVector3($0.x, $0.y, $0.z) })
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        let geometry = SCNGeometry(sources: [vs, ns], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .lambert
        material.diffuse.contents = UIColor(white: 0.92, alpha: 1)
        material.emission.contents = UIColor(white: 0.18, alpha: 1)
        material.isDoubleSided = true
        geometry.materials = [material]
        return geometry
    }
}
