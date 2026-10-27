import HyperVaultKit
import SwiftUI

/// The keys on Agent keys: loading them (saved copy first), revoking and the "Can send mail" switch. What it
/// holds about a key is what the server states: its name, prefix, dates and scopes, and the slug of its setup
/// challenge page. Whether an agent finished the challenge is not worked out here. The raw value of a key is
/// never here: only its prefix.
@MainActor
@Observable
final class AgentsAndKeysModel {
    enum Phase {
        case loading
        case loaded
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var snapshot = AgentKeysSnapshot()
    /// What is on screen is the saved copy.
    private(set) var isStale = false
    /// Keys with a change in flight.
    private(set) var changing: Set<String> = []
    /// Keys being revoked.
    private(set) var revoking: Set<String> = []

    private let client: HVClient
    private let rest: AccountRest
    private let cache: DiskCache
    private let userID: String

    static let cacheKey = "account.keys"

    init(client: HVClient, rest: AccountRest, cache: DiskCache, userID: String) {
        self.client = client
        self.rest = rest
        self.cache = cache
        self.userID = userID
    }

    var keys: [AgentKey] { snapshot.keys }

    /// The slug of the page the key's agent is asked to rewrite, where there is one.
    func challengeSlug(of key: AgentKey) -> String? { snapshot.challengeSlugs[key.id] }

    // MARK: Loading

    func load() async {
        let rest = self.rest
        let userID = self.userID
        do {
            let stream = cachedLoad(cache: cache, namespace: userID, key: Self.cacheKey) {
                try await AgentKeyDirectory.snapshot(rest: rest, userID: userID)
            }
            for try await loaded in stream {
                snapshot = loaded.value
                isStale = loaded.isStale
                phase = .loaded
            }
        } catch {
            if case .loaded = phase {} else { phase = .failed(keysMessage(for: error)) }
        }
    }

    // MARK: Changing

    /// Revokes a key at once. The row goes only when the server has agreed.
    func revoke(_ key: AgentKey) async throws {
        changing.insert(key.id)
        revoking.insert(key.id)
        defer {
            changing.remove(key.id)
            revoking.remove(key.id)
        }
        _ = try await client.send(.revokeAgentKey(id: key.id))
        snapshot.keys.removeAll { $0.id == key.id }
        snapshot.challengeSlugs[key.id] = nil
        await cache.store(snapshot, key: Self.cacheKey, namespace: userID)
    }

    /// Turns "Can send mail" on or off. The switch moves at once and goes back if the server says no.
    func setCanSendMail(_ key: AgentKey, _ canSend: Bool) async throws {
        guard let index = snapshot.keys.firstIndex(where: { $0.id == key.id }) else { return }
        let before = snapshot.keys[index]
        snapshot.keys[index] = before.with(scopes: AgentKeyScope.scopes(canSendMail: canSend), mailClaimId: before.mailClaimId, mailPinCleared: before.mailPinCleared)
        changing.insert(key.id)
        defer { changing.remove(key.id) }
        do {
            let answer = try await client.send(.setAgentKeyMail(id: key.id, canSendMail: canSend))
            if let at = snapshot.keys.firstIndex(where: { $0.id == key.id }) {
                snapshot.keys[at] = snapshot.keys[at].with(
                    scopes: answer.key.scopes,
                    mailClaimId: answer.key.mailClaimId,
                    mailPinCleared: answer.key.mailPinCleared ?? false
                )
            }
            await cache.store(snapshot, key: Self.cacheKey, namespace: userID)
        } catch {
            if let at = snapshot.keys.firstIndex(where: { $0.id == key.id }) { snapshot.keys[at] = before }
            throw error
        }
    }
}
