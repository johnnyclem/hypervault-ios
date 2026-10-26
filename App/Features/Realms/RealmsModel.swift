import HyperVaultKit
import SwiftUI

/// Your address: the realms a person has claimed, their plan, and the pages a realm can open to. Claims and
/// plan come from the database through the person's own token (the web page reads them the same way); a
/// look or a home page is changed through PATCH /api/claim-domain.
@MainActor
@Observable
final class RealmsModel {
    enum Phase {
        case loading
        case loaded
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var snapshot = RealmsSnapshot()
    private(set) var isStale = false
    private(set) var saving: Set<String> = []

    private let client: HVClient
    private let rest: AccountRest
    private let cache: DiskCache
    private let userID: String

    static let cacheKey = "account.realms"

    init(client: HVClient, rest: AccountRest, cache: DiskCache, userID: String) {
        self.client = client
        self.rest = rest
        self.cache = cache
        self.userID = userID
    }

    var claims: [RealmClaim] { snapshot.claims }

    func claim(id: String) -> RealmClaim? { snapshot.claims.first { $0.id == id } }

    func load() async {
        let rest = self.rest
        let userID = self.userID
        do {
            let stream = cachedLoad(cache: cache, namespace: userID, key: Self.cacheKey) {
                try await RealmDirectory.snapshot(rest: rest, userID: userID)
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

    // MARK: Claiming

    func availability(name: String, base: String) async throws -> ClaimAvailability {
        try await client.send(.claimAvailability(name: name, base: base))
    }

    func claim(name: String, base: String) async throws -> ClaimResult {
        let result = try await client.send(.claimRealm(name: name, base: base))
        await reloadAfterChange()
        return result
    }

    private func reloadAfterChange() async {
        if let fresh = try? await RealmDirectory.snapshot(rest: rest, userID: userID) {
            snapshot = fresh
            isStale = false
            phase = .loaded
            await cache.store(fresh, key: Self.cacheKey, namespace: userID)
        }
    }

    // MARK: Look and home page

    /// Sets the look. The row moves at once and goes back if the server says no.
    @discardableResult
    func setTheme(_ claim: RealmClaim, to theme: String?) async throws -> RealmUpdate {
        try await change(claim) { old in
            RealmClaim(id: old.id, subdomain: old.subdomain, baseDomain: old.baseDomain, theme: theme, defaultArtifactSlug: old.defaultArtifactSlug, claimedAt: old.claimedAt)
        } send: {
            .setRealmTheme(subdomain: claim.subdomain, base: claim.baseDomain, theme: theme)
        }
    }

    @discardableResult
    func setHome(_ claim: RealmClaim, to slug: String?) async throws -> RealmUpdate {
        try await change(claim) { old in
            RealmClaim(id: old.id, subdomain: old.subdomain, baseDomain: old.baseDomain, theme: old.theme, defaultArtifactSlug: slug, claimedAt: old.claimedAt)
        } send: {
            .setRealmHome(subdomain: claim.subdomain, base: claim.baseDomain, artifactSlug: slug)
        }
    }

    private func change(
        _ claim: RealmClaim,
        apply: (RealmClaim) -> RealmClaim,
        send: () -> Endpoint<RealmUpdate>
    ) async throws -> RealmUpdate {
        guard let index = snapshot.claims.firstIndex(where: { $0.id == claim.id }) else { throw HVError.invalidRequest("That address is no longer yours.") }
        let before = snapshot.claims
        snapshot.claims[index] = apply(snapshot.claims[index])
        saving.insert(claim.id)
        defer { saving.remove(claim.id) }
        do {
            let answer = try await client.send(send())
            await cache.store(snapshot, key: Self.cacheKey, namespace: userID)
            return answer
        } catch {
            snapshot.claims = before
            throw error
        }
    }
}
