import HyperVaultKit
import SwiftUI
import UIKit

/// What the compile sheet is showing.
enum ToolsCompileState: Equatable {
    case idle
    case running(since: Date, servers: Int, tools: Int)
    case finished(McpCompileResult)
    /// The connection dropped, but the toolkit turned out to be built.
    case recovered(McpToolkit)
    case failed(String)
    /// The person stopped waiting; the server may still finish.
    case stopped

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

/// The Tools screen's state: the servers a person has connected, the compiled
/// toolkit, and every change to either. Toggles are saved as they are made (a
/// short pause lets a run of taps become one request) and roll back if the
/// server says no. Nothing reaches a chat until the toolkit is compiled.
@MainActor
@Observable
final class ToolsModel {
    enum Phase: Equatable { case loading, loaded, failed(String) }

    private(set) var phase: Phase = .loading
    private(set) var servers: [McpServer] = []
    private(set) var toolkit = McpToolkitStatus()
    private(set) var isShowingSavedCopy = false
    /// Servers whose last refresh said they want a new login.
    private(set) var needsSignIn: Set<String> = []
    /// Servers with a refresh or a removal in flight.
    private(set) var busy: Set<String> = []
    private(set) var compile: ToolsCompileState = .idle
    /// A change was made since the last compile (the server's own flag does
    /// not notice a server being switched off).
    private(set) var hasUncompiledChanges: Bool

    let maxServers: Int

    @ObservationIgnored var reportError: (Error) -> Void = { _ in }
    @ObservationIgnored var reportSuccess: (String) -> Void = { _ in }

    @ObservationIgnored private let client: HVClient
    @ObservationIgnored private let cache: DiskCache
    @ObservationIgnored private let namespace: String
    @ObservationIgnored private var saves: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var confirmedDisabled: [String: [String]] = [:]
    @ObservationIgnored private var compileTask: Task<Void, Never>?
    @ObservationIgnored private var lastCompileStart: Date?
    /// How long to wait between asking whether a dropped compile finished.
    @ObservationIgnored var recoveryPoll: UInt64 = 6_000_000_000

    init(client: HVClient, cache: DiskCache, namespace: String, maxServers: Int) {
        self.client = client
        self.cache = cache
        self.namespace = namespace
        self.maxServers = maxServers
        self.hasUncompiledChanges = UserDefaults.standard.bool(forKey: Self.dirtyKey(namespace))
    }

    private static func dirtyKey(_ namespace: String) -> String { "tools.uncompiled.\(namespace)" }

    // MARK: Derived

    func server(id: String) -> McpServer? { servers.first { $0.id == id } }

    var enabledToolCount: Int { servers.reduce(0) { $0 + $1.enabledToolCount } }
    var enabledServerCount: Int { servers.filter { $0.enabled && $0.enabledToolCount > 0 }.count }
    var isFull: Bool { servers.count >= maxServers }

    /// The toolkit is missing, or out of step with the servers.
    var needsCompile: Bool {
        guard enabledToolCount > 0 else { return false }
        return toolkit.toolkit == nil || toolkit.stale || hasUncompiledChanges
    }

    func isAlreadyAdded(url: String) -> Bool {
        let key = McpServer.normalize(url)
        return servers.contains { $0.normalizedURL == key }
    }

    // MARK: Loading

    func load() async {
        async let serverLoad: Void = loadServers()
        async let toolkitLoad: Void = loadToolkit()
        _ = await (serverLoad, toolkitLoad)
    }

    private func loadServers() async {
        let client = self.client
        do {
            for try await loaded in cachedLoad(cache: cache, namespace: namespace, key: "tools.servers", fetch: { try await client.send(.mcpServers) }) {
                adopt(loaded.value.servers)
                isShowingSavedCopy = loaded.isStale
                phase = .loaded
            }
        } catch {
            if servers.isEmpty { phase = .failed((error as? HVError)?.userMessage ?? error.localizedDescription) }
        }
    }

    private func loadToolkit() async {
        let client = self.client
        do {
            for try await loaded in cachedLoad(cache: cache, namespace: namespace, key: "tools.toolkit", fetch: { try await client.send(.mcpToolkit) }) {
                toolkit = loaded.value
                // A fresh answer that says "not stale" does not clear a local change.
            }
        } catch {
            // The list is the screen; the toolkit line simply stays as it was.
        }
    }

    private func adopt(_ list: [McpServer]) {
        servers = list
        for server in list { confirmedDisabled[server.id] = server.disabledTools }
        let ids = Set(list.map(\.id))
        needsSignIn.formIntersection(ids)
    }

