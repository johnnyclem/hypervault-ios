import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HyperVaultKit

/// Fixtures follow app/api/artifacts/[slug]/{content,versions,diff,revert}/route.ts and
/// lib/artifacts/write.ts (WriteSuccess, WriteConflict).
final class ArtifactVersionsTests: XCTestCase {
    let base = URL(string: "https://hv.test")!

    func client(_ transport: MockTransport) -> HVClient {
        HVClient(baseURL: base, transport: transport, tokens: StaticTokenProvider(), sleep: { _ in })
    }

    let contentJSON = #"""
    {"slug":"pomo-1","title":"Pomodoro","content":"<h1>Timer</h1>\n","is_jsx":false,"mutable":true,"content_hash":"abc123",
     "version":{"id":"v3","parent_version_id":"v2","message":"shorter break","created_at":"2026-10-20T10:00:00.000Z","authored_at":"2026-10-20T09:59:58.000Z","author_name":"grok","author_kind":"agent","is_head":true},
     "head_version_id":"v3"}
    """#

    func testContentDecodesTheHeadAndItsCommit() async throws {
        let transport = MockTransport(routes: [.json(.get, "/api/artifacts/pomo-1/content", contentJSON)])
        let content = try await client(transport).send(.artifactContent(slug: "pomo-1"))
        XCTAssertEqual(content.content, "<h1>Timer</h1>\n")
        XCTAssertTrue(content.mutable)
        XCTAssertEqual(content.headVersionId, "v3")
        XCTAssertEqual(content.version?.authorName, "grok")
        XCTAssertEqual(content.version?.isHead, true)
        XCTAssertEqual(content.version?.parentVersionId, "v2")
    }

    func testAnEarlierVersionIsAskedForByQuery() async throws {
        let transport = MockTransport(routes: [
            .json(.get, "/api/artifacts/pomo-1/content", #"{"slug":"pomo-1","title":"Pomodoro","content":"old","is_jsx":false,"mutable":true,"content_hash":"h","version":{"id":"v1","parent_version_id":null,"message":"create","created_at":"2026-10-01T00:00:00Z","is_head":false},"head_version_id":null}"#),
        ])
        let content = try await client(transport).send(.artifactContent(slug: "pomo-1", version: "v1"))
        XCTAssertNil(content.headVersionId)
        XCTAssertEqual(content.version?.isHead, false)
        let query = await transport.requests.first?.url?.query
        XCTAssertEqual(query, "version=v1")
    }

    func testWriteSendsTheBaseItWasBuiltOn() async throws {
        let ok = #"""
        {"url":"https://hv.test/a/pomo-1","slug":"pomo-1","is_jsx":false,"unchanged":false,"rebased":true,"forced":false,"base_version_id":"v2",
         "version":{"id":"v4","parent_version_id":"v3","message":"edit","created_at":"2026-10-21T00:00:00.000Z"},"head_version_id":"v4",
         "message":"Committed a new version of “Pomodoro” (rebased onto the current head). Pass head_version_id as base_version_id on your next write."}
        """#
        let transport = MockTransport(routes: [.json(.put, "/api/artifacts/pomo-1/content", ok)])
        let result = try await client(transport).send(.writeArtifact(slug: "pomo-1", ArtifactWriteRequest(content: "<h1>New</h1>", message: "edit", baseVersionId: "v2")))
        XCTAssertTrue(result.rebased)
        XCTAssertFalse(result.unchanged)
        XCTAssertEqual(result.headVersionId, "v4")
        let sentRequests = await transport.requests
        let sent = try XCTUnwrap(sentRequests.first)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(sent.httpBody)) as? [String: Any])
        XCTAssertEqual(body["base_version_id"] as? String, "v2")
        XCTAssertEqual(body["message"] as? String, "edit")
        XCTAssertNil(body["force"])
    }

    func testAnUnchangedWriteIsNotACommit() throws {
        let json = #"{"url":"u","slug":"s","is_jsx":false,"unchanged":true,"rebased":false,"forced":false,"version":null,"head_version_id":"v3","message":"No change — the new content matches the current version, so no commit was recorded."}"#
        let result = try HVCoding.decoder().decode(ArtifactWriteResult.self, from: Data(json.utf8))
        XCTAssertTrue(result.unchanged)
        XCTAssertNil(result.version)
    }

    // MARK: Conflicts

    func testAConflictCarriesTheHeadSoThePersonCanChoose() async {
        let body = #"""
        {"error":"Cannot apply update … pull the latest version of the artifact and rebase locally first.","conflict":true,"reason":"rebase_conflict","base_version_id":"v1",
         "head":{"id":"v3","parent_version_id":"v2","message":"agent edit","created_at":"2026-10-20T10:00:00.000Z","author_name":"grok","author_kind":"agent"},
         "current_content_hash":"h3","head_content":"<h1>Theirs</h1>","base_content":"<h1>Base</h1>"}
        """#
        let transport = MockTransport(routes: [.json(.put, "/api/artifacts/pomo-1/content", body, status: 409)])
        do {
            _ = try await client(transport).send(.writeArtifact(slug: "pomo-1", ArtifactWriteRequest(content: "mine", baseVersionId: "v1")))
            XCTFail("expected 409")
        } catch let error as HVError {
            let conflict = error.failure.flatMap(ArtifactConflict.init(failure:))
            XCTAssertEqual(conflict?.reason, .rebaseConflict)
            XCTAssertEqual(conflict?.headContent, "<h1>Theirs</h1>")
            XCTAssertEqual(conflict?.baseContent, "<h1>Base</h1>")
            XCTAssertEqual(conflict?.headVersionId, "v3")
            XCTAssertEqual(conflict?.head?.authorName, "grok")
            XCTAssertEqual(conflict?.status, 409)
        } catch {
            XCTFail("\(error)")
        }
    }

    func testTheOtherRefusalsAreConflictsToo() {
        func conflict(_ status: Int, reason: String, base: String = "null") -> ArtifactConflict? {
            let json = #"{"error":"x","conflict":true,"reason":"\#(reason)","base_version_id":null,"head":null,"current_content_hash":null,"head_content":"head","base_content":\#(base)}"#
            let value = try? HVCoding.decoder(.verbatim).decode(JSONValue.self, from: Data(json.utf8))
            return ArtifactConflict(failure: APIFailure(status: status, message: "x", body: value))
        }
        XCTAssertEqual(conflict(412, reason: "precondition_failed")?.reason, .preconditionFailed)
        XCTAssertEqual(conflict(428, reason: "precondition_required")?.reason, .preconditionRequired)
        XCTAssertEqual(conflict(409, reason: "stale_base")?.reason, .staleBase)
        XCTAssertEqual(conflict(409, reason: "concurrent_write")?.reason, .concurrentWrite)
        XCTAssertEqual(conflict(409, reason: "a_new_reason")?.reason, .other)
        XCTAssertNil(conflict(409, reason: "stale_base")?.head)
        XCTAssertNil(conflict(409, reason: "stale_base")?.baseContent, "a collaborator is never shown an older version")
    }

    func testAnImmutablePagesRefusalIsNotAConflict() {
        // writeArtifactContent: 409 { error } with no conflict body.
        let value = try? HVCoding.decoder(.verbatim).decode(JSONValue.self, from: Data(#"{"error":"“P” is immutable, so it can't be rewritten."}"#.utf8))
        XCTAssertNil(ArtifactConflict(failure: APIFailure(status: 409, message: "immutable", body: value)))
        XCTAssertNil(ArtifactConflict(failure: APIFailure(status: 413, message: "too big", body: nil)))
    }

    // MARK: History

    func testVersionsListNewestFirstWithProvenance() async throws {
        let json = #"""
        {"slug":"pomo-1","mutable":true,"versions":[
         {"id":"v3","parent_version_id":"v2","title":"Pomodoro","message":"shorter break","author_kind":"agent","author_key_prefix":"hv_ab12cd34","content_hash":"h3","is_jsx":false,"is_head":true,"created_at":"2026-10-20T10:00:00.000Z","authored_at":"2026-10-20T09:59:58.000Z","author_name":"grok","rebased_from_version_id":"v1"},
         {"id":"v2","parent_version_id":"v1","title":"Pomodoro","message":"","author_kind":"user","author_key_prefix":null,"content_hash":"h2","is_jsx":false,"is_head":false,"created_at":"2026-10-19T10:00:00.000Z","authored_at":null,"author_name":null,"rebased_from_version_id":null},
         {"id":"v1","parent_version_id":null,"title":"Pomodoro","message":"create","author_kind":"system","author_key_prefix":null,"content_hash":"h1","is_jsx":false,"is_head":false,"created_at":"2026-10-18T10:00:00.000Z"}
        ]}
        """#
        let transport = MockTransport(routes: [.json(.get, "/api/artifacts/pomo-1/versions", json)])
        let list = try await client(transport).send(.artifactVersions(slug: "pomo-1"))
        XCTAssertEqual(list.versions.map(\.id), ["v3", "v2", "v1"])
        XCTAssertTrue(list.mutable)
        XCTAssertEqual(list.versions[0].authorLine, "grok")
        XCTAssertTrue(list.versions[0].isRebased)
        XCTAssertTrue(list.versions[0].isHead)
        XCTAssertEqual(list.versions[1].authorLine, "You")
        XCTAssertEqual(list.versions[1].summary, "edit", "a commit with no message reads as the server's default")
        XCTAssertEqual(list.versions[2].authorLine, "HyperVault")
        let agentOnlyKey = ArtifactVersion.preview(authorKind: "agent", keyPrefix: "hv_ab12cd34")
        XCTAssertEqual(agentOnlyKey.authorLine, "hv_ab12cd34")
    }

    func testDiffAndRevertEndpoints() async throws {
        let transport = MockTransport(routes: [
            .json(.get, "/api/artifacts/pomo-1/diff", #"{"slug":"pomo-1","from":"v2","to":"v3","patch":"Index: x\n","added":2,"removed":1,"hunks":1}"#),
            .json(.post, "/api/artifacts/pomo-1/revert", #"{"url":"u","slug":"pomo-1","is_jsx":false,"unchanged":false,"rebased":false,"forced":false,"version":{"id":"v4","parent_version_id":"v3","message":"revert to v1","created_at":"2026-10-21T00:00:00Z"},"head_version_id":"v4","message":"Committed."}"#),
        ])
        let api = client(transport)
        let diff = try await api.send(.artifactDiff(slug: "pomo-1", from: "v2", to: "v3"))
        XCTAssertEqual(diff.added, 2)
        XCTAssertEqual(diff.removed, 1)
        let reverted = try await api.send(.revertArtifact(slug: "pomo-1", to: "v1", base: "v3"))
        XCTAssertEqual(reverted.headVersionId, "v4")
        let requests = await transport.requests
        XCTAssertEqual(requests[0].url?.query, "from=v2&to=v3")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(requests[1].httpBody)) as? [String: String])
        XCTAssertEqual(body, ["version_id": "v1", "base_version_id": "v3"])
    }

    // MARK: Diff lines

    func testUnifiedPatchBecomesColouredLines() {
        let patch = """
        Index: pomo-1@v2
        ===================================================================
        --- pomo-1@v2
        +++ pomo-1@v3
        @@ -1,4 +1,5 @@
         <h1>Timer</h1>
        -<p>25:00</p>
        +<p>20:00</p>
        +<p>Short break</p>
         <script>
         start()
        \\ No newline at end of file

