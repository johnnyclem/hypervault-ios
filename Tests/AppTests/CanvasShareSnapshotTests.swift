import HyperVaultKit
import SwiftUI
import XCTest
@testable import HyperVault

/// The Home canvas with Share on the cards of pages, files and groups (and none on a memory or a key), and the sheet it opens.
@MainActor
final class CanvasShareSnapshotTests: XCTestCase {
    private let origin = URL(string: "https://hypervault.store")!

    private let artifacts = #"{"items":[{"slug":"bakery-landing-page-x1","title":"Bakery landing page","type":"html","tags":[],"is_pwa":false,"is_jsx":false,"visibility":"private","created_at":"2026-10-20T10:00:00.000Z"}]}"#
    private let shares = #"{"shares":[{"id":"s1","email":"maya@example.com","display_name":"Maya","role":"edit","created_at":"2026-10-01T00:00:00.000Z"}],"roles":["view","use","edit"],"roles_enforced":true}"#

    /// A page, a group, a memory and a key on the page.
    private func canvas(_ size: DynamicTypeSize) -> some View {
        let model = CanvasModel(client: AppEnvironment.preview().client, origin: origin)
        let things = [
            KeptItem(id: "a1", kind: .page, name: "Bakery landing page", href: "/a/bakery-landing-page-x1"),
            KeptItem(id: "g1", kind: .group, name: "Portfolio site", href: "/g/portfolio-site"),
            KeptItem(id: "m1", kind: .memory, name: "Trip to Lisbon: ferry and passports", href: "/vault/memory?open=m1"),
            KeptItem(id: "k1", kind: .key, name: "OPENAI_API_KEY", href: "/vault/account"),
        ]
        for thing in things { model.dispatch(.add(CanvasState.itemCard(thing))) }
        let routes: [MockRoute] = [.json(.get, "/api/backends", Fixtures.backends), .json(.get, "/api/yours", Fixtures.yours)]
        return PreviewHost(routes: routes, embedInNavigation: true) {
            CanvasScreen(model: model, origin: origin, userName: "Sam", avatarName: "Sam Rivers", avatarURL: nil)
                .environment(\.dynamicTypeSize, size)
        }
    }

    /// The share sheet over the canvas for a page the canvas has not read yet.
    private struct SheetHost: View {
        @Environment(AppEnvironment.self) private var env
        @State private var detail: ArtifactDetailModel?

        var body: some View {
            Group {
                if let detail { CanvasShareSheet(detail: detail) } else { Color.clear }
            }
            .task { detail = ArtifactDetailModel(slug: "bakery-landing-page-x1", env: env, kindHint: .page) }
        }
    }

    func testCardsOfferShareExceptAMemoryAndAKey() throws {
        try snapshot(canvas(.large), named: "canvas-share-cards")
    }

    func testCardsOfferShareAtTheLargestType() throws {
        try snapshot(canvas(.accessibility3), named: "canvas-share-cards-large", settle: 2)
    }

    func testTheShareSheetOverTheCanvas() throws {
        let routes: [MockRoute] = [.json(.get, "/api/artifacts", artifacts), .json(.get, "/api/shares", shares)]
        try snapshot(PreviewHost(routes: routes, embedInNavigation: false) { SheetHost() }, named: "canvas-share-sheet", settle: 3)
    }
}
