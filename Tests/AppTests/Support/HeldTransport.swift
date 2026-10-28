import Foundation
import HyperVaultKit
@testable import HyperVault

/// Holds answers back once armed, until released, so a test can act while a request is out.
actor RequestHold {
    private var armed = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// How many requests are being held.
    var waiting: Int { waiters.count }

    func arm() { armed = true }

    func pass() async {
        guard armed else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        armed = false
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

/// A network that holds back the requests `holds` picks out, and answers the rest from `base` at once.
struct HeldTransport: HTTPTransport {
    let base: MockTransport
    let hold: RequestHold
    let holds: @Sendable (URLRequest) -> Bool

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        if holds(request) { await hold.pass() }
        return try await base.send(request)
    }
}
