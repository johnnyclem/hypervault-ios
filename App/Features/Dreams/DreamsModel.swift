import HyperVaultKit
import SwiftUI

/// The dreams review: the nightly pass, and the connections it proposes,
/// merged or dismissed like a pull request. Verdicts show at once and are put
/// back if the server refuses them.
@MainActor
@Observable
final class DreamsModel {
    enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var review = DreamReview()
    private(set) var enabled = false
    private(set) var lastRunAt: Date?
    private(set) var isStale = false
    private(set) var isChangingSetting = false
    private(set) var isDreaming = false
    /// What the last pass said, in the server's words.
    private(set) var dreamNote: String?
    /// Connections accepted a moment ago, shown as "woven in" before they leave.
    private(set) var woven: Set<String> = []

    @ObservationIgnored private let env: AppEnvironment

    init(env: AppEnvironment) {
        self.env = env
    }

    var topScore: Double {
        review.runs.flatMap(\.connections).map(\.score).max() ?? 0
    }

    // MARK: Loading

    func load() async {
        let client = env.client
        do {
            for try await loaded in env.load("dreams.queue", fetch: { try await client.send(.dreamQueue) }) {
                apply(loaded.value)
                isStale = loaded.isStale && loaded.refreshError != nil
                phase = .loaded
            }
        } catch {
            guard !MemoryErrors.isCancelled(error) else { return }
            phase = .failed(MemoryErrors.message(error))
        }
    }

    func refresh(app: AppModel?) async {
        do {
            let fresh = try await env.client.send(.dreamQueue)
            apply(fresh)
            isStale = false
            phase = .loaded
            await env.cache.store(fresh, key: "dreams.queue", namespace: env.user.id)
        } catch {
            guard !MemoryErrors.isCancelled(error) else { return }
            if phase == .loading { phase = .failed(MemoryErrors.message(error)) } else { app?.toasts.show(error: error) }
        }
    }

    private func apply(_ queue: DreamQueue) {
        enabled = queue.dreamingEnabled
        lastRunAt = queue.lastRunAt
        review.replace(with: queue.runs)
    }

    // MARK: Settings

    /// Turns the nightly pass on or off. The switch moves at once and moves back if the server says no.
    func setEnabled(_ on: Bool) async throws {
        let before = enabled
        enabled = on
        isChangingSetting = true
        defer { isChangingSetting = false }
        do {
            let settings = try await env.client.send(.setDreaming(enabled: on))
            enabled = settings.enabled
            lastRunAt = settings.lastRunAt ?? lastRunAt
        } catch {
            enabled = before
            throw error
        }
    }

    // MARK: Dream now

    /// Runs a pass on demand. The server does the work before it answers; if a
    /// server ever hands it to a background job, that job is followed here.
    func dreamNow() async throws {
        isDreaming = true
        dreamNote = nil
        defer { isDreaming = false }
        let client = env.client
        let result = try await client.send(.dreamNow)
        var message = result.message
        if let jobID = result.jobId {
            let outcome = try await BackgroundJobPoller(client: client).wait(for: jobID)
            switch outcome {
            case .finished(let job):
                if let note = job.outcomeMessage { message = note }
            case .stillRunning:
                message = "Still dreaming. The connections will be here when it is done."
            }
        }
        dreamNote = message.isEmpty ? nil : message
        await refresh(app: nil)
    }

    // MARK: Verdicts

    /// Weaves one connection into the graph. It shows as woven for a moment, then leaves the queue.
    func accept(_ id: String, calm: Bool) async throws {
        woven.insert(id)
        do {
            let decision = try await env.client.send(.dreamDecide(connection: id, .accept))
            if let failure = decision.failures.first(where: { $0.id == id }) {
                woven.remove(id)
                throw HVError.invalidRequest(failure.error)
            }
        } catch {
            woven.remove(id)
            throw error
        }
        Haptics.success()
        if !calm { try? await Task.sleep(nanoseconds: 1_000_000_000) }
        withAnimation(calm ? nil : .spring(response: 0.4, dampingFraction: 0.85)) {
            review.remove(connection: id, verdict: .accept)
            woven.remove(id)
        }
        NotificationCenter.default.post(name: .hvMemoryChanged, object: nil)
    }

    /// Files one connection away for good: it is never proposed again.
    func reject(_ id: String) async throws {
        var removal: DreamReview.Removal?
        withAnimation(.easeOut(duration: 0.25)) {
            removal = review.remove(connection: id, verdict: .reject)
        }
        do {
            _ = try await env.client.send(.dreamDecide(connection: id, .reject))
        } catch {
            if let removal { withAnimation { review.restore(removal, verdict: .reject) } }
            throw error
        }
    }

    /// Accepts or rejects everything still pending in a run. Returns the server's sentence.
    func decide(run id: String, _ verdict: DreamVerdict, calm: Bool) async throws -> String {
        guard let run = review.runs.first(where: { $0.id == id }) else { return "" }
        let ids = run.connections.map(\.id)
        if verdict == .accept { for connection in ids { woven.insert(connection) } }
        let decision: DreamDecision
        do {
            decision = try await env.client.send(.dreamDecide(run: id, verdict))
        } catch {
            for connection in ids { woven.remove(connection) }
            throw error
        }
        if verdict == .accept {
            Haptics.success()
            if !calm { try? await Task.sleep(nanoseconds: 1_000_000_000) }
        }
        var removal: DreamReview.Removal?
        withAnimation(calm ? nil : .easeOut(duration: 0.3)) {
            removal = review.remove(run: id, verdict: verdict)
            for connection in ids { woven.remove(connection) }
        }
        // Some may not have been woven in: they stay pending, so they stay here.
        let failed = Set(decision.failures.map(\.id))
        if let removal, !failed.isEmpty {
            review.restore(removal, verdict: verdict, only: failed)
            throw HVError.invalidRequest("Some connections could not be woven in: " + decision.failures.map(\.error).joined(separator: "; "))
        }
        NotificationCenter.default.post(name: .hvMemoryChanged, object: nil)
        return decision.message
    }
}
