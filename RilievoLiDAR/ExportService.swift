import Foundation
import RoomPlan
import SceneKit
import simd

/// Genera i file da condividere a partire dai dati salvati nel progetto.
enum ExportService {

    static func loadRooms(project: Project, folder: URL) -> [(record: RoomRecord, room: CapturedRoom)] {
        project.rooms.compactMap { r -> (record: RoomRecord, room: CapturedRoom)? in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(r.file)),
                  let room = try? JSONDecoder().decode(CapturedRoom.self, from: data) else { return nil }
            return (r, room)
        }
    }

    static func planData(project: Project, folder: URL) -> (rooms: [RoomPlanData], markers: [PhotoMarker]) {
        let rooms = loadRooms(project: project, folder: folder).map {
            PlanBuilder.data(for: $0.room, name: $0.record.name, path: $0.record.path ?? [])
        }
        var markers: [PhotoMarker] = []
        for (i, p) in project.photos.enumerated() where p.source == "stanze" && p.position.count == 3 {
            markers.append(PhotoMarker(number: i + 1, point: PlanBuilder.plan(SIMD3<Float>(p.position[0], p.position[1], p.position[2]))))
        }
        return (rooms, markers)
    }

    static func outURL(_ project: Project, _ suffix: String) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Esportazioni", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(FileUtils.safeName(project.name))_\(suffix)")
        try? FileManager.default.removeItem(at: url)
        return url
    }

    @MainActor
    static func roomsUSDZ(project: Project, folder: URL) async throws -> URL {
        let rooms = loadRooms(project: project, folder: folder).map { $0.room }
        guard !rooms.isEmpty else { throw ExportError("Nessuna stanza scansionata.") }
        let url = outURL(project, "stanze.usdz")
        if rooms.count == 1 {
            try rooms[0].export(to: url)
        } else {
            let builder = StructureBuilder(options: [.beautifyObjects])
            let structure = try await builder.capturedStructure(from: rooms)
            try structure.export(to: url)
        }
        return url
    }

    static func planPDF(project: Project, folder: URL) throws -> URL {
        let data = planData(project: project, folder: folder)
        guard !data.rooms.isEmpty else { throw ExportError("Nessuna stanza scansionata.") }
        let photos = project.photos.enumerated().map { (number: $0.offset + 1, record: $0.element) }
        let url = outURL(project, "pianta.pdf")
        try PlanPDF.render(projectName: project.name, rooms: data.rooms, markers: data.markers,
                           photos: photos, projectFolder: folder, to: url)
        return url
    }

    static func planDXF(project: Project, folder: URL) throws -> URL {
        let data = planData(project: project, folder: folder)
        guard !data.rooms.isEmpty else { throw ExportError("Nessuna stanza scansionata.") }
        let url = outURL(project, "pianta.dxf")
        try PlanDXF.make(rooms: data.rooms, markers: data.markers).write(to: url, atomically: true, encoding: .ascii)
        return url
    }

    static func measuresCSV(project: Project, folder: URL) throws -> URL {
        let data = planData(project: project, folder: folder)
        guard !data.rooms.isEmpty else { throw ExportError("Nessuna stanza scansionata.") }
        let url = outURL(project, "misure.csv")
        try MeasuresCSV.make(rooms: data.rooms).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func meshPLY(project: Project, folder: URL) async throws -> URL {
        let preview = folder.appendingPathComponent("mesh/preview.scn")
        let url = outURL(project, "mesh.ply")
        try await Task.detached(priority: .userInitiated) {
            guard let scene = try? SCNScene(url: preview, options: nil),
                  let geometry = MeshGeometry.load(from: scene) else {
                throw ExportError("Mesh non trovata: esegui prima una scansione mesh.")
            }
            try geometry.writePLY(to: url)
        }.value
        return url
    }

    static func meshZip(project: Project, folder: URL) async throws -> URL {
        let dir = folder.appendingPathComponent("mesh/export", isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("modello.obj").path) else {
            throw ExportError("Mesh non trovata: esegui prima una scansione mesh.")
        }
        let url = outURL(project, "mesh.zip")
        try await Task.detached(priority: .userInitiated) {
            try FileUtils.zipDirectory(dir, to: url)
        }.value
        return url
    }

    // MARK: Dalla mesh (quando non ci sono stanze RoomPlan)

    private static func meshData(_ folder: URL) throws -> MeshPlanExport.Loaded {
        try MeshPlanExport.load(meshFolder: folder.appendingPathComponent("mesh", isDirectory: true))
    }

    static func meshUSDZ(project: Project, folder: URL) async throws -> URL {
        let url = outURL(project, "mesh.usdz")
        try await Task.detached(priority: .userInitiated) {
            try MeshPlanExport.usdz(try meshData(folder), to: url)
        }.value
        return url
    }

    static func meshPlanPDF(project: Project, folder: URL) async throws -> URL {
        let url = outURL(project, "pianta_mesh.pdf")
        let photos = project.photos.enumerated().map { (number: $0.offset + 1, record: $0.element) }
        let name = project.name
        try await Task.detached(priority: .userInitiated) {
            try MeshPlanExport.pdf(try meshData(folder), projectName: name, photos: photos,
                                   projectFolder: folder, to: url)
        }.value
        return url
    }

    static func meshPlanDXF(project: Project, folder: URL) async throws -> URL {
        let url = outURL(project, "pianta_mesh.dxf")
        try await Task.detached(priority: .userInitiated) {
            try MeshPlanExport.dxf(try meshData(folder)).write(to: url, atomically: true, encoding: .ascii)
        }.value
        return url
    }

    static func meshCSV(project: Project, folder: URL) async throws -> URL {
        let url = outURL(project, "misure_mesh.csv")
        try await Task.detached(priority: .userInitiated) {
            try MeshPlanExport.csv(try meshData(folder)).write(to: url, atomically: true, encoding: .utf8)
        }.value
        return url
    }
}
