import HyperVaultKit
import SwiftUI
import UniformTypeIdentifiers

/// What the share sheet is doing: reading what was shared, keeping it, or saving it for later.
@MainActor
@Observable
final class ShareModel {
    enum Phase {
        case loading
        case ready
        case keeping
        case kept(KeptThing, link: String)
        /// No network, or the session needs renewing: it is saved and the app will keep it.
        case queued(signedOut: Bool)
        case empty
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    var text = ""

    /// Reads the shared text and links out of the extension's input items.
    func load(from context: NSExtensionContext?) async {
        var pieces: [String] = []
        let items = (context?.inputItems as? [NSExtensionItem]) ?? []
        for item in items {
            var title = item.attributedTitle?.string ?? item.attributedContentText?.string
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL
                {
                    pieces.append([title, url.absoluteString].compactMap { $0 }.joined(separator: "\n"))
                    title = nil
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                          let value = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier)
                {
                    if let string = value as? String { pieces.append(string) }
                }
            }
            if let title, pieces.isEmpty { pieces.append(title) }
        }
        text = pieces.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        phase = text.isEmpty ? .empty : .ready
    }

    func keep() async {
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        phase = .keeping
        guard let (client, _) = SharedConfig.makeClient() else {
            // The app has never signed in on this phone: hold it until it has.
            OutboxStore.add(OutboxItem(content: content))
            phase = .queued(signedOut: true)
            return
        }
        do {
            let kept = try await client.send(.keep(content: content))
            let base = SharedConfig.server.baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            phase = .kept(kept, link: "\(base)/a/\(kept.slug)")
            Haptics.success()
        } catch {
            let failure = (error as? HVError) ?? .transport(error.localizedDescription)
            if Outbox.shouldRetain(after: failure) {
                OutboxStore.add(OutboxItem(content: content))
                phase = .queued(signedOut: failure == .unauthorized)
            } else {
                phase = .failed(failure.userMessage)
                Haptics.failure()
            }
        }
    }
}
