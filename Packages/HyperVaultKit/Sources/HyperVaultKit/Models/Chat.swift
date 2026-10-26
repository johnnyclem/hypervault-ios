import Foundation

// Chat: conversations, messages, and one turn with a model.
//
// TALKING TO A MODEL FROM ANOTHER SCREEN (the canvas does this)
//
//     let backends = try await client.send(.backends)                // [ChatBackend]
//     var options = ChatSendOptions()
//     options.pulled = [ChatPulledRef(kind: .memory, id: "...")]     // what is on the page
//     let turn = try await client.send(
//         .chat(backendID: backend.id, message: text, conversationID: nil, options: options)
//     )
//     turn.reply.content        // the answer, `<think>` traces already removed from `text`
//     turn.conversationID       // pass it back to continue the same thread
//     turn.grounding            // recalled pages and memories, deep memory, truth, pulled, tools
//
// `POST /api/chat` is NOT streaming. The server runs the whole turn (recall,
// the model, up to four tool round trips) and answers once, up to 120 seconds
// later, so `Endpoint.chat` waits 130 seconds. Cancel by cancelling the Task.
// Failures arrive as `HVError.api` carrying the server's own sentence:
//   400  backend_id or message missing, `truth_ledgers` malformed
//   404  "Backend not found - connect one first." / "Conversation not found."
//   413  "Message is too long."  (limit: Capabilities.Limits.chatMessageChars)
//   502  the model's endpoint failed; the message says how
//   500  could not create the conversation, or "Reply received but not saved: ..."
//   503  the server is not configured
// A `transport` error does not mean the turn was lost: the server may have
// finished and saved it. `ChatTurnReconciler` finds out.
//
// The response is decoded with the server's keys verbatim (`tool_selection`
// carries argument objects whose keys must survive), so every model below that
// decodes from `POST /api/chat` spells its own CodingKeys.

// MARK: Conversations

/// Who may read a conversation. Chats are born private; the first move away
/// from private mints a share link that stays stable when flipped back.
public enum ChatVisibility: String, Sendable, Codable, CaseIterable, Hashable {
    case `private`
    case shared
    case `public`

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ChatVisibility(rawValue: raw) ?? .private
    }

    public var title: String {
        switch self {
        case .private: return "Private"
        case .shared: return "Shared"
        case .public: return "Public"
        }
    }

    /// One calm line about what the setting means.
    public var detail: String {
        switch self {
        case .private: return "Only you can open this chat."
        case .shared: return "Anyone with the link can read this chat."
        case .public: return "Anyone can find and read this chat."
        }
    }

    public var hasLink: Bool { self != .private }
}

/// Where a conversation came from, in the words the web shows.
public enum ChatPlatform: Sendable, Hashable {
    case chatgpt, claude, gemini, grok, hypervault, other(String)

    public init(_ raw: String) {
        switch raw.lowercased() {
        case "chatgpt": self = .chatgpt
        case "claude": self = .claude
        case "gemini": self = .gemini
        case "grok": self = .grok
        case "hypervault": self = .hypervault
        default: self = .other(raw)
        }
    }

    public var label: String {
        switch self {
        case .chatgpt: return "ChatGPT"
        case .claude: return "Claude"
        case .gemini: return "Gemini"
        case .grok: return "Grok"
        case .hypervault: return "HyperVault"
        case .other: return "Imported"
        }
    }

    /// Brought in from another service rather than started here.
    public var isImported: Bool { self != .hypervault }
}

/// One row of `GET /api/conversations`, and the `conversation` of the detail
/// and visibility routes.
public struct ChatConversation: Sendable, Codable, Identifiable, Equatable, Hashable {
    public let id: String
    public var title: String
    public let sourcePlatform: String
    public let model: String?
    public let createdAt: Date?
    public var updatedAt: Date?
    public var visibility: ChatVisibility
    public var shareSlug: String?

    public init(
        id: String, title: String, sourcePlatform: String = "hypervault", model: String? = nil,
        createdAt: Date? = nil, updatedAt: Date? = nil, visibility: ChatVisibility = .private, shareSlug: String? = nil
    ) {
        self.id = id
        self.title = title
        self.sourcePlatform = sourcePlatform
        self.model = model
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.visibility = visibility
        self.shareSlug = shareSlug
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Untitled"
        sourcePlatform = try c.decodeIfPresent(String.self, forKey: .sourcePlatform) ?? "hypervault"
        model = try c.decodeIfPresent(String.self, forKey: .model)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
        // A database from before sharing sends neither column: everything is private.
        visibility = try c.decodeIfPresent(ChatVisibility.self, forKey: .visibility) ?? .private
        shareSlug = try c.decodeIfPresent(String.self, forKey: .shareSlug)
    }

