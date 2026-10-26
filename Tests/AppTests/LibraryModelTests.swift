import HyperVaultKit
import XCTest
@testable import HyperVault

/// What the Library and a page do with what the server says, on canned answers:
/// the file manager's join of three reads, and each change that is shown at once
/// and taken back when the server refuses it.
@MainActor
final class LibraryModelTests: XCTestCase {
    private let artifacts = #"""
    {"items":[
     {"slug":"pomo-1","title":"Pomodoro Timer","type":"react","tags":["focus","timer"],"is_pwa":true,"is_jsx":true,"visibility":"private","created_at":"2026-10-20T10:00:00.000Z"},
     {"slug":"trip-1","title":"Trip planner","type":"group","tags":["travel"],"is_pwa":false,"is_jsx":false,"visibility":"public","created_at":"2026-10-18T10:00:00.000Z"},
     {"slug":"setup-1","title":"Setup challenge","type":"html","tags":["agent-setup-challenge"],"is_pwa":false,"is_jsx":false,"visibility":"private","created_at":"2026-10-01T10:00:00.000Z"}
    ]}
    """#

    private let yours = #"""
    {"recent":[],"results":[
     {"id":"A1","kind":"page","name":"Pomodoro Timer","summary":"","updated_at":"2026-10-20T10:00:00.000Z","last_opened_at":null,"href":"/a/pomo-1"},
     {"id":"G1","kind":"group","name":"Trip planner","summary":"","updated_at":"2026-10-18T10:00:00.000Z","last_opened_at":null,"href":"/g/trip-1"}
    ]}
    """#

    private let edges = #"""
    {"connections":[{"id":"e1","a_id":"A1","b_id":"X","kind":"manual"},{"id":"e2","a_id":"Y","b_id":"A1","kind":"auto"}],"memory_links":[],"memory_artifact_links":[]}
    """#

    private func routes(extra: [MockRoute] = []) -> [MockRoute] {
        extra + [
            .json(.get, "/api/artifacts", artifacts),
            .json(.get, "/api/yours", yours),
            .json(.get, "/api/connections", edges),
        ]
    }

    private func model(_ routes: [MockRoute]) -> LibraryModel {
        LibraryModel(env: AppEnvironment.preview(routes: routes))
    }

    // MARK: Files

    func testTheFileManagerJoinsTheListTheIdsAndTheConnections() async {
        let model = model(routes())
        await model.load(filter: .file, query: "")
        let rows = model.rows(matching: "")
        XCTAssertEqual(rows.map(\.summary.slug), ["pomo-1", "trip-1"], "the page the system keeps for itself is not listed")
        XCTAssertEqual(rows[0].connections, 2)
        XCTAssertEqual(rows[0].rowID, "A1")
        XCTAssertEqual(rows[1].connections, 0)
        XCTAssertEqual(model.phase, .loaded)
    }

    func testSearchReadsTheNameATypeAsAPersonSaysItAndTags() async {
        let model = model(routes())
        await model.load(filter: .file, query: "")
        XCTAssertEqual(model.rows(matching: "pomo").map(\.summary.slug), ["pomo-1"])
        XCTAssertEqual(model.rows(matching: "TRAVEL").map(\.summary.slug), ["trip-1"])
        XCTAssertEqual(model.rows(matching: "group").map(\.summary.slug), ["trip-1"])
        XCTAssertEqual(model.rows(matching: "  react ").map(\.summary.slug), ["pomo-1"])
        XCTAssertEqual(model.rows(matching: "react page").map(\.summary.slug), ["pomo-1"], "the words the row shows find it")
        XCTAssertEqual(model.rows(matching: "nothing like this"), [])
    }

    func testAPageWhoseIdIsNotKnownStillListsWithNoCount() async {
        let model = model(routes(extra: [.json(.get, "/api/yours", #"{"recent":[],"results":[]}"#)]))
        await model.load(filter: .file, query: "")
        XCTAssertEqual(model.rows(matching: "").map(\.connections), [0, 0])
        XCTAssertNil(model.rows(matching: "").first?.rowID)
    }

    // MARK: Yours

    func testAnotherFilterDoesNotBorrowTheLastOnesRows() async {
        // The next filter's read is slow to answer: until it does, nothing from the first is on screen.
        let slow = LibraryModel(env: AppEnvironment.preview(routes: routes(), delay: 0.3))
        await slow.load(filter: .all, query: "")
        XCTAssertEqual(slow.items.count, 2)
        let reading = Task { await slow.load(filter: .key, query: "") }
        try? await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(slow.items.count, 0)
        XCTAssertEqual(slow.phase, .loading)
        await reading.value
        XCTAssertEqual(slow.phase, .loaded)
    }

    func testAFailedFirstReadSaysSoAndKeepsNoRows() async {
        let model = model([.failure(.get, "/api/yours", status: 500, message: "Could not list what you have kept. Try again.")])
        await model.load(filter: .all, query: "")
        XCTAssertEqual(model.phase, .failed(LibraryCopy.failed))
        XCTAssertEqual(model.items, [])
    }

    func testAFailedReadSaysWhatHappenedAndLeavesTheRetryToTheButton() async {
        let model = model([.failure(.get, "/api/yours", status: 500, message: "Could not list what you have kept. Try again.")])
        await model.load(filter: .all, query: "")
        XCTAssertFalse(model.failureIsOffline, "a server that answered is not a lost connection")
        XCTAssertFalse(LibraryCopy.failed.contains("Try again"), "the screen's button says that")
        XCTAssertFalse(LibraryCopy.offline.contains("Try again"))
    }

    func testAReadThatNeverGotThroughIsOffline() async {
        let server = ServerConfig(baseURL: URL(string: "https://preview.hypervault.test")!)
        let offline = LibraryOfflineTransport()
        let env = AppEnvironment(
            client: HVClient(baseURL: server.baseURL, transport: offline, tokens: StaticTokenProvider(), retry: .none),
            auth: AuthService(
                config: SupabaseConfig(url: URL(string: "https://preview.supabase.test")!, anonKey: "preview"),
                transport: offline, store: InMemorySecureStore()
            ),
            capabilities: Capabilities(),
            user: AuthUser(id: "preview-user", email: "sam@example.com", displayName: "Sam"),
            server: server,
            cache: DiskCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("hv-offline-\(UUID().uuidString)"))
        )
        let model = LibraryModel(env: env)
        await model.load(filter: .all, query: "")
        XCTAssertEqual(model.phase, .failed(LibraryCopy.offline))
        XCTAssertTrue(model.failureIsOffline)
    }

    func testASearchCutsTheNameAtOneHundredCharacters() async throws {
        let seen = LibraryTestBox<String?>(nil)
        let capture = MockRoute(.get, "/api/yours") { request in
            seen.value = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value
            return HTTPResponse(status: 200, data: Data(#"{"recent":[],"results":[]}"#.utf8))
        }
        let model = model([capture])
        await model.load(filter: .memory, query: String(repeating: "a", count: 140))
        XCTAssertEqual(seen.value?.count, 100)
    }

    // MARK: Changes

    func testMakingAPagePublicShowsAtOnceAndKeepsWhatTheServerSaid() async {
        let toasts = ToastCenter()
        let model = model(routes(extra: [
            .json(.patch, "/api/artifacts", #"{"artifact":{"id":"A1","slug":"pomo-1","title":"Pomodoro Timer","visibility":"public","icon":null},"message":"“Pomodoro Timer” is now public — anyone with the link can open it."}"#),
        ]))
        await model.load(filter: .file, query: "")
        let row = model.rows(matching: "pomo")[0]
        await model.setVisibility(row, to: .public, toasts: toasts)
        XCTAssertEqual(model.rows(matching: "pomo")[0].summary.visibility, .public)
        XCTAssertTrue(toasts.current?.message.contains("anyone with the link") == true)
    }

    func testARefusedChangeIsTakenBackWithTheServersSentence() async {
        let toasts = ToastCenter()
        let model = model(routes(extra: [.failure(.patch, "/api/artifacts", status: 503, message: "The database is missing artifact privacy.")]))
        await model.load(filter: .file, query: "")
        let row = model.rows(matching: "pomo")[0]
        await model.setVisibility(row, to: .public, toasts: toasts)
        XCTAssertEqual(model.rows(matching: "pomo")[0].summary.visibility, .private)
        XCTAssertEqual(toasts.current?.message, "The database is missing artifact privacy.")
        XCTAssertEqual(toasts.current?.style, .error)
    }

    func testDeletingAPageRemovesItAndAGroupGoesByItsOwnRoute() async {
        let toasts = ToastCenter()
        let hits = LibraryTestBox<[String]>([])
        let model = model(routes(extra: [
            MockRoute(.delete, "/api/artifact-groups/trip-1") { _ in
                hits.value.append("group")
                return HTTPResponse(status: 200, data: Data(#"{"deleted":{"slug":"trip-1"},"message":"Deleted."}"#.utf8))
            },
            MockRoute(.delete, "/api/artifacts") { _ in
                hits.value.append("page")
                return HTTPResponse(status: 200, data: Data(#"{"deleted":{"slug":"pomo-1","title":"P"},"message":"Deleted."}"#.utf8))
            },
        ]))
        await model.load(filter: .file, query: "")
        let group = model.rows(matching: "trip")[0]
        let removed = await model.delete(group, toasts: toasts)
        XCTAssertTrue(removed)
        XCTAssertEqual(hits.value, ["group"])
        XCTAssertEqual(model.rows(matching: "").map(\.summary.slug), ["pomo-1"])
        let page = model.rows(matching: "pomo")[0]
        _ = await model.delete(page, toasts: toasts)
        XCTAssertEqual(hits.value, ["group", "page"])
        XCTAssertEqual(model.rows(matching: ""), [])
    }

    func testADeleteTheServerRefusesPutsTheRowBack() async {
        let toasts = ToastCenter()
        let model = model(routes(extra: [.failure(.delete, "/api/artifacts", status: 404, message: "No artifact matching \"pomo-1\" in your vault.")]))
        await model.load(filter: .file, query: "")
        let removed = await model.delete(model.rows(matching: "pomo")[0], toasts: toasts)
        XCTAssertFalse(removed)
        XCTAssertEqual(model.rows(matching: "").count, 2)
        XCTAssertTrue(toasts.current?.message.contains("No artifact matching") == true)
    }

    func testLeavingAShareIsShownAtOnce() async {
        let toasts = ToastCenter()
        let model = model(routes(extra: [.json(.delete, "/api/shares", #"{"message":"Access removed."}"#)]))
        XCTAssertEqual(model.sharedWithYou, [])
        await model.leave(SharedWithYouItem(shareId: "s1", slug: "x", title: "Shared page", type: "html"), toasts: toasts)
        XCTAssertTrue(toasts.current?.message.contains("Shared page") == true)
    }

    func testTheOrderOfPinsFollowsTheDrag() async {
        let toasts = ToastCenter()
        let sent = LibraryTestBox<String?>(nil)
        let model = model(routes(extra: [
            MockRoute(.patch, "/api/sidebar-pins") { request in
                sent.value = request.httpBody.map { String(decoding: $0, as: UTF8.self) }
                return HTTPResponse(status: 200, data: Data(#"{"pins":[]}"#.utf8))
            },
        ]))
        await model.movePin(from: IndexSet(integer: 0), to: 1, toasts: toasts)
        XCTAssertNil(sent.value, "with nothing pinned there is nothing to move")
    }
}

/// A network that is never there.
struct LibraryOfflineTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        throw URLError(.notConnectedToInternet)
    }
}

/// A value a canned route can write to and a test can read.
final class LibraryTestBox<Value>: @unchecked Sendable {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}
