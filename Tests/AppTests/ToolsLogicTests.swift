import HyperVaultKit
import SwiftUI
import XCTest
@testable import HyperVault

/// A counter that closures on any thread may bump.
private final class Tally: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var bodies: [Data] = []

    @discardableResult
    func hit(_ body: Data? = nil) -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        if let body { bodies.append(body) }
        return count
    }

    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    var sent: [Data] { lock.lock(); defer { lock.unlock() }; return bodies }
}

private func temporaryCache() -> DiskCache {
    DiskCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("hv-tools-\(UUID().uuidString)"))
}

private func client(_ transport: HTTPTransport) -> HVClient {
    HVClient(baseURL: URL(string: "https://t.test")!, transport: transport, tokens: StaticTokenProvider(), retry: .none, sleep: { _ in })
}

private func pause(_ seconds: Double) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}

@MainActor
final class ToolsLogicTests: XCTestCase {
    /// A model loaded from the fixtures. Routes in `extra` win over the fixtures'.
    private func loadedModel(extra: [MockRoute], maxServers: Int = 20) async -> ToolsModel {
        let transport = MockTransport(routes: extra + ToolsFixtures.routes)
        let model = ToolsModel(client: client(transport), cache: temporaryCache(), namespace: "u1", maxServers: maxServers)
        await model.load()
        return model
    }

    func testTheListLoadsAndCountsWhatIsOn() async {
        let model = await loadedModel(extra: [])
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(model.servers.map(\.name), ["Linear", "Team notes", "Weather"])
        XCTAssertEqual(model.enabledToolCount, 4, "Linear has 2 of 3 on, Team notes 2, Weather is off")
        XCTAssertEqual(model.toolkit.toolkit?.stats.toolCount, 5)
        XCTAssertTrue(model.needsCompile, "the server said the toolkit is stale")
    }

