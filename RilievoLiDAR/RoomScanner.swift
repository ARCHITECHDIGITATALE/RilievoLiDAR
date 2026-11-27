import SwiftUI
import RoomPlan
import ARKit
import Combine

/// Scansione RoomPlan di una o più stanze nella stessa sessione (stesse coordinate).
@MainActor
final class RoomScanner: NSObject, ObservableObject, RoomCaptureViewDelegate {
    enum Phase { case idle, scanning, processing }

    @Published var phase: Phase = .idle
    @Published var roomsThisSession = 0
    @Published var message: String?

    let captureView: RoomCaptureView
    let sessionID = UUID()
    var onRoom: ((CapturedRoom, [Float]) -> Void)?
    private var currentPath: [SIMD3<Float>] = []
    private let configuration = RoomCaptureSession.Configuration()

    override init() {
        captureView = RoomCaptureView(frame: .zero)
        super.init()
        captureView.delegate = self
    }

    // RoomCaptureViewDelegate eredita da NSCoding: servono questi due metodi.
    required init?(coder: NSCoder) {
        return nil
    }

    func encode(with coder: NSCoder) {}

    var currentFrame: ARFrame? {
        captureView.captureSession.arSession.currentFrame
    }

    func startRoom() {
        message = nil
        currentPath = []
        captureView.captureSession.run(configuration: configuration)
        phase = .scanning
    }

    /// Termina la stanza ma lascia attiva la sessione AR, così la stanza successiva
    /// resta allineata alla precedente.
    func finishRoom() {
        guard phase == .scanning else { return }
        captureView.captureSession.stop(pauseARSession: false)
        phase = .processing
    }

    /// Registra la posizione dell'operatore (chiamato ogni mezzo secondo).
    func samplePath() {
        guard phase == .scanning, let frame = currentFrame else { return }
        guard case .normal = frame.camera.trackingState else { return }
        let p = frame.camera.transform.translation
        if let last = currentPath.last, simd_distance(last, p) < 0.1 { return }
        currentPath.append(p)
    }

    func endSession() {
        if phase == .scanning {
            captureView.captureSession.stop()
        }
        captureView.captureSession.arSession.pause()
    }

    // MARK: RoomCaptureViewDelegate

    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
        return true
    }

    func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.phase = .idle
            if let error {
                self.message = "Errore nell'elaborazione: \(error.localizedDescription)"
                return
            }
            self.roomsThisSession += 1
            let flat = self.currentPath.flatMap { [$0.x, $0.y, $0.z] }
            self.onRoom?(processedResult, flat)
        }
    }
}

struct RoomCaptureRepresentable: UIViewRepresentable {
    let view: RoomCaptureView

    func makeUIView(context: Context) -> RoomCaptureView { view }

    func updateUIView(_ uiView: RoomCaptureView, context: Context) {}
}

// MARK: - Schermata di scansione stanze

struct RoomScanView: View {
    let projectID: UUID
    @EnvironmentObject var store: ProjectStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var scanner = RoomScanner()

    @State private var showNote = false
    @State private var noteText = ""
    @State private var widthText = ""
    @State private var heightText = ""
    @State private var roomText = ""
    @State private var levelText = ""
    @AppStorage("lastPhotoRoom") private var lastRoom = ""
    @AppStorage("lastPhotoLevel") private var lastLevel = ""
    @State private var pendingPhotoID: UUID?
    @State private var flash = false

