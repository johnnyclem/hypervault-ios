import Foundation

// Chat with a model that runs on the device (Apple's Foundation Models on
// iOS 26, or any runtime someone plugs in behind `ChatModelProvider`).
//
// The server still owns the person's memory and history, so a turn is three
// steps and none of them is the model:
//
//   1. `POST /api/chat/context`  reads: system prompt (truth, pulled things, deep
//                                memory, recall, compacted history, style
//                                preferences) and the thread so far.
//   2. the provider generates, streaming, on the device.
//   3. `POST /api/chat/turns`    writes: the person's message and the reply.
//
// If the network is gone at step 3 the turn waits in `ChatTurnOutbox` and is
// saved when it is back. If it is gone at step 1 the model answers without
// the person's memory and says so. Tools are server-side, so this path has
// none: the screen says that in one calm line.

/// A model that writes replies. The Foundation Models adapter is the only
/// implementation in the app; tests use a fake.
public protocol ChatModelProvider: Sendable {
    /// Saved with the turn as its `model`, e.g. `apple-on-device`.
    var modelName: String { get }
    /// How many characters of system prompt plus history the model can read at
    /// once, leaving room for its answer.
    var contextBudget: Int { get }
    /// Writes a reply. Every element is the whole reply so far (not a delta),
    /// so a view can simply replace its text.
    func generate(system: String, messages: [ChatWireMessage]) -> AsyncThrowingStream<String, Error>
}

public enum OnDeviceChatError: Error, Equatable, LocalizedError, Sendable {
    /// The model failed; the text says why in plain words.
    case generation(String)
    /// The model finished without writing anything.
    case emptyReply

    public var errorDescription: String? {
        switch self {
        case .generation(let message): return message
        case .emptyReply: return "The model on this device did not write anything. Try asking another way."
        }
    }
}

// MARK: Fitting a small context window

/// The on-device model reads about four thousand tokens, answer included. The
/// server's context is built for models with far more room, so before the
/// device model sees it: tool traffic goes (it is tool-free here), reasoning
/// traces go, and what is left is trimmed to a budget in characters, the
/// newest words first.
public enum ChatContextFitter {
    public struct Fitted: Sendable, Equatable {
        public let system: String
        public let messages: [ChatWireMessage]
        public let shortenedSystem: Bool
        public let droppedMessages: Int
    }

    public static let shortenedMarker = "[\u{2026}]"

    public static func prepare(system: String, messages: [ChatWireMessage], budget: Int) -> Fitted {
        let cleaned = sanitize(messages)
        guard let latest = cleaned.last else {
            let fitted = clip(system, to: max(budget, 0))
            return Fitted(system: fitted.text, messages: [], shortenedSystem: fitted.clipped, droppedMessages: 0)
        }

        // The new message always goes, shortened if it alone is most of the room.
        let latestRoom = max(Int(Double(budget) * 0.5), 200)
        let latestFit = clip(latest.content, to: latestRoom, keepHead: true)
        let newest = ChatWireMessage(role: latest.role, content: latestFit.text)

        // The system prompt may use up to 45% of the budget, its head first:
        // asserted truth and pulled things lead it.
        let systemRoom = min(system.count, Int(Double(budget) * 0.45))
        let systemFit = clip(system, to: systemRoom)

        var remaining = budget - systemFit.text.count - newest.content.count
        var kept: [ChatWireMessage] = []
        for message in cleaned.dropLast().reversed() {
            let cost = message.content.count + 12
            if cost > remaining { break }
            remaining -= cost
            kept.append(message)
        }
        kept.reverse()
        let dropped = cleaned.count - 1 - kept.count
        return Fitted(system: systemFit.text, messages: kept + [newest], shortenedSystem: systemFit.clipped, droppedMessages: dropped)
    }

