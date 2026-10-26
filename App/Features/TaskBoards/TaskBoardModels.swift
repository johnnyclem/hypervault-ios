import HyperVaultKit
import SwiftUI

// MARK: The list of boards

/// The boards in the vault, each with a quiet progress line fetched when its
/// row appears. Creating a board returns the one just made.
@MainActor
@Observable
final class TaskBoardsModel {
    enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var boards: [TaskBoardListing] = []
    private(set) var summaries: [String: TaskBoardSummary] = [:]
    private(set) var isShowingSavedCopy = false
    private(set) var isCreating = false

    @ObservationIgnored private let client: HVClient
    @ObservationIgnored private let cache: DiskCache
    @ObservationIgnored private let namespace: String
    @ObservationIgnored private var requested = Set<String>()
    @ObservationIgnored private var started = false

    init(client: HVClient, cache: DiskCache, namespace: String) {
        self.client = client
        self.cache = cache
        self.namespace = namespace
    }

    func start() async {
        guard !started else { return }
        started = true
        await load()
    }

    func load() async {
        let client = self.client
        do {
            let stream = cachedLoad(cache: cache, namespace: namespace, key: "taskboards.index") { () async throws -> TaskBoardIndex in
                try await client.send(.taskBoards)
            }
            for try await loaded in stream {
                boards = loaded.value.boards
                isShowingSavedCopy = loaded.isStale
                phase = .loaded
            }
        } catch {
            if phase != .loaded { phase = .failed((error as? HVError)?.userMessage ?? error.localizedDescription) }
        }
    }

    /// Reads one board's rollup the first time its row is shown (and again when asked).
    func loadSummary(for board: TaskBoardListing, force: Bool = false) async {
        guard force || requested.insert(board.project).inserted else { return }
        if let response = try? await client.send(.taskBoardSummary(project: board.project)) {
            summaries[board.project] = response.summary
        }
    }

    func refresh() async {
        requested.removeAll()
        await load()
    }

    func create(_ draft: TaskBoardDraft) async throws -> TaskBoardListing {
        isCreating = true
        defer { isCreating = false }
        let created = try await client.send(.createTaskBoard(draft))
        let listing = TaskBoardListing(slug: created.data.slug, project: created.project, title: draft.trimmedTitle, url: created.data.url, createdAt: Date())
        boards.insert(listing, at: 0)
        phase = .loaded
        return listing
    }
}

// MARK: One board

/// A change that could not be put on top of what someone else did meanwhile.
struct TaskBoardClash: Identifiable {
    let id = UUID()
    let edit: TaskBoardEdit
    let reason: String
}

/// One board. What the screen shows is the last list the server confirmed with
/// the person's unsent changes laid on top, so a tick lands at once and a
/// refused change simply stops being laid on. Changes go one at a time, each
/// pinned to the revision it was made against; when the list moved on, a change
/// that does not touch what moved is sent again on top of it, and one that does
/// is put to the person.
@MainActor
@Observable
final class TaskBoardModel {
    enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var confirmed: TaskBoard?
    private(set) var pending: [TaskBoardEdit] = []
    private(set) var isShowingSavedCopy = false
    private(set) var clash: TaskBoardClash?
    var filter: TaskBoardFilter = .all

    let project: String
    let title: String

    /// Set by the screen: a change the server refused outright, in its own words.
    @ObservationIgnored var onFailure: (String) -> Void = { _ in }

    @ObservationIgnored private let client: HVClient
    @ObservationIgnored private let cache: DiskCache
    @ObservationIgnored private let namespace: String
    @ObservationIgnored private var isSending = false
    @ObservationIgnored private var started = false
    @ObservationIgnored private var tempCounter = 0

    init(client: HVClient, cache: DiskCache, namespace: String, project: String, title: String) {
        self.client = client
        self.cache = cache
        self.namespace = namespace
        self.project = project
        self.title = title
    }

    /// The list as the person sees it.
    var board: TaskBoard? {
        guard let confirmed else { return nil }
        return pending.reduce(confirmed) { $1.applying(to: $0) }
    }

    var groups: [TaskBoardGroup] { board?.groups(filter: filter) ?? [] }

    var summary: TaskBoardSummary? { board.map(TaskBoardSummary.compute) }

