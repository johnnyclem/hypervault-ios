import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HyperVaultKit

// The refusals the app special-cases that the journeys elsewhere do not reach by accident: 412 (a strict
// If-Match), 413 on the three ways to store a page, and 429 from the two meters the server keeps (a signed-in
// person at 120 calls a minute, an agent key at 60). Setup is in LocalServerE2ETests.swift.

/// Records the waits the client asked for instead of making them.
actor LocalSleepLog {
    private(set) var waits: [TimeInterval] = []
    func record(_ seconds: TimeInterval) { waits.append(seconds) }
}

final class LocalE2EStatusTests: LocalE2ECase {

    private func html(_ marker: String, _ body: String = "", footer: String = "end") -> String {
        "<!doctype html>\n<html>\n<head><title>Page \(marker)</title></head>\n<body>\n<h1>\(marker)</h1>\n<p>\(body)</p>\n<hr>\n<hr>\n<hr>\n<hr>\n<hr>\n<footer>\(footer)</footer>\n</body>\n</html>\n"
    }

    /// A call with no pacing, for the tests that want to run into a meter.
    private func unpaced(_ token: String, retry: RetryPolicy = .none, sleep: (@Sendable (TimeInterval) async -> Void)? = nil) -> HVClient {
        if let sleep {
            return HVClient(baseURL: env.server.baseURL, transport: URLSessionTransport(), tokens: LocalStaticToken(token: token), retry: retry, sleep: sleep)
        }
        return HVClient(baseURL: env.server.baseURL, transport: URLSessionTransport(), tokens: LocalStaticToken(token: token), retry: retry)
    }

    // MARK: 412

    func testAStrictIfMatchIsRefusedWith412AndTheHeadAndWritesNothing() async throws {
        let (api, _) = member(18)
        let marker = uniqueWord()
        let saved = try await send(.saveArtifact(ArtifactSaveRequest(content: html(marker, "alpha"), title: "Strict \(marker)", makePwa: false, mutable: true)), api)
        let slug = saved.slug
        let first = try await send(.artifactContent(slug: slug), api)
        let v1 = try XCTUnwrap(first.headVersionId)
        let second = try await send(.writeArtifact(slug: slug, ArtifactWriteRequest(content: html(marker, "beta"), message: "second", baseVersionId: v1)), api)
        let v2 = try XCTUnwrap(second.headVersionId)
        XCTAssertNotEqual(v1, v2)

        // The read names the head in its ETag, for a client that prefers If-Match to a base id in the body.
        let read = try await api.sendRaw(.artifactContent(slug: slug))
        let etag = try XCTUnwrap(read.header("etag"), "the content read sent no ETag")
        XCTAssertTrue(etag.contains(v2), "the ETag \(etag) does not name the head \(v2)")

        func strictWrite(_ body: String, ifMatch: String) -> Endpoint<ArtifactWriteResult> {
            Endpoint(.put, "/api/artifacts/\(slug)/content", body: .json(ArtifactWriteRequest(content: html(marker, body), message: "strict")), headers: ["If-Match": ifMatch])
        }

        // An older head as the tag: refused, with the head and its content, and no replay even though the change
        // would have merged cleanly.
        let stale = await expectFailure(412, strictWrite("gamma", ifMatch: v1), api)
        let conflict = try XCTUnwrap(stale.flatMap(ArtifactConflict.init(failure:)), "a 412 did not come back as a conflict the Kit can read: \(String(describing: stale?.body))")
        XCTAssertEqual(conflict.status, 412)
        XCTAssertEqual(conflict.reason, .preconditionFailed)
        XCTAssertEqual(conflict.headVersionId, v2)
        XCTAssertTrue(conflict.headContent.contains("beta"), "the refusal does not show what is there now")
        let afterRefusal = try await send(.artifactVersions(slug: slug), api)
        XCTAssertEqual(afterRefusal.versions.count, 2, "a refused strict write left a commit")
        let stillBeta = try await send(.artifactContent(slug: slug), api)
        XCTAssertTrue(stillBeta.content.contains("beta"))
        XCTAssertFalse(stillBeta.content.contains("gamma"))

        // A tag that names nothing the page ever had is refused the same way.
        let nonsense = await expectFailure(412, strictWrite("gamma", ifMatch: "\"00000000-0000-4000-8000-000000000000\""), api)
        XCTAssertEqual(nonsense.flatMap(ArtifactConflict.init(failure:))?.reason, .preconditionFailed)

        // The tag the read sent, quoted as it came, is the head: the write lands and the new ETag moves on.
        let landed = try await api.sendRaw(strictWrite("delta", ifMatch: etag))
        let result = try HVCoding.decoder().decode(ArtifactWriteResult.self, from: landed.data)
        let v3 = try XCTUnwrap(result.headVersionId)
        XCTAssertNotEqual(v3, v2)
        XCTAssertFalse(result.rebased)
        XCTAssertTrue(try XCTUnwrap(landed.header("etag")).contains(v3), "the write's ETag does not name the commit it made")
        let afterLanding = try await send(.artifactVersions(slug: slug), api)
        XCTAssertEqual(afterLanding.versions.count, 3)
        XCTAssertEqual(afterLanding.versions.first?.id, v3)

        // And the one that was the head a moment ago is now stale.
        await expectFailure(412, strictWrite("epsilon", ifMatch: etag), api)
        report("412", [("versions", afterLanding.versions.count)])
    }

