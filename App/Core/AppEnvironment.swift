import HyperVaultKit
import SwiftUI

/// Everything a signed-in screen needs, created once the person is signed in
/// and let in. Screens read it with `@Environment(AppEnvironment.self)`; view
/// models take `env.client` (and `env.cache` when they cache) as init
/// parameters so they stay testable with a `MockTransport`.
@MainActor
@Observable
final class AppEnvironment {
    let client: HVClient
    let auth: AuthService
    let capabilities: Capabilities
    let user: AuthUser
    let server: ServerConfig
    @ObservationIgnored let cache: DiskCache
    /// Tells of background jobs (a page repair) that finished while nobody was watching: on the Home canvas and the Library.
    let jobNotices: JobNotices
    /// The look the app wears for the person's theme (`AppModel.style`).
    let style: StyleKitStore

    /// Set by the Admin feature's probe; the Account menu shows the Admin row when true.
    var isAdmin = false

    init(
        client: HVClient, auth: AuthService, capabilities: Capabilities, user: AuthUser, server: ServerConfig, cache: DiskCache,
        style: StyleKitStore? = nil
    ) {
        self.style = style ?? StyleKitStore()
        self.client = client
        self.auth = auth
        self.capabilities = capabilities
        self.user = user
        self.server = server
        self.cache = cache
        self.jobNotices = JobNotices(client: client)
    }

    /// Reads and keeps this person's look, on the server and on disk. A server that sends no kits (`features.stylekit` false) is
    /// asked for the theme's id the way the Appearance pane always did, and the theme is then one the app cannot show.
    var styleLoader: StyleKitLoader {
        StyleKitLoader(client: client, rest: keysRest, cache: cache, userID: user.id, serverSendsKits: features.stylekit)
    }

    var limits: Capabilities.Limits { capabilities.limits }
    var features: Capabilities.Features { capabilities.features }

    /// Cached-then-fresh loading, namespaced to this person.
    func load<Value: Codable & Sendable>(
        _ key: String,
        fetch: @escaping @Sendable () async throws -> Value
    ) -> AsyncThrowingStream<Loaded<Value>, Error> {
        cachedLoad(cache: cache, namespace: user.id, key: key, fetch: fetch)
    }

    /// The permanent link for an artifact: `https://hypervault.store/a/<slug>`.
    func artifactURL(slug: String) -> URL {
        server.baseURL.appendingPathComponent("a").appendingPathComponent(slug)
    }

    /// A page on the web app, for hand-offs the app does not do itself.
    func webURL(_ path: String) -> URL {
        server.baseURL.appendingPathComponent(path.hasPrefix("/") ? String(path.dropFirst()) : path)
    }
}