    /// Roles and words a tool-free model can use: no tool rows, no tool
    /// requests at the end of a reply, no reasoning traces, nothing empty.
    public static func sanitize(_ messages: [ChatWireMessage]) -> [ChatWireMessage] {
        messages.compactMap { message -> ChatWireMessage? in
            if message.role == .tool { return nil }
            var text = message.content
            if message.role == .assistant {
                text = Thinking.strip(text).shown
                if let call = ChatToolProtocol.parseIntentCall(text) { text = call.visibleText }
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : ChatWireMessage(role: message.role, content: text)
        }
    }

    /// Cuts `text` to `limit` characters at a paragraph (or line, or word)
    /// boundary near the limit and marks the cut.
    static func clip(_ text: String, to limit: Int, keepHead: Bool = true) -> (text: String, clipped: Bool) {
        guard text.count > limit else { return (text, false) }
        guard limit > shortenedMarker.count + 10 else { return (String(text.prefix(max(limit, 0))), true) }
        let room = limit - shortenedMarker.count - 1
        let head = String(text.prefix(room))
        var cut = head
        for separator in ["\n\n", "\n", " "] {
            if let range = head.range(of: separator, options: .backwards),
               head.distance(from: head.startIndex, to: range.lowerBound) > room * 6 / 10
            {
                cut = String(head[..<range.lowerBound])
                break
            }
        }
        return (cut.trimmingCharacters(in: .whitespacesAndNewlines) + "\n" + shortenedMarker, true)
    }
}

/// How a thread is put to a model that takes one instruction string and one
/// prompt string (Foundation Models does).
public enum OnDevicePrompt {
    public static let defaultInstructions =
        "You are the person's assistant inside HyperVault. Answer plainly and briefly, in the language they write in."

    /// The system prompt with a line that says where the rest of the thread is.
    public static func instructions(system: String, hasMemory: Bool) -> String {
        let trimmed = system.trimmingCharacters(in: .whitespacesAndNewlines)
        var text = trimmed.isEmpty ? defaultInstructions : trimmed
        if !hasMemory {
            text += "\n\nYou do not have access to the person's saved memories right now; do not pretend to."
        }
        return text
    }

    /// Earlier turns as a short transcript, then the latest message.
    public static func prompt(messages: [ChatWireMessage]) -> String {
        guard let latest = messages.last else { return "" }
        let earlier = messages.dropLast()
        if earlier.isEmpty { return latest.content }
        let lines = earlier.map { message -> String in
            switch message.role {
            case .assistant: return "Assistant: \(message.content)"
            case .system: return "Note: \(message.content)"
            default: return "Person: \(message.content)"
            }
        }
        return "The conversation so far:\n\(lines.joined(separator: "\n"))\n\nThe person's latest message:\n\(latest.content)"
    }
}

// MARK: One turn

public struct OnDeviceTurn: Sendable {
    public var message: String
    public var conversationID: String?
    /// Names an unsaved conversation across turns, so turns waiting in the
    /// outbox land in one conversation. A fresh UUID per new chat.
    public var threadKey: String
    public var options: ChatSendOptions
    /// What the screen already shows, used when the server cannot be asked for context.
    public var history: [ChatWireMessage]

    public init(
        message: String, conversationID: String? = nil, threadKey: String = UUID().uuidString,
        options: ChatSendOptions = ChatSendOptions(), history: [ChatWireMessage] = []
    ) {
        self.message = message
        self.conversationID = conversationID
        self.threadKey = threadKey
        self.options = options
        self.history = history
    }
}

public struct OnDeviceOutcome: Sendable, Equatable {
    public enum Saved: Sendable, Equatable {
        case saved(conversationID: String, messageID: String?)
        /// The network was away; the outbox saves it later.
        case queued
        /// The server refused to save it, in its own words. The reply is still here.
        case rejected(String)
    }

    public let reply: String
    public let grounding: ChatGrounding
    /// False when the model answered without the person's memory.
    public let usedMemory: Bool
    public let saved: Saved
    public let model: String
}

/// Runs a turn: context, generate, save (or queue).
public struct OnDeviceChat: Sendable {
    let client: HVClient
    let provider: ChatModelProvider
    let outbox: ChatTurnOutbox

    public init(client: HVClient, provider: ChatModelProvider, outbox: ChatTurnOutbox) {
        self.client = client
        self.provider = provider
        self.outbox = outbox
    }

