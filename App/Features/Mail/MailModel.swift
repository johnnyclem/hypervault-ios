import HyperVaultKit
import SwiftUI

/// The person's mail: which mailbox, which list, and what can be done to a
/// thread from the list. It loads the saved copy first and the fresh one
/// after; every change is shown at once and rolled back if the server says no.
@MainActor
@Observable
final class MailModel {
    enum Load: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    private(set) var mailboxState: Load = .loading
    private(set) var mailboxes: [OwnerMailbox] = []
    private(set) var activeID: String?
    private(set) var isShowingSavedCopy = false

    private(set) var filter: MailFilter = .inbox
    private(set) var listState: Load = .idle
    private(set) var messages: [MailMessage] = []
    private(set) var nextCursor: String?
    private(set) var isLoadingMore = false

    private(set) var searchState: Load = .idle
    private(set) var hits: [MailMessage] = []

    @ObservationIgnored private let client: HVClient
    @ObservationIgnored private let cache: DiskCache
    @ObservationIgnored private let namespace: String
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var started = false

    init(client: HVClient, cache: DiskCache, namespace: String) {
        self.client = client
        self.cache = cache
        self.namespace = namespace
    }

    // MARK: What is showing

    var active: OwnerMailbox? { OwnerMailbox.choose(from: mailboxes, preferring: activeID) }

    /// The mailbox id the routes are asked about; nil lets the server pick the account's default.
    var mailboxParam: String? { active?.id }

    var threads: [MailThread] { MailThreads.group(messages) }

    var agentsSeeOwnerMail: Bool { active?.agentsSeeOwnerMail ?? true }

    var heldCount: Int { active?.heldCount ?? 0 }

    var totalUnread: Int { mailboxes.reduce(0) { $0 + $1.unreadCount } }

    private var service: MailService { MailService(client: client) }

    static func sentence(_ error: Error) -> String {
        (error as? HVError)?.mailSentence ?? error.localizedDescription
    }

    // MARK: Loading

    func start() async {
        guard !started else { return }
        started = true
        await loadMailboxes(quiet: false)
        await loadList(quiet: false)
    }

    func refresh() async {
        await loadMailboxes(quiet: true)
        await loadList(quiet: true)
    }

    /// The screen came back (from a thread, say): counts and rows may have moved.
    func refreshIfStarted() async {
        guard started else { return }
        await refresh()
    }

    private func loadMailboxes(quiet: Bool) async {
        let client = self.client
        do {
            let stream = cachedLoad(cache: cache, namespace: namespace, key: "mail.mailboxes") { () async throws -> OwnerMailboxList in
                try await client.send(.mailMailboxes)
            }
            for try await loaded in stream {
                mailboxes = loaded.value.mailboxes
                isShowingSavedCopy = loaded.isStale
                mailboxState = .loaded
            }
        } catch {
            if !quiet || mailboxState != .loaded { mailboxState = .failed(Self.sentence(error)) }
        }
    }

    private func loadList(quiet: Bool) async {
        if case .failed = mailboxState, mailboxes.isEmpty { return }
        generation += 1
        let mine = generation
        if !quiet || messages.isEmpty { listState = .loading }
        let client = self.client
        let box = filter.box
        let unreadOnly = filter.unreadOnly
        let mailbox = mailboxParam
        let key = "mail.list.\(mailbox ?? "default").\(filter.rawValue)"
        do {
            let stream = cachedLoad(cache: cache, namespace: namespace, key: key) { () async throws -> MailMessagePage in
                try await client.send(.mailMessages(box: box, unreadOnly: unreadOnly, mailbox: mailbox))
            }
            for try await loaded in stream {
                guard mine == generation else { return }
                messages = loaded.value.messages
                nextCursor = loaded.value.nextCursor
                listState = .loaded
                if loaded.isStale { isShowingSavedCopy = true }
            }
        } catch {
            guard mine == generation else { return }
            if listState != .loaded || !quiet { listState = .failed(Self.sentence(error)) }
        }
    }

    private func resetList() {
        generation += 1
        messages = []
        nextCursor = nil
        listState = .loading
    }

    func select(mailbox id: String) async {
        guard id != active?.id else { return }
        activeID = id
        resetList()
        await loadList(quiet: false)
    }

    func select(filter newFilter: MailFilter) async {
        guard newFilter != filter else { return }
        filter = newFilter
        resetList()
        await loadList(quiet: false)
    }

