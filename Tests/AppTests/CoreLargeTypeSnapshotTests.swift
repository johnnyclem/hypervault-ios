import HyperVaultKit
import SwiftUI
import XCTest
@testable import HyperVault

/// The screens whose filter or choice is a segmented control at ordinary sizes, drawn at the largest accessibility
/// type, where it becomes a menu whose words grow with the rest of the screen.
@MainActor
final class CoreLargeTypeSnapshotTests: XCTestCase {
    override func setUp() {
        super.setUp()
        SharedState.begin()
    }

    override func tearDown() {
        SharedState.end()
        super.tearDown()
    }

    func testYoursAtTheLargestType() throws {
        try snapshot(
            PreviewHost(routes: [.json(.get, "/api/yours", Fixtures.yours)]) { YoursRootView().environment(\.dynamicTypeSize, .accessibility3) },
            named: "yours-large", schemes: [.light]
        )
    }

    func testLockScreenAtTheLargestType() throws {
        try snapshot(LockScreen(lock: AppLock()).environment(\.dynamicTypeSize, .accessibility5), named: "lock-large", schemes: [.light])
    }

    func testSettingsAtTheLargestType() throws {
        try snapshot(
            PreviewHost { SettingsRootView().environment(\.dynamicTypeSize, .accessibility3) },
            named: "settings-large", schemes: [.light]
        )
    }
}
