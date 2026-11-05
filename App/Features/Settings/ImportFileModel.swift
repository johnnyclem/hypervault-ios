import HyperVaultKit
import SwiftUI

/// The Import pane's "A file": one entry that takes any supported file and sends it where it belongs by its type
/// (`FileImport.kind`), as the web's side menu Import does. It answers with what was made, or with the sentence for why not.
@MainActor
@Observable
final class ImportFileModel {
    enum Outcome: Equatable {
        /// A page, or a stored file, was made (or was already there).
        case page(slug: String, duplicate: Bool)
        /// A memory was made. `message` is the server's sentence; `id` is empty if it did not say.
        case memory(id: String, message: String)
        /// It was not kept, and this is why.
        case refused(String)
    }

    private(set) var isBusy = false

    @ObservationIgnored private let client: HVClient
    /// What the server takes, as it says (`AppEnvironment.limits`). Left out, it is a server that says nothing: documents of up
    /// to 4 MB, in the request.
    @ObservationIgnored private let limits: Capabilities.Limits
    /// Carries only the PUT of a file to storage; every call to the app's server goes through `client`.
    @ObservationIgnored private let transport: HTTPTransport

    init(client: HVClient, limits: Capabilities.Limits = Capabilities.Limits(), transport: HTTPTransport = URLSessionTransport()) {
        self.client = client
        self.limits = limits
        self.transport = transport
    }

    /// Reads the file the person picked and keeps it. The file's size is looked at first, so one that is over the limit is
    /// refused without being read. A document becomes a memory on `branch`, the one the person is reading, so that the memory
    /// that opens afterwards is there.
    func keep(_ url: URL, branch: String? = nil) async -> Outcome {
        let name = url.lastPathComponent
        guard let kind = FileImport.kind(ofFilename: name) else { return .refused(FileImport.pickAFile) }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
           let refusal = FileImport.refusal(forFilename: name, kind: kind, byteCount: size, limits: limits) {
            return .refused(refusal)
        }
        guard let data = try? Data(contentsOf: url) else { return .refused("That file couldn't be read.") }
        return await keep(name: name, data: data, branch: branch)
    }

    /// Keeps a file whose bytes are already in hand.
    func keep(name: String, data: Data, branch: String? = nil) async -> Outcome {
        guard let kind = FileImport.kind(ofFilename: name) else { return .refused(FileImport.pickAFile) }
        if let refusal = FileImport.refusal(forFilename: name, kind: kind, byteCount: data.count, limits: limits) { return .refused(refusal) }
        isBusy = true
        defer { isBusy = false }
        do {
            switch kind {
            case .pdf, .image:
                let result = try await ArtifactUploader(client: client, transport: transport).upload(data: data, filename: name)
                return .page(slug: result.slug, duplicate: result.duplicate)
            case .component:
                guard let text = String(data: data, encoding: .utf8) else { return .refused(Self.notText) }
                let result = try await client.send(.saveArtifact(FileImport.saveRequest(componentText: text, filename: name)))
                return .page(slug: result.slug, duplicate: result.duplicate)
            case .html:
                guard let text = String(data: data, encoding: .utf8) else { return .refused(Self.notText) }
                let result = try await client.send(.saveArtifact(FileImport.saveRequest(htmlText: text, filename: name)))
                return .page(slug: result.slug, duplicate: result.duplicate)
            case .document:
                // In the request when it fits, by way of storage when it does not, as the Memorize sheet sends one.
                let kept = try await MemoryFileImporter(client: client, limits: limits, transport: transport)
                    .importFile(filename: name, data: data, branch: branch)
                return .memory(id: kept.id, message: kept.message.isEmpty ? HVCopy.keptInMemoryLine : kept.message)
            case .export:
                return .refused(FileImport.exportElsewhere)
            }
        } catch let error as HVError {
            // A document goes through the memory import, which has sentences of its own for its limits.
            return .refused(kind == .document ? MemoryImportPolicy.message(for: error, limits: limits) : keysMessage(for: error))
        } catch {
            return .refused(keysMessage(for: error))
        }
    }

    private static let notText = "That file isn't text, so it can't be kept as a page."
}
