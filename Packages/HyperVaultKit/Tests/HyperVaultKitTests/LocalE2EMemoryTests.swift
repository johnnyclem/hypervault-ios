import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HyperVaultKit

// The memory wiki and "Git for a Mind": create, recall, edit, forget, bring back, branches, commits, compare,
// time travel, merge with and without conflicts, revert.

final class LocalE2EMemoryTests: LocalE2ECase {

    // MARK: Memories

    func testMemorizeListReadSearchEditForgetAndBringBack() async throws {
        let (api, _) = member(14)
        let word = uniqueWord()
        let draft = MemoryDraft(content: "The \(word) protocol: always ask twice.\nSecond line about quokkas.", title: "Protocol \(word)", tagsText: "e2e, \(word)")
        let (kept, keptRaw) = try await fetch(.memoryCreate(draft), api)
        XCTAssertEqual(kept.id, keptRaw["id"]?.string)
        XCTAssertEqual(kept.title, "Protocol \(word)")
        // The server adds keyword tags of its own to the ones given.
        XCTAssertTrue(Set(["e2e", word]).isSubset(of: Set(kept.tags)), "tags: \(kept.tags)")
        XCTAssertEqual(kept.branch, "main")
        XCTAssertNotNil(kept.commitId, "a memory is a commit")
        XCTAssertFalse(kept.summary.isEmpty)
        XCTAssertEqual(kept.source, "manual")

        // The list is main, newest first, with the same row.
        let (list, listRaw) = try await fetch(.memoryList(), api)
        XCTAssertEqual(list.branch, "main")
        XCTAssertEqual(list.memories.count, rawCount(listRaw, "memories"))
        let row = try XCTUnwrap(list.memories.first { $0.id == kept.id })
        XCTAssertEqual(row.title, kept.title)
        XCTAssertEqual(Set(row.tags), Set(kept.tags))
        XCTAssertEqual(row.summary, kept.summary)
        XCTAssertNotNil(row.createdAt)

        // The page: content, revision count, provenance, no related yet.
        let (page, pageRaw) = try await fetch(.memoryPage(id: kept.id), api)
        XCTAssertEqual(page.memory.id, kept.id)
        XCTAssertTrue(page.memory.content.contains("quokkas"))
        XCTAssertEqual(page.branch, "main")
        XCTAssertEqual(page.revisionCount, 1)
        XCTAssertEqual(page.provenance?.commitId, kept.commitId)
        XCTAssertEqual(page.provenance?.authorKind, .user)
        XCTAssertEqual(page.related.count, rawCount(pageRaw, "related"))
        XCTAssertEqual(page.artifacts.count, rawCount(pageRaw, "artifacts"))

        // Recall finds it by a word in the body; a word nowhere finds nothing.
        let (recall, recallRaw) = try await fetch(.memoryRecall(word), api)
        XCTAssertEqual(recall.results.count, rawCount(recallRaw, "results"))
        let hit = try XCTUnwrap(recall.results.first { $0.id == kept.id }, "recall did not find the memory by its word")
        XCTAssertGreaterThan(hit.score, 0)
        XCTAssertEqual(recall.branch, "main")
        XCTAssertEqual(recall.recallMode, .lexical, "no embedding backend is connected, so recall is lexical")
        XCTAssertEqual(hit.provenance?.commitId, kept.commitId)
        let none = try await send(.memoryRecall(uniqueWord()), api)
        XCTAssertTrue(none.results.isEmpty)

        // Edit: title and content and tags, with a message; the page and the history follow.
        let request = try XCTUnwrap(MemoryEditRequest.make(
            original: page.memory, title: "Protocol \(word) v2", content: "The \(word) protocol: always ask THREE times.",
            tags: ["e2e", "revised"], message: "tighten it"
        ))
        let edited = try await send(.memoryEdit(id: kept.id, request), api)
        XCTAssertEqual(edited.id, kept.id)
        XCTAssertEqual(edited.title, "Protocol \(word) v2")
        XCTAssertEqual(Set(edited.tags), ["e2e", "revised"])
        XCTAssertNotNil(edited.commitId)
        XCTAssertNotEqual(edited.commitId, kept.commitId)
        let page2 = try await send(.memoryPage(id: kept.id), api)
        XCTAssertTrue(page2.memory.content.contains("THREE"))
        XCTAssertEqual(page2.revisionCount, 2)

        let (history, historyRaw) = try await fetch(.memoryHistory(id: kept.id, full: true), api)
        XCTAssertEqual(history.memoryId, kept.id)
        XCTAssertEqual(history.revisions.count, rawCount(historyRaw, "revisions"))
        XCTAssertEqual(history.revisions.count, 2)
        XCTAssertEqual(history.revisions.first?.op, .update)
        XCTAssertEqual(history.revisions.last?.op, .create)
        XCTAssertEqual(history.revisions.first?.commit?.message, "tighten it")
        XCTAssertTrue(history.revisions.last?.content?.contains("ask twice") ?? false)

        // An edit that changes nothing is refused by the server and the Kit never builds one.
        XCTAssertNil(MemoryEditRequest.make(original: page2.memory, title: page2.memory.title, content: page2.memory.content, tags: page2.memory.tags))

        // Forget: gone from the list and the page; the history keeps the delete.
        let forgotten = try await send(.memoryForget(id: kept.id), api)
        XCTAssertEqual(forgotten.deleted, kept.id)
        XCTAssertEqual(forgotten.branch, "main")
        let after = try await send(.memoryList(), api)
        XCTAssertNil(after.memories.first { $0.id == kept.id })
        await expectFailure(404, .memoryPage(id: kept.id), api)
        let hist2 = try await send(.memoryHistory(id: kept.id, full: true), api)
        XCTAssertEqual(hist2.revisions.first?.op, .delete)
        let live = try XCTUnwrap(hist2.lastLive, "no live revision to bring back")
        XCTAssertEqual(live.title, "Protocol \(word) v2")
        await expectFailure(404, .memoryForget(id: kept.id), api)

        // Bring it back: a revert lands as a new commit and the memory is whole again.
        let reverted = try await send(.mindRevert(memoryId: kept.id, revisionId: live.revisionId), api)
        XCTAssertEqual(reverted.memoryId, kept.id)
        XCTAssertEqual(reverted.title, "Protocol \(word) v2")
        XCTAssertFalse(reverted.commitId.isEmpty)
        let back = try await send(.memoryPage(id: kept.id), api)
        XCTAssertTrue(back.memory.content.contains("THREE"))
        let hist3 = try await send(.memoryHistory(id: kept.id), api)
        XCTAssertEqual(hist3.revisions.first?.op, .create, "an undelete is a restore")
    }