    private func saveServers() {
        let list = McpServerList(servers: servers)
        let cache = self.cache, namespace = self.namespace
        Task { await cache.store(list, key: "tools.servers", namespace: namespace) }
    }

    private func markChanged() {
        hasUncompiledChanges = true
        UserDefaults.standard.set(true, forKey: Self.dirtyKey(namespace))
    }

    private func replace(_ server: McpServer) {
        guard let index = servers.firstIndex(where: { $0.id == server.id }) else { return }
        servers[index] = server
        confirmedDisabled[server.id] = server.disabledTools
    }

    // MARK: Switches

    func setEnabled(_ on: Bool, serverID: String) async {
        guard let before = server(id: serverID), before.enabled != on else { return }
        update(serverID) { $0.enabled = on }
        do {
            let answer = try await client.send(.updateMcpServer(id: serverID, enabled: on))
            replace(answer.server)
            markChanged()
            saveServers()
        } catch {
            update(serverID) { $0.enabled = before.enabled }
            reportError(error)
        }
    }

    func setTool(_ name: String, on: Bool, serverID: String) {
        guard let current = server(id: serverID) else { return }
        let disabled = current.disabledTools(setting: name, enabled: on)
        update(serverID) { $0.disabledTools = disabled }
        scheduleSave(serverID)
    }

    func setAllTools(on: Bool, serverID: String) {
        guard let current = server(id: serverID) else { return }
        let disabled = current.disabledToolsSettingAll(enabled: on)
        update(serverID) { $0.disabledTools = disabled }
        scheduleSave(serverID)
    }

    /// One request for a run of taps: the list is sent once things go quiet.
    private func scheduleSave(_ serverID: String) {
        saves[serverID]?.cancel()
        saves[serverID] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            await self?.flushTools(serverID)
        }
    }

    private func flushTools(_ serverID: String) async {
        saves[serverID] = nil
        guard let current = server(id: serverID) else { return }
        let sending = current.disabledTools
        if sending == confirmedDisabled[serverID] { return }
        do {
            let answer = try await client.send(.updateMcpServer(id: serverID, disabledTools: sending))
            // Taps made while this was in flight stay; only the confirmed copy moves.
            confirmedDisabled[serverID] = answer.server.disabledTools
            if saves[serverID] == nil { replace(answer.server) }
            markChanged()
            saveServers()
        } catch {
            if saves[serverID] == nil {
                let back = confirmedDisabled[serverID] ?? []
                update(serverID) { $0.disabledTools = back }
            }
            reportError(error)
        }
    }

    private func update(_ id: String, _ change: (inout McpServer) -> Void) {
        guard let index = servers.firstIndex(where: { $0.id == id }) else { return }
        change(&servers[index])
    }

    // MARK: Refresh, rename, remove

    func refresh(serverID: String) async {
        guard !busy.contains(serverID) else { return }
        busy.insert(serverID)
        defer { busy.remove(serverID) }
        do {
            let result = try await client.send(.refreshMcpServer(id: serverID))
            update(serverID) {
                $0.tools = result.tools
                $0.disabledTools = result.disabledTools
                $0.introspectedAt = result.introspectedAt
            }
            confirmedDisabled[serverID] = result.disabledTools
            needsSignIn.remove(serverID)
            markChanged()
            saveServers()
            reportSuccess("Read \(result.tools.count) tool\(result.tools.count == 1 ? "" : "s").")
        } catch let error as HVError where error.isMcpAuthRequired {
            needsSignIn.insert(serverID)
            reportError(error)
        } catch {
            reportError(error)
        }
    }

    func remove(serverID: String) async -> Bool {
        guard !busy.contains(serverID) else { return false }
        busy.insert(serverID)
        defer { busy.remove(serverID) }
        do {
            let ack = try await client.send(.deleteMcpServer(id: serverID))
            saves[serverID]?.cancel()
            saves[serverID] = nil
            servers.removeAll { $0.id == serverID }
            markChanged()
            saveServers()
            reportSuccess(ack.message ?? "Removed.")
            return true
        } catch {
            reportError(error)
            return false
        }
    }

    func replaceHeaders(serverID: String, headers: [String: String]) async -> Bool {
        do {
            let answer = try await client.send(.replaceMcpHeaders(id: serverID, headers: headers))
            replace(answer.server)
            needsSignIn.remove(serverID)
            markChanged()
            saveServers()
            return true
        } catch {
            reportError(error)
            return false
        }
    }

