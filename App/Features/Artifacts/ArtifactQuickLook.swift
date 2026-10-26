import HyperVaultKit
import QuickLook
import SwiftUI
import UIKit

/// A PDF or an image kept as a page, opened in Quick Look: the system's own
/// viewer, with zoom, search, markup and the share sheet.
struct ArtifactQuickLook: UIViewControllerRepresentable {
    let fileURL: URL

    func makeCoordinator() -> Coordinator { Coordinator(fileURL) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let fileURL: URL

        init(_ fileURL: URL) {
            self.fileURL = fileURL
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            fileURL as NSURL
        }
    }
}

/// Downloads a stored file's signed address to a temporary file named for the
/// page, so Quick Look knows what it is.
enum ArtifactFileDownload {
    static func fetch(_ file: ArtifactEmbeddedFile, title: String) async throws -> URL {
        // A copy of a private file belongs in the temporary folder only while it is on screen.
        PrivateTemporaryFiles.removeStale(prefix: "hv-files-")
        let (temporary, response) = try await URLSession.shared.download(from: file.url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw HVError.api(APIFailure(status: http.statusCode, message: "The file couldn't be downloaded just now. Try again in a moment."))
        }
        let ext = file.url.pathExtension.isEmpty ? (file.kind == .pdf ? "pdf" : "png") : file.url.pathExtension
        let safe = title.components(separatedBy: CharacterSet(charactersIn: "/\\:?*\"<>|")).joined(separator: "-")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hv-files-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent("\(safe.isEmpty ? "File" : safe).\(ext)")
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }
}

/// The Quick Look screen: Done, and the file.
struct ArtifactQuickLookScreen: View {
    let file: ArtifactEmbeddedFile
    let title: String

    @Environment(\.dismiss) private var dismiss
    @State private var state: ArtifactLoad<URL> = .loading

    var body: some View {
        NavigationStack {
            Group {
                switch state {
                case .loading:
                    HVLoadingState(message: "Getting the file").frame(maxHeight: .infinity)
                case .failed(let message):
                    HVErrorState(message: message) { Task { await download() } }.frame(maxHeight: .infinity)
                case .loaded(let url):
                    ArtifactQuickLook(fileURL: url)
                }
            }
            .hvScreenBackground()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .task { await download() }
        .onDisappear {
            if case .loaded(let url) = state { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        }
    }

    private func download() async {
        state = .loading
        do {
            state = .loaded(try await ArtifactFileDownload.fetch(file, title: title))
        } catch {
            state = .failed(ArtifactErrors.message(error))
        }
    }
}