    func testImportingAFileMakesAMemory() async throws {
        let (api, _) = member(14)
        let word = uniqueWord()
        let text = "# Notes \(word)\n\nA file about \(word) to memorize."
        let kept = try await send(.memoryImport(filename: "notes-\(word).md", data: Data(text.utf8)), api)
        XCTAssertFalse(kept.id.isEmpty)
        XCTAssertEqual(kept.branch, "main")
        XCTAssertEqual(kept.source, "file")
        let page = try await send(.memoryPage(id: kept.id), api)
        XCTAssertTrue(page.memory.content.contains(word))
        XCTAssertEqual(page.memory.source, "file")
        XCTAssertEqual(MemorySource.label(page.memory.source), page.memory.sourceLabel)
        let found = try await send(.memoryRecall(word), api)
        XCTAssertTrue(found.results.contains { $0.id == kept.id })
    }

    func testMemoriesAreConnectedAndTheGraphReadsBack() async throws {
        let (api, _) = member(14)
        let word = uniqueWord()
        let a = try await send(.memoryCreate(MemoryDraft(content: "Giraffes ruminate slowly \(word)", title: "A \(word)")), api)
        let b = try await send(.memoryCreate(MemoryDraft(content: "Submarines descend quietly", title: "B \(word)")), api)
        let connected = try await send(.memoryConnect(source: a.id, target: b.id), api)
        XCTAssertFalse(connected.message.isEmpty)
        XCTAssertTrue(connected.connected.contains(b.id) || connected.connected.contains(a.id), "\(connected.connected)")
        let (graph, raw) = try await fetch(.memoryConnections, api)
        XCTAssertEqual(graph.memoryLinks.count, rawCount(raw, "memory_links"))
        XCTAssertEqual(graph.bridges.count, rawCount(raw, "memory_artifact_links"))
        let pair = Set([a.id, b.id])
        let link = try XCTUnwrap(graph.memoryLinks.first { Set([$0.aId, $0.bId]) == pair }, "the link is missing from the graph")
        XCTAssertTrue([.manual, .auto].contains(link.kind))
        let page = try await send(.memoryPage(id: a.id), api)
        XCTAssertTrue(page.related.contains { $0.id == b.id }, "the page does not list the connected memory")
        let backends = try await send(.memoryAskBackends, api)
        XCTAssertTrue(backends.isEmpty, "no chat backend is connected for this person")
    }

