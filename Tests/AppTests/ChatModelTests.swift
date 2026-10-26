import HyperVaultKit
import XCTest
@testable import HyperVault

/// A model that writes a fixed reply in pieces.
private struct FakeOnDeviceModel: ChatModelProvider {
    let modelName = "fake-on-device"
    let contextBudget = 7_000

    func generate(system: String, messages: [ChatWireMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield("Hel")
            continuation.yield("Hello from the phone.")
            continuation.finish()
        }
    }
}

/// Never answers; throws when the task is cancelled, as URLSession does.
private struct HangingTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        try await Task.sleep(nanoseconds: 60_000_000_000)
        return HTTPResponse(status: 200)
    }
}

@MainActor
final class ChatModelTests: XCTestCase {
    private let turn = """
    {"conversation_id":"c9","reply":{"id":"m12","role":"assistant","content":"Here is the answer.","model":"claude-opus-4-8","truncated":false},
     "backend":{"id":"b1","name":"Claude","provider":"anthropic"},
     "recalled":[{"title":"Trip notes","slug":"trip-1"}],"recalled_memories":["Flights"],"pulled":[],
     "recall_branch":"main","smart_context":false,"deep_memory":null,"truth":null,
     "tools":{"status":"off","toolkit_id":null,"turns":[],"embedder":null},"tool_selection":null}
    """

    private func makeModel(
        routes: [MockRoute], transport: HTTPTransport? = nil, onDevice: ChatOnDeviceSupport = .fixed(.unavailable("test"))
    ) -> ChatConversationModel {
        let env = AppEnvironment.preview(routes: routes)
        let client = transport.map { HVClient(baseURL: env.client.baseURL, transport: $0, tokens: StaticTokenProvider()) } ?? env.client
        let defaults = UserDefaults(suiteName: "chat-model-tests-\(UUID().uuidString)") ?? .standard
        let model = ChatConversationModel(
            conversationID: nil, client: client, cache: env.cache, namespace: "test",
            limits: env.limits, features: env.features, onDevice: onDevice,
            outbox: ChatTurnOutbox(cache: env.cache, namespace: "test"), defaults: defaults
        )
        let claude = ChatBackend(id: "b1", name: "Claude", provider: "anthropic", defaultModel: "claude-opus-4-8")
        model.seed(rows: [], backends: [claude], choice: .server("b1"))
        return model
    }