    static func isTemporary(_ id: String) -> Bool { id.hasPrefix("tmp-") }

    private var cacheKey: String { "taskboards.board.\(project)" }

    // MARK: Loading

    func start() async {
        guard !started else { return }
        started = true
        await load()
    }

    func load() async {
        let client = self.client
        let project = self.project
        do {
            let stream = cachedLoad(cache: cache, namespace: namespace, key: cacheKey) { () async throws -> TaskBoard in
                let fetch = try await client.send(.taskBoard(project: project))
                guard let board = fetch.board else { throw HVError.decoding("No board in the answer.") }
                return board
            }
            for try await loaded in stream {
                confirmed = loaded.value
                isShowingSavedCopy = loaded.isStale
                phase = .loaded
            }
        } catch {
            if phase != .loaded { phase = .failed((error as? HVError)?.userMessage ?? error.localizedDescription) }
        }
    }

    /// The cheap poll: nothing comes back unless the revision moved.
    func refresh() async {
        guard let confirmed else { return await load() }
        do {
            let fetch = try await client.send(.taskBoard(project: project, sinceVersion: confirmed.version))
            isShowingSavedCopy = false
            if !fetch.unchanged, let fresh = fetch.board { adopt(fresh) }
        } catch {
            // A poll that fails leaves the list as it was; pull to refresh says why.
        }
    }

    func refreshAndReport() async {
        guard let confirmed else { return await load() }
        do {
            let fetch = try await client.send(.taskBoard(project: project, sinceVersion: confirmed.version))
            isShowingSavedCopy = false
            if !fetch.unchanged, let fresh = fetch.board { adopt(fresh) }
        } catch {
            onFailure((error as? HVError)?.userMessage ?? error.localizedDescription)
        }
    }

    private func adopt(_ board: TaskBoard) {
        confirmed = board
        phase = .loaded
        let cache = self.cache
        let namespace = self.namespace
        let key = cacheKey
        Task { await cache.store(board, key: key, namespace: namespace) }
    }

    // MARK: Changing

    func newTempID() -> String {
        tempCounter += 1
        return "tmp-\(tempCounter)"
    }

    func add(title: String, parent: String? = nil) {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        enqueue(.add(title: text, parent: parent, tempID: newTempID()))
    }

    func enqueue(_ edit: TaskBoardEdit) {
        guard confirmed != nil else { return }
        pending.append(edit)
        pump()
    }

    private func pump() {
        guard !isSending else { return }
        isSending = true
        Task {
            await drain()
            isSending = false
        }
    }

    private func drain() async {
        while let edit = pending.first, let base = confirmed {
            await send(edit, base: base, attempt: 0)
            if !pending.isEmpty { pending.removeFirst() }
        }
    }

    /// Sends one change pinned to `base`'s revision. On a 409 the latest list
    /// is adopted and the change is sent again if it still makes sense.
    private func send(_ edit: TaskBoardEdit, base: TaskBoard, attempt: Int) async {
        do {
            let result = try await client.send(edit.endpoint(project: project, expectedVersion: base.version))
            if let fresh = result.board {
                adopt(fresh)
            } else {
                // Completing answers a summary and no list: read it again.
                let fetch = try await client.send(.taskBoard(project: project))
                if let fresh = fetch.board { adopt(fresh) }
            }
        } catch {
            guard let latest = TaskBoardConflict.latest(in: error) else {
                onFailure((error as? HVError)?.boardSentence ?? error.localizedDescription)
                return
            }
            switch edit.mergeDecision(base: base, latest: latest) {
            case .reapply where attempt < 3:
                adopt(latest)
                await send(edit, base: latest, attempt: attempt + 1)
            case .reapply:
                adopt(latest)
                onFailure("The board keeps changing. Pull to refresh and try again.")
            case .alreadyDone:
                adopt(latest)
            case .conflict(let reason):
                adopt(latest)
                clash = TaskBoardClash(edit: edit, reason: reason)
            }
        }
    }

    /// The person chose: send their change anyway, on top of the latest, or let it go.
    func resolveClash(keepMine: Bool) {
        guard let current = clash else { return }
        clash = nil
        guard keepMine else { return }
        var edit = current.edit
        if case .claim(let id, _) = edit { edit = .claim(taskID: id, force: true) }
        pending.append(edit)
        pump()
    }
}
