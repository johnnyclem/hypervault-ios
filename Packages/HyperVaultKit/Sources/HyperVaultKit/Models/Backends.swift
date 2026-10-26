import Foundation

// Your own models: the backends a person connects so chat can talk to them
// (`/api/backends`). The server stores the key encrypted and makes every call
// to the model itself; the phone only ever sends the key once, to connect or
// to replace it, and the server never returns it (only `key_hint`, the first
// characters).

/// A connected model.
public struct ChatBackend: Sendable, Codable, Identifiable, Equatable, Hashable {
    public let id: String
    public var name: String
    public let provider: String
    public var baseUrl: String?
    public var defaultModel: String?
    public var embeddingModel: String?
    /// The start of the key, `sk-ant-…`, enough to recognise it and no more.
    public var keyHint: String?
    public let createdAt: Date?
    public var lastUsedAt: Date?

    public init(
        id: String, name: String, provider: String, baseUrl: String? = nil, defaultModel: String? = nil,
        embeddingModel: String? = nil, keyHint: String? = nil, createdAt: Date? = nil, lastUsedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.provider = provider
        self.baseUrl = baseUrl
        self.defaultModel = defaultModel
        self.embeddingModel = embeddingModel
        self.keyHint = keyHint
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? "custom"
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? provider
        baseUrl = try c.decodeIfPresent(String.self, forKey: .baseUrl)
        defaultModel = try c.decodeIfPresent(String.self, forKey: .defaultModel)
        embeddingModel = try c.decodeIfPresent(String.self, forKey: .embeddingModel)
        keyHint = try c.decodeIfPresent(String.self, forKey: .keyHint)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        lastUsedAt = try c.decodeIfPresent(Date.self, forKey: .lastUsedAt)
    }

    enum Keys: String, CodingKey {
        case id, name, provider, baseUrl, defaultModel, embeddingModel, keyHint, createdAt, lastUsedAt
    }

    /// "Claude Opus - anthropic", the line a picker shows.
    public var modelLine: String {
        if let defaultModel, !defaultModel.isEmpty { return defaultModel }
        return provider
    }
}

/// `POST` and `PATCH /api/backends`: the saved backend and the server's sentence,
/// which says what the live test found ("Claude connected - test reply received").
public struct ChatBackendSaved: Sendable, Decodable, Equatable {
    public let backend: ChatBackend
    public let message: String?
}

extension Capabilities.ProviderSpec {
    /// Ollama and LM Studio run on a machine of the person's own and need no key.
    public var isLocalRuntime: Bool { id == "ollama" || id == "lmstudio" }

    /// "Custom endpoint" in either API style: the person supplies URL and model.
    public var isCustom: Bool { id == "custom" || id == "custom-anthropic" }

    /// Only OpenAI-protocol backends can serve embeddings for semantic recall.
    public var supportsEmbeddings: Bool { `protocol` == "openai" }

    /// Whether the connect form asks for a key at all.
    public var acceptsKey: Bool { requiresKey || optionalKey }

    /// Whether the connect form asks for a base URL.
    public var asksForBaseURL: Bool { isCustom || isLocalRuntime }
}

