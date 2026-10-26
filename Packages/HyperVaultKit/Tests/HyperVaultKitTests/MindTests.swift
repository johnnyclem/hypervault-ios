import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HyperVaultKit

/// Fixtures are shaped by app/api/mind/*/route.ts and lib/mind/diff.ts.
final class MindTests: XCTestCase {
    private let base = URL(string: "https://hv.test")!

    private func client(_ routes: [MockRoute]) -> (HVClient, MockTransport) {
        let transport = MockTransport(routes: routes)
        return (HVClient(baseURL: base, transport: transport, tokens: StaticTokenProvider(), retry: .none), transport)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try HVCoding.decoder().decode(type, from: Data(json.utf8))
    }

    // MARK: Branches

    func testBranchesDecodeAndOrderMainFirst() throws {
        let json = #"""
        {"branches":[
          {"id":"b2","name":"research/quantum","is_default":false,"head_commit_id":"c9","created_at":"2026-10-10T00:00:00Z","memory_count":52},
          {"id":"b1","name":"main","is_default":true,"head_commit_id":"c8","created_at":"2026-09-01T00:00:00Z","memory_count":184},
          {"id":"b3","name":"ideas","is_default":false,"head_commit_id":null,"created_at":"2026-10-11T00:00:00Z","memory_count":3}
        ]}
        """#
        let list = try decode(MindBranchList.self, json)
        XCTAssertEqual(list.ordered.map(\.name), ["main", "ideas", "research/quantum"])
        XCTAssertEqual(list.ordered.first?.memoryCount, 184)
        XCTAssertNil(list.branches[2].headCommitId)
    }

    func testBranchNamesFollowTheServersRule() {
        for good in ["ideas", "research/quantum", "a", "x-1_y", "0day"] { XCTAssertTrue(MindBranchName.isValid(good), good) }
        for bad in ["", "Ideas", "-x", "/x", "has space", "dots.here", String(repeating: "a", count: 64), "é"] { XCTAssertFalse(MindBranchName.isValid(bad), bad) }
        XCTAssertTrue(MindBranchName.isValid(String(repeating: "a", count: 63)))
        XCTAssertEqual(MindBranchName.normalized("  My New Idea "), "my-new-idea")
        XCTAssertEqual(MindBranchName.validationMessage(for: "main"), "main already exists. It is the default branch.")
        XCTAssertEqual(MindBranchName.validationMessage(for: "Bad Name"), "Branch names are lowercase letters, digits, and /_- (max 63 chars, must start alphanumeric).")
        XCTAssertEqual(MindBranchName.validationMessage(for: "ideas", existing: ["main", "ideas"]), "A branch named \"ideas\" already exists.")
        XCTAssertNil(MindBranchName.validationMessage(for: "fresh", existing: ["main"]))
    }

    func testBranchCreateAndDelete() async throws {
        let (api, transport) = client([
            .json(.post, "/api/mind/branches", #"{"id":"b4","name":"ideas","from":"main","head_commit_id":"c8","message":"Branched \"ideas\" from main — edits there won't touch main until you merge."}"#),
            .json(.delete, "/api/mind/branches/ideas", #"{"deleted":"ideas","message":"Branch \"ideas\" is gone."}"#),
        ])
        let created = try await api.send(.mindCreateBranch(name: "ideas", from: "main"))
        XCTAssertEqual(created.name, "ideas")
        XCTAssertEqual(created.message, "Branched \"ideas\" from main — edits there won't touch main until you merge.")
        let deleted = try await api.send(.mindDeleteBranch(name: "ideas"))
        XCTAssertEqual(deleted.message, "Branch \"ideas\" is gone.")
        let sent = await transport.requests
        XCTAssertEqual(String(decoding: sent[0].httpBody ?? Data(), as: UTF8.self), #"{"from":"main","name":"ideas"}"#)
        XCTAssertEqual(sent[1].httpMethod, "DELETE")
    }

    func testBranchRefusalsKeepTheirSentences() async {
        let (api, _) = client([
            .failure(.delete, "/api/mind/branches/base", status: 409, message: "Branch \"base\" still has branches forked from it — delete or merge those first."),
            .failure(.delete, "/api/mind/branches/main", status: 400, message: "The default branch cannot be deleted."),
        ])
        for (name, sentence) in [("base", "Branch \"base\" still has branches forked from it — delete or merge those first."), ("main", "The default branch cannot be deleted.")] {
            do {
                _ = try await api.send(.mindDeleteBranch(name: name))
                XCTFail("expected a refusal")
            } catch let error as HVError {
                XCTAssertEqual(error.userMessage, sentence)
            } catch {
                XCTFail("wrong error \(error)")
            }
        }
    }

    func testALogHoldsTheCommitsAndTheMergesItTookIn() throws {
        let log = try decode(MindCommitLog.self, #"""
        {"branch":"main","commits":[
          {"id":"m1","message":"merge ideas into main","author_kind":"user","parent_commit_id":"c2","merge_parent_commit_id":"x2","created_at":"2026-10-25T10:00:00Z"},
          {"id":"c2","message":"memorize: A","author_kind":"user","parent_commit_id":"c1","created_at":"2026-10-24T10:00:00Z"},
          {"id":"c1","message":"genesis","author_kind":"system","created_at":"2026-09-01T10:00:00Z"}]}
        """#)
        XCTAssertTrue(log.holds("c1"), "on the branch")
        XCTAssertTrue(log.holds("m1"))
        XCTAssertTrue(log.holds("x2"), "the other branch's last commit, merged in")
        XCTAssertFalse(log.holds("x1"), "not in what the log shows")
        XCTAssertFalse(MindCommitLog().holds("c1"))
    }

    func testTwoBranchesAreSaidAsHowTheyDifferNotAsWhatAMergeDoes() throws {
        let diff = try decode(MindStateDiff.self, #"""
        {"from":{"ref":"main","commit_id":"c9"},"to":{"ref":"ideas","commit_id":"c13"},
         "memories":{"added":[{"id":"b","title":"B"}],"removed":[{"id":"a","title":"A"},{"id":"a2","title":"A2"}],
           "changed":[{"id":"m","title_from":"M","title_to":"M","tags_added":[],"tags_removed":[],"content_changed":true,"diff":{"hunks":[],"oversize":false}}]},
         "links":{"added":[{"a_id":"a","b_id":"b","kind":"auto"}],"removed":[]}}
        """#)
        XCTAssertEqual(
            diff.differenceSummary(source: "ideas", target: "main"),
            "1\u{00A0}only\u{00A0}on\u{00A0}ideas\u{00A0}\u{00B7} 1\u{00A0}different\u{00A0}\u{00B7} 2\u{00A0}only\u{00A0}on\u{00A0}main\u{00A0}\u{00B7} 1\u{00A0}link\u{00A0}differs"
        )
        XCTAssertFalse(diff.differenceSummary(source: "ideas", target: "main").contains("forgotten"))
        XCTAssertEqual(diff.to.commitId, "c13", "the source's last commit, which the target's log may already hold")
    }

    func testAStateRowCarriesTheRevisionWhenTheServerSendsIt() throws {
        let row = try decode(MindStateMemory.self, #"{"id":"m1","title":"T","revision_id":"r7","committed_at":"2026-10-21T10:00:00Z"}"#)
        XCTAssertEqual(row.revisionId, "r7")
        XCTAssertNil(try decode(MindStateMemory.self, #"{"id":"m1","title":"T"}"#).revisionId)
    }

    // MARK: Commits

    func testCommitLogDecodesAndClassifies() throws {
        let json = #"""
        {"branch":"main","commits":[
          {"id":"3f2a9c1e-0000-4000-8000-000000000001","message":"merge ideas into main","author_kind":"user","parent_commit_id":"p1","merge_parent_commit_id":"p2","created_at":"2026-10-25T10:00:00Z","change_counts":{"created":2,"updated":1,"deleted":0,"links":3}},
          {"id":"c2","message":"memorize: Trip notes","author_kind":"agent","author_key_prefix":"hv_ab12cdef","parent_commit_id":"c1","merge_parent_commit_id":null,"created_at":"2026-10-24T10:00:00Z","change_counts":{"created":1,"updated":0,"deleted":0,"links":2}},
          {"id":"c3","message":"forget: Old idea","author_kind":"user","parent_commit_id":"c2","created_at":"2026-10-23T10:00:00Z","change_counts":{"created":0,"updated":0,"deleted":1,"links":0}},
          {"id":"c4","message":"revert: restore \"Trip\" to revision 1a2b3c4d","author_kind":"user","created_at":"2026-10-22T10:00:00Z","change_counts":{"created":0,"updated":1,"deleted":0,"links":0}},
          {"id":"c5","message":"import (web): Some page","author_kind":"user","created_at":"2026-10-21T10:00:00Z","change_counts":{"created":1,"updated":0,"deleted":0,"links":0}},
          {"id":"c6","message":"link: connect two memories","author_kind":"user","created_at":"2026-10-20T10:00:00Z","change_counts":{"created":0,"updated":0,"deleted":0,"links":1}},
          {"id":"c7","message":"genesis","author_kind":"system","created_at":"2026-09-01T10:00:00Z","change_counts":{"created":40,"updated":0,"deleted":0,"links":0}},
          {"id":"c8","message":"tidy","author_kind":"user","created_at":"2026-09-01T09:00:00Z"}
        ]}
        """#
        let log = try decode(MindCommitLog.self, json)
        XCTAssertEqual(log.commits.count, 8)
        let first = log.commits[0]
        XCTAssertEqual(first.shortId, "3f2a9c1e")
        XCTAssertTrue(first.isMerge)
        XCTAssertEqual(first.kind, .merge)
        XCTAssertEqual(first.changeCounts.summary, "2\u{00A0}added\u{00A0}\u{00B7} 1\u{00A0}edited\u{00A0}\u{00B7} 3\u{00A0}links")
        XCTAssertEqual(first.changeCounts.total, 6)
        XCTAssertEqual(log.commits[1].author, "Agent hv_ab12cdef")
        XCTAssertEqual(log.commits.map(\.kind), [.merge, .memorize, .forget, .revert, .importing, .link, .memorize, .other])
        XCTAssertEqual(log.commits[2].changeCounts.summary, "1\u{00A0}forgotten")
        XCTAssertEqual(log.commits[6].author, "HyperVault")
        XCTAssertEqual(log.commits[7].changeCounts.summary, "")
    }

    // MARK: Diff rendering

    private func hunk(oldStart: Int, oldLines: Int, newStart: Int, newLines: Int, _ lines: [(String, String)]) -> MindDiffHunk {
        MindDiffHunk(oldStart: oldStart, oldLines: oldLines, newStart: newStart, newLines: newLines, lines: lines.map { MindDiffLine(kind: $0.0 == "+" ? .add : $0.0 == "-" ? .del : .ctx, text: $0.1) })
    }

    func testRowsNumberTheLinesAndFoldWhatIsSkipped() {
        let diff = MindTextDiff(hunks: [
            hunk(oldStart: 4, oldLines: 4, newStart: 4, newLines: 5, [(" ", "keep a"), ("-", "old b"), ("+", "new b"), ("+", "extra"), (" ", "keep c"), (" ", "keep d")]),
            hunk(oldStart: 20, oldLines: 3, newStart: 21, newLines: 2, [(" ", "x"), ("-", "gone"), (" ", "y")]),
        ])
        let rows = diff.rows
        XCTAssertEqual(rows.map(\.kind), [.gap, .ctx, .del, .add, .add, .ctx, .ctx, .gap, .ctx, .del, .ctx])
        XCTAssertEqual(rows[0].skipped, 3, "three lines come before the first hunk")
        XCTAssertEqual(rows[1].oldLine, 4)
        XCTAssertEqual(rows[1].newLine, 4)
        XCTAssertEqual(rows[2].oldLine, 5)
        XCTAssertNil(rows[2].newLine)
        XCTAssertNil(rows[3].oldLine)
        XCTAssertEqual(rows[3].newLine, 5)
        XCTAssertEqual(rows[4].newLine, 6)
        XCTAssertEqual(rows[5].oldLine, 6)
        XCTAssertEqual(rows[5].newLine, 7)
        XCTAssertEqual(rows[7].skipped, 12, "lines 8 to 19 sit between the hunks")
        XCTAssertEqual(rows[9].oldLine, 21)
        XCTAssertEqual(rows.map(\.id), Array(0..<rows.count))
        XCTAssertEqual(diff.addedLines, 2)
        XCTAssertEqual(diff.removedLines, 2)
        XCTAssertEqual(diff.summary, "+2 \u{2212}2")
        XCTAssertTrue(diff.hasTextChanges)
    }

    func testRowsDropJsdiffsNoNewlineNote() {
        let diff = MindTextDiff(hunks: [hunk(oldStart: 1, oldLines: 1, newStart: 1, newLines: 1, [("-", "a"), (" ", " No newline at end of file"), ("+", "b"), (" ", " No newline at end of file")])])
        XCTAssertEqual(diff.rows.map(\.kind), [.del, .add])
        XCTAssertEqual(diff.rows.map(\.text), ["a", "b"])
    }

    func testSummariesForTheCasesWithoutHunks() {
        XCTAssertEqual(MindTextDiff().summary, "No text changes")
        XCTAssertFalse(MindTextDiff().hasTextChanges)
        XCTAssertTrue(MindTextDiff().rows.isEmpty)
        XCTAssertEqual(MindTextDiff(oversize: true).summary, "Replaced (too large to compare line by line)")
        XCTAssertTrue(MindTextDiff(oversize: true).hasTextChanges)
    }

    func testStateDiffDecodesTheNestedShape() throws {
        let json = #"""
        {"from":{"ref":"main","commit_id":"c1"},"to":{"ref":"ideas","commit_id":"c2"},
         "memories":{
           "added":[{"id":"m3","title":"New idea","tags":["x"]}],
           "removed":[{"id":"m4","title":"Old idea","tags":[]}],
           "changed":[{"id":"m1","title_from":"Trip","title_to":"Trip notes","tags_added":["ferry"],"tags_removed":[],"content_changed":true,
             "diff":{"hunks":[{"oldStart":1,"oldLines":1,"newStart":1,"newLines":2,"lines":[{"kind":"del","text":"a"},{"kind":"add","text":"b"},{"kind":"add","text":"c"}]}],"oversize":false}}]},
         "links":{"added":[{"a_id":"m1","b_id":"m3","kind":"auto"}],"removed":[{"a_id":"m4","b_id":"m1","kind":"manual"}]}}
        """#
        let diff = try decode(MindStateDiff.self, json)
        XCTAssertEqual(diff.from.ref, "main")
        XCTAssertEqual(diff.to.commitId, "c2")
        XCTAssertEqual(diff.added.map(\.id), ["m3"])
        XCTAssertEqual(diff.removed.first?.title, "Old idea")
        let change = try XCTUnwrap(diff.changed.first)
        XCTAssertTrue(change.renamed)
        XCTAssertEqual(change.tagsAdded, ["ferry"])
        XCTAssertEqual(change.diff.summary, "+2 \u{2212}1")
        XCTAssertEqual(diff.linksAdded.first?.id, "m1:m3")
        XCTAssertEqual(diff.linksRemoved.first?.kind, "manual")
        XCTAssertEqual(diff.summary, "1\u{00A0}added\u{00A0}\u{00B7} 1\u{00A0}edited\u{00A0}\u{00B7} 1\u{00A0}forgotten\u{00A0}\u{00B7} 2\u{00A0}link\u{00A0}changes")
        // A line can only break after a dot, never inside an item or before a dot.
        XCTAssertEqual(diff.summary.split(separator: " ").count, 4)
        XCTAssertFalse(diff.isEmpty)
        XCTAssertEqual(diff.titles["m1"], "Trip notes")
        XCTAssertEqual(diff.titles["m4"], "Old idea")
        // Round trip through the cache.
        let data = try HVCoding.encoder(.verbatim).encode(diff)
        XCTAssertEqual(try HVCoding.decoder(.verbatim).decode(MindStateDiff.self, from: data), diff)
    }

    func testAnEmptyDiffIsEmpty() throws {
        let diff = try decode(MindStateDiff.self, #"{"from":{"ref":"a","commit_id":"1"},"to":{"ref":"b","commit_id":"1"},"memories":{"added":[],"removed":[],"changed":[]},"links":{"added":[],"removed":[]}}"#)
        XCTAssertTrue(diff.isEmpty)
        XCTAssertEqual(diff.summary, "")
    }

    func testMemoryDiffAndRefs() async throws {
        let json = #"{"from":{"ref":"c1","commit_id":"c1"},"to":{"ref":"c2","commit_id":"c2"},"memory_id":"m1","title_from":"Trip","title_to":"Trip notes","tags_added":["ferry"],"tags_removed":[],"status":"changed","diff":{"hunks":[],"oversize":false}}"#
        let (api, transport) = client([.json(.get, "/api/mind/diff", json)])
        let diff = try await api.send(.mindMemoryDiff(from: .commit("c1"), to: .commit("c2"), memoryId: "m1"))
        XCTAssertEqual(diff.status, .changed)
        XCTAssertEqual(diff.titleTo, "Trip notes")
        let moment = HVDate.parse("2026-10-01T09:30:00Z")!
        _ = try await api.send(.mindDiff(from: .branch("main"), to: .moment(moment), branch: "ideas"))
        let sent = await transport.requests
        let first = URLComponents(url: sent[0].url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(first.first { $0.name == "memory_id" }?.value, "m1")
        XCTAssertEqual(first.first { $0.name == "from" }?.value, "c1")
        let second = URLComponents(url: sent[1].url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(second.first { $0.name == "to" }?.value, "2026-10-01T09:30:00.000Z")
        XCTAssertEqual(second.first { $0.name == "branch" }?.value, "ideas")
        XCTAssertEqual(MindRef.commit("3f2a9c1e-0000-4000").label, "3f2a9c1e")
        XCTAssertEqual(MindRef.branch("main").label, "main")
    }

    func testACompareFieldNamesTheKindOfAMomentAndNotItsDate() throws {
        let commits = try decode(MindCommitLog.self, #"{"branch":"main","commits":[{"id":"8b41d07a-2c93-4f55-a6e0-1d7c93b4e802","message":"memorize: Passport checklist","author_kind":"user","created_at":"2026-10-24T10:00:00Z"}]}"#).commits
        XCTAssertEqual(MindRef.branch("ideas").fieldText(commits: commits), "ideas")
        XCTAssertEqual(MindRef.commit("8b41d07a-2c93-4f55-a6e0-1d7c93b4e802").fieldText(commits: commits), "memorize: Passport checklist (8b41d07a)")
        XCTAssertEqual(MindRef.commit("c92e5f13-aa6d-4b08").fieldText(commits: commits), "Commit c92e5f13", "a commit that is not in the list yet")
        XCTAssertEqual(MindRef.moment(Date(timeIntervalSince1970: 1_792_054_800)).fieldText(), "A moment in time")
    }

    // MARK: Time travel and revert

    func testTimeTravelState() async throws {
        let json = #"""
        {"at":"2026-10-01T00:00:00.000Z","commit_id":"c3","memories":[
          {"id":"m1","title":"Trip","summary":"s","tags":["trip"],"source":"manual","committed_at":"2026-09-30T10:00:00Z"}],
         "links":[{"a_id":"m1","b_id":"m2","kind":"auto"}],
         "message":"Your mind held 1 memory and 1 link at that point."}
        """#
        let (api, transport) = client([.json(.get, "/api/mind/state", json)])
        let state = try await api.send(.mindState(at: .moment(HVDate.parse("2026-10-01T00:00:00Z")!), branch: "main"))
        XCTAssertEqual(state.memories.first?.title, "Trip")
        XCTAssertEqual(state.links.count, 1)
        XCTAssertEqual(state.message, "Your mind held 1 memory and 1 link at that point.")
        let sent = await transport.requests
        XCTAssertTrue(sent[0].url?.query?.contains("at=2026-10-01T00:00:00.000Z") == true)
    }

    func testRevertAndUnforget() async throws {
        let (api, transport) = client([.json(.post, "/api/mind/revert", #"{"commit_id":"c9","restored":{"memory_id":"m1","memory_title":"x","title":"Trip notes","revision_id":"r2"},"branch":"main","message":"Unforgotten — \"Trip notes\" is back in your wiki."}"#)])
        let result = try await api.send(.mindRevert(memoryId: "m1", revisionId: "r2", branch: "main"))
        XCTAssertEqual(result.title, "Trip notes")
        XCTAssertEqual(result.memoryId, "m1")
        XCTAssertEqual(result.message, "Unforgotten — \"Trip notes\" is back in your wiki.")
        let sent = await transport.requests
        XCTAssertEqual(String(decoding: sent[0].httpBody ?? Data(), as: UTF8.self), #"{"branch":"main","memory_id":"m1","revision_id":"r2"}"#)
    }

    // MARK: Merging

    private func snapshot(_ id: String, _ title: String, _ content: String, tags: [String] = []) -> MindSnapshot {
        MindSnapshot(memoryId: id, title: title, content: content, summary: content, tags: tags)
    }

    private func conflict(_ id: String, ours: String?, theirs: String?) -> MindMergeConflict {
        MindMergeConflict(
            memoryId: id,
            base: snapshot(id, "Base", "one\ntwo"),
            ours: ours.map { snapshot(id, "Ours", $0, tags: ["a"]) },
            theirs: theirs.map { snapshot(id, "Theirs", $0, tags: ["b"]) }
        )
    }

    func testConflictsTellWhatHappened() {
        XCTAssertEqual(conflict("x", ours: "a", theirs: "b").situation, .bothEdited)
        XCTAssertEqual(conflict("x", ours: nil, theirs: "b").situation, .forgottenHere)
        XCTAssertEqual(conflict("x", ours: "a", theirs: nil).situation, .forgottenThere)
        XCTAssertEqual(conflict("x", ours: nil, theirs: "b").title, "Theirs")
    }

    func testKeepBothStartsFromOursAndAddsTheirNewLines() {
        let both = conflict("x", ours: "one\nours only\nshared", theirs: "shared\ntheirs only\n\none")
        XCTAssertEqual(both.combinedContent, "one\nours only\nshared\ntheirs only")
        XCTAssertEqual(both.combinedTags, ["a", "b"])
        XCTAssertEqual(conflict("x", ours: nil, theirs: "only theirs").combinedContent, "only theirs")
        XCTAssertEqual(conflict("x", ours: "only ours", theirs: nil).combinedContent, "only ours")
    }

    func testSessionCollectsAnAnswerForEveryConflictBeforeItCanMerge() {
        var session = MindMergeSession(source: "ideas")
        XCTAssertEqual(session.target, "main")
        XCTAssertTrue(session.canMerge, "the first attempt has nothing to resolve")
        XCTAssertFalse(session.hasConflicts)

        session.receive([conflict("a", ours: "1", theirs: "2"), conflict("b", ours: nil, theirs: "3"), conflict("c", ours: "4", theirs: nil)])
        XCTAssertTrue(session.hasConflicts)
        XCTAssertFalse(session.canMerge)
        XCTAssertEqual(session.unresolved.map(\.memoryId), ["a", "b", "c"])
        XCTAssertEqual(session.nextUnresolved(after: nil)?.memoryId, "a")

        session.resolve("a", .theirs)
        XCTAssertEqual(session.resolvedCount, 1)
        XCTAssertEqual(session.nextUnresolved(after: "a")?.memoryId, "b")
        XCTAssertEqual(session.nextUnresolved(after: "c")?.memoryId, "b", "it wraps round to what is still open")

        session.resolve("zzz", .ours)  // not a conflict of this merge
        XCTAssertNil(session.resolution(for: "zzz"))

        session.resolveRemaining(.ours)
        XCTAssertTrue(session.canMerge)
        XCTAssertEqual(session.resolution(for: "a"), .theirs, "bulk choices do not overwrite a pick")
        XCTAssertEqual(session.resolution(for: "b"), .ours)
        XCTAssertNil(session.nextUnresolved(after: "b"))

        session.unresolve("b")
        XCTAssertFalse(session.canMerge)
        XCTAssertEqual(session.unresolved.map(\.memoryId), ["b"])
    }

    func testAnotherRoundOfConflictsAddsToTheSession() {
        var session = MindMergeSession(source: "ideas")
        session.receive([conflict("a", ours: "1", theirs: "2")])
        session.resolve("a", .ours)
        session.receive([conflict("d", ours: "5", theirs: "6")])
        XCTAssertEqual(session.conflicts.map(\.memoryId), ["a", "d"])
        XCTAssertEqual(session.resolution(for: "a"), .ours, "an answer stands")
        XCTAssertEqual(session.unresolved.map(\.memoryId), ["d"])
        // A conflict the server lists again was not settled after all.
        session.receive([conflict("a", ours: "1", theirs: "7")])
        XCTAssertNil(session.resolution(for: "a"))
    }

    func testRequestBodyCarriesEveryResolutionVerbatim() throws {
        var session = MindMergeSession(source: "research/quantum", target: "main")
        XCTAssertEqual(session.requestBody()["resolutions"]?.array?.count, 0)
        session.receive([conflict("b", ours: "1", theirs: "2"), conflict("a", ours: "3", theirs: "4"), conflict("c", ours: "5", theirs: nil)])
        session.resolve("b", .theirs)
        session.resolve("a", .custom(title: "Both", content: "merged", tags: ["x", "y"]))
        session.resolve("c", .ours)
        session.message = "  settle it  "
        let body = session.requestBody()
        XCTAssertEqual(body["source"]?.string, "research/quantum")
        XCTAssertEqual(body["target"]?.string, "main")
        XCTAssertEqual(body["message"]?.string, "settle it")
        let resolutions = try XCTUnwrap(body["resolutions"]?.array)
        XCTAssertEqual(resolutions.compactMap { $0["memory_id"]?.string }, ["a", "b", "c"], "in a steady order")
        XCTAssertEqual(resolutions[0]["resolution"]?["title"]?.string, "Both")
        XCTAssertEqual(resolutions[0]["resolution"]?["content"]?.string, "merged")
        XCTAssertEqual(resolutions[0]["resolution"]?["tags"]?.array?.compactMap(\.string), ["x", "y"])
        XCTAssertEqual(resolutions[1]["resolution"]?.string, "theirs")
        XCTAssertEqual(resolutions[2]["resolution"]?.string, "ours")
        session.message = ""
        XCTAssertNil(session.requestBody()["message"])
    }

    func testDescriptionsReadAsWhatWillHappen() {
        var session = MindMergeSession(source: "ideas")
        let both = conflict("a", ours: "1", theirs: "2")
        let forgottenHere = conflict("b", ours: nil, theirs: "2")
        let forgottenThere = conflict("c", ours: "1", theirs: nil)
        session.receive([both, forgottenHere, forgottenThere])
        XCTAssertEqual(session.describe(.ours, for: both), "Keep the version on main")
        XCTAssertEqual(session.describe(.theirs, for: both), "Take the version from ideas")
        XCTAssertEqual(session.describe(.ours, for: forgottenHere), "Keep it forgotten on main")
        XCTAssertEqual(session.describe(.theirs, for: forgottenThere), "Forget it, as ideas did")
        XCTAssertEqual(session.describe(.custom(title: "t", content: "c", tags: nil), for: both), "Your own version")
    }

    private let conflictBody = #"""
    {"error":"Merge has 2 conflicts — resolve and resubmit.","conflicts":[
      {"memory_id":"m1","base":{"memory_id":"m1","title":"Trip","content":"one\ntwo","summary":"one two","tags":["trip"],"source":"manual"},
       "ours":{"memory_id":"m1","title":"Trip (main)","content":"one\nthree","summary":"one three","tags":["trip"],"source":"manual"},
       "theirs":{"memory_id":"m1","title":"Trip (ideas)","content":"one\nfour","summary":"one four","tags":["trip","ferry"],"source":"manual"},
       "hunks_ours":{"hunks":[{"oldStart":1,"oldLines":2,"newStart":1,"newLines":2,"lines":[{"kind":"ctx","text":"one"},{"kind":"del","text":"two"},{"kind":"add","text":"three"}]}],"oversize":false},
       "hunks_theirs":{"hunks":[{"oldStart":1,"oldLines":2,"newStart":1,"newLines":2,"lines":[{"kind":"ctx","text":"one"},{"kind":"del","text":"two"},{"kind":"add","text":"four"}]}],"oversize":false}},
      {"memory_id":"m2","base":{"memory_id":"m2","title":"Keep","content":"x","summary":"x","tags":[],"source":"manual"},"ours":null,
       "theirs":{"memory_id":"m2","title":"Keep!","content":"xx","summary":"xx","tags":[],"source":"manual"},
       "hunks_ours":{"hunks":[],"oversize":false},"hunks_theirs":{"hunks":[],"oversize":false}}]}
    """#

    func testMergerTurnsA409IntoConflictsAndTheRetryIntoAMerge() async throws {
        let calls = MergeCalls()
        let transport = MockTransport()
        let conflictBody = self.conflictBody
        await transport.add(MockRoute(.post, "/api/mind/merge") { request in
            let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]) ?? [:]
            let resolutions = body["resolutions"] as? [[String: Any]] ?? []
            calls.record(resolutions.count)
            if resolutions.count < 2 { return HTTPResponse(status: 409, data: Data(conflictBody.utf8)) }
            return HTTPResponse(status: 200, data: Data(#"{"commit_id":"c10","merged":{"created":0,"updated":2,"deleted":0},"links_changed":1,"message":"Merged ideas into main: 0 new, 2 updated, 0 forgotten, 1 link change."}"#.utf8))
        })
        let api = HVClient(baseURL: base, transport: transport, tokens: StaticTokenProvider(), retry: .none)
        let merger = MindMerger(client: api)

        var session = MindMergeSession(source: "ideas")
        guard case .conflicts(let message, let conflicts) = try await merger.attempt(session) else { return XCTFail("expected conflicts") }
        XCTAssertEqual(message, "Merge has 2 conflicts — resolve and resubmit.")
        XCTAssertEqual(conflicts.map(\.memoryId), ["m1", "m2"])
        XCTAssertEqual(conflicts[0].hunksOurs.addedLines, 1)
        XCTAssertNil(conflicts[1].ours)
        XCTAssertEqual(conflicts[1].situation, .forgottenHere)

        session.receive(conflicts)
        session.resolve("m1", .custom(title: "Trip", content: "one\nthree\nfour", tags: nil))
        session.resolve("m2", .theirs)
        guard case .merged(let result) = try await merger.attempt(session) else { return XCTFail("expected a merge") }
        XCTAssertEqual(result.commitId, "c10")
        XCTAssertEqual(result.updated, 2)
        XCTAssertEqual(result.linksChanged, 1)
        XCTAssertFalse(result.isNoOp)
        XCTAssertEqual(calls.counts, [0, 2])
    }

    func testOtherRefusalsAreNotConflicts() async {
        let (api, _) = client([
            .json(.post, "/api/mind/merge", #"{"error":"The target branch moved while merging — try again."}"#, status: 409),
        ])
        do {
            _ = try await MindMerger(client: api).attempt(MindMergeSession(source: "ideas"))
            XCTFail("expected a refusal")
        } catch let error as HVError {
            XCTAssertEqual(error.status, 409)
            XCTAssertEqual(error.userMessage, "The target branch moved while merging — try again.")
        } catch {
            XCTFail("wrong error \(error)")
        }
    }

    func testNothingToMerge() async throws {
        let (api, _) = client([.json(.post, "/api/mind/merge", #"{"commit_id":null,"merged":{"created":0,"updated":0,"deleted":0},"links_changed":0,"message":"Already up to date — main contains everything on ideas."}"#)])
        guard case .merged(let result) = try await MindMerger(client: api).attempt(MindMergeSession(source: "ideas")) else { return XCTFail("expected a result") }
        XCTAssertTrue(result.isNoOp)
        XCTAssertEqual(result.message, "Already up to date — main contains everything on ideas.")
    }
}

private final class MergeCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []

    func record(_ count: Int) {
        lock.lock(); defer { lock.unlock() }
        values.append(count)
    }

    var counts: [Int] {
        lock.lock(); defer { lock.unlock() }
        return values
    }
}
