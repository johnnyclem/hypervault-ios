import HyperVaultKit
import SwiftUI

/// How much mail is unread, for the number on the Mail tab. A tab's first screen is built when the tab is first shown, so
/// the number cannot wait for Mail to load: the tab bar reads it itself (`refresh`) when the app opens, comes to the front
/// and when the person leaves Mail, with the one route the Account menu used to read when it opened. Nothing polls it.
/// While Mail shows, its own list is the truth and pushes the count here (`set`).
@MainActor
@Observable
final class MailUnread {
    private(set) var count = 0
    /// The server has no mail at all (`mail_unavailable`): asking again would only get the same answer.
    @ObservationIgnored private var unavailable = false

    func refresh(client: HVClient) async {
        guard !unavailable else { return }
        do {
            count = try await client.send(.mailMailboxes).totalUnread
        } catch let error as HVError where error.isMailUnavailable {
            unavailable = true
            count = 0
        } catch {
            // A read that failed leaves the number as it was.
        }
    }

    func set(_ count: Int) {
        self.count = count
    }
}
