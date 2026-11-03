import HyperVaultKit
import XCTest
@testable import HyperVault

/// When Home may say a person has no chats. The starter page stands in for the list only once the server itself has said
/// "none": a cached empty list is a guess (the person may have made chats elsewhere since), and a refresh that failed
/// says nothing.
@MainActor
final class ChatListStarterTests: XCTestCase {
    private let base = URL(string: "https://t.test")!
    private let namespace = "u1"
    private let cacheKey = "chat.conversations"
    private let none = #"{"conversations":[]}"#
    private let one = #"{"conversations":[{"id":"c1","title":"Lisbon","source_platform":"hypervault","updated_at":"2026-10-24T08:30:00.000Z"}]}"#

    private func freshCache() -> DiskCache {
        DiskCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("hv-chatlist-\(UUID().uuidString)"))
    }

    private func list(_ transport: any HTTPTransport, cache: DiskCache) -> ChatListModel {
        let client = HVClient(baseURL: base, transport: transport, tokens: StaticTokenProvider(), retry: .none)
        return ChatListModel(client: client, cache: cache, namespace: namespace)
    }

    private func eventually(_ what: String, file: StaticString = #filePath, line: UInt = #line, _ condition: () async -> Bool) async {
        for _ in 0..<300 {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Never happened: \(what)", file: file, line: line)
    }

    // MARK: Nothing is known until the server answers

    func testACachedNoChatsIsNotTheStarterWhileTheFetchIsOut() async {
        let cache = freshCache()
        await cache.store([ChatConversation](), key: cacheKey, namespace: namespace)
        let hold = RequestHold()
        await hold.arm()
        let mock = MockTransport(routes: [.json(.get, "/api/conversations", none)])
        let model = list(HeldTransport(base: mock, hold: hold, holds: { $0.url?.path == "/api/conversations" }), cache: cache)

        let loading = Task { await model.load() }
        await eventually("the fetch to be on its way") { await hold.waiting == 1 }
        // (The cached copy was read before the fetch went out: give the model the moment it needs to see it.)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(model.phase, .loading, "the cached empty list is passed over, so the skeleton stays")
        XCTAssertFalse(model.showsStarter, "and the starter does not flash under a list that may be on its way")

        await hold.release()
        await loading.value
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertTrue(model.showsStarter, "the server said there are none")
    }

    func testAnEmptyCacheAndAFailedFetchIsAnErrorNotTheStarter() async {
        let cache = freshCache()
        await cache.store([ChatConversation](), key: cacheKey, namespace: namespace)
        let model = list(OfflineTransport(), cache: cache)
        await model.load()
        guard case .failed = model.phase else { return XCTFail("a refresh that failed is not \"no chats\": \(model.phase)") }
        XCTAssertFalse(model.showsStarter)
    }

    func testNothingCachedAndAFailedFetchIsAnErrorNotTheStarter() async {
        let model = list(OfflineTransport(), cache: freshCache())
        await model.load()
        guard case .failed = model.phase else { return XCTFail("\(model.phase)") }
        XCTAssertFalse(model.showsStarter)
    }

    func testNothingCachedAndTheServerSayingNoneIsTheStarter() async {
        let model = list(MockTransport(routes: [.json(.get, "/api/conversations", none)]), cache: freshCache())
        XCTAssertFalse(model.showsStarter, "before anything has been asked")
        await model.load()
        XCTAssertTrue(model.showsStarter)
        XCTAssertTrue(model.conversations.isEmpty)
        XCTAssertFalse(model.isStale)
    }

    // MARK: A list that is there stays until the server says otherwise

    func testChatsInTheCacheAndTheServerSayingNoneIsTheStarter() async {
        let cache = freshCache()
        await cache.store([ChatConversation(id: "c1", title: "Lisbon")], key: cacheKey, namespace: namespace)
        let model = list(MockTransport(routes: [.json(.get, "/api/conversations", none)]), cache: cache)
        await model.load()
        XCTAssertTrue(model.conversations.isEmpty)
        XCTAssertTrue(model.showsStarter, "every chat was deleted somewhere else: the server's answer wins over the cache")
    }

    func testChatsInTheCacheAndAFailedFetchKeepTheListAsStale() async {
        let cache = freshCache()
        await cache.store([ChatConversation(id: "c1", title: "Lisbon")], key: cacheKey, namespace: namespace)
        let model = list(OfflineTransport(), cache: cache)
        await model.load()
        XCTAssertEqual(model.conversations.map(\.id), ["c1"])
        XCTAssertTrue(model.isStale)
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertFalse(model.showsStarter)
    }

    func testAStarterThatTheServerSaidStaysThroughARefreshThatFails() async {
        let flaky = Flaky(inner: MockTransport(routes: [.json(.get, "/api/conversations", none)]))
        let model = list(flaky, cache: freshCache())
        await model.load()
        XCTAssertTrue(model.showsStarter)

        await flaky.setOnline(false)
        await model.load()
        XCTAssertTrue(model.showsStarter, "the last thing the server said is still \"none\", as a list would stay a list")
        XCTAssertEqual(model.phase, .loaded)
    }

    func testAStarterGivesWayToTheListThatArrivesLater() async {
        let transport = MockTransport(routes: [.json(.get, "/api/conversations", none)])
        let model = list(transport, cache: freshCache())
        await model.load()
        XCTAssertTrue(model.showsStarter)

        await transport.add(.json(.get, "/api/conversations", one))
        await model.load()
        XCTAssertFalse(model.showsStarter)
        XCTAssertEqual(model.conversations.map(\.id), ["c1"])
    }

    // MARK: Deleting the last chat

    func testDeletingTheLastChatOfAFreshListIsTheStarterAtOnce() async throws {
        let transport = MockTransport(routes: [
            .json(.get, "/api/conversations", one),
            MockRoute(.delete, "/api/conversations/c1") { _ in HTTPResponse(status: 204) },
        ])
        let model = list(transport, cache: freshCache())
        await model.load()
        XCTAssertFalse(model.showsStarter)

        let last = try XCTUnwrap(model.conversations.first)
        try await model.delete(last)
        XCTAssertTrue(model.showsStarter)
    }

    func testDeletingTheLastChatOfAListFromTheCacheAsksTheServerWhatIsLeft() async throws {
        let cache = freshCache()
        await cache.store([ChatConversation(id: "c1", title: "Lisbon")], key: cacheKey, namespace: namespace)
        let flaky = Flaky(inner: MockTransport(routes: [
            .json(.get, "/api/conversations", none),
            MockRoute(.delete, "/api/conversations/c1") { _ in HTTPResponse(status: 204) },
        ]))
        await flaky.setOnline(false)
        let model = list(flaky, cache: cache)
        await model.load()
        XCTAssertTrue(model.isStale, "offline: the list is the cached one")

        await flaky.setOnline(true)
        let last = try XCTUnwrap(model.conversations.first)
        try await model.delete(last)
        XCTAssertFalse(model.isStale, "the server was asked, not the cache")
        XCTAssertTrue(model.showsStarter, "and it said there are none")
    }
}
