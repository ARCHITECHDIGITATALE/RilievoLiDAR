import Foundation
import Combine

/// Archivio dei rilievi: ogni rilievo è una cartella in Documenti/Rilievi/<id>/
final class ProjectStore: ObservableObject {
    @Published private(set) var projects: [Project] = []
    let root: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = docs.appendingPathComponent("Rilievi", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        load()
    }

    func folder(for id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func project(_ id: UUID) -> Project? {
        projects.first { $0.id == id }
    }

    func load() {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var list: [Project] = []
        for dir in dirs {
            let file = dir.appendingPathComponent("project.json")
            if let data = try? Data(contentsOf: file),
               let p = try? decoder.decode(Project.self, from: data) {
                list.append(p)
            }
        }
        projects = list.sorted { $0.modified > $1.modified }
    }

    @discardableResult
    func create(name: String) -> Project {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = Project(name: trimmed.isEmpty ? "Rilievo" : trimmed)
        try? FileManager.default.createDirectory(at: folder(for: p.id), withIntermediateDirectories: true)
        write(p)
        projects.insert(p, at: 0)
        return p
    }

    func update(_ id: UUID, _ change: (inout Project) -> Void) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        var p = projects[i]
        change(&p)
        p.modified = Date()
        projects[i] = p
        write(p)
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update(id) { $0.name = trimmed }
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: folder(for: id))
        projects.removeAll { $0.id == id }
    }

    private func write(_ p: Project) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(p) {
            try? data.write(to: folder(for: p.id).appendingPathComponent("project.json"), options: .atomic)
        }
    }
}