    /// Throws an `HVError` (the server's own sentence) when the context cannot
    /// be read for a reason other than being offline, or `OnDeviceChatError`
    /// when the model fails. Cancel by cancelling the task; nothing is saved.
    public func run(_ turn: OnDeviceTurn, onPartial: @escaping @MainActor @Sendable (String) -> Void) async throws -> OnDeviceOutcome {
        let message = turn.message.trimmingCharacters(in: .whitespacesAndNewlines)

        var system = ""
        var wire = turn.history + [ChatWireMessage(role: .user, content: message)]
        var grounding = ChatGrounding.none
        var conversationID = turn.conversationID
        var usedMemory = true
        do {
            let context = try await client.send(.chatContext(message: message, conversationID: turn.conversationID, options: turn.options))
            system = context.system
            wire = context.messages.isEmpty ? wire : context.messages
            grounding = context.grounding
            conversationID = context.conversationID ?? turn.conversationID
        } catch let error as HVError where error.isOffline {
            usedMemory = false
        }
        try Task.checkCancellation()

        let fitted = ChatContextFitter.prepare(system: system, messages: wire, budget: provider.contextBudget)
        var reply = ""
        do {
            for try await snapshot in provider.generate(system: fitted.system, messages: fitted.messages) {
                reply = snapshot
                await onPartial(Thinking.strip(snapshot).shown)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as OnDeviceChatError {
            throw error
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw OnDeviceChatError.generation(error.localizedDescription)
        }
        try Task.checkCancellation()

        let final = Thinking.strip(reply).shown
        guard !final.isEmpty else { throw OnDeviceChatError.emptyReply }

        let saved = await save(turn: turn, message: message, reply: final, conversationID: conversationID)
        return OnDeviceOutcome(reply: final, grounding: grounding, usedMemory: usedMemory, saved: saved, model: provider.modelName)
    }

    private func save(turn: OnDeviceTurn, message: String, reply: String, conversationID: String?) async -> OnDeviceOutcome.Saved {
        do {
            let result = try await client.send(
                .saveTurn(userMessage: message, assistantContent: reply, conversationID: conversationID, model: provider.modelName)
            )
            return .saved(conversationID: result.conversationID, messageID: result.reply.id)
        } catch let error as HVError {
            // A refusal that repeating cannot fix is the server's to explain;
            // a lost connection or a server hiccup waits for the outbox.
            if let status = error.status, (400..<500).contains(status), status != 429, status != 401 {
                return .rejected(error.userMessage)
            }
            await outbox.enqueue(
                PendingChatTurn(
                    threadKey: turn.threadKey, conversationID: conversationID, userMessage: message,
                    assistantContent: reply, model: provider.modelName
                )
            )
            return .queued
        } catch {
            return .rejected(error.localizedDescription)
        }
    }
}

// MARK: The outbox

/// A turn written on the device that the server has not saved yet.
public struct PendingChatTurn: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public var threadKey: String
    public var conversationID: String?
    public let userMessage: String
    public let assistantContent: String
    public let model: String
    public let createdAt: Date

    public init(
        id: String = UUID().uuidString, threadKey: String, conversationID: String?, userMessage: String,
        assistantContent: String, model: String, createdAt: Date = Date()
    ) {
        self.id = id
        self.threadKey = threadKey
        self.conversationID = conversationID
        self.userMessage = userMessage
        self.assistantContent = assistantContent
        self.model = model
        self.createdAt = createdAt
    }
}

/// What one pass over the outbox did.
public struct ChatOutboxReport: Sendable, Equatable {
    public struct Saved: Sendable, Equatable {
        public let turnID: String
        public let threadKey: String
        public let conversationID: String
        public let messageID: String?
    }

    public struct Rejected: Sendable, Equatable {
        public let turnID: String
        public let message: String
    }

