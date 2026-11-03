import HyperVaultKit
import SwiftUI

/// The person's avatar in the corner of a tab's first screen. It opens the Account sheet: the menu that holds what the tab
/// bar does not, and Settings. Every tab's first screen carries one, because that sheet is the only way in to Settings.
///
/// There is one control, so the label and the identifier are the same everywhere: tests and VoiceOver find "Account" on
/// whichever tab shows. It is attached by each first screen (`accountAvatar()`) and not by `TabRoot`, because Memory's bar
/// has a leading item of its own and two leading items from separate `.toolbar` modifiers have no promised order.
struct AccountAvatarButton: View {
    @Environment(AppModel.self) private var app
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        Button {
            app.router.showAccountMenu()
        } label: {
            HVAvatar(
                name: env.user.displayName ?? env.user.email ?? "?",
                imageURL: env.user.avatarUrl.flatMap(URL.init(string:)),
                size: 32
            )
        }
        .accessibilityLabel("Account")
        .accessibilityIdentifier("account.avatar")
    }
}

extension View {
    /// The avatar alone in the leading slot of this screen's bar.
    func accountAvatar() -> some View {
        toolbar {
            ToolbarItem(placement: .topBarLeading) { AccountAvatarButton() }
        }
    }
}