    enum Keys: String, CodingKey { case id, title, sourcePlatform, model, createdAt, updatedAt, visibility, shareSlug }

    public var platform: ChatPlatform { ChatPlatform(sourcePlatform) }

    /// The page for a shared chat, relative to the server: `/c/<slug>`.
    public var sharePath: String? {
        guard visibility.hasLink, let shareSlug, !shareSlug.isEmpty else { return nil }
        return "/c/\(shareSlug)"
    }
}

/// A thumbs rating on an assistant reply. The wire stores 1 and -1.
public enum ChatFeedback: String, Sendable, Codable, Hashable {
    case up, down

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Int.self) {
            self = number < 0 ? .down : .up
        } else {
            let raw = try container.decode(String.self)
            self = raw == "down" ? .down : .up
        }
    }
}

public enum ChatRole: String, Sendable, Codable, Hashable {
    case system, user, assistant, tool

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ChatRole(rawValue: raw) ?? .system
    }
}

/// A saved message, as `GET /api/conversations/[id]` lists them.
public struct ChatMessage: Sendable, Codable, Identifiable, Equatable, Hashable {
    public let id: String
    public let role: ChatRole
    public let content: String
    public let model: String?
    public let position: Int
    public let createdAt: Date?
    public var feedback: ChatFeedback?

    public init(
        id: String, role: ChatRole, content: String, model: String? = nil, position: Int = 0,
        createdAt: Date? = nil, feedback: ChatFeedback? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.model = model
        self.position = position
        self.createdAt = createdAt
        self.feedback = feedback
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        role = try c.decodeIfPresent(ChatRole.self, forKey: .role) ?? .assistant
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        model = try c.decodeIfPresent(String.self, forKey: .model)
        position = try c.decodeIfPresent(Int.self, forKey: .position) ?? 0
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        feedback = try? c.decodeIfPresent(ChatFeedback.self, forKey: .feedback)
    }

    enum Keys: String, CodingKey { case id, role, content, model, position, createdAt, feedback }
}

/// `GET /api/conversations/[id]`: the conversation and its whole history.
public struct ChatConversationDetail: Sendable, Codable, Equatable {
    public let conversation: ChatConversation
    public let messages: [ChatMessage]

    public init(conversation: ChatConversation, messages: [ChatMessage]) {
        self.conversation = conversation
        self.messages = messages
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        conversation = try c.decode(ChatConversation.self, forKey: .conversation)
        messages = try c.decodeIfPresent([ChatMessage].self, forKey: .messages) ?? []
    }

    enum Keys: String, CodingKey { case conversation, messages }
}

/// `PATCH /api/conversations/[id]` with a visibility.
public struct ChatVisibilityChange: Sendable, Decodable, Equatable {
    public let conversation: ChatConversation
    /// A path to put after the server's origin: `/c/<slug>`. Nil while private.
    public let shareUrl: String?
    /// The server's sentence: "Anyone with the link can now read this chat."
    public let message: String?
}

// MARK: Settings

/// `GET/PATCH /api/chat-settings`: the context switches that persist across
/// sessions. Each send also carries the current value, so a failed save costs
/// nothing in the session at hand.
public struct ChatSettings: Sendable, Codable, Equatable {
    public var smartContext: Bool
    public var deepMemory: Bool
    public var polytician: Bool
    public var truth: Bool

    public init(smartContext: Bool = true, deepMemory: Bool = true, polytician: Bool = true, truth: Bool = true) {
        self.smartContext = smartContext
        self.deepMemory = deepMemory
        self.polytician = polytician
        self.truth = truth
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        smartContext = try c.decodeIfPresent(Bool.self, forKey: .smartContext) ?? true
        deepMemory = try c.decodeIfPresent(Bool.self, forKey: .deepMemory) ?? true
        polytician = try c.decodeIfPresent(Bool.self, forKey: .polytician) ?? true
        truth = try c.decodeIfPresent(Bool.self, forKey: .truth) ?? true
    }

