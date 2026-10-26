import Foundation

// Rooms: group chats between the person and several of their connected
// models (docs/rooms.md). Each member is a backend wearing a handle (`@grok`)
// and an optional role brief. A human message queues the members it addresses
// (everyone, when it addresses nobody); members hand the turn on by
// @mentioning each other; a round has a budget of 12 agent turns. One request
// runs at most three turns, so the client keeps calling `run` until the queue
// drains: `ChatRoomDriver` is that loop.

public struct ChatRoomBackend: Sendable, Codable, Equatable, Hashable {
    public let name: String
    public let provider: String
    public let defaultModel: String?

    public init(name: String, provider: String, defaultModel: String? = nil) {
        self.name = name
        self.provider = provider
        self.defaultModel = defaultModel
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? ""
        defaultModel = try c.decodeIfPresent(String.self, forKey: .defaultModel)
    }

    enum Keys: String, CodingKey { case name, provider, defaultModel }
}

public struct ChatRoomMember: Sendable, Codable, Identifiable, Equatable, Hashable {
    public let id: String
    public let backendId: String
    public let handle: String
    public let roleBrief: String
    public let position: Int
    public let backend: ChatRoomBackend?

    public init(
        id: String, backendId: String, handle: String, roleBrief: String = "", position: Int = 0,
        backend: ChatRoomBackend? = nil
    ) {
        self.id = id
        self.backendId = backendId
        self.handle = handle
        self.roleBrief = roleBrief
        self.position = position
        self.backend = backend
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        backendId = try c.decodeIfPresent(String.self, forKey: .backendId) ?? ""
        handle = try c.decode(String.self, forKey: .handle)
        roleBrief = try c.decodeIfPresent(String.self, forKey: .roleBrief) ?? ""
        position = try c.decodeIfPresent(Int.self, forKey: .position) ?? 0
        backend = try c.decodeIfPresent(ChatRoomBackend.self, forKey: .backend)
    }

    enum Keys: String, CodingKey { case id, backendId, handle, roleBrief, position, backend }
}

/// A member waiting for a turn, and why.
public struct ChatRoomTurn: Sendable, Codable, Equatable, Hashable {
    public let handle: String
    public let reason: String

    public init(handle: String, reason: String = "") {
        self.handle = handle
        self.reason = reason
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        handle = try c.decode(String.self, forKey: .handle)
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
    }

    enum Keys: String, CodingKey { case handle, reason }
}

/// One row of `GET /api/rooms`.
public struct ChatRoomSummary: Sendable, Codable, Identifiable, Equatable, Hashable {
    public let id: String
    public var title: String
    public var pending: [ChatRoomTurn]
    public let createdAt: Date?
    public var updatedAt: Date?
    public var members: [ChatRoomMember]

    public init(
        id: String, title: String, pending: [ChatRoomTurn] = [], createdAt: Date? = nil, updatedAt: Date? = nil,
        members: [ChatRoomMember] = []
    ) {
        self.id = id
        self.title = title
        self.pending = pending
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.members = members
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Untitled room"
        pending = try c.decodeIfPresent([ChatRoomTurn].self, forKey: .pending) ?? []
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
        members = try c.decodeIfPresent([ChatRoomMember].self, forKey: .members) ?? []
    }

    enum Keys: String, CodingKey { case id, title, pending, createdAt, updatedAt, members }
}

/// A vault tool a member used while writing a message.
public struct ChatRoomToolTurn: Sendable, Codable, Equatable, Hashable {
    public let tool: String
    public let ok: Bool
    public let summary: String
    public let url: String?
    public let slug: String?

    public init(tool: String, ok: Bool = true, summary: String = "", url: String? = nil, slug: String? = nil) {
        self.tool = tool
        self.ok = ok
        self.summary = summary
        self.url = url
        self.slug = slug
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        tool = try c.decodeIfPresent(String.self, forKey: .tool) ?? ""
        ok = try c.decodeIfPresent(Bool.self, forKey: .ok) ?? true
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        url = try c.decodeIfPresent(String.self, forKey: .url)
        slug = try c.decodeIfPresent(String.self, forKey: .slug)
    }

    enum Keys: String, CodingKey { case tool, ok, summary, url, slug }
}

