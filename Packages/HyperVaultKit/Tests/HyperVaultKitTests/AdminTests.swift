import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HyperVaultKit

/// app/api/admin/**: every route is write-only, and guarded by `requireAdmin()`.
final class AdminTests: XCTestCase {
    let base = URL(string: "https://hv.test")!

    func client(_ transport: MockTransport) -> HVClient {
        HVClient(baseURL: base, transport: transport, tokens: FakeTokens(token: "t"), retry: RetryPolicy(maxAttempts: 2), sleep: { _ in })
    }

    // app/api/admin/invites/route.ts: `.insert(...).select().single()` returns the whole row.
    let inviteJSON = #"{"invite":{"id":"3f1c1a2e-0000-4000-8000-000000000001","code":"HV-K7QM-2XPA","note":"Twitter launch batch","max_uses":5,"use_count":2,"disabled":false,"created_by":"u1","created_at":"2026-10-24T01:02:03.123456+00:00"}}"#

    func testInviteRowDecodesAndReadsLikeTheWebTable() throws {
        let answer = try HVCoding.decoder().decode(AdminInviteEnvelope.self, from: Data(inviteJSON.utf8))
        let invite = answer.invite
        XCTAssertEqual(invite.code, "HV-K7QM-2XPA")
        XCTAssertEqual(invite.maxUses, 5)
        XCTAssertEqual(invite.useCount, 2)
        XCTAssertEqual(invite.remaining, 3)
        XCTAssertEqual(invite.status, .active)
        XCTAssertNotNil(invite.createdAt)

        var used = invite
        used.useCount = 5
        XCTAssertEqual(used.status, .usedUp)
        used.disabled = true
        XCTAssertEqual(used.status, .disabled, "disabled wins over used up")
    }

    func testTheLinkFillsInTheCode() throws {
        let invite = AdminInvite(id: "1", code: "HV-K7QM-2XPA")
        XCTAssertEqual(invite.shareURL(server: base).absoluteString, "https://hv.test/login?invite=HV-K7QM-2XPA")
    }

    func testTheBookKeepsNewestFirstAndReplacesInPlace() throws {
        var book = AdminInviteBook()
        let older = AdminInvite(id: "a", code: "HV-AAAA-AAAA", createdAt: Date(timeIntervalSince1970: 1_000))
        let newer = AdminInvite(id: "b", code: "HV-BBBB-BBBB", createdAt: Date(timeIntervalSince1970: 2_000))
        book.upsert(older)
        book.upsert(newer)
        XCTAssertEqual(book.invites.map(\.id), ["b", "a"])
        var changed = older
        changed.useCount = 1
        book.upsert(changed)
        XCTAssertEqual(book.invites.count, 2)
        XCTAssertEqual(book.invites.last?.useCount, 1)
        book.remove(id: "b")
        XCTAssertEqual(book.invites.map(\.id), ["a"])

        // It is cached with the generic cache, so it must survive the round trip.
        let data = try HVCoding.encoder(.verbatim).encode(book)
        let again = try HVCoding.decoder(.verbatim).decode(AdminInviteBook.self, from: data)
        XCTAssertEqual(again, book)
    }

    func testCreateWritesCamelCaseKeysAndClampsTheUses() async throws {
        let transport = MockTransport(routes: [.json(.post, "/api/admin/invites", inviteJSON)])
        let api = client(transport)
        _ = try await api.send(.createInvite(maxUses: 99_999, note: "  Twitter launch batch  "))
        _ = try await api.send(.createInvite(maxUses: 0, note: "   "))
        let sent = await transport.requests
        let first = try JSONDecoder().decode(JSONValue.self, from: sent[0].httpBody ?? Data())
        XCTAssertEqual(first["maxUses"]?.int, 10_000)
        XCTAssertEqual(first["note"]?.string, "Twitter launch batch")
        let second = try JSONDecoder().decode(JSONValue.self, from: sent[1].httpBody ?? Data())
        XCTAssertEqual(second["maxUses"]?.int, 1)
        XCTAssertNil(second["note"])
    }

