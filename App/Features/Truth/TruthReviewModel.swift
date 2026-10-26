import HyperVaultKit
import SwiftUI

/// A deferral the person can take back.
struct TruthUndoableDeferral: Equatable {
    let itemID: String
    let text: String
}

/// One review session: the docket of a ledger as a deck of cards, and the five
/// things that can be done with a card. Nothing here is cached: a decision
/// needs the server, and a stale card would be a wrong one.
@MainActor
@Observable
final class TruthReviewModel {
    enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var ledgers: [TruthLedger] = []
    private(set) var ledger: TruthLedger?
    private(set) var deck = TruthDeck()
    private(set) var schedule = TruthReviewSchedule()
    private(set) var rooms: [TruthRoomChoice] = []
    /// The name the person signs under; nil until they choose one.
    private(set) var handle: String?
    private(set) var answers: [String: [TruthAgentReply]] = [:]
    private(set) var deferral: TruthUndoableDeferral?
    private(set) var isWorking = false

    @ObservationIgnored private let client: HVClient
    @ObservationIgnored private var started = false

    init(client: HVClient) {
        self.client = client
    }

    var isHosted: Bool { ledger?.isHosted == true }

    // MARK: Loading

    func start(preferring slug: String?) async {
        guard !started else { return }
        started = true
        phase = .loading
        do {
            let list = try await client.send(.truthLedgers)
            ledgers = list.ledgers
            ledger = list.chooseForReview(preferring: slug)
        } catch {
            // Not started after all: the next try (the button, or the screen coming back) begins again.
            started = false
            phase = .failed(TruthModel.sentence(error))
            return
        }
        async let signers: Void = loadSigners()
        async let roomList: Void = loadRooms()
        await reload()
        await signers
        await roomList
        // Sitting down restarts the reminder clock.
        _ = try? await client.send(.startTruthReview())
    }

    /// "Try again" on the failed screen: from the top when the ledgers never
    /// came, since there is nothing to reload until they have.
    func retry(preferring slug: String?) async {
        if ledger == nil { await start(preferring: slug) } else { await reload() }
    }

    func reload() async {
        guard let ledger else {
            phase = .failed("There is no ledger to review.")
            return
        }
        do {
            let payload = try await client.send(.truthReview(ledger: ledger.slug))
            deck.replace(with: payload.docket.items)
            schedule = payload.review
            phase = .loaded
        } catch {
            if phase != .loaded { phase = .failed(TruthModel.sentence(error)) }
        }
    }

    func select(slug: String) async {
        guard let next = ledgers.first(where: { $0.slug == slug }), next.slug != ledger?.slug else { return }
        ledger = next
        deck = TruthDeck()
        answers = [:]
        deferral = nil
        phase = .loading
        await reload()
    }

    private func loadSigners() async {
        if let signers = try? await client.send(.truthSigners) { handle = signers.handle }
    }

    private func loadRooms() async {
        if let list = try? await client.send(.truthRooms) { rooms = list.rooms }
    }

    // MARK: The handle

    func saveHandle(_ text: String) async throws {
        if let problem = TruthHandle.problem(text) { throw HVError.invalidRequest(problem) }
        let saved = try await client.send(.setTruthHandle(text))
        handle = saved.handle
    }

    // MARK: Cards

    func state(of action: TruthAction, for item: TruthDocketItem) -> TruthActionState {
        TruthDocketRules.state(of: action, for: item, in: ledger)
    }

    func skip(_ item: TruthDocketItem) {
        deck.skip(item.id)
    }

    /// Carries out a decision. The card leaves the deck whatever the answer (an
    /// approval that did not complete is still on the docket, but the person is
    /// done with it for now). A failure throws the server's sentence.
    func decide(_ action: TruthAction, item: TruthDocketItem, draft: TruthDecisionDraft) async throws -> TruthDecisionOutcome {
        guard let ledger else { throw HVError.invalidRequest("There is no ledger to decide in.") }
        if let problem = TruthDocketRules.problem(with: action, for: item, draft: draft) { throw HVError.invalidRequest(problem) }
        guard let target = TruthDocketRules.target(of: action, for: item, draft: draft) else {
            throw HVError.invalidRequest("There is nothing to decide here.")
        }
        isWorking = true
        defer { isWorking = false }
        do {
            let body = TruthDocketRules.body(of: action, for: item, ledger: ledger.slug, draft: draft)
            let outcome = try await client.send(.decideTruth(target: target, body: body))
            deck.markHandled(item.id)
            if action == .deferral { deferral = TruthUndoableDeferral(itemID: item.id, text: item.text) } else { deferral = nil }
            await reload()
            return outcome
        } catch {
            if (error as? HVError)?.isTruthHandleRequired == true { handle = nil }
            throw error
        }
    }

    /// Asks an agent room about a card. The replies land on the card.
    func ask(item: TruthDocketItem, draft: TruthDecisionDraft) async throws -> [TruthAgentReply] {
        guard let ledger else { throw HVError.invalidRequest("There is no ledger to ask about.") }
        if let problem = TruthDocketRules.problem(with: .ask, for: item, draft: draft) { throw HVError.invalidRequest(problem) }
        guard let target = TruthDocketRules.target(of: .ask, for: item, draft: draft) else {
            throw HVError.invalidRequest("There is nothing to ask about here.")
        }
        isWorking = true
        defer { isWorking = false }
        do {
            let body = TruthDocketRules.body(of: .ask, for: item, ledger: ledger.slug, draft: draft)
            let answer = try await client.send(.askTruth(target: target, body: body))
            let replies = answer.replies ?? []
            answers[item.id] = replies
            await reload()
            return replies
        } catch {
            if (error as? HVError)?.isTruthHandleRequired == true { handle = nil }
            throw error
        }
    }

    /// Takes a deferral back: the card is asked for again by deferring it to a moment ago.
    func undoDeferral() async throws {
        guard let last = deferral, let ledger else { return }
        deferral = nil
        _ = try await client.send(.decideTruth(target: last.itemID, body: TruthDocketRules.undoDeferralBody(ledger: ledger.slug)))
        deck.unmark(last.itemID)
        await reload()
    }

    func dismissUndo() { deferral = nil }

    func setCadence(_ cadence: TruthCadence?) async throws {
        let answer = try await client.send(.setTruthCadence(cadence))
        schedule = answer.review
    }

    func createHostedLedger(slug: String, name: String) async throws {
        let made = try await client.send(.createTruthLedger(slug: slug, name: name, kind: .hosted))
        ledgers.append(made.ledger)
        ledger = made.ledger
        deck = TruthDeck()
        phase = .loading
        await reload()
    }
}