    enum Keys: String, CodingKey { case smartContext, deepMemory, polytician, truth }
}

/// `GET /api/toolkits`, reduced to the one fact the composer needs: whether
/// there are compiled tools to use.
public struct ChatToolkitStatus: Sendable, Equatable, Codable {
    public let hasToolkit: Bool
    public let stale: Bool

    public init(hasToolkit: Bool, stale: Bool = false) {
        self.hasToolkit = hasToolkit
        self.stale = stale
    }
}

// MARK: One turn with a model

/// A thing the person has on their canvas, handed to the model by name. The
/// server reads the ones the account owns; anything else is left out silently.
public struct ChatPulledRef: Sendable, Hashable, Codable {
    public let kind: KeptKind
    public let id: String

    public init(kind: KeptKind, id: String) {
        self.kind = kind
        self.id = id
    }

    var json: JSONValue { ["kind": .string(kind.rawValue), "id": .string(id)] }
}

/// What the model was given from the canvas: the thing by name, never its text.
public struct ChatPulledUse: Sendable, Hashable, Codable, Identifiable {
    public let kind: KeptKind
    public let id: String
    public let title: String

    public init(kind: KeptKind, id: String, title: String) {
        self.kind = kind
        self.id = id
        self.title = title
    }
}

/// A page the server recalled to ground a reply.
public struct ChatRecalledPage: Sendable, Hashable, Codable, Identifiable {
    public let title: String
    public let slug: String
    public var id: String { slug }

    public init(title: String, slug: String) {
        self.title = title
        self.slug = slug
    }
}

/// How the truth ledger grounded one reply.
public struct ChatTruthSummary: Sendable, Hashable, Codable {
    public let cited: Int
    public let contested: Int
    public let flags: Int
    public let drafted: Int
    public let ledgers: [String]

    public init(cited: Int = 0, contested: Int = 0, flags: Int = 0, drafted: Int = 0, ledgers: [String] = []) {
        self.cited = cited
        self.contested = contested
        self.flags = flags
        self.drafted = drafted
        self.ledgers = ledgers
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        cited = try c.decodeIfPresent(Int.self, forKey: .cited) ?? 0
        contested = try c.decodeIfPresent(Int.self, forKey: .contested) ?? 0
        flags = try c.decodeIfPresent(Int.self, forKey: .flags) ?? 0
        drafted = try c.decodeIfPresent(Int.self, forKey: .drafted) ?? 0
        ledgers = try c.decodeIfPresent([String].self, forKey: .ledgers) ?? []
    }

    enum Keys: String, CodingKey { case cited, contested, flags, drafted, ledgers }

    /// The footnote the web shows: "Cited 3 ledger entries, 1 contested".
    public var footnote: String? {
        guard cited > 0 else { return nil }
        var parts = ["Cited \(cited) ledger entr\(cited == 1 ? "y" : "ies")"]
        if contested > 0 { parts.append("\(contested) contested") }
        if flags > 0 { parts.append("\(flags) unverified flag\(flags == 1 ? "" : "s")") }
        if drafted > 0 { parts.append("\(drafted) draft\(drafted == 1 ? "" : "s") staged") }
        return parts.joined(separator: ", ")
    }
}

/// One step of tool use inside a turn: the model said what it wanted done and
/// the server resolved it to a tool. Also read back from saved history.
public struct ChatToolTurn: Sendable, Hashable, Codable, Identifiable {
    public struct Refinement: Sendable, Hashable, Codable {
        public struct Option: Sendable, Hashable, Codable {
            public let label: String
            public let intent: String
            public let canonical: String?

            public init(label: String, intent: String, canonical: String? = nil) {
                self.label = label
                self.intent = intent
                self.canonical = canonical
            }
        }

        public let question: String
        public let options: [Option]

        public init(question: String, options: [Option]) {
            self.question = question
            self.options = options
        }
    }

    public let id: UUID
    public let intent: String
    public let tool: String?
    public let ok: Bool
    public let confidence: Double?
    public let tier: String?
    public let preview: String?
    public let error: String?
    public let refinement: Refinement?

