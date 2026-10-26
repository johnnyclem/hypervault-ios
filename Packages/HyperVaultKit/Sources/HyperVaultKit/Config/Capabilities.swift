import Foundation

/// Where the app talks to. `hypervault.store` unless someone points a build at
/// their own deployment (Settings > Advanced).
public struct ServerConfig: Sendable, Equatable, Codable {
    public var baseURL: URL

    public init(baseURL: URL) {
        self.baseURL = baseURL
    }

    public static let production = ServerConfig(baseURL: URL(string: "https://hypervault.store")!)

    /// Accepts "hypervault.store", "https://my.host/" and the like; only https
    /// (or http for localhost) is allowed.
    public init?(userInput: String) {
        var text = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), let host = url.host, !host.isEmpty else { return nil }
        let local = host == "localhost" || host == "127.0.0.1"
        guard url.scheme == "https" || (url.scheme == "http" && local) else { return nil }
        self.baseURL = url
    }
}

/// `GET /api/capabilities`: what this deployment can do, and its limits. The
/// app reads it at launch and again after sign-in. Every field has a default so
/// a newer or older server never breaks decoding.
public struct Capabilities: Sendable, Equatable, Codable {
    public var appUrl: String
    public var apiVersion: String
    public var auth: Auth
    public var features: Features
    public var limits: Limits
    public var providers: [ProviderSpec]
    public var domains: [PortfolioDomain]
    public var themes: [ThemeInfo]
    public var user: UserInfo?

    public struct Auth: Sendable, Equatable, Codable {
        public var supabaseUrl: String?
        public var supabaseAnonKey: String?
        public var inviteGated: Bool

        public init(supabaseUrl: String? = nil, supabaseAnonKey: String? = nil, inviteGated: Bool = true) {
            self.supabaseUrl = supabaseUrl
            self.supabaseAnonKey = supabaseAnonKey
            self.inviteGated = inviteGated
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            supabaseUrl = try c.decodeIfPresent(String.self, forKey: .supabaseUrl)
            supabaseAnonKey = try c.decodeIfPresent(String.self, forKey: .supabaseAnonKey)
            inviteGated = try c.decodeIfPresent(Bool.self, forKey: .inviteGated) ?? true
        }

        enum Keys: String, CodingKey { case supabaseUrl, supabaseAnonKey, inviteGated }
    }

    public struct Features: Sendable, Equatable, Codable {
        public var configured: Bool
        public var deepMemory: Bool
        public var keyEncryption: Bool
        public var smartContext: Bool
        public var truthLedger: Bool
        public var truthNotary: Bool
        public var onDeviceInference: Bool
        public var dreaming: Bool
        public var realmHomePage: Bool

        public init(
            configured: Bool = true, deepMemory: Bool = false, keyEncryption: Bool = true,
            smartContext: Bool = true, truthLedger: Bool = true, truthNotary: Bool = false,
            onDeviceInference: Bool = true, dreaming: Bool = true, realmHomePage: Bool = true
        ) {
            self.configured = configured
            self.deepMemory = deepMemory
            self.keyEncryption = keyEncryption
            self.smartContext = smartContext
            self.truthLedger = truthLedger
            self.truthNotary = truthNotary
            self.onDeviceInference = onDeviceInference
            self.dreaming = dreaming
            self.realmHomePage = realmHomePage
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            func flag(_ key: Keys, _ fallback: Bool) throws -> Bool { try c.decodeIfPresent(Bool.self, forKey: key) ?? fallback }
            configured = try flag(.configured, true)
            deepMemory = try flag(.deepMemory, false)
            keyEncryption = try flag(.keyEncryption, true)
            smartContext = try flag(.smartContext, true)
            truthLedger = try flag(.truthLedger, true)
            truthNotary = try flag(.truthNotary, false)
            onDeviceInference = try flag(.onDeviceInference, true)
            dreaming = try flag(.dreaming, true)
            realmHomePage = try flag(.realmHomePage, true)
        }

        enum Keys: String, CodingKey {
            case configured, deepMemory, keyEncryption, smartContext, truthLedger, truthNotary
            case onDeviceInference, dreaming, realmHomePage
        }
    }

    public struct Limits: Sendable, Equatable, Codable {
        public var artifactBytes: Int
        public var sourcePromptChars: Int
        public var chatMessageChars: Int
        public var memoryBytes: Int
        public var importBytes: Int
        public var maxBackends: Int
        public var maxMcpServers: Int
        public var maxProSubdomains: Int

        public init(
            artifactBytes: Int = 1_000_000, sourcePromptChars: Int = 10_000, chatMessageChars: Int = 100_000,
            memoryBytes: Int = 500_000, importBytes: Int = 50_000_000, maxBackends: Int = 20,
            maxMcpServers: Int = 20, maxProSubdomains: Int = 10
        ) {
            self.artifactBytes = artifactBytes
            self.sourcePromptChars = sourcePromptChars
            self.chatMessageChars = chatMessageChars
            self.memoryBytes = memoryBytes
            self.importBytes = importBytes
            self.maxBackends = maxBackends
            self.maxMcpServers = maxMcpServers
            self.maxProSubdomains = maxProSubdomains
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            func number(_ key: Keys, _ fallback: Int) throws -> Int { try c.decodeIfPresent(Int.self, forKey: key) ?? fallback }
            artifactBytes = try number(.artifactBytes, 1_000_000)
            sourcePromptChars = try number(.sourcePromptChars, 10_000)
            chatMessageChars = try number(.chatMessageChars, 100_000)
            memoryBytes = try number(.memoryBytes, 500_000)
            importBytes = try number(.importBytes, 50_000_000)
            maxBackends = try number(.maxBackends, 20)
            maxMcpServers = try number(.maxMcpServers, 20)
            maxProSubdomains = try number(.maxProSubdomains, 10)
        }