    // MARK: 413

    func testAPageOverTheLimitIs413OnSaveKeepAndWriteAndOneAtTheLimitIsAccepted() async throws {
        let (api, _) = member(21)
        let caps = try await send(.capabilities, api)
        let limit = caps.limits.artifactBytes
        XCTAssertEqual(limit, 1_000_000, "the limit capabilities advertise is not the one the routes enforce")

        let marker = uniqueWord()
        let head = "<!doctype html><html><head><title>Big \(marker)</title></head><body><p>"
        let tail = "</p></body></html>"
        func page(bytes: Int) -> String {
            head + String(repeating: "a", count: max(0, bytes - head.utf8.count - tail.utf8.count)) + tail
        }
        let atLimit = page(bytes: limit)
        let over = page(bytes: limit + 1)
        XCTAssertEqual(atLimit.utf8.count, limit)
        XCTAssertEqual(over.utf8.count, limit + 1)

        // Save: one byte over is refused with a sentence the app can show, and nothing is stored.
        let save = await expectFailure(413, .saveArtifact(ArtifactSaveRequest(content: over, title: "Over \(marker)", makePwa: false)), api, message: "1 MB")
        XCTAssertNil(save.flatMap(ArtifactConflict.init(failure:)), "a 413 is not a conflict to resolve")
        let search = try await send(.yours(query: marker), api)
        XCTAssertTrue(search.results.isEmpty && search.recent.allSatisfy { !$0.name.contains(marker) }, "the refused page was stored anyway")

        // Keep has the same ceiling and says what it is.
        let keep = await expectFailure(413, .keep(content: over, title: "Over \(marker)"), api, message: "1 MB")
        XCTAssertEqual(keep?.recovery?["max_bytes"]?.int, limit, "the refusal does not name the limit in its recovery: \(String(describing: keep?.body))")
        XCTAssertEqual(keep?.recovery?["kind"]?.string, "shrink")

        // A living page refuses an oversize write too, and keeps what it had.
        let living = try await send(.saveArtifact(ArtifactSaveRequest(content: html(marker, "small"), title: "Living \(marker)", makePwa: false, mutable: true)), api)
        let content = try await send(.artifactContent(slug: living.slug), api)
        let base = try XCTUnwrap(content.headVersionId)
        let write = await expectFailure(413, .writeArtifact(slug: living.slug, ArtifactWriteRequest(content: over, baseVersionId: base)), api, message: "1 MB")
        XCTAssertNil(write.flatMap(ArtifactConflict.init(failure:)))
        let versions = try await send(.artifactVersions(slug: living.slug), api)
        XCTAssertEqual(versions.versions.count, 1, "a refused oversize write left a commit")

        // The limit itself is inclusive.
        let started = Date()
        let exact = try await send(.saveArtifact(ArtifactSaveRequest(content: atLimit, title: "Exact \(marker)", makePwa: false, mutable: true)), api)
        let back = try await send(.artifactContent(slug: exact.slug), api)
        XCTAssertEqual(back.content.utf8.count, limit, "a page of exactly the limit did not come back whole")
        report("413", [("saveMillis", Int(Date().timeIntervalSince(started) * 1000))])
    }

    // MARK: 429

