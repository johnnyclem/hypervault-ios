import Foundation
import HyperVaultKit
import Observation

/// The allow switches of one entry: which of the person's agent keys may read it.
///
/// A switch moves only when the server agrees (handoff 4.6, 10: no optimistic allow switch). A tap marks its key
/// pending and sends the request; `phase` changes only on the answer, so what is drawn is always what the server last
/// said. The keys and the entry's grants are read together, and a switch exists only when both reads answered: a failed
/// read is a state of its own with its own sentence, not "no keys" and not a row of switches that all read off.
@MainActor
@Observable
final class VaultAllowedKeysModel {
    enum Phase: Equatable {
        case loading
        /// Both reads answered: the person's active keys, newest first, and which of them may read the entry. A grant
        /// to a key revoked since is not in `allowed`: revoking a key keeps its row, and the switch for it is gone.
        case ready(keys: [AgentKey], allowed: Set<String>)
        /// A read failed. No switches: the sentence says why, and the screen offers to try again.
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    /// Keys with a request on the wire. Their switch is replaced by a spinner until the answer comes.
    private(set) var pending: Set<String> = []
    /// Why the last change was refused, in the server's words, or the product's line for a network failure.
    private(set) var changeError: String?
    /// The entry was deleted somewhere else: a 404 on its grants that reading them again confirmed. The screen closes
    /// the entry and refreshes the list.
    private(set) var entryIsGone = false

    private let client: HVClient
    private let rest: AccountRest
    private let userID: String
    @ObservationIgnored private let announcer: SpeechAnnouncer

    init(client: HVClient, rest: AccountRest, userID: String, announcer: SpeechAnnouncer = VoiceOverAnnouncer.shared) {
        self.client = client
        self.rest = rest
        self.userID = userID
        self.announcer = announcer
    }

    // MARK: Showing

    var isReady: Bool {
        if case .ready = phase { return true }
        return false
    }

    /// The active keys, once they are known.
    var keys: [AgentKey] {
        if case .ready(let keys, _) = phase { return keys }
        return []
    }

    /// Whether the server last said this key may read the entry.
    func isAllowed(_ keyID: String) -> Bool {
        if case .ready(_, let allowed) = phase { return allowed.contains(keyID) }
        return false
    }

    func isPending(_ keyID: String) -> Bool {
        pending.contains(keyID)
    }

    // MARK: Loading

    /// Reads the keys and the entry's grants. `quietly` keeps what is on screen until the answer comes, for a read made
    /// after a change rather than on opening.
    func load(name: String, quietly: Bool = false) async {
        if !quietly { phase = .loading }
        changeError = nil
        let rest = self.rest
        let userID = self.userID
        async let keysRead = Self.readKeys(rest: rest, userID: userID)
        let grants = await client.loadSecretGrants(name: name)
        let keys = await keysRead
        // The sheet was closed while the reads were out: whatever they said is nobody's to hear.
        guard !Task.isCancelled else { return }
        switch grants {
        case .entryGone:
            entryIsGone = true
        case .failure(let failure):
            fail(failure.message)
        case .loaded(let granted):
            switch keys {
            case .success(let list):
                phase = .ready(keys: list, allowed: granted.intersection(Set(list.map(\.id))))
            case .failure(let error):
                fail(VaultErrorText.loadMessage(for: error))
            }
        }
    }

    nonisolated private static func readKeys(rest: AccountRest, userID: String) async -> Result<[AgentKey], Error> {
        do {
            return .success(try await AgentKeyDirectory.keys(rest: rest, userID: userID))
        } catch {
            return .failure(error)
        }
    }

    private func fail(_ message: String) {
        phase = .failed(message)
        announcer.announce(message)
    }

    // MARK: Changing

    /// Asks the server to allow (`on`) or revoke one key's read of the entry. The key is pending from here to the answer,
    /// and nothing else moves until then. A second tap on a key that is pending, and a tap before the reads have answered,
    /// do nothing.
    ///
    /// - applied, or a revoke the server had already done: the switch ends where the person asked, and nothing is said.
    /// - the key is gone: the keys are read again.
    /// - the entry is gone: `entryIsGone`.
    /// - anything else: the sentence, shown and announced; the switch stays where the server says it is.
    func setAllowed(_ on: Bool, keyID: String, name: String) async {
        guard isReady, !pending.contains(keyID) else { return }
        pending.insert(keyID)
        changeError = nil
        let outcome = await client.setSecretGrant(name: name, keyID: keyID, allowed: on)
        pending.remove(keyID)
        switch outcome {
        case .applied, .alreadyOff:
            confirm(keyID, allowed: on)
        case .keyGone:
            await load(name: name, quietly: true)
        case .entryGone:
            entryIsGone = true
        case .failure(let failure):
            changeError = failure.message
            announcer.announce(failure.message)
        }
    }

    /// Moves one switch to what the server agreed to, leaving the others as they are: another key's request may have
    /// been answered while this one was out.
    private func confirm(_ keyID: String, allowed on: Bool) {
        guard case .ready(let keys, var allowed) = phase else { return }
        if on { allowed.insert(keyID) } else { allowed.remove(keyID) }
        phase = .ready(keys: keys, allowed: allowed)
    }
}

extension AgentKey {
    /// What an allow switch is called: the key's prefix first, then its name unless it is the unnamed "default" key.
    /// VoiceOver reads it as "hv_Zk3pQ9vL..., Claude Code".
    var allowSwitchLabel: String {
        displayName.map { "\(prefixLabel), \($0)" } ?? prefixLabel
    }
}