/// The connectors the server knows, for a build that could not reach
/// `/api/capabilities` and for previews. The server's list wins when it has one.
public enum ChatProviders {
    public static let builtIn: [Capabilities.ProviderSpec] = [
        .init(id: "openai", label: "OpenAI", protocol: "openai", defaultBaseUrl: "https://api.openai.com/v1", defaultModel: "gpt-4o", requiresKey: true, defaultEmbeddingModel: "text-embedding-3-small"),
        .init(id: "anthropic", label: "Anthropic (Claude)", protocol: "anthropic", defaultBaseUrl: "https://api.anthropic.com", defaultModel: "claude-opus-4-8", requiresKey: true),
        .init(id: "xai", label: "xAI (Grok)", protocol: "openai", defaultBaseUrl: "https://api.x.ai/v1", defaultModel: "grok-4", requiresKey: true),
        .init(id: "gemini", label: "Google (Gemini)", protocol: "gemini", defaultBaseUrl: "https://generativelanguage.googleapis.com", defaultModel: "gemini-2.5-pro", requiresKey: true),
        .init(id: "mistral", label: "Mistral", protocol: "openai", defaultBaseUrl: "https://api.mistral.ai/v1", defaultModel: "mistral-large-latest", requiresKey: true),
        .init(id: "ollama", label: "Ollama (local)", protocol: "openai", defaultBaseUrl: "http://localhost:11434/v1", defaultModel: "llama3.3", requiresKey: false),
        .init(id: "lmstudio", label: "LM Studio (local)", protocol: "openai", defaultBaseUrl: "http://localhost:1234/v1", defaultModel: "local-model", requiresKey: false),
        .init(id: "custom", label: "Custom endpoint (OpenAI-compatible)", protocol: "openai", requiresKey: false, optionalKey: true),
        .init(id: "custom-anthropic", label: "Custom endpoint (Anthropic-compatible)", protocol: "anthropic", requiresKey: false, optionalKey: true),
    ]

    /// The providers the connect form lists: the server's registry, or the
    /// built-in copy, with the two custom styles folded into one "Custom
    /// endpoint" row (the style is a second choice, as on the web).
    public static func choices(from registry: [Capabilities.ProviderSpec]) -> [Capabilities.ProviderSpec] {
        (registry.isEmpty ? builtIn : registry).filter { $0.id != "custom-anthropic" }
    }

    public static func spec(for id: String, in registry: [Capabilities.ProviderSpec]) -> Capabilities.ProviderSpec? {
        (registry.isEmpty ? builtIn : registry).first { $0.id == id }
    }

    /// The word for a provider on a chip: "Anthropic", "Ollama".
    public static func shortName(for id: String, in registry: [Capabilities.ProviderSpec]) -> String {
        let label = spec(for: id, in: registry)?.label ?? id
        if let paren = label.firstIndex(of: "(") { return label[..<paren].trimmingCharacters(in: .whitespaces) }
        return label
    }
}

/// What the person has typed into the connect or edit form.
public struct ChatBackendDraft: Sendable, Equatable {
    public var provider: String
    public var name: String
    /// Typed once; never kept after it is sent.
    public var apiKey: String
    public var baseURL: String
    public var model: String
    public var embeddingModel: String
    /// Save without the live test (the server tests for up to 60 seconds).
    public var skipTest: Bool

    public init(
        provider: String = "anthropic", name: String = "", apiKey: String = "", baseURL: String = "",
        model: String = "", embeddingModel: String = "", skipTest: Bool = false
    ) {
        self.provider = provider
        self.name = name
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.model = model
        self.embeddingModel = embeddingModel
        self.skipTest = skipTest
    }

    /// A draft that edits `backend`: the key stays blank, which keeps the stored one.
    public init(editing backend: ChatBackend) {
        self.init(
            provider: backend.provider, name: backend.name, apiKey: "", baseURL: backend.baseUrl ?? "",
            model: backend.defaultModel ?? "", embeddingModel: backend.embeddingModel ?? ""
        )
    }

    private static func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    public var hasKey: Bool { !Self.trimmed(apiKey).isEmpty }

    /// What stops this draft from being sent, in the server's words where it has
    /// them, or nil when it is ready. `editing` relaxes the key rule: a blank
    /// key keeps the stored one.
    public func problem(
        spec: Capabilities.ProviderSpec, serverCanStoreKeys: Bool, editing: Bool = false,
        connectedCount: Int = 0, maxBackends: Int = .max
    ) -> String? {
        if !editing, connectedCount >= maxBackends { return "Backend limit reached (\(maxBackends))." }
        if spec.requiresKey, !hasKey, !editing {
            return serverCanStoreKeys ? "\(spec.label) needs an API key." : Self.noKeyStorageLine
        }
        if hasKey, !serverCanStoreKeys { return Self.noKeyStorageLine }
        if spec.isCustom, Self.trimmed(baseURL).isEmpty { return "Custom endpoints need a base URL." }
        if spec.isCustom, Self.trimmed(model).isEmpty { return "Custom endpoints need a model." }
        if !Self.trimmed(embeddingModel).isEmpty, !spec.supportsEmbeddings {
            return "\(spec.label) can't serve embeddings. Only OpenAI-style backends can."
        }
        return nil
    }

