import Foundation

// Tools: the remote services (MCP servers) a person's chats can use. The wire
// is `app/api/mcp-servers/**`, `app/api/toolkits/**` and `app/api/registry/**`
// in the web app. Those routes mix snake_case rows (`disabled_tools`) with
// camelCase objects (`toolkitId`, `registryId`) and carry JSON-schema
// dictionaries whose keys must survive, so every call here decodes with
// `keys: .verbatim` and explicit coding keys.

// MARK: Servers

/// How a connected server knows who you are: a login you approved in the
/// browser (OAuth), headers you pasted, or nothing at all.
public enum McpAuthType: String, Sendable, Codable, Hashable {
    case oauth, headers, none

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = McpAuthType(rawValue: raw) ?? .none
    }
}

/// One parameter of a tool, read from its JSON-schema input for display.
public struct McpToolParameter: Sendable, Hashable, Identifiable {
    public let name: String
    public let type: String?
    public let isRequired: Bool
    public let summary: String?

    public var id: String { name }
}

/// One tool a server offers (an entry of the server's cached `tools_cache`).
public struct McpToolInfo: Sendable, Codable, Hashable, Identifiable {
    public let name: String
    public let description: String
    public let inputSchema: JSONValue?

    public var id: String { name }

    public init(name: String, description: String = "", inputSchema: JSONValue? = nil) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }

    enum CodingKeys: String, CodingKey {
        case name, description
        case inputSchema = "input_schema"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        inputSchema = try c.decodeIfPresent(JSONValue.self, forKey: .inputSchema)
    }

    /// The tool's parameters in the schema's order of appearance is not
    /// guaranteed by JSON, so they are sorted: required first, then by name.
    public var parameters: [McpToolParameter] {
        guard let properties = inputSchema?["properties"]?.object else { return [] }
        let required = Set(inputSchema?["required"]?.array?.compactMap(\.string) ?? [])
        let list = properties.map { name, definition -> McpToolParameter in
            let type: String?
            if let single = definition["type"]?.string {
                type = single
            } else if let several = definition["type"]?.array?.compactMap(\.string), !several.isEmpty {
                type = several.joined(separator: " | ")
            } else {
                type = nil
            }
            return McpToolParameter(
                name: name,
                type: type,
                isRequired: required.contains(name),
                summary: definition["description"]?.string
            )
        }
        return list.sorted { lhs, rhs in
            if lhs.isRequired != rhs.isRequired { return lhs.isRequired }
            return lhs.name < rhs.name
        }
    }
}

/// What a server row looks like at a glance.
public enum McpServerStatus: Sendable, Equatable {
    /// Switched off: new chats will not use it.
    case off
    /// On, but the server offered no tools the last time it was read.
    case noTools
    /// On, with every tool switched off one by one.
    case allToolsOff
    case on
}

/// A connected MCP server, as `GET /api/mcp-servers` lists it. Never carries a
/// credential: only whether one is stored and where.
public struct McpServer: Sendable, Codable, Identifiable, Hashable {
    /// The most tools a server can have switched off (the route keeps 500).
    public static let maxDisabledTools = 500

    public let id: String
    public var name: String
    public var url: String
    public var enabled: Bool
    public var disabledTools: [String]
    public var tools: [McpToolInfo]
    public var introspectedAt: Date?
    public var registryId: String?
    public var hasAuth: Bool
    /// True when the credential lives in the saved-secrets vault.
    public var secretBacked: Bool
    public var authType: McpAuthType
    public var createdAt: Date?

