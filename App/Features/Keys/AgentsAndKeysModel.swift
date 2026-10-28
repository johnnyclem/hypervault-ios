import HyperVaultKit
import SwiftUI

/// The keys on Agent keys: loading them (saved copy first), revoking, the "Can send mail" switch and the "Mail
/// address" picker. What it holds about a key is what the server states: its name, prefix, dates, scopes and the
/// address it is pinned to, and the slug of its setup challenge page. Whether an agent finished the challenge is
/// not worked out here. The raw value of a key is never here: only its prefix.
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
    /// The person's mailboxes, which the "Mail address" picker offers the claimed ones of. Empty until a key's screen
    /// has asked, and when the server will not say: then the picker is not offered.
    private(set) var mailboxes: [OwnerMailbox] = []

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

    /// Reads the mailboxes the "Mail address" picker offers. Asked for when a key's screen opens, as the web card asks
    /// once it has a key to show them on. Best effort: when they cannot be read the picker is simply not offered, and
    /// the "Can send mail" switch does not need them.
    func loadMailboxes() async {
        if let list = try? await client.send(.mailMailboxes) { mailboxes = list.mailboxes }
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
            await adopt(answer, for: key.id)
        } catch {
            if let at = snapshot.keys.firstIndex(where: { $0.id == key.id }) { snapshot.keys[at] = before }
            throw error
        }
    }

    /// Pins the key to one of the person's own claimed addresses (`claimId`), so it reads and sends as that address,
    /// or back to the account's default address (nil). The picker moves at once and goes back if the server says no.
    /// Either choice ends a released address's warning, as the server does.
    func setMailAddress(_ key: AgentKey, claimId: String?) async throws {
        guard let index = snapshot.keys.firstIndex(where: { $0.id == key.id }) else { return }
        let before = snapshot.keys[index]
        snapshot.keys[index] = before.with(scopes: before.scopes, mailClaimId: claimId, mailPinCleared: false)
        changing.insert(key.id)
        defer { changing.remove(key.id) }
        do {
            let answer = try await client.send(.setAgentKeyMailAddress(id: key.id, claimId: claimId))
            await adopt(answer, for: key.id)
        } catch {
            if let at = snapshot.keys.firstIndex(where: { $0.id == key.id }) { snapshot.keys[at] = before }
            throw error
        }
    }

    /// Takes what the server says about a key's mail settings after a change, and saves the list.
    private func adopt(_ answer: AgentKeyUpdate, for id: String) async {
        if let at = snapshot.keys.firstIndex(where: { $0.id == id }) {
            snapshot.keys[at] = snapshot.keys[at].with(
                scopes: answer.key.scopes,
                mailClaimId: answer.key.mailClaimId,
                mailPinCleared: answer.key.mailPinCleared ?? false
            )
        }
        await cache.store(snapshot, key: Self.cacheKey, namespace: userID)
    }
}