    // MARK: Adding

    /// A server was connected (by the add sheet, a quick add or a login).
    func didAdd(_ server: McpServer, message: String?) {
        if let index = servers.firstIndex(where: { $0.id == server.id || $0.normalizedURL == server.normalizedURL }) {
            servers[index] = server
        } else {
            servers.append(server)
        }
        confirmedDisabled[server.id] = server.disabledTools
        needsSignIn.remove(server.id)
        markChanged()
        saveServers()
        if phase != .loaded { phase = .loaded }
        if let message { reportSuccess(message) }
    }

    /// After a browser login: the callback page cannot tell the app how it
    /// went, so ask the server what it has now. A login counts when the server
    /// has the address with a sign-in on it and it was read after `previous`.
    func serverAfterLogin(url: String, previous: McpServer?) async -> McpServer? {
        let client = self.client
        guard let list = try? await client.send(.mcpServers) else { return nil }
        adopt(list.servers)
        saveServers()
        let key = McpServer.normalize(url)
        guard let found = list.servers.first(where: { $0.normalizedURL == key }), found.hasAuth else { return nil }
        if let previous, let before = previous.introspectedAt, let after = found.introspectedAt, after <= before {
            return nil
        }
        needsSignIn.remove(found.id)
        markChanged()
        return found
    }

    // MARK: Compile

    func startCompile() {
        guard compileTask == nil, enabledToolCount > 0 else { return }
        let started = Date()
        lastCompileStart = started
        compile = .running(since: started, servers: enabledServerCount, tools: enabledToolCount)
        compileTask = Task { [weak self] in
            let grace = ToolsBackgroundGrace(name: "Compile tools")
            await self?.runCompile(started: started)
            grace.end()
        }
    }

    /// Stops waiting for the answer. The server does not stop: it may well finish.
    func stopWaiting() {
        compileTask?.cancel()
    }

    func dismissCompile() {
        if !compile.isRunning { compile = .idle }
    }

    /// After stopping to wait: has the toolkit been built since?
    func checkToolkitNow() async {
        await loadToolkit()
        if let start = lastCompileStart, toolkit.compiled(since: start), let built = toolkit.toolkit {
            hasUncompiledChanges = false
            UserDefaults.standard.set(false, forKey: Self.dirtyKey(namespace))
            compile = .recovered(built)
            Haptics.success()
        } else {
            reportSuccess("Not finished yet. Check again in a minute.")
        }
    }

    private func runCompile(started: Date) async {
        defer { compileTask = nil }
        do {
            let result = try await client.send(.compileMcpToolkit)
            toolkit = McpToolkitStatus(
                toolkit: McpToolkit(id: result.toolkitId, stats: result.stats, embedderLabel: result.embedderLabel, compiledAt: Date()),
                stale: false
            )
            hasUncompiledChanges = false
            UserDefaults.standard.set(false, forKey: Self.dirtyKey(namespace))
            compile = .finished(result)
            Haptics.success()
        } catch let error as HVError {
            switch error {
            case .cancelled:
                compile = .stopped
            case .transport:
                // The phone lost the connection (or was put away); the server keeps going.
                if let landed = await waitForToolkit(since: started) {
                    compile = .recovered(landed)
                    Haptics.success()
                } else if Task.isCancelled {
                    compile = .stopped
                } else {
                    compile = .failed(error.userMessage)
                }
            default:
                compile = .failed(error.mcpCompileSentence)
                Haptics.failure()
            }
        } catch {
            compile = .failed(error.localizedDescription)
        }
    }

    /// Asks every few seconds whether the toolkit has been built since `start`.
    private func waitForToolkit(since start: Date) async -> McpToolkit? {
        for _ in 0..<24 {
            try? await Task.sleep(nanoseconds: recoveryPoll)
            if Task.isCancelled { return nil }
            if let status = try? await client.send(.mcpToolkit), status.compiled(since: start), let built = status.toolkit {
                toolkit = status
                hasUncompiledChanges = false
                UserDefaults.standard.set(false, forKey: Self.dirtyKey(namespace))
                return built
            }
        }
        return nil
    }
}

/// Asks iOS for a little more time when the app is put away mid-request, so a
/// compile or an import is not cut off the moment someone checks a message.
@MainActor
final class ToolsBackgroundGrace {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init(name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            self?.end()
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

#if DEBUG
extension ToolsModel {
    /// Puts the compile sheet in a state a snapshot can show.
    func previewCompile(_ state: ToolsCompileState) {
        compile = state
    }
}
#endif