    func loadMore() async throws {
        guard let cursor = nextCursor, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let mine = generation
        let page = try await client.send(.mailMessages(
            box: filter.box, unreadOnly: filter.unreadOnly, mailbox: mailboxParam, cursor: cursor
        ))
        guard mine == generation else { return }
        messages = MailThreads.appendUnique(messages, page.messages)
        nextCursor = page.nextCursor
    }

    // MARK: Search

    /// Searches after a short pause. Call it from `.task(id:)`, so typing cancels the last one.
    func search(_ text: String) async {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            hits = []
            searchState = .idle
            return
        }
        searchState = .loading
        try? await Task.sleep(nanoseconds: 350_000_000)
        guard !Task.isCancelled else { return }
        do {
            let result = try await client.send(.mailSearch(query: query, mailbox: mailboxParam))
            guard !Task.isCancelled else { return }
            hits = result.messages
            searchState = .loaded
        } catch {
            guard !Task.isCancelled else { return }
            searchState = .failed(Self.sentence(error))
        }
    }

    // MARK: Changing a thread

    /// Moves a whole thread to another folder, taking it off the list at once.
    /// A failure puts it back and throws the server's sentence.
    func move(_ thread: MailThread, to folder: MailFolder) async throws -> MailMoveResult {
        let before = messages
        messages.removeAll { $0.threadId == thread.id }
        do {
            let result = try await service.moveThread(id: thread.id, mailbox: mailboxParam, loaded: nil, olderCursor: nil, to: folder)
            if case .tooMany = result { messages = before }
            await loadMailboxes(quiet: true)
            return result
        } catch {
            messages = before
            throw error
        }
    }

    func markRead(_ thread: MailThread) async {
        let ids = thread.messages.filter(\.unread).map(\.id)
        guard !ids.isEmpty else { return }
        setUnread(false, for: Set(ids))
        let cleared = await service.markRead(ids, mailbox: mailboxParam)
        let failed = Set(ids).subtracting(cleared)
        if !failed.isEmpty { setUnread(true, for: failed) }
        await loadMailboxes(quiet: true)
    }

    func markUnread(_ thread: MailThread) async throws {
        let id = thread.newest.id
        setUnread(true, for: [id])
        do {
            _ = try await client.send(.mailUpdate(id: id, unread: true, mailbox: mailboxParam))
            await loadMailboxes(quiet: true)
        } catch {
            setUnread(false, for: [id])
            throw error
        }
    }

    private func setUnread(_ value: Bool, for ids: Set<String>) {
        messages = messages.map { ids.contains($0.id) ? $0.withUnread(value) : $0 }
    }

    // MARK: Writing and settings

    /// Sends a note from the person to their agents, then shows Sent.
    func send(subject: String, text: String) async throws {
        _ = try await client.send(.mailSend(subject: subject, text: text, mailbox: mailboxParam))
        filter = .sent
        resetList()
        await loadList(quiet: false)
        await loadMailboxes(quiet: true)
    }

    func emptyTrash() async throws -> Int {
        let result = try await client.send(.mailEmptyTrash(mailbox: mailboxParam))
        messages = []
        nextCursor = nil
        await loadMailboxes(quiet: true)
        return result.deleted
    }

    func setAgentsSeeReplies(_ on: Bool) async throws {
        guard let active else { return }
        let before = mailboxes
        mailboxes = mailboxes.map { $0.id == active.id ? $0.withAgentsSeeOwnerMail(on) : $0 }
        do {
            let updated = try await client.send(.mailAgentsSeeReplies(on, mailbox: active.id))
            mailboxes = mailboxes.map { $0.id == updated.mailbox.id ? updated.mailbox : $0 }
        } catch {
            mailboxes = before
            throw error
        }
    }

    /// The whole mailbox as a JSON file in the temporary folder, ready for the share sheet.
    func export() async throws -> URL {
        let data = try await client.send(.mailExport(mailbox: mailboxParam))
        return try MailShareFile.write(data, named: MailText.exportFilename(address: active?.address))
    }

    /// Counts moved under the list (something was released, say).
    func refreshCounts() async {
        await loadMailboxes(quiet: true)
    }
}

/// Files made for the share sheet live in the temporary folder, under their own names.
enum MailShareFile {
    static func write(_ data: Data, named name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hv-share-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
    }
}
