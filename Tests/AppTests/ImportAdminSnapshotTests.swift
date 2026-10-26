import HyperVaultKit
import SwiftUI
import XCTest
@testable import HyperVault

@MainActor
final class ImportSnapshotTests: XCTestCase {
    func testChooseASource() throws {
        try snapshot(PreviewHost { ImportPreviewHost(stage: .choose) }, named: "import-choose")
    }

    func testReviewWhatWasFound() throws {
        try snapshot(PreviewHost { ImportPreviewHost(stage: .review) }, named: "import-review")
    }

    func testSending() throws {
        try snapshot(PreviewHost { ImportPreviewHost(stage: .sending) }, named: "import-sending")
    }

    func testDone() throws {
        try snapshot(PreviewHost { ImportPreviewHost(stage: .done) }, named: "import-done")
    }

    func testStopped() throws {
        try snapshot(PreviewHost { ImportPreviewHost(stage: .stopped) }, named: "import-stopped")
    }

    func testNothingFound() throws {
        try snapshot(PreviewHost { ImportPreviewHost(stage: .nothing) }, named: "import-nothing")
    }
}

@MainActor
final class AdminSnapshotTests: XCTestCase {
    func testAdminHome() throws {
        try snapshot(PreviewHost { AdminPreviewHost() }, named: "admin-home")
    }

    func testInviteDetail() throws {
        try snapshot(PreviewHost { AdminInvitePreview() }, named: "admin-invite")
    }

    func testAccountTools() throws {
        try snapshot(PreviewHost { AdminAccountsPreview() }, named: "admin-accounts")
    }

    func testDeleteAccountSheet() throws {
        try snapshot(
            PreviewHost(embedInNavigation: false) {
                AdminDeleteAccountSheet(accountID: "3f1c1a2e-0000-4000-8000-000000000001") { false }
            },
            named: "admin-delete"
        )
    }
}
