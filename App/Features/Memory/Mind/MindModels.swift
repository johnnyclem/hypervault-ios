import HyperVaultKit
import SwiftUI

// State for the Git-for-a-mind screens: branches, the commit log, a commit's
// changes, comparing two points, time travel, and merging.

extension MemoryListModel {
    /// Forks the current branch (or `from`) into a new one.
    func createBranch(named name: String, from source: String) async throws -> MindBranchCreated {
        let created = try await client.send(.mindCreateBranch(name: name, from: source))
        await reloadBranches()
        return created
    }

    /// Drops a branch. If it was the one being read, reading moves to main.
    func deleteBranch(_ branch: MindBranch) async throws -> String {
        let result = try await client.send(.mindDeleteBranch(name: branch.name))
        await reloadBranches()
        await env.cache.remove(key: "memory.list.\(branch.name)", namespace: userID)
        if self.branch == branch.name { switchBranch(to: MindBranchName.defaultName) }
        return result.message.isEmpty ? "Branch \"\(branch.name)\" is gone." : result.message
    }
}

/// Brings a memory back to a version it had: the shared step of "bring back" and "restore".
struct MindRestorer {
    let client: HVClient
    let branch: String

    /// The newest version before it was forgotten.
    func bringBack(memoryID: String) async throws -> MindReverted {
        let history = try await client.send(.memoryHistory(id: memoryID, limit: 100))
        guard let revision = history.lastLive else {
            throw HVError.invalidRequest("There is no earlier version of that memory to bring back.")
        }
        return try await client.send(.mindRevert(memoryId: memoryID, revisionId: revision.revisionId, branch: branch))
    }

    /// The version it had at a moment.
    func restore(memoryID: String, asOf moment: Date) async throws -> MindReverted {
        let history = try await client.send(.memoryHistory(id: memoryID, limit: 100))
        guard let revision = history.revision(asOf: moment) else {
            throw HVError.invalidRequest("That memory did not exist at that moment.")
        }
        return try await client.send(.mindRevert(memoryId: memoryID, revisionId: revision.revisionId, branch: branch))
    }
}

// MARK: Commit log

@MainActor
@Observable
final class MindCommitLogModel {
    enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    let branch: String
    private(set) var phase: Phase = .loading
    private(set) var commits: [MindCommit] = []
    private(set) var isStale = false

    @ObservationIgnored private let env: AppEnvironment

    init(branch: String, env: AppEnvironment) {
        self.branch = branch
        self.env = env
    }

    func load() async {
        let client = env.client
        let branch = self.branch
        do {
            let stream = env.load("mind.commits.\(branch)") { try await client.send(.mindCommits(branch: branch, limit: 100)) }
            for try await loaded in stream {
                commits = loaded.value.commits
                isStale = loaded.isStale && loaded.refreshError != nil
                phase = .loaded
            }
        } catch {
            guard !MemoryErrors.isCancelled(error) else { return }
            if commits.isEmpty { phase = .failed(MemoryErrors.message(error)) }
        }
    }

    func refresh() async {
        do {
            let fresh = try await env.client.send(.mindCommits(branch: branch, limit: 100))
            commits = fresh.commits
            isStale = false
            phase = .loaded
            await env.cache.store(fresh, key: "mind.commits.\(branch)", namespace: env.user.id)
        } catch {
            if commits.isEmpty { phase = .failed(MemoryErrors.message(error)) }
        }
    }
}

// MARK: One commit

@MainActor
@Observable
final class MindCommitDetailModel {
    enum Content: Equatable {
        /// What the commit changed, against its first parent.
        case diff(MindStateDiff)
        /// The very first commit has no parent: what it started with.
        case start(MindState)
    }

    enum Phase: Equatable {
        case loading
        case loaded(Content)
        case failed(String)
    }

    let commit: MindCommit
    let branch: String
    private(set) var phase: Phase = .loading
    private(set) var restoringID: String?

    @ObservationIgnored private let env: AppEnvironment

    init(commit: MindCommit, branch: String, env: AppEnvironment) {
        self.commit = commit
        self.branch = branch
        self.env = env
    }

    func load() async {
        do {
            if let parent = commit.parentCommitId {
                let diff = try await env.client.send(.mindDiff(from: .commit(parent), to: .commit(commit.id)))
                phase = .loaded(.diff(diff))
            } else {
                let state = try await env.client.send(.mindState(at: .commit(commit.id)))
                phase = .loaded(.start(state))
            }
        } catch {
            guard !MemoryErrors.isCancelled(error) else { return }
            phase = .failed(MemoryErrors.message(error))
        }
    }

    func bringBack(_ memory: MindDiffMemory) async throws -> String {
        restoringID = memory.id
        defer { restoringID = nil }
        let result = try await MindRestorer(client: env.client, branch: branch).bringBack(memoryID: memory.id)
        NotificationCenter.default.post(name: .hvMemoryChanged, object: nil)
        return result.message.isEmpty ? "\"\(memory.title)\" is back." : result.message
    }
}

// MARK: Comparing

