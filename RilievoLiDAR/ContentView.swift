import SwiftUI

/// Schermata iniziale: archivio dei rilievi.
struct ContentView: View {
    @EnvironmentObject var store: ProjectStore

    @State private var showNew = false
    @State private var newName = ""
    @State private var renameTarget: Project?
    @State private var renameText = ""
    @State private var deleteTarget: Project?

    var body: some View {
        NavigationStack {
            Group {
                if store.projects.isEmpty {
                    ContentUnavailableView("Nessun rilievo",
                                           systemImage: "cube.transparent",
                                           description: Text("Tocca + in alto per creare un nuovo rilievo."))
                } else {
                    List {
                        ForEach(store.projects) { project in
                            NavigationLink {
                                ProjectDetailView(projectID: project.id)
                            } label: {
                                ProjectRow(project: project, folder: store.folder(for: project.id))
                            }
                            .swipeActions {
                                Button(role: .destructive) {
                                    deleteTarget = project
                                } label: {
                                    Label("Elimina", systemImage: "trash")
                                }
                            }
                            .contextMenu {
                                Button {
                                    renameText = project.name
                                    renameTarget = project
                                } label: {
                                    Label("Rinomina", systemImage: "pencil")
                                }
                                Button(role: .destructive) {
                                    deleteTarget = project
                                } label: {
                                    Label("Elimina", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Rilievi")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        newName = "Rilievo \(store.projects.count + 1)"
                        showNew = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .alert("Nuovo rilievo", isPresented: $showNew) {
                TextField("Nome del rilievo", text: $newName)
                Button("Crea") { store.create(name: newName) }
                Button("Annulla", role: .cancel) {}
            }
            .alert("Rinomina rilievo", isPresented: Binding(get: { renameTarget != nil },
                                                           set: { if !$0 { renameTarget = nil } })) {
                TextField("Nome", text: $renameText)
                Button("Salva") {
                    if let t = renameTarget { store.rename(t.id, to: renameText) }
                    renameTarget = nil
                }
                Button("Annulla", role: .cancel) { renameTarget = nil }
            }
            .confirmationDialog("Eliminare il rilievo?",
                                isPresented: Binding(get: { deleteTarget != nil },
                                                     set: { if !$0 { deleteTarget = nil } }),
                                titleVisibility: .visible) {
                Button("Elimina", role: .destructive) {
                    if let t = deleteTarget { store.delete(t.id) }
                    deleteTarget = nil
                }
            } message: {
                Text("Verranno eliminati scansioni, mesh e foto. L'operazione non si può annullare.")
            }
        }
    }
}

struct ProjectRow: View {
    let project: Project
    let folder: URL

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let thumb = project.photos.first,
                   let image = UIImage(contentsOfFile: folder.appendingPathComponent(thumb.thumbFile).path) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "cube.transparent")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 56, height: 56)
            .background(Color.gray.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                Text(project.name).font(.headline)
                Text(Fmt.date(project.modified)).font(.caption).foregroundStyle(.secondary)
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var summary: String {
        var parts = ["\(project.rooms.count) stanze", "\(project.photos.count) foto"]
        if project.mesh != nil { parts.append("mesh") }
        return parts.joined(separator: " · ")
    }
}
