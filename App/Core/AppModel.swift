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

    /// Points the app at a different deployment and starts over.
    func changeServer(to newServer: ServerConfig) async {
        await auth?.signOut()
        await cache.clearAll()
        env = nil
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
            env = nil
            phase = .signedOut
        case .signedIn(let user):
            // A token refresh republishes the same person: nothing to rebuild.
            if case .ready = phase, env?.user.id == user.id { return }
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
        if let link = pendingLink {
            pendingLink = nil
            router.open(link)
        }
    }

    // MARK: Account

    func signOut() async {
        let namespace = env?.user.id
        await auth?.signOut()
        if let namespace { await cache.clear(namespace: namespace) }
        SpotlightIndexer.clear()
        SharedConfig.defaults.removeObject(forKey: PrefKey.approvedUser)
        router.sheet = nil
        router.popToRoot(.canvas)
        router.tab = .canvas
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
