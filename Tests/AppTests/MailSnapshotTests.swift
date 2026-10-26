import SwiftUI
import XCTest
@testable import HyperVault

@MainActor
final class MailSnapshotTests: XCTestCase {
    func testInbox() throws {
        try snapshot(PreviewHost(routes: MailPreviewData.routes) { MailRootView() }, named: "mail-inbox")
    }

    func testEmptyInbox() throws {
        try snapshot(PreviewHost(routes: MailPreviewData.emptyRoutes) { MailRootView() }, named: "mail-empty")
    }

    func testMailUnavailable() throws {
        try snapshot(PreviewHost(routes: MailPreviewData.unavailableRoutes) { MailRootView() }, named: "mail-unavailable")
    }

    func testThread() throws {
        try snapshot(
            PreviewHost(routes: MailPreviewData.threadRoutes) {
                MailThreadView(id: MailPreviewData.threadID, mailbox: MailPreviewData.boxA)
            },
            named: "mail-thread"
        )
    }

    func testHeld() throws {
        try snapshot(
            PreviewHost(routes: MailPreviewData.heldRoutes) { MailHeldView(mailbox: nil) {} },
            named: "mail-held"
        )
    }

    func testCompose() throws {
        try snapshot(
            PreviewHost(embedInNavigation: false) {
                MailComposeView(address: "ana@vault.cool", agentsSeeReplies: false) { _, _ in }
            },
            named: "mail-compose"
        )
    }

    func testSettings() throws {
        try snapshot(
            PreviewHost(embedInNavigation: false) {
                MailSettingsView(address: "ana@vault.cool", agentsSeeReplies: true, onToggle: { _ in }, onExport: { URL(fileURLWithPath: "/tmp/x") })
            },
            named: "mail-settings"
        )
    }
}
