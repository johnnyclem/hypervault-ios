import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Supabase Auth (GoTrue) on device: PKCE OAuth, Sign in with Apple's id-token
/// exchange, emailed one-time codes, silent refresh and sign-out. It keeps the
/// session in a `SecureStore` and is the `TokenProvider` the API client uses.
public actor AuthService: TokenProvider {
    public let config: SupabaseConfig

    private let transport: HTTPTransport
    private let store: SecureStore
    private let now: @Sendable () -> Date
    /// A token this close to expiry is refreshed before it is used.
    private let refreshMargin: TimeInterval

    private var session: AuthSession?
    private var loaded = false
    private var refreshTask: Task<AuthSession, Error>?
    private var listeners: [UUID: AsyncStream<AuthState>.Continuation] = [:]

    static let sessionKey = "hypervault.session"
    static let verifierKey = "hypervault.pkce.verifier"

    public init(
        config: SupabaseConfig,
        transport: HTTPTransport = URLSessionTransport(),
        store: SecureStore,
        refreshMargin: TimeInterval = 60,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.config = config
        self.transport = transport
        self.store = store
        self.refreshMargin = refreshMargin
        self.now = now
    }

    // MARK: State

    public var state: AuthState {
        guard loaded else { return .unknown }
        if let user = session?.user { return .signedIn(user) }
        return .signedOut
    }

    public var currentUser: AuthUser? { session?.user }

    /// Reads the stored session. Call once at launch.
    @discardableResult
    public func restore() async -> AuthState {
        await loadIfNeeded()
        broadcast()
        return state
    }

    /// A stream of every sign-in, refresh and sign-out, starting with the current state.
    public func states() -> AsyncStream<AuthState> {
        let (stream, continuation) = AsyncStream<AuthState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        listeners[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeListener(id) }
        }
        continuation.yield(state)
        return stream
    }

    private func removeListener(_ id: UUID) { listeners[id] = nil }

    private func broadcast() {
        let current = state
        for continuation in listeners.values { continuation.yield(current) }
    }

    private func loadIfNeeded() async {
        guard !loaded else { return }
        if let data = await store.get(Self.sessionKey),
           let stored = try? HVCoding.decoder(.verbatim).decode(AuthSession.self, from: data)
        {
            session = stored
        }
        loaded = true
    }

    private func adopt(_ newSession: AuthSession) async {
        session = newSession
        loaded = true
        if let data = try? HVCoding.encoder(.verbatim).encode(newSession) {
            await store.set(data, for: Self.sessionKey)
        }
        broadcast()
    }

    private func clearSession() async {
        session = nil
        loaded = true
        refreshTask?.cancel()
        refreshTask = nil
        await store.remove(Self.sessionKey)
        broadcast()
    }

    /// Picks up a session another process saved since this one was read. The app, the
    /// widgets, the share extension and Shortcuts each run their own service over one
    /// Keychain item, and any of them may have refreshed. It keeps what it has when the
    /// store holds nothing newer, and never signs anyone out.
    public func reloadFromStore() async {
        await loadIfNeeded()
        await adoptStoredSession()
    }

    /// Takes up the stored session when another process saved a newer one for the same person,
    /// and returns it. A missing or unreadable item says nothing, and an older one (a write that
    /// did not take) must not replace a live session.
    @discardableResult
    private func adoptStoredSession() async -> AuthSession? {
        guard let data = await store.get(Self.sessionKey),
              let stored = try? HVCoding.decoder(.verbatim).decode(AuthSession.self, from: data)
        else { return nil }
        // `session` is read after the await: it may have changed while the store was being read.
        guard let mine = session, stored.user.id == mine.user.id,
              stored.refreshToken != mine.refreshToken, stored.expiresAt > mine.expiresAt
        else { return nil }
        session = stored
        broadcast()
        return stored
    }

    // MARK: TokenProvider

    public func accessToken() async throws -> String? {
        await loadIfNeeded()
        guard let current = session else { return nil }
        if !current.isExpiring(within: refreshMargin, now: now()) { return current.accessToken }
        do {
            return try await refreshSession().accessToken
        } catch let error as AuthError {
            // A refresh that could not be done is not a sign-out: use the token while it
            // still works, and let the caller see the failure after.
            guard let failure = Self.transientFailure(of: error) else { return nil }
            if let latest = session, !latest.isExpiring(within: 0, now: now()) { return latest.accessToken }
            throw failure
        }
    }

    public func refreshAfterUnauthorized(rejected: String?) async throws -> String? {
        await loadIfNeeded()
        guard let current = session else { return nil }
        // Someone already refreshed since this token was handed out.
        if let rejected, current.accessToken != rejected { return current.accessToken }
        do {
            return try await refreshSession().accessToken
        } catch let error as AuthError {
            if let failure = Self.transientFailure(of: error) { throw failure }
            return nil
        }
    }

    /// How a refresh that neither worked nor ended the session reaches the API client.
    /// Nil for the errors that mean there is no session to use.
    private static func transientFailure(of error: AuthError) -> HVError? {
        switch error {
        case .network:
            return .transport("offline")
        case .unavailable(let status):
            return .api(APIFailure(status: status, message: error.errorDescription ?? ""))
        case .cancelled, .failed, .notConfigured:
            return nil
        }
    }

    /// Exchanges the refresh token for a new session. Concurrent callers share one request.
    /// The server refusing the refresh token ends the session (`.failed`); a server that is busy
    /// or out of reach (`.unavailable`, `.network`) leaves it signed in.
    @discardableResult
    public func refreshSession() async throws -> AuthSession {
        await loadIfNeeded()
        // From here to `refreshTask = task` there is no suspension point, so callers that arrive
        // together all find the one task. Anything that waits on the store belongs inside it.
        if let refreshTask { return try await refreshTask.value }
        guard session != nil else { throw AuthError.failed("Not signed in.") }

        let task = Task<AuthSession, Error> { [self] in try await renew() }
        refreshTask = task
        do {
            let fresh = try await task.value
            refreshTask = nil
            return fresh
        } catch let error as AuthError {
            refreshTask = nil
            throw error
        } catch {
            refreshTask = nil
            throw AuthError.network(error.localizedDescription)
        }
    }

    /// One refresh, run by `refreshSession`. A refresh token works once, and the widgets, the
    /// share extension and Shortcuts refresh the same session from their own process, so what is
    /// in memory may already be spent. The store is read before the request and again if the
    /// server refuses it, and a session another process saved is used rather than overwritten.
    private func renew() async throws -> AuthSession {
        if let adopted = await adoptStoredSession(), !adopted.isExpiring(within: refreshMargin, now: now()) {
            return adopted
        }
        guard let current = session else { throw AuthError.failed("Not signed in.") }

        let response = try await send(
            path: "auth/v1/token",
            query: [URLQueryItem(name: "grant_type", value: "refresh_token")],
            body: ["refresh_token": .string(current.refreshToken)]
        )
        let unreadable = AuthError.network("The sign-in service answered in a way the app could not read.")
        if (200..<300).contains(response.status) {
            guard let fresh = try? makeSession(from: response.data) else { throw unreadable }
            await adopt(fresh)
            return fresh
        }
        if Self.isRefreshTokenRefusal(response) {
            // If another process refreshed while this request was out, its session is the live one
            // and is not what was refused.
            if let adopted = await adoptStoredSession() { return adopted }
            // `session` is read again after the store was: a sign-in may have replaced it meanwhile.
            if session?.refreshToken == current.refreshToken { await clearSession() }
            throw AuthError.failed(Self.message(from: response))
        }
        if response.status == 408 || response.status == 429 || (500...599).contains(response.status) {
            throw AuthError.unavailable(status: response.status)
        }
        // A proxy's page or an error that names no token is not the server refusing this one.
        throw unreadable
    }

    /// Whether the server refused the refresh token itself (unknown, already used, expired, its
    /// session gone, the person banned), as opposed to being busy, down or behind a proxy that
    /// answered for it. Only this ends a session.
    private static func isRefreshTokenRefusal(_ response: HTTPResponse) -> Bool {
        guard (400..<500).contains(response.status), response.status != 408, response.status != 429,
              let body = try? HVCoding.decoder(.verbatim).decode(JSONValue.self, from: response.data)
        else { return false }
        // GoTrue says it in `error` (OAuth style) or in `error_code` and `msg`.
        let said = ["error", "error_code", "error_description", "msg", "message"]
            .compactMap { body[$0]?.string?.lowercased() }
        let refusals = [
            "invalid_grant", "invalid refresh token", "refresh_token_not_found", "refresh_token_already_used",
            "session_not_found", "session_expired", "user_not_found", "user_banned",
            // What GoTrue says of a stored token that is empty or malformed: it cannot be refreshed either.
            "refresh token is not valid",
        ]
        return said.contains { text in refusals.contains { text.contains($0) } }
    }

    // MARK: Sign-in

    /// What the project lets people sign in with.
    public func providers() async -> AuthProviders {
        var request = URLRequest(url: config.url.appendingPathComponent("auth/v1/settings"))
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        request.timeoutInterval = 15
        guard let response = try? await transport.send(request), (200..<300).contains(response.status),
              let body = try? HVCoding.decoder(.verbatim).decode(JSONValue.self, from: response.data),
              let external = body["external"]?.object
        else {
            // When settings cannot be read, offer what the web app offers.
            return AuthProviders(google: true, apple: false, email: false)
        }
        return AuthProviders(
            google: external["google"]?.bool ?? false,
            apple: external["apple"]?.bool ?? false,
            email: external["email"]?.bool ?? false,
            signupDisabled: body["disable_signup"]?.bool ?? false
        )
    }

    /// The URL to open in a web authentication session to sign in with `provider`
    /// (`google`, `apple`). Remembers the PKCE verifier for `completeOAuth`.
    public func authorizationURL(provider: String, redirectTo: URL) async throws -> URL {
        let verifier = PKCE.makeVerifier()
        await store.set(Data(verifier.utf8), for: Self.verifierKey)
        var components = URLComponents(url: config.url.appendingPathComponent("auth/v1/authorize"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "provider", value: provider),
            URLQueryItem(name: "redirect_to", value: redirectTo.absoluteString),
            URLQueryItem(name: "code_challenge", value: PKCE.challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "s256"),
        ]
        guard let url = components?.url else { throw AuthError.notConfigured }
        return url
    }

    /// Finishes a web sign-in from the URL the provider sent the app back to.
    @discardableResult
    public func completeOAuth(callbackURL: URL) async throws -> AuthSession {
        let items = Self.parameters(of: callbackURL)
        if let error = items["error_description"] ?? items["error"] {
            let cancelled = items["error"] == "access_denied"
            throw cancelled ? AuthError.cancelled : AuthError.failed(error.replacingOccurrences(of: "+", with: " "))
        }
        guard let code = items["code"] else { throw AuthError.failed("Sign-in did not finish. Try again.") }
        guard let verifierData = await store.get(Self.verifierKey), let verifier = String(data: verifierData, encoding: .utf8) else {
            throw AuthError.failed("Sign-in expired. Try again.")
        }
        let response = try await request(
            path: "auth/v1/token",
            query: [URLQueryItem(name: "grant_type", value: "pkce")],
            body: ["auth_code": .string(code), "code_verifier": .string(verifier)]
        )
        let newSession = try makeSession(from: response.data)
        await store.remove(Self.verifierKey)
        await adopt(newSession)
        return newSession
    }

    /// Signs in with a token from Sign in with Apple. `nonce` is the raw nonce
    /// whose SHA-256 was sent to Apple.
    @discardableResult
    public func signIn(withIDToken token: String, provider: String = "apple", nonce: String?) async throws -> AuthSession {
        var body: [String: JSONValue] = ["provider": .string(provider), "id_token": .string(token)]
        if let nonce { body["nonce"] = .string(nonce) }
        let response = try await request(
            path: "auth/v1/token",
            query: [URLQueryItem(name: "grant_type", value: "id_token")],
            body: body
        )
        let newSession = try makeSession(from: response.data)
        await adopt(newSession)
        return newSession
    }

    /// Emails a six-digit code. A new address becomes a new account.
    public func requestEmailCode(email: String) async throws {
        _ = try await request(
            path: "auth/v1/otp",
            query: [],
            body: ["email": .string(email.trimmingCharacters(in: .whitespaces)), "create_user": true]
        )
    }

    @discardableResult
    public func verifyEmailCode(email: String, code: String) async throws -> AuthSession {
        let response = try await request(
            path: "auth/v1/verify",
            query: [],
            body: [
                "type": "email",
                "email": .string(email.trimmingCharacters(in: .whitespaces)),
                "token": .string(code.filter(\.isNumber)),
            ]
        )
        let newSession = try makeSession(from: response.data)
        await adopt(newSession)
        return newSession
    }

    /// Ends the session here and, when it can, on the server.
    public func signOut() async {
        await loadIfNeeded()
        if let current = session {
            var request = URLRequest(url: logoutURL())
            request.httpMethod = "POST"
            request.timeoutInterval = 10
            request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(current.accessToken)", forHTTPHeaderField: "Authorization")
            _ = try? await transport.send(request)
        }
        await store.remove(Self.verifierKey)
        await clearSession()
    }

    private func logoutURL() -> URL {
        var components = URLComponents(url: config.url.appendingPathComponent("auth/v1/logout"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "scope", value: "local")]
        return components?.url ?? config.url
    }

    // MARK: Plumbing

    /// A call whose answer must be a success; a refusal is `.failed` with the server's sentence.
    private func request(path: String, query: [URLQueryItem], body: [String: JSONValue]) async throws -> HTTPResponse {
        let response = try await send(path: path, query: query, body: body)
        guard (200..<300).contains(response.status) else {
            throw AuthError.failed(Self.message(from: response))
        }
        return response
    }

    /// POSTs to the auth server and returns whatever status it answered. Only a call that got no
    /// answer throws.
    private func send(path: String, query: [URLQueryItem], body: [String: JSONValue]) async throws -> HTTPResponse {
        var components = URLComponents(url: config.url.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else { throw AuthError.notConfigured }

        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(config.anonKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? HVCoding.encoder(.verbatim).encode(JSONValue.object(body))

        do {
            return try await transport.send(request)
        } catch let error as URLError where error.code == .cancelled {
            throw AuthError.cancelled
        } catch {
            throw AuthError.network(error.localizedDescription)
        }
    }

    static func message(from response: HTTPResponse) -> String {
        let body = try? HVCoding.decoder(.verbatim).decode(JSONValue.self, from: response.data)
        let raw = body?["msg"]?.string
            ?? body?["error_description"]?.string
            ?? body?["message"]?.string
            ?? body?["error"]?.string
        guard let raw, !raw.isEmpty else { return "Sign-in did not work. Try again." }
        // Make the common GoTrue refusals readable.
        let lowered = raw.lowercased()
        if lowered.contains("invalid refresh token") || lowered.contains("refresh_token_not_found") {
            return "Your session ended. Sign in again."
        }
        // GoTrue answers a wrong code and an expired one in the same words ("Token has expired or is invalid").
        if lowered.contains("token has expired") || lowered.contains("otp_expired") {
            return "That code did not work, or it has expired. Check it, or ask for a new one."
        }
        // A Google sign-in whose state is gone (the sheet sat open too long, or the link was used twice).
        if lowered.contains("flow state") || lowered.contains("flow_state") {
            return "That sign-in expired. Start again."
        }
        if lowered.contains("invalid") && lowered.contains("token") {
            return "That code did not work. Check it and try again."
        }
        return raw
    }

    private func makeSession(from data: Data) throws -> AuthSession {
        guard let token = try? HVCoding.decoder(.verbatim).decode(TokenResponse.self, from: data) else {
            throw AuthError.failed("Sign-in answered in a way the app could not read.")
        }
        let expires: Date
        if let at = token.expiresAt {
            expires = Date(timeIntervalSince1970: at)
        } else {
            expires = now().addingTimeInterval(TimeInterval(token.expiresIn ?? 3600))
        }
        return AuthSession(
            accessToken: token.accessToken,
            refreshToken: token.refreshToken,
            expiresAt: expires,
            user: token.user.authUser
        )
    }

    /// Query and fragment parameters of a callback URL, merged.
    static func parameters(of url: URL) -> [String: String] {
        var result: [String: String] = [:]
        if let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems {
            for item in items { result[item.name] = item.value ?? "" }
        }
        if let fragment = url.fragment, let items = URLComponents(string: "?" + fragment)?.queryItems {
            for item in items { result[item.name] = item.value ?? "" }
        }
        return result
    }
}

// MARK: Token response

private struct TokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int?
    let expiresAt: Double?
    let user: GoTrueUser

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case expiresAt = "expires_at"
        case user
    }
}