    public init(
        intent: String, tool: String? = nil, ok: Bool = true, confidence: Double? = nil, tier: String? = nil,
        preview: String? = nil, error: String? = nil, refinement: Refinement? = nil, id: UUID = UUID()
    ) {
        self.id = id
        self.intent = intent
        self.tool = tool
        self.ok = ok
        self.confidence = confidence
        self.tier = tier
        self.preview = preview
        self.error = error
        self.refinement = refinement
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = UUID()
        intent = try c.decodeIfPresent(String.self, forKey: .intent) ?? ""
        tool = try c.decodeIfPresent(String.self, forKey: .tool)
        ok = try c.decodeIfPresent(Bool.self, forKey: .ok) ?? true
        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence)
        tier = try c.decodeIfPresent(String.self, forKey: .tier)
        preview = try c.decodeIfPresent(String.self, forKey: .preview)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        refinement = try c.decodeIfPresent(Refinement.self, forKey: .refinement)
    }

    enum Keys: String, CodingKey { case id, intent, tool, ok, confidence, tier, preview, error, refinement }

    /// The line that stands for this step: `"fetch a url" -> web.fetch`.
    public var summary: String {
        guard let tool, !tool.isEmpty else { return "\u{201C}\(intent)\u{201D}" }
        return "\u{201C}\(intent)\u{201D} \u{2192} \(tool)"
    }

    /// What expanding the step shows: the error, else the result preview.
    public var detail: String? { error ?? preview }

    /// "high 92%": the confidence tier with its rounded percentage.
    public var tierLabel: String? {
        guard let tier, !tier.isEmpty else { return nil }
        if let confidence { return "\(tier) \(Int((confidence * 100).rounded()))%" }
        return tier
    }
}

/// Whether the turn used the person's compiled tools.
public struct ChatToolsReport: Sendable, Hashable, Codable {
    public enum Status: String, Sendable, Codable, Hashable {
        case ok, off, stale

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Status(rawValue: raw) ?? .off
        }
    }

    public struct Embedder: Sendable, Hashable, Codable {
        public let label: String
        public let lexical: Bool
        public let upgradeAvailable: Bool
        public let detail: String?

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
            lexical = try c.decodeIfPresent(Bool.self, forKey: .lexical) ?? false
            upgradeAvailable = try c.decodeIfPresent(Bool.self, forKey: .upgradeAvailable) ?? false
            detail = try c.decodeIfPresent(String.self, forKey: .detail)
        }

        enum Keys: String, CodingKey { case label, lexical, upgradeAvailable = "upgrade_available", detail }
    }

    public let status: Status
    public let toolkitId: String?
    public let turns: [ChatToolTurn]
    public let embedder: Embedder?

    public static let off = ChatToolsReport(status: .off, toolkitId: nil, turns: [], embedder: nil)

    public init(status: Status, toolkitId: String? = nil, turns: [ChatToolTurn] = [], embedder: Embedder? = nil) {
        self.status = status
        self.toolkitId = toolkitId
        self.turns = turns
        self.embedder = embedder
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        status = try c.decodeIfPresent(Status.self, forKey: .status) ?? .off
        toolkitId = try c.decodeIfPresent(String.self, forKey: .toolkitId)
        turns = try c.decodeIfPresent([ChatToolTurn].self, forKey: .turns) ?? []
        embedder = try? c.decodeIfPresent(Embedder.self, forKey: .embedder)
    }

    enum Keys: String, CodingKey { case status, toolkitId = "toolkit_id", turns, embedder }

    /// A sentence for the person when tools could not be used, nil otherwise.
    public var notice: String? {
        guard status == .stale else { return nil }
        return embedder?.detail ?? "Your tools were set up with a different configuration. Set them up again under Tools."
    }
}

/// A choice the server could not make for the model: which tool to run.
public struct ChatToolSelection: Sendable, Hashable, Codable {
    public struct Option: Sendable, Hashable, Codable, Identifiable {
        public let label: String
        public let canonical: String
        public let args: JSONValue
        public var id: String { canonical }

        public init(label: String, canonical: String, args: JSONValue = [:]) {
            self.label = label
            self.canonical = canonical
            self.args = args
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
            canonical = try c.decode(String.self, forKey: .canonical)
            args = try c.decodeIfPresent(JSONValue.self, forKey: .args) ?? [:]
        }

        enum Keys: String, CodingKey { case label, canonical, args }
    }

    public let intent: String
    public let question: String
    public let options: [Option]