    func testAPersonPastTheirMinuteIs429WithASentenceAndTheKitRetriesReadsButNotWrites() async throws {
        let person = try await freshMember("meter")
        let api = unpaced(person.token)
        let started = Date()

        var succeeded = 0
        var firstRefusal: HVError?
        for _ in 0..<140 {
            do {
                _ = try await api.sendRaw(.yours())
                succeeded += 1
            } catch let error as HVError {
                firstRefusal = error
                break
            }
        }
        let refusal = try XCTUnwrap(firstRefusal, "140 calls in a row were all accepted: the meter is not there")
        XCTAssertEqual(succeeded, 120, "the meter let \(succeeded) calls through; the server's stated limit is 120 a minute")
        XCTAssertEqual(refusal.status, 429)
        XCTAssertTrue(refusal.isRateLimited)
        XCTAssertFalse(refusal.isWaitlisted)
        let failure = try XCTUnwrap(refusal.failure)
        XCTAssertTrue(failure.message.localizedCaseInsensitiveContains("slow down"), failure.message)
        XCTAssertEqual(failure.status, 429)
        XCTAssertNil(failure.code, "a bare 429 carries no machine code")
        // What the server says to wait, if anything: the Kit uses it when it is there and backs off by itself when not.
        report("429", [("accepted", succeeded), ("retryAfterSent", failure.retryAfter == nil ? 0 : 1), ("seconds", Int(Date().timeIntervalSince(started)))])

        // A read is asked again with the Kit's own backoff, three tries in all, and then the refusal is shown.
        let log = LocalSleepLog()
        let patient = unpaced(person.token, retry: RetryPolicy(maxAttempts: 3, baseDelay: 0.5, maxDelay: 4), sleep: { await log.record($0) })
        do {
            _ = try await patient.sendRaw(.yours())
            XCTFail("a person past their minute was served")
        } catch let error as HVError {
            XCTAssertEqual(error.status, 429)
        }
        let waits = await log.waits
        XCTAssertEqual(waits.count, 2, "a read that is refused three times should wait twice; waited \(waits)")
        if failure.retryAfter == nil {
            XCTAssertGreaterThan(waits.first ?? 0, 0.4, "the first backoff was shorter than the policy's base")
            XCTAssertLessThanOrEqual(waits.first ?? 99, 1.0)
            if waits.count == 2 { XCTAssertGreaterThan(waits[1], waits[0] - 0.25, "the second wait did not grow: \(waits)") }
        }

        // A write is not asked again on its own: it could have landed.
        let before = await log.waits.count
        do {
            _ = try await patient.sendRaw(.keep(content: "While the meter says no \(uniqueWord())"))
            XCTFail("a write by a person past their minute was accepted")
        } catch let error as HVError {
            XCTAssertEqual(error.status, 429)
        }
        let after = await log.waits.count
        XCTAssertEqual(after, before, "a refused write was retried")

        // The meter is one person's, not the server's.
        let (other, _) = member(21)
        _ = try await send(.yours(), other)
        // And the refused person is still themselves to the routes that do not need the meter to say who: the token is good.
        XCTAssertNotNil(jwtSubject(person.token))
    }

    func testAnAgentKeyPastItsMinuteIs429NamingTheKeyLimit() async throws {
        let (api, token) = member(18)
        let minted = try await send(.createAgentKey(name: unique("meter key")), api)
        let agent = unpaced(minted.key)

        var succeeded = 0
        var firstRefusal: HVError?
        for _ in 0..<80 {
            do {
                _ = try await agent.sendRaw(.yours())
                succeeded += 1
            } catch let error as HVError {
                firstRefusal = error
                break
            }
        }
        let refusal = try XCTUnwrap(firstRefusal, "80 calls on one key were all accepted")
        XCTAssertEqual(succeeded, 60, "the key meter let \(succeeded) calls through; the server's stated limit is 60 a minute")
        XCTAssertEqual(refusal.status, 429)
        XCTAssertTrue(refusal.isRateLimited)
        XCTAssertTrue(refusal.failure?.message.contains("60") ?? false, "the refusal does not say what the key limit is: \(refusal)")
        XCTAssertTrue(refusal.failure?.message.localizedCaseInsensitiveContains("per key") ?? false, "\(refusal)")

        // The person's own token is another meter: the same account is not shut out by what its key did.
        _ = try await send(.yours(), api)

        // Still refused a moment later, and revoked once the person is done with it so reruns do not pile keys up.
        await expectFailure(429, .yours(), agent)
        let userID = try XCTUnwrap(jwtSubject(token))
        let listed = try await AgentKeyDirectory.keys(rest: try rest(token: token), userID: userID)
        let row = try XCTUnwrap(listed.first { $0.keyPrefix == minted.prefix })
        _ = try await send(.revokeAgentKey(id: row.id), api)
        report("429 key", [("accepted", succeeded)])
    }
}