    public init(
        id: String,
        name: String,
        url: String,
        enabled: Bool = true,
        disabledTools: [String] = [],
        tools: [McpToolInfo] = [],
        introspectedAt: Date? = nil,
        registryId: String? = nil,
        hasAuth: Bool = false,
        secretBacked: Bool = false,
        authType: McpAuthType? = nil,
        createdAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.enabled = enabled
        self.disabledTools = disabledTools
        self.tools = tools
        self.introspectedAt = introspectedAt
        self.registryId = registryId
        self.hasAuth = hasAuth
        self.secretBacked = secretBacked
        self.authType = authType ?? (hasAuth ? .headers : .none)
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, name, url, enabled
        case disabledTools = "disabled_tools"
        case tools = "tools_cache"
        case introspectedAt = "introspected_at"
        case registryId = "registry_id"
        case hasAuth = "has_auth"
        case secretBacked = "secret_backed"
        case authType = "auth_type"
        case createdAt = "created_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        let fallbackName = URL(string: url)?.host ?? "Server"
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? fallbackName
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        disabledTools = try c.decodeIfPresent([String].self, forKey: .disabledTools) ?? []
        tools = try c.decodeIfPresent([McpToolInfo].self, forKey: .tools) ?? []
        introspectedAt = try c.decodeIfPresent(Date.self, forKey: .introspectedAt)
        registryId = try c.decodeIfPresent(String.self, forKey: .registryId)
        hasAuth = try c.decodeIfPresent(Bool.self, forKey: .hasAuth) ?? false
        secretBacked = try c.decodeIfPresent(Bool.self, forKey: .secretBacked) ?? false
        // The web's own fallback: an older row without `auth_type` is headers
        // when it has auth, none otherwise.
        authType = try c.decodeIfPresent(McpAuthType.self, forKey: .authType) ?? (hasAuth ? .headers : .none)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
    }

    /// The address without its scheme and path: `mcp.example.com`.
    public var host: String { URL(string: url)?.host ?? url }

    /// The address as compared for "already added": no trailing slash, any case.
    public var normalizedURL: String { Self.normalize(url) }

    public static func normalize(_ url: String) -> String {
        var text = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        return text.lowercased()
    }

    public func isToolEnabled(_ name: String) -> Bool { !disabledTools.contains(name) }

    /// How many of the server's tools are switched on (0 while the server is off).
    public var enabledToolCount: Int {
        guard enabled else { return 0 }
        let off = Set(disabledTools)
        return tools.filter { !off.contains($0.name) }.count
    }

    public var status: McpServerStatus {
        if !enabled { return .off }
        if tools.isEmpty { return .noTools }
        if enabledToolCount == 0 { return .allToolsOff }
        return .on
    }

    /// The disabled list after switching one tool, sorted and capped.
    public func disabledTools(setting tool: String, enabled isOn: Bool) -> [String] {
        var off = Set(disabledTools)
        if isOn { off.remove(tool) } else { off.insert(tool) }
        return Self.capped(off)
    }

    /// The disabled list after switching every tool on or off.
    public func disabledToolsSettingAll(enabled isOn: Bool) -> [String] {
        isOn ? [] : Self.capped(Set(tools.map(\.name)))
    }

    private static func capped(_ names: Set<String>) -> [String] {
        Array(names.sorted().prefix(maxDisabledTools))
    }
}

public struct McpServerList: Sendable, Codable, Equatable {
    public let servers: [McpServer]

    public init(servers: [McpServer] = []) { self.servers = servers }

    enum CodingKeys: String, CodingKey { case servers }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        servers = try c.decodeIfPresent([McpServer].self, forKey: .servers) ?? []
    }
}

/// The `{ server }` answer of an update, or `{ server, message }` of an add.
public struct McpServerEnvelope: Sendable, Decodable {
    public let server: McpServer
    public let message: String?

    enum CodingKeys: String, CodingKey { case server, message }
}

/// The `{ ok, message }` answer of a delete.
public struct McpAck: Sendable, Decodable {
    public let ok: Bool?
    public let message: String?
}

/// `POST /api/mcp-servers/[id]/refresh`.
public struct McpRefreshResult: Sendable, Decodable {
    public let tools: [McpToolInfo]
    public let disabledTools: [String]
    public let introspectedAt: Date?

    enum CodingKeys: String, CodingKey {
        case tools
        case disabledTools = "disabled_tools"
        case introspectedAt = "introspected_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tools = try c.decodeIfPresent([McpToolInfo].self, forKey: .tools) ?? []
        disabledTools = try c.decodeIfPresent([String].self, forKey: .disabledTools) ?? []
        introspectedAt = try c.decodeIfPresent(Date.self, forKey: .introspectedAt)
    }
}

/// `POST /api/mcp-servers/preview`: a server's tools without saving it.
public struct McpPreview: Sendable, Decodable {
    public let url: String
    public let name: String
    public let serverName: String?
    public let tools: [McpToolInfo]

