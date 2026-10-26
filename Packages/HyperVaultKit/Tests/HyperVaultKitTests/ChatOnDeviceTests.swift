import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HyperVaultKit

/// A model that writes a fixed reply in pieces, and remembers what it was given.
final class FakeModel: ChatModelProvider, @unchecked Sendable {
    let modelName = "fake-on-device"
    let contextBudget: Int
    private let lock = NSLock()
    private var _seen: [(system: String, messages: [ChatWireMessage])] = []
    let pieces: [String]
    let failure: Error?

    init(pieces: [String] = ["Hel", "Hello", "Hello there."], contextBudget: Int = 7_000, failure: Error? = nil) {
        self.pieces = pieces
        self.contextBudget = contextBudget
        self.failure = failure
    }

    var seen: [(system: String, messages: [ChatWireMessage])] { lock.lock(); defer { lock.unlock() }; return _seen }

    func generate(system: String, messages: [ChatWireMessage]) -> AsyncThrowingStream<String, Error> {
        lock.lock(); _seen.append((system, messages)); lock.unlock()
        let pieces = pieces
        let failure = failure
        return AsyncThrowingStream { continuation in
            for piece in pieces { continuation.yield(piece) }
            if let failure { continuation.finish(throwing: failure) } else { continuation.finish() }
        }
    }
}

final class ChatOnDeviceTests: XCTestCase {
    let base = URL(string: "https://hv.test")!

    func client(_ transport: MockTransport) -> HVClient {
        HVClient(baseURL: base, transport: transport, tokens: StaticTokenProvider(), retry: .none, sleep: { _ in })
    }

    func outbox() -> ChatTurnOutbox {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hv-outbox-\(UUID().uuidString)")
        return ChatTurnOutbox(cache: DiskCache(directory: directory), namespace: "u1")
    }

    static let contextJSON = """
    {"conversation_id":"c1","system":"## Truth\\nThe flight is on the 3rd.","messages":[
      {"role":"user","content":"hello"},{"role":"assistant","content":"Hi!"},{"role":"user","content":"when do we fly?"}],
     "next_position":2,"recalled":[{"title":"Trip","slug":"trip-1"}],"recalled_memories":["Flights"],"pulled":[],
     "smart_context":false,"deep_memory":null,"truth":null}
    """

    // MARK: the fitter

    func testFitterDropsToolTrafficAndReasoningAndKeepsTheNewestWords() {
        let messages = [
            ChatWireMessage(role: .user, content: "old question"),
            ChatWireMessage(role: .assistant, content: "Checking.\n\n```tool\n{\"intent\":\"x\",\"args\":{}}\n```"),
            ChatWireMessage(role: .tool, content: "```tool-result\n{\"intent\":\"x\"}\n```"),
            ChatWireMessage(role: .assistant, content: "<think>hm</think>The answer."),
            ChatWireMessage(role: .user, content: "newest"),
        ]
        let fitted = ChatContextFitter.prepare(system: "S", messages: messages, budget: 1_000)
        XCTAssertEqual(fitted.messages.map(\.content), ["old question", "Checking.", "The answer.", "newest"])
        XCTAssertEqual(fitted.droppedMessages, 0)
    }

    func testFitterTrimsHistoryOldestFirstAndKeepsTheHeadOfTheSystemPrompt() {
        let system = (1...50).map { "Fact number \($0) is that things are as they are." }.joined(separator: "\n\n")
        let messages = (1...30).flatMap { n in
            [ChatWireMessage(role: .user, content: "question \(n) " + String(repeating: "q", count: 80)),
             ChatWireMessage(role: .assistant, content: "answer \(n) " + String(repeating: "a", count: 80))]
        } + [ChatWireMessage(role: .user, content: "the final question")]
        let fitted = ChatContextFitter.prepare(system: system, messages: messages, budget: 2_000)
        XCTAssertTrue(fitted.shortenedSystem)
        XCTAssertTrue(fitted.system.hasPrefix("Fact number 1 "))
        XCTAssertTrue(fitted.system.hasSuffix(ChatContextFitter.shortenedMarker))
        XCTAssertLessThanOrEqual(fitted.system.count, 2_000 * 45 / 100)
        XCTAssertEqual(fitted.messages.last?.content, "the final question")
        XCTAssertGreaterThan(fitted.droppedMessages, 0)
        let total = fitted.system.count + fitted.messages.reduce(0) { $0 + $1.content.count + 12 }
        XCTAssertLessThanOrEqual(total, 2_000)
        // What is kept is the newest history, still in order, just before the new message.
        XCTAssertTrue(fitted.messages.dropLast().last?.content.hasPrefix("answer 30") == true)
    }

