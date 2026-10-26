import HyperVaultKit
import XCTest
@testable import HyperVault

/// What the Mind screens send and say on canned answers: which revision a restore or a bring-back writes onto a
/// branch, and what the merge screen tells before anything is merged.
@MainActor
final class MindRestoreMergeTests: XCTestCase {
    private let base = URL(string: "https://hv.test")!

    /// main edited the memory at 21 October, ideas at 22 October, and the first version is from the 20th.
    private let history = #"""
    {"memory_id":"m1","revisions":[
      {"revision_id":"r-ideas","op":"update","title":"Trip notes","summary":"Ideas version","tags":[],"source":"manual","commit":{"id":"c3","message":"edit","author_kind":"user","branch":"ideas","created_at":"2026-10-22T10:00:00Z"}},
      {"revision_id":"r-main","op":"update","title":"Trip notes","summary":"Main version","tags":[],"source":"manual","commit":{"id":"c2","message":"edit","author_kind":"user","branch":"main","created_at":"2026-10-21T10:00:00Z"}},
      {"revision_id":"r-first","op":"create","title":"Trip","summary":"First","tags":[],"source":"manual","commit":{"id":"c1","message":"memorize","author_kind":"user","branch":"main","created_at":"2026-10-20T10:00:00Z"}}
    ]}
    """#

    private let reverted = #"{"commit_id":"c9","restored":{"memory_id":"m1","title":"Trip notes","revision_id":"x"},"branch":"main","message":"Restored."}"#

    private func makeRestorer(_ routes: [MockRoute], branch: String = "main") -> (MindRestorer, MockTransport) {
        let transport = MockTransport(routes: routes)
        let client = HVClient(baseURL: base, transport: transport, tokens: StaticTokenProvider(), retry: .none)
        return (MindRestorer(client: client, branch: branch), transport)
    }

    private func row(_ json: String) throws -> MindStateMemory {
        try HVCoding.decoder().decode(MindStateMemory.self, from: Data(json.utf8))
    }

    private func sentBody(_ request: URLRequest?) throws -> [String: Any] {
        let data = try XCTUnwrap(request?.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func message(_ error: Error) -> String? { (error as? HVError)?.userMessage }

    // MARK: Restore

    func testRestoreWritesTheRevisionOfTheBranchBeingReadNotAnotherBranchsNewerOne() async throws {
        let (restorer, transport) = makeRestorer([.json(.get, "/api/memories/m1/history", history), .json(.post, "/api/mind/revert", reverted)])
        // Time travel on main shows the version main made on the 21st; ideas made a newer one since.
        let shown = try row(#"{"id":"m1","title":"Trip notes","summary":"Main version","tags":[],"source":"manual","committed_at":"2026-10-21T10:00:00Z"}"#)
        _ = try await restorer.restore(memoryID: "m1", version: shown)

        let sent = await transport.requests
        let revert = try sentBody(sent.last)
        XCTAssertEqual(revert["revision_id"] as? String, "r-main")
        XCTAssertEqual(revert["branch"] as? String, "main")
        let limit = URLComponents(url: try XCTUnwrap(sent.first?.url), resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "limit" }?.value
        XCTAssertEqual(limit, "200", "as much of the history as the route gives")
    }

    func testARevisionTheServerNamesNeedsNoHistory() async throws {
        let (restorer, transport) = makeRestorer([.json(.post, "/api/mind/revert", reverted)], branch: "ideas")
        let shown = try row(#"{"id":"m1","title":"Trip notes","summary":"","tags":[],"source":"manual","committed_at":"2026-10-21T10:00:00Z","revision_id":"r-exact"}"#)
        _ = try await restorer.restore(memoryID: "m1", version: shown)

        let sent = await transport.requests
        XCTAssertEqual(sent.count, 1, "no history was read")
        XCTAssertEqual(try sentBody(sent.first)["revision_id"] as? String, "r-exact")
        XCTAssertEqual(try sentBody(sent.first)["branch"] as? String, "ideas")
    }

    func testAVersionNotFoundSaysSoAndOnlyBlamesTheAgeWhenTheHistoryWasFull() async throws {
        let shown = try row(#"{"id":"m1","title":"Not in it","summary":"","tags":[],"source":"manual","committed_at":"2026-01-01T10:00:00Z"}"#)

        let (short, _) = makeRestorer([.json(.get, "/api/memories/m1/history", history)])
        do {
            _ = try await short.restore(memoryID: "m1", version: shown)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(message(error), "That version could not be found in the memory's history.")
        }

        // A memory with a revision for every chat turn: a full page may not reach back that far.
        let revisions = (0..<MemoryHistory.maxLimit).map { number in
            #"{"revision_id":"r\#(number)","op":"update","title":"Chat","summary":"s\#(number)","tags":[],"source":"chat","commit":{"id":"c\#(number)","message":"m","author_kind":"user","branch":"main","created_at":"2026-10-24T10:00:00Z"}}"#
        }
        let full = #"{"memory_id":"m1","revisions":[\#(revisions.joined(separator: ","))]}"#
        let (long, _) = makeRestorer([.json(.get, "/api/memories/m1/history", full)])
        do {
            _ = try await long.restore(memoryID: "m1", version: shown)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(message(error), "That version is too old to restore from here.")
        }
    }

    // MARK: Bring back

    func testBringBackReadsTheMemoryAsItStoodAtThePointItWasStillThere() async throws {
        let state = #"{"at":"c8","commit_id":"c8","memories":[{"id":"m1","title":"Trip notes","summary":"Main version","tags":[],"source":"manual","committed_at":"2026-10-21T10:00:00Z"}],"links":[]}"#
        let (restorer, transport) = makeRestorer([
            .json(.get, "/api/mind/state", state), .json(.get, "/api/memories/m1/history", history), .json(.post, "/api/mind/revert", reverted),
        ])
        _ = try await restorer.bringBack(memoryID: "m1", asOf: "c8")

        let sent = await transport.requests
        let at = URLComponents(url: try XCTUnwrap(sent.first?.url), resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "at" }?.value
        XCTAssertEqual(at, "c8")
        XCTAssertEqual(try sentBody(sent.last)["revision_id"] as? String, "r-main", "its version there, not the newest on any branch")
    }

    func testBringBackOfAMemoryThePointDoesNotHoldSaysThereIsNothingToBringBack() async {
        let (restorer, transport) = makeRestorer([.json(.get, "/api/mind/state", #"{"at":"c8","commit_id":"c8","memories":[],"links":[]}"#)])
        do {
            _ = try await restorer.bringBack(memoryID: "m1", asOf: "c8")
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(message(error), "There is no earlier version of that memory to bring back.")
        }
        let sent = await transport.requests
        XCTAssertEqual(sent.count, 1, "nothing was written")
    }

    // MARK: Merge preview

    /// ideas split from main at c0. The comparison of the two heads shows the memory main wrote since (A) as
    /// missing from ideas, and the one ideas wrote (B) as extra.
    private let diff = #"""
    {"from":{"ref":"main","commit_id":"c1"},"to":{"ref":"ideas","commit_id":"c0"},
     "memories":{"added":[{"id":"B","title":"Ferry"}],"removed":[{"id":"A","title":"Boat"}],"changed":[]},
     "links":{"added":[],"removed":[]}}
    """#

    private func mergeModel(_ routes: [MockRoute]) -> MindMergeModel {
        MindMergeModel(source: "ideas", env: AppEnvironment.preview(routes: routes))
    }

    private func log(_ commits: String) -> MockRoute {
        .json(.get, "/api/mind/commits", #"{"branch":"main","commits":[\#(commits)]}"#)
    }

    func testABranchWithNothingNewIsUpToDateWhateverMainHasDoneSince() async {
        // main moved on from c0 and ideas did not. The server answers "Already up to date"; so does the screen,
        // and it does not list main's memory as one the merge would forget.
        let model = mergeModel([
            .json(.get, "/api/mind/diff", diff),
            log(#"{"id":"c1","message":"memorize: Boat","author_kind":"user","parent_commit_id":"c0"},{"id":"c0","message":"genesis","author_kind":"system"}"#),
        ])
        await model.loadPreview()
        XCTAssertEqual(model.phase, .upToDate)
    }

    func testABranchAlreadyMergedInIsUpToDateToo() async {
        let model = mergeModel([
            .json(.get, "/api/mind/diff", diff),
            log(#"{"id":"m1","message":"merge ideas into main","author_kind":"user","parent_commit_id":"c1","merge_parent_commit_id":"c0"},{"id":"c1","message":"memorize: Boat","author_kind":"user"}"#),
        ])
        await model.loadPreview()
        XCTAssertEqual(model.phase, .upToDate)
    }

    func testABranchWithNewWorkIsPreviewedAsHowTheTwoDiffer() async throws {
        let model = mergeModel([
            .json(.get, "/api/mind/diff", diff),
            log(#"{"id":"c1","message":"memorize: Boat","author_kind":"user","parent_commit_id":"cx"},{"id":"cx","message":"genesis","author_kind":"system"}"#),
        ])
        await model.loadPreview()
        guard case .ready(let shown) = model.phase else { return XCTFail("expected a preview, got \(model.phase)") }
        XCTAssertEqual(shown.added.map(\.title), ["Ferry"])
        XCTAssertEqual(shown.removed.map(\.title), ["Boat"])
        let words = shown.differenceSummary(source: model.source, target: model.target)
        XCTAssertTrue(words.contains("only\u{00A0}on\u{00A0}ideas"))
        XCTAssertFalse(words.contains("forgotten"), "the merge keeps main's memory; it is not forgotten")
    }

    func testAPreviewDoesNotNeedTheLog() async {
        let model = mergeModel([.json(.get, "/api/mind/diff", diff)])
        await model.loadPreview()
        guard case .ready = model.phase else { return XCTFail("expected a preview, got \(model.phase)") }
    }

    func testTwoBranchesThatHoldTheSameMemoriesAreUpToDate() async {
        let same = #"{"from":{"ref":"main","commit_id":"c1"},"to":{"ref":"ideas","commit_id":"c5"},"memories":{"added":[],"removed":[],"changed":[]},"links":{"added":[],"removed":[]}}"#
        let model = mergeModel([.json(.get, "/api/mind/diff", same)])
        await model.loadPreview()
        XCTAssertEqual(model.phase, .upToDate)
    }
}