    func testDisableDeleteAndTheirSentences() async throws {
        let transport = MockTransport(routes: [
            .json(.patch, "/api/admin/invites/abc", inviteJSON),
            .json(.delete, "/api/admin/invites/abc", #"{"ok":true}"#),
            .failure(.patch, "/api/admin/invites/zzz", status: 404, message: "No such invite code."),
            .failure(.delete, "/api/admin/invites/def", status: 503, message: "The database is missing the invite tables."),
        ])
        let api = client(transport)
        let row = try await api.send(.setInvite(id: "abc", disabled: true))
        XCTAssertEqual(row.invite.code, "HV-K7QM-2XPA")
        let sent = await transport.requests
        XCTAssertEqual(String(decoding: sent[0].httpBody ?? Data(), as: UTF8.self), #"{"disabled":true}"#)
        let ack = try await api.send(.deleteInvite(id: "abc"))
        XCTAssertEqual(ack.ok, true)

        do {
            _ = try await api.send(.setInvite(id: "zzz", disabled: false))
            XCTFail("expected 404")
        } catch let error as HVError {
            XCTAssertEqual(error.userMessage, "No such invite code.")
        }
        do {
            _ = try await api.send(.deleteInvite(id: "def"))
            XCTFail("expected 503")
        } catch let error as HVError {
            XCTAssertTrue(error.isUnavailable)
        }
    }

    func testAccountChangesUseTheRoutesKeys() async throws {
        XCTAssertEqual(AdminAccountChange.plan(.pro).body, .object(["plan": "pro"]))
        XCTAssertEqual(AdminAccountChange.approve.body, .object(["approved": true]))
        XCTAssertEqual(AdminAccountChange.revoke.body, .object(["approved": false]))
        XCTAssertEqual(AdminAccountChange.displayName("  Sam  ").body, .object(["displayName": "Sam"]))
        XCTAssertEqual(AdminAccountChange.displayName(String(repeating: "x", count: 200)).body["displayName"]?.string?.count, 80)

        let transport = MockTransport(routes: [
            .json(.patch, "/api/admin/accounts/*", #"{"ok":true}"#),
            .json(.delete, "/api/admin/accounts/*", #"{"ok":true}"#),
            .json(.delete, "/api/admin/waitlist/*", #"{"ok":true}"#),
        ])
        let api = client(transport)
        _ = try await api.send(.changeAccount(id: "u1", .plan(.free)))
        _ = try await api.send(.deleteAccount(id: "u1"))
        _ = try await api.send(.dropFromWaitlist(id: "u2"))
        let sent = await transport.requests
        XCTAssertEqual(sent.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" }, [
            "PATCH /api/admin/accounts/u1", "DELETE /api/admin/accounts/u1", "DELETE /api/admin/waitlist/u2",
        ])
    }

    func testTheServerRefusesSelfHarmInItsOwnWords() async {
        let transport = MockTransport(routes: [
            .failure(.delete, "/api/admin/accounts/me", status: 400, message: "You can't delete your own admin account here."),
            .failure(.patch, "/api/admin/accounts/me", status: 400, message: "You can't revoke your own access."),
        ])
        let api = client(transport)
        do {
            _ = try await api.send(.deleteAccount(id: "me"))
            XCTFail("expected 400")
        } catch let error as HVError {
            XCTAssertEqual(error.userMessage, "You can't delete your own admin account here.")
        } catch {
            XCTFail("wrong error \(error)")
        }
    }

    func testPastedAccountIDs() {
        XCTAssertEqual(AdminAccountID.parse(" \"3F1C1A2E-0000-4000-8000-000000000001\", "), "3f1c1a2e-0000-4000-8000-000000000001")
        XCTAssertNil(AdminAccountID.parse("sam@example.com"))
        XCTAssertNil(AdminAccountID.parse("3f1c1a2e"))
        XCTAssertNil(AdminAccountID.parse(""))
    }

    // MARK: The probe

    func testWhatEachAnswerToTheProbeMeans() {
        XCTAssertEqual(AdminProbe.verdict(status: 400), .admin, "the guard let an admin through to the body check")
        XCTAssertEqual(AdminProbe.verdict(status: 403), .notAdmin)
        XCTAssertEqual(AdminProbe.verdict(status: 401), .unknown, "a route that only reads the web cookie says nothing about the person")
        XCTAssertEqual(AdminProbe.verdict(status: 500), .unknown)
        XCTAssertEqual(AdminProbe.verdict(status: 503), .admin)
        XCTAssertEqual(AdminProbe.verdict(status: 204), .admin)
        XCTAssertEqual(AdminProbe.verdict(status: nil), .unknown)
    }

    func testTheLastAnswerIsRememberedForAWhile() throws {
        let now = Date()
        let admin = AdminProbeRecord(.admin, at: now.addingTimeInterval(-3_600))
        XCTAssertTrue(admin.isFresh(now: now))
        XCTAssertEqual(admin.isAdmin, true)
        XCTAssertFalse(AdminProbeRecord(.notAdmin, at: now.addingTimeInterval(-7 * 3_600)).isFresh(now: now))
        let unclear = AdminProbeRecord(.unknown, at: now.addingTimeInterval(-300))
        XCTAssertTrue(unclear.isFresh(now: now), "an unclear answer is not asked again at once")
        XCTAssertFalse(AdminProbeRecord(.unknown, at: now.addingTimeInterval(-700)).isFresh(now: now))
        XCTAssertNil(unclear.isAdmin)

        let data = try HVCoding.encoder(.verbatim).encode(admin)
        XCTAssertEqual(try HVCoding.decoder(.verbatim).decode(AdminProbeRecord.self, from: data).answer, .admin)
    }

    func testTheProbeNeverWrites() async throws {
        // Asked of the real route's three answers.
        let admin = MockTransport(routes: [.failure(.patch, "/api/admin/invites/*", status: 400, message: "Pass { disabled: boolean }.")])
        let other = MockTransport(routes: [.failure(.patch, "/api/admin/invites/*", status: 403, message: "Admin access required.")])
        for (transport, expected) in [(admin, AdminProbe.Verdict.admin), (other, .notAdmin)] {
            do {
                _ = try await client(transport).send(.adminProbe)
                XCTFail("the probe's empty body is always refused")
            } catch let error as HVError {
                XCTAssertEqual(AdminProbe.verdict(status: error.status), expected)
            }
            let sent = await transport.requests
            XCTAssertEqual(sent.count, 1)
            XCTAssertEqual(sent[0].httpMethod, "PATCH")
            XCTAssertEqual(sent[0].url?.path, "/api/admin/invites/\(AdminProbe.probeID)")
            XCTAssertEqual(String(decoding: sent[0].httpBody ?? Data(), as: UTF8.self), "{}", "no field that could change a row")
        }
    }
}