public struct ChatRoomMessage: Sendable, Codable, Identifiable, Equatable, Hashable {
    public enum Sender: String, Sendable, Codable, Hashable {
        case human, agent, system

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Sender(rawValue: raw) ?? .system
        }
    }

    public let id: String
    public let position: Int
    public let senderKind: Sender
    public let senderHandle: String?
    public let memberId: String?
    public let content: String
    /// The handles this message addressed.
    public let mentions: [String]
    public let toolTurns: [ChatRoomToolTurn]
    public let model: String?
    /// `error` when the member could not answer; the content says why.
    public let failed: Bool
    public let createdAt: Date?

    public init(
        id: String, position: Int, senderKind: Sender, senderHandle: String? = nil, memberId: String? = nil,
        content: String, mentions: [String] = [], toolTurns: [ChatRoomToolTurn] = [], model: String? = nil,
        failed: Bool = false, createdAt: Date? = nil
    ) {
        self.id = id
        self.position = position
        self.senderKind = senderKind
        self.senderHandle = senderHandle
        self.memberId = memberId
        self.content = content
        self.mentions = mentions
        self.toolTurns = toolTurns
        self.model = model
        self.failed = failed
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        position = try c.decodeIfPresent(Int.self, forKey: .position) ?? 0
        senderKind = try c.decodeIfPresent(Sender.self, forKey: .senderKind) ?? .system
        senderHandle = try c.decodeIfPresent(String.self, forKey: .senderHandle)
        memberId = try c.decodeIfPresent(String.self, forKey: .memberId)
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        mentions = try c.decodeIfPresent([String].self, forKey: .mentions) ?? []
        toolTurns = try c.decodeIfPresent([ChatRoomToolTurn].self, forKey: .toolTurns) ?? []
        model = try c.decodeIfPresent(String.self, forKey: .model)
        failed = (try c.decodeIfPresent(String.self, forKey: .status)) == "error"
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
    }

    enum Keys: String, CodingKey {
        case id, position, senderKind, senderHandle, memberId, content, mentions, toolTurns, model, status, createdAt
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(id, forKey: .id)
        try c.encode(position, forKey: .position)
        try c.encode(senderKind, forKey: .senderKind)
        try c.encodeIfPresent(senderHandle, forKey: .senderHandle)
        try c.encodeIfPresent(memberId, forKey: .memberId)
        try c.encode(content, forKey: .content)
        try c.encode(mentions, forKey: .mentions)
        try c.encode(toolTurns, forKey: .toolTurns)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encode(failed ? "error" : "complete", forKey: .status)
        try c.encodeIfPresent(createdAt, forKey: .createdAt)
    }
}

/// The room header of `GET /api/rooms/[id]`.
public struct ChatRoomHeader: Sendable, Equatable {
    public var id: String
    public var title: String
    public var pending: [ChatRoomTurn]
    /// Agent turns left in this round.
    public var budget: Int
    /// A run holds the room right now (this phone or another client).
    public var running: Bool

    public init(id: String, title: String, pending: [ChatRoomTurn] = [], budget: Int = 0, running: Bool = false) {
        self.id = id
        self.title = title
        self.pending = pending
        self.budget = budget
        self.running = running
    }
}

extension ChatRoomHeader: Decodable {
    enum Keys: String, CodingKey { case id, title, pending, budget, running }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Untitled room"
        pending = try c.decodeIfPresent([ChatRoomTurn].self, forKey: .pending) ?? []
        budget = try c.decodeIfPresent(Int.self, forKey: .budget) ?? 0
        running = try c.decodeIfPresent(Bool.self, forKey: .running) ?? false
    }
}

/// `GET /api/rooms/[id]`: the room, its members and its transcript (the newest
/// 500 messages, or only those past `after`).
public struct ChatRoomDetail: Sendable, Decodable, Equatable {
    public let room: ChatRoomHeader
    public let members: [ChatRoomMember]
    public let messages: [ChatRoomMessage]

    public init(room: ChatRoomHeader, members: [ChatRoomMember], messages: [ChatRoomMessage]) {
        self.room = room
        self.members = members
        self.messages = messages
    }

    enum Keys: String, CodingKey { case room, members, messages }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        room = try c.decode(ChatRoomHeader.self, forKey: .room)
        members = try c.decodeIfPresent([ChatRoomMember].self, forKey: .members) ?? []
        messages = try c.decodeIfPresent([ChatRoomMessage].self, forKey: .messages) ?? []
    }
}

/// What `POST .../messages` and `POST .../run` answer.
public struct ChatRoomRun: Sendable, Decodable, Equatable {
    /// Everything produced by this request (the person's message first).
    public let messages: [ChatRoomMessage]
    /// Turns still queued when the request ran out of time.
    public let pending: [ChatRoomTurn]
    public let budget: Int
    /// Another run holds the room; try again shortly.
    public let busy: Bool

    public init(messages: [ChatRoomMessage] = [], pending: [ChatRoomTurn] = [], budget: Int = 0, busy: Bool = false) {
        self.messages = messages
        self.pending = pending
        self.budget = budget
        self.busy = busy
    }

    enum Keys: String, CodingKey { case messages, pending, budget, busy }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        messages = try c.decodeIfPresent([ChatRoomMessage].self, forKey: .messages) ?? []
        pending = try c.decodeIfPresent([ChatRoomTurn].self, forKey: .pending) ?? []
        budget = try c.decodeIfPresent(Int.self, forKey: .budget) ?? 0
        busy = try c.decodeIfPresent(Bool.self, forKey: .busy) ?? false
    }
}

/// `POST /api/rooms`.
public struct ChatRoomCreated: Sendable, Decodable, Equatable {
    public struct Room: Sendable, Decodable, Equatable {
        public let id: String
        public let title: String
    }

