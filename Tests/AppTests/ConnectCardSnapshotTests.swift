import HyperVaultKit
import SwiftUI
import XCTest
@testable import HyperVault

/// The first-run connect card: on the canvas under the hints, and on Home's starter page under its buttons, for someone with
/// no key and no model; and on its own at the largest accessibility type, where the icon goes above the title and the
/// buttons keep their width.
@MainActor
final class ConnectCardSnapshotTests: XCTestCase {
    private let origin = URL(string: "https://hypervault.store")!

    func testTheCardOnTheCanvas() throws {
        let routes: [MockRoute] = [
            .json(.get, "/api/backends", Fixtures.noBackends),
            .json(.get, "/rest/v1/api_keys", "[]"),
            .json(.get, "/rest/v1/profiles", #"[{"onboarding":{}}]"#),
        ]
        let model = CanvasModel(client: AppEnvironment.preview().client, origin: origin)
        try snapshot(
            PreviewHost(routes: routes, delay: 0.05, embedInNavigation: true) {
                CanvasScreen(model: model, origin: origin)
            },
            named: "canvas-connect-card",
            // Taller than a phone, so the card under the hints is in the picture; on a phone it is a scroll away.
            size: CGSize(width: 393, height: 1100),
            settle: 1.5
        )
    }

    func testTheCardOnHomesStarterPage() throws {
        let routes: [MockRoute] = [
            .json(.get, "/api/conversations", #"{"conversations":[]}"#),
            .json(.get, "/api/backends", Fixtures.noBackends),
            .json(.get, "/rest/v1/api_keys", "[]"),
            .json(.get, "/rest/v1/profiles", #"[{"onboarding":{}}]"#),
        ]
        UserDefaults.standard.set("Chats", forKey: "pref.chat.section")
        defer { UserDefaults.standard.removeObject(forKey: "pref.chat.section") }
        try snapshot(
            PreviewHost(routes: routes, delay: 0.05, embedInNavigation: true) { ChatRootView() },
            named: "home-starter-connect-card",
            // Taller than a phone, so the card under the buttons is in the picture; on a phone it is a scroll away.
            size: CGSize(width: 393, height: 1100),
            settle: 1.5
        )
    }

    func testTheCardAtTheLargestType() throws {
        try snapshot(
            ConnectCard(onConnect: {}, onDismiss: {})
                .padding(HV.Space.m)
                .frame(maxHeight: .infinity, alignment: .top)
                .hvScreenBackground()
                .environment(\.dynamicTypeSize, .accessibility3),
            named: "canvas-connect-card-large"
        )
    }
}
