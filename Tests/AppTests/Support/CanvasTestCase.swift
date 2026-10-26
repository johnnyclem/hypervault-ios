import HyperVaultKit
import XCTest
@testable import HyperVault

/// Every request fails the way a phone with no signal does.
struct OfflineTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        throw URLError(.notConnectedToInternet)
    }
}

/// Answers from `inner` while online and fails like a phone with no signal while not.
actor Flaky: HTTPTransport {
    private let inner: MockTransport
    private var online = true

    init(inner: MockTransport) { self.inner = inner }

    func setOnline(_ value: Bool) { online = value }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        guard online else { throw URLError(.notConnectedToInternet) }
        return try await inner.send(request)
    }
}

/// Answers the first request it gets and then never answers; it throws when its task is cancelled,
/// as URLSession does.
actor ServedOnce: HTTPTransport {
    private let first: HTTPResponse
    private var served = false
    private(set) var waiting = 0

    init(first: String) {
        self.first = HTTPResponse(status: 200, headers: ["content-type": "application/json"], data: Data(first.utf8))
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        if !served {
            served = true
            return first
        }
        waiting += 1
        try await Task.sleep(nanoseconds: 60_000_000_000)
        return first
    }
}

/// What the canvas model tests share: a model on canned routes, and a way to wait for the requests
/// the model fires and forgets. The subclasses are `@MainActor`, as the model is.
class CanvasTestCase: XCTestCase {
    let origin = URL(string: "https://hypervault.store")!
    let baseURL = URL(string: "https://hv.test")!

    let oneModel = #"{"backends":[{"id":"b1","name":"My Claude","provider":"anthropic","default_model":"claude-opus"}]}"#
    let noModel = #"{"backends":[]}"#
    let reply = #"{"conversation_id":"c1","reply":{"id":"r1","role":"assistant","content":"Here you go.","truncated":false},"pulled":[]}"#
    let kept = #"{"slug":"here-you-go-1","url":"https://hypervault.store/a/here-you-go-1","kind":"page","form":"note","title":"Here you go.","visibility":"private","duplicate":false,"message":"Kept. Here's the link."}"#
    let memory = #"{"id":"m1","kind":"memory","name":"Trip notes","href":"/vault/memory?open=m1"}"#
    let tripList = #"{"recent":[],"results":[{"id":"m1","kind":"memory","name":"Trip notes","summary":"","updated_at":"2026-10-24T10:00:00Z","last_opened_at":null,"href":"/vault/memory?open=m1"}]}"#

    func client(_ transport: HTTPTransport) -> HVClient {
        HVClient(baseURL: baseURL, transport: transport, tokens: StaticTokenProvider(), retry: .none)
    }

    @MainActor
    func make(_ routes: [MockRoute]) -> (model: CanvasModel, transport: MockTransport) {
        let transport = MockTransport(routes: routes)
        return (CanvasModel(client: client(transport), origin: origin), transport)
    }

    /// Waits for something that happens off to the side, such as a request fired and forgotten.
    func eventually(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<300 {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await condition()
    }

    func body(of request: URLRequest?) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: request?.httpBody ?? Data()) as? [String: Any])
    }

    /// A long, plain paste: the kind of thing that waits above the field.
    var aPaste: String { Array(repeating: "Handoffs on Wednesday and every other weekend.", count: 12).joined(separator: " ") }
}
