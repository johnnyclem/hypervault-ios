import Foundation

/// Reads the person's look the way every cached screen is read: the copy on disk first, then the network, per person.
/// The app's `StyleKitStore` (main actor, observable) owns one and applies what it returns; this is the part that needs
/// no UI, so it is tested on Linux.
///
/// What is cached is the `DashboardThemeState` as decoded, kit included, under a key of its own in the person's cache
/// namespace. Reading it back runs the state's own checks again, so a build with stricter floors than the one that wrote
/// the file re-checks it. Signing out clears the namespace (`DiskCache.clear(namespace:)`), which takes this with it;
/// `forget()` does the same for this one key.
public struct StyleKitLoader: Sendable {
    /// The `DiskCache` key.
    public static let cacheKey = "stylekit"

    private let client: HVClient
    private let rest: AccountRest
    private let cache: DiskCache
    private let userID: String
    private let serverSendsKits: Bool

    /// - Parameters:
    ///   - rest: the Supabase read of `profiles.theme`, for a server that sends no kit.
    ///   - userID: the cache namespace, as everywhere else (`AppEnvironment.load`).
    ///   - serverSendsKits: `capabilities.features.stylekit`. When false the GET is not even tried.
    public init(client: HVClient, rest: AccountRest, cache: DiskCache, userID: String, serverSendsKits: Bool) {
        self.client = client
        self.rest = rest
        self.cache = cache
        self.userID = userID
        self.serverSendsKits = serverSendsKits
    }

    /// What is on disk for this person, nil when nothing is. No network: the first frame after sign-in can wear it.
    public func cached() async -> DashboardThemeState? {
        await Self.cached(in: cache, userID: userID)
    }

    /// The same read, for a caller that has the person and the cache but not yet a client: the app wears what is on disk
    /// while launch is still asking the server who this is.
    public static func cached(in cache: DiskCache, userID: String) async -> DashboardThemeState? {
        await cache.entry(DashboardThemeState.self, key: cacheKey, namespace: userID)?.value
    }

    /// Asks the server, keeps the answer, and returns it. A failure throws and leaves the cache as it was, so the look
    /// being worn stays.
    ///
    /// A server that sends kits answers `GET /api/dashboard-theme`. One that does not (`features.stylekit` false, or a
    /// 404/405 from a server that has the flag wrong) is asked for the theme id the way the pane always did, and the
    /// answer is that theme with no kit, which the app wears as its default look and can say it cannot show.
    public func refresh() async throws -> DashboardThemeState {
        let state = try await fetch()
        await cache.store(state, key: Self.cacheKey, namespace: userID)
        return state
    }

    /// Cached first, then fresh, as `cachedLoad` does it. The last element repeats the cached copy with `refreshError`
    /// when the network failed; with nothing cached a failure throws.
    public func load() -> AsyncThrowingStream<Loaded<DashboardThemeState>, Error> {
        let loader = self
        return cachedLoad(cache: cache, namespace: userID, key: Self.cacheKey) { try await loader.fetch() }
    }

    /// Keeps a state the server just returned (the answer to a `PATCH`), without another request.
    public func remember(_ state: DashboardThemeState) async {
        await cache.store(state, key: Self.cacheKey, namespace: userID)
    }

    /// Drops this person's cached look.
    public func forget() async {
        await cache.remove(key: Self.cacheKey, namespace: userID)
    }

    /// Asks the server and returns the answer without keeping it: for a caller that decides whether the answer is still the
    /// one it wants (the app's store drops an answer that a newer choice or a sign-out has overtaken) before it `remember`s it.
    /// Same rules as `refresh()`.
    public func fetch() async throws -> DashboardThemeState {
        if serverSendsKits, let state = try await client.dashboardThemeState() {
            return state
        }
        let theme = try await rest.dashboardTheme(userID: userID)
        return DashboardThemeState(theme: theme)
    }
}
