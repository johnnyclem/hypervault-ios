import HyperVaultKit
import SwiftUI
import XCTest
@testable import HyperVault

@MainActor
final class CanvasSnapshotTests: XCTestCase {
    private let origin = URL(string: "https://hypervault.store")!

    private func screen(_ model: CanvasModel) -> some View {
        PreviewHost(routes: [.json(.get, "/api/backends", Fixtures.backends), .json(.get, "/api/yours", Fixtures.yours)], embedInNavigation: true) {
            CanvasScreen(model: model, origin: origin, userName: "Sam", avatarName: "Sam Rivers", avatarURL: nil)
        }
    }

    private func model() -> CanvasModel {
        CanvasModel(client: AppEnvironment.preview().client, origin: origin)
    }

    func testEmptyCanvas() throws {
        try snapshot(screen(model()), named: "canvas-empty")
    }

    func testKeptCardAndThread() throws {
        let canvas = model()
        let kept = KeptThing(slug: "bakery-landing-page-x1", url: "", kind: .page, form: "html", title: "Bakery landing page", visibility: "private", duplicate: false, message: "")
        canvas.dispatch(.add(CanvasState.keptCard(kept, origin: origin)))
        canvas.dispatch(.add(CanvasState.itemCard(KeptItem(id: "m1", kind: .memory, name: "Co-parenting schedule", summary: "Handoffs on Wednesday and every other weekend.", updatedAt: Date().addingTimeInterval(-3600), href: "/vault/memory?open=m1"))))
        canvas.say(HVCopy.helpLine)
        try snapshot(screen(canvas), named: "canvas-kept")
    }

    func testYours() throws {
        try snapshot(PreviewHost(routes: [.json(.get, "/api/yours", Fixtures.yours)]) { YoursRootView() }, named: "yours")
    }

    func testYoursEmpty() throws {
        try snapshot(PreviewHost(routes: [.json(.get, "/api/yours", #"{"recent":[],"results":[]}"#)]) { YoursRootView() }, named: "yours-empty")
    }
}
