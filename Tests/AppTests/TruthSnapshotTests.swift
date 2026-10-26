import HyperVaultKit
import SwiftUI
import XCTest
@testable import HyperVault

/// Every screen is rendered with no delay on the canned answers, and given time to settle, so none is
/// captured while it is still showing its loading skeleton. The long ones are drawn taller than a phone so
/// the whole of the screen can be looked at, and the main ones again at a large text size.
@MainActor
final class TruthSnapshotTests: XCTestCase {
    private let tall = CGSize(width: 393, height: 1300)
    private let team = TruthLedger(id: "l1", slug: "team", name: "Team", kind: .hosted)
    private let accessibility = DynamicTypeSize.accessibility2

    // MARK: The ledger

    func testLedger() throws {
        try snapshot(PreviewHost(routes: TruthPreviewData.ledgerRoutes, delay: 0) { TruthRootView() }, named: "truth-ledger", size: tall, settle: 2)
    }

    func testLedgerAtLargeType() throws {
        try snapshot(
            PreviewHost(routes: TruthPreviewData.ledgerRoutes, delay: 0) { TruthRootView() }.environment(\.dynamicTypeSize, accessibility),
            named: "truth-ledger-large", size: CGSize(width: 393, height: 1800), settle: 2, schemes: [.light]
        )
    }

    func testEmptyLedger() throws {
        try snapshot(PreviewHost(routes: TruthPreviewData.emptyRoutes, delay: 0) { TruthRootView() }, named: "truth-empty", settle: 2)
    }

    // MARK: An entry

    private func entryScreen(_ env: AppEnvironment) throws -> TruthEntryScreen {
        let row = try XCTUnwrap(
            try HVCoding.decoder().decode(TruthOverview.self, from: Data(TruthPreviewData.overview.utf8)).sections.standing.last
        )
        return TruthEntryScreen(client: env.client, ref: TruthEntryRef(row: row, ledger: "team", isHosted: true))
    }

    func testEntryWithTrace() throws {
        let env = AppEnvironment.preview(routes: TruthPreviewData.entryRoutes)
        let screen = try entryScreen(env)
        try snapshot(
            PreviewHost(routes: TruthPreviewData.entryRoutes, delay: 0) { screen },
            named: "truth-entry", size: CGSize(width: 393, height: 1700), settle: 2
        )
    }

    func testEntryAtLargeType() throws {
        let env = AppEnvironment.preview(routes: TruthPreviewData.entryRoutes)
        let screen = try entryScreen(env)
        try snapshot(
            PreviewHost(routes: TruthPreviewData.entryRoutes, delay: 0) { screen }.environment(\.dynamicTypeSize, accessibility),
            named: "truth-entry-large", size: CGSize(width: 393, height: 2600), settle: 2, schemes: [.light]
        )
    }

    // MARK: The review

    func testReview() throws {
        try snapshot(PreviewHost(routes: TruthPreviewData.reviewRoutes, delay: 0) { TruthReviewView() }, named: "truth-review", settle: 2)
    }