    public init(intent: String, question: String, options: [Option]) {
        self.intent = intent
        self.question = question
        self.options = options
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        intent = try c.decodeIfPresent(String.self, forKey: .intent) ?? ""
        question = try c.decodeIfPresent(String.self, forKey: .question) ?? ""
        options = try c.decodeIfPresent([Option].self, forKey: .options) ?? []
    }

    enum Keys: String, CodingKey { case intent, question, options }
}

/// What a reply was grounded in. Built from a turn (or from the context an
/// on-device model was given); empty when the model went on its own.
public struct ChatGrounding: Sendable, Hashable, Codable {
    public var pages: [ChatRecalledPage]
    public var memories: [String]
    public var deepMemory: [String]
    public var truth: ChatTruthSummary?
    public var pulled: [ChatPulledUse]
    public var smartContext: Bool

    public static let none = ChatGrounding()

    public init(
        pages: [ChatRecalledPage] = [], memories: [String] = [], deepMemory: [String] = [],
        truth: ChatTruthSummary? = nil, pulled: [ChatPulledUse] = [], smartContext: Bool = false
    ) {
        self.pages = pages
        self.memories = memories
        self.deepMemory = deepMemory
        self.truth = truth
        self.pulled = pulled
        self.smartContext = smartContext
    }

    public var isEmpty: Bool {
        pages.isEmpty && memories.isEmpty && deepMemory.isEmpty && (truth?.cited ?? 0) == 0 && pulled.isEmpty
    }
}

/// `POST /api/chat`: one answered turn.
public struct ChatTurnResponse: Sendable, Equatable, Decodable {
    public struct Reply: Sendable, Equatable, Decodable {
        /// The saved message's id, which thumbs and "Keep this" need. Nil only
        /// if the server could not say.
        public let id: String?
        public let content: String
        public let model: String?
        /// The model stopped at its length limit even after continuing.
        public let truncated: Bool

        public init(id: String?, content: String, model: String? = nil, truncated: Bool = false) {
            self.id = id
            self.content = content
            self.model = model
            self.truncated = truncated
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            id = try c.decodeIfPresent(String.self, forKey: .id)
            content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
            model = try c.decodeIfPresent(String.self, forKey: .model)
            truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
        }

        enum Keys: String, CodingKey { case id, content, model, truncated }

        /// The reply without reasoning traces, falling back to the trace when
        /// the whole reply is one.
        public var text: String { Thinking.strip(content).shown }
    }

    public struct Backend: Sendable, Equatable, Decodable {
        public let id: String
        public let name: String
        public let provider: String

        public init(id: String, name: String, provider: String) {
            self.id = id
            self.name = name
            self.provider = provider
        }
    }

    public let conversationID: String
    public let reply: Reply
    public let backend: Backend?
    /// Pages recalled to ground the reply (`recalled`).
    public let recalled: [ChatRecalledPage]
    /// Titles of memories recalled to ground it (`recalled_memories`).
    public let recalledMemories: [String]
    /// Canvas things the model was given, by name.
    public let pulled: [ChatPulledUse]
    public let recallBranch: String?
    public let smartContext: Bool
    /// Labels from the conversation graph; nil when deep memory was off.
    public let deepMemory: [String]?
    public let truth: ChatTruthSummary?
    public let tools: ChatToolsReport
    /// Set when the model's tool request could not be resolved and the person
    /// must choose; answer it with `ChatToolChoice`.
    public let toolSelection: ChatToolSelection?

    public init(
        conversationID: String, reply: Reply, backend: Backend? = nil, recalled: [ChatRecalledPage] = [],
        recalledMemories: [String] = [], pulled: [ChatPulledUse] = [], recallBranch: String? = nil,
        smartContext: Bool = false, deepMemory: [String]? = nil, truth: ChatTruthSummary? = nil,
        tools: ChatToolsReport = .off, toolSelection: ChatToolSelection? = nil
    ) {
        self.conversationID = conversationID
        self.reply = reply
        self.backend = backend
        self.recalled = recalled
        self.recalledMemories = recalledMemories
        self.pulled = pulled
        self.recallBranch = recallBranch
        self.smartContext = smartContext
        self.deepMemory = deepMemory
        self.truth = truth
        self.tools = tools
        self.toolSelection = toolSelection
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        conversationID = try c.decode(String.self, forKey: .conversationID)
        reply = try c.decode(Reply.self, forKey: .reply)
        backend = try c.decodeIfPresent(Backend.self, forKey: .backend)
        recalled = try c.decodeIfPresent([ChatRecalledPage].self, forKey: .recalled) ?? []
        recalledMemories = try c.decodeIfPresent([String].self, forKey: .recalledMemories) ?? []
        pulled = try c.decodeIfPresent([ChatPulledUse].self, forKey: .pulled) ?? []
        recallBranch = try c.decodeIfPresent(String.self, forKey: .recallBranch)
        smartContext = try c.decodeIfPresent(Bool.self, forKey: .smartContext) ?? false
        deepMemory = try c.decodeIfPresent([String].self, forKey: .deepMemory)
        truth = try c.decodeIfPresent(ChatTruthSummary.self, forKey: .truth)
        tools = try c.decodeIfPresent(ChatToolsReport.self, forKey: .tools) ?? .off
        toolSelection = try c.decodeIfPresent(ChatToolSelection.self, forKey: .toolSelection)
    }