    func testAFewTapsBecomeOneSave() async throws {
        let tally = Tally()
        let patch = MockRoute(.patch, "/api/mcp-servers/s1") { request in
            tally.hit(request.httpBody)
            return HTTPResponse(status: 200, data: Data(#"{"server":{"id":"s1","name":"Linear","url":"https://mcp.linear.app/mcp","disabled_tools":["create_issue","delete_issue"],"tools_cache":[{"name":"list_issues"},{"name":"create_issue"},{"name":"delete_issue"}],"has_auth":true,"auth_type":"oauth"}}"#.utf8))
        }
        let model = await loadedModel(extra: [patch])
        model.setTool("create_issue", on: false, serverID: "s1")
        model.setTool("create_issue", on: true, serverID: "s1")
        model.setTool("create_issue", on: false, serverID: "s1")
        XCTAssertEqual(model.server(id: "s1")?.disabledTools, ["create_issue", "delete_issue"], "shown at once")
        await pause(1.2)
        XCTAssertEqual(tally.value, 1)
        let body = try JSONDecoder().decode(JSONValue.self, from: try XCTUnwrap(tally.sent.first))
        XCTAssertEqual(body["disabled_tools"]?.array?.compactMap(\.string), ["create_issue", "delete_issue"])
    }

    func testARefusedSaveRollsBackAndSaysWhy() async {
        let refused = MockRoute.failure(.patch, "/api/mcp-servers/s1", status: 500, message: "The server had a problem. Try again in a moment.")
        let model = await loadedModel(extra: [refused])
        var reported: [String] = []
        model.reportError = { reported.append(($0 as? HVError)?.userMessage ?? "other") }
        model.setTool("list_issues", on: false, serverID: "s1")
        XCTAssertEqual(model.server(id: "s1")?.disabledTools, ["delete_issue", "list_issues"])
        await pause(1.2)
        XCTAssertEqual(model.server(id: "s1")?.disabledTools, ["delete_issue"], "back to what the server has")
        XCTAssertEqual(reported, ["The server had a problem. Try again in a moment."])
    }

    func testSwitchingAServerOffRollsBackToo() async {
        let refused = MockRoute.failure(.patch, "/api/mcp-servers/s1", status: 500, message: "Nope.")
        let model = await loadedModel(extra: [refused])
        await model.setEnabled(false, serverID: "s1")
        XCTAssertEqual(model.server(id: "s1")?.enabled, true)
    }

    func testRemovingAServerForgetsItAndRemembersToCompile() async {
        let removed = MockRoute.json(.delete, "/api/mcp-servers/s3", #"{"ok":true,"message":"Removed. Compiled toolkits keep working until you compile again."}"#)
        let model = await loadedModel(extra: [removed])
        var said: [String] = []
        model.reportSuccess = { said.append($0) }
        let ok = await model.remove(serverID: "s3")
        XCTAssertTrue(ok)
        XCTAssertEqual(model.servers.map(\.id), ["s1", "s2"])
        XCTAssertEqual(said, ["Removed. Compiled toolkits keep working until you compile again."])
        XCTAssertTrue(model.hasUncompiledChanges)
        UserDefaults.standard.removeObject(forKey: "tools.uncompiled.u1")
    }

    func testRefreshThatWantsALoginMarksTheServer() async {
        let challenge = MockRoute.json(.post, "/api/mcp-servers/s1/refresh", #"{"error":"Authorization expired — reconnect this server.","auth_required":true}"#, status: 401)
        let model = await loadedModel(extra: [challenge])
        var said: [String] = []
        model.reportError = { said.append(($0 as? HVError)?.userMessage ?? "") }
        await model.refresh(serverID: "s1")
        XCTAssertTrue(model.needsSignIn.contains("s1"))
        XCTAssertEqual(said, ["Authorization expired — reconnect this server."])
    }

    // MARK: Adding

    func testTheAddFlowRefusesADuplicateAndAFullList() async {
        let model = await loadedModel(extra: [], maxServers: 3)
        let http = client(MockTransport())
        let duplicate = ToolsAddFlow(candidate: ToolsCandidate(url: "https://mcp.linear.app/mcp/"), client: http, model: model)
        let none = await duplicate.add()
        XCTAssertNil(none)
        XCTAssertEqual(duplicate.error, "That server is already added.")

        let fresh = ToolsAddFlow(candidate: ToolsCandidate(url: "https://new.example.com/mcp"), client: http, model: model)
        let blocked = await fresh.add()
        XCTAssertNil(blocked)
        XCTAssertEqual(fresh.error, "Limit of 3 MCP servers reached.")

        let typo = ToolsAddFlow(candidate: ToolsCandidate(url: "not a url"), client: http, model: model)
        _ = await typo.add()
        XCTAssertEqual(typo.error, "Enter the server's address, like https://mcp.example.com/mcp.")
    }

    func testAServerThatWantsALoginSendsTheFlowToSignIn() async {
        let challenge = MockRoute.json(.post, "/api/mcp-servers", #"{"error":"This MCP server requires authorization.","auth_required":true,"url":"https://new.example.com/mcp"}"#, status: 401)
        let model = await loadedModel(extra: [challenge])
        let flow = ToolsAddFlow(candidate: ToolsCandidate(url: "https://new.example.com/mcp", name: "New"), client: client(MockTransport(routes: [challenge])), model: model)
        let added = await flow.add()
        XCTAssertNil(added)
        guard case .needsSignIn = flow.stage else { return XCTFail("expected the sign-in step, got \(flow.stage)") }
        XCTAssertEqual(flow.authFlow?.target.displayName, "New")
    }

    func testAddingAServerPutsItInTheListAndKeepsSecretsOutOfIt() async throws {
        let created = MockRoute.json(.post, "/api/mcp-servers", #"{"server":{"id":"n1","name":"New","url":"https://new.example.com/mcp","enabled":true,"disabled_tools":[],"tools_cache":[{"name":"ping"}],"has_auth":true,"secret_backed":true,"auth_type":"headers"},"message":"Connected — 1 tool discovered. Compile to use them in chat."}"#)
        let model = await loadedModel(extra: [created])
        let flow = ToolsAddFlow(candidate: nil, client: client(MockTransport(routes: [created])), model: model)
        flow.url = "new.example.com/mcp"
        flow.addHeader()
        flow.headers[0].name = "X-Api-Key"
        flow.headers[0].value = "s3cret"
        flow.saveToVault = true
        var said: [String] = []
        model.reportSuccess = { said.append($0) }
        let added = await flow.add()
        XCTAssertEqual(added?.id, "n1")
        XCTAssertEqual(model.servers.last?.id, "n1")
        XCTAssertTrue(flow.headers.isEmpty, "the key is not kept after it is sent")
        XCTAssertEqual(said, ["Connected — 1 tool discovered. Compile to use them in chat."])
        UserDefaults.standard.removeObject(forKey: "tools.uncompiled.u1")
    }

    // MARK: Compile

    func testACompileThatSucceedsClearsTheNudge() async {
        let model = await loadedModel(extra: [])
        XCTAssertTrue(model.needsCompile)
        model.startCompile()
        XCTAssertTrue(model.compile.isRunning)
        for _ in 0..<40 where model.compile.isRunning { await pause(0.1) }
        guard case .finished(let result) = model.compile else { return XCTFail("expected finished, got \(model.compile)") }
        XCTAssertEqual(result.stats.uniqueSelectorCount, 5)
        XCTAssertFalse(model.needsCompile)
        XCTAssertEqual(model.toolkit.toolkit?.id, "k2")
    }

    func testACompileThatTheServerRefusesShowsItsSentence() async {
        let refused = MockRoute.json(.post, "/api/toolkits/compile", #"{"error":"no_enabled_tools","message":"Every tool is toggled off — enable at least one."}"#, status: 422)
        let model = await loadedModel(extra: [refused])
        model.startCompile()
        for _ in 0..<40 where model.compile.isRunning { await pause(0.1) }
        XCTAssertEqual(model.compile, .failed("Every tool is toggled off — enable at least one."))
    }

    func testACompileCutOffByTheNetworkIsFoundOnceItLands() async {
        let flaky = FlakyCompileTransport()
        let model = ToolsModel(client: client(flaky), cache: temporaryCache(), namespace: "u2", maxServers: 20)
        model.recoveryPoll = 50_000_000
        await model.load()
        model.startCompile()
        for _ in 0..<60 where model.compile.isRunning { await pause(0.1) }
        guard case .recovered(let toolkit) = model.compile else { return XCTFail("expected recovered, got \(model.compile)") }
        XCTAssertEqual(toolkit.id, "k9")
    }

    func testStoppingTheWaitSaysSo() async {
        let model = ToolsModel(client: client(HangingTransport()), cache: temporaryCache(), namespace: "u3", maxServers: 20)
        model.didAdd(McpServer(id: "x", name: "X", url: "https://x.example.com", tools: [McpToolInfo(name: "t")]), message: nil)
        model.startCompile()
        XCTAssertTrue(model.compile.isRunning)
        await pause(0.2)
        model.stopWaiting()
        for _ in 0..<40 where model.compile.isRunning { await pause(0.1) }
        XCTAssertEqual(model.compile, .stopped)
        UserDefaults.standard.removeObject(forKey: "tools.uncompiled.u3")
    }
}

/// Never answers, but gives up when the task is cancelled.
private struct HangingTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        try await Task.sleep(nanoseconds: 60_000_000_000)
        return HTTPResponse(status: 504)
    }
}

/// Answers the compile call with a dropped connection, then reports the toolkit as built.
private struct FlakyCompileTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let path = request.url?.path ?? ""
        if path == "/api/toolkits/compile" { throw URLError(.networkConnectionLost) }
        if path == "/api/mcp-servers" {
            return HTTPResponse(status: 200, data: Data(#"{"servers":[{"id":"s1","name":"A","url":"https://a.example.com","tools_cache":[{"name":"t"}]}]}"#.utf8))
        }
        if path == "/api/toolkits" {
            let now = HVDate.format(Date().addingTimeInterval(5))
            return HTTPResponse(status: 200, data: Data(#"{"toolkit":{"id":"k9","stats":{"toolCount":1,"uniqueSelectorCount":1,"providerCount":1,"collisionCount":0},"embedder_label":"semantic","compiled_at":"\#(now)"},"stale":false}"#.utf8))
        }
        return HTTPResponse(status: 404, data: Data(#"{"error":"No route"}"#.utf8))
    }
}
