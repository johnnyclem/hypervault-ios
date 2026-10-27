import Foundation
import HyperVaultKit
import Observation

/// How saving a new entry came out.
enum VaultCreateOutcome: Equatable {
    case created(VaultSecret)
    /// The sentence to show. `isConflict` is a taken name, which belongs under the Name field.
    case failure(VaultFailure)
}

/// The saved logins, cards, contact info and keys. The list is metadata and a masked hint, never a value.
/// It is not kept on disk: a username or a card's last four digits is not something to leave in a cache.
@MainActor
@Observable
final class VaultItemsModel {
    enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var secrets: [VaultSecret] = []
    /// Why the last refresh failed, while the list from the load before it is still on screen. Nil once a refresh works.
    private(set) var refreshError: String?

    var filter: VaultCategory?
    var query = ""

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

    /// The allow switches of one entry, for its page.
    func makeAllowedKeys() -> VaultAllowedKeysModel {
        VaultAllowedKeysModel(client: client, rest: rest, userID: userID, announcer: announcer)
    }

    // MARK: Loading

    /// Reads the list. A first read that fails is the screen's error; a refresh that fails leaves the list that is
    /// showing and says so in `refreshError`. Either is announced.
    func load() async {
        do {
            secrets = try await client.send(.vaultSecrets).secrets
            phase = .loaded
            refreshError = nil
        } catch {
            // A pull to refresh that is let go of, or a screen that went away, is not a failure.
            if error is CancellationError { return }
            if case .cancelled? = error as? HVError { return }
            let message = VaultErrorText.loadMessage(for: error)
            if case .loaded = phase {
                refreshError = message
            } else {
                phase = .failed(message)
            }
            announcer.announce(message)
        }
    }

    // MARK: Showing

    /// How many entries are in a category, whatever is typed in the search: the counts add up to All.
    func count(in category: VaultCategory?) -> Int {
        guard let category else { return secrets.count }
        return secrets.filter { $0.kind.category == category }.count
    }

    /// Whether the account has no room for another entry.
    var isFull: Bool {
        VaultLimits.entryLimitReached(count: secrets.count)
    }

    /// In the category, matching what was typed, by name in the web's fixed English order.
    var visible: [VaultSecret] {
        let words = query.lowercased().split(whereSeparator: { $0 == " " }).map(String.init)
        return secrets
            .filter { filter == nil || $0.kind.category == filter }
            .filter { secret in
                words.allSatisfy { word in
                    secret.name.lowercased().contains(word)
                        || (secret.hint ?? "").lowercased().contains(word)
                        || secret.kind.label.lowercased().contains(word)
                }
            }
            .sortedByName()
    }

    func secret(named name: String) -> VaultSecret? { secrets.first { $0.name == name } }

    func secret(id: String) -> VaultSecret? { secrets.first { $0.id == id } }

    // MARK: Changing

    func add(_ secret: VaultSecret) {
        secrets.removeAll { $0.id == secret.id }
        secrets.append(secret)
    }

    func replace(oldName: String, with secret: VaultSecret) {
        if let index = secrets.firstIndex(where: { $0.name == oldName || $0.id == secret.id }) {
            secrets[index] = secret
        } else {
            secrets.append(secret)
        }
    }

    /// The entry is gone from the server (deleted on another device, or a 404 on a change): it leaves the list at once,
    /// and the list is read again in the background.
    func forget(_ secret: VaultSecret) {
        secrets.removeAll { $0.id == secret.id }
        Task { await load() }
    }

    /// Saves a new entry. `value` is the canonical JSON of a login, card or contact, or the text of a key; it goes
    /// to the server and is not kept here. A taken name is a conflict.
    func create(name: String, kind: SecretKind, value: String) async -> VaultCreateOutcome {
        do {
            let made = try await client.send(.createVaultSecret(name: name, kind: kind, value: value))
            add(made.secret)
            return .created(made.secret)
        } catch {
            let failure = VaultFailure(error)
            announcer.announce(failure.message)
            return .failure(failure)
        }
    }

    /// Renames an entry (`newName`) or replaces its value (`value`). Fields left nil stay as they are. An entry that is
    /// gone leaves the list.
    func change(_ secret: VaultSecret, newName: String? = nil, value: String? = nil) async -> VaultUpdateOutcome {
        let outcome = await client.changeVaultSecret(name: secret.name, newName: newName, value: value)
        switch outcome {
        case .updated(let updated):
            replace(oldName: secret.name, with: updated)
        case .entryGone:
            forget(secret)
        case .failure(let failure):
            announcer.announce(failure.message)
        }
        return outcome
    }

    /// Deletes an entry. One that is already gone is deleted, as far as the person is concerned. A failure is the
    /// screen's to say (it is a toast, which announces itself).
    func delete(_ secret: VaultSecret) async -> VaultDeleteOutcome {
        let outcome = await client.removeVaultSecret(name: secret.name)
        switch outcome {
        case .deleted:
            secrets.removeAll { $0.id == secret.id }
        case .entryGone:
            forget(secret)
        case .failure:
            break
        }
        return outcome
    }
}
