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

    private func settle(_ model: ChatConversationModel) async {
        for _ in 0..<300 where model.isWorking { try? await Task.sleep(nanoseconds: 10_000_000) }
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
}

private struct OfflineAlways: HTTPTransport {
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        throw URLError(.notConnectedToInternet)
    }
}