    var body: some View {
        ZStack {
            RoomCaptureRepresentable(view: scanner.captureView)
                .ignoresSafeArea()

            if flash {
                Color.white.opacity(0.6).ignoresSafeArea()
            }

            VStack {
                HStack {
                    Button {
                        scanner.endSession()
                        dismiss()
                    } label: {
                        Label("Chiudi", systemImage: "xmark")
                    }
                    .disabled(scanner.phase == .processing)
                    Spacer()
                    TorchButton()
                        .padding(.trailing, 12)
                    Text("Stanze in questa sessione: \(scanner.roomsThisSession)")
                        .font(.subheadline)
                }
                .padding(12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding()

                Spacer()

                VStack(spacing: 10) {
                    if let message = scanner.message {
                        Text(message).font(.footnote).foregroundStyle(.red)
                    }
                    controls
                }
                .padding()
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                .padding()
            }
        }
        .onAppear {
            let store = self.store
            let projectID = self.projectID
            let sessionID = scanner.sessionID
            scanner.onRoom = { room, path in
                RoomScanView.saveRoom(room, path: path, store: store, projectID: projectID, sessionID: sessionID)
            }
        }
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
            scanner.samplePath()
        }
        .sheet(isPresented: $showNote) {
            PhotoNoteForm(note: $noteText, width: $widthText, height: $heightText,
                          room: $roomText, level: $levelText,
                          message: "RoomPlan non si può mettere in pausa: tieni l'iPad fermo mentre scrivi, oppure salta e completa la nota dopo dalla galleria.",
                          onSave: { saveNote() }, onSkip: {})
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch scanner.phase {
        case .idle:
            HStack(spacing: 16) {
                Button {
                    scanner.startRoom()
                } label: {
                    Label(scanner.roomsThisSession == 0 ? "Avvia scansione stanza" : "Scansiona stanza successiva",
                          systemImage: "viewfinder")
                }
                .buttonStyle(.borderedProminent)

                if scanner.roomsThisSession > 0 {
                    Button("Fine") {
                        scanner.endSession()
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                }
            }
            .controlSize(.large)
            Text("Inquadra anche il soffitto e il pavimento. Per più stanze passa da una all'altra senza chiudere questa schermata.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        case .scanning:
            HStack(spacing: 16) {
                Button {
                    takePhoto()
                } label: {
                    Label("Foto", systemImage: "camera.fill")
                }
                .buttonStyle(.bordered)

                Button(role: .destructive) {
                    scanner.finishRoom()
                } label: {
                    Label("Termina stanza", systemImage: "stop.circle.fill")
                }
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
        case .processing:
            ProgressView("Elaborazione della stanza…")
        }
    }

    private func takePhoto() {
        guard let frame = scanner.currentFrame,
              let record = PhotoSaver.save(frame: frame, projectFolder: store.folder(for: projectID), source: "stanze")
        else { return }
        store.update(projectID) { $0.photos.append(record) }
        flash = true
        Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            flash = false
        }
        pendingPhotoID = record.id
        noteText = ""
        widthText = ""
        roomText = lastRoom
        levelText = lastLevel
        heightText = ""
        showNote = true
    }

    private func saveNote() {
        guard let id = pendingPhotoID else { return }
        let text = noteText
        let w = PhotoAim.parseMeters(widthText)
        let h = PhotoAim.parseMeters(heightText)
        let room = roomText.trimmingCharacters(in: .whitespaces)
        let level = levelText.trimmingCharacters(in: .whitespaces)
        lastRoom = room
        lastLevel = level
        store.update(projectID) { p in
            if let i = p.photos.firstIndex(where: { $0.id == id }) {
                p.photos[i].note = text
                p.photos[i].width = w
                p.photos[i].height = h
                p.photos[i].room = room.isEmpty ? nil : room
                p.photos[i].level = level.isEmpty ? nil : level
            }
        }
    }

    static func saveRoom(_ room: CapturedRoom, path: [Float], store: ProjectStore, projectID: UUID, sessionID: UUID) {
        let base = store.folder(for: projectID)
        try? FileManager.default.createDirectory(at: base.appendingPathComponent("stanze", isDirectory: true),
                                                 withIntermediateDirectories: true)
        let id = UUID()
        let file = "stanze/\(id.uuidString).json"
        do {
            let data = try JSONEncoder().encode(room)
            try data.write(to: base.appendingPathComponent(file))
            store.update(projectID) { p in
                p.rooms.append(RoomRecord(id: id, name: "Stanza \(p.rooms.count + 1)", file: file,
                                          sessionID: sessionID, date: Date(), path: path))
            }
        } catch {
            print("Salvataggio stanza non riuscito: \(error)")
        }
    }
}
