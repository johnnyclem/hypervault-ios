import HyperVaultKit
import SwiftUI

/// The digest review: memories that are really many, proposed as splits. A
/// split is applied as one commit (so it can be reverted) or dismissed, which
/// leaves the memory whole.
@MainActor
@Observable
final class DigestModel {
    enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var runs: [DigestRun] = []
    private(set) var enabled = false
    private(set) var isStale = false
    private(set) var isChangingSetting = false
    /// Splits being applied or dismissed right now.
    private(set) var busy: Set<String> = []
    private(set) var appliedThisSitting = 0

    @ObservationIgnored private let env: AppEnvironment

    init(env: AppEnvironment) {
        self.env = env
    }

    func load() async {
        let client = env.client
        do {
            for try await loaded in env.load("digest.queue", fetch: { try await client.send(.digestQueue) }) {
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
            let fresh = try await env.client.send(.digestQueue)
            apply(fresh)
            isStale = false
            phase = .loaded
            await env.cache.store(fresh, key: "digest.queue", namespace: env.user.id)
        } catch {
            guard !MemoryErrors.isCancelled(error) else { return }
            if phase == .loading { phase = .failed(MemoryErrors.message(error)) } else { app?.toasts.show(error: error) }
        }
    }

    private func apply(_ queue: DigestQueue) {
        enabled = queue.digestionEnabled
        runs = queue.runs.filter { !$0.segments.isEmpty }
    }

    func setEnabled(_ on: Bool) async throws {
        let before = enabled
        enabled = on
        isChangingSetting = true
        defer { isChangingSetting = false }
        do {
            enabled = try await env.client.send(.setDigesting(enabled: on)).enabled
        } catch {
            enabled = before
            throw error
        }
    }

    /// Applies or dismisses a split. Returns the server's sentence.
    func decide(_ run: DigestRun, _ verdict: DigestVerdict) async throws -> String {
        busy.insert(run.id)
        defer { busy.remove(run.id) }
        let decision = try await env.client.send(.digestDecide(run: run.id, verdict))
        withAnimation(.easeOut(duration: 0.3)) {
            runs.removeAll { $0.id == run.id }
        }
        if decision.applied {
            appliedThisSitting += 1
            NotificationCenter.default.post(name: .hvMemoryChanged, object: nil)
        }
        return decision.message
    }
}