    enum CodingKeys: String, CodingKey { case url, name, serverName, tools }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? url
        serverName = try c.decodeIfPresent(String.self, forKey: .serverName)
        tools = try c.decodeIfPresent([McpToolInfo].self, forKey: .tools) ?? []
    }
}

// MARK: Requests

/// What it takes to connect a server. Header values are credentials: the
/// description never prints them.
public struct McpAddRequest: Sendable, CustomStringConvertible {
    public var url: String
    public var name: String?
    public var headers: [String: String]
    public var registryId: String?
    /// Keep the credential as a named secret in the vault instead of on the server row.
    public var saveToVault: Bool

    public init(url: String, name: String? = nil, headers: [String: String] = [:], registryId: String? = nil, saveToVault: Bool = false) {
        self.url = url
        self.name = name
        self.headers = headers
        self.registryId = registryId
        self.saveToVault = saveToVault
    }

    public var description: String { "McpAddRequest(url: \(url), headers: \(headers.count) hidden)" }

    /// The body, with header names exactly as typed.
    public var body: JSONValue {
        var object: [String: JSONValue] = ["url": .string(url)]
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { object["name"] = .string(name) }
        if !headers.isEmpty { object["headers"] = .object(headers.mapValues { .string($0) }) }
        if let registryId, !registryId.isEmpty { object["registry_id"] = .string(registryId) }
        if saveToVault { object["save_to_vault"] = .bool(true) }
        return .object(object)
    }
}

/// Turns what a person types into the single header a server wants.
public enum McpAuthHeader {
    /// A bare token on the `Authorization` header is a bearer token (the
    /// web form does the same); anything with a space in it is sent as typed.
    public static func make(name: String, token: String) -> [String: String]? {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let header = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = header.isEmpty ? "Authorization" : header
        let isBare = !value.contains(where: \.isWhitespace)
        if key.lowercased() == "authorization", isBare { return [key: "Bearer \(value)"] }
        return [key: value]
    }
}

/// What the browser hands back when an OAuth login ends. Today the server's
/// callback is a web page that closes itself, so the app learns the outcome by
/// reading the server list again; if the callback ever redirects to
/// `hypervault://mcp-oauth?ok=1` (or `?error=...`), this reads it.
public enum McpOAuthResult: Sendable, Equatable {
    case connected
    case failed(String)
    /// Nothing the app recognises: check the server list instead.
    case unknown

    public init(callback url: URL) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = value("error_description") ?? value("error"), !error.isEmpty {
            self = .failed(error)
        } else if value("ok") == "1" || value("ok") == "true" {
            self = .connected
        } else if value("ok") == "0" || value("ok") == "false" {
            self = .failed(value("message") ?? "The login did not finish.")
        } else {
            self = .unknown
        }
    }
}

/// Reads the address a person typed.
public enum McpServerURL {
    /// A usable http(s) address, or nil. A missing scheme is taken to be https.
    public static func parse(_ text: String) -> URL? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains(where: \.isWhitespace) else { return nil }
        if !value.contains("://") { value = "https://" + value }
        while value.hasSuffix("/") { value.removeLast() }
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = url.host, host.contains(".") || host == "localhost"
        else { return nil }
        return url
    }
}

// MARK: Toolkit

public struct McpToolkitStats: Sendable, Codable, Hashable {
    public let toolCount: Int
    public let uniqueSelectorCount: Int
    public let providerCount: Int
    public let collisionCount: Int

    public init(toolCount: Int = 0, uniqueSelectorCount: Int = 0, providerCount: Int = 0, collisionCount: Int = 0) {
        self.toolCount = toolCount
        self.uniqueSelectorCount = uniqueSelectorCount
        self.providerCount = providerCount
        self.collisionCount = collisionCount
    }

    enum CodingKeys: String, CodingKey { case toolCount, uniqueSelectorCount, providerCount, collisionCount }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        toolCount = try c.decodeIfPresent(Int.self, forKey: .toolCount) ?? 0
        uniqueSelectorCount = try c.decodeIfPresent(Int.self, forKey: .uniqueSelectorCount) ?? 0
        providerCount = try c.decodeIfPresent(Int.self, forKey: .providerCount) ?? 0
        collisionCount = try c.decodeIfPresent(Int.self, forKey: .collisionCount) ?? 0
    }
}

