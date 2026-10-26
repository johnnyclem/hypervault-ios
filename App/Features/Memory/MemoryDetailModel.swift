import HyperVaultKit
import SwiftUI

/// One memory: its page (cached, then fresh) and what can be done to it.
@MainActor
@Observable
final class MemoryDetailModel {
    enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
        /// The server has no such memory on this branch ("No such memory in your wiki.").
        case gone(String)
    }

    let id: String
    private(set) var branch: String
    private(set) var phase: Phase = .loading
    private(set) var page: MemoryPage?
    private(set) var blocks: [MarkdownBlock] = []
    private(set) var isStale = false
    private(set) var isWorking = false

    @ObservationIgnored let env: AppEnvironment

    init(id: String, env: AppEnvironment) {
        self.id = id
        self.env = env
        self.branch = MemoryBranchStore.current(for: env.user.id)
    }

    var client: HVClient { env.client }

    func load() async {
        let client = env.client
        let id = self.id
        let branch = self.branch
        do {
            let stream = env.load("memory.page.\(branch).\(id)") { try await client.send(.memoryPage(id: id, branch: branch)) }
            for try await loaded in stream {
                apply(loaded.value)
                isStale = loaded.isStale && loaded.refreshError != nil
            }
        } catch {
            guard !MemoryErrors.isCancelled(error) else { return }
            if let hv = error as? HVError, hv.status == 404 {
                if hv.userMessage.contains("branch"), branch != MindBranchName.defaultName {
                    // The branch is gone; read it on main.
                    self.branch = MindBranchName.defaultName
                    await load()
                    return
                }
                if page == nil { phase = .gone(hv.userMessage) }
                return
            }
            if page == nil { phase = .failed(MemoryErrors.message(error)) }
        }
    }

    private func apply(_ page: MemoryPage) {
        if self.page?.memory.content != page.memory.content || blocks.isEmpty {
            blocks = MarkdownBlocks.parse(page.memory.content)
        }
        self.page = page
        phase = .loaded
    }

    /// Reads it again from the server, keeping what is shown until the answer comes.
    func reload() async {
        do {
            let fresh = try await env.client.send(.memoryPage(id: id, branch: branch))
            apply(fresh)
            isStale = false
            await env.cache.store(fresh, key: "memory.page.\(branch).\(id)", namespace: env.user.id)
        } catch let error as HVError where error.status == 404 {
            page = nil
            phase = .gone(error.userMessage)
        } catch {
            // What is on screen is still right as of its last load.
        }
    }

    /// Saves an edit. Returns the server's sentence on success; throws what the server said otherwise.
    func save(_ request: MemoryEditRequest) async throws -> String {
        isWorking = true
        defer { isWorking = false }
        var request = request
        request.branch = branch
        let edited = try await env.client.send(.memoryEdit(id: id, request))
        await reload()
        NotificationCenter.default.post(name: .hvMemoryChanged, object: nil)
        return edited.message.isEmpty ? "Edited." : edited.message
    }

    func forget() async throws -> String {
        isWorking = true
        defer { isWorking = false }
        let result = try await env.client.send(.memoryForget(id: id, branch: branch))
        await env.cache.remove(key: "memory.page.\(branch).\(id)", namespace: env.user.id)
        NotificationCenter.default.post(name: .hvMemoryChanged, object: nil)
        return result.message.isEmpty ? "Forgotten." : result.message
    }

    func digest() async throws -> DigestProposal {
        isWorking = true
        defer { isWorking = false }
        return try await env.client.send(.digestMemory(id: id, branch: branch))
    }
}

/// A memory's revisions: what it said before, and how to go back.
@MainActor
@Observable
final class MemoryHistoryModel {
    enum DiffState: Equatable {
        case loading
        case loaded(MindMemoryDiff)
        case failed(String)
    }

    let memoryID: String
    let branch: String
    private(set) var phase: MemoryDetailModel.Phase = .loading
    private(set) var history: MemoryHistory?
    private(set) var diffs: [String: DiffState] = [:]
    private(set) var restoringID: String?

    @ObservationIgnored private let env: AppEnvironment

    init(memoryID: String, branch: String, env: AppEnvironment) {
        self.memoryID = memoryID
        self.branch = branch
        self.env = env
    }

    /// The memory is forgotten as of the newest revision.
    var isForgotten: Bool { history?.revisions.first?.op == .delete }

    func load() async {
        let client = env.client
        let id = memoryID
        do {
            for try await loaded in env.load("memory.history.\(id)", fetch: { try await client.send(.memoryHistory(id: id, limit: 100)) }) {
                history = loaded.value
                phase = .loaded
            }
        } catch {
            guard !MemoryErrors.isCancelled(error) else { return }
            phase = (error as? HVError)?.status == 404 ? .gone(MemoryErrors.message(error)) : .failed(MemoryErrors.message(error))
        }
    }

    func reload() async {
        if let fresh = try? await env.client.send(.memoryHistory(id: memoryID, limit: 100)) {
            history = fresh
            phase = .loaded
            await env.cache.store(fresh, key: "memory.history.\(memoryID)", namespace: env.user.id)
        }
    }

    /// The changes a revision made, against the one before it.
    func loadDiff(for revision: MemoryRevision) async {
        guard let history, let older = history.previous(of: revision),
              let from = older.commit?.id, let to = revision.commit?.id
        else { return }
        if case .loaded = diffs[revision.revisionId] { return }
        diffs[revision.revisionId] = .loading
        do {
            let diff = try await env.client.send(.mindMemoryDiff(from: .commit(from), to: .commit(to), memoryId: memoryID))
            diffs[revision.revisionId] = .loaded(diff)
        } catch {
            diffs[revision.revisionId] = .failed(MemoryErrors.message(error))
        }
    }

    /// Restores a revision as a new commit (or brings back a forgotten memory).
    func restore(_ revision: MemoryRevision) async throws -> String {
        restoringID = revision.revisionId
        defer { restoringID = nil }
        let result = try await env.client.send(.mindRevert(memoryId: memoryID, revisionId: revision.revisionId, branch: branch))
        await reload()
        await env.cache.remove(key: "memory.page.\(branch).\(memoryID)", namespace: env.user.id)
        NotificationCenter.default.post(name: .hvMemoryChanged, object: nil)
        return result.message.isEmpty ? "Restored." : result.message
    }
}
