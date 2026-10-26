import HyperVaultKit
import XCTest
@testable import HyperVault

/// Answers the plain list at once and never answers a search; a search that is cancelled throws, as
/// URLSession does.
private actor SearchNeverAnswers: HTTPTransport {
    private let list: HTTPResponse
    private(set) var searches = 0

    init(list: String) {
        self.list = HTTPResponse(status: 200, headers: ["content-type": "application/json"], data: Data(list.utf8))
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        guard request.url?.query?.contains("q=") == true else { return list }
        searches += 1
        try await Task.sleep(nanoseconds: 60_000_000_000)
        return list
    }
}

/// What Yours shows while a person types in its search.
@MainActor
final class YoursModelTests: XCTestCase {
    private let list = #"{"recent":[],"results":[{"id":"m1","kind":"memory","name":"Trip notes","summary":"","updated_at":"2026-10-24T10:00:00Z","last_opened_at":null,"href":"/vault/memory?open=m1"}]}"#

    private func make(_ transport: SearchNeverAnswers) -> YoursModel {
        let client = HVClient(baseURL: URL(string: "https://hv.test")!, transport: transport, tokens: StaticTokenProvider(), retry: .none)
        let cache = DiskCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("hv-yours-\(UUID().uuidString)"))
        return YoursModel(client: client, cache: cache, namespace: "test")
    }

    /// Types a search, waits until its request is on the wire, and types again so that it is cancelled.
    private func typeThenTypeAgain(_ model: YoursModel, _ transport: SearchNeverAnswers) async {
        model.query = "tri"
        let search = Task { await model.reload() }
        for _ in 0..<300 {
            if await transport.searches == 1 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let onTheWire = await transport.searches
        XCTAssertEqual(onTheWire, 1)
        search.cancel()
        await search.value
    }

    func testASearchThatIsTypedOverDoesNotMarkTheListStale() async {
        let transport = SearchNeverAnswers(list: list)
        let model = make(transport)
        await model.reload()
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertFalse(model.isStale)

        await typeThenTypeAgain(model, transport)

        XCTAssertFalse(model.isStale, "a cancelled request is not a lost connection")
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(model.results.map(\.name), ["Trip notes"])
    }

    func testASearchThatIsTypedOverBeforeAnythingLoadedIsNotAnError() async {
        let transport = SearchNeverAnswers(list: list)
        let model = make(transport)

        await typeThenTypeAgain(model, transport)

        XCTAssertEqual(model.phase, .loading, "it was cancelled, not refused: the newer search is still to come")
    }
}