/// The active compiled toolkit: the searchable index chats use to pick a tool.
public struct McpToolkit: Sendable, Codable, Hashable, Identifiable {
    public let id: String
    public let stats: McpToolkitStats
    public let embedderLabel: String
    public let compiledAt: Date?

    public init(id: String, stats: McpToolkitStats = McpToolkitStats(), embedderLabel: String = "", compiledAt: Date? = nil) {
        self.id = id
        self.stats = stats
        self.embedderLabel = embedderLabel
        self.compiledAt = compiledAt
    }

    enum CodingKeys: String, CodingKey {
        case id, stats
        case embedderLabel = "embedder_label"
        case compiledAt = "compiled_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        stats = try c.decodeIfPresent(McpToolkitStats.self, forKey: .stats) ?? McpToolkitStats()
        embedderLabel = try c.decodeIfPresent(String.self, forKey: .embedderLabel) ?? ""
        compiledAt = try c.decodeIfPresent(Date.self, forKey: .compiledAt)
    }

    /// Matching by wording alone, not by meaning: the model that reads
    /// meaning did not load when this was built.
    public var isLexical: Bool { embedderLabel.localizedCaseInsensitiveContains("lexical") }
}

/// `GET /api/toolkits`: the active toolkit, and whether a server changed since.
public struct McpToolkitStatus: Sendable, Codable, Equatable {
    public let toolkit: McpToolkit?
    public let stale: Bool

    public init(toolkit: McpToolkit? = nil, stale: Bool = false) {
        self.toolkit = toolkit
        self.stale = stale
    }

    enum CodingKeys: String, CodingKey { case toolkit, stale }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        toolkit = try c.decodeIfPresent(McpToolkit.self, forKey: .toolkit)
        stale = try c.decodeIfPresent(Bool.self, forKey: .stale) ?? false
    }

    /// Whether a compile that began at `start` has landed. Used when the
    /// connection dropped mid-compile (the server keeps going without us).
    public func compiled(since start: Date, slack: TimeInterval = 5) -> Bool {
        guard let compiledAt = toolkit?.compiledAt else { return false }
        return compiledAt >= start.addingTimeInterval(-slack)
    }
}

public struct McpSkippedServer: Sendable, Codable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let error: String

    enum CodingKeys: String, CodingKey { case id, name, error }

    public init(id: String, name: String, error: String) {
        self.id = id
        self.name = name
        self.error = error
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "A server"
        error = try c.decodeIfPresent(String.self, forKey: .error) ?? ""
    }
}

/// Two tools the matcher can barely tell apart.
public struct McpCollision: Sendable, Codable, Hashable {
    public let selectorA: String
    public let selectorB: String
    public let similarity: Double
    public let hint: String

    enum CodingKeys: String, CodingKey { case selectorA, selectorB, similarity, hint }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        selectorA = try c.decodeIfPresent(String.self, forKey: .selectorA) ?? ""
        selectorB = try c.decodeIfPresent(String.self, forKey: .selectorB) ?? ""
        similarity = try c.decodeIfPresent(Double.self, forKey: .similarity) ?? 0
        hint = try c.decodeIfPresent(String.self, forKey: .hint) ?? ""
    }
}

/// `POST /api/toolkits/compile`: what the build produced. (This object is
/// written camelCase by the server, unlike the rows above.)
public struct McpCompileResult: Sendable, Decodable, Equatable {
    public let toolkitId: String
    public let stats: McpToolkitStats
    public let embedderLabel: String
    public let embedderDegradeReason: String?
    public let skippedServers: [McpSkippedServer]
    public let collisions: [McpCollision]

    enum CodingKeys: String, CodingKey {
        case toolkitId, stats, embedderLabel, embedderDegradeReason, skippedServers, collisions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        toolkitId = try c.decodeIfPresent(String.self, forKey: .toolkitId) ?? ""
        stats = try c.decodeIfPresent(McpToolkitStats.self, forKey: .stats) ?? McpToolkitStats()
        embedderLabel = try c.decodeIfPresent(String.self, forKey: .embedderLabel) ?? ""
        embedderDegradeReason = try c.decodeIfPresent(String.self, forKey: .embedderDegradeReason)
        skippedServers = try c.decodeIfPresent([McpSkippedServer].self, forKey: .skippedServers) ?? []
        collisions = try c.decodeIfPresent([McpCollision].self, forKey: .collisions) ?? []
    }

