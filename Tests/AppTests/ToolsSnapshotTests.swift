import HyperVaultKit
import SwiftUI
import XCTest
@testable import HyperVault

@MainActor
final class ToolsSnapshotTests: XCTestCase {
    func testConnectedTools() throws {
        try snapshot(PreviewHost(routes: ToolsFixtures.routes) { ToolsRootView() }, named: "tools-list")
    }

    func testNoToolsYet() throws {
        try snapshot(PreviewHost(routes: ToolsFixtures.emptyRoutes) { ToolsRootView() }, named: "tools-empty")
    }

    func testServerDetail() throws {
        try snapshot(
            PreviewHost(routes: ToolsFixtures.routes) {
                ToolsModelHost { model, client in ToolsServerDetailView(model: model, serverID: "s1", client: client) }
            },
            named: "tools-server"
        )
    }

    func testAddByAddress() throws {
        try snapshot(
            PreviewHost(routes: ToolsFixtures.routes, embedInNavigation: false) {
                ToolsModelHost { model, client in ToolsAddServerSheet(candidate: nil, client: client, model: model) }
            },
            named: "tools-add-form"
        )
    }

    func testLookingInsideAServer() throws {
        let candidate = ToolsCandidate(url: "https://notes.example.com/mcp", name: "Team notes", transport: "streamable-http")
        try snapshot(
            PreviewHost(routes: ToolsFixtures.routes, embedInNavigation: false) {
                ToolsModelHost { model, client in ToolsAddServerSheet(candidate: candidate, client: client, model: model) }
            },
            named: "tools-add-preview"
        )
    }

    func testAServerThatWantsASignIn() throws {
        try snapshot(
            PreviewHost(routes: ToolsFixtures.routes, embedInNavigation: false) {
                ToolsModelHost { model, client in Self.signInSheet(model: model, client: client) }
            },
            named: "tools-add-signin"
        )
    }

    func testCatalog() throws {
        try snapshot(
            PreviewHost(routes: ToolsFixtures.routes, embedInNavigation: false) {
                ToolsModelHost { model, client in ToolsCatalogSheet(model: model, client: client) }
            },
            named: "tools-catalog"
        )
    }

    func testCompileRunning() throws {
        try snapshot(
            PreviewHost(routes: ToolsFixtures.routes, embedInNavigation: false) {
                ToolsModelHost(prepare: { $0.previewCompile(.running(since: Date().addingTimeInterval(-42), servers: 2, tools: 5)) }) { model, _ in
                    ToolsCompileSheet(model: model)
                }
            },
            named: "tools-compile-running"
        )
    }

    func testCompileDone() throws {
        let result = try HVCoding.decoder(.verbatim).decode(McpCompileResult.self, from: Data(ToolsFixtures.compileJSON.utf8))
        try snapshot(
            PreviewHost(routes: ToolsFixtures.routes, embedInNavigation: false) {
                ToolsModelHost(prepare: { $0.previewCompile(.finished(result)) }) { model, _ in ToolsCompileSheet(model: model) }
            },
            named: "tools-compile-done"
        )
    }

    func testCompileFailed() throws {
        try snapshot(
            PreviewHost(routes: ToolsFixtures.routes, embedInNavigation: false) {
                ToolsModelHost(prepare: { $0.previewCompile(.failed("Every tool is toggled off — enable at least one.")) }) { model, _ in
                    ToolsCompileSheet(model: model)
                }
            },
            named: "tools-compile-failed"
        )
    }

    private static func signInSheet(model: ToolsModel, client: HVClient) -> some View {
        let flow = ToolsAddFlow(candidate: ToolsCandidate(url: "https://mcp.linear.app/mcp", name: "Linear"), client: client, model: model)
        flow.previewNeedsSignIn(client: client, model: model)
        return ToolsAddServerSheet(flow: flow, model: model)
    }
}