    func testFitterShortensAHugeLatestMessageInsteadOfDroppingIt() {
        let huge = String(repeating: "word ", count: 5_000)
        let fitted = ChatContextFitter.prepare(system: "", messages: [ChatWireMessage(role: .user, content: huge)], budget: 1_000)
        XCTAssertEqual(fitted.messages.count, 1)
        XCTAssertLessThanOrEqual(fitted.messages[0].content.count, 500)
        XCTAssertTrue(fitted.messages[0].content.hasSuffix(ChatContextFitter.shortenedMarker))
    }

    func testPromptFlattening() {
        XCTAssertEqual(OnDevicePrompt.prompt(messages: [ChatWireMessage(role: .user, content: "hi")]), "hi")
        let prompt = OnDevicePrompt.prompt(messages: [
            ChatWireMessage(role: .user, content: "a"), ChatWireMessage(role: .assistant, content: "b"), ChatWireMessage(role: .user, content: "c"),
        ])
        XCTAssertEqual(prompt, "The conversation so far:\nPerson: a\nAssistant: b\n\nThe person's latest message:\nc")
        XCTAssertTrue(OnDevicePrompt.instructions(system: "", hasMemory: true).contains("HyperVault"))
        XCTAssertTrue(OnDevicePrompt.instructions(system: "S", hasMemory: false).contains("do not pretend"))
    }

    // MARK: a turn