    public var isLexical: Bool { embedderLabel.localizedCaseInsensitiveContains("lexical") }
}

// MARK: Registry

/// One server from the official MCP registry (remote-capable ones only).
public struct McpRegistryEntry: Sendable, Codable, Hashable, Identifiable {
    public let registryId: String
    public let name: String
    public let description: String
    public let url: String
    /// `streamable-http` or `sse`.
    public let transport: String
    /// The address answered HTTP 404/410 when last checked.
    public var dead: Bool

    public var id: String { registryId + "|" + url }

    public init(registryId: String, name: String, description: String = "", url: String, transport: String = "streamable-http", dead: Bool = false) {
        self.registryId = registryId
        self.name = name
        self.description = description
        self.url = url
        self.transport = transport
        self.dead = dead
    }

    enum CodingKeys: String, CodingKey { case registryId, name, description, url, transport, dead }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decode(String.self, forKey: .url)
        registryId = try c.decodeIfPresent(String.self, forKey: .registryId) ?? url
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? registryId
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        transport = try c.decodeIfPresent(String.self, forKey: .transport) ?? "streamable-http"
        dead = try c.decodeIfPresent(Bool.self, forKey: .dead) ?? false
    }

    public var normalizedURL: String { McpServer.normalize(url) }

    /// The transport as a person reads it: the catalog row and the preview header say the same words.
    public var transportLabel: String { Self.transportLabel(for: transport) }

    /// `streamable-http` and `sse` are the registry's own values; neither belongs on screen as written.
    public static func transportLabel(for transport: String) -> String {
        let key = transport.lowercased().replacingOccurrences(of: "_", with: "-")
        switch key {
        case "sse": return "SSE"
        case "streamable-http", "http": return "Streamable HTTP"
        default:
            // A transport this app has not met: its own name, with spaces for hyphens, rather than a wrong one.
            let words = key.replacingOccurrences(of: "-", with: " ").trimmingCharacters(in: .whitespaces)
            return words.isEmpty ? "Streamable HTTP" : String(words.prefix(1)).uppercased() + String(words.dropFirst())
        }
    }

    /// The registry's short name is often just "mcp" (the last part of
    /// `app.linear/mcp`); when it says nothing, the full id does.
    public var displayName: String {
        let generic: Set<String> = ["mcp", "server", "mcp-server", "mcp_server", "remote", "remote-mcp"]
        if generic.contains(name.lowercased()), registryId.contains("/") { return registryId }
        return name
    }
}

/// `GET /api/registry/search`: matches, and servers worth suggesting.
public struct McpRegistryResults: Sendable, Codable, Equatable {
    public let servers: [McpRegistryEntry]
    public let suggested: [McpRegistryEntry]

    public init(servers: [McpRegistryEntry] = [], suggested: [McpRegistryEntry] = []) {
        self.servers = servers
        self.suggested = suggested
    }

    enum CodingKeys: String, CodingKey { case servers, suggested }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        servers = try c.decodeIfPresent([McpRegistryEntry].self, forKey: .servers) ?? []
        suggested = try c.decodeIfPresent([McpRegistryEntry].self, forKey: .suggested) ?? []
    }
}

/// What a reachability probe found. `unknown` (a timeout, a 5xx) never demotes anything.
public enum McpLivenessState: String, Sendable, Codable, Hashable {
    case alive, dead, unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = McpLivenessState(rawValue: raw) ?? .unknown
    }
}

public struct McpLivenessVerdict: Sendable, Codable, Hashable {
    public let url: String
    public let state: McpLivenessState
    public let status: Int?

    enum CodingKeys: String, CodingKey { case url, state, status }

    public init(url: String, state: McpLivenessState, status: Int? = nil) {
        self.url = url
        self.state = state
        self.status = status
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decode(String.self, forKey: .url)
        state = try c.decodeIfPresent(McpLivenessState.self, forKey: .state) ?? .unknown
        status = try c.decodeIfPresent(Int.self, forKey: .status)
    }
}