    func testAMemoryCannotBeEmptyOrOverTheLimit() async throws {
        let (api, _) = member(14)
        let caps = try await send(.capabilities, api)
        await expectFailure(400, .memoryCreate(MemoryDraft(content: "   ")), api)
        let tooBig = String(repeating: "x", count: caps.limits.memoryBytes + 10)
        let failure = await expectFailure(413, .memoryCreate(MemoryDraft(content: tooBig)), api)
        XCTAssertNotNil(failure)
        await expectFailure(404, .memoryPage(id: "00000000-0000-4000-8000-000000000000"), api)
        await expectFailure(404, .memoryPage(id: "not-a-uuid"), api)
    }

    // MARK: Branches, commits, compare, time travel

    func testBranchesCommitsCompareAndTimeTravel() async throws {
        let (api, _) = member(15)
        let word = uniqueWord()
        let branchName = "research/\(word)"
        let base = try await send(.memoryCreate(MemoryDraft(content: "Base fact \(word)", title: "Base \(word)")), api)
        let before = Date()
        try await Task.sleep(nanoseconds: 1_100_000_000)

        // Create the branch (a name with a slash travels as one path part).
        let (branches0, raw0) = try await fetch(.mindBranches, api)
        XCTAssertEqual(branches0.branches.count, rawCount(raw0, "branches"))
        let main = try XCTUnwrap(branches0.branches.first { $0.name == "main" })
        XCTAssertTrue(main.isDefault)
        XCTAssertNotNil(main.headCommitId)
        XCTAssertGreaterThanOrEqual(main.memoryCount, 1)
        let created = try await send(.mindCreateBranch(name: branchName), api)
        XCTAssertEqual(created.name, branchName)
        XCTAssertEqual(created.from, "main")
        let branches = try await send(.mindBranches, api)
        let branch = try XCTUnwrap(branches.branches.first { $0.name == branchName })
        XCTAssertFalse(branch.isDefault)
        XCTAssertEqual(branch.headCommitId, main.headCommitId, "a new branch starts at the head of main")
        XCTAssertEqual(branch.memoryCount, main.memoryCount)
        await expectFailure(409, .mindCreateBranch(name: branchName), api)
        await expectFailure(404, .mindCreateBranch(name: "x\(word)", from: "no-such-branch"), api)
        XCTAssertNotNil(MindBranchName.validationMessage(for: "has space"))

        // A memory kept on the branch is only on the branch.
        let side = try await send(.memoryCreate(MemoryDraft(content: "Side finding \(word)", title: "Side \(word)"), branch: branchName), api)
        XCTAssertEqual(side.branch, branchName)
        let onBranch = try await send(.memoryList(branch: branchName), api)
        XCTAssertEqual(onBranch.branch, branchName)
        XCTAssertTrue(onBranch.memories.contains { $0.id == side.id })
        XCTAssertTrue(onBranch.memories.contains { $0.id == base.id })
        let onMain = try await send(.memoryList(), api)
        XCTAssertNil(onMain.memories.first { $0.id == side.id }, "a branch's memory leaked onto main")
        let recallOnBranch = try await send(.memoryRecall("Side finding \(word)", branch: branchName), api)
        XCTAssertTrue(recallOnBranch.results.contains { $0.id == side.id }, "recall on a branch")
        let recallOnMain = try await send(.memoryRecall("Side finding \(word)"), api)
        XCTAssertFalse(recallOnMain.results.contains { $0.id == side.id })

        // Commits: newest first, first-parent, with change counts.
        let (log, logRaw) = try await fetch(.mindCommits(branch: branchName), api)
        XCTAssertEqual(log.branch, branchName)
        XCTAssertEqual(log.commits.count, rawCount(logRaw, "commits"))
        let tip = try XCTUnwrap(log.commits.first)
        XCTAssertEqual(tip.id, side.commitId)
        XCTAssertEqual(tip.changeCounts.created, 1)
        XCTAssertEqual(tip.kind, .memorize)
        XCTAssertEqual(tip.authorKind, .user)
        XCTAssertNotNil(tip.createdAt)
        XCTAssertEqual(tip.parentCommitId, log.commits.dropFirst().first?.id)
        let limited = try await send(.mindCommits(branch: branchName, limit: 1), api)
        XCTAssertEqual(limited.commits.count, 1)

        // Compare: main to the branch shows the memory added.
        let diff = try await send(.mindDiff(from: .branch("main"), to: .branch(branchName)), api)
        XCTAssertEqual(diff.added.map(\.id), [side.id])
        XCTAssertTrue(diff.removed.isEmpty)
        XCTAssertEqual(diff.added.first?.title, "Side \(word)")
        let reverse = try await send(.mindDiff(from: .branch(branchName), to: .branch("main")), api)
        XCTAssertEqual(reverse.removed.map(\.id), [side.id])
        let byCommit = try await send(.mindDiff(from: .commit(try XCTUnwrap(main.headCommitId)), to: .commit(tip.id)), api)
        XCTAssertEqual(byCommit.added.map(\.id), [side.id])

        // Time travel: a moment before the side memory, and the state at a commit.
        let atTip = try await send(.mindState(at: .commit(tip.id)), api)
        XCTAssertEqual(atTip.commitId, tip.id)
        XCTAssertTrue(atTip.memories.contains { $0.id == side.id })
        let atBranch = try await send(.mindState(at: .branch(branchName)), api)
        XCTAssertEqual(atBranch.commitId, tip.id)
        let beforeSide = try await send(.mindState(at: .moment(before), branch: branchName), api)
        XCTAssertTrue(beforeSide.memories.contains { $0.id == base.id })
        XCTAssertFalse(beforeSide.memories.contains { $0.id == side.id }, "time travel showed a memory from the future")
        await expectFailure(404, .mindState(at: .branch("nowhere-\(word)")), api)

        // A memory's own diff between two points.
        let edited = try await send(.memoryEdit(id: base.id, MemoryEditRequest(title: nil, content: "Base fact \(word), amended", tags: nil, branch: branchName, message: nil)), api)
        XCTAssertEqual(edited.branch, branchName)
        let memoryDiff = try await send(.mindMemoryDiff(from: .branch("main"), to: .branch(branchName), memoryId: base.id), api)
        XCTAssertEqual(memoryDiff.memoryId, base.id)
        XCTAssertEqual(memoryDiff.status, .changed)
        XCTAssertFalse(memoryDiff.diff.hunks.isEmpty)

        // Delete the branch; main keeps its own.
        let deleted = try await send(.mindDeleteBranch(name: branchName), api)
        XCTAssertEqual(deleted.deleted, branchName)
        await expectFailure(404, .mindDeleteBranch(name: branchName), api)
        await expectFailure(400, .mindDeleteBranch(name: "main"), api)
    }

