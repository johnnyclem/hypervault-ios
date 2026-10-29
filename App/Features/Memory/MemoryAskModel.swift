import HyperVaultKit
import SwiftUI

/// Ask mode. The web's Ask is a chat with wiki recall on: the question goes to
/// `POST /api/chat` with the person's own connected model, and the answer is
/// grounded in the memories recalled for it. Here the recall is also shown, as
/// the sources, and when no model is connected the sources are the answer.
@MainActor
@Observable
final class MemoryAskModel {
    struct Turn: Identifiable, Equatable {
        enum Phase: Equatable {
            case recalling
            case answering
            case done
        }

        let id = UUID()
        let question: String
        var phase: Phase = .recalling
        var hits: [MemoryRecallHit] = []
        var recallMode: MemoryRecallMode = .lexical
        var recallMessage = ""
        var answer: MemoryAnswer?
        var failure: String?
        /// The person's thumb on the answer, and what Keep made of it.
        var feedback: ChatFeedback?
        var kept: ChatKeptNote?

        static func == (lhs: Turn, rhs: Turn) -> Bool {
            lhs.id == rhs.id && lhs.phase == rhs.phase && lhs.hits == rhs.hits && lhs.answer == rhs.answer
                && lhs.failure == rhs.failure && lhs.feedback == rhs.feedback && lhs.kept == rhs.kept
        }
    }

    private(set) var turns: [Turn] = []
    private(set) var backends: [MemoryAskBackend] = []
    private(set) var backendsLoaded = false
    private(set) var conversationID: String?
    /// Whether the person has compiled tools, which the model may use to answer.
    private(set) var hasToolkit = false
    /// Tools can be used only by a model that answers: with none connected there is only recall to show.
    var offersTools: Bool { hasToolkit && selectedBackend != nil }
    var selectedBackendID: String?
    /// Tools are on for an Ask, as they are for a chat, until the person switches them off.
    var useTools = true

    @ObservationIgnored private let env: AppEnvironment

    init(env: AppEnvironment) {
        self.env = env
    }

    var isBusy: Bool { turns.last.map { $0.phase != .done } ?? false }

    var selectedBackend: MemoryAskBackend? {
        backends.first { $0.id == selectedBackendID } ?? backends.first
    }

    func loadBackends() async {
        guard !backendsLoaded else { return }
        let client = env.client
        async let fetchedToolkit = try? await client.send(.toolkitStatus)
        do {
            backends = try await client.send(.memoryAskBackends)
            if selectedBackendID == nil { selectedBackendID = backends.first?.id }
        } catch {
            // Without a list of models there is still recall to show.
            backends = []
        }
        // A server that predates tools reads as none, and the switch is not offered.
        if let value = await fetchedToolkit { hasToolkit = value.hasToolkit }
        backendsLoaded = true
    }

    func ask(_ question: String, branch: String) async {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isBusy else { return }
        let turn = Turn(question: text)
        let id = turn.id
        turns.append(turn)
        let client = env.client

        // What memory holds on it comes first, and shows at once.
        do {
            let recall = try await client.send(.memoryRecall(text, branch: branch))
            update(id) {
                $0.hits = recall.results
                $0.recallMode = recall.recallMode
                $0.recallMessage = recall.message
            }
        } catch {
            if MemoryErrors.isCancelled(error) {
                turns.removeAll { $0.id == id }
                return
            }
            update(id) {
                $0.failure = MemoryErrors.message(error)
                $0.phase = .done
            }
            return
        }

        guard let backend = selectedBackend else {
            update(id) { $0.phase = .done }
            return
        }
        update(id) { $0.phase = .answering }
        do {
            // The answer is written from the branch the sources came from.
            let answer = try await client.send(.memoryAsk(
                backendId: backend.id, message: text, conversationId: conversationID, recallBranch: branch, useTools: hasToolkit ? useTools : nil
            ))
            if !answer.conversationId.isEmpty { conversationID = answer.conversationId }
            update(id) { $0.answer = answer }
        } catch {
            if !MemoryErrors.isCancelled(error) {
                let message = MemoryErrors.message(error)
                update(id) { $0.failure = message }
            }
        }
        update(id) { $0.phase = .done }
    }

