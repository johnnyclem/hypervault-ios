import HyperVaultKit
import SwiftUI

/// What the overview of one project reads, and how each part of it fares. The board and the sections that go with it
/// load, fail and retry on their own: a chat list that will not load does not take the board down with it.
@MainActor
@Observable
final class ProjectOverviewModel {
    enum Part<Value: Equatable>: Equatable {
        case loading
        case loaded(Value)
        case failed(String)
    }

    /// The reads behind the sections that go with the project. A failed one is named here so its section can say so; the
    /// others still show.
    enum Source: String, Hashable, CaseIterable {
        case pages, links, memories, chats
    }

    let project: String
    private(set) var title: String
    private(set) var board: Part<ProjectBoardDigest> = .loading
    /// The board shown is the saved copy, because the server could not be reached.
    private(set) var boardIsStale = false
    private(set) var related: Part<ProjectRelated> = .loading
    /// The sections shown are the saved copy, because none of the reads behind them worked.
    private(set) var relatedIsStale = false
    private(set) var unavailable: Set<Source> = []

    @ObservationIgnored private let env: AppEnvironment
    @ObservationIgnored private var started = false
    @ObservationIgnored private var firstLoadDone = false
    @ObservationIgnored private var boardVersion: Int?
    @ObservationIgnored private var relatedLoadedAt: Date?

    /// A read of what goes with the project this recent is not made again when the screen reappears (coming back from
    /// the page it opened).
    private static let freshFor: TimeInterval = 60

    /// The board could not be read (a link to a project that is not in this vault, say): nothing else is said about it.
    var boardFailed: Bool {
        if case .failed = board { return true }
        return false
    }

    /// The same keys the board screen and the list of boards use, so opening a project after either is a cache hit, and
    /// the other way round.
    static func boardKey(_ project: String) -> String { "taskboards.board.\(project)" }
    static let indexKey = "taskboards.index"
    /// What the sections came to, the last time every read behind them worked.
    static func relatedKey(_ project: String) -> String { "projects.related.\(project)" }

    init(env: AppEnvironment, project: String) {
        self.env = env
        self.project = project
        title = ArtifactSlugName.readable(project)
    }

    /// The listing the Projects list already holds, when there is one: what the board is called, as the list spells it.
    private func cachedListing() async -> TaskBoardListing? {
        let index = await env.cache.entry(TaskBoardIndex.self, key: Self.indexKey, namespace: env.user.id)
        return index?.value.boards.first { $0.project == project }
    }

    func start() async {
        guard !started else { return }
        started = true
        if let listing = await cachedListing() { title = listing.displayTitle }
        // Everything is asked at once. What goes with the project is put together once the board has answered, because it
        // is matched by the board's name, which the board is the first to say right.
        let client = env.client, rest = env.keysRest, userID = env.user.id
        async let sources = Self.read(client: client, rest: rest, userID: userID)
        await seedRelatedFromTheSavedCopy()
        await loadBoard()
        let read = await sources
        if !boardFailed { await put(together: read) }
        firstLoadDone = true
    }

    /// Pull to refresh: the board by the cheap poll, what goes with it read again.
    func refresh() async {
        await reload(force: true)
    }

    /// The screen came back (from the board, or a page it opened). The board is polled every time, which is one small
    /// request that answers "unchanged"; what goes with it only when the last read is old.
    func refreshIfStarted() async {
        guard firstLoadDone else { return }
        await reload(force: false)
    }

    /// The board and what goes with it, side by side. A board that has not answered yet (the first read failed, or the
    /// screen was left before it came back) is read first, whatever the screen was doing: what goes with the project is
    /// matched by the board's name, which only the board says right, and sections built before it would match by the id.
    private func reload(force: Bool) async {
        guard boardVersion != nil else {
            await loadBoard()
            if !boardFailed { await loadRelated(force: force) }
            return
        }
        async let boardDone: Void = pollBoard()
        async let relatedDone: Void = loadRelated(force: force)
        _ = await (boardDone, relatedDone)
    }

    // MARK: The board

    /// Try again on a board that would not load. What goes with the project waited for it, so it is put together now.
    func retryBoard() async {
        await loadBoard()
        guard !boardFailed, case .loading = related else { return }
        await loadRelated()
    }

    func loadBoard() async {
        if case .failed = board { board = .loading }
        let client = env.client
        let project = self.project
        do {
            let stream = env.load(Self.boardKey(project)) { () async throws -> TaskBoard in
                let fetch = try await client.send(.taskBoard(project: project))
                guard let board = fetch.board else { throw HVError.decoding("No board in the answer.") }
                return board
            }
            for try await loaded in stream {
                adopt(loaded.value)
                boardIsStale = loaded.isStale && loaded.refreshError != nil
            }
        } catch {
            guard !Task.isCancelled else { return }
            if case .loaded = board { return }
            board = .failed((error as? HVError)?.userMessage ?? error.localizedDescription)
        }
    }

