import XCTest
@testable import HyperVaultKit

/// components/canvas/account-menu.tsx and lib/mail/copy.ts: the words of the Account menu.
final class AccountMenuTests: XCTestCase {
    func testTheWordsAreTheWebs() {
        XCTAssertEqual(AccountMenu.title, "Account")
        XCTAssertEqual(AccountMenu.library, "Library")
        XCTAssertEqual(AccountMenu.mail, "Mail")
        XCTAssertEqual(AccountMenu.accountAndKeys, "Account & keys")
        XCTAssertEqual(AccountMenu.groupChats, "Group chats")
        XCTAssertEqual(AccountMenu.tools, "Tools")
        XCTAssertEqual(AccountMenu.importAnything, "Import")
        XCTAssertEqual(AccountMenu.beta, "Beta")
        XCTAssertEqual(AccountMenu.dreams, "Dreams")
        XCTAssertEqual(AccountMenu.truth, "Truth")
        XCTAssertEqual(AccountMenu.admin, "Admin")
        XCTAssertEqual(AccountMenu.signOut, "Sign out")
    }

    func testTheMailBadgeCountsToNinetyNineAndSaysHowManyAreUnread() {
        XCTAssertEqual(AccountMenu.badgeText(1), "1")
        XCTAssertEqual(AccountMenu.badgeText(99), "99")
        XCTAssertEqual(AccountMenu.badgeText(100), "99+")
        XCTAssertEqual(AccountMenu.mailBadgeLabel(3), "3 unread")
        XCTAssertEqual(AccountMenu.mailBadgeLabel(100), "100 unread", "VoiceOver says the whole number")
    }
}