    enum Keys: String, CodingKey {
        case conversationID = "conversation_id", reply, backend, recalled
        case recalledMemories = "recalled_memories", pulled
        case recallBranch = "recall_branch", smartContext = "smart_context"
        case deepMemory = "deep_memory", truth, tools, toolSelection = "tool_selection"
    }

    public var grounding: ChatGrounding {
        ChatGrounding(
            pages: recalled, memories: recalledMemories, deepMemory: deepMemory ?? [],
            truth: truth, pulled: pulled, smartContext: smartContext
        )
    }
}

/// The person's pick from a `ChatToolSelection`: run exactly this tool.
public struct ChatToolChoice: Sendable, Hashable {
    public let canonical: String
    public let args: JSONValue
    public let intent: String?

    public init(canonical: String, args: JSONValue = [:], intent: String? = nil) {
        self.canonical = canonical
        self.args = args
        self.intent = intent
    }

    public init(option: ChatToolSelection.Option, intent: String?) {
        self.init(canonical: option.canonical, args: option.args, intent: intent)
    }

    var json: JSONValue {
        var object: [String: JSONValue] = ["canonical": .string(canonical), "args": args]
        if let intent, !intent.isEmpty { object["intent"] = .string(intent) }
        return .object(object)
    }
}

/// The switches of one send. Everything left nil follows the person's saved
/// settings on the server, which is what the web composer's chips override.
public struct ChatSendOptions: Sendable, Equatable {
    /// Ground the reply in recalled memories and pages (the server default).
    public var useRecall: Bool
    /// A memory branch to recall from; nil is main.
    public var recallBranch: String?
    public var smartContext: Bool?
    public var deepMemory: Bool?
    public var truth: Bool?
    /// Let the model use compiled tools. Only meaningful with a toolkit.
    public var tools: Bool?
    /// Truth ledgers (slugs) this thread cites; nil keeps the stored pins.
    public var truthLedgers: [String]?
    /// What is on the canvas, at most eight things.
    public var pulled: [ChatPulledRef]
    public var toolChoice: ChatToolChoice?

    public init(
        useRecall: Bool = true, recallBranch: String? = nil, smartContext: Bool? = nil, deepMemory: Bool? = nil,
        truth: Bool? = nil, tools: Bool? = nil, truthLedgers: [String]? = nil, pulled: [ChatPulledRef] = [],
        toolChoice: ChatToolChoice? = nil
    ) {
        self.useRecall = useRecall
        self.recallBranch = recallBranch
        self.smartContext = smartContext
        self.deepMemory = deepMemory
        self.truth = truth
        self.tools = tools
        self.truthLedgers = truthLedgers
        self.pulled = pulled
        self.toolChoice = toolChoice
    }

    /// The most things the server takes from the canvas in one turn.
    public static let maxPulled = 8

    /// Fields shared by `POST /api/chat` and `POST /api/chat/context`.
    func fill(_ object: inout [String: JSONValue], includeTools: Bool) {
        object["use_recall"] = .bool(useRecall)
        if useRecall, let recallBranch, !recallBranch.isEmpty { object["recall_branch"] = .string(recallBranch) }
        if let smartContext { object["use_smart_context"] = .bool(smartContext) }
        if let deepMemory { object["use_deep_memory"] = .bool(deepMemory) }
        if let truth { object["use_truth"] = .bool(truth) }
        if !pulled.isEmpty { object["pulled"] = .array(pulled.prefix(Self.maxPulled).map(\.json)) }
        guard includeTools else { return }
        if let tools { object["use_tools"] = .bool(tools) }
        if let truthLedgers { object["truth_ledgers"] = .array(truthLedgers.map(JSONValue.string)) }
        if let toolChoice { object["tool_choice"] = toolChoice.json }
    }
}

