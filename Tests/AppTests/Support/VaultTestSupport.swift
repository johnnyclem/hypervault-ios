import Foundation
import HyperVaultKit
@testable import HyperVault

/// A canned server for the Vault models: the six entries and three agent keys of the previews, with whatever routes a test
/// puts in front of them (the first route that matches answers), and the models built on it.
@MainActor
final class VaultWorld {
    let transport: MockTransport
    let announcer = RecordingAnnouncer()
    let client: HVClient
    let rest: AccountRest

    /// `wrapping` puts a transport of its own between the client and the canned server, to hold or refuse requests.
    init(extra: [MockRoute] = [], wrapping: ((MockTransport) -> HTTPTransport)? = nil) {
        let canned = MockTransport(routes: extra + VaultPreviewData.routes)
        transport = canned
        client = HVClient(
            baseURL: URL(string: "https://hv.test")!, transport: wrapping?(canned) ?? canned, tokens: StaticTokenProvider(), retry: .none
        )
        rest = AccountRest(client: client, anonKey: "test")
    }

    func list() -> VaultItemsModel {
        VaultItemsModel(client: client, rest: rest, userID: "u1", announcer: announcer)
    }

    func allowedKeys() -> VaultAllowedKeysModel {
        VaultAllowedKeysModel(client: client, rest: rest, userID: "u1", announcer: announcer)
    }

    /// The requests the server has seen, as `METHOD /path`.
    func seen() async -> [String] {
        await transport.requests.map { "\($0.httpMethod ?? "GET") \($0.url?.path ?? "")" }
    }
}

/// Holds every write until `open()`, so a test can look at a model while its request is on the wire.
actor HeldWrites: HTTPTransport {
    private let inner: HTTPTransport
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var held = 0

    init(inner: HTTPTransport) {
        self.inner = inner
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        if (request.httpMethod ?? "GET").uppercased() != "GET", !isOpen {
            held += 1
            await withCheckedContinuation { waiting.append($0) }
        }
        return try await inner.send(request)
    }

    /// Lets the held writes, and every later one, through.
    func open() {
        isOpen = true
        let all = waiting
        waiting = []
        for continuation in all { continuation.resume() }
    }
}

/// Serves the reads of one path at once but hands the answer back only on `open()`, once `hold()` has been called: the
/// answer is what the server said when it was asked, and a test can let a change happen before it arrives.
actor HeldReads: HTTPTransport {
    private let inner: HTTPTransport
    private let path: String
    private var holding = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var held = 0

    init(inner: HTTPTransport, path: String) {
        self.inner = inner
        self.path = path
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let answer = try await inner.send(request)
        if holding, (request.httpMethod ?? "GET").uppercased() == "GET", request.url?.path == path {
            held += 1
            await withCheckedContinuation { waiting.append($0) }
        }
        return answer
    }

    /// From here, the answers to reads of the path wait for `open()`.
    func hold() {
        holding = true
    }

    /// Hands back the answers that are waiting, and lets every later one through.
    func open() {
        holding = false
        let all = waiting
        waiting = []
        for continuation in all { continuation.resume() }
    }
}

/// Answers reads and fails every write the way a phone with no signal does.
struct OfflineWrites: HTTPTransport {
    let inner: HTTPTransport

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        if (request.httpMethod ?? "GET").uppercased() != "GET" { throw URLError(.notConnectedToInternet) }
        return try await inner.send(request)
    }
}

/// Every request fails the way a phone with no signal does.
struct NoSignal: HTTPTransport {
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        throw URLError(.notConnectedToInternet)
    }
}

/// Answers a route with each of `answers` in turn, and with the last one from then on.
final class Sequenced: @unchecked Sendable {
    private let lock = NSLock()
    private var next = 0
    private let answers: [HTTPResponse]

    init(_ answers: [HTTPResponse]) {
        self.answers = answers
    }

    var route: (HTTPMethod, String) -> MockRoute {
        { method, path in MockRoute(method, path) { _ in self.take() } }
    }

    private func take() -> HTTPResponse {
        lock.lock()
        defer { lock.unlock() }
        let answer = answers[min(next, answers.count - 1)]
        next += 1
        return answer
    }

    static func json(_ text: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["content-type": "application/json"], data: Data(text.utf8))
    }

    static func error(_ message: String, status: Int) -> HTTPResponse {
        json("{\"error\":\"\(message)\"}", status: status)
    }
}

/// Polls until `condition` holds or about three seconds pass.
@MainActor
func vaultEventually(_ condition: () async -> Bool) async -> Bool {
    for _ in 0..<300 {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return await condition()
}
