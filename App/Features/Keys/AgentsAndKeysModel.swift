import HyperVaultKit
import SwiftUI

/// The keys on Account & keys: loading them (saved copy first), what each agent's setup has come to,
/// revoking and the "Can send mail" switch. The raw value of a key is never here: only its prefix.
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
    /// Whether the server has pairing on. Nil until the question has been answered.
    private(set) var pairingOn: Bool?
    /// Keys with a change in flight.
    private(set) var changing: Set<String> = []

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

    func status(of key: AgentKey) -> AgentSetupStatus? { snapshot.statuses[key.id] }

    // MARK: Loading

    func load() async {
        let rest = self.rest
        let userID = self.userID
        async let pairing = PairingAvailability.probe(client: client)
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
        pairingOn = await pairing
        recordConnectedOnce()
    }

    /// The first time an agent is seen connected, tell the server (best effort, silent): the profile
    /// remembers it so the connect card on other devices stays away.
    private func recordConnectedOnce() {
        guard snapshot.connectedCount > 0 else { return }
        let flag = "keys.onboarding.completed.\(userID)"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        UserDefaults.standard.set(true, forKey: flag)
        let client = self.client
        Task { _ = try? await client.send(.recordOnboarding(connectCompleted: true)) }
    }

    // MARK: Changing

    /// Revokes a key at once. The row goes only when the server has agreed.
    func revoke(_ key: AgentKey) async throws {
        changing.insert(key.id)
        defer { changing.remove(key.id) }
        _ = try await client.send(.revokeAgentKey(id: key.id))
        snapshot.keys.removeAll { $0.id == key.id }
        snapshot.statuses[key.id] = nil
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