    public let room: Room
    public let members: [ChatRoomMember]
}

/// A member to add: a connected backend wearing a handle.
public struct ChatRoomMemberDraft: Sendable, Equatable, Identifiable {
    public var backendID: String
    public var handle: String
    public var roleBrief: String
    public var id: String { backendID }

    public init(backendID: String, handle: String, roleBrief: String = "") {
        self.backendID = backendID
        self.handle = handle
        self.roleBrief = roleBrief
    }

    var json: JSONValue {
        var object: [String: JSONValue] = ["backend_id": .string(backendID), "handle": .string(handle)]
        let brief = roleBrief.trimmingCharacters(in: .whitespacesAndNewlines)
        if !brief.isEmpty { object["role_brief"] = .string(brief) }
        return .object(object)
    }
}

// MARK: Handles and addressing (lib/rooms/mentions.ts)

public enum ChatRoomHandles {
    /// Longest title the server keeps.
    public static let maxTitle = 120
    /// Longest role brief the server keeps.
    public static let maxRoleBrief = 4_000

    /// Lower-case, URL-safe handle, or nil when none can be made of `raw`.
    public static func normalize(_ raw: String) -> String? {
        var handle = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while handle.hasPrefix("@") { handle.removeFirst() }
        var out = ""
        var pendingDash = false
        for scalar in handle.unicodeScalars {
            let isAllowed = (scalar.value >= 0x61 && scalar.value <= 0x7A) || (scalar.value >= 0x30 && scalar.value <= 0x39)
                || scalar == "_" || scalar == "-"
            if isAllowed {
                out.unicodeScalars.append(scalar)
                pendingDash = false
            } else if !pendingDash {
                out.append("-")
                pendingDash = true
            }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        guard let first = trimmed.unicodeScalars.first, trimmed.count <= 32,
              (first.value >= 0x61 && first.value <= 0x7A) || (first.value >= 0x30 && first.value <= 0x39)
        else { return nil }
        return trimmed
    }

    /// A name to start from: `claude`, `grok`, `gemini`, `gpt`, or the backend's own name.
    public static func defaultHandle(provider: String, name: String) -> String {
        switch provider {
        case "anthropic", "custom-anthropic": return "claude"
        case "xai": return "grok"
        case "gemini": return "gemini"
        case "openai": return "gpt"
        case "mistral": return "mistral"
        default: return normalize(name) ?? provider
        }
    }

    /// Defaults for several backends at once, numbered so no two collide.
    public static func defaultHandles(for backends: [ChatBackend], taken: Set<String> = []) -> [String: String] {
        var used = taken
        var result: [String: String] = [:]
        for backend in backends {
            let base = defaultHandle(provider: backend.provider, name: backend.name)
            var handle = base
            var n = 2
            while used.contains(handle) {
                handle = "\(base)\(n)"
                n += 1
            }
            used.insert(handle)
            result[backend.id] = handle
        }
        return result
    }

    /// The first thing wrong with a set of handles, in plain words, or nil.
    public static func problem(in handles: [String], alreadyTaken: Set<String> = []) -> String? {
        var seen = alreadyTaken
        for raw in handles {
            guard let handle = normalize(raw) else {
                return "\u{201C}\(raw)\u{201D} isn't a usable handle. Use letters, digits, - and _."
            }
            if seen.contains(handle) { return "Two members can't both be @\(handle)." }
            seen.insert(handle)
        }
        return nil
    }

    /// Handles `text` addresses, in first-mention order, restricted to the room's
    /// members: `@handle` anywhere, or a handle opening a message, line or clause
    /// followed by `:` `-` `,` or a second-person word. A handle merely talked
    /// about ("Gemini already finished") does not count.
    public static func mentions(in text: String, handles: [String]) -> [String] {
        guard !text.isEmpty, !handles.isEmpty else { return [] }
        let lowered = text.lowercased()
        let range = NSRange(location: 0, length: (lowered as NSString).length)
        let address = "you|your|you're|youre|please|can|could|would|will"
        var found: [(index: Int, handle: String)] = []
        for handle in handles {
            let escaped = NSRegularExpression.escapedPattern(for: handle.lowercased())
            let patterns = [
                "(?<![a-z0-9_-])@\(escaped)(?![a-z0-9_-])",
                "(?:^|[\\n;.!?]\\s*)(?:and\\s+|then\\s+)?\(escaped)(?=\\s*[:\\-\u{2013}\u{2014},]|\\s+(?:\(address))\\b)",
            ]
            for pattern in patterns {
                guard let expression = try? NSRegularExpression(pattern: pattern),
                      let match = expression.firstMatch(in: lowered, range: range)
                else { continue }
                found.append((match.range.location, handle.lowercased()))
            }
        }
        found.sort { $0.index < $1.index }
        var seen = Set<String>()
        return found.compactMap { seen.insert($0.handle).inserted ? $0.handle : nil }
    }
}
