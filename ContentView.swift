import SwiftUI
import RoomPlan

struct ContentView: View {
    var body: some View {
        if RoomCaptureSession.isSupported {
            ScannerScreen()
        } else {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                Text("Dispositivo non supportato")
                    .font(.headline)
                Text("RoomPlan richiede un iPad o iPhone con sensore LiDAR e iOS/iPadOS 16 o successivo.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .padding(32)
        }
    }
}

struct ScannerScreen: View {
    @StateObject private var scanner = RoomScanner()

    var body: some View {
        ZStack(alignment: .bottom) {
            RoomCaptureViewRepresentable(scanner: scanner)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                if let message = scanner.errorMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                HStack(spacing: 16) {
                    if scanner.isScanning {
                        Button(role: .destructive) {
                            scanner.stop()
                        } label: {
                            Label("Termina scansione", systemImage: "stop.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                    } else if scanner.isProcessing {
                        ProgressView("Elaborazione del rilievo…")
                    } else {
                        Button {
                            scanner.start()
                        } label: {
                            Label(scanner.exportURL == nil ? "Avvia scansione" : "Nuova scansione",
                                  systemImage: "viewfinder")
                        }
                        .buttonStyle(.borderedProminent)

                        if let url = scanner.exportURL {
                            ShareLink(item: url) {
                                Label("Condividi USDZ", systemImage: "square.and.arrow.up")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
                .controlSize(.large)
            }
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding()
        }
    }
}

struct RoomCaptureViewRepresentable: UIViewRepresentable {
    let scanner: RoomScanner

    func makeUIView(context: Context) -> RoomCaptureView {
        scanner.captureView
    }

    func updateUIView(_ uiView: RoomCaptureView, context: Context) {}
}
