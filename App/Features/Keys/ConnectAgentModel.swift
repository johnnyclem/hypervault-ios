import HyperVaultKit
import SwiftUI

/// Connecting an agent: pick the app it lives in, make a key for it (once per opening), and get that
/// app's steps and strings with the key filled in. The steps come from the server (GET /connect.md?client=<id>,
/// the registry the web serves to agents); the key is filled in here and goes nowhere.
///
/// The key exists in `fresh` and nowhere else. `wipe()` drops it when the sheet closes; it is never saved
/// and never logged. The model does not look for the agent to connect: no route reports the server's check of
/// the setup challenge, so the sheet tells what to do next and claims nothing about the result.
@MainActor
@Observable
final class ConnectAgentModel {
    struct FreshKey {
        let key: String
        let prefix: String
        let challengeSlug: String?
    }

    enum MakePhase {
        case idle
        case making
        case failed(String)
    }

    enum DocumentState {
        case loading
        case loaded(markdown: String, guide: ConnectGuide)
        case failed(String)
    }

    var query = ""
    /// What the key is called. Prefilled with the app's name, as the canvas's connect sheet names it.
    var keyName = ""
    var canSendMail = false

    private(set) var make: MakePhase = .idle
    private(set) var fresh: FreshKey?
    private(set) var documents: [String: DocumentState] = [:]
    private(set) var copied = false

    /// Set when the sheet shows the steps of a key made earlier: its raw value is gone, so strings carry a placeholder.
    let existingKey: AgentKey?
    let existingSlug: String?

    private let client: HVClient
    private let cache: DiskCache
    let origin: String

    init(client: HVClient, cache: DiskCache, origin: String, existingKey: AgentKey? = nil, challengeSlug: String? = nil) {
        self.client = client
        self.cache = cache
        self.origin = origin
        self.existingKey = existingKey
        self.existingSlug = challengeSlug
    }

    // MARK: Picking

    var results: [AgentClientInfo] { AgentClientCatalog.search(query) }

    /// A key was made and has not been copied: closing now would lose it.
    var hasUncopiedKey: Bool { fresh != nil && !copied }

    func markCopied() { copied = true }

    // MARK: Making the key

    func prepare(for info: AgentClientInfo?) {
        if keyName.isEmpty, fresh == nil { keyName = String((info?.name ?? "").prefix(AgentKeyRules.nameMaxLength)) }
    }

    func makeKey() async {
        guard fresh == nil else { return }
        make = .making
        do {
            let minted = try await client.send(.createAgentKey(name: keyName, canSendMail: canSendMail))
            fresh = FreshKey(key: minted.key, prefix: minted.prefix, challengeSlug: minted.challenge?.slug)
            make = .idle
            Haptics.success()
        } catch {
            make = .failed(keysMessage(for: error))
            Haptics.failure()
        }
    }

    /// Drops the key and everything built from it. Called when the sheet goes away.
    func wipe() {
        fresh = nil
        copied = false
        keyName = ""
    }

    // MARK: The steps

    func loadDocument(for info: AgentClientInfo) async {
        let id = info.id
        if case .loaded = documents[id] { return }
        if documents[id] == nil { documents[id] = .loading }
        let client = self.client
        do {
            let stream = cachedLoad(cache: cache, namespace: "app", key: "connect.\(id)") {
                try await client.send(.connectDocument(clientID: id))
            }
            for try await loaded in stream {
                let guide = ConnectGuide.parse(loaded.value)
                documents[id] = guide.isEmpty ? .failed("The steps for this one came back empty. Try again in a moment.") : .loaded(markdown: loaded.value, guide: guide)
            }
        } catch {
            if case .loaded = documents[id] {} else {
                let message = (error as? HVError)?.isNotFound == true
                    ? "The server does not list this app any more. Pick another, or choose Any agent that can make HTTP requests."
                    : keysMessage(for: error)
                documents[id] = .failed(message)
            }
        }
    }

    private var slug: String? { fresh?.challengeSlug ?? existingSlug }

    private var keyText: String? { fresh?.key }

    /// The client's steps and strings, with the key (when there is one) and its challenge slug filled in.
    func guide(for info: AgentClientInfo) -> ConnectGuide? {
        guard case .loaded(_, let guide) = documents[info.id] else { return nil }
        return guide.filled(with: keyText, challengeSlug: slug)
    }

    /// The text to paste into the AI: the client's page with the key in it. Without a fetched page, a pointer to it.
    func prompt(for info: AgentClientInfo) -> String {
        let key = keyText ?? ConnectKey.placeholder
        if case .loaded(let markdown, _) = documents[info.id] {
            return ConnectPrompt.make(clientName: info.name, document: markdown, key: key, challengeSlug: slug)
        }
        return ConnectPrompt.pointer(clientName: info.name, clientID: info.id, origin: origin, key: key)
    }

    /// Whether `text` carries the real key, so it is copied the way a secret is.
    func isSecret(_ text: String) -> Bool {
        guard let key = keyText else { return false }
        return text.contains(key)
    }
}
