import Foundation

// The rest of the canvas's pure logic, ported from the web app's lib/canvas,
// lib/kept/link.ts, lib/chat/thinking.ts and lib/keep/client.ts, so a message
// means the same on either.

// MARK: Pulling

/// What "Pull the co-parenting notes onto the page" resolves to. Pulling never
/// guesses: it pulls on an exact match of the whole name, or when exactly one
/// thing fits, and otherwise asks.
public enum PullResolution: Sendable, Equatable {
    case one(KeptItem)
    case choose(items: [KeptItem], more: Bool)
    case none
}

public enum PullResolver {
    /// The most things "Which one?" lists.
    public static let maxChoices = 5
    /// How many matches to ask the search for: the route's most.
    public static let searchLimit = 50

    /// Decide from the search results, which come most recently used first.
    public static func resolve(query: String, results: [KeptItem]) -> PullResolution {
        if results.isEmpty { return .none }
        let wanted = CanvasState.nameWords(query)
        let exact = wanted.isEmpty ? [] : results.filter { CanvasState.nameWords($0.name) == wanted }
        if exact.count == 1 { return .one(exact[0]) }
        // Several with the very same whole name are the only ones worth choosing between.
        let fits = exact.count > 1 ? exact : results
        if fits.count == 1 { return .one(fits[0]) }
        return .choose(items: Array(fits.prefix(maxChoices)), more: fits.count > maxChoices)
    }
}

// MARK: Links

/// A link to one of the person's own things, read from a message that is only that link.
public enum VaultLink: Sendable, Equatable {
    case artifact(slug: String)
    case memory(id: String)

    private static let maxLinkChars = 500
    private static let maxSlugChars = 200

    /// What `text` points at, or nil when it is not only a link to a page, file, group or memory
    /// on this origin or a HyperVault host. A link inside a sentence is a sentence.
    public static func parse(_ text: String, origin: URL?) -> VaultLink? {
        let bare = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bare.isEmpty, bare.count <= maxLinkChars, !bare.contains(where: \.isWhitespace) else { return nil }

        var cleaned = bare
        while let first = cleaned.first, "<([\u{201C}\u{2018}\"'".contains(first) { cleaned.removeFirst() }
        while let last = cleaned.last, ">)]\u{201D}\u{2019}\"'.,;:!?".contains(last) { cleaned.removeLast() }
        guard let url = URL(string: cleaned), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.user == nil, url.password == nil, let host = url.host?.lowercased()
        else { return nil }
        guard isOurs(host: host, origin: origin) else { return nil }

        let parts = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if parts.count == 2, parts[0] == "a" || parts[0] == "g" {
            let slug = parts[1].removingPercentEncoding ?? ""
            guard !slug.isEmpty, slug.count <= maxSlugChars, !slug.contains(where: { $0.isWhitespace || $0 == "/" || $0 == "\\" }) else { return nil }
            return .artifact(slug: slug)
        }
        if parts == ["vault", "memory"] {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let id = items.first { $0.name == "open" }?.value?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            let uuid = #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#
            return id.range(of: uuid, options: .regularExpression) != nil ? .memory(id: id) : nil
        }
        return nil
    }

    /// The app's own origin, or any HyperVault vanity host.
    private static func isOurs(host: String, origin: URL?) -> Bool {
        if let originHost = origin?.host?.lowercased(), originHost == host { return true }
        return vanityBases.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// The portfolio of base domains (`lib/domains.ts`).
    static let vanityBases = [
        "hypervault.store", "vault.cool", "agentvault.cloud", "cleon.wiki", "inkbound.ink", "claudedamnit.com",
        "cleon.casa", "cleon.city", "tinderforai.com", "onlywizards.website", "ralphy.website", "permaclaw.com",
        "bo.dy", "memory.baby", "memory.delivery", "smallchat.dev",
    ]
}

// MARK: Pasting

public enum PasteStaging {
    public static let longPasteChars = 400
    public static let multilinePasteChars = 120
    public static let multilinePasteLines = 3