@MainActor
@Observable
final class MindCompareModel {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded(MindStateDiff)
        case failed(String)
    }

    var from: MindRef
    var to: MindRef
    private(set) var phase: Phase = .idle
    private(set) var commits: [MindCommit] = []
    private(set) var restoringID: String?

    @ObservationIgnored private let env: AppEnvironment
    @ObservationIgnored let branch: String

    init(env: AppEnvironment, branch: String, from: MindRef, to: MindRef) {
        self.env = env
        self.branch = branch
        self.from = from
        self.to = to
    }

    func loadCommits() async {
        if let log = try? await env.client.send(.mindCommits(branch: branch, limit: 30)) {
            commits = log.commits
        }
    }

    func compare() async {
        phase = .loading
        do {
            let diff = try await env.client.send(.mindDiff(from: from, to: to, branch: branch))
            phase = .loaded(diff)
        } catch {
            guard !MemoryErrors.isCancelled(error) else { return }
            phase = .failed(MemoryErrors.message(error))
        }
    }

    func swap() {
        let held = from
        from = to
        to = held
        phase = .idle
    }

    func bringBack(_ memory: MindDiffMemory) async throws -> String {
        restoringID = memory.id
        defer { restoringID = nil }
        let result = try await MindRestorer(client: env.client, branch: branch).bringBack(memoryID: memory.id)
        NotificationCenter.default.post(name: .hvMemoryChanged, object: nil)
        return result.message.isEmpty ? "\"\(memory.title)\" is back." : result.message
    }
}

// MARK: Time travel

@MainActor
@Observable
final class MindTimeTravelModel {
    enum Phase: Equatable {
        case loading
        case loaded(MindState)
        case failed(String)
    }

    let branch: String
    private(set) var phase: Phase = .loading
    private(set) var restoringID: String?

    @ObservationIgnored private let env: AppEnvironment

    init(env: AppEnvironment, branch: String) {
        self.env = env
        self.branch = branch
    }

    func load(at moment: Date) async {
        phase = .loading
        do {
            let state = try await env.client.send(.mindState(at: .moment(moment), branch: branch))
            phase = .loaded(state)
        } catch {
            guard !MemoryErrors.isCancelled(error) else { return }
            phase = .failed(MemoryErrors.message(error))
        }
    }

    /// Puts a memory back as it was at the moment shown.
    func restore(_ memory: MindStateMemory, at moment: Date) async throws -> String {
        restoringID = memory.id
        defer { restoringID = nil }
        let result = try await MindRestorer(client: env.client, branch: branch).restore(memoryID: memory.id, asOf: moment)
        NotificationCenter.default.post(name: .hvMemoryChanged, object: nil)
        return result.message.isEmpty ? "\"\(memory.title)\" restored." : result.message
    }
}

// MARK: Merging

@MainActor
@Observable
final class MindMergeModel {
    enum Phase: Equatable {
        /// Reading what the merge would bring.
        case previewing
        /// Ready to merge; `MindStateDiff` is what it would change.
        case ready(MindStateDiff)
        case merging
        /// Both branches changed the same memories.
        case resolving
        case merged(MindMergeResult)
        case failed(String)
    }

    private(set) var phase: Phase = .previewing
    private(set) var session: MindMergeSession
    /// The sentence the server gave with the conflicts, or for a refusal worth keeping on screen.
    private(set) var notice: String?

    @ObservationIgnored private let env: AppEnvironment
    @ObservationIgnored private var preview: MindStateDiff?

    /// `conflicts` starts the merge at the point of choosing (for previews).
    init(source: String, target: String = MindBranchName.defaultName, env: AppEnvironment, conflicts: [MindMergeConflict] = []) {
        self.session = MindMergeSession(source: source, target: target)
        self.env = env
        if !conflicts.isEmpty {
            session.receive(conflicts)
            phase = .resolving
        }
    }

    var source: String { session.source }
    var target: String { session.target }

    func loadPreview() async {
        if case .resolving = phase { return }  // started at the choosing, for a preview
        phase = .previewing
        do {
            let diff = try await env.client.send(.mindDiff(from: .branch(target), to: .branch(source)))
            preview = diff
            phase = .ready(diff)
        } catch {
            guard !MemoryErrors.isCancelled(error) else { return }
            phase = .failed(MemoryErrors.message(error))
        }
    }

    func merge() async {
        phase = .merging
        notice = nil
        do {
            let step = try await MindMerger(client: env.client).attempt(session)
            switch step {
            case .merged(let result):
                phase = .merged(result)
                NotificationCenter.default.post(name: .hvMemoryChanged, object: nil)
            case .conflicts(let message, let conflicts):
                session.receive(conflicts)
                notice = message
                phase = .resolving
            }
        } catch {
            guard !MemoryErrors.isCancelled(error) else { return }
            notice = MemoryErrors.message(error)
            if session.hasConflicts {
                phase = .resolving
            } else if let preview {
                phase = .ready(preview)
            } else {
                phase = .failed(MemoryErrors.message(error))
            }
        }
    }

    func resolve(_ memoryID: String, _ resolution: MindResolution) {
        session.resolve(memoryID, resolution)
    }

    func unresolve(_ memoryID: String) {
        session.unresolve(memoryID)
    }

    func resolveRemaining(_ side: MindSide) {
        session.resolveRemaining(side)
    }

    func setMessage(_ message: String) {
        session.message = message
    }
}