public struct McpLivenessResults: Sendable, Decodable {
    public let results: [McpLivenessVerdict]

    enum CodingKeys: String, CodingKey { case results }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        results = try c.decodeIfPresent([McpLivenessVerdict].self, forKey: .results) ?? []
    }
}

extension McpRegistryEntry {
    /// The most addresses one liveness call probes.
    public static let livenessBatchSize = 12

    /// Applies the probes' verdicts (and what is already known): dead ones are
    /// flagged and sunk below the rest, alive ones are cleared if they were
    /// flagged, unknown ones change nothing. The order within each group is
    /// the registry's own.
    public static func applying(_ verdicts: [McpLivenessVerdict], to entries: [McpRegistryEntry], knownDead: Set<String> = []) -> [McpRegistryEntry] {
        var state: [String: Bool] = [:]
        for verdict in verdicts {
            switch verdict.state {
            case .dead: state[McpServer.normalize(verdict.url)] = true
            case .alive: state[McpServer.normalize(verdict.url)] = false
            case .unknown: break
            }
        }
        let marked = entries.map { entry -> McpRegistryEntry in
            var copy = entry
            let key = entry.normalizedURL
            copy.dead = state[key] ?? (entry.dead || knownDead.contains(key))
            return copy
        }
        return marked.filter { !$0.dead } + marked.filter(\.dead)
    }
}

// MARK: OAuth

/// `POST /api/mcp-servers/oauth/start`: where to send the person to log in.
public struct McpOAuthStart: Sendable, Decodable {
    public let authorizationUrl: URL

    enum CodingKeys: String, CodingKey { case authorizationUrl = "authorization_url" }
}

public struct McpOAuthStartRequest: Sendable {
    public var url: String
    public var name: String?
    public var registryId: String?
    /// Re-authorise an already connected server.
    public var serverId: String?
    public var saveToVault: Bool

    public init(url: String, name: String? = nil, registryId: String? = nil, serverId: String? = nil, saveToVault: Bool = false) {
        self.url = url
        self.name = name
        self.registryId = registryId
        self.serverId = serverId
        self.saveToVault = saveToVault
    }

    public var body: JSONValue {
        var object: [String: JSONValue] = ["url": .string(url)]
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { object["name"] = .string(name) }
        if let registryId, !registryId.isEmpty { object["registry_id"] = .string(registryId) }
        if let serverId, !serverId.isEmpty { object["server_id"] = .string(serverId) }
        if saveToVault { object["save_to_vault"] = .bool(true) }
        return .object(object)
    }
}

// MARK: Errors

extension HVError {
    /// The server answered 401 because the *MCP server* wants a login, not
    /// because the person's session ended (`auth_required: true` in the body).
    public var isMcpAuthRequired: Bool {
        guard let failure, failure.status == 401 else { return false }
        return failure.body?["auth_required"]?.bool == true
    }

    /// The OAuth start answered 409 with `oauth_available: false`: this server
    /// has no usable OAuth login, so a pasted token is the way in.
    public var isMcpOAuthUnavailable: Bool {
        failure?.body?["oauth_available"]?.bool == false
    }

    /// The compile route writes `{ error: code, message: sentence }`, so the
    /// sentence is in `message`, not `error`.
    public var mcpCompileSentence: String {
        failure?.body?["message"]?.string ?? userMessage
    }

    /// The compile route refused because every tool is switched off. That is a choice
    /// for the person to make, not a failure to try again.
    public var isMcpNothingToCompile: Bool {
        failure?.body?["error"]?.string == "no_enabled_tools"
    }
}

// MARK: Endpoints

extension Endpoint where Response == McpServerList {
    public static var mcpServers: Endpoint<McpServerList> {
        Endpoint(.get, "/api/mcp-servers", keys: .verbatim)
    }
}

extension Endpoint where Response == McpServerEnvelope {
    /// Connects a server. The server reads its tools live first (up to 60
    /// seconds); an auth challenge answers 401 with `auth_required`, a
    /// duplicate 409, an unreachable server 502.
    public static func addMcpServer(_ request: McpAddRequest) -> Endpoint<McpServerEnvelope> {
        Endpoint(.post, "/api/mcp-servers", body: .jsonValue(request.body), keys: .verbatim, timeout: 100)
    }