    /// Whether pasted text should wait above the field as a chip (a thing) instead of going
    /// into it (a message). A link is never staged.
    public static func shouldStage(_ text: String) -> Bool {
        let pasted = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // The web measures with JavaScript's `length`, which counts UTF-16 units: a CRLF is two.
        let length = pasted.utf16.count
        guard length >= multilinePasteChars else { return false }
        if pasted.range(of: #"^(?:[a-z][a-z0-9+.-]*://|www\.)\S+$"#, options: [.regularExpression, .caseInsensitive]) != nil { return false }
        if length >= longPasteChars { return true }
        // Lines are split on `\r\n`, `\r` and `\n` alone, as the web does. Swift reads "\r\n" as one
        // Character, so a CRLF is one break; `CharacterSet.newlines` would split it in two and
        // would also count U+0085, U+2028, U+2029, VT and FF.
        let lines = pasted.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }.count
        return lines >= multilinePasteLines
    }
}

// MARK: Reasoning traces

public struct ThinkingSplit: Sendable, Equatable {
    public let text: String
    public let reasoning: String
}

public enum Thinking {
    /// Splits an assistant reply into the visible answer and any `<think>…</think>` trace,
    /// including unbalanced tags: an unclosed `<think>` swallows to the end, an orphan
    /// `</think>` swallows from the start.
    public static func strip(_ raw: String) -> ThinkingSplit {
        let pattern = #"<(/?)think(?:ing)?>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)) != nil
        else { return ThinkingSplit(text: raw.trimmingCharacters(in: .whitespacesAndNewlines), reasoning: "") }

        var visible: [String] = []
        var reasoning: [String] = []
        var cursor = raw.startIndex
        var inThought = false
        for match in regex.matches(in: raw, range: NSRange(raw.startIndex..., in: raw)) {
            guard let full = Range(match.range, in: raw), let slash = Range(match.range(at: 1), in: raw) else { continue }
            let chunk = String(raw[cursor..<full.lowerBound])
            if raw[slash] == "/" {
                reasoning.append(chunk)
                inThought = false
            } else {
                if inThought { reasoning.append(chunk) } else { visible.append(chunk) }
                inThought = true
            }
            cursor = full.upperBound
        }
        let tail = String(raw[cursor...])
        if inThought { reasoning.append(tail) } else { visible.append(tail) }
        return ThinkingSplit(
            text: visible.joined().trimmingCharacters(in: .whitespacesAndNewlines),
            reasoning: reasoning.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        )
    }
}

// MARK: The canvas's chat turn

/// A model the canvas can talk to: a row of `GET /api/backends`, never a key.
public struct CanvasBackend: Sendable, Equatable, Identifiable, Decodable {
    public let id: String
    public let name: String
    public let defaultModel: String?
    public let provider: String?

    public init(id: String, name: String, defaultModel: String? = nil, provider: String? = nil) {
        self.id = id
        self.name = name
        self.defaultModel = defaultModel
        self.provider = provider
    }
}

struct CanvasBackendList: Decodable {
    let backends: [CanvasBackend]
}

/// What the canvas says to `POST /api/chat`. Nothing else rides along: recall always on,
/// tools always off (the canvas has no UI to show a tool run), `pulled` only when there are some.
struct CanvasChatRequest: Encodable, Sendable {
    let backendId: String
    let message: String
    let conversationId: String?
    let useRecall = true
    let useTools = false
    let pulled: [CardRef]?

    init(backendId: String, message: String, conversationId: String?, pulled: [CardRef]) {
        self.backendId = backendId
        self.message = message
        self.conversationId = conversationId
        self.pulled = pulled.isEmpty ? nil : pulled
    }
}

/// One answered canvas turn, reduced to what the canvas shows and keeps.
public struct CanvasTurn: Sendable, Equatable {
    public let conversationId: String
    public let replyId: String?
    public let content: String
    public let truncated: Bool
    /// The names of the pulled things the model was given.
    public let pulledTitles: [String]
}

struct CanvasChatResponse: Decodable, Sendable {
    struct Reply: Decodable, Sendable {
        let id: String?
        let content: String?
        let truncated: Bool?
    }

    struct Pulled: Decodable, Sendable {
        let kind: KeptKind?
        let id: String?
        let title: String?
    }

    let conversationId: String?
    let reply: Reply?
    let pulled: [Pulled]?

