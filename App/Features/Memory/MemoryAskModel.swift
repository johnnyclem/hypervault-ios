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
                backendId: backend.id, message: text, conversationId: conversationID, recallBranch: branch, useTools: !hasToolkit || useTools
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

/// The map of memories: what `/api/connections` adds to the list.
@MainActor
@Observable
final class MemoryGraphModel {
    enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var connections = MemoryConnections()
    private(set) var artifacts: [MemoryGraphArtifact] = []
    private(set) var isStale = false

    @ObservationIgnored private let env: AppEnvironment

    init(env: AppEnvironment) {
        self.env = env
    }

    func load() async {
        let client = env.client
        do {
            for try await loaded in env.load("memory.connections", fetch: { try await client.send(.memoryConnections) }) {
                connections = loaded.value
                isStale = loaded.isStale && loaded.refreshError != nil
                phase = .loaded
            }
        } catch {
            guard !MemoryErrors.isCancelled(error) else { return }
            phase = .failed(MemoryErrors.message(error))
            return
        }
        // Names for the pages the memories are bridged to. Nice to have: the map works without them.
        if let list = try? await client.send(.yours(filter: .file, limit: 50)) {
            artifacts = list.results.map { MemoryGraphArtifact(id: $0.id, title: $0.name, slug: $0.slug) }
        }
    }

    func graph(for items: [MemoryItem], cap: Int = MemoryGraphBuilder.defaultCap) -> MemoryGraph {
        MemoryGraphBuilder.build(memories: items, links: connections.memoryLinks, bridges: connections.bridges, artifacts: artifacts, cap: cap)
    }
}
