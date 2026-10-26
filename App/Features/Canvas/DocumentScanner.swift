import SwiftUI
import Vision
import VisionKit

/// Scan a page with the camera and keep what it says. The text is read on the device.
struct DocumentScanner: UIViewControllerRepresentable {
    static var isSupported: Bool { VNDocumentCameraViewController.isSupported }

    let onText: (String) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onText: onText, onCancel: onCancel)
    }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onText: (String) -> Void
        let onCancel: () -> Void

        init(onText: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
            self.onText = onText
            self.onCancel = onCancel
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            onCancel()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            onCancel()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            let images = (0..<scan.pageCount).map { scan.imageOfPage(at: $0) }
            DispatchQueue.global(qos: .userInitiated).async { [onText] in
                var pages: [String] = []
                for image in images {
                    guard let cgImage = image.cgImage else { continue }
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.usesLanguageCorrection = true
                    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                    try? handler.perform([request])
                    let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                    if !lines.isEmpty { pages.append(lines.joined(separator: "\n")) }
                }
                let text = pages.joined(separator: "\n\n")
                DispatchQueue.main.async { onText(text) }
            }
        }
    }
}