private struct GoTrueUser: Decodable {
    let id: String
    let email: String?
    let appMetadata: [String: JSONValue]?
    let userMetadata: [String: JSONValue]?

    enum CodingKeys: String, CodingKey {
        case id, email
        case appMetadata = "app_metadata"
        case userMetadata = "user_metadata"
    }

    var authUser: AuthUser {
        let meta = userMetadata ?? [:]
        let name = meta["full_name"]?.string ?? meta["name"]?.string
        let avatar = meta["avatar_url"]?.string ?? meta["picture"]?.string
        return AuthUser(
            id: id,
            email: email,
            displayName: name,
            avatarUrl: avatar,
            provider: appMetadata?["provider"]?.string
        )
    }
}

// MARK: PKCE and nonces

public enum PKCE {
    /// A random verifier of 86 URL-safe characters.
    public static func makeVerifier() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<64).map { _ in UInt8.random(in: 0...255, using: &generator) }
        return Data(bytes).base64URLEncoded
    }

    public static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(Data(verifier.utf8))).base64URLEncoded
    }
}

public enum AuthNonce {
    /// A raw nonce for Supabase and the SHA-256 hex of it for Apple's request.
    public static func make() -> (raw: String, hashed: String) {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: 0...255, using: &generator) }
        let raw = Data(bytes).base64URLEncoded
        return (raw, SHA256.hex(Data(raw.utf8)))
    }
}
