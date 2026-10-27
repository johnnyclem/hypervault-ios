import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HyperVaultKit

/// How a switch, a rename and a delete come out, classified by status and never by the server's words.
final class VaultOutcomesTests: XCTestCase {
    private let base = URL(string: "https://hv.test")!
    private let grants = "/api/secrets/github.com/grants"

    private func client(_ transport: any HTTPTransport, retry: RetryPolicy = .none) -> HVClient {
        HVClient(baseURL: base, transport: transport, tokens: StaticTokenProvider(), retry: retry, sleep: { _ in })
    }

    private let noGrants = #"{"grants":[]}"#
    private let oneGrant = #"{"grants":[{"id":"g1","api_key_id":"k1","created_at":"2026-10-24T10:00:00Z"}]}"#

    // MARK: Allowing

    func testAnAllowThatTheServerAcceptsIsApplied() async {
        let transport = MockTransport(routes: [
            .json(.post, grants, #"{"grant":{"id":"g2","api_key_id":"k2","created_at":"2026-10-24T10:01:00Z"}}"#),
        ])
        let outcome = await client(transport).setSecretGrant(name: "github.com", keyID: "k2", allowed: true)
        XCTAssertEqual(outcome, .applied)
        let requests = await transport.requests(matching: grants)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.httpMethod, "POST")
        XCTAssertEqual(requestJSON(requests.first), .object(["api_key_id": .string("k2")]))
    }

    func testASlimOrDifferentSuccessBodyStillCountsAsAnAllow() async throws {
        for body in [#"{"ok":true}"#, "{}", "", "null", #"{"grant":null}"#, #"{"grant":{"id":7}}"#, "not json", "[]"] {
            let transport = MockTransport(routes: [.json(.post, grants, body, status: 201)])
            let outcome = await client(transport).setSecretGrant(name: "github.com", keyID: "k2", allowed: true)
            XCTAssertEqual(outcome, .applied, body)
        }
    }