    // MARK: Acting on an answer

    /// Thumbs up or down; the same one again clears it. Rolls back if the server says no.
    func rate(_ id: Turn.ID, _ rating: ChatFeedback) async throws {
        guard let turn = turns.first(where: { $0.id == id }), let serverID = turn.answer?.messageId else { return }
        let previous = turn.feedback
        let next: ChatFeedback? = previous == rating ? nil : rating
        update(id) { $0.feedback = next }
        do {
            _ = try await env.client.send(.rate(messageID: serverID, next))
        } catch {
            update(id) { $0.feedback = previous }
            guard let error = error as? HVError else { throw error }
            throw ChatActionError(message: error.sentence(offline: "Network hiccup. Your rating was not saved."))
        }
    }

    /// Keeps an answer in Yours, with the question that brought it, as Keep on a chat reply does.
    func keep(_ id: Turn.ID) async throws {
        guard let turn = turns.first(where: { $0.id == id }), let answer = turn.answer else { return }
        guard let content = KeepReply.content(of: answer.text) else { throw ChatActionError(message: HVCopy.nothingToKeepLine) }
        let question = turn.question.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = question.isEmpty || question.count > env.limits.sourcePromptChars ? nil : question
        do {
            let kept = try await env.client.send(.keep(content: content, title: nil, sourcePrompt: source))
            let note = ChatKeptNote(slug: kept.slug, url: URL(string: kept.url), duplicate: kept.duplicate, isPrivate: kept.isPrivate)
            update(id) { $0.kept = note }
        } catch let error as HVError {
            throw ChatActionError(message: error.sentence(offline: HVCopy.keepOfflineLine))
        }
    }

    private func update(_ id: UUID, _ change: (inout Turn) -> Void) {
        guard let index = turns.firstIndex(where: { $0.id == id }) else { return }
        change(&turns[index])
    }

    func clear() {
        turns = []
        conversationID = nil
    }
}

/// The map of memories: what `/api/connections` adds to the list. That route has main's memory links and no others,
/// so on any other branch the links are read from the branch's own state (`/api/mind/state`). The pages the memories
/// are bridged to are not kept per branch and always come from `/api/connections`.
@MainActor
@Observable
final class MemoryGraphModel {
    enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    /// Where the links between memories on the map come from.
    enum LinkSource: Equatable {
        /// Main's, from `/api/connections`.
        case main
        /// The branch's own, which are on their way.
        case reading
        /// The branch's own, read from its state.
        case branch
        /// The branch's state could not be read, so main's stand in for them.
        case mainInstead
    }

    /// The sentences under the map when the branch's own links could not be read.
    static let mainInsteadNote = "this branch's links could not be read, so these are main's"
    static let unreadNote = "this branch's links could not be read"

    private(set) var phase: Phase = .loading
    private(set) var connections = MemoryConnections()
    private(set) var artifacts: [MemoryGraphArtifact] = []
    private(set) var isStale = false
    private(set) var linkSource = LinkSource.main
    private(set) var branchLinks: [MemoryLinkRow] = []
    /// What the person has typed to find a memory by name.
    var query = ""
    /// Kinds of node left off the map, by the names in `MemoryGraph.types`.
    private(set) var hiddenTypes: Set<String> = []
    /// Memories and pages with no links are left off the map.
    private(set) var hideUnlinked = false

    /// The most memories the search lists at once, as the Library's graph lists.
    static let matchLimit = 6

    @ObservationIgnored private let env: AppEnvironment
    @ObservationIgnored private var branch = MindBranchName.defaultName

