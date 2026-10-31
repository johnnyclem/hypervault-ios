import HyperVaultKit
import SwiftUI
import UIKit

/// The owner's invite codes. The server cannot list them, so this keeps the
/// ones minted from this phone (in the signed-in person's cache) and updates
/// each from the server's answer when it is acted on.
@MainActor
@Observable
final class AdminModel {
    private(set) var book = AdminInviteBook()
    /// The code just minted, shown large until it is dismissed.
    private(set) var justMinted: AdminInvite?
    private(set) var isMinting = false
    private(set) var busy: Set<String> = []
    var usesText = "1"
    var note = ""

    @ObservationIgnored var reportError: (Error) -> Void = { _ in }
    @ObservationIgnored var reportSuccess: (String) -> Void = { _ in }

    @ObservationIgnored private let client: HVClient
    @ObservationIgnored private let cache: DiskCache
    @ObservationIgnored private let namespace: String

    init(client: HVClient, cache: DiskCache, namespace: String) {
        self.client = client
        self.cache = cache
        self.namespace = namespace
    }

    func invite(id: String) -> AdminInvite? { book.invites.first { $0.id == id } }

    /// The uses as typed, kept in the route's range.
    var uses: Int { AdminInvite.clampUses(Int(usesText.trimmingCharacters(in: .whitespaces)) ?? 1) }

    func load() async {
        if let saved = await cache.entry(AdminInviteBook.self, key: "admin.invites", namespace: namespace) {
            book = saved.value
        }
    }

    private func save() {
        let book = self.book, cache = self.cache, namespace = self.namespace
        Task { await cache.store(book, key: "admin.invites", namespace: namespace) }
    }

    // MARK: Invites

    func mint() async {
        guard !isMinting else { return }
        isMinting = true
        defer { isMinting = false }
        do {
            let answer = try await client.send(.createInvite(maxUses: uses, note: note))
            book.upsert(answer.invite)
            justMinted = answer.invite
            save()
            usesText = "1"
            note = ""
            Haptics.success()
        } catch {
            reportError(error)
        }
    }

    func dismissMinted() { justMinted = nil }

    func setDisabled(_ disabled: Bool, inviteID: String) async {
        guard !busy.contains(inviteID) else { return }
        busy.insert(inviteID)
        defer { busy.remove(inviteID) }
        do {
            let answer = try await client.send(.setInvite(id: inviteID, disabled: disabled))
            book.upsert(answer.invite)
            if justMinted?.id == inviteID { justMinted = answer.invite }
            save()
            Haptics.success()
        } catch {
            reportError(error)
        }
    }

    /// Asks the server for the code's current uses. (It has no read, so this
    /// sets the code to the state it already has and reads the row it answers with.)
    func refresh(inviteID: String) async {
        guard let current = invite(id: inviteID) else { return }
        await setDisabled(current.disabled, inviteID: inviteID)
    }

    func destroy(inviteID: String) async -> Bool {
        guard !busy.contains(inviteID) else { return false }
        busy.insert(inviteID)
        defer { busy.remove(inviteID) }
        do {
            _ = try await client.send(.deleteInvite(id: inviteID))
            book.remove(id: inviteID)
            if justMinted?.id == inviteID { justMinted = nil }
            save()
            reportSuccess("Invite code destroyed")
            return true
        } catch {
            reportError(error)
            return false
        }
    }
}

/// Acting on one account by its id.
@MainActor
@Observable
final class AdminAccountModel {
    var idText = ""
    var displayName = ""
    var plan: AdminPlan = .pro
    private(set) var isWorking = false
    /// What was done in this visit, newest first, so the owner can see it landed.
    private(set) var log: [String] = []

    @ObservationIgnored var reportError: (Error) -> Void = { _ in }
    @ObservationIgnored private let client: HVClient
    @ObservationIgnored let ownID: String

    init(client: HVClient, ownID: String) {
        self.client = client
        self.ownID = ownID.lowercased()
    }

    var accountID: String? { AdminAccountID.parse(idText) }
    var isSelf: Bool { accountID == ownID }
    var shortID: String { accountID.map { String($0.prefix(8)) + "…" } ?? "" }

    func change(_ change: AdminAccountChange, done: String) async {
        guard let id = accountID, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await client.send(.changeAccount(id: id, change))
            record(done)
            Haptics.success()
        } catch {
            reportError(error)
        }
    }

    func dropFromWaitlist() async {
        guard let id = accountID, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await client.send(.dropFromWaitlist(id: id))
            record("Removed \(shortID) from the waitlist.")
            Haptics.success()
        } catch {
            reportError(error)
        }
    }

    func deleteAccount() async -> Bool {
        guard let id = accountID, !isWorking else { return false }
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await client.send(.deleteAccount(id: id))
            record("Deleted the account \(shortID).")
            idText = ""
            Haptics.success()
            return true
        } catch {
            reportError(error)
            return false
        }
    }

    private func record(_ line: String) {
        log.insert(line, at: 0)
        if log.count > 6 { log.removeLast() }
    }
}

#if DEBUG
enum AdminFixtures {
    static var invites: [AdminInvite] {
        let now = Date()
        return [
            AdminInvite(id: "i3", code: "HV-K7QM-2XPA", note: "Launch batch", maxUses: 25, useCount: 9, createdAt: now.addingTimeInterval(-3_600)),
            AdminInvite(id: "i2", code: "HV-9TRD-WEHN", note: "For Sam", maxUses: 1, useCount: 1, createdAt: now.addingTimeInterval(-86_400 * 3)),
            AdminInvite(id: "i1", code: "HV-4CFB-Y8LZ", note: nil, maxUses: 5, useCount: 0, disabled: true, createdAt: now.addingTimeInterval(-86_400 * 9)),
        ]
    }
}

extension AdminModel {
    /// Fills the model the way an earlier visit would have, for previews and snapshots.
    func previewSeed(minted: AdminInvite? = nil) {
        var book = AdminInviteBook()
        for invite in AdminFixtures.invites { book.upsert(invite) }
        self.book = book
        justMinted = minted
    }
}
#endif
