import Foundation
import RoomPlan
import UIKit

/// Gestisce la sessione RoomPlan e l'esportazione del rilievo in USDZ.
@MainActor
final class RoomScanner: NSObject, ObservableObject, RoomCaptureViewDelegate {
    @Published var isScanning = false
    @Published var isProcessing = false
    @Published var exportURL: URL?
    @Published var errorMessage: String?

    let captureView: RoomCaptureView

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

    // MARK: - Comandi

    func start() {
        exportURL = nil
        errorMessage = nil
        isProcessing = false
        captureView.captureSession.run(configuration: RoomCaptureSession.Configuration())
        isScanning = true
    }

    func stop() {
        guard isScanning else { return }
        captureView.captureSession.stop()
        isScanning = false
        isProcessing = true
    }

    // MARK: - RoomCaptureViewDelegate

    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
        return true
    }

    func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isProcessing = false
            if let error {
                self.errorMessage = "Errore nell'elaborazione: \(error.localizedDescription)"
                return
            }
            self.export(processedResult)
        }
    }

    // MARK: - Esportazione

    private func export(_ room: CapturedRoom) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let fileName = "Rilievo_\(formatter.string(from: Date())).usdz"
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = documents.appendingPathComponent(fileName)

        do {
            try room.export(to: url)
            exportURL = url
        } catch {
            errorMessage = "Esportazione USDZ non riuscita: \(error.localizedDescription)"
        }
    }
}
