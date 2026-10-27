import HyperVaultKit
import SwiftUI

/// Which agent keys may read one secret, as far as its page knows. A read that failed is a state of its own,
/// not "none": a row of switches that all read off would say no agent can read the entry when the truth is
/// that nobody knows yet.
enum VaultGrantsPhase: Equatable {
    case loading
    case loaded(Set<String>)
    case failed

    /// The keys known to be allowed; empty while loading or after a failure.
    var granted: Set<String> {
        if case .loaded(let ids) = self { return ids }
        return []
    }

    var isLoaded: Bool {
        if case .loaded = self { return true }
        return false
    }

    var hasFailed: Bool { self == .failed }

    /// The same keys with one switch set. A switch moves at once when it is tapped, and goes back through
    /// here alone if the server refuses it, so the other switches, which may have moved and been accepted
    /// since, are left as they are. While loading or after a failed read there are no switches to set.
    func setting(_ keyID: String, to allowed: Bool) -> VaultGrantsPhase {
        guard case .loaded(var ids) = self else { return self }
        if allowed { ids.insert(keyID) } else { ids.remove(keyID) }
        return .loaded(ids)
    }
}

enum VaultGrantsCopy {
    /// Said instead of the server's words, which can be a bare status line.
    static let loadFailed = "Couldn't load which keys are allowed."
}

/// The saved logins, cards, contact info and keys. The list is metadata and a masked hint, never a value.
/// It is not kept on disk: a username or a card's last four digits is not something to leave in a cache.
@MainActor
@Observable
final class VaultItemsModel {
    enum Phase {
        case loading
        case loaded
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var secrets: [VaultSecret] = []
    /// The person's agent keys, for choosing which may read a secret.
    private(set) var keys: [AgentKey] = []

    var filter: VaultCategory?
    var query = ""

    private let client: HVClient
    private let rest: AccountRest
    private let userID: String

    init(client: HVClient, rest: AccountRest, userID: String) {
        self.client = client
        self.rest = rest
        self.userID = userID
    }

    // MARK: Loading

    func load() async {
        async let loadedKeys = try? AgentKeyDirectory.keys(rest: rest, userID: userID)
        do {
            let list = try await client.send(.vaultSecrets)
            secrets = list.secrets
            phase = .loaded
        } catch {
            if case .loaded = phase {} else { phase = .failed(keysMessage(for: error)) }
        }
        if let fresh = await loadedKeys { keys = fresh }
    }

    // MARK: Showing

    func count(in category: VaultCategory?) -> Int {
        guard let category else { return secrets.count }
        return secrets.filter { $0.kind.category == category }.count
    }

    /// By name, in the category, matching what was typed.
    var visible: [VaultSecret] {
        let words = query.lowercased().split(whereSeparator: { $0 == " " }).map(String.init)
        return secrets
            .filter { filter == nil || $0.kind.category == filter }
            .filter { secret in
                words.allSatisfy { word in
                    secret.name.lowercased().contains(word)
                        || (secret.hint ?? "").lowercased().contains(word)
                        || secret.kind.label.lowercased().contains(word)
                        || (secret.description ?? "").lowercased().contains(word)
                }
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
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

    /// Saves a new entry. `value` is the canonical JSON of a login, card or contact, or the text of a key; it goes
    /// to the server and is not kept here. A 409 is a taken name.
    func create(name: String, kind: SecretKind, value: String, description: String?) async throws -> VaultSecret {
        let made = try await client.send(.createVaultSecret(name: name, kind: kind, value: value, description: description))
        add(made.secret)
        return made.secret
    }

    /// Renames, changes the description, or replaces the value. Fields left nil stay as they are.
    func update(_ secret: VaultSecret, newName: String? = nil, description: String? = nil, value: String? = nil) async throws -> VaultSecret {
        let answer = try await client.send(.updateVaultSecret(name: secret.name, newName: newName, description: description, value: value))
        replace(oldName: secret.name, with: answer.secret)
        return answer.secret
    }

    /// The keys allowed to read a secret.
    func grantedKeyIDs(for secret: VaultSecret) async throws -> Set<String> {
        Set(try await client.send(.secretGrants(name: secret.name)).grants.map(\.apiKeyId))
    }

    /// The same read as a phase the screen can show. The reason for a failure is dropped on purpose: it can be
    /// a bare status line from a proxy, and the screen says its own plain sentence.
    func grantsPhase(for secret: VaultSecret) async -> VaultGrantsPhase {
        do {
            return .loaded(try await grantedKeyIDs(for: secret))
        } catch {
            return .failed
        }
    }

    func setGranted(_ granted: Bool, keyID: String, for secret: VaultSecret) async throws {
        if granted {
            _ = try await client.send(.grantSecret(name: secret.name, keyID: keyID))
        } else {
            _ = try await client.send(.revokeSecretGrant(name: secret.name, keyID: keyID))
        }
    }

    func delete(_ secret: VaultSecret) async throws {
        _ = try await client.send(.deleteVaultSecret(name: secret.name))
        secrets.removeAll { $0.id == secret.id }
    }
}
