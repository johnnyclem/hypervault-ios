import HyperVaultKit
import SwiftUI

/// What the Library shows and the few things it does to a row. The list is the
/// server's `GET /api/yours` (the same one Yours is), and the Files filter is
/// the file manager: every page, file and group with its type, who can open it,
/// its tags and how many things it is connected to.
@MainActor
@Observable
final class LibraryModel {
    /// A page, file or group in the file manager.
    struct FileRow: Identifiable, Equatable {
        let summary: ArtifactSummary
        /// The row id, when the list of ids knew it; connections are keyed by it.
        let rowID: String?
        let connections: Int
        var id: String { summary.slug }
    }

    enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    /// Rows revealed at first, and added by each "Show more" (the web's `LIBRARY_PAGE_SIZE`).
    static let pageSize = 25
    /// The most rows the route gives for one view (`MAX_LIMIT`).
    static let readLimit = 50

    private(set) var phase: Phase = .loading
    private(set) var items: [KeptItem] = []
    private(set) var artifacts: [ArtifactSummary] = []
    private(set) var rowIDs: [String: String] = [:]
    private(set) var edgeCounts: [String: Int] = [:]
    private(set) var isStale = false
    /// True when the first read failed for want of a connection, so the screen can say so with the right glyph.
    private(set) var failureIsOffline = false
    private(set) var sharedWithYou: [SharedWithYouItem] = []
    private(set) var pins = SidebarPins()
    /// The list of pages, read only to name the pinned ones when the file manager (which holds it) is not what is showing.
    private(set) var pinSummaries: [ArtifactSummary] = []
    private(set) var realms: [ArtifactRealm] = []
    var shown = LibraryModel.pageSize
    /// Set while something is being kept from a file.
    private(set) var busy: String?
    private var lastFilter: YoursFilter?

    let env: AppEnvironment

    init(env: AppEnvironment) {
        self.env = env
    }

    #if DEBUG
    /// The parts that are read from the person's own rows in Supabase, put in by hand for a preview or a
    /// snapshot, which have no such server.
    func seed(pins: SidebarPins = SidebarPins(), sharedWithYou: [SharedWithYouItem] = []) {
        self.pins = pins
        self.sharedWithYou = sharedWithYou
    }
    #endif

    // MARK: Reading

    func load(filter: YoursFilter, query: String) async {
        shown = Self.pageSize
        // The web cuts a search at 100 characters, as the route does.
        let text = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        // A different filter does not borrow the last one's rows while it loads.
        if filter != lastFilter {
            lastFilter = filter
            items = []
            phase = .loading
        } else if case .failed = phase {
            // A retry shows that it is reading, rather than the failure it is trying to get past.
            phase = .loading
        }
        if filter == .file {
            await loadFiles()
        } else {
            await loadYours(filter: filter, query: text)
        }
    }

    /// Pulls to refresh: the same read, nothing cached shown first.
    func refresh(filter: YoursFilter, query: String) async {
        await load(filter: filter, query: query)
        await loadExtras()
    }

    private func loadYours(filter: YoursFilter, query: String) async {
        let client = env.client
        if !query.isEmpty {
            // A search goes to the server for every name, and is not worth keeping.
            do {
                items = try await client.send(.yours(filter: filter, query: query, limit: Self.readLimit)).results
                isStale = false
                phase = .loaded
            } catch {
                // The list on screen is for another search, so it is not left standing as this one's answer.
                fail(error, keepingRows: false)
            }
            return
        }
        let fetch: @Sendable () async throws -> YoursList = {
            try await client.send(.yours(filter: filter, query: nil, limit: LibraryModel.readLimit))
        }
        do {
            for try await loaded in env.load(LibraryCache.yoursKey(filter), fetch: fetch) {
                items = loaded.value.results
                isStale = loaded.isStale
                phase = .loaded
            }
        } catch {
            fail(error, keepingRows: true)
        }
    }