    init(env: AppEnvironment) {
        self.env = env
    }

    /// The branch's own links are on their way, and until they are here the map would show the wrong ones.
    var isReadingLinks: Bool { linkSource == .reading }

    /// What the caption says about the links when they are not the branch's own; nil when they are.
    var linkNote: String? {
        guard linkSource == .mainInstead else { return nil }
        return phase == .loaded ? Self.mainInsteadNote : Self.unreadNote
    }

    func load(branch: String) async {
        self.branch = branch
        let onMain = branch == MindBranchName.defaultName
        linkSource = onMain ? .main : .reading
        branchLinks = []
        let client = env.client
        // Another branch's links are read at its head while main's connections load, which still carry the pages.
        async let own = Self.ownLinks(of: branch, client: client)
        var connectionsFailed = false
        do {
            for try await loaded in env.load("memory.connections", fetch: { try await client.send(.memoryConnections) }) {
                guard branch == self.branch else { return }
                connections = loaded.value
                isStale = loaded.isStale && loaded.refreshError != nil
                phase = .loaded
            }
        } catch {
            guard !MemoryErrors.isCancelled(error), branch == self.branch else { return }
            phase = .failed(MemoryErrors.message(error))
            connectionsFailed = true
        }
        if !onMain {
            let read = await own
            guard branch == self.branch, !Task.isCancelled else { return }
            if let read {
                branchLinks = read
                linkSource = .branch
            } else {
                linkSource = .mainInstead
            }
        }
        guard !connectionsFailed else { return }
        // Names for the pages the memories are bridged to. Nice to have: the map works without them.
        if let list = try? await client.send(.yours(filter: .file, limit: 50)) {
            guard branch == self.branch else { return }
            artifacts = list.results.map { MemoryGraphArtifact(id: $0.id, title: $0.name, slug: $0.slug) }
        }
    }

    /// The links of `branch`, read from its state; nil for main (`/api/connections` is its own) and when the read fails.
    private nonisolated static func ownLinks(of branch: String, client: HVClient) async -> [MemoryLinkRow]? {
        guard branch != MindBranchName.defaultName else { return nil }
        guard let state = try? await client.send(.mindState(at: .branch(branch), branch: branch)) else { return nil }
        return MemoryGraphBuilder.links(in: state)
    }

    /// The links could not be read, so what is drawn has none: `/api/connections` failed, and a branch's own links, which
    /// do not come from it, were not there to take their place.
    var linksUnavailable: Bool {
        guard case .failed = phase else { return false }
        return linkSource != .branch
    }

    /// The map as the person has set it: without the kinds of node they left off and, when asked, without what has no links.
    func graph(for items: [MemoryItem], cap: Int = MemoryGraphBuilder.defaultCap) -> MemoryGraph {
        MemoryGraphBuilder.build(
            memories: items, links: memoryLinks, bridges: connections.bridges, artifacts: artifacts,
            cap: cap, hideUnlinked: hideUnlinked, hiddenTypes: hiddenTypes
        )
    }

    /// The nodes of `graph` whose name has what was typed in it, the best connected first. Only what is on the map is found,
    /// so a memory past the cap is not.
    func matches(in graph: MemoryGraph) -> [MemoryGraph.Node] {
        graph.matches(query, limit: Self.matchLimit)
    }

    func setHideUnlinked(_ on: Bool) {
        hideUnlinked = on
    }

    /// Shows or hides every node of this type.
    func toggle(type: String) {
        if hiddenTypes.contains(type) { hiddenTypes.remove(type) } else { hiddenTypes.insert(type) }
    }

    func showEverything() {
        hiddenTypes = []
        hideUnlinked = false
    }

    /// The links between memories that the map draws.
    private var memoryLinks: [MemoryLinkRow] {
        switch linkSource {
        case .main, .mainInstead: return connections.memoryLinks
        case .branch: return branchLinks
        case .reading: return []
        }
    }
}
