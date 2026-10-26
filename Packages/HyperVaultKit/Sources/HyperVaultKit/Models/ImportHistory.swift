import Foundation

// Import: bringing a ChatGPT, Claude, Gemini or Grok history in. The wire is
// `POST /api/import` (app/api/import/route.ts): a JSON body `{ data, platform?,
// title? }` where `data` is the export file's text (or a pasted transcript) and
// the answer is `{ platform, imported, skipped, messages, message }`. The call
// is synchronous (there is no job to poll), up to 60 seconds, and capped at
// 50 MB, so large histories are sent in batches (ImportInspector, ImportRunner).

/// Where a history comes from. `other` is a pasted transcript or a plain
/// `[{ title, messages }]` file.
public enum ImportPlatform: String, Sendable, Codable, CaseIterable, Identifiable, Hashable {
    case chatgpt, claude, gemini, grok, other

    public var id: String { rawValue }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ImportPlatform(rawValue: raw.lowercased()) ?? .other
    }

    public var title: String {
        switch self {
        case .chatgpt: return "ChatGPT"
        case .claude: return "Claude"
        case .gemini: return "Gemini"
        case .grok: return "Grok"
        case .other: return "Pasted text"
        }
    }

    /// The `platform` hint the route understands. Nothing for `other`.
    public var wireName: String? { self == .other ? nil : rawValue }

    /// The export file to look for, in the words the web page uses.
    public var exportFileName: String {
        switch self {
        case .chatgpt, .claude: return "conversations.json"
        case .gemini: return "MyActivity.json"
        case .grok: return "the conversations file in the archive"
        case .other: return "a text file"
        }
    }
}

/// The body of `POST /api/import`.
public struct ImportRequest: Sendable, Encodable {
    public let data: String
    public let platform: String?
    public let title: String?

    public init(data: String, platform: ImportPlatform? = nil, title: String? = nil) {
        self.data = data
        self.platform = platform?.wireName
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    enum CodingKeys: String, CodingKey { case data, platform, title }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(data, forKey: .data)
        try c.encodeIfPresent(platform, forKey: .platform)
        try c.encodeIfPresent(title, forKey: .title)
    }
}

/// What the route answers.
public struct ImportOutcome: Sendable, Decodable, Equatable {
    public let platform: ImportPlatform
    public let imported: Int
    public let skipped: Int
    public let messages: Int
    public let message: String?

    public init(platform: ImportPlatform = .other, imported: Int = 0, skipped: Int = 0, messages: Int = 0, message: String? = nil) {
        self.platform = platform
        self.imported = imported
        self.skipped = skipped
        self.messages = messages
        self.message = message
    }

    enum CodingKeys: String, CodingKey { case platform, imported, skipped, messages, message }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        platform = try c.decodeIfPresent(ImportPlatform.self, forKey: .platform) ?? .other
        imported = try c.decodeIfPresent(Int.self, forKey: .imported) ?? 0
        skipped = try c.decodeIfPresent(Int.self, forKey: .skipped) ?? 0
        messages = try c.decodeIfPresent(Int.self, forKey: .messages) ?? 0
        message = try c.decodeIfPresent(String.self, forKey: .message)
    }
}

/// What a whole import added up to, across every batch.
public struct ImportTotals: Sendable, Equatable {
    public var imported = 0
    /// Conversations the server left out (nothing in them) plus any too large to send.
    public var skipped = 0
    public var messages = 0
    /// Of `skipped`, the ones the server refused as too large even on their own.
    public var tooLarge = 0
    public var batches = 0
    public var lastMessage: String?

    public init() {}

    public mutating func add(_ outcome: ImportOutcome) {
        imported += outcome.imported
        skipped += outcome.skipped
        messages += outcome.messages
        batches += 1
        lastMessage = outcome.message
    }

    /// The sentence for the finish line, in the server's own shape. Numbers are grouped the way the
    /// stats card beside it groups them, and a count of one is singular.
    public func summary(platform: ImportPlatform, locale: Locale = .current) -> String {
        let conversations = "\(imported.formatted(.number.locale(locale))) \(imported == 1 ? "conversation" : "conversations")"
        let said = "\(messages.formatted(.number.locale(locale))) \(messages == 1 ? "message" : "messages")"
        let from = platform == .other ? "" : " from \(platform.title)"
        return "Imported \(conversations) (\(said))\(from). Open Chat to continue them on any backend."
    }
}

/// How far along a run is.
public struct ImportProgress: Sendable, Equatable {
    public var conversationsDone: Int
    public var conversationsTotal: Int
    public var batchesDone: Int
    public var batchesTotal: Int
    public var totals: ImportTotals

    public init(conversationsDone: Int, conversationsTotal: Int, batchesDone: Int, batchesTotal: Int, totals: ImportTotals = ImportTotals()) {
        self.conversationsDone = conversationsDone
        self.conversationsTotal = conversationsTotal
        self.batchesDone = batchesDone
        self.batchesTotal = batchesTotal
        self.totals = totals
    }

    public var fraction: Double {
        guard conversationsTotal > 0 else { return 0 }
        return min(1, Double(conversationsDone) / Double(conversationsTotal))
    }
}

extension Endpoint where Response == ImportOutcome {
    /// Imports one batch. Not retried: a repeat is harmless (the route replaces
    /// a conversation it already has) but doubles a slow call, so the runner
    /// decides when to try again.
    public static func importHistory(_ request: ImportRequest) -> Endpoint<ImportOutcome> {
        Endpoint(.post, "/api/import", body: .json(request), timeout: 100)
    }
}