        """
        let lines = ArtifactDiffLines.parse(patch: patch)
        XCTAssertEqual(lines.map(\.kind), [.hunk, .context, .removed, .added, .added, .context, .context, .note])
        XCTAssertEqual(lines[2].text, "<p>25:00</p>")
        XCTAssertEqual(lines[4].text, "<p>Short break</p>")
        XCTAssertEqual(lines.last?.text, "No newline at end of file")
        XCTAssertEqual(ArtifactDiffLines.parse(patch: "").count, 0)
    }

    func testARemovedLineThatStartsWithDashesIsStillARemovedLine() {
        let patch = "Index: x\n=====\n--- a\n+++ b\n@@ -1,2 +1,1 @@\n--- a SQL comment\n keep\n"
        let lines = ArtifactDiffLines.parse(patch: patch)
        XCTAssertEqual(lines.map(\.kind), [.hunk, .removed, .context])
        XCTAssertEqual(lines[1].text, "-- a SQL comment")
    }

    func testComparingTwoTextsFoldsWhatDidNotChange() throws {
        let old = (1...30).map { "line \($0)" }.joined(separator: "\n")
        var edited = (1...30).map { "line \($0)" }
        edited[14] = "line 15 changed"
        edited.insert("brand new", at: 28)
        let lines = try XCTUnwrap(ArtifactDiffLines.compare(old: old, new: edited.joined(separator: "\n")))
        XCTAssertTrue(lines.contains { $0.kind == .removed && $0.text == "line 15" })
        XCTAssertTrue(lines.contains { $0.kind == .added && $0.text == "line 15 changed" })
        XCTAssertTrue(lines.contains { $0.kind == .added && $0.text == "brand new" })
        XCTAssertTrue(lines.contains { $0.kind == .hunk && $0.text.hasSuffix("unchanged lines") })
        XCTAssertLessThan(lines.count, 30, "the folded diff is shorter than the file")
        // Context kept around a change: three lines each side.
        XCTAssertTrue(lines.contains { $0.kind == .context && $0.text == "line 12" })
        XCTAssertFalse(lines.contains { $0.kind == .context && $0.text == "line 5" })
    }

    func testIdenticalTextsHaveNothingToShowButTheFold() throws {
        let lines = try XCTUnwrap(ArtifactDiffLines.compare(old: "a\nb", new: "a\nb"))
        XCTAssertEqual(lines.map(\.kind), [.hunk])
        XCTAssertEqual(lines.first?.text, "2 unchanged lines")
    }

    func testTooLongToCompareIsSaidNotGuessed() {
        let long = (0..<(ArtifactDiffLines.compareLimit + 1)).map(String.init).joined(separator: "\n")
        XCTAssertNil(ArtifactDiffLines.compare(old: long, new: "x"))
    }
}

extension ArtifactVersion {
    /// A version for tests that only care about who wrote it.
    static func preview(authorKind: String, keyPrefix: String?) -> ArtifactVersion {
        let json = #"{"id":"v","author_kind":"\#(authorKind)","author_key_prefix":\#(keyPrefix.map { "\"\($0)\"" } ?? "null")}"#
        return try! HVCoding.decoder().decode(ArtifactVersion.self, from: Data(json.utf8))
    }
}