    /// Changes a server's name, whether it is on, or which of its tools are off.
    public static func updateMcpServer(id: String, name: String? = nil, enabled: Bool? = nil, disabledTools: [String]? = nil) -> Endpoint<McpServerEnvelope> {
        var object: [String: JSONValue] = [:]
        if let name { object["name"] = .string(name) }
        if let enabled { object["enabled"] = .bool(enabled) }
        if let disabledTools {
            object["disabled_tools"] = .array(disabledTools.prefix(McpServer.maxDisabledTools).map { .string($0) })
        }
        return Endpoint(.patch, "/api/mcp-servers/\(id)", body: .jsonValue(.object(object)), keys: .verbatim)
    }

    /// Replaces the pasted headers of a server whose sign-in is stored on the
    /// server row. (A vault-backed sign-in is replaced in the vault instead:
    /// the route reads the vault reference first, so this would be ignored.)
    public static func replaceMcpHeaders(id: String, headers: [String: String]) -> Endpoint<McpServerEnvelope> {
        Endpoint(.patch, "/api/mcp-servers/\(id)", body: .jsonValue(.object(["headers": .object(headers.mapValues { .string($0) })])), keys: .verbatim)
    }
}

extension Endpoint where Response == McpAck {
    public static func deleteMcpServer(id: String) -> Endpoint<McpAck> {
        Endpoint(.delete, "/api/mcp-servers/\(id)", keys: .verbatim)
    }
}

extension Endpoint where Response == McpRefreshResult {
    /// Reads the server's tools again (up to 60 seconds).
    public static func refreshMcpServer(id: String) -> Endpoint<McpRefreshResult> {
        Endpoint(.post, "/api/mcp-servers/\(id)/refresh", keys: .verbatim, timeout: 100)
    }
}

extension Endpoint where Response == McpPreview {
    /// Reads a server's tools without saving it. Carries the same headers as an
    /// add would, so a token can be checked before it is stored.
    public static func previewMcpServer(url: String, name: String? = nil, headers: [String: String] = [:]) -> Endpoint<McpPreview> {
        var object: [String: JSONValue] = ["url": .string(url)]
        if let name, !name.isEmpty { object["name"] = .string(name) }
        if !headers.isEmpty { object["headers"] = .object(headers.mapValues { .string($0) }) }
        return Endpoint(.post, "/api/mcp-servers/preview", body: .jsonValue(.object(object)), keys: .verbatim, timeout: 100, idempotent: true)
    }
}

extension Endpoint where Response == McpOAuthStart {
    public static func startMcpOAuth(_ request: McpOAuthStartRequest) -> Endpoint<McpOAuthStart> {
        Endpoint(.post, "/api/mcp-servers/oauth/start", body: .jsonValue(request.body), keys: .verbatim, timeout: 100)
    }
}

extension Endpoint where Response == McpToolkitStatus {
    public static var mcpToolkit: Endpoint<McpToolkitStatus> {
        Endpoint(.get, "/api/toolkits", keys: .verbatim)
    }
}

extension Endpoint where Response == McpCompileResult {
    /// Builds the toolkit from every server that is on. Up to 300 seconds on
    /// the server, so the client waits a little longer.
    public static var compileMcpToolkit: Endpoint<McpCompileResult> {
        Endpoint(.post, "/api/toolkits/compile", body: .jsonValue(.object([:])), keys: .verbatim, timeout: 330)
    }
}

extension Endpoint where Response == McpRegistryResults {
    public static func searchMcpRegistry(query: String) -> Endpoint<McpRegistryResults> {
        Endpoint(.get, "/api/registry/search", query: .make([("q", String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)))]), keys: .verbatim, timeout: 30)
    }
}

extension Endpoint where Response == McpLivenessResults {
    /// Probes up to 12 addresses for reachability (no credentials involved).
    public static func probeMcpLiveness(urls: [String]) -> Endpoint<McpLivenessResults> {
        let list = urls.prefix(McpRegistryEntry.livenessBatchSize).map { JSONValue.string($0) }
        return Endpoint(.post, "/api/registry/liveness", body: .jsonValue(.object(["urls": .array(Array(list))])), keys: .verbatim, timeout: 45, idempotent: true)
    }
}