    private func loadFiles() async {
        let client = env.client
        // The ids and the connections ride along; the list is what the screen waits for.
        async let edges: ArtifactEdges? = try? client.send(.artifactEdges)
        async let ids: YoursList? = try? client.send(.yours(filter: .file, query: nil, limit: Self.readLimit))
        let fetch: @Sendable () async throws -> ArtifactList = { try await client.send(.artifacts) }
        do {
            for try await loaded in env.load(LibraryCache.artifactsKey, fetch: fetch) {
                artifacts = loaded.value.items.filter { !$0.isBookkeeping }
                isStale = loaded.isStale
                phase = .loaded
            }
        } catch {
            fail(error, keepingRows: true)
        }
        if let list = await ids {
            var map: [String: String] = [:]
            for item in list.results {
                if let slug = item.slug { map[slug] = item.id }
            }
            rowIDs = map
        }
        if let found = await edges { edgeCounts = found.counts }
    }

    /// A read that failed. The rows on screen are kept only when they are this very view's, read before and
    /// only being refreshed: a filter switch resets the phase, so it never leans on another view's rows, and a
    /// search that fails says so instead of leaving the list it was meant to narrow.
    private func fail(_ error: Error, keepingRows: Bool) {
        guard !(error is CancellationError), (error as? HVError) != .cancelled else { return }
        if keepingRows, phase == .loaded {
            isStale = true
            return
        }
        failureIsOffline = (error as? HVError)?.isOffline == true
        phase = .failed(failureIsOffline ? LibraryCopy.offline : LibraryCopy.failed)
    }

    /// The parts that sit around the list: what was shared with the person, their pins, their addresses.
    func loadExtras() async {
        // These are the person's own rows, read as themselves; a server with no such project shows none.
        if let tables = env.artifactTables {
            let userId = env.user.id
            async let shared = try? SharedWithYouReader(tables: tables, userId: userId).items()
            async let pinned = try? SidebarPinsReader(tables: tables, userId: userId).pins()
            async let claimed = try? ArtifactRealmReader(tables: tables, userId: userId).realms()
            if let list = await shared { sharedWithYou = list }
            if let value = await pinned { pins = value }
            if let list = await claimed { realms = list }
        }
        await loadPinnedNames()
    }

    /// A pin is a slug. Its name is in the list of pages, which only the Files filter reads, so any other
    /// filter reads it here rather than show the slug.
    private func loadPinnedNames() async {
        guard !pins.artifactSlugs.isEmpty else { return }
        let client = env.client
        let fetch: @Sendable () async throws -> ArtifactList = { try await client.send(.artifacts) }
        do {
            for try await loaded in env.load(LibraryCache.artifactsKey, fetch: fetch) {
                pinSummaries = loaded.value.items
            }
        } catch {
            // The pins still show, under a name made from the slug.
        }
    }

    // MARK: The file manager