    func testReviewAtLargeType() throws {
        try snapshot(
            PreviewHost(routes: TruthPreviewData.reviewRoutes, delay: 0) { TruthReviewView() }.environment(\.dynamicTypeSize, accessibility),
            named: "truth-review-large", size: CGSize(width: 393, height: 1900), settle: 2, schemes: [.light]
        )
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
            named: "truth-decision", settle: 2
        )
    }

    // MARK: Asserting

    func testAssert() throws {
        let env = AppEnvironment.preview(routes: TruthPreviewData.reviewRoutes)
        try snapshot(
            PreviewHost(routes: TruthPreviewData.reviewRoutes, delay: 0, embedInNavigation: false) { TruthAssertView(client: env.client, ledger: team) {} },
            named: "truth-assert", settle: 2
        )
    }

    func testAssertAtLargeType() throws {
        let env = AppEnvironment.preview(routes: TruthPreviewData.reviewRoutes)
        try snapshot(
            PreviewHost(routes: TruthPreviewData.reviewRoutes, delay: 0, embedInNavigation: false) { TruthAssertView(client: env.client, ledger: team) {} }
                .environment(\.dynamicTypeSize, accessibility),
            named: "truth-assert-large", size: CGSize(width: 393, height: 1400), settle: 2, schemes: [.light]
        )
    }

    /// A TB with its evidence, ready to send: the button on, no hint under it.
    func testAssertSignedTruth() throws {
        let env = AppEnvironment.preview(routes: TruthPreviewData.reviewRoutes)
        var draft = TruthAssertDraft(type: .tb)
        draft.text = "Retries are capped at 5; the old cap of 3 is dead."
        draft.evidence = [TruthEvidenceDraft(kind: .test, ref: "test/retry.test.ts", detail: "Fails at 6")]
        try snapshot(
            PreviewHost(routes: TruthPreviewData.reviewRoutes, delay: 0, embedInNavigation: false) { TruthAssertView(client: env.client, ledger: team, draft: draft) {} },
            named: "truth-assert-tb", size: CGSize(width: 393, height: 1100), settle: 2
        )
    }

    func testNewLedger() throws {
        try snapshot(PreviewHost(embedInNavigation: false) { TruthNewLedgerView { _, _, _ in } }, named: "truth-new-ledger", settle: 1)
    }

    // MARK: Drafts, notices, out of date, signers

    func testDrafts() throws {
        let env = AppEnvironment.preview(routes: TruthPreviewData.draftRoutes)
        try snapshot(
            PreviewHost(routes: TruthPreviewData.draftRoutes, delay: 0) { TruthDraftsScreen(client: env.client, ledger: "default") },
            named: "truth-drafts", size: CGSize(width: 393, height: 1000), settle: 2
        )
    }

    func testDraftsAtLargeType() throws {
        let env = AppEnvironment.preview(routes: TruthPreviewData.draftRoutes)
        try snapshot(
            PreviewHost(routes: TruthPreviewData.draftRoutes, delay: 0) { TruthDraftsScreen(client: env.client, ledger: "default") }
                .environment(\.dynamicTypeSize, accessibility),
            named: "truth-drafts-large", size: CGSize(width: 393, height: 2000), settle: 2, schemes: [.light]
        )
    }

    func testNotices() throws {
        let env = AppEnvironment.preview(routes: TruthPreviewData.noticeRoutes)
        try snapshot(
            PreviewHost(routes: TruthPreviewData.noticeRoutes, delay: 0) { TruthNoticesScreen(client: env.client, ledger: team) },
            named: "truth-notices", settle: 2
        )
    }

    func testNoticesAtLargeType() throws {
        let env = AppEnvironment.preview(routes: TruthPreviewData.noticeRoutes)
        try snapshot(
            PreviewHost(routes: TruthPreviewData.noticeRoutes, delay: 0) { TruthNoticesScreen(client: env.client, ledger: team) }
                .environment(\.dynamicTypeSize, accessibility),
            named: "truth-notices-large", size: CGSize(width: 393, height: 1500), settle: 2, schemes: [.light]
        )
    }

    func testStale() throws {
        let env = AppEnvironment.preview(routes: TruthPreviewData.staleRoutes)
        try snapshot(
            PreviewHost(routes: TruthPreviewData.staleRoutes, delay: 0) { TruthStaleScreen(client: env.client) },
            named: "truth-stale", settle: 2
        )
    }

    func testStaleAtLargeType() throws {
        let env = AppEnvironment.preview(routes: TruthPreviewData.staleRoutes)
        try snapshot(
            PreviewHost(routes: TruthPreviewData.staleRoutes, delay: 0) { TruthStaleScreen(client: env.client) }
                .environment(\.dynamicTypeSize, accessibility),
            named: "truth-stale-large", size: CGSize(width: 393, height: 1800), settle: 2, schemes: [.light]
        )
    }

    func testSigners() throws {
        let env = AppEnvironment.preview(routes: TruthPreviewData.signerRoutes)
        try snapshot(
            PreviewHost(routes: TruthPreviewData.signerRoutes, delay: 0) { TruthSignersScreen(client: env.client) },
            named: "truth-signers", settle: 2
        )
    }

    // MARK: Import

    func testImport() throws {
        let ledger = TruthLedger(id: "l2", slug: "default", name: "Default", kind: .mirror)
        try snapshot(
            PreviewHost(embedInNavigation: false) {
                TruthImportView(ledger: ledger, onStream: { _ in throw HVError.cancelled }, onPage: { _, _ in throw HVError.cancelled })
            },
            named: "truth-import", settle: 1
        )
    }

    func testImportAtLargeType() throws {
        let ledger = TruthLedger(id: "l2", slug: "default", name: "Default", kind: .mirror)
        try snapshot(
            PreviewHost(embedInNavigation: false) {
                TruthImportView(ledger: ledger, onStream: { _ in throw HVError.cancelled }, onPage: { _, _ in throw HVError.cancelled })
            }
            .environment(\.dynamicTypeSize, accessibility),
            named: "truth-import-large", size: CGSize(width: 393, height: 1700), settle: 1, schemes: [.light]
        )
    }
}
