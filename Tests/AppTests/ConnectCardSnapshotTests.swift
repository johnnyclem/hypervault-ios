import HyperVaultKit
import SwiftUI
import XCTest
@testable import HyperVault

/// The first-run connect card: on Home under the hints for someone with no key and no model, and on its own at the largest
/// accessibility type, where the icon goes above the title and the buttons keep their width.
@MainActor
final class ConnectCardSnapshotTests: XCTestCase {
    private let origin = URL(string: "https://hypervault.store")!

    func testTheCardOnHome() throws {
        let routes: [MockRoute] = [
            .json(.get, "/api/backends", Fixtures.noBackends),
            .json(.get, "/rest/v1/api_keys", "[]"),
            .json(.get, "/rest/v1/profiles", #"[{"onboarding":{}}]"#),
        ]
        let model = CanvasModel(client: AppEnvironment.preview().client, origin: origin)
        try snapshot(
            PreviewHost(routes: routes, delay: 0.05, embedInNavigation: true) {
                CanvasScreen(model: model, origin: origin, userName: "Sam", avatarName: "Sam Rivers", avatarURL: nil)
            },
            named: "canvas-connect-card",
            // Taller than a phone, so the card under the hints is in the picture; on a phone it is a scroll away.
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
