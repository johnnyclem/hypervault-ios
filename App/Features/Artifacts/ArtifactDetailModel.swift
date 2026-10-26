import HyperVaultKit
import SwiftUI

/// The state behind one page: what to show in the web view, what is known about
/// the page, and the few things done to it straight from the bar. The heavier
/// jobs (sharing, source, history, passwords) have models of their own.
@MainActor
@Observable
final class ArtifactDetailModel {
    enum PageState {
        case loading
        case ready(ArtifactWebContent)
        case blocked(ArtifactBlock)
    }

    let slug: String
    private(set) var pageState: PageState = .loading
    /// What the list knows about the page; nil for a page that is not the person's own.
    private(set) var summary: ArtifactSummary?
    /// Whether the page is the person's own: nil until that is known.
    private(set) var isOwner: Bool?
    private(set) var kindHint: KeptKind?
    private(set) var feedback: ArtifactFeedback?
    private(set) var pins = SidebarPins()
    private(set) var realms: [ArtifactRealm] = []
    private(set) var embeddedFile: ArtifactEmbeddedFile?
    /// The page's row id, which connections are keyed by. Asked for when needed.
    private(set) var rowID: String?
    /// 0...1 while the web view is loading.
    var progress: Double = 0
    var webFailure: String?

    let env: AppEnvironment
    private let loader: ArtifactPageLoader
    private var hasLoaded = false

    init(slug: String, env: AppEnvironment, loader: ArtifactPageLoader? = nil) {
        self.slug = slug
        self.env = env
        self.loader = loader ?? ArtifactPageLoader(baseURL: env.server.baseURL, tokens: env.auth)
    }

    // MARK: What is known

    var title: String { summary?.title ?? "Page" }
    var visibility: ArtifactVisibility? { summary?.visibility }
    var isGroup: Bool { summary?.isGroup ?? (kindHint == .group) }
    var isStoredFile: Bool { summary?.isStoredFile ?? (kindHint == .file) }
    var isPinned: Bool { pins.contains(artifact: slug) }
    var canManage: Bool { isOwner != false }

    var linkRouter: ArtifactLinkRouter {
        ArtifactLinkRouter(serverHost: env.server.baseURL.host, domains: env.capabilities.domains.map(\.domain))
    }

    /// The permanent link on the app's own address, which every claimed address also serves.
    func link(host: String? = nil) -> URL {
        ArtifactLinks.url(slug: slug, isGroup: isGroup, host: host, appURL: env.server.baseURL)
    }

    /// The address a link is shared from by default: a public page lives on the person's own address when they have one (the web's `linkOrigin`).
    var defaultHost: String? {
        visibility == .public ? ArtifactLinks.primaryHost(realms) : nil
    }

    var shareURL: URL { link(host: defaultHost) }

    /// The page in Safari: where a private page asks for a sign-in the app cannot give it.
    var safariURL: URL { link() }

    // MARK: Loading

    func load() async {
        // Coming back to the screen from something pushed over it keeps the page where it was.
        guard !hasLoaded else { return }
        hasLoaded = true
        pageState = .loading
        webFailure = nil
        if summary == nil { summary = await cachedSummary() }
        // A page not seen before is asked about first: a group is read another way from a page.
        let known = summary != nil
        if !known { await loadMetadata() }
        async let metadata: Void = refreshMetadata(if: known)
        async let extras: Void = loadExtras()
        await loadPage()
        await metadata
        await extras
        if isStoredFile, case .ready(let content) = pageState, case .html(let html, _) = content.source {
            embeddedFile = ArtifactEmbeddedFile.find(in: html)
        }
    }

    /// Asks again for the markup, after a repair, an edit or a pull.
    func reload() async {
        webFailure = nil
        progress = 0
        await loadPage()
    }

    private func loadPage() async {
        let result = await loader.load(slug: slug, isGroup: isGroup, visibility: summary?.visibility)
        switch result {
        case .html(let html, let base):
            pageState = .ready(ArtifactWebContent(source: .html(html, base: base)))
        case .navigate(let url):
            pageState = .ready(ArtifactWebContent(source: .url(url)))
        case .blocked(let block):
            pageState = .blocked(block)
        }
    }

    private func cachedSummary() async -> ArtifactSummary? {
        let entry = await env.cache.entry(ArtifactList.self, key: LibraryCache.artifactsKey, namespace: env.user.id)
        return entry?.value.items.first { $0.slug == slug }
    }

    private func refreshMetadata(if known: Bool) async {
        if known { await loadMetadata() }
    }

    private func loadMetadata() async {
        let client = env.client
        let fetch: @Sendable () async throws -> ArtifactList = { try await client.send(.artifacts) }
        do {
            for try await loaded in env.load(LibraryCache.artifactsKey, fetch: fetch) {
                if let found = loaded.value.items.first(where: { $0.slug == slug }) {
                    summary = found
                    isOwner = true
                }
            }
        } catch {
            // The page itself is what matters; the details fill in when they can.
        }
        if summary == nil { await lookUpCard() }
    }

    /// A page past the list's 200, or someone else's: the card says which, and what kind.
    private func lookUpCard() async {
        do {
            let card = try await env.client.send(.card(slug: slug))
            kindHint = card.kind
            rowID = card.id
            isOwner = true
            if summary == nil {
                summary = ArtifactSummary(slug: slug, title: card.name, type: card.kind == .group ? "group" : "html", visibility: .private)
                summaryIsPlaceholder = true
            }
        } catch let error as HVError where error.isNotFound {
            isOwner = false
        } catch {
            // Offline or a hiccup: leave ownership unknown rather than guess.
        }
    }

    /// True when `summary` was made from a card and so does not know the real visibility.
    private(set) var summaryIsPlaceholder = false

