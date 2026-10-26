import Foundation

/// The five nouns a person sees. Underneath there are three tables; this is
/// the one place the two vocabularies meet (the web's `lib/kept/kinds.ts`).
public enum KeptKind: String, Sendable, Codable, CaseIterable, Hashable {
    case memory, file, group, key, page

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = KeptKind(rawValue: raw) ?? .page
    }

    public var singular: String {
        switch self {
        case .memory: return "Memory"
        case .file: return "File"
        case .group: return "Group"
        case .key: return "Key"
        case .page: return "Page"
        }
    }
}

/// The four quiet filters of Yours. Files are every artifact: pages and
/// groups included.
public enum YoursFilter: String, Sendable, CaseIterable, Identifiable, Hashable {
    case all, memory, file, key

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: return "All"
        case .memory: return "Memories"
        case .file: return "Files"
        case .key: return "Keys"
        }
    }
}

/// One thing in Yours. `id` is the stored row's own id.
public struct KeptItem: Sendable, Codable, Identifiable, Hashable {
    public let id: String
    public let kind: KeptKind
    public let name: String
    /// One line about it: a memory's digest, or which agents may use a key.
    public let summary: String
    public let updatedAt: Date?
    public let lastOpenedAt: Date?
    /// A path on the server, to put after the origin: `/a/<slug>`.
    public let href: String

    public init(id: String, kind: KeptKind, name: String, summary: String = "", updatedAt: Date? = nil, lastOpenedAt: Date? = nil, href: String = "") {
        self.id = id
        self.kind = kind
        self.name = name
        self.summary = summary
        self.updatedAt = updatedAt
        self.lastOpenedAt = lastOpenedAt
        self.href = href
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decodeIfPresent(KeptKind.self, forKey: .kind) ?? .page
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled"
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
        lastOpenedAt = try c.decodeIfPresent(Date.self, forKey: .lastOpenedAt)
        href = try c.decodeIfPresent(String.self, forKey: .href) ?? ""
    }

    enum Keys: String, CodingKey { case id, kind, name, summary, updatedAt, lastOpenedAt, href }

    /// The artifact slug when this is a page, file or group (`/a/<slug>`, `/g/<slug>`).
    public var slug: String? {
        let parts = href.split(separator: "/").map(String.init)
        guard parts.count >= 2, parts[0] == "a" || parts[0] == "g" || parts[0] == "c" else { return nil }
        return parts[1]
    }
}

public struct YoursList: Sendable, Codable, Equatable {
    public let recent: [KeptItem]
    public let results: [KeptItem]

    public init(recent: [KeptItem] = [], results: [KeptItem] = []) {
        self.recent = recent
        self.results = results
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        recent = try c.decodeIfPresent([KeptItem].self, forKey: .recent) ?? []
        results = try c.decodeIfPresent([KeptItem].self, forKey: .results) ?? []
    }

    enum Keys: String, CodingKey { case recent, results }
}

extension KeptItem: Equatable {}

/// An agent that may use a key. Never its own key: only what names it.
public struct CardAgent: Sendable, Codable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let keyPrefix: String

    public init(id: String, name: String, keyPrefix: String) {
        self.id = id
        self.name = name
        self.keyPrefix = keyPrefix
    }
}

public struct GroupMember: Sendable, Codable, Hashable {
    public let path: String
    public let sizeBytes: Int
}

/// What a card on the canvas shows about the thing it stands for
/// (`GET /api/yours/card`). Nothing here can hold a secret or a file's content.
public struct KeptCard: Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: KeptKind
    public let name: String
    public let href: String
    /// A memory's digest.
    public let digest: String?
    public let updatedAt: Date?
    /// A group's files, by path and size.
    public let files: [GroupMember]
    /// A key's last use, who may use it and who could be let.
    public let lastUsedAt: Date?
    public let agents: [CardAgent]
    public let available: [CardAgent]

    public var slug: String? {
        let parts = href.split(separator: "/").map(String.init)
        return parts.count >= 2 ? parts[1] : nil
    }
}

extension KeptCard: Decodable {
    enum Keys: String, CodingKey {
        case id, kind, name, href, digest, updatedAt, files, lastUsedAt, agents, available
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decodeIfPresent(KeptKind.self, forKey: .kind) ?? .page
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled"
        href = try c.decodeIfPresent(String.self, forKey: .href) ?? ""
        digest = try c.decodeIfPresent(String.self, forKey: .digest)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
        files = try c.decodeIfPresent([GroupMember].self, forKey: .files) ?? []
        lastUsedAt = try c.decodeIfPresent(Date.self, forKey: .lastUsedAt)
        agents = try c.decodeIfPresent([CardAgent].self, forKey: .agents) ?? []
        available = try c.decodeIfPresent([CardAgent].self, forKey: .available) ?? []
    }
}