    public var saved: [Saved] = []
    public var rejected: [Rejected] = []
    /// Turns still waiting.
    public var remaining = 0
}

/// On-device turns that could not be saved yet, kept on disk (per person) and
/// replayed in order. Saving a turn is not idempotent on the server, so before
/// replaying one into a known conversation the outbox looks at that
/// conversation's tail: if the turn is already there (the request got through
/// and only its answer was lost) it is dropped instead of saved twice. A turn
/// for a conversation that does not exist yet cannot be checked this way; it is
/// the one place a lost answer can duplicate a conversation.
public actor ChatTurnOutbox {
    private let cache: DiskCache
    private let namespace: String
    private static let key = "chat.outbox"
    private var items: [PendingChatTurn]?
    private var flushing = false

    public init(cache: DiskCache, namespace: String) {
        self.cache = cache
        self.namespace = namespace
    }

    public func pending() async -> [PendingChatTurn] {
        await load()
    }

    public func enqueue(_ turn: PendingChatTurn) async {
        var all = await load()
        all.append(turn)
        items = all
        await persist()
    }

    /// Tries to save everything waiting, oldest first. Stops at the first
    /// failure that retrying may cure (offline, a server error, signed out).
    @discardableResult
    public func flush(client: HVClient) async -> ChatOutboxReport {
        var report = ChatOutboxReport()
        guard !flushing else {
            report.remaining = await load().count
            return report
        }
        flushing = true
        defer { flushing = false }

        var created: [String: String] = [:]  // threadKey -> conversation id made by an earlier turn
        let queue = await load()
        outer: for turn in queue {
            var conversationID = turn.conversationID ?? created[turn.threadKey]
            if let known = conversationID, let existing = await alreadySaved(turn, in: known, client: client) {
                report.saved.append(.init(turnID: turn.id, threadKey: turn.threadKey, conversationID: known, messageID: existing))
                await remove(turn.id)
                continue
            }
            do {
                let result = try await client.send(
                    .saveTurn(userMessage: turn.userMessage, assistantContent: turn.assistantContent, conversationID: conversationID, model: turn.model)
                )
                conversationID = result.conversationID
                created[turn.threadKey] = result.conversationID
                report.saved.append(.init(turnID: turn.id, threadKey: turn.threadKey, conversationID: result.conversationID, messageID: result.reply.id))
                await remove(turn.id)
            } catch let error as HVError {
                if let status = error.status, (400..<500).contains(status), status != 429, status != 401 {
                    report.rejected.append(.init(turnID: turn.id, message: error.userMessage))
                    await remove(turn.id)
                    continue
                }
                break outer
            } catch {
                break outer
            }
        }
        report.remaining = await load().count
        return report
    }

    private func alreadySaved(_ turn: PendingChatTurn, in conversationID: String, client: HVClient) async -> String? {
        guard let detail = try? await client.send(.conversation(id: conversationID)) else { return nil }
        return ChatTurnReconciler.savedReply(
            for: turn.userMessage, replyText: turn.assistantContent, in: detail.messages, afterIndex: 0
        )?.id
    }

    private func remove(_ id: String) async {
        var all = await load()
        all.removeAll { $0.id == id }
        items = all
        await persist()
    }

    private func load() async -> [PendingChatTurn] {
        if let items { return items }
        let stored = await cache.entry([PendingChatTurn].self, key: Self.key, namespace: namespace)?.value ?? []
        items = stored
        return stored
    }

    private func persist() async {
        guard let items else { return }
        if items.isEmpty {
            await cache.remove(key: Self.key, namespace: namespace)
        } else {
            await cache.store(items, key: Self.key, namespace: namespace)
        }
    }
}

// MARK: Did the server save it after all?

/// A request that takes up to two minutes on a phone can lose its answer while
/// the server finishes the work. Before telling the person "not sent", look.
public enum ChatTurnReconciler {
    /// The assistant reply the server saved for `message`, searching messages
    /// from `afterIndex` on (so an older identical message cannot match). Nil
    /// when the thread has no such turn. `replyText` narrows the match to a
    /// specific reply (used by the outbox); leave nil to take the final reply.
    public static func savedReply(
        for message: String, replyText: String? = nil, in messages: [ChatMessage], afterIndex: Int
    ) -> ChatMessage? {
        let wanted = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let start = max(afterIndex, 0)
        guard start < messages.count else { return nil }
        for index in stride(from: messages.count - 1, through: start, by: -1) {
            let candidate = messages[index]
            guard candidate.role == .user,
                  candidate.content.trimmingCharacters(in: .whitespacesAndNewlines) == wanted
            else { continue }
            // The final assistant row before the next user message is the reply.
            var reply: ChatMessage?
            var cursor = index + 1
            while cursor < messages.count, messages[cursor].role != .user {
                if messages[cursor].role == .assistant { reply = messages[cursor] }
                cursor += 1
            }
            guard let reply else { return nil }
            if let replyText, reply.content.trimmingCharacters(in: .whitespacesAndNewlines)
                != replyText.trimmingCharacters(in: .whitespacesAndNewlines)
            { continue }
            return reply
        }
        return nil
    }

    /// A conversation that the server made from `message` while its answer was
    /// lost: a HyperVault chat updated since `startedAt` whose title is the
    /// start of the message.
    public static func newConversation(
        for message: String, in conversations: [ChatConversation], startedAt: Date
    ) -> ChatConversation? {
        let wanted = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let lead = String(wanted.prefix(60))
        return conversations
            .filter { $0.platform == .hypervault }
            .filter { ($0.updatedAt ?? $0.createdAt ?? .distantPast) >= startedAt.addingTimeInterval(-10) }
            .first { wanted.hasPrefix($0.title) || $0.title.hasPrefix(lead) }
    }

    /// Asks the server whether the turn was saved. Returns the conversation as
    /// it now stands when it was, nil when it was not (or the server cannot be reached).
    public static func reconcile(
        client: HVClient, message: String, conversationID: String?, knownMessageCount: Int, startedAt: Date
    ) async -> ChatConversationDetail? {
        var id = conversationID
        if id == nil {
            guard let all = try? await client.send(.conversations) else { return nil }
            id = newConversation(for: message, in: all, startedAt: startedAt)?.id
        }
        guard let id, let detail = try? await client.send(.conversation(id: id)) else { return nil }
        guard savedReply(for: message, in: detail.messages, afterIndex: knownMessageCount) != nil else { return nil }
        return detail
    }
}
