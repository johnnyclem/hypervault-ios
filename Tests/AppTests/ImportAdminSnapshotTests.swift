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

    func testChooseASourceAtLargeText() throws {
        try snapshot(
            PreviewHost { ImportPreviewHost(stage: .choose) }.environment(\.dynamicTypeSize, .accessibility2),
            named: "import-choose-large"
        )
    }

    func testChoosePastingText() throws {
        try snapshot(PreviewHost { ImportPreviewHost(stage: .paste) }, named: "import-paste")
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

    func testJustMinted() throws {
        try snapshot(PreviewHost { AdminPreviewHost(minted: true) }, named: "admin-minted")
    }

    func testInviteDetail() throws {
        try snapshot(PreviewHost { AdminInvitePreview() }, named: "admin-invite")
    }

    func testInviteDetailAtLargeText() throws {
        try snapshot(
            PreviewHost { AdminInvitePreview() }.environment(\.dynamicTypeSize, .accessibility2),
            named: "admin-invite-large"
        )
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
