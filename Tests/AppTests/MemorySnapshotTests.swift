import HyperVaultKit
import SwiftUI
import XCTest
@testable import HyperVault

/// The Memory tab, Git for a mind, Dreams and Digest, on canned answers.
@MainActor
final class MemorySnapshotTests: XCTestCase {
    private let routes = MemoryPreviewData.routes
    private let tall = CGSize(width: 393, height: 1200)
    /// The moment Time travel and Compare start from, pinned so the renders do not change with the clock.
    private let pinnedMoment = ISO8601DateFormatter().date(from: "2026-10-15T09:00:00Z") ?? Date(timeIntervalSince1970: 1_792_054_800)

    func testMemoryList() throws {
        try snapshot(PreviewHost(routes: routes) { MemoryRootView() }, named: "memory-list")
    }

    func testRecall() throws {
        try snapshot(PreviewHost(routes: routes) { MemoryTabPreview(query: "ferry") }, named: "memory-recall", settle: 1.6)
    }

    func testGraph() throws {
        try snapshot(PreviewHost(routes: routes) { MemoryTabPreview(mode: .graph) }, named: "memory-graph", settle: 5)
    }

    func testAsk() throws {
        try snapshot(PreviewHost(routes: routes) { MemoryTabPreview(mode: .ask) }, named: "memory-ask")
    }

    func testEmptyMemory() throws {
        var empty: [MockRoute] = [.json(.get, "/api/memories", #"{"branch":"main","memories":[]}"#)]
        empty.append(contentsOf: routes)
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
        let moment = pinnedMoment
        try snapshot(
            PreviewHost(routes: routes) { MemoryScreenHost { list in MindCompareView(list: list, from: .moment(moment)) } },
            named: "mind-compare", size: tall
        )
    }

    func testTimeTravel() throws {
        let moment = pinnedMoment
        try snapshot(
            PreviewHost(routes: routes) { MemoryScreenHost { list in MindTimeTravelView(list: list, moment: moment) } },
            named: "mind-time-travel", size: tall, settle: 1.6
        )
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
        var quiet: [MockRoute] = [.json(.get, "/api/dreams", MemoryPreviewData.dreamsEmpty)]
        quiet.append(contentsOf: routes)
        try snapshot(PreviewHost(routes: quiet) { DreamsRootView() }, named: "dreams-quiet")
    }

    func testDigest() throws {
        try snapshot(PreviewHost(routes: routes) { DigestRootView() }, named: "digest", size: tall)
    }

    func testDigestEmpty() throws {
        var none: [MockRoute] = [
            .json(.get, "/api/digest", MemoryPreviewData.digestEmpty),
            .json(.get, "/api/digest/settings", #"{"enabled":false}"#),
        ]
        none.append(contentsOf: routes)
        try snapshot(PreviewHost(routes: none) { DigestRootView() }, named: "digest-empty")
    }

    func testForceGraphOnItsOwn() throws {
        var nodes: [ForceGraphNode] = []
        for index in 0..<24 {
            let color: Color = index % 3 == 0 ? Palette.violet : Palette.blue
            let shape: ForceGraphNode.Shape = index % 5 == 0 ? .diamond : .circle
            let weight = 1.0 + Double(index % 4)
            nodes.append(ForceGraphNode(id: "n\(index)", label: "Node \(index)", color: color, shape: shape, weight: weight))
        }
        var edges: [ForceGraphEdge] = []
        for index in 1..<24 {
            edges.append(ForceGraphEdge(source: "n\(index)", target: "n\(index / 2)", isStrong: index % 7 == 0))
        }
        let legend = [ForceGraphLegendItem(title: "Memory", color: Palette.blue)]
        let graph = ForceGraphView(nodes: nodes, edges: edges, legend: legend, onOpen: { _ in })
        try snapshot(graph.hvScreenBackground(), named: "force-graph", settle: 5)
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
            // Fill the canvas first, so the page color is the whole picture and not a band round the diff.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .hvScreenBackground(),
            named: "mind-diff"
        )
    }
}