    /// Reads one answer the way the web's `readChatResponse` does: an answer with no
    /// conversation or no reply text is a failed turn, never a blank reply.
    func turn() throws -> CanvasTurn {
        guard let conversationId, let content = reply?.content else { throw HVError.decoding(HVCopy.chatFailedLine) }
        let split = Thinking.strip(content)
        let shown = split.text.isEmpty ? split.reasoning : split.text
        guard !shown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HVError.api(APIFailure(status: 502, message: HVCopy.chatFailedLine))
        }
        let titles = (pulled ?? []).compactMap { entry -> String? in
            guard entry.kind != nil, entry.id != nil, let title = entry.title?.trimmingCharacters(in: .whitespaces), !title.isEmpty else { return nil }
            return title
        }
        return CanvasTurn(conversationId: conversationId, replyId: reply?.id, content: shown, truncated: reply?.truncated == true, pulledTitles: titles)
    }
}

extension Endpoint where Response == [CanvasBackend] {
    /// The models the person has connected (`GET /api/backends`), keys and hints left out.
    public static var canvasBackends: Endpoint<[CanvasBackend]> {
        Endpoint(
            method: .get, path: "/api/backends",
            decode: { response, keys in
                try HVCoding.decoder(keys).decode(CanvasBackendList.self, from: response.data).backends
            }
        )
    }
}

extension Endpoint where Response == CanvasTurn {
    /// One canvas turn. Not streaming: the server answers after the whole turn, up to 120 seconds.
    public static func canvasChat(backendId: String, message: String, conversationId: String?, pulled: [CardRef]) -> Endpoint<CanvasTurn> {
        Endpoint(
            method: .post, path: "/api/chat",
            body: .json(CanvasChatRequest(backendId: backendId, message: message, conversationId: conversationId, pulled: pulled)),
            timeout: 130,
            decode: { response, keys in
                let decoded: CanvasChatResponse
                do {
                    decoded = try HVCoding.decoder(keys).decode(CanvasChatResponse.self, from: response.data)
                } catch {
                    throw HVError.api(APIFailure(status: 502, message: HVCopy.chatFailedLine))
                }
                return try decoded.turn()
            }
        )
    }
}

// MARK: Running a command

/// What a command is allowed to act on: the canvas, and nothing on the network.
@MainActor
public protocol CanvasCommandHost: AnyObject {
    var cards: [CanvasCard] { get }
    func dispatch(_ action: CanvasAction)
    func clearThread()
    func keepThis()
    func show(_ target: ShowTarget)
    func pull(_ query: String)
    func pullLink(_ link: VaultLink)
    func showAgentKeys()
    func help()
    var origin: URL? { get }
}

public enum CanvasCommandRunner {
    /// Runs the message as a canvas command if it is one. True means it was handled here
    /// (the caller clears the field and sends nothing); false means an ordinary message.
    @MainActor
    public static func run(_ text: String, host: CanvasCommandHost) -> Bool {
        guard let command = CanvasCommandParser.parse(text) else {
            guard let link = VaultLink.parse(text, origin: host.origin) else { return false }
            host.pullLink(link)
            return true
        }
        switch command {
        case .help:
            if !host.cards.isEmpty { return false }
            host.help()
            return true
        case .hideAll:
            host.dispatch(.hideAll)
            host.clearThread()
            return true
        case .hide(let name):
            guard let card = CanvasState.findCard(named: name, in: host.cards) else { return false }
            host.dispatch(.hide(key: card.key))
            return true
        case .keep:
            host.keepThis()
            return true
        case .show(let target):
            host.show(target)
            return true
        case .pull(let query):
            host.pull(query)
            return true
        case .agentKeys:
            host.showAgentKeys()
            return true
        }
    }
}

// MARK: Spotting a paste

public enum PasteDiff {
    /// The text that was inserted when `old` became `new` in one change, or nil when the change
    /// was not one insertion (typing a letter, deleting, replacing a range). A text field gives no
    /// paste event, but a paste is the one edit that adds a whole page in a single step.
    public static func insertion(old: String, new: String) -> String? {
        guard new.count > old.count else { return nil }
        let oldChars = Array(old)
        let newChars = Array(new)
        var prefix = 0
        while prefix < oldChars.count, oldChars[prefix] == newChars[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < oldChars.count - prefix, oldChars[oldChars.count - 1 - suffix] == newChars[newChars.count - 1 - suffix] { suffix += 1 }
        // Everything of the old text must be accounted for by the shared head and tail.
        guard prefix + suffix == oldChars.count else { return nil }
        return String(newChars[prefix..<(newChars.count - suffix)])
    }
}
