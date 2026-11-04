import XCTest
import HyperVaultKit
@testable import HyperVault

/// The number on the Mail tab: read by the tab bar itself (a tab's first screen is not built until it is visited), and
/// corrected by the inbox once that has loaded.
@MainActor
final class MailUnreadTests: XCTestCase {
    func testTheTabStartsWithNothingToCount() {
        XCTAssertEqual(MailUnread().count, 0)
    }

    func testTheTabCountsTheUnreadMailOfEveryMailbox() async {
        let env = AppEnvironment.preview(routes: MailPreviewData.routes)
        let unread = MailUnread()
        await unread.refresh(client: env.client)
        XCTAssertEqual(unread.count, 2, "the preview mailboxes hold two and none")
    }

    func testWhatTheInboxFoundReplacesTheNumber() {
        let unread = MailUnread()
        unread.set(5)
        XCTAssertEqual(unread.count, 5)
        unread.set(0)
        XCTAssertEqual(unread.count, 0)
    }

    func testAServerWithoutMailShowsNoNumber() async {
        let env = AppEnvironment.preview(routes: MailPreviewData.unavailableRoutes)
        let unread = MailUnread()
        unread.set(3)
        await unread.refresh(client: env.client)
        XCTAssertEqual(unread.count, 0, "mail that is not set up has nothing unread to show")
    }

    func testAReadThatCannotBeAnsweredLeavesTheNumberAsItWas() async {
        // No route answers, so the read fails; a number the person was shown does not vanish for it.
        let env = AppEnvironment.preview(routes: [])
        let unread = MailUnread()
        unread.set(4)
        await unread.refresh(client: env.client)
        XCTAssertEqual(unread.count, 4)
    }
}