    /// `since_version` answers `unchanged` when nothing moved, so this is cheap enough to run every time the screen returns.
    private func pollBoard() async {
        guard let version = boardVersion else { return await loadBoard() }
        do {
            let fetch = try await env.client.send(.taskBoard(project: project, sinceVersion: version))
            boardIsStale = false
            if !fetch.unchanged, let fresh = fetch.board {
                adopt(fresh)
                await env.cache.store(fresh, key: Self.boardKey(project), namespace: env.user.id)
            }
        } catch {
            // A poll that fails leaves the board as it was.
        }
    }

    private func adopt(_ value: TaskBoard) {
        boardVersion = value.version
        title = value.title
        board = .loaded(ProjectBoardDigest(board: value))
    }

    // MARK: What goes with it

    /// Reads what goes with the project again (Try again, pull to refresh, the screen coming back after a minute).
    func loadRelated(force: Bool = true) async {
        if !force, let relatedLoadedAt, Date().timeIntervalSince(relatedLoadedAt) < Self.freshFor, case .loaded = related { return }
        await seedRelatedFromTheSavedCopy()
        let client = env.client, rest = env.keysRest, userID = env.user.id
        let read = await Self.read(client: client, rest: rest, userID: userID)
        await put(together: read)
    }

    /// The four reads, each of which may fail without the others.
    private struct Sources: Sendable {
        let pages: Result<LibraryGraphPages, Error>
        let links: Result<LibraryConnections, Error>
        let memories: Result<[MemoryItem], Error>
        let chats: Result<[ChatConversation], Error>
    }

    nonisolated private static func read(client: HVClient, rest: AccountRest, userID: String) async -> Sources {
        async let pagesRead = attempt { try await LibraryGraphRow.pages(rest: rest, userID: userID) }
        async let linksRead = attempt { try await client.send(.libraryConnections) }
        async let memoriesRead = attempt { try await client.send(.memoryList()).memories }
        async let chatsRead = attempt { try await client.send(.conversations) }
        return Sources(pages: await pagesRead, links: await linksRead, memories: await memoriesRead, chats: await chatsRead)
    }

    /// The last whole answer first, so the sections do not start empty. It is not marked as a saved copy here: the reads are
    /// already under way, and a banner for the second they take would come and go on every open. `relatedIsStale` is set when
    /// none of them worked (`put(together:)`), which is when the copy is what is being shown.
    private func seedRelatedFromTheSavedCopy() async {
        guard case .loading = related,
              let cached = await env.cache.entry(ProjectRelated.self, key: Self.relatedKey(project), namespace: env.user.id)
        else { return }
        related = .loaded(cached.value)
    }

    private func put(together read: Sources) async {
        guard !Task.isCancelled else { return }
        let cache = env.cache, namespace = env.user.id

        var missing: Set<Source> = []
        var pageList: [LibraryGraphPage] = []
        switch read.pages {
        case .success(let found): pageList = found.pages
        case .failure: missing.insert(.pages)
        }
        var connections = LibraryConnections()
        switch read.links {
        case .success(let found): connections = found
        case .failure: missing.insert(.links)
        }
        var memoryList: [MemoryItem] = []
        switch read.memories {
        case .success(let found): memoryList = found
        case .failure: missing.insert(.memories)
        }
        var chatList: [ChatConversation] = []
        switch read.chats {
        case .success(let found): chatList = found
        case .failure: missing.insert(.chats)
        }

        // Every read failed: the saved copy stays, and says so; with none, that is the error.
        if missing.count == Source.allCases.count {
            unavailable = []
            if case .loaded = related { relatedIsStale = true } else { related = .failed(ProjectsCopy.couldntReadAll) }
            return
        }

        // The id a connection names the board page by. The table read holds it unless the vault is past its newest 300 pages.
        let boardSlug = "taskboard-\(project)"
        var anchors = Set(pageList.filter { $0.slug == boardSlug }.map(\.id))
        if anchors.isEmpty, !missing.contains(.links), let card = try? await env.client.send(.card(slug: boardSlug)) {
            anchors.insert(card.id)
        }
        guard !Task.isCancelled else { return }

        let built = ProjectRelatedBuilder.build(ProjectRelatedInput(
            project: project, title: title, anchors: anchors, connections: connections,
            pages: pageList, memories: memoryList, conversations: chatList
        ))
        unavailable = missing
        relatedIsStale = false
        related = .loaded(built)
        relatedLoadedAt = Date()
        // Only a whole answer is worth keeping: a partial one would paint holes on the next visit.
        if missing.isEmpty { await cache.store(built, key: Self.relatedKey(project), namespace: namespace) }
    }
}

private func attempt<T: Sendable>(_ work: @Sendable () async throws -> T) async -> Result<T, Error> {
    do {
        return .success(try await work())
    } catch {
        return .failure(error)
    }
}
