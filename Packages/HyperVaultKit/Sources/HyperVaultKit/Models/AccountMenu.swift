import Foundation

// The Account menu: the drawer the web's Home opens from the corner mark (components/canvas/account-menu.tsx), in the
// web's words (lib/copy.ts `MENU_*`, lib/mail/copy.ts). The app's tab bar carries Home, Projects, Memory and Mail, so the
// menu holds what the tab bar does not ("this menu carries what the dock doesn't", components/mobile-nav.tsx): Settings
// (the account, its keys and the rest of what used to be the You tab), the Library, Group chats, Tools, the Beta features,
// Admin for an admin, and signing out. The web's Memory and Chat history rows are left out. A signed-out drawer's Pricing
// and Sign in are not here either: signed out, the app is the first-run flow.

public enum AccountMenu {
    public static let title = "Account"
    /// App only: the first row, and the name of the list of panes it opens (the web's You page, `/vault/account`, which the
    /// menu there calls "Account & keys"). It is also the pane list's navigation title.
    public static let settings = "Settings"
    public static let library = "Library"
    /// The Mail tab's name, and the word on its unread badge's label.
    public static let mail = "Mail"
    public static let groupChats = "Group chats"
    public static let tools = "Tools"
    public static let beta = "Beta"
    public static let dreams = "Dreams"
    public static let truth = "Truth"
    public static let admin = "Admin"
    public static let signOut = "Sign out"

    /// The most the badge counts to before it says "99+" (`BADGE_MAX`).
    public static let badgeMax = 99

    /// What VoiceOver says for the Mail badge (`mailBadgeLabel`).
    public static func mailBadgeLabel(_ count: Int) -> String { "\(count) unread" }

    /// What VoiceOver says for the badge on Dreams (`dream_connections` waiting) and on Memory's More (those and the digest's
    /// proposals): how many are waiting for the person to decide.
    public static func pendingBadgeLabel(_ count: Int) -> String { "\(count) waiting for review" }

    /// What the badge shows.
    public static func badgeText(_ count: Int) -> String { count > badgeMax ? "\(badgeMax)+" : "\(count)" }
}