    func testGrantSecretDecodesLeniently() async throws {
        let slim = MockTransport(routes: [.json(.post, grants, #"{"ok":true}"#)])
        let granted = try await client(slim).send(.grantSecret(name: "github.com", keyID: "k2"))
        XCTAssertEqual(granted.grant.apiKeyId, "k2")
        XCTAssertEqual(granted.grant.id, "")
        let full = MockTransport(routes: [.json(.post, grants, #"{"grant":{"id":"g2","api_key_id":"k9","created_at":"2026-10-24T10:01:00Z"}}"#)])
        let whole = try await client(full).send(.grantSecret(name: "github.com", keyID: "k2"))
        XCTAssertEqual(whole.grant.id, "g2")
        XCTAssertEqual(whole.grant.apiKeyId, "k9")
        XCTAssertNotNil(whole.grant.createdAt)
    }

    func testAnAllowIsRepeatedOnABusyServerAndARevokeIsNot() async {
        XCTAssertTrue(Endpoint<SecretGrantResponse>.grantSecret(name: "n", keyID: "k").idempotent)
        XCTAssertFalse(Endpoint<NoContent>.revokeSecretGrant(name: "n", keyID: "k").idempotent)

        let retry = RetryPolicy(maxAttempts: 3, baseDelay: 0, maxDelay: 0)
        let calls = VaultOutcomesCallCount()
        let busy = MockTransport(routes: [
            MockRoute(.post, grants) { _ in
                calls.bump()
                return calls.value == 1
                    ? HTTPResponse(status: 503, headers: ["content-type": "application/json"], data: Data(#"{"error":"busy"}"#.utf8))
                    : HTTPResponse(status: 200, headers: ["content-type": "application/json"], data: Data(#"{"ok":true}"#.utf8))
            },
        ])
        let allowed = await client(busy, retry: retry).setSecretGrant(name: "github.com", keyID: "k2", allowed: true)
        XCTAssertEqual(allowed, .applied)
        XCTAssertEqual(calls.value, 2)

        let revokeCalls = VaultOutcomesCallCount()
        let alsoBusy = MockTransport(routes: [
            MockRoute(.delete, grants) { _ in
                revokeCalls.bump()
                return HTTPResponse(status: 503, headers: ["content-type": "application/json"], data: Data(#"{"error":"busy"}"#.utf8))
            },
        ])
        let revoked = await client(alsoBusy, retry: retry).setSecretGrant(name: "github.com", keyID: "k2", allowed: false)
        XCTAssertEqual(revokeCalls.value, 1)
        XCTAssertEqual(revoked, .failure(VaultFailure(message: "busy", status: 503)))
    }

    // MARK: Revoking

    func testARevokeThatTheServerAcceptsIsApplied() async {
        let transport = MockTransport(routes: [.json(.delete, grants, #"{"ok":true}"#)])
        let outcome = await client(transport).setSecretGrant(name: "github.com", keyID: "k2", allowed: false)
        XCTAssertEqual(outcome, .applied)
        let requests = await transport.requests(matching: grants)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.httpMethod, "DELETE")
        XCTAssertEqual(requestJSON(requests.first), .object(["api_key_id": .string("k2")]))
    }

    func testARevokeWithNoGrantIsAlreadyOffAndShowsNothing() async {
        let transport = MockTransport(routes: [
            .failure(.delete, grants, status: 404, message: "No such grant."),
            .json(.get, grants, noGrants),
        ])
        let outcome = await client(transport).setSecretGrant(name: "github.com", keyID: "k2", allowed: false)
        XCTAssertEqual(outcome, .alreadyOff)
        // The grants were read to tell the 404s apart, once, and the revoke was sent once.
        let requests = await transport.requests(matching: grants)
        XCTAssertEqual(requests.map { $0.httpMethod ?? "" }, ["DELETE", "GET"])
    }

    func testARevokeOnAGoneEntryIsEntryGone() async {
        let transport = MockTransport(routes: [
            .failure(.delete, grants, status: 404, message: "No such secret."),
            .failure(.get, grants, status: 404, message: "No such secret."),
        ])
        let outcome = await client(transport).setSecretGrant(name: "github.com", keyID: "k2", allowed: false)
        XCTAssertEqual(outcome, .entryGone)
    }

    func testTheClassificationReadsTheStatusAndNeverTheWords() async {
        // Words that point the wrong way: the revoke says "No such secret." but the entry is there, and the other
        // way round. Only the second 404 decides.
        let there = MockTransport(routes: [
            .failure(.delete, grants, status: 404, message: "No such secret."),
            .json(.get, grants, oneGrant),
        ])
        let a = await client(there).setSecretGrant(name: "github.com", keyID: "k1", allowed: false)
        XCTAssertEqual(a, .alreadyOff)
        let gone = MockTransport(routes: [
            .failure(.delete, grants, status: 404, message: "No such grant."),
            .failure(.get, grants, status: 404, message: "Not found."),
        ])
        let b = await client(gone).setSecretGrant(name: "github.com", keyID: "k1", allowed: false)
        XCTAssertEqual(b, .entryGone)
        let bare = MockTransport(routes: [MockRoute(.delete, grants) { _ in HTTPResponse(status: 404) }, .json(.get, grants, noGrants)])
        let c = await client(bare).setSecretGrant(name: "github.com", keyID: "k1", allowed: false)
        XCTAssertEqual(c, .alreadyOff)
    }

    // MARK: Allowing a key that is gone

    func testAnAllowForAMissingKeyIsKeyGone() async {
        let transport = MockTransport(routes: [
            .failure(.post, grants, status: 404, message: "No such API key."),
            .json(.get, grants, noGrants),
        ])
        let outcome = await client(transport).setSecretGrant(name: "github.com", keyID: "k2", allowed: true)
        XCTAssertEqual(outcome, .keyGone)
    }

    func testAnAllowOnAGoneEntryIsEntryGone() async {
        let transport = MockTransport(routes: [
            .failure(.post, grants, status: 404, message: "No such secret."),
            .failure(.get, grants, status: 404, message: "No such secret."),
        ])
        let outcome = await client(transport).setSecretGrant(name: "github.com", keyID: "k2", allowed: true)
        XCTAssertEqual(outcome, .entryGone)
    }

    // MARK: Failures

    func testAFailureCarriesWordsThatAreSafeToShow() async {
        let refused = MockTransport(routes: [.failure(.post, grants, status: 403, message: "API keys cannot manage grants \u{2014} use a signed-in session.")])
        let a = await client(refused).setSecretGrant(name: "github.com", keyID: "k2", allowed: true)
        XCTAssertEqual(a, .failure(VaultFailure(message: "API keys cannot manage grants \u{2014} use a signed-in session.", status: 403)))

        let limited = MockTransport(routes: [.failure(.delete, grants, status: 429, message: "Rate limit exceeded \u{2014} slow down a little.")])
        let b = await client(limited).setSecretGrant(name: "github.com", keyID: "k2", allowed: false)
        XCTAssertEqual(b, .failure(VaultFailure(message: "Rate limit exceeded \u{2014} slow down a little.", status: 429)))
    }

    func testNoSuchGrantNeverComesOutOfAFailure() async {
        // A status that is not a 404 with that sentence: it is not shown either.
        let transport = MockTransport(routes: [.failure(.delete, grants, status: 400, message: "No such grant.")])
        let outcome = await client(transport).setSecretGrant(name: "github.com", keyID: "k2", allowed: false)
        XCTAssertEqual(outcome, .failure(VaultFailure(message: VaultCopy.keyChangeFailedLine, status: 400)))
    }

    func testOfflineIsTheProductsLine() async {
        let outcome = await client(VaultOutcomesOfflineTransport()).setSecretGrant(name: "github.com", keyID: "k2", allowed: true)
        XCTAssertEqual(outcome, .failure(VaultFailure(message: "Network hiccup. That did not go through. Try again.", status: nil)))
        let load = await client(VaultOutcomesOfflineTransport()).loadSecretGrants(name: "github.com")
        XCTAssertEqual(load, .failure(VaultFailure(message: "Network hiccup. That did not load. Try again.", status: nil)))
    }

    func testAFailedReloadAfterA404IsAFailureAndNotAGuess() async {
        let transport = MockTransport(routes: [
            .failure(.delete, grants, status: 404, message: "No such grant."),
            .failure(.get, grants, status: 500, message: "database is down"),
        ])
        let outcome = await client(transport).setSecretGrant(name: "github.com", keyID: "k2", allowed: false)
        XCTAssertEqual(outcome, .failure(VaultFailure(message: "database is down", status: 500)))
    }

    func testASignedOutPersonIsToldSo() async {
        let signedOut = HVClient(baseURL: base, transport: MockTransport(), tokens: StaticTokenProvider(nil), retry: .none, sleep: { _ in })
        let outcome = await signedOut.setSecretGrant(name: "github.com", keyID: "k2", allowed: true)
        XCTAssertEqual(outcome, .failure(VaultFailure(message: "Your session ended. Sign in again.", status: 401)))
    }

    // MARK: Reading the grants

    func testLoadingTheGrants() async {
        let transport = MockTransport(routes: [.json(.get, grants, #"{"grants":[{"id":"g1","api_key_id":"k1"},{"id":"g2","api_key_id":"k2"}]}"#)])
        let load = await client(transport).loadSecretGrants(name: "github.com")
        XCTAssertEqual(load, .loaded(["k1", "k2"]))
        let none = await client(MockTransport(routes: [.json(.get, grants, noGrants)])).loadSecretGrants(name: "github.com")
        XCTAssertEqual(none, .loaded([]))
    }

    func testA404WhileLoadingTheGrantsIsAGoneEntry() async {
        let transport = MockTransport(routes: [.failure(.get, grants, status: 404, message: "No such secret.")])
        let load = await client(transport).loadSecretGrants(name: "github.com")
        XCTAssertEqual(load, .entryGone)
    }

    func testAnotherFailureWhileLoadingTheGrantsIsAFailureInTheLoadWords() async {
        let transport = MockTransport(routes: [.failure(.get, grants, status: 500, message: "database is down")])
        let load = await client(transport).loadSecretGrants(name: "github.com")
        XCTAssertEqual(load, .failure(VaultFailure(message: "database is down", status: 500)))
    }

    // MARK: Renaming and deleting

    private let row = #"{"secret":{"id":"a1","name":"gh","kind":"login","description":null,"created_at":"2026-10-20T10:00:00Z","updated_at":"2026-10-24T10:00:00Z","last_accessed_at":null,"hint":"jane"}}"#

    func testARenameComesBackAsTheNewRow() async {
        let transport = MockTransport(routes: [.json(.patch, "/api/secrets/github.com", row)])
        let outcome = await client(transport).changeVaultSecret(name: "github.com", newName: "gh")
        guard case .updated(let secret) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(secret.name, "gh")
        XCTAssertEqual(secret.hint, "jane")
    }

    func testARenameOfAGoneEntryIsEntryGone() async {
        let transport = MockTransport(routes: [.failure(.patch, "/api/secrets/github.com", status: 404, message: "No such secret.")])
        let outcome = await client(transport).changeVaultSecret(name: "github.com", newName: "gh")
        XCTAssertEqual(outcome, .entryGone)
    }

    func testANameInUseIsAConflictWithTheServersSentence() async {
        let transport = MockTransport(routes: [.failure(.patch, "/api/secrets/github.com", status: 409, message: "A secret with that name already exists.")])
        let outcome = await client(transport).changeVaultSecret(name: "github.com", newName: "gh")
        guard case .failure(let failure) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(failure.isConflict)
        XCTAssertEqual(failure.message, "A secret with that name already exists.")
        let changed = MockTransport(routes: [.failure(.patch, "/api/secrets/github.com", status: 409, message: "This secret changed while you were saving it. Try again.")])
        let again = await client(changed).changeVaultSecret(name: "github.com", description: "x")
        XCTAssertEqual(again, .failure(VaultFailure(message: "This secret changed while you were saving it. Try again.", status: 409)))
    }

    func testADeleteIsDeletedOrGone() async {
        let ok = MockTransport(routes: [.json(.delete, "/api/secrets/github.com", #"{"ok":true,"deleted":"github.com"}"#)])
        let deleted = await client(ok).removeVaultSecret(name: "github.com")
        XCTAssertEqual(deleted, .deleted)
        let gone = MockTransport(routes: [.failure(.delete, "/api/secrets/github.com", status: 404, message: "No such secret.")])
        let alreadyGone = await client(gone).removeVaultSecret(name: "github.com")
        XCTAssertEqual(alreadyGone, .entryGone)
        let refused = MockTransport(routes: [.failure(.delete, "/api/secrets/github.com", status: 500, message: "database is down")])
        let failed = await client(refused).removeVaultSecret(name: "github.com")
        XCTAssertEqual(failed, .failure(VaultFailure(message: "database is down", status: 500)))
    }

    // MARK: Names that cannot be addressed

    func testADotNameIsNeverSentAsAPathSegment() async {
        let transport = MockTransport(routes: [MockRoute(nil, "/*") { _ in HTTPResponse(status: 200, data: Data("{}".utf8)) }])
        let hv = client(transport)
        let refused = VaultFailure(message: "That request was not accepted.", status: nil)
        for name in [".", "..", "%2e", "%2E%2e", ".%2e", "%2e."] {
            let delete = await hv.removeVaultSecret(name: name)
            XCTAssertEqual(delete, .failure(refused), name)
            let change = await hv.changeVaultSecret(name: name, newName: "x")
            XCTAssertEqual(change, .failure(refused), name)
            let revoke = await hv.setSecretGrant(name: name, keyID: "k", allowed: false)
            XCTAssertEqual(revoke, .failure(refused), name)
            let allow = await hv.setSecretGrant(name: name, keyID: "k", allowed: true)
            XCTAssertEqual(allow, .failure(refused), name)
            let load = await hv.loadSecretGrants(name: name)
            XCTAssertEqual(load, .failure(refused), name)
        }
        let sent = await transport.requests
        XCTAssertTrue(sent.isEmpty, "\(sent.count) requests reached the network")
    }

    func testNamesWithDotsInThemAreSentAsTheyAre() async {
        for name in ["a.b", "...", "..a", "a..", ".a", "a.", "github.com"] {
            let transport = MockTransport(routes: [.json(.delete, "/api/secrets/\(name)", #"{"ok":true}"#)])
            let outcome = await client(transport).removeVaultSecret(name: name)
            XCTAssertEqual(outcome, .deleted, name)
        }
    }

    func testTheDotSegmentRule() {
        XCTAssertTrue(HVClient.hasDotSegment("/api/secrets/.."))
        XCTAssertTrue(HVClient.hasDotSegment("/api/secrets/./grants"))
        XCTAssertTrue(HVClient.hasDotSegment("/api/secrets/%2E%2E/grants"))
        XCTAssertFalse(HVClient.hasDotSegment("/api/secrets/a.b/grants"))
        XCTAssertFalse(HVClient.hasDotSegment("/api/secrets/..a"))
        XCTAssertFalse(HVClient.hasDotSegment("/api/secrets/..."))
        XCTAssertFalse(HVClient.hasDotSegment("/api/artifacts/slug/files/styles/app.css"))
        XCTAssertFalse(HVClient.hasDotSegment("/"))
        XCTAssertFalse(HVClient.hasDotSegment(""))
    }
}

private final class VaultOutcomesCallCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func bump() { lock.lock(); count += 1; lock.unlock() }
}

private struct VaultOutcomesOfflineTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        throw URLError(.notConnectedToInternet)
    }
}