    func testContextThenGenerateThenSave() async throws {
        let transport = MockTransport(routes: [
            .json(.post, "/api/chat/context", Self.contextJSON),
            .json(.post, "/api/chat/turns", #"{"conversation_id":"c1","reply":{"id":"m7","role":"assistant","content":"Hello there.","model":"fake-on-device"}}"#),
        ])
        let model = FakeModel()
        let chat = OnDeviceChat(client: client(transport), provider: model, outbox: outbox())
        let partials = TestBox<[String]>([])
        let outcome = try await chat.run(OnDeviceTurn(message: "when do we fly?", conversationID: "c1")) { partials.value.append($0) }

        XCTAssertEqual(outcome.reply, "Hello there.")
        XCTAssertEqual(outcome.saved, .saved(conversationID: "c1", messageID: "m7"))
        XCTAssertTrue(outcome.usedMemory)
        XCTAssertEqual(outcome.grounding.memories, ["Flights"])
        XCTAssertEqual(outcome.grounding.pages.map(\.slug), ["trip-1"])
        XCTAssertEqual(partials.value, ["Hel", "Hello", "Hello there."])
        XCTAssertEqual(model.seen.first?.system, "## Truth\nThe flight is on the 3rd.")
        XCTAssertEqual(model.seen.first?.messages.last?.content, "when do we fly?")
        let saved = requestJSON(await transport.requests(matching: "/api/chat/turns").first)
        XCTAssertEqual(saved?["user_message"], "when do we fly?")
        XCTAssertEqual(saved?["assistant_content"], "Hello there.")
        XCTAssertEqual(saved?["conversation_id"], "c1")
        XCTAssertEqual(saved?["model"], "fake-on-device")
    }

    func testOfflineContextFallsBackToTheScreensOwnHistory() async throws {
        let transport = MockTransport(routes: [
            .json(.post, "/api/chat/turns", #"{"conversation_id":"c2","reply":{"id":"m1","role":"assistant","content":"x","model":"fake-on-device"}}"#),
        ])
        let offline = OfflineTransport(inner: transport, failing: ["/api/chat/context"])
        let model = FakeModel()
        let api = HVClient(baseURL: base, transport: offline, tokens: StaticTokenProvider(), retry: .none, sleep: { _ in })
        let chat = OnDeviceChat(client: api, provider: model, outbox: outbox())
        let history = [ChatWireMessage(role: .user, content: "earlier"), ChatWireMessage(role: .assistant, content: "reply")]
        let outcome = try await chat.run(OnDeviceTurn(message: "now", history: history)) { _ in }
        XCTAssertFalse(outcome.usedMemory)
        XCTAssertEqual(model.seen.first?.messages.map(\.content), ["earlier", "reply", "now"])
        XCTAssertTrue(model.seen.first?.system.isEmpty == true)
        XCTAssertEqual(outcome.saved, .saved(conversationID: "c2", messageID: "m1"))
    }

    func testAContextRefusalIsTheServersSentenceAndNothingIsGenerated() async {
        let transport = MockTransport(routes: [.failure(.post, "/api/chat/context", status: 404, message: "Conversation not found.")])
        let model = FakeModel()
        let chat = OnDeviceChat(client: client(transport), provider: model, outbox: outbox())
        do {
            _ = try await chat.run(OnDeviceTurn(message: "x", conversationID: "gone")) { _ in }
            XCTFail("expected 404")
        } catch let error as HVError {
            XCTAssertEqual(error.userMessage, "Conversation not found.")
        } catch { XCTFail("\(error)") }
        XCTAssertTrue(model.seen.isEmpty)
    }

    func testAModelFailureSavesNothing() async {
        let transport = MockTransport(routes: [.json(.post, "/api/chat/context", Self.contextJSON)])
        let model = FakeModel(pieces: ["partial"], failure: OnDeviceChatError.generation("Too long for this model."))
        let chat = OnDeviceChat(client: client(transport), provider: model, outbox: outbox())
        do {
            _ = try await chat.run(OnDeviceTurn(message: "x", conversationID: "c1")) { _ in }
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual((error as? OnDeviceChatError), .generation("Too long for this model."))
        }
        let turns = await transport.requests(matching: "/api/chat/turns")
        XCTAssertTrue(turns.isEmpty)
    }

    func testAnEmptyReplyIsAnError() async {
        let transport = MockTransport(routes: [.json(.post, "/api/chat/context", Self.contextJSON)])
        let chat = OnDeviceChat(client: client(transport), provider: FakeModel(pieces: ["  "]), outbox: outbox())
        do {
            _ = try await chat.run(OnDeviceTurn(message: "x")) { _ in }
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual((error as? OnDeviceChatError), .emptyReply)
        }
    }

    func testAServerRefusalToSaveKeepsTheReplyAndSaysWhy() async throws {
        let transport = MockTransport(routes: [
            .json(.post, "/api/chat/context", Self.contextJSON),
            .failure(.post, "/api/chat/turns", status: 413, message: "assistant_content is too long."),
        ])
        let store = outbox()
        let chat = OnDeviceChat(client: client(transport), provider: FakeModel(), outbox: store)
        let outcome = try await chat.run(OnDeviceTurn(message: "x", conversationID: "c1")) { _ in }
        XCTAssertEqual(outcome.reply, "Hello there.")
        XCTAssertEqual(outcome.saved, .rejected("assistant_content is too long."))
        let waiting = await store.pending()
        XCTAssertTrue(waiting.isEmpty)
    }

    // MARK: the outbox

    func testALostConnectionQueuesTheTurnAndTheOutboxSavesItLater() async throws {
        let online = TestBox(false)
        let inner = MockTransport(routes: [
            .json(.post, "/api/chat/context", Self.contextJSON),
            .json(.post, "/api/chat/turns", #"{"conversation_id":"c1","reply":{"id":"m8","role":"assistant","content":"Hello there.","model":"fake-on-device"}}"#),
            .json(.get, "/api/conversations/c1", #"{"conversation":{"id":"c1","title":"t"},"messages":[]}"#),
        ])
        let flaky = FlakyTransport(inner: inner, isOnline: { online.value }, onlyAfterContext: true)
        let api = HVClient(baseURL: base, transport: flaky, tokens: StaticTokenProvider(), retry: .none, sleep: { _ in })
        let store = outbox()
        let chat = OnDeviceChat(client: api, provider: FakeModel(), outbox: store)

        online.value = true
        flaky.dropAfterContext = true
        let outcome = try await chat.run(OnDeviceTurn(message: "when do we fly?", conversationID: "c1", threadKey: "t1")) { _ in }
        XCTAssertEqual(outcome.saved, .queued)
        let waiting = await store.pending()
        XCTAssertEqual(waiting.count, 1)
        XCTAssertEqual(waiting[0].userMessage, "when do we fly?")
        XCTAssertEqual(waiting[0].conversationID, "c1")

        // Still offline: nothing changes.
        flaky.dropAfterContext = true
        let stuck = await store.flush(client: api)
        XCTAssertEqual(stuck.remaining, 1)
        XCTAssertTrue(stuck.saved.isEmpty)

        // Back online: saved, and the outbox is empty.
        flaky.dropAfterContext = false
        let report = await store.flush(client: api)
        XCTAssertEqual(report.saved.map(\.conversationID), ["c1"])
        XCTAssertEqual(report.saved.first?.messageID, "m8")
        XCTAssertEqual(report.remaining, 0)
        let after = await store.pending()
        XCTAssertTrue(after.isEmpty)
    }

    func testTurnsOfAnUnsavedConversationLandTogether() async throws {
        let ids = TestBox<[String?]>([])
        let transport = MockTransport(routes: [
            MockRoute(.post, "/api/chat/turns") { request in
                let id = requestJSON(request)?["conversation_id"]?.string
                ids.value.append(id)
                return HTTPResponse(status: 200, data: Data(#"{"conversation_id":"new1","reply":{"id":"m","role":"assistant","content":"x","model":"m"}}"#.utf8))
            },
            .json(.get, "/api/conversations/*", #"{"conversation":{"id":"new1","title":"t"},"messages":[]}"#),
        ])
        let store = outbox()
        await store.enqueue(PendingChatTurn(threadKey: "T", conversationID: nil, userMessage: "one", assistantContent: "1", model: "m"))
        await store.enqueue(PendingChatTurn(threadKey: "T", conversationID: nil, userMessage: "two", assistantContent: "2", model: "m"))
        await store.enqueue(PendingChatTurn(threadKey: "U", conversationID: nil, userMessage: "other", assistantContent: "3", model: "m"))
        let report = await store.flush(client: client(transport))
        XCTAssertEqual(report.saved.count, 3)
        // The first creates the conversation; the second joins it; the third is another thread.
        XCTAssertEqual(ids.value.map { $0 ?? "nil" }, ["nil", "new1", "nil"])
    }

    func testAReplayedTurnThatAlreadyGotThroughIsNotSavedTwice() async throws {
        let saves = Counter()
        let transport = MockTransport(routes: [
            .json(.get, "/api/conversations/c1", """
            {"conversation":{"id":"c1","title":"t"},"messages":[
              {"id":"u1","role":"user","content":"when do we fly?","position":0},
              {"id":"a1","role":"assistant","content":"Hello there.","position":1}]}
            """),
            MockRoute(.post, "/api/chat/turns") { _ in saves.bump(); return HTTPResponse(status: 500) },
        ])
        let store = outbox()
        await store.enqueue(PendingChatTurn(threadKey: "t", conversationID: "c1", userMessage: "when do we fly?", assistantContent: "Hello there.", model: "m"))
        let report = await store.flush(client: client(transport))
        XCTAssertEqual(report.saved.first?.messageID, "a1")
        XCTAssertEqual(saves.value, 0)
        XCTAssertEqual(report.remaining, 0)
    }

    func testARefusedQueuedTurnIsDroppedWithTheServersWords() async throws {
        let transport = MockTransport(routes: [
            .json(.get, "/api/conversations/gone", #"{"error":"x"}"#, status: 404),
            .failure(.post, "/api/chat/turns", status: 404, message: "Conversation not found."),
        ])
        let store = outbox()
        await store.enqueue(PendingChatTurn(threadKey: "t", conversationID: "gone", userMessage: "a", assistantContent: "b", model: "m"))
        let report = await store.flush(client: client(transport))
        XCTAssertEqual(report.rejected.map(\.message), ["Conversation not found."])
        XCTAssertEqual(report.remaining, 0)
    }

    func testTheOutboxSurvivesARestart() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hv-outbox-\(UUID().uuidString)")
        let first = ChatTurnOutbox(cache: DiskCache(directory: directory), namespace: "u1")
        await first.enqueue(PendingChatTurn(threadKey: "t", conversationID: nil, userMessage: "a", assistantContent: "b", model: "m"))
        let second = ChatTurnOutbox(cache: DiskCache(directory: directory), namespace: "u1")
        let waiting = await second.pending()
        XCTAssertEqual(waiting.map(\.userMessage), ["a"])
        let other = ChatTurnOutbox(cache: DiskCache(directory: directory), namespace: "someone-else")
        let none = await other.pending()
        XCTAssertTrue(none.isEmpty)
    }

    // MARK: reconciling a server turn

    func testReconcilerFindsASavedTurnOnlyAfterTheKnownMessages() {
        let history = [
            ChatMessage(id: "1", role: .user, content: "same words"),
            ChatMessage(id: "2", role: .assistant, content: "old answer"),
            ChatMessage(id: "3", role: .user, content: "same words "),
            ChatMessage(id: "4", role: .assistant, content: "```tool\n{\"intent\":\"x\"}\n```"),
            ChatMessage(id: "5", role: .tool, content: "```tool-result\n{\"intent\":\"x\"}\n```"),
            ChatMessage(id: "6", role: .assistant, content: "new answer"),
        ]
        XCTAssertEqual(ChatTurnReconciler.savedReply(for: "same words", in: history, afterIndex: 0)?.id, "6")
        // Before the turn was sent there were two messages; only the new pair counts.
        XCTAssertEqual(ChatTurnReconciler.savedReply(for: "same words", in: history, afterIndex: 2)?.id, "6")
        XCTAssertNil(ChatTurnReconciler.savedReply(for: "same words", in: Array(history.prefix(2)), afterIndex: 2))
        XCTAssertNil(ChatTurnReconciler.savedReply(for: "different", in: history, afterIndex: 0))
        // A user message with no reply yet is not a finished turn.
        XCTAssertNil(ChatTurnReconciler.savedReply(for: "x", in: [ChatMessage(id: "1", role: .user, content: "x")], afterIndex: 0))
    }

    func testReconcilerFindsANewConversationByItsTitle() {
        let now = Date()
        let list = [
            ChatConversation(id: "old", title: "Hello there friend", updatedAt: now.addingTimeInterval(-3_600)),
            ChatConversation(id: "imported", title: "Hello there friend", sourcePlatform: "chatgpt", updatedAt: now),
            ChatConversation(id: "mine", title: "Hello there friend, how are you today", updatedAt: now),
        ]
        let found = ChatTurnReconciler.newConversation(for: "Hello there friend, how are you today", in: list, startedAt: now.addingTimeInterval(-30))
        XCTAssertEqual(found?.id, "mine")
        XCTAssertNil(ChatTurnReconciler.newConversation(for: "Something else", in: list, startedAt: now.addingTimeInterval(-30)))
    }

    func testReconcileAsksTheServer() async {
        let transport = MockTransport(routes: [.json(.get, "/api/conversations/c1", """
        {"conversation":{"id":"c1","title":"t"},"messages":[
          {"id":"1","role":"user","content":"hi","position":0},{"id":"2","role":"assistant","content":"hello","position":1}]}
        """)])
        let found = await ChatTurnReconciler.reconcile(client: client(transport), message: "hi", conversationID: "c1", knownMessageCount: 0, startedAt: Date())
        XCTAssertEqual(found?.messages.count, 2)
        let missing = await ChatTurnReconciler.reconcile(client: client(transport), message: "hi", conversationID: "c1", knownMessageCount: 2, startedAt: Date())
        XCTAssertNil(missing)
    }
}

/// Answers some paths as if the network were gone.
struct OfflineTransport: HTTPTransport {
    let inner: MockTransport
    let failing: Set<String>
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        if let path = request.url?.path, failing.contains(path) { throw URLError(.notConnectedToInternet) }
        return try await inner.send(request)
    }
}

/// Lets the context call through, then drops the network when told to.
final class FlakyTransport: HTTPTransport, @unchecked Sendable {
    let inner: MockTransport
    let isOnline: @Sendable () -> Bool
    private let lock = NSLock()
    private var _drop = false
    init(inner: MockTransport, isOnline: @escaping @Sendable () -> Bool, onlyAfterContext: Bool) {
        self.inner = inner
        self.isOnline = isOnline
    }
    var dropAfterContext: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _drop }
        set { lock.lock(); _drop = newValue; lock.unlock() }
    }
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let path = request.url?.path ?? ""
        if dropAfterContext, path != "/api/chat/context" { throw URLError(.networkConnectionLost) }
        return try await inner.send(request)
    }
}
