import SwiftUI
import VisionKit

@Observable
final class ScannerController {
    @ObservationIgnored weak var scanner: DataScannerViewController?

    static var isSupported: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    func capture() async -> UIImage? {
        try? await scanner?.capturePhoto()
    }
}

private struct DataScannerRepresentable: UIViewControllerRepresentable {
    let controller: ScannerController

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.text()],
            qualityLevel: .accurate,
            recognizesMultipleItems: true,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true
        )
        controller.scanner = scanner
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        if !scanner.isScanning {
            try? scanner.startScanning()
        }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: ()) {
        scanner.stopScanning()
    }
}

/// Full-screen live camera with Live Text highlights and a shutter button.
struct ScannerSheet: View {
    var onCapture: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var controller = ScannerController()
    @State private var isCapturing = false

    var body: some View {
        ZStack(alignment: .bottom) {
            DataScannerRepresentable(controller: controller)
                .ignoresSafeArea()

            HStack {
                Button("Cancel") { dismiss() }
                    .pathSecondaryAction()

                Spacer()

                Button {
                    Task {
                        isCapturing = true
                        let image = await controller.capture()
                        isCapturing = false
                        if let image {
                            dismiss()
                            onCapture(image)
                        }
                    }
                } label: {
                    ZStack {
                        Circle()
                            .strokeBorder(Color.aurora, lineWidth: 4)
                            .frame(width: 80, height: 80)
                        Circle()
                            .fill(Color.ice)
                            .frame(width: 64, height: 64)
                            .scaleEffect(isCapturing ? 0.85 : 1)
                        if isCapturing {
                            ProgressView()
                                .tint(.void)
                        }
                    }
                    .contentShape(.circle)
                    .animation(PathMotion.control, value: isCapturing)
                }
                .buttonStyle(.plain)
                .disabled(isCapturing)
                .accessibilityLabel("Capture")

                Spacer()

                Color.clear.frame(width: 72, height: 1)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }
}