// MARK: Saved history, ready to draw

/// A reply or message as a thread shows it: reasoning traces removed, tool
/// traffic folded into steps, and the live state of a turn in flight.
public struct ChatThreadRow: Sendable, Identifiable, Equatable {
    public enum Kind: Sendable, Equatable { case user, assistant, tool }

    public enum State: Sendable, Equatable {
        /// Saved on the server.
        case saved
        /// Sent, waiting for the model.
        case sending
        /// A local model is writing it.
        case streaming
        /// Made on this device and waiting for the network to be saved.
        case waitingToSync
        /// The reply exists on this device but the server refused to save it.
        case notSaved(String)
        /// The message never got an answer.
        case failed(String)
    }

    public var id: String
    /// The saved message's id, once there is one.
    public var serverID: String?
    public var kind: Kind
    public var text: String
    public var model: String?
    public var feedback: ChatFeedback?
    public var toolTurn: ChatToolTurn?
    public var grounding: ChatGrounding
    public var toolSelection: ChatToolSelection?
    public var truncated: Bool
    public var createdAt: Date?
    public var state: State
    /// Written by a model on this device.
    public var onDevice: Bool

    public init(
        id: String = UUID().uuidString, serverID: String? = nil, kind: Kind, text: String = "", model: String? = nil,
        feedback: ChatFeedback? = nil, toolTurn: ChatToolTurn? = nil, grounding: ChatGrounding = .none,
        toolSelection: ChatToolSelection? = nil, truncated: Bool = false, createdAt: Date? = nil,
        state: State = .saved, onDevice: Bool = false
    ) {
        self.id = id
        self.serverID = serverID
        self.kind = kind
        self.text = text
        self.model = model
        self.feedback = feedback
        self.toolTurn = toolTurn
        self.grounding = grounding
        self.toolSelection = toolSelection
        self.truncated = truncated
        self.createdAt = createdAt
        self.state = state
        self.onDevice = onDevice
    }

    /// Saved history as rows, the way the web renders it: reasoning traces are
    /// hidden; a `tool` row is one collapsed step; an assistant row that ended
    /// in a tool request keeps only the words before it (and goes if there are
    /// none); system rows stay out of the thread.
    public static func hydrate(_ messages: [ChatMessage]) -> [ChatThreadRow] {
        messages.compactMap { message -> ChatThreadRow? in
            switch message.role {
            case .user:
                return ChatThreadRow(
                    id: message.id, serverID: message.id, kind: .user, text: message.content, createdAt: message.createdAt
                )
            case .assistant:
                var text = Thinking.strip(message.content).shown
                if let call = ChatToolProtocol.parseIntentCall(text) {
                    guard !call.visibleText.isEmpty else { return nil }
                    text = call.visibleText
                }
                return ChatThreadRow(
                    id: message.id, serverID: message.id, kind: .assistant, text: text, model: message.model,
                    feedback: message.feedback, createdAt: message.createdAt
                )
            case .tool:
                guard let step = ChatToolProtocol.parseToolResult(message.content) else { return nil }
                return ChatThreadRow(
                    id: message.id, serverID: message.id, kind: .tool, toolTurn: step, createdAt: message.createdAt
                )
            case .system:
                return nil
            }
        }
    }
}

/// Rows for the steps a live turn took, then its reply.
extension ChatThreadRow {
    public static func rows(for turn: ChatTurnResponse) -> [ChatThreadRow] {
        var rows = turn.tools.turns.map { step in
            ChatThreadRow(kind: .tool, toolTurn: step)
        }
        var text = turn.reply.text
        // A reply that picked a tool gets the picker below it, as the web does.
        if let call = ChatToolProtocol.parseIntentCall(text) { text = call.visibleText }
        rows.append(
            ChatThreadRow(
                serverID: turn.reply.id, kind: .assistant, text: text, model: turn.reply.model,
                grounding: turn.grounding,
                toolSelection: (turn.toolSelection?.options.isEmpty ?? true) ? nil : turn.toolSelection,
                truncated: turn.reply.truncated
            )
        )
        return rows
    }
}
