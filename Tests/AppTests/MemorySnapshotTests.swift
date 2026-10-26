import HyperVaultKit
import SwiftUI
import XCTest
@testable import HyperVault

/// The Memory tab, Git for a mind, Dreams and Digest, on canned answers.
@MainActor
final class MemorySnapshotTests: XCTestCase {
    private let routes = MemoryPreviewData.routes
    private let tall = CGSize(width: 393, height: 1200)

    func testMemoryList() throws {
        try snapshot(PreviewHost(routes: routes) { MemoryRootView() }, named: "memory-list")
    }

    func testRecall() throws {
        try snapshot(PreviewHost(routes: routes) { MemoryTabPreview(query: "ferry") }, named: "memory-recall", settle: 1.6)
    }

    func testGraph() throws {
        try snapshot(PreviewHost(routes: routes) { MemoryTabPreview(mode: .graph) }, named: "memory-graph", settle: 2.5)
    }

    func testAsk() throws {
        try snapshot(PreviewHost(routes: routes) { MemoryTabPreview(mode: .ask) }, named: "memory-ask")
    }

    func testEmptyMemory() throws {
        let empty = [MockRoute.json(.get, "/api/memories", #"{"branch":"main","memories":[]}"#)] + routes
        try snapshot(PreviewHost(routes: empty) { MemoryRootView() }, named: "memory-empty")
    }

    func testDetail() throws {
        try snapshot(PreviewHost(routes: routes) { MemoryDetailView(id: "m1") }, named: "memory-detail", size: tall)
    }

    func testHistory() throws {
        try snapshot(
            PreviewHost(routes: routes) {
                MemoryScreenHost { list in MemoryHistoryView(memoryID: "m1", title: "Trip to Lisbon", branch: list.branch, env: list.env) }
            },
            named: "memory-history", size: tall
        )
    }

    func testMemorize() throws {
        try snapshot(PreviewHost(routes: routes, embedInNavigation: false) { MemoryScreenHost { list in MemorizeSheet(list: list) } }, named: "memory-memorize")
    }

    func testExportPrompt() throws {
        try snapshot(PreviewHost(routes: routes) { MemoryExportPromptView() }, named: "memory-export-prompt", size: tall)
    }

    func testBranches() throws {
        try snapshot(PreviewHost(routes: routes) { MemoryScreenHost { list in MindBranchesView(list: list) } }, named: "mind-branches")
    }

    func testCommitLog() throws {
        try snapshot(PreviewHost(routes: routes) { MemoryScreenHost { list in MindCommitLogView(list: list) } }, named: "mind-commits")
    }

    func testCompare() throws {
        try snapshot(PreviewHost(routes: routes) { MemoryScreenHost { list in MindCompareView(list: list) } }, named: "mind-compare", size: tall)
    }

    func testTimeTravel() throws {
        try snapshot(PreviewHost(routes: routes) { MemoryScreenHost { list in MindTimeTravelView(list: list) } }, named: "mind-time-travel", size: tall, settle: 1.6)
    }

    func testMergePreview() throws {
        try snapshot(PreviewHost(routes: routes) { MemoryScreenHost { list in MindMergeView(source: "ideas", list: list) } }, named: "mind-merge-preview", size: tall)
    }

    func testMergeConflicts() throws {
        let conflicts = try conflictFixtures()
        try snapshot(
            PreviewHost(routes: routes) { MemoryScreenHost { list in MindMergeView(source: "ideas", list: list, conflicts: conflicts) } },
            named: "mind-merge-conflicts", size: tall
        )
    }

    func testDreams() throws {
        try snapshot(PreviewHost(routes: routes) { DreamsRootView() }, named: "dreams", size: tall)
    }

    func testDreamsQuietNight() throws {
        let quiet = [MockRoute.json(.get, "/api/dreams", MemoryPreviewData.dreamsEmpty)] + routes
        try snapshot(PreviewHost(routes: quiet) { DreamsRootView() }, named: "dreams-quiet")
    }

    func testDigest() throws {
        try snapshot(PreviewHost(routes: routes) { DigestRootView() }, named: "digest", size: tall)
    }

    func testDigestEmpty() throws {
        let none = [MockRoute.json(.get, "/api/digest", MemoryPreviewData.digestEmpty), MockRoute.json(.get, "/api/digest/settings", #"{"enabled":false}"#)] + routes
        try snapshot(PreviewHost(routes: none) { DigestRootView() }, named: "digest-empty")
    }

    func testForceGraphOnItsOwn() throws {
        let nodes = (0..<24).map { index in
            ForceGraphNode(
                id: "n\(index)", label: "Node \(index)", color: index % 3 == 0 ? Palette.violet : Palette.blue,
                shape: index % 5 == 0 ? .diamond : .circle, weight: 1 + Double(index % 4)
            )
        }
        let edges = (1..<24).map { ForceGraphEdge(source: "n\($0)", target: "n\($0 / 2)", isStrong: $0 % 7 == 0) }
        try snapshot(
            ForceGraphView(nodes: nodes, edges: edges, legend: [ForceGraphLegendItem(title: "Memory", color: Palette.blue)], onOpen: { _ in })
                .hvScreenBackground(),
            named: "force-graph", settle: 2.5
        )
    }

    private func conflictFixtures() throws -> [MindMergeConflict] {
        let value = try HVCoding.decoder(.verbatim).decode(JSONValue.self, from: Data(MemoryPreviewData.conflicts.utf8))
        let data = try JSONEncoder().encode(value["conflicts"] ?? .null)
        return try HVCoding.decoder().decode([MindMergeConflict].self, from: data)
    }

    func testDiffRowsAndTally() throws {
        // The renderer on its own: lines, numbers and a fold.
        let diff = MindTextDiff(hunks: [
            MindDiffHunk(oldStart: 3, oldLines: 3, newStart: 3, newLines: 4, lines: [
                MindDiffLine(kind: .ctx, text: "A line that stays."),
                MindDiffLine(kind: .del, text: "A line that goes."),
                MindDiffLine(kind: .add, text: "A line that comes."),
                MindDiffLine(kind: .add, text: "And another."),
                MindDiffLine(kind: .ctx, text: "The end."),
            ]),
        ])
        try snapshot(
            VStack(alignment: .leading, spacing: 12) {
                MindDiffTally(added: diff.addedLines, removed: diff.removedLines)
                MindDiffView(diff: diff)
            }
            .padding()
            .hvScreenBackground(),
            named: "mind-diff"
        )
    }
}
