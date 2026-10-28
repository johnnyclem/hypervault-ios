import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HyperVaultKit

/// Fixtures are shaped by app/api/memories/route.ts, [id]/route.ts,
/// [id]/history/route.ts and import/route.ts.
final class MemoryTests: XCTestCase {
    private let base = URL(string: "https://hv.test")!

    private func client(_ routes: [MockRoute]) -> (HVClient, MockTransport) {
        let transport = MockTransport(routes: routes)
        return (HVClient(baseURL: base, transport: transport, tokens: StaticTokenProvider(), retry: .none), transport)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try HVCoding.decoder().decode(type, from: Data(json.utf8))
    }

    // MARK: Reading

    func testDecodesTheList() throws {
        let json = #"""
        {"branch":"main","memories":[
          {"id":"m1","title":"Trip notes","summary":"Book the ferry on Friday.","tags":["trip","ferry"],"source":"manual","created_at":"2026-10-20T08:15:00.123456+00:00"},
          {"id":"m2","title":"Auth decision","summary":"Use passkeys.","tags":null,"source":"coding","created_at":"2026-10-19T08:15:00Z"}
        ]}
        """#
        let list = try decode(MemoryList.self, json)
        XCTAssertEqual(list.branch, "main")
        XCTAssertEqual(list.memories.map(\.id), ["m1", "m2"])
        XCTAssertEqual(list.memories[0].tags, ["trip", "ferry"])
        XCTAssertEqual(list.memories[1].tags, [], "null tags read as none")
        XCTAssertNotNil(list.memories[0].createdAt)
        XCTAssertEqual(list.memories[1].sourceLabel, "Coding")
    }

    func testAMemoryWithMissingFieldsStillDecodes() throws {
        let item = try decode(MemoryItem.self, #"{"id":"x"}"#)
        XCTAssertEqual(item.title, "Untitled memory")
        XCTAssertEqual(item.summary, "")
        XCTAssertEqual(item.source, "manual")
        XCTAssertNil(item.createdAt)
    }

    func testDecodesRecallWithReceiptsAndRelated() throws {
        let json = #"""
        {"query":"ferry","branch":"main","recall_mode":"hybrid","results":[
          {"id":"m1","title":"Trip notes","summary":"Book the ferry on Friday.","tags":["trip"],"source":"manual","created_at":"2026-10-20T08:15:00Z","score":0.82,
           "content":"Book the ferry on Friday.\n\nBring the passports and the printed tickets, the app is flaky on the pier. Leave by seven so we make the early crossing before the queue builds up at the terminal.",
           "related":["Passport checklist"],
           "provenance":{"commit_id":"3f2a9c1e-0000-4000-8000-000000000001","message":"memorize: Trip notes","author_kind":"agent","author_key_prefix":"hv_ab12cdef","committed_at":"2026-10-20T08:15:01Z"}},
          {"id":"m2","title":"Ferry times","summary":"Winter timetable.","tags":[],"source":"web","created_at":"2026-10-01T08:15:00Z","score":0.4,"related":[]}
        ],"message":"Recalled 2 matching memories."}
        """#
        let recall = try decode(MemoryRecall.self, json)
        XCTAssertEqual(recall.recallMode, .hybrid)
        XCTAssertEqual(recall.recallMode.label, "Meaning and keywords")
        XCTAssertEqual(recall.results.count, 2)
        let top = recall.results[0]
        XCTAssertEqual(top.score, 0.82, accuracy: 0.0001)
        XCTAssertEqual(top.related, ["Passport checklist"])
        XCTAssertEqual(top.provenance?.author, "Agent hv_ab12cdef")
        XCTAssertEqual(top.provenance?.shortCommitId, "3f2a9c1e")
        XCTAssertNil(recall.results[1].content, "only the best matches carry the chunk")
        XCTAssertNil(recall.results[1].provenance)
        XCTAssertEqual(recall.message, "Recalled 2 matching memories.")
        // The excerpt is the chunk, flattened and cut on a word.
        let excerpt = try XCTUnwrap(top.excerpt(limit: 80))
        XCTAssertTrue(excerpt.hasSuffix("…"))
        XCTAssertFalse(excerpt.contains("\n"))
        XCTAssertLessThanOrEqual(excerpt.count, 81)
    }

    func testExcerptIsNilWhenItAddsNothing() {
        let hit = MemoryRecallHit(id: "m", title: "t", summary: "Same words.", content: "Same   words.")
        XCTAssertNil(hit.excerpt(), "the same text as the summary adds nothing")
        XCTAssertNil(MemoryRecallHit(id: "m", title: "t").excerpt())
    }

    func testUnknownRecallModesReadAsKeyword() throws {
        let recall = try decode(MemoryRecall.self, #"{"query":"q","recall_mode":"quantum","results":[]}"#)
        XCTAssertEqual(recall.recallMode, .lexical)
        XCTAssertEqual(try decode(MemoryRecall.self, #"{"recall_mode":"hybrid-local"}"#).recallMode, .hybridLocal)
        XCTAssertEqual(MemoryRecallMode.lexical.label, "Keywords")
    }

    func testNothingMatchesKeepsTheServersSentence() throws {
        let recall = try decode(MemoryRecall.self, #"{"query":"zzz","branch":"main","recall_mode":"lexical","results":[],"message":"Nothing in memory matches that yet. Keep something first."}"#)
        XCTAssertTrue(recall.results.isEmpty)
        XCTAssertEqual(recall.message, "Nothing in memory matches that yet. Keep something first.")
    }

    func testDecodesAPageWithTruthAndBridges() throws {
        let json = #"""
        {"branch":"main",
         "memory":{"id":"m1","title":"Trip notes","content":"Book the ferry on Friday.","summary":"Book the ferry on Friday.","tags":["trip"],"source":"manual","created_at":"2026-10-20T08:15:00Z"},
         "related":[{"id":"m2","title":"Passport checklist","summary":"Where they are.","tags":null}],
         "artifacts":[{"id":"a1","slug":"trip-plan","title":"Trip plan","type":"note"}],
         "provenance":{"commit_id":"c1","message":"edit: Trip notes","author_kind":"user","committed_at":"2026-10-21T09:00:00Z"},
         "revision_count":3,
         "truth":{"stale":1,"rests_on":[
           {"ledger":"default","entry":{"id":"TB-12","type":"TB","status":"held","standing":"upheld","reasons":[],"text":"The ferry leaves at 07:10.","signedBy":null,"answerableBy":null},
            "relation":"rests_on","seen_status":"held","seen_standing":"upheld","stale_since":"2026-10-22T10:00:00Z","stale_kind":"struck","stale_by":"sam","stale_summary":"TB-12 was struck.","successor":null}]}}
        """#
        let page = try decode(MemoryPage.self, json)
        XCTAssertEqual(page.memory.title, "Trip notes")
        XCTAssertEqual(page.related.first?.title, "Passport checklist")
        XCTAssertEqual(page.related.first?.tags, [])
        XCTAssertEqual(page.artifacts.first?.slug, "trip-plan")
        XCTAssertEqual(page.provenance?.author, "You")
        XCTAssertEqual(page.revisionCount, 3)
        let edge = try XCTUnwrap(page.truth?.restsOn.first)
        XCTAssertEqual(edge.entryId, "TB-12")
        XCTAssertEqual(edge.entryText, "The ferry leaves at 07:10.")
        XCTAssertTrue(edge.isStale)
        XCTAssertEqual(edge.staleSummary, "TB-12 was struck.")
        XCTAssertEqual(page.truth?.stale, 1)
    }

    func testAPageWithoutTheOptionalBlocksDecodes() throws {
        let page = try decode(MemoryPage.self, #"{"branch":"ideas","memory":{"id":"m1","title":"T","content":"c","summary":"s","tags":[],"source":"manual"},"related":[],"artifacts":[],"revision_count":0}"#)
        XCTAssertNil(page.provenance)
        XCTAssertNil(page.truth)
        XCTAssertEqual(page.branch, "ideas")
    }

    func testPageSurvivesTheCache() throws {
        // The disk cache writes verbatim keys: what we encode must read back.
        let page = try decode(MemoryPage.self, #"{"branch":"main","memory":{"id":"m1","title":"T","content":"c","summary":"s","tags":["a"],"source":"manual","created_at":"2026-10-20T08:15:00Z"},"related":[{"id":"m2","title":"R","summary":"","tags":[]}],"artifacts":[],"provenance":{"commit_id":"c1","message":"m","author_kind":"agent","author_key_prefix":"hv_1","committed_at":"2026-10-21T09:00:00Z"},"revision_count":2,"truth":{"stale":0,"rests_on":[]}}"#)
        let data = try HVCoding.encoder(.verbatim).encode(page)
        let again = try HVCoding.decoder(.verbatim).decode(MemoryPage.self, from: data)
        XCTAssertEqual(again.memory.id, page.memory.id)
        XCTAssertEqual(again.provenance?.authorKeyPrefix, "hv_1")
        XCTAssertEqual(again.related.first?.title, "R")
        let list = MemoryList(branch: "main", memories: [MemoryItem(id: "a", title: "A", tags: ["x"], createdAt: Date(timeIntervalSince1970: 1_700_000_000))])
        let listData = try HVCoding.encoder(.verbatim).encode(list)
        XCTAssertEqual(try HVCoding.decoder(.verbatim).decode(MemoryList.self, from: listData).memories.first?.tags, ["x"])
        let connections = MemoryConnections(memoryLinks: [MemoryLinkRow(id: "l", aId: "a", bId: "b", kind: .manual)], bridges: [MemoryBridgeRow(id: "k", memoryId: "a", artifactId: "z")])
        let connectionData = try HVCoding.encoder(.verbatim).encode(connections)
        XCTAssertEqual(try HVCoding.decoder(.verbatim).decode(MemoryConnections.self, from: connectionData), connections)
    }

    func testHistoryHelpers() throws {
        let json = #"""
        {"memory_id":"m1","revisions":[
          {"revision_id":"r4","op":"delete","title":"Trip notes","summary":"","tags":[],"source":"manual","commit":{"id":"c4","message":"forget: Trip notes","author_kind":"user","branch":"main","created_at":"2026-10-25T10:00:00Z"}},
          {"revision_id":"r3","op":"update","title":"Trip notes","summary":"","tags":[],"source":"manual","commit":{"id":"c3","message":"edit: Trip notes","author_kind":"agent","author_key_prefix":"hv_9","branch":"main","created_at":"2026-10-22T10:00:00Z"}},
          {"revision_id":"r2","op":"update","title":"Trip notes","summary":"","tags":[],"source":"manual","commit":{"id":"c2","message":"edit: Trip notes","author_kind":"user","branch":"ideas","created_at":"2026-10-21T10:00:00Z"}},
          {"revision_id":"r1","op":"create","title":"Trip","summary":"","tags":[],"source":"manual","commit":{"id":"c1","message":"memorize: Trip","author_kind":"user","branch":"main","created_at":"2026-10-20T10:00:00Z"}}
        ]}
        """#
        let history = try decode(MemoryHistory.self, json)
        XCTAssertEqual(history.revisions.count, 4)
        XCTAssertEqual(history.revisions[1].commit?.author, "Agent hv_9")
        XCTAssertEqual(history.lastLive?.revisionId, "r3", "what to bring back is the newest version that was not the forgetting")
        let day = { (d: Int) in HVDate.parse("2026-10-\(d)T12:00:00Z")! }
        XCTAssertNil(history.revision(asOf: day(19)), "not written yet")
        XCTAssertEqual(history.revision(asOf: day(20))?.revisionId, "r1")
        XCTAssertEqual(history.revision(asOf: day(21))?.revisionId, "r2")
        XCTAssertEqual(history.revision(asOf: day(24))?.revisionId, "r3")
        XCTAssertNil(history.revision(asOf: day(26)), "it had been forgotten by then")
        XCTAssertEqual(history.previous(of: history.revisions[1])?.revisionId, "r2")
        XCTAssertNil(history.previous(of: history.revisions[3]))
    }

    func testAStateRowFindsItsOwnBranchsRevisionNotAnotherBranchsNewerOne() throws {
        // main edited the memory at T1, ideas at T2 > T1. Time travel on main at T3 shows main's T1 version.
        let json = #"""
        {"memory_id":"m1","revisions":[
          {"revision_id":"r-ideas","op":"update","title":"Trip notes","summary":"Ideas version","tags":["a"],"source":"manual","commit":{"id":"c3","message":"edit","author_kind":"user","branch":"ideas","created_at":"2026-10-22T10:00:00.123456Z"}},
          {"revision_id":"r-main","op":"update","title":"Trip notes","summary":"Main version","tags":["a"],"source":"manual","commit":{"id":"c2","message":"edit","author_kind":"user","branch":"main","created_at":"2026-10-21T10:00:00.654321Z"}},
          {"revision_id":"r-first","op":"create","title":"Trip","summary":"First","tags":[],"source":"manual","commit":{"id":"c1","message":"memorize","author_kind":"user","branch":"main","created_at":"2026-10-20T10:00:00Z"}}
        ]}
        """#
        let history = try decode(MemoryHistory.self, json)
        let main = try decode(MindStateMemory.self, #"{"id":"m1","title":"Trip notes","summary":"Main version","tags":["a"],"source":"manual","committed_at":"2026-10-21T10:00:00.654321Z"}"#)
        XCTAssertEqual(history.revision(for: main)?.revisionId, "r-main", "not the newest in the list, which is another branch's")
        XCTAssertEqual(history.revision(asOf: HVDate.parse("2026-10-23T00:00:00Z")!)?.revisionId, "r-ideas", "a moment alone lands on the other branch's edit")
        let first = try decode(MindStateMemory.self, #"{"id":"m1","title":"Trip","summary":"First","tags":[],"source":"manual","committed_at":"2026-10-20T10:00:00Z"}"#)
        XCTAssertEqual(history.revision(for: first)?.revisionId, "r-first")
    }

    func testAStateRowOfAMemoryThatPredatesBranchesIsFoundByWhatItSays() throws {
        // Its first revision keeps the memory's own time; the commit that adopted it is later, so the times differ.
        let history = try decode(MemoryHistory.self, #"""
        {"memory_id":"m1","revisions":[
          {"revision_id":"r-deleted","op":"delete","title":"Trip","summary":"First","tags":["x","y"],"source":"manual","commit":{"id":"c3","message":"forget","author_kind":"user","branch":"main","created_at":"2026-10-25T10:00:00Z"}},
          {"revision_id":"r-adopted","op":"create","title":"Trip","summary":"First","tags":["y","x"],"source":"manual","commit":{"id":"c1","message":"genesis","author_kind":"system","branch":"main","created_at":"2026-09-01T00:00:00Z"}}
        ]}
        """#)
        let row = try decode(MindStateMemory.self, #"{"id":"m1","title":"Trip","summary":"First","tags":["x","y"],"source":"manual","committed_at":"2026-03-02T08:00:00Z"}"#)
        XCTAssertEqual(history.revision(for: row)?.revisionId, "r-adopted", "a forgetting is never a version to restore")
        let other = try decode(MindStateMemory.self, #"{"id":"m1","title":"Something else","summary":"First","tags":[],"source":"manual","committed_at":"2026-03-02T08:00:00Z"}"#)
        XCTAssertNil(history.revision(for: other), "nothing that matches is no version, not the nearest one")
        XCTAssertNil(try decode(MemoryHistory.self, #"{"memory_id":"m1","revisions":[]}"#).revision(for: row))
    }

    // MARK: Writing

    func testDraftProblemsUseTheServersSentences() {
        XCTAssertEqual(MemoryDraft(content: "  \n ").problem(limitBytes: 500_000), "content is required — the text to memorize.")
        XCTAssertNil(MemoryDraft(content: "A thought.").problem(limitBytes: 500_000))
        let big = MemoryDraft(content: String(repeating: "x", count: 2_001))
        XCTAssertEqual(big.problem(limitBytes: 2_000), "That chunk is over the 2 kB memory limit — split it into smaller memories.")
        XCTAssertEqual(MemoryDraft(content: String(repeating: "é", count: 300_000)).problem(limitBytes: 500_000), "That chunk is over the 500 kB memory limit — split it into smaller memories.", "limits count bytes, not characters")
        XCTAssertEqual(MemoryLimits.label(forBytes: 500_000), "500 kB")
        XCTAssertEqual(MemoryLimits.label(forBytes: 4_000_000), "4 MB")
        XCTAssertEqual(MemoryLimits.label(forBytes: 2_500_000), "2.5 MB")
    }

    func testTagsAreCleanedTheWayTheServerWould() {
        XCTAssertEqual(MemoryTags.parse("trip, #ferry,Trip ,, \n passports"), ["trip", "ferry", "passports"])
        XCTAssertEqual(MemoryTags.parse(""), [])
        XCTAssertEqual(MemoryTags.parse((1...20).map { "t\($0)" }.joined(separator: ",")).count, 12)
    }

    func testCreateSendsOnlyWhatWasFilledIn() async throws {
        let (api, transport) = client([.json(.post, "/api/memories", #"{"id":"m9","title":"Trip notes","summary":"s","tags":["trip"],"source":"manual","links":2,"branch":"ideas","commit_id":"c9","message":"Kept in memory, and linked to 2 related memories."}"#)])
        let draft = MemoryDraft(content: "  Book the ferry.  ", title: " Trip notes ", tagsText: "trip, ferry", source: "coding")
        let kept = try await api.send(.memoryCreate(draft, branch: "ideas"))
        XCTAssertEqual(kept.id, "m9")
        XCTAssertEqual(kept.links, 2)
        XCTAssertEqual(kept.message, "Kept in memory, and linked to 2 related memories.")
        XCTAssertEqual(kept.item(now: Date(timeIntervalSince1970: 0)).title, "Trip notes")
        let allSent = await transport.requests
        let sent = try XCTUnwrap(allSent.first)
        let body = try XCTUnwrap(sent.httpBody)
        let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        XCTAssertEqual(object?["content"] as? String, "Book the ferry.")
        XCTAssertEqual(object?["title"] as? String, "Trip notes")
        XCTAssertEqual(object?["tags"] as? [String], ["trip", "ferry"])
        XCTAssertEqual(object?["source"] as? String, "coding")
        XCTAssertEqual(object?["branch"] as? String, "ideas")

        let bare = MemoryDraft(content: "Just text", source: "not-a-source")
        _ = try await api.send(.memoryCreate(bare))
        let allSent2 = await transport.requests
        let second = try XCTUnwrap(allSent2.last?.httpBody)
        let secondObject = try JSONSerialization.jsonObject(with: second) as? [String: Any]
        XCTAssertEqual(Set(secondObject?.keys.map { $0 } ?? []), ["content"], "no title, tags, source or branch when none was given")
    }

    func testEditSendsOnlyWhatChanged() throws {
        let original = MemoryFull(id: "m1", title: "Trip notes", content: "Book the ferry.", summary: "s", tags: ["trip", "ferry"])
        XCTAssertNil(MemoryEditRequest.make(original: original, title: "Trip notes", content: "Book the ferry.", tags: ["trip", "ferry"]), "the server refuses an edit that changes nothing")
        let retagged = MemoryEditRequest.make(original: original, title: "  Trip notes ", content: "Book the ferry.\n", tags: ["Trip", "ferry"])
        XCTAssertNil(retagged?.title, "whitespace around the same title is not a rename")
        XCTAssertNil(retagged?.content, "a trailing newline is not an edit")
        XCTAssertEqual(retagged?.tags, ["Trip", "ferry"], "a changed capital is")

        let titleOnly = try XCTUnwrap(MemoryEditRequest.make(original: original, title: "Ferry trip", content: "Book the ferry.", tags: ["trip", "ferry"], message: "  rename ", branch: "main"))
        XCTAssertEqual(titleOnly.title, "Ferry trip")
        XCTAssertNil(titleOnly.content)
        XCTAssertNil(titleOnly.tags)
        XCTAssertEqual(titleOnly.message, "rename")
        XCTAssertEqual(titleOnly.branch, "main")

        let all = try XCTUnwrap(MemoryEditRequest.make(original: original, title: "", content: "Book the ferry and the bus.", tags: ["#trip"]))
        XCTAssertNil(all.title, "a blank title keeps the old one")
        XCTAssertEqual(all.content, "Book the ferry and the bus.")
        XCTAssertEqual(all.tags, ["trip"])
        XCTAssertNil(all.message)

        XCTAssertNil(MemoryEditRequest.make(original: original, title: "Trip notes", content: "   ", tags: ["trip", "ferry"]), "blank text is not an edit")
    }

    func testEditForgetAndHistoryEndpoints() async throws {
        let (api, transport) = client([
            .json(.patch, "/api/memories/m1", #"{"id":"m1","title":"Ferry trip","summary":"s","tags":["trip"],"branch":"main","commit_id":"c2","links":1,"message":"Edited — revision committed to main."}"#),
            .json(.delete, "/api/memories/m1", #"{"deleted":"m1","branch":"main","message":"Forgotten — the memory and its links are gone (its history remains revertible)."}"#),
            .json(.get, "/api/memories/m1/history", #"{"memory_id":"m1","revisions":[]}"#),
        ])
        let original = MemoryFull(id: "m1", title: "Trip notes", content: "c", summary: "s", tags: ["trip"])
        let request = try XCTUnwrap(MemoryEditRequest.make(original: original, title: "Ferry trip", content: "c", tags: ["trip"], branch: "main"))
        let edited = try await api.send(.memoryEdit(id: "m1", request))
        XCTAssertEqual(edited.message, "Edited — revision committed to main.")
        let forgotten = try await api.send(.memoryForget(id: "m1", branch: "ideas"))
        XCTAssertEqual(forgotten.deleted, "m1")
        _ = try await api.send(.memoryHistory(id: "m1", full: true, limit: 20))
        let sent = await transport.requests
        XCTAssertEqual(String(decoding: sent[0].httpBody ?? Data(), as: UTF8.self), #"{"branch":"main","title":"Ferry trip"}"#)
        XCTAssertEqual(sent[1].url?.query, "branch=ideas")
        XCTAssertEqual(sent[1].httpMethod, "DELETE")
        XCTAssertEqual(Set((sent[2].url?.query ?? "").split(separator: "&").map(String.init)), ["full=1", "limit=20"])
    }

    func testAStaleEditComesBackAsTheServersConflictSentence() async {
        let (api, _) = client([.json(.patch, "/api/memories/m1", #"{"error":"The memory changed while you were editing it — reload it and reapply your edit.","conflict":true}"#, status: 409)])
        let original = MemoryFull(id: "m1", title: "t", content: "c")
        let request = MemoryEditRequest.make(original: original, title: "u", content: "c", tags: [])!
        do {
            _ = try await api.send(.memoryEdit(id: "m1", request))
            XCTFail("expected a refusal")
        } catch let error as HVError {
            XCTAssertEqual(error.status, 409)
            XCTAssertEqual(error.userMessage, "The memory changed while you were editing it — reload it and reapply your edit.")
            XCTAssertEqual(error.failure?.body?["conflict"]?.bool, true)
        } catch {
            XCTFail("wrong error \(error)")
        }
    }

    // MARK: Importing

    func testFileImportIsMultipartWithTheBranchInTheQuery() async throws {
        let (api, transport) = client([.json(.post, "/api/memories/import", #"{"id":"m5","title":"Quarterly report","summary":"s","tags":["pdf","notes"],"source":"file","links":0,"branch":"main","commit_id":"c5","message":"Imported the file — it's in your private wiki now."}"#)])
        let kept = try await api.send(.memoryImport(filename: "Quarterly report.pdf", data: Data("%PDF-1.4".utf8), branch: "main"))
        XCTAssertEqual(kept.source, "file")
        XCTAssertEqual(kept.message, "Imported the file — it's in your private wiki now.")
        let allSent = await transport.requests
        let sent = try XCTUnwrap(allSent.first)
        XCTAssertEqual(sent.url?.query, "branch=main")
        XCTAssertTrue(sent.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
        let body = String(decoding: sent.httpBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains(#"name="file"; filename="Quarterly report.pdf""#))
        XCTAssertTrue(body.contains("Content-Type: application/pdf"))
    }

    func testURLImportSendsJSON() async throws {
        let (api, transport) = client([.json(.post, "/api/memories/import", #"{"id":"m6","title":"owner/repo","summary":"s","tags":[],"source":"github","links":1,"branch":"main","commit_id":"c6","message":"Imported the repository digest and linked it to 1 related memory in your wiki."}"#)])
        let kept = try await api.send(.memoryImport(url: "https://github.com/owner/repo"))
        XCTAssertEqual(kept.source, "github")
        let allSent = await transport.requests
        let sent = try XCTUnwrap(allSent.first)
        XCTAssertEqual(String(decoding: sent.httpBody ?? Data(), as: UTF8.self), #"{"url":"https://github.com/owner/repo"}"#)
        XCTAssertNil(sent.url?.query)
    }

    func testImportRefusalsKeepTheirSentences() async {
        // 429, 415 and a JSON 413 come from the route; the platform's plain-text 413 does not.
        let cases: [(Int, String, String)] = [
            (429, #"{"error":"Import rate limit reached — try again in a minute."}"#, "Import rate limit reached — try again in a minute."),
            (415, #"{"error":"Unsupported file type — import a PDF, DOCX, .md, or .txt file."}"#, "Unsupported file type — import a PDF, DOCX, .md, or .txt file."),
            (413, #"{"error":"That file is over the 4 MB import limit."}"#, "That file is over the 4 MB import limit."),
            (413, "Request Entity Too Large", "That upload is too large — the import limit is 4 MB."),
            (400, #"{"error":"No readable text found in that file."}"#, "No readable text found in that file."),
        ]
        for (status, body, expected) in cases {
            let (api, _) = client([MockRoute(.post, "/api/memories/import") { _ in HTTPResponse(status: status, data: Data(body.utf8)) }])
            do {
                _ = try await api.send(.memoryImport(url: "https://example.com"))
                XCTFail("expected a refusal for \(status)")
            } catch let error as HVError {
                XCTAssertEqual(MemoryImportPolicy.message(for: error), expected)
            } catch {
                XCTFail("wrong error \(error)")
            }
        }
    }

    func testImportPolicy() {
        XCTAssertEqual(MemoryImportPolicy.kind(forFilename: "Report.PDF"), .pdf)
        XCTAssertEqual(MemoryImportPolicy.kind(forFilename: "notes.md"), .markdown)
        XCTAssertEqual(MemoryImportPolicy.kind(forFilename: "readme.mdx"), .markdown)
        XCTAssertEqual(MemoryImportPolicy.kind(forFilename: "a.b.docx"), .docx)
        XCTAssertEqual(MemoryImportPolicy.kind(forFilename: "log.txt"), .text)
        XCTAssertNil(MemoryImportPolicy.kind(forFilename: "photo.png"))
        XCTAssertNil(MemoryImportPolicy.kind(forFilename: "noextension"))
        XCTAssertNil(MemoryImportPolicy.problem(filename: "ok.pdf", byteCount: 3_999_999))
        XCTAssertEqual(MemoryImportPolicy.problem(filename: "big.pdf", byteCount: 4_000_001), "\"big.pdf\" is over the 4 MB import limit — split it or trim it down.")
        XCTAssertEqual(MemoryImportPolicy.problem(filename: "pic.png", byteCount: 10), "Unsupported file type — import a PDF, DOCX, .md, or .txt file.")
        XCTAssertEqual(MemoryImportPolicy.normalizedURL("github.com/owner/repo"), "https://github.com/owner/repo")
        XCTAssertEqual(MemoryImportPolicy.normalizedURL(" https://example.com/a "), "https://example.com/a")
        XCTAssertNil(MemoryImportPolicy.normalizedURL("not a url"))
        XCTAssertNil(MemoryImportPolicy.normalizedURL("localhost"))
        XCTAssertNil(MemoryImportPolicy.normalizedURL("ftp://example.com"))
        XCTAssertNil(MemoryImportPolicy.normalizedURL(""))
    }

    // MARK: Recall on the device

    func testKeywordsMatchTheServers() {
        XCTAssertEqual(MemoryRecallScorer.keywords("What did I decide about the Auth flow?"), ["decide", "auth", "flow"])
        XCTAssertEqual(MemoryRecallScorer.keywords("c++ and C# in 2026 — the e-mail's"), ["c++", "2026", "e-mail's"])
        XCTAssertEqual(MemoryRecallScorer.keywords("a an to of"), [])
    }

    func testScoreWeighsTitleTagsAndSummary() {
        XCTAssertEqual(MemoryRecallScorer.score(query: "ferry", title: "Ferry notes", summary: "x", tags: []), 3)
        XCTAssertEqual(MemoryRecallScorer.score(query: "ferry", title: "Notes", summary: "ferry times", tags: ["Ferry"]), 5)
        XCTAssertEqual(MemoryRecallScorer.score(query: "ferry passports", title: "Ferry notes", summary: "Passports", tags: []), 5)
        XCTAssertEqual(MemoryRecallScorer.score(query: "the", title: "the", summary: "", tags: []), 0)
    }

    func testRankNarrowsWhileTypingAndKeepsNewestFirstOnTies() {
        let items = [
            MemoryItem(id: "1", title: "Architecture review", summary: "Notes from the review", tags: ["design"]),
            MemoryItem(id: "2", title: "Lunch", summary: "Soup", tags: []),
            MemoryItem(id: "3", title: "Auth decision", summary: "Passkeys", tags: ["architecture"]),
            MemoryItem(id: "4", title: "Archery club", summary: "Saturdays", tags: []),
        ]
        XCTAssertEqual(MemoryRecallScorer.rank("arch", in: items).map(\.id), ["1", "4", "3"], "a half-typed word finds words that start with it")
        XCTAssertEqual(MemoryRecallScorer.rank("architecture", in: items).map(\.id), ["1", "3"], "a title word and a tag word both count; the title gets the tie-break from being newer")
        XCTAssertEqual(MemoryRecallScorer.rank("", in: items).map(\.id), ["1", "2", "3", "4"])
        XCTAssertTrue(MemoryRecallScorer.rank("zzzz", in: items).isEmpty)
        XCTAssertEqual(MemoryRecallScorer.rank("soup", in: items).map(\.id), ["2"])
    }

    // MARK: Graph

    func testGraphKeepsOnlyRealEdgesAndDedupes() {
        let memories = ["a", "b", "c"].map { MemoryItem(id: $0, title: $0.uppercased()) }
        let links = [
            MemoryLinkRow(id: "1", aId: "a", bId: "b", kind: .manual),
            MemoryLinkRow(id: "2", aId: "b", bId: "a", kind: .auto),
            MemoryLinkRow(id: "3", aId: "a", bId: "zzz"),
            MemoryLinkRow(id: "4", aId: "c", bId: "c"),
        ]
        let bridges = [MemoryBridgeRow(id: "5", memoryId: "c", artifactId: "art1"), MemoryBridgeRow(id: "6", memoryId: "gone", artifactId: "art2")]
        let graph = MemoryGraphBuilder.build(
            memories: memories, links: links, bridges: bridges,
            artifacts: [MemoryGraphArtifact(id: "art1", title: "Trip plan", slug: "trip-plan")]
        )
        XCTAssertEqual(graph.nodes.map(\.id), ["a", "b", "c", "art1"])
        XCTAssertEqual(graph.edges.count, 2)
        XCTAssertEqual(graph.edges.first?.isManual, true)
        XCTAssertEqual(graph.node("art1")?.title, "Trip plan")
        XCTAssertEqual(graph.node("art1")?.slug, "trip-plan")
        XCTAssertEqual(graph.node("art1")?.kind, .artifact)
        XCTAssertEqual(graph.node("a")?.degree, 1)
        XCTAssertEqual(graph.neighbours(of: "c"), ["art1"])
        XCTAssertFalse(graph.isCapped)
    }

    func testGraphCapPrefersConnectedNodesThenNewest() {
        let memories = (0..<10).map { MemoryItem(id: "m\($0)", title: "M\($0)") }
        // m8 and m9 are the only linked ones; the rest are loose.
        let links = [MemoryLinkRow(id: "l", aId: "m8", bId: "m9")]
        let graph = MemoryGraphBuilder.build(memories: memories, links: links, cap: 4)
        XCTAssertEqual(graph.nodes.count, 4)
        XCTAssertEqual(Set(graph.nodes.map(\.id)), ["m8", "m9", "m0", "m1"])
        XCTAssertEqual(graph.edges.count, 1)
        XCTAssertTrue(graph.isCapped)
        XCTAssertEqual(graph.memoryTotal, 10)
    }

    func testGraphCanHideLooseMemories() {
        let memories = ["a", "b", "c"].map { MemoryItem(id: $0, title: $0) }
        let graph = MemoryGraphBuilder.build(memories: memories, links: [MemoryLinkRow(id: "1", aId: "a", bId: "b")], hideUnlinked: true)
        XCTAssertEqual(graph.nodes.map(\.id), ["a", "b"])
    }

    func testTheDefaultCapIs150() {
        let memories = (0..<400).map { MemoryItem(id: "m\($0)", title: "M") }
        XCTAssertEqual(MemoryGraphBuilder.build(memories: memories, links: []).nodes.count, 150)
    }

    func testConnectionsDecode() throws {
        let json = #"""
        {"connections":[{"id":"x","a_id":"p","b_id":"q","kind":"auto","created_at":"2026-10-01T00:00:00Z"}],
         "memory_links":[{"id":"l1","a_id":"m1","b_id":"m2","kind":"manual","created_at":"2026-10-01T00:00:00Z"},{"id":"l2","a_id":"m2","b_id":"m3","kind":"auto","created_at":"2026-10-01T00:00:00Z"}],
         "memory_artifact_links":[{"id":"b1","memory_id":"m1","artifact_id":"a1","kind":"auto","created_at":"2026-10-01T00:00:00Z"}]}
        """#
        let connections = try decode(MemoryConnections.self, json)
        XCTAssertEqual(connections.memoryLinks.map(\.kind), [.manual, .auto])
        XCTAssertEqual(connections.bridges.first?.artifactId, "a1")
    }

    func testConnectingTwoThings() async throws {
        let (api, transport) = client([.json(.post, "/api/connections", #"{"connected":["m1","m2"],"message":"Connected — check the graph view!"}"#)])
        let result = try await api.send(.memoryConnect(source: "m1", target: "m2"))
        XCTAssertEqual(result.connected, ["m1", "m2"])
        XCTAssertEqual(result.message, "Connected — check the graph view!")
        let allSent = await transport.requests
        XCTAssertEqual(String(decoding: allSent.first?.httpBody ?? Data(), as: UTF8.self), #"{"source":"m1","target":"m2"}"#)
    }

    func testConnectingToItselfIsRefusedWithTheServersSentence() async {
        let (api, _) = client([.failure(.post, "/api/connections", status: 400, message: "An item cannot connect to itself.")])
        do {
            _ = try await api.send(.memoryConnect(source: "m1", target: "m1"))
            XCTFail("expected a refusal")
        } catch let error as HVError {
            XCTAssertEqual(error.userMessage, "An item cannot connect to itself.")
        } catch {
            XCTFail("wrong error \(error)")
        }
    }

    // MARK: Ask

    func testAskIsOneChatTurnWithRecallOn() async throws {
        let reply = #"""
        {"conversation_id":"conv-1","reply":{"id":"msg-2","role":"assistant","content":"You decided on passkeys.","model":"gpt-x","truncated":false},
         "backend":{"id":"b1","name":"Mine","provider":"openai"},"recalled":3,"recalled_memories":["Auth decision","Passkeys notes"],"recall_branch":"main","tools":{"status":"off","turns":[]}}
        """#
        let (api, transport) = client([
            .json(.get, "/api/backends", #"{"backends":[{"id":"b1","name":"Mine","provider":"openai","default_model":"gpt-x","key_hint":"…1234"}],"providers":[]}"#),
            .json(.post, "/api/chat", reply),
        ])
        let backends = try await api.send(.memoryAskBackends)
        XCTAssertEqual(backends, [MemoryAskBackend(id: "b1", name: "Mine", defaultModel: "gpt-x")])
        let answer = try await api.send(.memoryAsk(backendId: "b1", message: "What did I decide about auth?", conversationId: "conv-0"))
        XCTAssertEqual(answer.text, "You decided on passkeys.")
        XCTAssertEqual(answer.recalled, ["Auth decision", "Passkeys notes"])
        XCTAssertEqual(answer.conversationId, "conv-1")
        XCTAssertEqual(answer.model, "gpt-x")
        let allSent = await transport.requests
        let sent = try XCTUnwrap(allSent.last?.httpBody)
        let object = try JSONSerialization.jsonObject(with: sent) as? [String: Any]
        XCTAssertEqual(object?["backend_id"] as? String, "b1")
        XCTAssertEqual(object?["use_recall"] as? Bool, true)
        XCTAssertEqual(object?["conversation_id"] as? String, "conv-0")
    }

    func testAskIsWrittenFromTheBranchBeingRead() async throws {
        let reply = #"{"conversation_id":"conv-1","reply":{"id":"m","role":"assistant","content":"Ferries run hourly."},"recalled_memories":["Ferry times"],"recall_branch":"ideas"}"#
        let (api, transport) = client([.json(.post, "/api/chat", reply)])
        _ = try await api.send(.memoryAsk(backendId: "b1", message: "When is the ferry?", recallBranch: "ideas"))
        _ = try await api.send(.memoryAsk(backendId: "b1", message: "And on main?", recallBranch: "main"))
        _ = try await api.send(.memoryAsk(backendId: "b1", message: "And with none?"))
        _ = try await api.send(.memoryAsk(backendId: "b1", message: "And with an empty one?", recallBranch: ""))
        let sent = try await transport.requests.map { try XCTUnwrap($0.httpBody) }
        let bodies = try sent.map { try XCTUnwrap(JSONSerialization.jsonObject(with: $0) as? [String: Any]) }
        XCTAssertEqual(bodies[0]["recall_branch"] as? String, "ideas", "the route recalls main unless it is told a branch")
        XCTAssertNil(bodies[1]["recall_branch"], "main is what the route reads without being asked")
        XCTAssertNil(bodies[2]["recall_branch"])
        XCTAssertNil(bodies[3]["recall_branch"])
    }

    func testAnAnswerCarriesItsReplyIdTheLedgerTheGraphAndTheToolSteps() async throws {
        let reply = #"""
        {"conversation_id":"conv-1","reply":{"id":"msg-9","role":"assistant","content":"The ferry leaves at nine.","model":"gpt-x","truncated":false},
         "recalled":2,"recalled_memories":["Ferry times"],"recall_branch":"main",
         "deep_memory":["Passports","Lisbon trip"],
         "truth":{"cited":2,"contested":1,"flags":0,"drafted":0,"ledgers":["main"]},
         "tools":{"status":"ok","toolkit_id":"tk1","turns":[{"intent":"look up the ferry","tool":"ferries.lookup","ok":true,"confidence":0.92,"tier":"high","preview":"Friday 09:00"}]}}
        """#
        let (api, _) = client([.json(.post, "/api/chat", reply)])
        let answer = try await api.send(.memoryAsk(backendId: "b1", message: "When is the ferry?"))
        XCTAssertEqual(answer.messageId, "msg-9", "a thumb is saved against the reply's own id")
        XCTAssertEqual(answer.deepMemory, ["Passports", "Lisbon trip"])
        XCTAssertEqual(answer.truth?.footnote, "Cited 2 ledger entries, 1 contested")
        XCTAssertEqual(answer.tools.status, .ok)
        XCTAssertEqual(answer.tools.toolkitId, "tk1", "the tool block is read as a chat turn reads it")
        XCTAssertEqual(answer.tools.turns.map(\.summary), ["\u{201C}look up the ferry\u{201D} \u{2192} ferries.lookup"])
        XCTAssertEqual(answer.tools.turns.first?.tierLabel, "high 92%")
        XCTAssertEqual(answer.grounding.deepMemory, ["Passports", "Lisbon trip"])
        XCTAssertEqual(answer.grounding.truth?.cited, 2)
        XCTAssertTrue(answer.grounding.memories.isEmpty, "the memories are the sources the screen lists, not chips under the answer")
    }

    func testAnAnswerWithNoneOfThatIsPlain() async throws {
        let reply = #"{"conversation_id":"conv-1","reply":{"content":"Passkeys."},"recalled_memories":["Auth decision"]}"#
        let (api, _) = client([.json(.post, "/api/chat", reply)])
        let answer = try await api.send(.memoryAsk(backendId: "b1", message: "What did I decide about auth?"))
        XCTAssertEqual(answer.text, "Passkeys.")
        XCTAssertNil(answer.messageId)
        XCTAssertEqual(answer.deepMemory, [])
        XCTAssertNil(answer.truth)
        XCTAssertEqual(answer.tools, .off)
        XCTAssertTrue(answer.grounding.isEmpty)
    }

    func testAnAnswerIsNotLostToAFieldItOnlyDecoratesWith() async throws {
        let reply = #"{"conversation_id":"conv-1","reply":{"id":"m","content":"Passkeys."},"deep_memory":"not a list","truth":[1,2],"tools":"on"}"#
        let (api, _) = client([.json(.post, "/api/chat", reply)])
        let answer = try await api.send(.memoryAsk(backendId: "b1", message: "What did I decide about auth?"))
        XCTAssertEqual(answer.text, "Passkeys.")
        XCTAssertEqual(answer.deepMemory, [])
        XCTAssertNil(answer.truth)
        XCTAssertEqual(answer.tools, .off)
    }

    func testToolsAreOnForAnAskUnlessTheyAreSwitchedOff() async throws {
        let reply = #"{"conversation_id":"conv-1","reply":{"id":"m","content":"Ferries run hourly."},"recalled_memories":[]}"#
        let (api, transport) = client([.json(.post, "/api/chat", reply)])
        _ = try await api.send(.memoryAsk(backendId: "b1", message: "With tools by default"))
        _ = try await api.send(.memoryAsk(backendId: "b1", message: "With tools off", useTools: false))
        let sent = try await transport.requests.map { try XCTUnwrap($0.httpBody) }
        let bodies = try sent.map { try XCTUnwrap(JSONSerialization.jsonObject(with: $0) as? [String: Any]) }
        XCTAssertNil(bodies[0]["use_tools"], "the route lets the model use tools unless it is told not to")
        XCTAssertEqual(bodies[1]["use_tools"] as? Bool, false)
        XCTAssertEqual(bodies[1]["use_recall"] as? Bool, true, "switching tools off leaves recall on")
    }

    func testRecallAndListEndpointsCarryTheBranch() async throws {
        let (api, transport) = client([
            .json(.get, "/api/memories", #"{"query":"q","branch":"ideas","recall_mode":"lexical","results":[],"message":""}"#),
        ])
        _ = try await api.send(.memoryRecall("  ferry times ", branch: "ideas"))
        let allSent = await transport.requests
        let sent = try XCTUnwrap(allSent.first)
        let items = URLComponents(url: try XCTUnwrap(sent.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "q" }?.value, "ferry times")
        XCTAssertEqual(items.first { $0.name == "branch" }?.value, "ideas")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer preview-token")
    }
}