    func testMergeWithoutAndWithConflictsAndRevert() async throws {
        let (api, _) = member(15)
        let word = uniqueWord()
        let shared = try await send(.memoryCreate(MemoryDraft(content: "line one\nline two\nline three \(word)", title: "Shared \(word)")), api)
        let featureName = "feature-\(word)"
        _ = try await send(.mindCreateBranch(name: featureName), api)

        // Fast, clean merge: the branch added a memory.
        let added = try await send(.memoryCreate(MemoryDraft(content: "Only on the feature \(word)", title: "Added \(word)"), branch: featureName), api)
        var session = MindMergeSession(source: featureName)
        let merger = MindMerger(client: api)
        guard case .merged(let result) = try await merger.attempt(session) else { return XCTFail("a clean merge reported conflicts") }
        XCTAssertFalse(result.isNoOp)
        XCTAssertEqual(result.created, 1)
        XCTAssertNotNil(result.commitId)
        XCTAssertFalse(result.message.isEmpty)
        let main = try await send(.memoryList(), api)
        XCTAssertTrue(main.memories.contains { $0.id == added.id }, "the merge did not bring the memory to main")
        let mainLog = try await send(.mindCommits(limit: 1), api)
        XCTAssertEqual(mainLog.commits.first?.id, result.commitId)
        XCTAssertTrue(mainLog.commits.first?.isMerge ?? false)
        XCTAssertEqual(mainLog.commits.first?.kind, .merge)

        // Merging again has nothing to do.
        guard case .merged(let again) = try await merger.attempt(session) else { return XCTFail("a no-op merge reported conflicts") }
        XCTAssertTrue(again.isNoOp)

        // Both sides edit the same memory: a conflict the Kit reads from the 409.
        _ = try await send(.memoryEdit(id: shared.id, MemoryEditRequest(title: nil, content: "line one\nline two CHANGED ON MAIN\nline three \(word)", tags: nil, branch: nil, message: nil)), api)
        _ = try await send(.memoryEdit(id: shared.id, MemoryEditRequest(title: nil, content: "line one\nline two CHANGED ON FEATURE\nline three \(word)", tags: nil, branch: featureName, message: nil)), api)
        session = MindMergeSession(source: featureName)
        guard case .conflicts(let message, let conflicts) = try await merger.attempt(session) else { return XCTFail("a conflicting merge went through") }
        XCTAssertFalse(message.isEmpty)
        XCTAssertEqual(conflicts.map(\.memoryId), [shared.id])
        let conflict = conflicts[0]
        XCTAssertEqual(conflict.situation, .bothEdited)
        XCTAssertTrue(conflict.base?.content.contains("line two\n") ?? false)
        XCTAssertTrue(conflict.ours?.content.contains("CHANGED ON MAIN") ?? false)
        XCTAssertTrue(conflict.theirs?.content.contains("CHANGED ON FEATURE") ?? false)
        XCTAssertFalse(conflict.hunksOurs.hunks.isEmpty)
        XCTAssertFalse(conflict.hunksTheirs.hunks.isEmpty)

        session.receive(conflicts)
        XCTAssertFalse(session.canMerge)
        // The server insists on an answer for every conflict.
        let mainBefore = try await send(.memoryPage(id: shared.id), api)
        session.resolve(shared.id, .custom(title: "Shared \(word) merged", content: "line one\nline two BOTH\nline three \(word)", tags: ["merged"]))
        session.message = "merge by hand"
        XCTAssertTrue(session.canMerge)
        guard case .merged(let resolved) = try await merger.attempt(session) else { return XCTFail("a resolved merge still reported conflicts") }
        XCTAssertEqual(resolved.updated, 1)
        let mainAfter = try await send(.memoryPage(id: shared.id), api)
        XCTAssertEqual(mainAfter.memory.title, "Shared \(word) merged")
        XCTAssertTrue(mainAfter.memory.content.contains("BOTH"))
        XCTAssertEqual(mainAfter.memory.tags, ["merged"])
        XCTAssertEqual(mainAfter.revisionCount, mainBefore.revisionCount + 1)
        let mergedLog = try await send(.mindCommits(limit: 1), api)
        XCTAssertEqual(mergedLog.commits.first?.message, "merge by hand")

        // Revert the memory to the revision before the merge.
        let history = try await send(.memoryHistory(id: shared.id, full: true), api)
        // The history spans branches: pick the revision that was on main before the merge.
        let previous = try XCTUnwrap(history.revisions.first { $0.content?.contains("CHANGED ON MAIN") == true })
        let reverted = try await send(.mindRevert(memoryId: shared.id, revisionId: previous.revisionId), api)
        XCTAssertEqual(reverted.memoryId, shared.id)
        let afterRevert = try await send(.memoryPage(id: shared.id), api)
        XCTAssertTrue(afterRevert.memory.content.contains("CHANGED ON MAIN"), "revisions: \(history.revisions.map { "\($0.op) \($0.content ?? "-")" }) now: \(afterRevert.memory.content)")
        XCTAssertFalse(afterRevert.memory.content.contains("BOTH"))

        // "Ours" and "theirs" resolutions, and a memory one side forgot.
        let forgetMe = try await send(.memoryCreate(MemoryDraft(content: "to be forgotten \(word)", title: "Forget \(word)")), api)
        let second = "second-\(word)"
        _ = try await send(.mindCreateBranch(name: second), api)
        _ = try await send(.memoryEdit(id: forgetMe.id, MemoryEditRequest(title: nil, content: "edited on second \(word)", tags: nil, branch: second, message: nil)), api)
        _ = try await send(.memoryForget(id: forgetMe.id), api)
        var forgetSession = MindMergeSession(source: second)
        guard case .conflicts(_, let forgetConflicts) = try await merger.attempt(forgetSession) else { return XCTFail("an edit against a forget merged silently") }
        XCTAssertEqual(forgetConflicts.first?.situation, .forgottenHere)
        forgetSession.receive(forgetConflicts)
        forgetSession.resolveRemaining(.theirs)
        guard case .merged = try await merger.attempt(forgetSession) else { return XCTFail("taking theirs did not merge") }
        let revived = try await send(.memoryPage(id: forgetMe.id), api)
        XCTAssertTrue(revived.memory.content.contains("edited on second"))
    }
}
