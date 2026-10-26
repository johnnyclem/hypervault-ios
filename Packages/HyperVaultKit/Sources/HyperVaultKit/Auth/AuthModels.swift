import Foundation

/// The Supabase project the app signs in against. It comes from
/// `GET /api/capabilities` (`auth.supabase_url`, `auth.supabase_anon_key`); the
/// anon key is public by design.
public struct SupabaseConfig: Sendable, Equatable, Codable {
    public let url: URL
    public let anonKey: String

    public init(url: URL, anonKey: String) {
        self.url = url
        self.anonKey = anonKey
    }
}

public struct AuthUser: Sendable, Equatable, Codable, Identifiable {
    public let id: String
    public let email: String?
    public let displayName: String?
    public let avatarUrl: String?
    public let provider: String?

    public init(id: String, email: String?, displayName: String? = nil, avatarUrl: String? = nil, provider: String? = nil) {
        self.id = id
        self.email = email
        self.displayName = displayName
        self.avatarUrl = avatarUrl
        self.provider = provider
    }

    /// First name for a greeting: the given name, else the start of the email.
    public var firstName: String? {
        if let displayName, let first = displayName.split(separator: " ").first { return String(first) }
        if let email, let local = email.split(separator: "@").first { return String(local) }
        return nil
    }
}

public struct AuthSession: Sendable, Equatable, Codable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Date
    public let user: AuthUser

    public init(accessToken: String, refreshToken: String, expiresAt: Date, user: AuthUser) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.user = user
    }

    public func isExpiring(within seconds: TimeInterval, now: Date) -> Bool {
        expiresAt.timeIntervalSince(now) <= seconds
    }
}

/// What the Supabase project allows, from `GET /auth/v1/settings`.
public struct AuthProviders: Sendable, Equatable {
    public var google: Bool
    public var apple: Bool
    public var email: Bool
    public var signupDisabled: Bool

    public init(google: Bool = true, apple: Bool = false, email: Bool = false, signupDisabled: Bool = false) {
        self.google = google
        self.apple = apple
        self.email = email
        self.signupDisabled = signupDisabled
    }
}

public enum AuthState: Sendable, Equatable {
    /// Not yet looked at the stored session.
    case unknown
    case signedOut
    case signedIn(AuthUser)

    public var user: AuthUser? {
        if case .signedIn(let user) = self { return user }
        return nil
    }
}

public enum AuthError: Error, Sendable, Equatable {
    /// The user closed the sign-in sheet.
    case cancelled
    /// The provider or server turned the sign-in down; `message` is for people.
    case failed(String)
    case network(String)
    /// The auth server could not take the request just now: it timed out, is down or is limiting
    /// requests (`status` is 408, 429 or 5xx). Nothing was refused, so a session stays signed in.
    case unavailable(status: Int)
    case notConfigured
}

extension AuthError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .cancelled: return "Sign-in was cancelled."
        case .failed(let message): return message
        case .network: return "Network hiccup. Check your connection and try again."
        case .unavailable(let status):
            return status == 429
                ? "Too many requests. Wait a moment and try again."
                : "Your session could not be renewed right now. Try again in a moment."
        case .notConfigured: return "This server is not set up for sign-in yet."
        }
    }
}

/// Where the session and the in-flight PKCE verifier are kept. The app backs
/// this with the Keychain (shared with the share extension); tests use memory.
public protocol SecureStore: Sendable {
    func get(_ key: String) async -> Data?
    func set(_ value: Data, for key: String) async
    func remove(_ key: String) async
}

public actor InMemorySecureStore: SecureStore {
    private var values: [String: Data] = [:]

    public init() {}

    public func get(_ key: String) -> Data? { values[key] }
    public func set(_ value: Data, for key: String) { values[key] = value }
    public func remove(_ key: String) { values[key] = nil }
}