    /// Said plainly when the server has no secret to encrypt keys with.
    public static let noKeyStorageLine =
        "This server can't store keys safely right now, so HyperVault won't send one. A model that needs no key still works."

    /// The `POST /api/backends` body. The key goes only when the server can store it.
    func connectBody(serverCanStoreKeys: Bool) -> JSONValue {
        var object: [String: JSONValue] = ["provider": .string(provider)]
        func put(_ key: String, _ value: String) {
            let text = Self.trimmed(value)
            if !text.isEmpty { object[key] = .string(text) }
        }
        put("name", name)
        if serverCanStoreKeys { put("api_key", apiKey) }
        put("base_url", baseURL)
        put("default_model", model)
        put("embedding_model", embeddingModel)
        if skipTest { object["skip_test"] = .bool(true) }
        return .object(object)
    }

    /// The `PATCH /api/backends` body. Every field is sent so a cleared one
    /// clears ("" empties an optional field); a blank key is left out, which
    /// keeps the stored key. The provider cannot change.
    func editBody(id: String, supportsEmbeddings: Bool, serverCanStoreKeys: Bool) -> JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(id),
            "name": .string(Self.trimmed(name)),
            "base_url": .string(Self.trimmed(baseURL)),
            "default_model": .string(Self.trimmed(model)),
        ]
        if supportsEmbeddings { object["embedding_model"] = .string(Self.trimmed(embeddingModel)) }
        if serverCanStoreKeys, hasKey { object["api_key"] = .string(Self.trimmed(apiKey)) }
        if skipTest { object["skip_test"] = .bool(true) }
        return .object(object)
    }

    /// A line for the person when the address points at their own network.
    public func reachabilityNote(spec: Capabilities.ProviderSpec) -> String? {
        ChatBackendHints.reachabilityNote(provider: spec, baseURL: baseURL)
    }
}

public enum ChatBackendHints {
    /// True for an address that means a machine on the person's own network:
    /// localhost, loopback, private ranges, `.local`.
    public static func isLocalAddress(_ url: String) -> Bool {
        let text = url.contains("://") ? url : "https://\(url)"
        guard let host = URLComponents(string: text)?.host?.lowercased(), !host.isEmpty else { return false }
        if host == "localhost" || host == "0.0.0.0" || host == "::1" { return true }
        if host.hasSuffix(".local") || host.hasSuffix(".localhost") || host.hasSuffix(".internal") { return true }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else { return false }
        if octets[0] == 127 || octets[0] == 10 { return true }
        if octets[0] == 192, octets[1] == 168 { return true }
        if octets[0] == 172, (16...31).contains(octets[1]) { return true }
        return false
    }

    /// The caveat shown beside Ollama, LM Studio and any home-network address:
    /// HyperVault's server makes the call, so an address only your network can
    /// see will not work. (The hosted server refuses private addresses outright.)
    public static func reachabilityNote(provider: Capabilities.ProviderSpec, baseURL: String) -> String? {
        let address = baseURL.trimmingCharacters(in: .whitespaces)
        let isLocal = address.isEmpty ? provider.isLocalRuntime : isLocalAddress(address)
        guard isLocal else { return nil }
        return "HyperVault's server makes the call to your model, not your phone. An address like localhost or 192.168.x.x only means something on your own network, so the server can't reach it. Use a tunnel address (ngrok or Tailscale Funnel) or a cloud endpoint, or add it under On your network, where this iPhone calls it directly."
    }
}
