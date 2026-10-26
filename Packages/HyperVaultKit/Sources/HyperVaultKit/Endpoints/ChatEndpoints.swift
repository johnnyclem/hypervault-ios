import Foundation

// Chat endpoints. `Models/Chat.swift` documents `.chat`, the call another
// screen makes to talk to a model.

/// How long `POST /api/chat` may take: the server stops at 120 seconds.
public let chatTurnTimeout: TimeInterval = 130

extension Endpoint where Response == ChatTurnResponse {
    /// One turn with a connected model (`POST /api/chat`). Not streaming; waits
    /// for the whole answer. `conversationID` nil starts a conversation.
    public static func chat(
        backendID: String,
        message: String,
        conversationID: String? = nil,
        options: ChatSendOptions = ChatSendOptions()
    ) -> Endpoint<ChatTurnResponse> {
        var object: [String: JSONValue] = ["backend_id": .string(backendID), "message": .string(message)]
        if let conversationID, !conversationID.isEmpty { object["conversation_id"] = .string(conversationID) }
        options.fill(&object, includeTools: true)
        return Endpoint(
            .post, "/api/chat", body: .jsonValue(.object(object)), keys: .verbatim, timeout: chatTurnTimeout
        )
    }
}

// MARK: Conversations

private struct ConversationsEnvelope: Decodable { let conversations: [ChatConversation] }

private struct ToolkitEnvelope: Decodable {
    struct Toolkit: Decodable { let id: String? }
    let toolkit: Toolkit?
    let stale: Bool?
}

extension Endpoint where Response == [ChatConversation] {
    /// The person's conversations, newest first (at most 500).
    public static var conversations: Endpoint<[ChatConversation]> {
        Endpoint(
            method: .get, path: "/api/conversations",
            decode: { response, keys in
                do {
                    return try HVCoding.decoder(keys).decode(ConversationsEnvelope.self, from: response.data).conversations
                } catch {
                    throw HVError.decoding("\(error)")
                }
            }
        )
    }
}

extension Endpoint where Response == ChatConversationDetail {
    /// One conversation with its whole history.
    public static func conversation(id: String) -> Endpoint<ChatConversationDetail> {
        Endpoint(.get, "/api/conversations/\(id)")
    }
}

extension Endpoint where Response == ChatVisibilityChange {
    /// Changes who can read a chat. The first move away from private mints the share link.
    public static func setVisibility(conversationID: String, _ visibility: ChatVisibility) -> Endpoint<ChatVisibilityChange> {
        Endpoint(.patch, "/api/conversations/\(conversationID)", body: .jsonValue(["visibility": .string(visibility.rawValue)]))
    }
}

extension Endpoint where Response == NoContent {
    /// Deletes a conversation and its messages, and the memory that mirrored it.
    public static func deleteConversation(id: String) -> Endpoint<NoContent> {
        Endpoint(.delete, "/api/conversations/\(id)")
    }
}

// MARK: Rating a reply

/// `POST /api/messages/[id]/feedback`.
public struct ChatFeedbackSaved: Sendable, Decodable, Equatable {
    public let id: String?
    public let message: String?
}

extension Endpoint where Response == ChatFeedbackSaved {
    /// Rates an assistant reply; nil clears the rating. Ratings steer later replies.
    public static func rate(messageID: String, _ feedback: ChatFeedback?) -> Endpoint<ChatFeedbackSaved> {
        Endpoint(
            .post, "/api/messages/\(messageID)/feedback",
            body: .jsonValue(["feedback": feedback.map { JSONValue.string($0.rawValue) } ?? .null])
        )
    }
}

// MARK: Settings and tools

extension Endpoint where Response == ChatSettings {
    public static var chatSettings: Endpoint<ChatSettings> { Endpoint(.get, "/api/chat-settings") }

    /// Saves the switches that changed; nil fields are left alone.
    public static func updateChatSettings(
        smartContext: Bool? = nil, deepMemory: Bool? = nil, truth: Bool? = nil
    ) -> Endpoint<ChatSettings> {
        var object: [String: JSONValue] = [:]
        if let smartContext { object["smart_context"] = .bool(smartContext) }
        if let deepMemory { object["deep_memory"] = .bool(deepMemory) }
        if let truth { object["truth"] = .bool(truth) }
        return Endpoint(.patch, "/api/chat-settings", body: .jsonValue(.object(object)))
    }
}

extension Endpoint where Response == ChatToolkitStatus {
    /// Whether the person has compiled tools (`GET /api/toolkits`). A server
    /// that predates tools answers with an error, which reads as "no tools".
    public static var toolkitStatus: Endpoint<ChatToolkitStatus> {
        Endpoint(
            method: .get, path: "/api/toolkits",
            decode: { response, keys in
                guard let wrapper = try? HVCoding.decoder(keys).decode(ToolkitEnvelope.self, from: response.data) else {
                    return ChatToolkitStatus(hasToolkit: false)
                }
                return ChatToolkitStatus(hasToolkit: wrapper.toolkit != nil, stale: wrapper.stale ?? false)
            }
        )
    }
}

// MARK: On-device chat

/// One message as a model that runs on the device reads it.
public struct ChatWireMessage: Sendable, Codable, Equatable, Hashable {
    public let role: ChatRole
    public let content: String

    public init(role: ChatRole, content: String) {
        self.role = role
        self.content = content
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        role = try c.decodeIfPresent(ChatRole.self, forKey: .role) ?? .user
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
    }

