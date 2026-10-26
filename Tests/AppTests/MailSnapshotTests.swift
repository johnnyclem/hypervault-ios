import SwiftUI
import XCTest
@testable import HyperVault

/// Every state is rendered with no delay on the canned answers, and given time to settle, so a screen is
/// never captured while it is still showing its loading skeleton.
@MainActor
final class MailSnapshotTests: XCTestCase {
    func testInbox() throws {
        try snapshot(PreviewHost(routes: MailPreviewData.routes, delay: 0) { MailRootView() }, named: "mail-inbox", settle: 2)
    }

    func testInboxAtLargeType() throws {
        try snapshot(
            PreviewHost(routes: MailPreviewData.routes, delay: 0) { MailRootView() }
                .environment(\.dynamicTypeSize, .accessibility2),
            named: "mail-inbox-large", settle: 2, schemes: [.light]
        )
    }

    func testEmptyInbox() throws {
        try snapshot(PreviewHost(routes: MailPreviewData.emptyRoutes, delay: 0) { MailRootView() }, named: "mail-empty", settle: 2)
    }

    /// The client retries a 503 twice with a pause before it gives up, so this one waits longer.
    func testMailUnavailable() throws {
        try snapshot(PreviewHost(routes: MailPreviewData.unavailableRoutes, delay: 0) { MailRootView() }, named: "mail-unavailable", settle: 4)
    }

    func testThread() throws {
        try snapshot(
            PreviewHost(routes: MailPreviewData.threadRoutes, delay: 0) {
                MailThreadView(id: MailPreviewData.threadID, mailbox: MailPreviewData.boxA)
            },
            named: "mail-thread", settle: 2
        )
    }

    func testHeld() throws {
        try snapshot(
            PreviewHost(routes: MailPreviewData.heldRoutes, delay: 0) { MailHeldView(mailbox: nil) {} },
            named: "mail-held", settle: 2
        )
    }

    func testCompose() throws {
        try snapshot(
            PreviewHost(embedInNavigation: false) {
                MailComposeView(address: "ana@vault.cool", agentsSeeReplies: false) { _, _ in }
            },
            named: "mail-compose", settle: 1
        )
    }

    func testComposeAtLargeType() throws {
        try snapshot(
            PreviewHost(embedInNavigation: false) {
                MailComposeView(address: "ana@vault.cool", agentsSeeReplies: false) { _, _ in }
            }
            .environment(\.dynamicTypeSize, .accessibility2),
            named: "mail-compose-large", settle: 1, schemes: [.light]
        )
    }

    func testSettings() throws {
        try snapshot(
            PreviewHost(embedInNavigation: false) {
                MailSettingsView(address: "ana@vault.cool", agentsSeeReplies: true, onToggle: { _ in }, onExport: { URL(fileURLWithPath: "/tmp/x") })
            },
            named: "mail-settings", settle: 1
        )
    }
}
