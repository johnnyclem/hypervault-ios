import HyperVaultKit
import SwiftUI
import XCTest
@testable import HyperVault

/// The screens the window shows before the app: the lock, the waitlist and the way back from a server that does not answer.
@MainActor
final class RootSnapshotTests: XCTestCase {
    override func setUp() {
        super.setUp()
        SharedState.begin()
    }

    override func tearDown() {
        SharedState.end()
        super.tearDown()
    }

    func testLockScreen() throws {
        try snapshot(LockScreen(lock: AppLock()), named: "lock")
    }

    func testUnreachableOnASavedServer() throws {
        // The preview model points at a server of its own, so the way back to the default one is offered.
        try snapshot(
            PreviewHost(embedInNavigation: false) { UnreachableView(message: "Network hiccup. Check your connection and try again.") },
            named: "unreachable-saved-server"
        )
    }

    func testWaitlist() throws {
        let user = AuthUser(id: "u1", email: "sam@example.com", displayName: "Sam Rivers")
        try snapshot(PreviewHost(embedInNavigation: false) { WaitlistView(user: user) }, named: "waitlist")
    }
}