    enum Keys: String, CodingKey { case role, content }
}

/// `POST /api/chat/context`: everything a turn needs except the model. Nothing
/// is written; the server only reads and assembles.
public struct ChatContext: Sendable, Decodable, Equatable {
    public let conversationID: String?
    /// A ready system prompt: asserted truth, pulled things, deep memory, recall,
    /// the compacted older thread and learned style preferences, in that order.
    public let system: String
    /// The thread so far (compacted when smart context is on), ending with the new message.
    public let messages: [ChatWireMessage]
    public let nextPosition: Int
    public let recalled: [ChatRecalledPage]
    public let recalledMemories: [String]
    public let pulled: [ChatPulledUse]
    public let smartContext: Bool
    public let deepMemory: [String]?
    public let truth: ChatTruthSummary?

    public init(
        conversationID: String? = nil, system: String, messages: [ChatWireMessage], nextPosition: Int = 0,
        recalled: [ChatRecalledPage] = [], recalledMemories: [String] = [], pulled: [ChatPulledUse] = [],
        smartContext: Bool = false, deepMemory: [String]? = nil, truth: ChatTruthSummary? = nil
    ) {
        self.conversationID = conversationID
        self.system = system
        self.messages = messages
        self.nextPosition = nextPosition
        self.recalled = recalled
        self.recalledMemories = recalledMemories
        self.pulled = pulled
        self.smartContext = smartContext
        self.deepMemory = deepMemory
        self.truth = truth
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        conversationID = try c.decodeIfPresent(String.self, forKey: .conversationID)
        system = try c.decodeIfPresent(String.self, forKey: .system) ?? ""
        messages = try c.decodeIfPresent([ChatWireMessage].self, forKey: .messages) ?? []
        nextPosition = try c.decodeIfPresent(Int.self, forKey: .nextPosition) ?? 0
        recalled = try c.decodeIfPresent([ChatRecalledPage].self, forKey: .recalled) ?? []
        recalledMemories = try c.decodeIfPresent([String].self, forKey: .recalledMemories) ?? []
        pulled = try c.decodeIfPresent([ChatPulledUse].self, forKey: .pulled) ?? []
        smartContext = try c.decodeIfPresent(Bool.self, forKey: .smartContext) ?? false
        deepMemory = try c.decodeIfPresent([String].self, forKey: .deepMemory)
        truth = try c.decodeIfPresent(ChatTruthSummary.self, forKey: .truth)
    }

    enum Keys: String, CodingKey {
        case conversationID = "conversation_id", system, messages, nextPosition = "next_position"
        case recalled, recalledMemories = "recalled_memories", pulled, smartContext = "smart_context"
        case deepMemory = "deep_memory", truth
    }

    public var grounding: ChatGrounding {
        ChatGrounding(
            pages: recalled, memories: recalledMemories, deepMemory: deepMemory ?? [],
            truth: truth, pulled: pulled, smartContext: smartContext
        )
    }
}

extension Endpoint where Response == ChatContext {
    /// The context for a turn answered by a model on this device. Sent with
    /// the same switches as a server turn; tools are never part of it.
    public static func chatContext(
        message: String, conversationID: String? = nil, options: ChatSendOptions = ChatSendOptions()
    ) -> Endpoint<ChatContext> {
        var object: [String: JSONValue] = ["message": .string(message)]
        if let conversationID, !conversationID.isEmpty { object["conversation_id"] = .string(conversationID) }
        options.fill(&object, includeTools: false)
        return Endpoint(.post, "/api/chat/context", body: .jsonValue(.object(object)), keys: .verbatim, timeout: 60, idempotent: true)
    }
}

/// `POST /api/chat/turns`: a turn written by a model on the device, saved.
public struct ChatTurnSaved: Sendable, Decodable, Equatable {
    public struct Reply: Sendable, Decodable, Equatable {
        public let id: String?
        public let content: String?
        public let model: String?

        public init(id: String?, content: String?, model: String?) {
            self.id = id
            self.content = content
            self.model = model
        }
    }

    public let conversationID: String
    public let reply: Reply

    enum Keys: String, CodingKey { case conversationID = "conversation_id", reply }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        conversationID = try c.decode(String.self, forKey: .conversationID)
        reply = try c.decode(Reply.self, forKey: .reply)
    }

    public init(conversationID: String, reply: Reply) {
        self.conversationID = conversationID
        self.reply = reply
    }
}

extension Endpoint where Response == ChatTurnSaved {
    /// Saves a turn a model on this device wrote: the person's message and the
    /// reply together, in a new conversation unless `conversationID` is given.
    /// Not idempotent: sending it twice saves it twice.
    public static func saveTurn(
        userMessage: String, assistantContent: String, conversationID: String? = nil,
        title: String? = nil, model: String? = nil
    ) -> Endpoint<ChatTurnSaved> {
        var object: [String: JSONValue] = [
            "user_message": .string(userMessage), "assistant_content": .string(assistantContent),
        ]
        if let conversationID, !conversationID.isEmpty { object["conversation_id"] = .string(conversationID) }
        if let title, !title.isEmpty { object["title"] = .string(title) }
        if let model, !model.isEmpty { object["model"] = .string(model) }
        return Endpoint(.post, "/api/chat/turns", body: .jsonValue(.object(object)), keys: .verbatim, timeout: 60)
    }
}
