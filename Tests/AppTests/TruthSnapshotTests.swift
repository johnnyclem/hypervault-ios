import HyperVaultKit
import SwiftUI
import XCTest
@testable import HyperVault

@MainActor
final class TruthSnapshotTests: XCTestCase {
    func testLedger() throws {
        try snapshot(PreviewHost(routes: TruthPreviewData.ledgerRoutes) { TruthRootView() }, named: "truth-ledger")
    }

    func testEmptyLedger() throws {
        try snapshot(PreviewHost(routes: TruthPreviewData.emptyRoutes) { TruthRootView() }, named: "truth-empty")
    }

    func testEntryWithTrace() throws {
        let env = AppEnvironment.preview(routes: TruthPreviewData.entryRoutes)
        let row = try XCTUnwrap(
            try HVCoding.decoder().decode(TruthOverview.self, from: Data(TruthPreviewData.overview.utf8)).sections.standing.last
        )
        let ref = TruthEntryRef(row: row, ledger: "team", isHosted: true)
        try snapshot(PreviewHost(routes: TruthPreviewData.entryRoutes) { TruthEntryScreen(client: env.client, ref: ref) }, named: "truth-entry")
    }

    func testReview() throws {
        try snapshot(PreviewHost(routes: TruthPreviewData.reviewRoutes) { TruthReviewView() }, named: "truth-review")
    }

    func testDecisionSheet() throws {
        let env = AppEnvironment.preview(routes: TruthPreviewData.reviewRoutes)
        let model = TruthReviewModel(client: env.client)
        let payload = try HVCoding.decoder().decode(TruthReviewPayload.self, from: Data(TruthPreviewData.docket.utf8))
        try snapshot(
            PreviewHost(embedInNavigation: false) {
                TruthDecisionSheet(model: model, action: .approve, item: payload.docket.items[1]) {}
                    .task { await model.start(preferring: "team") }
            },
            named: "truth-decision"
        )
    }

    func testAssert() throws {
        let env = AppEnvironment.preview(routes: TruthPreviewData.reviewRoutes)
        let ledger = TruthLedger(id: "l1", slug: "team", name: "Team", kind: .hosted)
        try snapshot(PreviewHost(routes: TruthPreviewData.reviewRoutes, embedInNavigation: false) { TruthAssertView(client: env.client, ledger: ledger) {} }, named: "truth-assert")
    }

    func testDrafts() throws {
        let env = AppEnvironment.preview(routes: TruthPreviewData.draftRoutes)
        try snapshot(PreviewHost(routes: TruthPreviewData.draftRoutes) { TruthDraftsScreen(client: env.client, ledger: "default") }, named: "truth-drafts")
    }

    func testNotices() throws {
        let env = AppEnvironment.preview(routes: TruthPreviewData.noticeRoutes)
        try snapshot(PreviewHost(routes: TruthPreviewData.noticeRoutes) { TruthNoticesScreen(client: env.client) }, named: "truth-notices")
    }

    func testStale() throws {
        let env = AppEnvironment.preview(routes: TruthPreviewData.staleRoutes)
        try snapshot(PreviewHost(routes: TruthPreviewData.staleRoutes) { TruthStaleScreen(client: env.client) }, named: "truth-stale")
    }

    func testSigners() throws {
        let env = AppEnvironment.preview(routes: TruthPreviewData.signerRoutes)
        try snapshot(PreviewHost(routes: TruthPreviewData.signerRoutes) { TruthSignersScreen(client: env.client) }, named: "truth-signers")
    }

    func testImport() throws {
        let ledger = TruthLedger(id: "l2", slug: "default", name: "Default", kind: .mirror)
        try snapshot(
            PreviewHost(embedInNavigation: false) {
                TruthImportView(ledger: ledger, onStream: { _ in throw HVError.cancelled }, onPage: { _, _ in throw HVError.cancelled })
            },
            named: "truth-import"
        )
    }
}