/// What `POST /api/keep` answers.
public struct KeptThing: Sendable, Codable, Equatable {
    public let slug: String
    public let url: String
    public let kind: KeptKind
    /// What the paste was recognised as: `note`, `html` or `jsx`.
    public let form: String
    public let title: String
    /// Read this rather than assume private.
    public let visibility: String
    public let duplicate: Bool
    public let message: String

    public var isPrivate: Bool { visibility == "private" }

    public init(slug: String, url: String, kind: KeptKind = .page, form: String = "note", title: String, visibility: String = "private", duplicate: Bool = false, message: String = "") {
        self.slug = slug
        self.url = url
        self.kind = kind
        self.form = form
        self.title = title
        self.visibility = visibility
        self.duplicate = duplicate
        self.message = message
    }
}

/// What `POST /api/keep` takes as `source_prompt`: at most 10,000 characters as the server counts
/// them, which is UTF-16 units (a JavaScript string's length), not Swift Characters. A longer one is a
/// 400, not a trim, so it is clipped as the web does (`trim().slice(0, 10000)`), but only between
/// characters, never through an emoji or a pair of units that belong together.
public enum SourcePrompt {
    public static let limit = 10_000

    /// The prompt trimmed and, if it is over the limit, cut at the last whole character that fits.
    /// Nil when nothing is left, so the field is left out as the web leaves it out.
    public static func clipped(_ prompt: String, to limit: Int = SourcePrompt.limit) -> String? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf16.count > limit else { return trimmed.isEmpty ? nil : trimmed }
        var kept = ""
        var units = 0
        for character in trimmed {
            units += String(character).utf16.count
            if units > limit { break }
            kept.append(character)
        }
        return kept.isEmpty ? nil : kept
    }
}

public struct KeepRequest: Sendable, Encodable {
    public let content: String
    public let title: String?
    public let sourcePrompt: String?

    /// Every way of keeping goes through here, so a prompt that is too long for the server is clipped
    /// whoever sends it: the canvas, a kept chat reply, or the share-sheet outbox.
    public init(content: String, title: String? = nil, sourcePrompt: String? = nil) {
        self.content = content
        self.title = title
        self.sourcePrompt = sourcePrompt.flatMap { SourcePrompt.clipped($0) }
    }
}

extension Endpoint where Response == KeptThing {
    /// Keeps one thing and returns its private link. The server decides whether
    /// it is a note, an HTML page or a React page.
    public static func keep(content: String, title: String? = nil, sourcePrompt: String? = nil) -> Endpoint<KeptThing> {
        Endpoint(.post, "/api/keep", body: .json(KeepRequest(content: content, title: title, sourcePrompt: sourcePrompt)))
    }
}

extension Endpoint where Response == YoursList {
    public static func yours(filter: YoursFilter = .all, query: String? = nil, limit: Int? = nil) -> Endpoint<YoursList> {
        Endpoint(.get, "/api/yours", query: .make([
            ("kind", filter.rawValue),
            ("q", query?.trimmingCharacters(in: .whitespaces)),
            ("limit", limit.map(String.init)),
        ]))
    }
}

extension Endpoint where Response == KeptCard {
    public static func card(kind: KeptKind, id: String) -> Endpoint<KeptCard> {
        Endpoint(.get, "/api/yours/card", query: .make([("kind", kind.rawValue), ("id", id)]))
    }

    /// A card from a pasted link, which carries a slug and no id.
    public static func card(slug: String) -> Endpoint<KeptCard> {
        Endpoint(.get, "/api/yours/card", query: .make([("slug", slug)]))
    }
}

/// `POST /api/yours/open` answers `{ persisted, hint? }`; the app fires it and moves on.
public struct OpenStamp: Sendable, Decodable {
    public let persisted: Bool?
}

extension Endpoint where Response == OpenStamp {
    /// Makes a thing the most recent in Yours.
    public static func markOpened(kind: KeptKind, id: String) -> Endpoint<OpenStamp> {
        Endpoint(.post, "/api/yours/open", body: .jsonValue(["kind": .string(kind.rawValue), "id": .string(id)]))
    }
}