    /// Waits for a turn to finish. The limit is generous: a shared CI runner can stall for seconds, and a
    /// test that waits longer than it needs to costs nothing, where one that gives up early is a false failure.
    private func settle(_ model: ChatConversationModel) async {
        for _ in 0..<2_000 where model.isWorking { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    func testASentMessageGetsItsReplyAndTheConversationIsAdopted() async {
        let model = makeModel(routes: [.json(.post, "/api/chat", turn)])
        model.draft = "  plan it  "
        model.sendDraft()
        XCTAssertEqual(model.draft, "")
        XCTAssertTrue(model.isWorking)
        await settle(model)

        XCTAssertEqual(model.rows.map(\.kind), [.user, .assistant])
        XCTAssertEqual(model.rows[0].text, "plan it")
        XCTAssertEqual(model.rows[0].state, .saved)
        XCTAssertEqual(model.rows[1].text, "Here is the answer.")
        XCTAssertEqual(model.rows[1].serverID, "m12")
        XCTAssertEqual(model.rows[1].grounding.memories, ["Flights"])
        XCTAssertEqual(model.conversationID, "c9")
        XCTAssertEqual(model.title, "plan it")
    }

    func testTheServersOwnSentenceIsShownAndTheMessageCanBeRetried() async {
        let model = makeModel(routes: [.failure(.post, "/api/chat", status: 502, message: "No response from the endpoint.")])
        model.draft = "hello"
        model.sendDraft()
        await settle(model)
        XCTAssertEqual(model.rows.count, 1)
        XCTAssertEqual(model.rows[0].state, .failed("No response from the endpoint."))

        model.edit(model.rows[0])
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertEqual(model.draft, "hello")
    }

    func testAMessageOverTheLimitNeverLeaves() async {
        let model = makeModel(routes: [.json(.post, "/api/chat", turn)])
        model.draft = String(repeating: "a", count: model.maxCharacters + 1)
        XCTAssertFalse(model.canSend)
        model.sendDraft()
        XCTAssertEqual(model.notice, "Message is too long.")
        XCTAssertTrue(model.rows.isEmpty)
    }

    func testStoppingPutsTheWordsBack() async {
        let model = makeModel(routes: [], transport: HangingTransport())
        model.draft = "this will take a while"
        model.sendDraft()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(model.isWorking)
        model.stop()
        await settle(model)
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertEqual(model.draft, "this will take a while")
        XCTAssertNotNil(model.notice)
    }

    func testAThumbIsUndoneWhenTheServerSaysNo() async throws {
        let model = makeModel(routes: [
            .json(.post, "/api/chat", turn),
            .failure(.post, "/api/messages/m12/feedback", status: 503, message: "Feedback isn't enabled on this server yet."),
        ])
        model.draft = "hi"
        model.sendDraft()
        await settle(model)
        let reply = try XCTUnwrap(model.rows.last)
        do {
            try await model.rate(reply, .up)
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Feedback isn't enabled on this server yet.")
        }
        XCTAssertNil(model.rows.last?.feedback)
    }

    func testAnOnDeviceTurnStreamsAndIsSaved() async {
        let model = makeModel(
            routes: [
                .json(.post, "/api/chat/context", #"{"conversation_id":null,"system":"S","messages":[{"role":"user","content":"hi"}],"next_position":0}"#),
                .json(.post, "/api/chat/turns", #"{"conversation_id":"c5","reply":{"id":"m3","role":"assistant","content":"x","model":"fake-on-device"}}"#),
            ],
            onDevice: .fixed(.ready, provider: FakeOnDeviceModel())
        )
        model.select(.onDevice)
        model.draft = "hi"
        model.sendDraft()
        await settle(model)
        XCTAssertEqual(model.rows.map(\.kind), [.user, .assistant])
        XCTAssertEqual(model.rows[1].text, "Hello from the phone.")
        XCTAssertEqual(model.rows[1].state, .saved)
        XCTAssertTrue(model.rows[1].onDevice)
        XCTAssertEqual(model.conversationID, "c5")
    }

    func testAModelOnTheNetworkAnswersAndIsSaved() async {
        let local = ChatLocalModel(id: "l1", name: "Studio", baseURL: "192.168.1.20:11434", model: "llama3.3")
        let model = makeModel(
            routes: [
                .json(.post, "/api/chat/context", #"{"conversation_id":null,"system":"S","messages":[{"role":"user","content":"hi"}],"next_position":0}"#),
                .json(.post, "/api/chat/turns", #"{"conversation_id":"c6","reply":{"id":"m4","role":"assistant","content":"x","model":"fake-on-device"}}"#),
            ],
            onDevice: .fixed(.unavailable("no"), localModels: [local], localProvider: FakeOnDeviceModel())
        )
        model.localModelsChanged([local])
        model.select(.local("l1"))
        XCTAssertTrue(model.runsLocally)
        XCTAssertEqual(model.modelName, "Studio")
        XCTAssertNotNil(model.toolFreeLine)
        model.draft = "hi"
        model.sendDraft()
        await settle(model)
        XCTAssertEqual(model.rows.map(\.kind), [.user, .assistant])
        XCTAssertEqual(model.rows[1].text, "Hello from the phone.")
        XCTAssertEqual(model.rows[1].state, .saved)
        XCTAssertEqual(model.conversationID, "c6")
    }

    func testAnOnDeviceTurnWaitsInTheOutboxWhenTheNetworkIsGone() async {
        let env = AppEnvironment.preview(routes: [])
        let outbox = ChatTurnOutbox(cache: env.cache, namespace: "offline")
        let client = HVClient(
            baseURL: env.client.baseURL, transport: OfflineAlways(), tokens: StaticTokenProvider(), retry: .none, sleep: { _ in }
        )
        let model = ChatConversationModel(
            conversationID: nil, client: client, cache: env.cache, namespace: "offline", limits: env.limits, features: env.features,
            onDevice: .fixed(.ready, provider: FakeOnDeviceModel()), outbox: outbox
        )
        model.seed(rows: [], choice: .onDevice)
        model.draft = "hi"
        model.sendDraft()
        await settle(model)
        XCTAssertEqual(model.rows.map(\.state), [.waitingToSync, .waitingToSync])
        let waiting = await outbox.pending()
        XCTAssertEqual(waiting.map(\.userMessage), ["hi"])
        XCTAssertNotNil(model.notice)
    }

    /// A phone that starts offline and is told when the network is back.
    private func offlineChat(
        conversationID: String?, namespace: String, routes: [MockRoute]
    ) -> (model: ChatConversationModel, network: ChatSwitchedTransport) {
        let env = AppEnvironment.preview(routes: [])
        let network = ChatSwitchedTransport(routes: routes)
        let client = HVClient(baseURL: env.client.baseURL, transport: network, tokens: StaticTokenProvider(), retry: .none, sleep: { _ in })
        let model = ChatConversationModel(
            conversationID: conversationID, client: client, cache: env.cache, namespace: namespace,
            limits: env.limits, features: env.features, onDevice: .fixed(.ready, provider: FakeOnDeviceModel()),
            outbox: ChatTurnOutbox(cache: env.cache, namespace: namespace)
        )
        let existing = conversationID.map { ChatConversation(id: $0, title: "Trip", updatedAt: Date()) }
        model.seed(rows: [], conversation: existing, choice: .onDevice)
        return (model, network)
    }

    func testAReplyQueuedInAChatThatAlreadyExistsStopsWaitingOnceTheOutboxSavesIt() async {
        let (model, network) = offlineChat(conversationID: "c1", namespace: "existing", routes: [
            .json(.get, "/api/conversations/c1", #"{"conversation":{"id":"c1","title":"Trip"},"messages":[]}"#),
            .json(.post, "/api/chat/turns", #"{"conversation_id":"c1","reply":{"id":"m77","role":"assistant","content":"x","model":"fake-on-device"}}"#),
        ])
        model.draft = "hi"
        model.sendDraft()
        await settle(model)
        XCTAssertEqual(model.rows.map(\.state), [.waitingToSync, .waitingToSync])

        network.goOnline()
        await model.syncOutbox()
        XCTAssertEqual(model.rows.map(\.state), [.saved, .saved])
        XCTAssertNil(model.rows[0].serverID)
        XCTAssertEqual(model.rows[1].serverID, "m77", "the reply can be rated, and the thread can be pulled to refresh")
        XCTAssertEqual(model.conversationID, "c1")
    }

    func testAQueuedTurnTheServerRefusesForGoodSaysSoInsteadOfWaiting() async {
        let (model, network) = offlineChat(conversationID: "c1", namespace: "refused", routes: [
            .json(.get, "/api/conversations/c1", #"{"error":"Conversation not found."}"#, status: 404),
            .failure(.post, "/api/chat/turns", status: 404, message: "Conversation not found."),
        ])
        model.draft = "hi"
        model.sendDraft()
        await settle(model)
        XCTAssertEqual(model.rows.map(\.state), [.waitingToSync, .waitingToSync])

        network.goOnline()
        await model.syncOutbox()
        XCTAssertEqual(model.rows.map(\.state), [.notSaved("Conversation not found."), .notSaved("Conversation not found.")])
    }

    func testOnlyTheTurnsTheOutboxSavedStopWaiting() async {
        // Two turns wait; the connection comes back for the first and the second is met by a server hiccup.
        let posts = ChatPostCount()
        let (model, network) = offlineChat(conversationID: "c1", namespace: "half", routes: [
            .json(.get, "/api/conversations/c1", #"{"conversation":{"id":"c1","title":"Trip"},"messages":[]}"#),
            MockRoute(.post, "/api/chat/turns") { _ in
                if posts.next() == 1 {
                    return HTTPResponse(status: 200, data: Data(#"{"conversation_id":"c1","reply":{"id":"m1","role":"assistant","content":"x","model":"m"}}"#.utf8))
                }
                return HTTPResponse(status: 503, data: Data(#"{"error":"Try again."}"#.utf8))
            },
        ])
        model.draft = "one"
        model.sendDraft()
        await settle(model)
        model.draft = "two"
        model.sendDraft()
        await settle(model)
        XCTAssertEqual(model.rows.map(\.state), Array(repeating: ChatThreadRow.State.waitingToSync, count: 4))

        network.goOnline()
        await model.syncOutbox()
        XCTAssertEqual(model.rows.map(\.state), [.saved, .saved, .waitingToSync, .waitingToSync])
        XCTAssertEqual(model.rows[1].serverID, "m1")
        XCTAssertNil(model.rows[3].serverID)
    }

    func testAChatThatWasNewWhenItWasWrittenIsAdoptedAndItsRowsSettled() async {
        let (model, network) = offlineChat(conversationID: nil, namespace: "fresh", routes: [
            .json(.post, "/api/chat/turns", #"{"conversation_id":"c42","reply":{"id":"m5","role":"assistant","content":"x","model":"m"}}"#),
        ])
        model.draft = "hi"
        model.sendDraft()
        await settle(model)
        XCTAssertNil(model.conversationID)

        network.goOnline()
        await model.syncOutbox()
        XCTAssertEqual(model.conversationID, "c42")
        XCTAssertEqual(model.rows.map(\.state), [.saved, .saved])
        XCTAssertEqual(model.rows[1].serverID, "m5")
    }

    func testConsecutiveToolStepsFoldIntoOneGroup() {
        func step() -> ChatThreadRow { ChatThreadRow(kind: .tool, toolTurn: ChatToolTurn(intent: "x")) }
        let rows = [
            ChatThreadRow(id: "u", kind: .user, text: "hi"), step(), step(),
            ChatThreadRow(id: "a", kind: .assistant, text: "done"), step(),
        ]
        let items = ChatThreadItem.items(from: rows)
        XCTAssertEqual(items.count, 4)
        guard case .tools(let first) = items[1], case .tools(let last) = items[3] else { return XCTFail("\(items)") }
        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(last.count, 1)
    }

    func testDateBuckets() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func bucket(_ secondsAgo: Double) -> ChatDates.Bucket {
            ChatDates.bucket(for: now.addingTimeInterval(-secondsAgo), now: now, calendar: calendar)
        }
        XCTAssertEqual(bucket(60), .today)
        XCTAssertEqual(bucket(86_400), .yesterday)
        XCTAssertEqual(bucket(86_400 * 4), .week)
        XCTAssertEqual(bucket(86_400 * 20), .month)
        XCTAssertEqual(bucket(86_400 * 90), .earlier)
        XCTAssertEqual(ChatDates.bucket(for: nil, now: now, calendar: calendar), .earlier)
    }

    func testItemsAreGroupedUnderTheirDateBuckets() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let items: [(name: String, date: Date?)] = [
            ("fresh", now.addingTimeInterval(-60)),
            ("last week", now.addingTimeInterval(-86_400 * 4)),
            ("old", now.addingTimeInterval(-86_400 * 90)),
            ("undated", nil),
        ]
        let sections = ChatDates.sections(of: items, date: { $0.date }, now: now, calendar: calendar)
        XCTAssertEqual(sections.map(\.bucket), [.today, .week, .earlier])
        XCTAssertEqual(sections[2].items.map(\.name), ["old", "undated"])
    }

    // MARK: Who wears which colour

    func testAModelKeepsItsColourWhoeverElseIsInTheRoom() {
        XCTAssertEqual(ChatAgentTone.tones(forProviders: ["xai", "gemini", "anthropic"]), [.violet, .blue, .coral])
        XCTAssertEqual(ChatAgentTone.tones(forProviders: ["anthropic", "openai"]), [.coral, .mint])
        XCTAssertEqual(ChatAgentTone.tones(forProviders: ["openai", "anthropic"]), [.mint, .coral])
    }

    func testTwoMembersOfOneModelNeverShareAColour() {
        let tones = ChatAgentTone.tones(forProviders: ["anthropic", "anthropic", "openai", "anthropic"])
        XCTAssertEqual(tones.count, 4)
        XCTAssertEqual(Set(tones).count, 4)
        // The first of each family keeps its own tone; the copies take whatever is free.
        XCTAssertEqual(tones[0], .coral)
        XCTAssertEqual(tones[2], .mint)
        XCTAssertEqual(tones, ChatAgentTone.tones(forProviders: ["anthropic", "anthropic", "openai", "anthropic"]))
    }

    func testARoomLargerThanThePaletteStillGetsAToneForEveryone() {
        let tones = ChatAgentTone.tones(forProviders: Array(repeating: "anthropic", count: ChatAgentTone.allCases.count + 3))
        XCTAssertEqual(tones.count, ChatAgentTone.allCases.count + 3)
        XCTAssertEqual(tones.first, .coral)
    }

    func testAnImportedChatWearsTheColourOfItsModelsFamily() {
        XCTAssertEqual(ChatAgentTone(platform: .claude), ChatAgentTone(provider: "anthropic"))
        XCTAssertEqual(ChatAgentTone(platform: .chatgpt), ChatAgentTone(provider: "openai"))
        XCTAssertEqual(ChatAgentTone(platform: .gemini), ChatAgentTone(provider: "gemini"))
        XCTAssertEqual(ChatAgentTone(platform: .grok), ChatAgentTone(provider: "xai"))
        XCTAssertNotEqual(ChatAgentTone(platform: .claude), ChatAgentTone(platform: .chatgpt))
        XCTAssertNil(ChatAgentTone(platform: .hypervault))
    }

    // MARK: Rooms

    func testTheRoomsMessageBoxSuggestsAddressingTheMembersItHas() async {
        let env = AppEnvironment.preview(routes: ChatPreviewData.routes)
        let model = ChatRoomModel(roomID: "r1", client: env.client)
        XCTAssertEqual(model.composerPrompt, "Say something to the room")

        await model.load()
        let handles = model.members.map(\.handle)
        XCTAssertEqual(handles, ["grok", "gemini", "claude"])
        XCTAssertEqual(model.composerPrompt, "grok, draft it. gemini, review it.")
        // The example is a real address: typed as it stands, it goes to the first two members.
        XCTAssertEqual(ChatRoomHandles.mentions(in: model.composerPrompt, handles: handles), ["grok", "gemini"])
    }

    func testRoomsAreGroupedByWhenTheyLastMoved() async throws {
        let env = AppEnvironment.preview(routes: ChatPreviewData.routes)
        let model = ChatRoomsListModel(client: env.client, cache: env.cache, namespace: "test")
        await model.load()
        XCTAssertEqual(model.rooms.map(\.id), ["r1", "r2"])
        XCTAssertEqual(model.sections.flatMap(\.items).map(\.id), ["r1", "r2"])
        // Ten minutes ago is today, or yesterday for the minutes just after midnight; four days ago is last week.
        let first = try XCTUnwrap(model.sections.first).bucket
        XCTAssertTrue(first == .today || first == .yesterday)
        XCTAssertEqual(model.sections.last?.bucket, .week)
    }
}

private struct OfflineAlways: HTTPTransport {
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        throw URLError(.notConnectedToInternet)
    }
}

/// Drops every request until it is told the network is back, then answers from its routes.
private final class ChatSwitchedTransport: HTTPTransport, @unchecked Sendable {
    private let inner: MockTransport
    private let lock = NSLock()
    private var online = false

    init(routes: [MockRoute]) { inner = MockTransport(routes: routes) }

    func goOnline() { lock.lock(); online = true; lock.unlock() }

    private var isUp: Bool { lock.lock(); defer { lock.unlock() }; return online }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        if !isUp { throw URLError(.notConnectedToInternet) }
        return try await inner.send(request)
    }
}

/// Numbers the calls a route gets, from any thread.
private final class ChatPostCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func next() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
}
