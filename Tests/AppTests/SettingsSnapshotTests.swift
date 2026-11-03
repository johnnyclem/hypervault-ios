import HyperVaultKit
import SwiftUI
import XCTest
@testable import HyperVault

/// Settings (the list of panes and the panes), and the Account menu behind the avatar, rendered in light and dark on canned
/// routes. CI publishes the PNGs to the branch's snapshots branch. Nothing here compares a render: they are for looking at.
@MainActor
final class SettingsSnapshotTests: XCTestCase {
    private var tabRoutes: [MockRoute] {
        VaultPreviewData.routes + KeysPreviewData.routes + RealmsPreviewData.routes + MailPreviewData.routes
    }

    func testTheListOfPanes() throws {
        try snapshot(PreviewHost(routes: tabRoutes, capabilities: RealmsPreviewData.capabilities) { SettingsListView() }, named: "settings-list")
    }

    func testTheListOfPanesAtTheLargestType() throws {
        try snapshot(
            PreviewHost(routes: tabRoutes, capabilities: RealmsPreviewData.capabilities) {
                SettingsListView().environment(\.dynamicTypeSize, .accessibility3)
            },
            named: "settings-list-large"
        )
    }

    func testTheVaultPane() throws {
        try snapshot(PreviewHost(routes: tabRoutes, capabilities: RealmsPreviewData.capabilities) { AccountPaneView(pane: .vault) }, named: "settings-vault")
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

/// The Models pane as Settings has it, with the environment it reads.
private struct ModelsPaneSnapshotHost: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        ChatModelsContent(env: env, onChange: nil, embedded: true)
    }
}
