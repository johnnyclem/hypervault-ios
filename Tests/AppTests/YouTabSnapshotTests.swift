import HyperVaultKit
import SwiftUI
import XCTest
@testable import HyperVault

/// The You tab, the panes that are new in it, and the Account menu behind the avatar, rendered in light and dark on canned
/// routes. CI publishes the PNGs to the branch's snapshots branch. Nothing here compares a render: they are for looking at.
@MainActor
final class YouTabSnapshotTests: XCTestCase {
    private var tabRoutes: [MockRoute] {
        VaultPreviewData.routes + KeysPreviewData.routes + RealmsPreviewData.routes + MailPreviewData.routes
    }

    func testTheYouTabOpensOnTheVault() throws {
        try snapshot(PreviewHost(routes: tabRoutes, capabilities: RealmsPreviewData.capabilities, embedInNavigation: false) { YouTabView() }, named: "you-tab-vault")
    }

    func testTheYouTabWhereBothColumnsShow() throws {
        // The iPad's layout is the device's, not the window's: it is asked for here, as a simulator of a phone has the other.
        try snapshot(
            PreviewHost(routes: tabRoutes, capabilities: RealmsPreviewData.capabilities, embedInNavigation: false, youIsStack: false) {
                YouTabView()
            },
            named: "you-tab-wide", size: CGSize(width: 1180, height: 820)
        )
    }

    func testGeneralForAFreePerson() throws {
        try snapshot(PreviewHost(routes: [.json(.get, "/rest/v1/profiles", #"[{"plan":"free","vanity_subdomain":null}]"#)]) { GeneralPane() }, named: "pane-general-free")
    }

    func testGeneralForAProPerson() throws {
        try snapshot(PreviewHost(routes: RealmsPreviewData.routes) { GeneralPane() }, named: "pane-general-pro")
    }

    func testModelsInThePane() throws {
        try snapshot(
            PreviewHost(routes: ChatPreviewData.routes) { ModelsPaneSnapshotHost() },
            named: "pane-models"
        )
    }

    func testAppearance() throws {
        let routes: [MockRoute] = [.json(.get, "/rest/v1/profiles", #"[{"theme":"glassmorphism"}]"#)]
        try snapshot(PreviewHost(routes: routes, capabilities: RealmsPreviewData.capabilities) { AppearancePane() }, named: "pane-appearance")
    }

    func testImport() throws {
        try snapshot(PreviewHost { ImportPane() }, named: "pane-import")
    }

    func testTheAccountMenu() throws {
        try snapshot(PreviewHost(routes: MailPreviewData.routes, embedInNavigation: false) { AccountMenuSheet() }, named: "account-menu")
    }

    func testTheAccountMenuAtTheLargestType() throws {
        try snapshot(
            PreviewHost(routes: MailPreviewData.routes, embedInNavigation: false) {
                AccountMenuSheet().environment(\.dynamicTypeSize, .accessibility3)
            },
            named: "account-menu-large"
        )
    }
}

/// The Models pane as the You tab has it, with the environment it reads.
private struct ModelsPaneSnapshotHost: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        ChatModelsContent(env: env, onChange: nil, embedded: true)
    }
}
