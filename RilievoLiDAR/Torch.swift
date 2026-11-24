import SwiftUI
import AVFoundation

/// Torcia (flash LED) dell'iPad durante la scansione, utile negli ambienti poco illuminati.
enum Torch {
    private static var device: AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    }

    static var isAvailable: Bool { device?.hasTorch ?? false }

    static var isOn: Bool { device?.torchMode == .on }

    /// level da 0,1 a 1 (intensità della luce).
    @discardableResult
    static func set(_ on: Bool, level: Float = 1) -> Bool {
        guard let d = device, d.hasTorch else { return false }
        do {
            try d.lockForConfiguration()
            defer { d.unlockForConfiguration() }
            if on {
                try d.setTorchModeOn(level: max(0.1, min(level, AVCaptureDevice.maxAvailableTorchLevel)))
            } else {
                d.torchMode = .off
            }
            return true
        } catch {
            return false
        }
    }
}

/// Pulsante luce per le schermate di scansione. ARKit può spegnere la torcia quando riavvia
/// la sessione: finché è attiva la riaccende da solo.
struct TorchButton: View {
    @AppStorage("torchLevel") private var level: Double = 1
    @State private var on = false
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        if Torch.isAvailable {
            Menu {
                Button(on ? "Spegni luce" : "Accendi luce") { toggle() }
                Picker("Intensità", selection: $level) {
                    Text("Bassa").tag(0.3)
                    Text("Media").tag(0.6)
                    Text("Alta").tag(1.0)
                }
            } label: {
                Label(on ? "Luce accesa" : "Luce", systemImage: on ? "flashlight.on.fill" : "flashlight.off.fill")
                    .foregroundStyle(on ? Color.yellow : Color.primary)
            } primaryAction: {
                toggle()
            }
            .onChange(of: level) { _, newValue in
                if on { Torch.set(true, level: Float(newValue)) }
            }
            .onReceive(timer) { _ in
                if on && !Torch.isOn { Torch.set(true, level: Float(level)) }
            }
            .onDisappear {
                Torch.set(false)
            }
        }
    }

    private func toggle() {
        on.toggle()
        Torch.set(on, level: Float(level))
    }
}