        enum Keys: String, CodingKey {
            case artifactBytes, sourcePromptChars, chatMessageChars, memoryBytes, importBytes
            case maxBackends, maxMcpServers, maxProSubdomains
        }
    }

    /// One row of the connector registry (OpenAI, Anthropic, Ollama, ...).
    public struct ProviderSpec: Sendable, Equatable, Codable, Identifiable {
        public var id: String
        public var label: String
        public var `protocol`: String
        public var defaultBaseUrl: String
        public var defaultModel: String
        public var requiresKey: Bool
        public var optionalKey: Bool
        public var defaultEmbeddingModel: String?

        public init(
            id: String, label: String, protocol: String = "openai", defaultBaseUrl: String = "",
            defaultModel: String = "", requiresKey: Bool = true, optionalKey: Bool = false,
            defaultEmbeddingModel: String? = nil
        ) {
            self.id = id
            self.label = label
            self.protocol = `protocol`
            self.defaultBaseUrl = defaultBaseUrl
            self.defaultModel = defaultModel
            self.requiresKey = requiresKey
            self.optionalKey = optionalKey
            self.defaultEmbeddingModel = defaultEmbeddingModel
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            id = try c.decode(String.self, forKey: .id)
            label = try c.decodeIfPresent(String.self, forKey: .label) ?? id
            `protocol` = try c.decodeIfPresent(String.self, forKey: .protocol) ?? "openai"
            defaultBaseUrl = try c.decodeIfPresent(String.self, forKey: .defaultBaseUrl) ?? ""
            defaultModel = try c.decodeIfPresent(String.self, forKey: .defaultModel) ?? ""
            requiresKey = try c.decodeIfPresent(Bool.self, forKey: .requiresKey) ?? true
            optionalKey = try c.decodeIfPresent(Bool.self, forKey: .optionalKey) ?? false
            defaultEmbeddingModel = try c.decodeIfPresent(String.self, forKey: .defaultEmbeddingModel)
        }

        enum Keys: String, CodingKey {
            case id, label, `protocol`, defaultBaseUrl, defaultModel, requiresKey, optionalKey, defaultEmbeddingModel
        }
    }

    public struct PortfolioDomain: Sendable, Equatable, Codable, Identifiable {
        public var domain: String
        public var tagline: String
        public var featured: Bool
        public var available: Bool
        public var id: String { domain }

        public init(domain: String, tagline: String = "", featured: Bool = false, available: Bool = true) {
            self.domain = domain
            self.tagline = tagline
            self.featured = featured
            self.available = available
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            domain = try c.decode(String.self, forKey: .domain)
            tagline = try c.decodeIfPresent(String.self, forKey: .tagline) ?? ""
            featured = try c.decodeIfPresent(Bool.self, forKey: .featured) ?? false
            available = try c.decodeIfPresent(Bool.self, forKey: .available) ?? true
        }

        enum Keys: String, CodingKey { case domain, tagline, featured, available }
    }

    public struct ThemeInfo: Sendable, Equatable, Codable, Identifiable {
        public var id: String
        public var name: String
        public var mode: String
    }

    public struct UserInfo: Sendable, Equatable, Codable {
        public var id: String
        public var email: String?
        public var via: String?
    }

    public init(
        appUrl: String = ServerConfig.production.baseURL.absoluteString,
        apiVersion: String = "",
        auth: Auth = Auth(),
        features: Features = Features(),
        limits: Limits = Limits(),
        providers: [ProviderSpec] = [],
        domains: [PortfolioDomain] = [],
        themes: [ThemeInfo] = [],
        user: UserInfo? = nil
    ) {
        self.appUrl = appUrl
        self.apiVersion = apiVersion
        self.auth = auth
        self.features = features
        self.limits = limits
        self.providers = providers
        self.domains = domains
        self.themes = themes
        self.user = user
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        appUrl = try c.decodeIfPresent(String.self, forKey: .appUrl) ?? ServerConfig.production.baseURL.absoluteString
        apiVersion = try c.decodeIfPresent(String.self, forKey: .apiVersion) ?? ""
        auth = try c.decodeIfPresent(Auth.self, forKey: .auth) ?? Auth()
        features = try c.decodeIfPresent(Features.self, forKey: .features) ?? Features()
        limits = try c.decodeIfPresent(Limits.self, forKey: .limits) ?? Limits()
        providers = try c.decodeIfPresent([ProviderSpec].self, forKey: .providers) ?? []
        domains = try c.decodeIfPresent([PortfolioDomain].self, forKey: .domains) ?? []
        themes = try c.decodeIfPresent([ThemeInfo].self, forKey: .themes) ?? []
        user = try c.decodeIfPresent(UserInfo.self, forKey: .user)
    }

    enum Keys: String, CodingKey {
        case appUrl, apiVersion, auth, features, limits, providers, domains, themes, user
    }

    /// The Supabase project to sign in against, when the server reports one.
    public var supabase: SupabaseConfig? {
        guard let url = auth.supabaseUrl.flatMap(URL.init(string:)), let key = auth.supabaseAnonKey, !key.isEmpty else { return nil }
        return SupabaseConfig(url: url, anonKey: key)
    }
}

extension Endpoint where Response == Capabilities {
    /// Public; adding a token fills in `user`.
    public static var capabilities: Endpoint<Capabilities> {
        Endpoint(.get, "/api/capabilities", auth: .optional)
    }
}
