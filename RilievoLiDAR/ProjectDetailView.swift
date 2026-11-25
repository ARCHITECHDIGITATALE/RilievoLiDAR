import SwiftUI
import QuickLook
import RoomPlan
import ARKit

struct PhotoSelection: Identifiable {
    let photo: PhotoRecord
    let number: Int
    var id: UUID { photo.id }
}

struct ProjectDetailView: View {
    let projectID: UUID
    @EnvironmentObject var store: ProjectStore

    @State private var showRoomScan = false
    @State private var showMeshScan = false
    @State private var confirmMeshOverwrite = false
    @State private var shareItem: ShareItem?
    @State private var quickLookURL: URL?
    @State private var showMeshPreview = false
    @State private var busyText: String?
    @State private var errorText: String?
    @State private var roomToRename: RoomRecord?
    @State private var renameText = ""
    @State private var selectedPhoto: PhotoSelection?
    @State private var askPDFStyle = false

    private var folder: URL { store.folder(for: projectID) }

    var body: some View {
        Group {
            if let project = store.project(projectID) {
                content(project)
            } else {
                Text("Rilievo non trovato")
            }
        }
    }

    @ViewBuilder
    private func content(_ project: Project) -> some View {
        List {
            scanSection(project)
            roomsSection(project)
            meshSection(project)
            photosSection(project)
            exportSection(project)
        }
        .navigationTitle(project.name)
        .fullScreenCover(isPresented: $showRoomScan) {
            RoomScanView(projectID: projectID).environmentObject(store)
        }
        .fullScreenCover(isPresented: $showMeshScan) {
            MeshScanView(projectID: projectID).environmentObject(store)
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(url: item.url)
        }
        .fullScreenCover(isPresented: $showMeshPreview) {
            MeshViewerView(projectFolder: folder)
        }
        .sheet(item: $selectedPhoto) { sel in
            PhotoDetailView(projectID: projectID, photo: sel.photo, number: sel.number)
                .environmentObject(store)
        }
        .quickLookPreview($quickLookURL)
        .confirmationDialog("Sostituire la mesh esistente?", isPresented: $confirmMeshOverwrite, titleVisibility: .visible) {
            Button("Nuova scansione mesh", role: .destructive) { showMeshScan = true }
        } message: {
            Text("La mesh e i fotogrammi della scansione precedente verranno eliminati. Le foto con nota restano.")
        }
        .alert("Rinomina stanza", isPresented: Binding(get: { roomToRename != nil },
                                                       set: { if !$0 { roomToRename = nil } })) {
            TextField("Nome", text: $renameText)
            Button("Salva") { renameRoom() }
            Button("Annulla", role: .cancel) { roomToRename = nil }
        }
        .alert("Errore", isPresented: Binding(get: { errorText != nil },
                                              set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
        .overlay {
            if let busyText {
                ZStack {
                    Color.black.opacity(0.25).ignoresSafeArea()
                    ProgressView(busyText)
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
        }
    }

    // MARK: Sezioni

    private func scanSection(_ project: Project) -> some View {
        Section {
            Button {
                showRoomScan = true
            } label: {
                Label("Scansione stanze (pianta e modello)", systemImage: "square.split.bottomrightquarter")
            }
            .disabled(!RoomCaptureSession.isSupported)

            Button {
                if project.mesh != nil { confirmMeshOverwrite = true } else { showMeshScan = true }
            } label: {
                Label("Scansione mesh con foto", systemImage: "camera.metering.matrix")
            }
            .disabled(!ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh))
        } header: {
            Text("Nuova scansione")
        } footer: {
            Text("Per unire più stanze in un unico modello, scansionale una dopo l'altra senza chiudere la schermata di scansione.")
        }
    }

    private func roomsSection(_ project: Project) -> some View {
        Section("Stanze (\(project.rooms.count))") {
            if project.rooms.isEmpty {
                Text("Nessuna stanza scansionata.").foregroundStyle(.secondary)
            }
            ForEach(project.rooms) { room in
                NavigationLink {
                    RoomMeasuresView(projectID: projectID, room: room)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(room.name)
                        Text(Fmt.date(room.date)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .swipeActions {
                    Button(role: .destructive) {
                        deleteRoom(room)
                    } label: {
                        Label("Elimina", systemImage: "trash")
                    }
                }
                .contextMenu {
                    Button {
                        renameText = room.name
                        roomToRename = room
                    } label: {
                        Label("Rinomina", systemImage: "pencil")
                    }
                }
            }
        }
    }

    private func meshSection(_ project: Project) -> some View {
        Section("Mesh con foto") {
            if let mesh = project.mesh {
                LabeledContent("Fotogrammi", value: "\(mesh.keyframes)")
                LabeledContent("Triangoli", value: "\(mesh.faces)")
                LabeledContent("Origine della mesh", value: mesh.sourceText)
                if let ts = mesh.textureScale {
                    LabeledContent("Risoluzione texture", value: "\(Int((ts * 100).rounded()))%")
                }
                if let secs = mesh.processingSeconds {
                    LabeledContent("Elaborazione", value: "\(Int(secs.rounded())) s")
                }
                LabeledContent("Coperti da foto",
                               value: mesh.faces > 0 ? "\(Int(Double(mesh.texturedFaces) / Double(mesh.faces) * 100))%" : "–")
                Button {
                    showMeshPreview = true
                } label: {
                    Label("Visualizza, misura, sezione e tour", systemImage: "ruler")
                }
                NavigationLink {
                    KeyframeGalleryView(meshFolder: folder.appendingPathComponent("mesh", isDirectory: true))
                } label: {
                    Label("Foto della scansione mesh (\(mesh.keyframes))", systemImage: "photo.on.rectangle")
                }
            } else {
                Text("Nessuna mesh. Usa \"Scansione mesh con foto\".").foregroundStyle(.secondary)
            }
        }
    }

    private func photosSection(_ project: Project) -> some View {
        Section("Foto e note (\(project.photos.count))") {
            if project.photos.isEmpty {
                Text("Durante la scansione tocca \"Foto\" per scattare una foto e aggiungere una nota.")
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 10)], spacing: 10) {
                    ForEach(Array(project.photos.enumerated()), id: \.element.id) { index, photo in
                        Button {
                            selectedPhoto = PhotoSelection(photo: photo, number: index + 1)
                        } label: {
                            PhotoThumb(url: folder.appendingPathComponent(photo.thumbFile),
                                       number: index + 1, note: photo.note)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func exportSection(_ project: Project) -> some View {
        let hasRooms = !project.rooms.isEmpty
        let hasMesh = project.mesh != nil
        let fromMesh = !hasRooms && hasMesh
        let f = folder
        return Section {
            Button {
                runExport("Creazione del modello…", preview: true) {
                    if hasRooms { return try await ExportService.roomsUSDZ(project: project, folder: f) }
                    return try await ExportService.meshUSDZ(project: project, folder: f)
                }
            } label: {
                Label(fromMesh ? "Anteprima 3D della mesh" : "Anteprima 3D delle stanze", systemImage: "cube")
            }
            .disabled(!hasRooms && !hasMesh)

            Button {
                runExport("Creazione del modello…") {
                    if hasRooms { return try await ExportService.roomsUSDZ(project: project, folder: f) }
                    return try await ExportService.meshUSDZ(project: project, folder: f)
                }
            } label: {
                Label(fromMesh ? "Modello mesh (USDZ)" : "Modello stanze (USDZ)", systemImage: "square.and.arrow.up")
            }
            .disabled(!hasRooms && !hasMesh)

            Button {
                if hasRooms {
                    runExport("Creazione della pianta…") { try ExportService.planPDF(project: project, folder: f) }
                } else {
                    askPDFStyle = true
                }
            } label: {
                Label("Pianta quotata con foto (PDF)", systemImage: "doc.richtext")
            }
            .disabled(!hasRooms && !hasMesh)
            .confirmationDialog("Pianta PDF dalla mesh", isPresented: $askPDFStyle, titleVisibility: .visible) {
                Button("Con il pavimento della mesh") {
                    runExport("Creazione della pianta…") {
                        try await ExportService.meshPlanPDF(project: project, folder: f, showFloor: true)
                    }
                }
                Button("Solo linee") {
                    runExport("Creazione della pianta…") {
                        try await ExportService.meshPlanPDF(project: project, folder: f, showFloor: false)
                    }
                }
            } message: {
                Text("Con il pavimento: sotto le linee compare il pavimento visto dall'alto con i colori reali.")
            }

            Button {
                runExport("Creazione del DXF…") {
                    if hasRooms { return try ExportService.planDXF(project: project, folder: f) }
                    return try await ExportService.meshPlanDXF(project: project, folder: f)
                }
            } label: {
                Label("Pianta per CAD (DXF)", systemImage: "square.and.pencil")
            }
            .disabled(!hasRooms && !hasMesh)

            Button {
                runExport("Creazione della tabella…") {
                    if hasRooms { return try ExportService.measuresCSV(project: project, folder: f) }
                    return try await ExportService.meshCSV(project: project, folder: f)
                }
            } label: {
                Label("Misure (CSV per Excel)", systemImage: "tablecells")
            }
            .disabled(!hasRooms && !hasMesh)

            Button {
                runExport("Compressione di mesh e foto…") {
                    try await ExportService.meshZip(project: project, folder: f)
                }
            } label: {
                Label("Mesh OBJ con texture + foto (ZIP)", systemImage: "shippingbox")
            }
            .disabled(project.mesh == nil)

            Button {
                runExport("Creazione del file PLY…") {
                    try await ExportService.meshPLY(project: project, folder: f)
                }
            } label: {
                Label("Mesh colorata / nuvola di punti (PLY)", systemImage: "circle.grid.3x3")
            }
            .disabled(project.mesh == nil)
        } header: {
            Text("Esporta e condividi")
        } footer: {
            Text(fromMesh
                 ? "Senza stanze scansionate, pianta, DXF e misure sono ricavati dalla mesh (sezione a 1,10 m dal pavimento, più le misure salvate nel visualizzatore). Il file si apre nel menu di condivisione."
                 : "Il file si apre nel menu di condivisione: puoi inviarlo per mail, AirDrop, Drive o salvarlo in File.")
        }
    }

    // MARK: Azioni

    private func runExport(_ label: String, preview: Bool = false, _ work: @escaping () async throws -> URL) {
        busyText = label
        Task {
            try? await Task.sleep(nanoseconds: 80_000_000)
            do {
                let url = try await work()
                busyText = nil
                if preview {
                    quickLookURL = url
                } else {
                    shareItem = ShareItem(url: url)
                }
            } catch {
                busyText = nil
                errorText = error.localizedDescription
            }
        }
    }

    private func deleteRoom(_ room: RoomRecord) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(room.file))
        store.update(projectID) { p in p.rooms.removeAll { $0.id == room.id } }
    }

    private func renameRoom() {
        guard let room = roomToRename else { return }
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            store.update(projectID) { p in
                if let i = p.rooms.firstIndex(where: { $0.id == room.id }) { p.rooms[i].name = name }
            }
        }
        roomToRename = nil
    }
}

struct PhotoThumb: View {
    let url: URL
    let number: Int
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topLeading) {
                if let image = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(height: 100)
                        .frame(maxWidth: .infinity)
                        .clipped()
                } else {
                    Rectangle().fill(Color.gray.opacity(0.2)).frame(height: 100)
                }
                Text("\(number)")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.red, in: Capsule())
                    .padding(4)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(note.isEmpty ? " " : note)
                .font(.caption2)
                .lineLimit(1)
                .foregroundStyle(.secondary)
        }
    }
}
