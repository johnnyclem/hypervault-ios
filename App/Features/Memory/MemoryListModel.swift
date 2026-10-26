import HyperVaultKit
import SwiftUI

/// The Memory tab's state: the branch being read, its memories (cached, then
/// fresh), and recall as someone types. One instance serves the list, the
/// search, the graph and the Ask mode.
@MainActor
@Observable
final class MemoryListModel {
    enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var items: [MemoryItem] = []
    private(set) var isStale = false
    private(set) var branch: String
    private(set) var branches: [MindBranch] = []
    private(set) var query = ""
    private(set) var recall: MemoryRecall?
    private(set) var isRecalling = false
    private(set) var recallFailure: String?

    @ObservationIgnored let env: AppEnvironment
    @ObservationIgnored private var recallTask: Task<Void, Never>?

    init(env: AppEnvironment) {
        self.env = env
        self.branch = MemoryBranchStore.current(for: env.user.id)
    }

    var userID: String { env.user.id }
    var client: HVClient { env.client }
    var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isSearching: Bool { !trimmedQuery.isEmpty }

    /// Server recall, once it has answered for what is typed now.
    var currentRecall: MemoryRecall? {
        guard let recall, recall.query == trimmedQuery else { return nil }
        return recall
    }

    /// While recall is on its way: the same words matched on the device.
    var localMatches: [MemoryItem] {
        MemoryRecallScorer.rank(trimmedQuery, in: items)
    }

    // MARK: Loading

    func load() async {
        let client = env.client
        let branch = self.branch
        do {
            let stream = env.load("memory.list.\(branch)") { try await client.send(.memoryList(branch: branch)) }
            for try await loaded in stream {
                guard branch == self.branch else { return }
                items = loaded.value.memories
                isStale = loaded.isStale && loaded.refreshError != nil
                phase = .loaded
            }
        } catch {
            guard branch == self.branch, !MemoryErrors.isCancelled(error) else { return }
            if branch != MindBranchName.defaultName, (error as? HVError)?.status == 404 {
                // The branch was deleted somewhere else.
                switchBranch(to: MindBranchName.defaultName)
                await load()
                return
            }
            if items.isEmpty { phase = .failed(MemoryErrors.message(error)) }
        }
    }

    /// Pull to refresh: keeps what is on screen, and says so if it could not refresh.
    func refresh(app: AppModel?) async {
        let client = env.client
        let branch = self.branch
        do {
            let fresh = try await client.send(.memoryList(branch: branch))
            guard branch == self.branch else { return }
            items = fresh.memories
            isStale = false
            phase = .loaded
            await env.cache.store(fresh, key: "memory.list.\(branch)", namespace: env.user.id)
        } catch {
            guard !MemoryErrors.isCancelled(error) else { return }
            if items.isEmpty { phase = .failed(MemoryErrors.message(error)) } else { app?.toasts.show(error: error) }
        }
    }

    func loadBranches() async {
        let client = env.client
        do {
            for try await loaded in env.load("mind.branches", fetch: { try await client.send(.mindBranches) }) {
                branches = loaded.value.ordered
            }
        } catch {
            // The switcher falls back to the branch it knows about.
        }
    }

    func reloadBranches() async {
        if let fresh = try? await env.client.send(.mindBranches) {
            branches = fresh.ordered
            await env.cache.store(fresh, key: "mind.branches", namespace: env.user.id)
        }
    }

    // MARK: Branch

    func switchBranch(to name: String) {
        guard name != branch else { return }
        branch = name
        MemoryBranchStore.set(name, for: env.user.id)
        items = []
        phase = .loading
        isStale = false
        recall = nil
        recallTask?.cancel()
        if isSearching { queryChanged(query) }
    }

    // MARK: Search

    func queryChanged(_ text: String) {
        query = text
        recallTask?.cancel()
        let trimmed = trimmedQuery
        guard trimmed.count >= 2 else {
            recall = nil
            isRecalling = false
            recallFailure = nil
            return
        }
        isRecalling = true
        recallFailure = nil
        let client = env.client
        let branch = self.branch
        recallTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            do {
                let result = try await client.send(.memoryRecall(trimmed, branch: branch))
                guard !Task.isCancelled, let self else { return }
                self.recall = result
                self.isRecalling = false
            } catch {
                guard !Task.isCancelled, !MemoryErrors.isCancelled(error), let self else { return }
                self.isRecalling = false
                self.recallFailure = MemoryErrors.message(error)
            }
        }
    }

    // MARK: Changes made elsewhere on the screen

    func didKeep(_ kept: MemoryKept) {
        guard !kept.id.isEmpty, !items.contains(where: { $0.id == kept.id }) else { return }
        items.insert(kept.item(), at: 0)
        phase = .loaded
        NotificationCenter.default.post(name: .hvMemoryChanged, object: nil)
    }

    func didForget(_ id: String) {
        items.removeAll { $0.id == id }
    }
}
