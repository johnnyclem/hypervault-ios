import HyperVaultKit
import SwiftUI

/// Preference keys, shared by `@AppStorage` in views and plain code.
enum PrefKey {
    static let appearance = "pref.appearance"
    static let accent = "pref.accent"
    static let haptics = Haptics.preferenceKey
    static let biometricLock = "pref.biometricLock"
    static let onboarded = "pref.onboarded.v1"
    static let onDeviceChat = "pref.onDeviceChat"
    static let approvedUser = "hv.approvedUser"
    /// Whose traces are on this phone: set when someone signs in, removed once everything they left is gone. It
    /// outlives the process, so a session that ended while the app was closed is still cleaned up at the next launch.
    static let sessionUser = "hv.sessionUser"
}

/// Why the app would not switch to a server, in words for Settings.
enum ServerSwitchError: LocalizedError, Equatable {
    case unreachable(host: String)
    case notHyperVault(host: String)
    case notSetUp(host: String)

    var errorDescription: String? {
        switch self {
        case .unreachable(let host): return "Could not reach \(host). Check the address and your connection."
        case .notHyperVault(let host): return "\(host) is not a HyperVault server."
        case .notSetUp(let host): return "\(host) is a HyperVault server that is not set up for sign-in yet."
        }
    }
}

/// The app's root state: where launch has got to, and the signed-in
/// environment once there is one. Nothing past `.ready` is built until the
/// server has said who this is and that they are let in.
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case launching
        case unreachable(String)
        case signedOut
        case waitlisted(AuthUser)
        case ready
    }

    private(set) var phase: Phase = .launching
    private(set) var env: AppEnvironment?
    private(set) var providers = AuthProviders()
    private(set) var auth: AuthService?
    private(set) var server: ServerConfig

    let toasts = ToastCenter()
    let router = AppRouter()
    let lock = AppLock()

    /// An invite code that arrived in a link before anyone was signed in.
    var pendingInviteCode: String?

    @ObservationIgnored private let secureStore: SecureStore
    @ObservationIgnored private let transport: HTTPTransport
    @ObservationIgnored private let cache: DiskCache
    @ObservationIgnored private var capabilities: Capabilities?
    @ObservationIgnored private var observer: Task<Void, Never>?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var pendingLink: DeepLink?

    /// The defaults are the real app's; tests pass a mock transport, an in-memory store and a scratch folder.
    init(
        secureStore: SecureStore = KeychainSecureStore(),
        server: ServerConfig = SharedConfig.server,
        transport: HTTPTransport = URLSessionTransport(),
        cacheDirectory: URL = AppModel.cacheDirectory()
    ) {
        self.secureStore = secureStore
        self.server = server
        self.transport = transport
        self.cache = DiskCache(directory: cacheDirectory)
    }

    nonisolated static func cacheDirectory() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("HyperVault", isDirectory: true)
    }

    // MARK: Launch

    func start() async {
        guard !started else { return }
        started = true
        await bootstrap()
    }

    func retry() async {
        started = true
        await bootstrap()
    }

    /// Points the app at a different deployment and starts over, once that deployment has answered like a HyperVault
    /// server that can sign people in. Until it has, nothing changes: the person stays signed in, the cache and the saved
    /// address stay as they were, and the error says why.
    func changeServer(to newServer: ServerConfig) async throws {
        guard newServer != server else { return }
        let verified = try await verify(newServer)
        await leave(for: newServer, seeding: verified)
    }

    /// The way back from a saved address that no longer answers: the server the app ships with.
    func resetServer() async {
        let fallback = SharedConfig.defaultServer
        guard server != fallback else { return }
        await leave(for: fallback, seeding: nil)
    }

    /// Whether the app is pointed at something other than the server it ships with.
    var isOnDefaultServer: Bool { server == SharedConfig.defaultServer }

    /// The candidate's capabilities, once it has answered like a HyperVault server that can sign people in.
    private func verify(_ candidate: ServerConfig) async throws -> Capabilities {
        let host = candidate.baseURL.host() ?? candidate.baseURL.absoluteString
        do {
            let capabilities = try await HVClient(baseURL: candidate.baseURL, transport: transport).send(.capabilities)
            guard capabilities.supabase != nil else { throw ServerSwitchError.notSetUp(host: host) }
            return capabilities
        } catch let error as HVError {
            switch error {
            case .transport: throw ServerSwitchError.unreachable(host: host)
            case .cancelled: throw error
            default: throw ServerSwitchError.notHyperVault(host: host)
            }
        }
    }

    /// Ends the session on the old server, takes what it left off the phone, and starts over on the new one.
    private func leave(for newServer: ServerConfig, seeding verified: Capabilities?) async {
        observer?.cancel()
        observer = nil
        let namespace = sessionUserID
        // Out of the app first, so the clean-up below does not play out on screen.
        env = nil
        phase = .launching
        // A launch that never got as far as a service still has the session in the Keychain: end it where it began.
        let ending = auth ?? SharedConfig.supabase.map { AuthService(config: $0, transport: transport, store: secureStore) }
        await ending?.signOut()
        await wipeLocalState(namespace: namespace)
        await cache.clearAll()
        // The address has just answered; let launch use that answer rather than depend on a second one.
        if let verified { await cache.store(verified, key: "capabilities", namespace: "app") }
        auth = nil
        capabilities = nil
        SharedConfig.supabase = nil
        server = newServer
        SharedConfig.server = newServer
        await bootstrap()
    }

    private func bootstrap() async {
        phase = .launching
        observer?.cancel()

        let publicClient = HVClient(baseURL: server.baseURL, transport: transport)
        var caps: Capabilities?
        var failure: HVError?
        do {
            let fresh = try await publicClient.send(.capabilities)
            caps = fresh
            await cache.store(fresh, key: "capabilities", namespace: "app")
        } catch {
            failure = error as? HVError
            caps = await cache.entry(Capabilities.self, key: "capabilities", namespace: "app")?.value
        }

        guard let caps else {
            phase = .unreachable(failure?.userMessage ?? "HyperVault could not be reached.")
            return
        }
        guard let supabase = caps.supabase else {
            phase = .unreachable("This server is not set up for sign-in yet.")
            return
        }
        capabilities = caps
        SharedConfig.supabase = supabase

        let service = AuthService(config: supabase, transport: transport, store: secureStore)
        auth = service
        providers = await service.providers()
        await service.restore()

        observer = Task { [weak self] in
            let states = await service.states()
            for await state in states {
                guard let self else { return }
                await self.apply(state)
            }
        }
    }

    private func apply(_ state: AuthState) async {
        switch state {
        case .unknown:
            break
        case .signedOut:
            // The session ended, by the person or by itself (a refresh the server refused). Whatever the account left
            // goes either way, but only if someone really was signed in: a launch with no session has nothing to wipe,
            // and what waits in the outbox then belongs to no one yet.
                if let namespace = sessionUserID { await wipeLocalState(namespace: namespace) }
            env = nil
            phase = .signedOut
        case .signedIn(let user):
            // A token refresh republishes the same person: nothing to rebuild.
            if case .ready = phase, env?.user.id == user.id { return }
            if let previous = sessionUserID, previous != user.id { await wipeLocalState(namespace: previous) }
            SharedConfig.defaults.set(user.id, forKey: PrefKey.sessionUser)
            await resolveAccess(for: user)
        }
    }

    /// Asks the server whether this person is let in. The capabilities answer
    /// carries a `user` block only for an identity that passed the invite gate.
    func resolveAccess(for user: AuthUser) async {
        guard let auth else { return }
        let client = HVClient(baseURL: server.baseURL, transport: transport, tokens: auth)
        do {
            let fresh = try await client.send(.capabilities)
            capabilities = fresh
            if fresh.user != nil {
                SharedConfig.defaults.set(user.id, forKey: PrefKey.approvedUser)
                activate(user: user, client: client, auth: auth, capabilities: fresh)
            } else {
                env = nil
                phase = .waitlisted(user)
            }
        } catch let error as HVError {
            if error.isUnauthorized { return }  // the auth service is signing out
            if SharedConfig.defaults.string(forKey: PrefKey.approvedUser) == user.id, let capabilities {
                // Offline, but this person was let in before: open from the cache.
                activate(user: user, client: client, auth: auth, capabilities: capabilities)
            } else {
                phase = .unreachable(error.userMessage)
            }
        } catch {
            phase = .unreachable(error.localizedDescription)
        }
    }

    private func activate(user: AuthUser, client: HVClient, auth: AuthService, capabilities: Capabilities) {
        env = AppEnvironment(client: client, auth: auth, capabilities: capabilities, user: user, server: server, cache: cache)
        phase = .ready
        // Widgets that were waiting for someone to sign in, or showing the last account, read the new one now.
        WidgetRefresh.reload()
        if let link = pendingLink {
            pendingLink = nil
            router.open(link)
        }
    }

    // MARK: Account

    func signOut() async {
        let namespace = sessionUserID
        await auth?.signOut()
        await wipeLocalState(namespace: namespace)
    }

    private var sessionUserID: String? {
        SharedConfig.defaults.string(forKey: PrefKey.sessionUser)
    }

    /// Takes everything the account left on this phone off it: its cache, what was waiting to be kept, the names the
    /// widgets and Spotlight hold, and where the person was in the app. Every way a session can end comes through here
    /// (signing out, a refresh the server refused, a switch of server), so none leaves anything for the next person to
    /// see, or to have kept into their own vault. A link that arrived before sign-in is not the account's and stays.
    private func wipeLocalState(namespace: String?) async {
        if let namespace { await cache.clear(namespace: namespace) }
        OutboxStore.save([])
        SpotlightIndexer.clear()
        SharedConfig.forgetWidgetCache()
        WidgetRefresh.reload()
        for key in [PrefKey.approvedUser, PrefKey.sessionUser] {
            SharedConfig.defaults.removeObject(forKey: key)
        }
        router.reset()
    }

    /// Redeems an invite code for the signed-in, waitlisted person.
    func redeemInvite(_ code: String) async throws -> InviteResult {
        guard let auth, let supabase = capabilities?.supabase else { throw HVError.unauthorized }
        let redeemer = InviteRedeemer(config: supabase, transport: transport, tokens: auth)
        let result = try await redeemer.redeem(code)
        if result.isAccepted, let user = await auth.currentUser {
            pendingInviteCode = nil
            await resolveAccess(for: user)
        }
        return result
    }

    /// Re-checks access, for the waitlist screen's "Check again".
    func recheckAccess() async {
        guard let user = await auth?.currentUser else { return }
        await resolveAccess(for: user)
    }

    // MARK: Links

    func handle(url: URL) {
        guard let link = DeepLink(url: url) else { return }
        switch phase {
        case .ready:
            router.open(link)
        default:
            if case .invite(let code) = link { pendingInviteCode = code }
            pendingLink = link
        }
    }
}
