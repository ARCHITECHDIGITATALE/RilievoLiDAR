import SwiftUI
import SceneKit
import RoomPlan

// MARK: - Misure di una stanza

struct RoomMeasuresView: View {
    let projectID: UUID
    let room: RoomRecord
    @EnvironmentObject var store: ProjectStore
    @State private var data: RoomPlanData?
    @State private var failed = false

    var body: some View {
        List {
            if let d = data {
                Section("Stanza") {
                    LabeledContent("Superficie", value: "\(Fmt.m(d.area)) m²")
                    LabeledContent("Perimetro", value: "\(Fmt.m(d.perimeter)) m")
                    LabeledContent("Altezza", value: "\(Fmt.m(d.height)) m")
                }
                if !d.walls.isEmpty {
                    Section("Pareti (\(d.walls.count))") {
                        ForEach(Array(d.walls.enumerated()), id: \.offset) { i, w in
                            LabeledContent("Parete \(i + 1)", value: "\(Fmt.m(w.width)) × h \(Fmt.m(w.height)) m")
                        }
                    }
                }
                if !d.doors.isEmpty {
                    Section("Porte (\(d.doors.count))") {
                        ForEach(Array(d.doors.enumerated()), id: \.offset) { i, w in
                            LabeledContent("Porta \(i + 1)", value: "\(Fmt.m(w.width)) × \(Fmt.m(w.height)) m")
                        }
                    }
                }
                if !d.windows.isEmpty {
                    Section("Finestre (\(d.windows.count))") {
                        ForEach(Array(d.windows.enumerated()), id: \.offset) { i, w in
                            LabeledContent("Finestra \(i + 1)",
                                           value: "\(Fmt.m(w.width)) × \(Fmt.m(w.height)) m, parapetto \(Fmt.m(w.bottom))")
                        }
                    }
                }
                if !d.openings.isEmpty {
                    Section("Aperture (\(d.openings.count))") {
                        ForEach(Array(d.openings.enumerated()), id: \.offset) { i, w in
                            LabeledContent("Apertura \(i + 1)", value: "\(Fmt.m(w.width)) × \(Fmt.m(w.height)) m")
                        }
                    }
                }
                if !d.objects.isEmpty {
                    Section("Arredi (\(d.objects.count))") {
                        ForEach(Array(d.objects.enumerated()), id: \.offset) { _, o in
                            LabeledContent(o.name,
                                           value: "\(Fmt.m(o.size.x)) × \(Fmt.m(o.size.z)) × h \(Fmt.m(o.size.y)) m")
                        }
                    }
                }
            } else if failed {
                Text("Impossibile leggere i dati della stanza.")
            } else {
                ProgressView()
            }
        }
        .navigationTitle(room.name)
        .onAppear(perform: load)
    }

    private func load() {
        guard data == nil else { return }
        let url = store.folder(for: projectID).appendingPathComponent(room.file)
        if let raw = try? Data(contentsOf: url),
           let captured = try? JSONDecoder().decode(CapturedRoom.self, from: raw) {
            data = PlanBuilder.data(for: captured, name: room.name)
        } else {
            failed = true
        }
    }
}

// MARK: - Dettaglio foto con nota

struct PhotoDetailView: View {
    let projectID: UUID
    let photo: PhotoRecord
    let number: Int
    @EnvironmentObject var store: ProjectStore
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""
    @State private var widthText = ""
    @State private var heightText = ""
    @State private var image: UIImage?
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    Text(Fmt.date(photo.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Nota", text: $note, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(3...8)
                    HStack(spacing: 12) {
                        Text("Larghezza")
                        TextField("m", text: $widthText)
                            .keyboardType(.decimalPad)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 110)
                        Text("Altezza")
                        TextField("m", text: $heightText)
                            .keyboardType(.decimalPad)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 110)
                        Text("m").foregroundStyle(.secondary)
                    }
                    if photo.direction != nil {
                        Text("Nella pianta la quota viene disegnata sul muro verso cui puntava la foto.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Label("Elimina foto", systemImage: "trash")
                    }
                    .padding(.top, 8)
                }
                .padding()
            }
            .navigationTitle("Foto \(number)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Chiudi") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salva") {
                        save()
                        dismiss()
                    }
                }
            }
            .confirmationDialog("Eliminare la foto?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Elimina", role: .destructive) {
                    delete()
                    dismiss()
                }
            }
            .onAppear {
                note = photo.note
                widthText = PhotoAim.text(photo.width)
                heightText = PhotoAim.text(photo.height)
                image = UIImage(contentsOfFile: store.folder(for: projectID).appendingPathComponent(photo.file).path)
            }
        }
    }

    private func save() {
        let text = note
        let id = photo.id
        let w = PhotoAim.parseMeters(widthText)
        let h = PhotoAim.parseMeters(heightText)
        store.update(projectID) { p in
            if let i = p.photos.firstIndex(where: { $0.id == id }) {
                p.photos[i].note = text
                p.photos[i].width = w
                p.photos[i].height = h
            }
        }
    }

    private func delete() {
        let folder = store.folder(for: projectID)
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(photo.file))
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(photo.thumbFile))
        let id = photo.id
        store.update(projectID) { p in p.photos.removeAll { $0.id == id } }
    }
}