    func rows(matching query: String) -> [FileRow] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let all = artifacts.map { summary in
            FileRow(summary: summary, rowID: rowIDs[summary.slug], connections: rowIDs[summary.slug].flatMap { edgeCounts[$0] } ?? 0)
        }
        guard !needle.isEmpty else { return all }
        return all.filter { row in
            ([row.summary.title, row.summary.type, row.summary.typeName] + row.summary.tags).joined(separator: " ").lowercased().contains(needle)
        }
    }

    /// Pinned pages, in the order they were pinned, named from the list when it holds them.
    var pinnedRows: [(slug: String, title: String, summary: ArtifactSummary?)] {
        pins.artifactSlugs.map { slug in
            let found = artifacts.first { $0.slug == slug } ?? pinSummaries.first { $0.slug == slug }
            return (slug, found?.title ?? ArtifactSlugName.readable(slug), found)
        }
    }

    // MARK: Changing a row

    func setVisibility(_ row: FileRow, to visibility: ArtifactVisibility, toasts: ToastCenter) async {
        let slug = row.summary.slug
        guard let index = artifacts.firstIndex(where: { $0.slug == slug }) else { return }
        artifacts[index] = row.summary.withVisibility(visibility)
        do {
            let result = try await env.client.send(.setArtifactVisibility(slug: slug, to: visibility))
            toasts.show(result.message, style: .success)
            await persist()
        } catch {
            // Only this row goes back. Other rows may have changed while this one was out, and the server kept those.
            if let current = artifacts.firstIndex(where: { $0.slug == slug }) {
                artifacts[current] = artifacts[current].withVisibility(row.summary.visibility)
            }
            toasts.show(error: error)
        }
    }

    /// Deletes a page, or a group with its files. Gone from the list at once; back if the server says no.
    func delete(_ row: FileRow, toasts: ToastCenter) async -> Bool {
        let slug = row.summary.slug
        let position = artifacts.firstIndex { $0.slug == slug }
        artifacts.removeAll { $0.slug == slug }
        do {
            if row.summary.isGroup {
                _ = try await env.client.send(.deleteArtifactGroup(slug: row.summary.slug))
            } else {
                _ = try await env.client.send(.deleteArtifact(slug: row.summary.slug))
            }
            toasts.show("Deleted. Its link is gone for good.", style: .success)
            await persist()
            return true
        } catch {
            // Only this row comes back, where it was. A row deleted meanwhile stays deleted.
            if !artifacts.contains(where: { $0.slug == slug }) {
                artifacts.insert(row.summary, at: min(position ?? artifacts.count, artifacts.count))
            }
            toasts.show(error: error)
            return false
        }
    }

    func togglePin(slug: String, toasts: ToastCenter) async {
        let before = pins
        do {
            // The list is replaced whole, so start from what the server holds now.
            var current = before
            if let tables = env.artifactTables, let held = try? await SidebarPinsReader(tables: tables, userId: env.user.id).pins() {
                current = held
            }
            let next = current.toggling(artifact: slug)
            pins = next
            _ = try await env.client.send(.replaceSidebarPins(next.pins))
            Haptics.tap()
        } catch {
            pins = before
            toasts.show(error: error)
        }
    }

    /// A pinned page dragged to a new place among the pins. Back where it was if the server says no.
    func movePin(from source: IndexSet, to destination: Int, toasts: ToastCenter) async {
        guard let from = source.first else { return }
        let before = pins
        let next = pins.movingArtifact(from: from, to: destination)
        guard next != before else { return }
        pins = next
        do {
            _ = try await env.client.send(.replaceSidebarPins(next.pins))
            Haptics.tap()
        } catch {
            pins = before
            toasts.show(error: error)
        }
    }

    /// Leaves a page someone shared. Gone from the list at once; back if the server says no.
    func leave(_ item: SharedWithYouItem, toasts: ToastCenter) async {
        let before = sharedWithYou
        sharedWithYou.removeAll { $0.shareId == item.shareId }
        do {
            _ = try await env.client.send(.endShare(id: item.shareId))
            toasts.show("You left \u{201C}\(item.title)\u{201D}.", style: .success)
        } catch {
            sharedWithYou = before
            toasts.show(error: error)
        }
    }

    private func persist() async {
        await env.cache.store(ArtifactList(items: artifacts), key: LibraryCache.artifactsKey, namespace: env.user.id)
    }

    /// Records that a row was opened, so Yours puts it first next time. Best effort.
    func stampOpen(_ item: KeptItem) {
        let client = env.client
        Task { _ = try? await client.send(.markOpened(kind: item.kind, id: item.id)) }
    }

    // MARK: Keeping a file

    /// Uploads a PDF or an image and gives it a permanent link.
    func upload(data: Data, filename: String, toasts: ToastCenter) async -> ArtifactSaveResult? {
        busy = "Uploading \(filename)"
        defer { busy = nil }
        do {
            let result = try await ArtifactUploader(client: env.client).upload(data: data, filename: filename)
            toasts.show(result.duplicate ? LibraryCopy.alreadyKept : LibraryCopy.kept, style: .success)
            return result
        } catch {
            toasts.show(error: error)
            return nil
        }
    }
}
