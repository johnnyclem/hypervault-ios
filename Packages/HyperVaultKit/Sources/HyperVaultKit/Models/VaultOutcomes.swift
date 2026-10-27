import Foundation

// What a change to a vault entry came to, classified from the HTTP result so a screen never reads server text to
// decide what to do (handoff 5.12: "Branch on the HTTP status, never on the message text").
//
// The 404s are the reason this exists. A 404 on a grants route is either "No such secret." (the entry is gone: close
// the sheet and refresh the list) or "No such grant." (the key is already off) and, for an allow, "No such API key.".
// The status cannot tell them apart, so the grants are read again: a second 404 means the entry is gone. "No such
// grant." is never shown, since the word on screen is revoke and not grant. A 404 on a delete or a rename can only
// mean the entry is gone.

/// Why a vault call did not go through, in words safe to show.
public struct VaultFailure: Sendable, Equatable {
    /// The server's sentence, or the product's line for a network failure (`VaultErrorText`). Never "No such grant.".
    public let message: String
    /// The HTTP status, or nil when there was no answer (offline) or the request was not sent.
    public let status: Int?

    public init(message: String, status: Int? = nil) {
        self.message = message
        self.status = status
    }

    /// From an error thrown by a call; `loading` for a call that only read.
    public init(_ error: Error, loading: Bool = false) {
        self.init(
            message: loading ? VaultErrorText.loadMessage(for: error) : VaultErrorText.message(for: error),
            status: (error as? HVError)?.status
        )
    }

    /// A 409: on a create or rename, the name is in use, and the form puts the server's sentence under the name
    /// field and moves focus there. On a rename it is also the sentence for an entry an MCP server signed in with.
    public var isConflict: Bool { status == 409 }
}

/// How turning one key's switch on or off came out.
public enum SecretGrantOutcome: Sendable, Equatable {
    /// The server agreed (a 2xx): the key may now read the entry (allow), or may not (revoke). Only now does the
    /// switch move.
    case applied
    /// A revoke found nothing to revoke (404, and the entry is still there): the key is already off. Set the
    /// switch off and show nothing.
    case alreadyOff
    /// The entry is gone (404, and reading its grants answered 404 too). Close the sheet and refresh the list.
    case entryGone
    /// An allow named a key that is not the person's, or no longer exists (404, and the entry is still there).
    /// Read the keys again.
    case keyGone
    /// Anything else. The switch stays where the server says it is.
    case failure(VaultFailure)
}

/// The keys allowed to read an entry.
public enum SecretGrantsLoad: Sendable, Equatable {
    /// The ids of the keys with a grant. That includes grants made to keys revoked since (revoking a key keeps its
    /// row), so match them against the active keys and set each switch from membership.
    case loaded(Set<String>)
    /// 404: the entry is gone.
    case entryGone
    case failure(VaultFailure)
}

/// How a rename, a new description or a new value came out.
public enum VaultUpdateOutcome: Sendable, Equatable {
    case updated(VaultSecret)
    /// 404: the entry was deleted somewhere else.
    case entryGone
    case failure(VaultFailure)
}

/// How a delete came out.
public enum VaultDeleteOutcome: Sendable, Equatable {
    case deleted
    /// 404: it was already gone, which is what the person wanted. Treat it as deleted.
    case entryGone
    case failure(VaultFailure)
}

extension HVClient {
    /// Reads which keys may read the entry. A 404 is `.entryGone`.
    public func loadSecretGrants(name: String) async -> SecretGrantsLoad {
        do {
            let list = try await send(.secretGrants(name: name))
            return .loaded(Set(list.grants.map(\.apiKeyId)))
        } catch let error as HVError where error.status == 404 {
            return .entryGone
        } catch {
            return .failure(VaultFailure(error, loading: true))
        }
    }

    /// Allows (`allowed: true`) or revokes one key's read of the entry and says how it came out. An allow is
    /// an upsert and is retried on a busy server; a revoke is sent once, since a repeat would answer 404.
    public func setSecretGrant(name: String, keyID: String, allowed: Bool) async -> SecretGrantOutcome {
        do {
            if allowed {
                _ = try await send(.grantSecret(name: name, keyID: keyID))
            } else {
                _ = try await send(.revokeSecretGrant(name: name, keyID: keyID))
            }
            return .applied
        } catch {
            guard (error as? HVError)?.status == 404 else { return .failure(VaultFailure(error)) }
        }
        switch await loadSecretGrants(name: name) {
        case .entryGone: return .entryGone
        case .failure(let failure): return .failure(failure)
        case .loaded: return allowed ? .keyGone : .alreadyOff
        }
    }

    /// `PATCH /api/secrets/[name]`: a rename, a description or a new value. A 404 is `.entryGone`.
    public func changeVaultSecret(
        name: String, newName: String? = nil, description: String? = nil, value: String? = nil
    ) async -> VaultUpdateOutcome {
        do {
            let answer = try await send(.updateVaultSecret(name: name, newName: newName, description: description, value: value))
            return .updated(answer.secret)
        } catch let error as HVError where error.status == 404 {
            return .entryGone
        } catch {
            return .failure(VaultFailure(error))
        }
    }

    /// `DELETE /api/secrets/[name]`. A 404 is `.entryGone`.
    public func removeVaultSecret(name: String) async -> VaultDeleteOutcome {
        do {
            _ = try await send(.deleteVaultSecret(name: name))
            return .deleted
        } catch let error as HVError where error.status == 404 {
            return .entryGone
        } catch {
            return .failure(VaultFailure(error))
        }
    }
}