    private func loadExtras() async {
        async let rated = try? env.client.send(.artifactFeedback(slug: slug))
        async let claimed = readRealms()
        async let pinned = readPins()
        if let state = await rated { feedback = state.feedback }
        if let list = await claimed { realms = list }
        if let list = await pinned { pins = list }
    }

    /// Reads the person's addresses again, after one was pointed at a page.
    func refreshRealms() async {
        if let list = await readRealms() { realms = list }
    }

    private func readRealms() async -> [ArtifactRealm]? {
        guard let tables = env.artifactTables else { return nil }
        return try? await ArtifactRealmReader(tables: tables, userId: env.user.id).realms()
    }

    private func readPins() async -> SidebarPins? {
        guard let tables = env.artifactTables else { return nil }
        return try? await SidebarPinsReader(tables: tables, userId: env.user.id).pins()
    }

    /// The page's row id, for connections. Nil for a page that is not the person's.
    func ensureRowID() async -> String? {
        if let rowID { return rowID }
        do {
            let card = try await env.client.send(.card(slug: slug))
            rowID = card.id
            return card.id
        } catch {
            return nil
        }
    }

    // MARK: Doing things

    /// Changes who can open the page: at once on screen, rolled back if the server says no.
    func setVisibility(_ next: ArtifactVisibility, toasts: ToastCenter) async {
        guard let current = summary, current.visibility != next else { return }
        replaceSummary(with: current.withVisibility(next))
        do {
            let result = try await env.client.send(.setArtifactVisibility(slug: slug, to: next))
            toasts.show(result.message, style: .success)
            await persistSummary()
        } catch {
            // Only the visibility goes back. The page may have changed in another way while this was out.
            if let latest = summary { replaceSummary(with: latest.withVisibility(current.visibility)) }
            toasts.show(error: error)
        }
    }

    func setIcon(_ glyph: String?, toasts: ToastCenter) async -> Bool {
        guard summary != nil else { return false }
        do {
            _ = try await env.client.send(.setArtifactIcon(slug: slug, glyph: glyph))
            // Set on the page as it is now, not as it was when the request went out.
            if let latest = summary { replaceSummary(with: latest.withIcon(ArtifactIcon.normalizedGlyph(glyph))) }
            Haptics.success()
            await persistSummary()
            return true
        } catch {
            toasts.show(error: error)
            return false
        }
    }

    /// A thumb; tapping the one already given clears it.
    func rate(_ choice: ArtifactFeedback, toasts: ToastCenter) async {
        let previous = feedback
        let next: ArtifactFeedback? = previous == choice ? nil : choice
        feedback = next
        do {
            _ = try await env.client.send(.rateArtifact(slug: slug, next))
            Haptics.tap()
        } catch {
            feedback = previous
            toasts.show(error: error)
        }
    }

    func togglePin(toasts: ToastCenter) async {
        let previous = pins
        do {
            // The pin list is replaced whole, so start from what the server holds now.
            let current = (await readPins()) ?? previous
            let next = current.toggling(artifact: slug)
            pins = next
            _ = try await env.client.send(.replaceSidebarPins(next.pins))
            Haptics.tap()
            toasts.show(next.contains(artifact: slug) ? "Pinned to your Library." : "Unpinned.", style: .info)
        } catch {
            pins = previous
            toasts.show(error: error)
        }
    }

    /// Deletes the page for good. A group has its own call, which removes its files.
    func delete() async throws {
        if isGroup {
            _ = try await env.client.send(.deleteArtifactGroup(slug: slug))
        } else {
            _ = try await env.client.send(.deleteArtifact(slug: slug))
        }
        Haptics.success()
        await removeFromCache()
    }

    // MARK: Cache

    private func replaceSummary(with next: ArtifactSummary) {
        summary = next
    }

    /// Keeps the saved list in step with a change made here, so the Library does not show the old one.
    private func persistSummary() async {
        guard let summary, !summaryIsPlaceholder else { return }
        let entry = await env.cache.entry(ArtifactList.self, key: LibraryCache.artifactsKey, namespace: env.user.id)
        guard var items = entry?.value.items, let index = items.firstIndex(where: { $0.slug == slug }) else { return }
        items[index] = summary
        await env.cache.store(ArtifactList(items: items), key: LibraryCache.artifactsKey, namespace: env.user.id)
    }

    private func removeFromCache() async {
        let entry = await env.cache.entry(ArtifactList.self, key: LibraryCache.artifactsKey, namespace: env.user.id)
        guard let items = entry?.value.items else { return }
        await env.cache.store(ArtifactList(items: items.filter { $0.slug != slug }), key: LibraryCache.artifactsKey, namespace: env.user.id)
    }
}

extension ArtifactSummary {
    func withVisibility(_ visibility: ArtifactVisibility) -> ArtifactSummary {
        ArtifactSummary(
            slug: slug, title: title, type: type, tags: tags, sourcePrompt: sourcePrompt, isPwa: isPwa, isJsx: isJsx,
            visibility: visibility, icon: icon, createdAt: createdAt, url: url
        )
    }

    func withIcon(_ icon: String?) -> ArtifactSummary {
        ArtifactSummary(
            slug: slug, title: title, type: type, tags: tags, sourcePrompt: sourcePrompt, isPwa: isPwa, isJsx: isJsx,
            visibility: visibility, icon: icon, createdAt: createdAt, url: url
        )
    }
}

/// Keys the Library and the page screens save under, so a change made on one shows on the other.
enum LibraryCache {
    static let artifactsKey = "library.artifacts"
    static let edgesKey = "library.edges"
    static func yoursKey(_ filter: YoursFilter) -> String { "library.yours.\(filter.rawValue)" }
}
