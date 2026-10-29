import Foundation

// The Account menu: the drawer the web's Home opens from the corner mark (components/canvas/account-menu.tsx), in the
// web's words (lib/copy.ts `MENU_*`, lib/mail/copy.ts). The app's tab bar carries Home, Chat, Memory and You, so the menu
// holds what the tab bar does not ("this menu carries what the dock doesn't", components/mobile-nav.tsx): the web's
// Memory and Chat history rows are left out. A signed-out drawer's Pricing and Sign in are not here either: signed out,
// the app is the first-run flow.

public enum AccountMenu {
    public static let title = "Account"
    public static let library = "Library"
    public static let mail = "Mail"
    /// App only: the web reaches task boards from the Mail and Library screens.
    public static let taskBoards = "Task boards"
    /// The You page again, as the menu names it (`MENU_ACCOUNT_AND_KEYS`). It opens on the vault, as `/vault/account` does.
    public static let accountAndKeys = "Account & keys"
    public static let groupChats = "Group chats"
    public static let tools = "Tools"
    public static let importAnything = "Import"
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
