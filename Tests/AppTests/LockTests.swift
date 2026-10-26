import HyperVaultKit
import XCTest
@testable import HyperVault

/// What the Face ID lock holds back from the places that cannot ask for Face ID: the widgets, Spotlight and Siri.
@MainActor
final class LockTests: XCTestCase {
    override func setUp() {
        super.setUp()
        SharedState.begin()
    }

    override func tearDown() {
        SharedState.end()
        super.tearDown()
    }

    func testTurningTheLockOnTellsTheWidgetsAndTakesBackWhatTheyKept() {
        SharedConfig.defaults.set(Data("[]".utf8), forKey: SharedConfig.widgetRecentKey)
        let lock = AppLock()
        XCTAssertFalse(SharedConfig.isLockOn)

        lock.preferenceChanged(to: true)
        XCTAssertTrue(SharedConfig.isLockOn)
        XCTAssertNil(SharedConfig.defaults.object(forKey: SharedConfig.widgetRecentKey))

        lock.preferenceChanged(to: false)
        XCTAssertFalse(SharedConfig.isLockOn)
    }

    func testALockThatWasAlreadyOnIsCopiedForTheWidgetsAtLaunch() {
        UserDefaults.standard.set(true, forKey: PrefKey.biometricLock)
        SharedConfig.isLockOn = false
        let lock = AppLock()
        XCTAssertTrue(lock.isLocked)
        XCTAssertTrue(SharedConfig.isLockOn)
    }

    func testSpotlightHoldsNothingWhileTheLockIsOn() {
        UserDefaults.standard.set(true, forKey: SpotlightIndexer.preferenceKey)
        XCTAssertTrue(SpotlightIndexer.isEnabled)

        UserDefaults.standard.set(true, forKey: PrefKey.biometricLock)
        XCTAssertFalse(SpotlightIndexer.isEnabled)

        // The choice itself is kept, and comes back with the lock off.
        UserDefaults.standard.set(false, forKey: PrefKey.biometricLock)
        XCTAssertTrue(SpotlightIndexer.isEnabled)
    }

    private let keptJSON = #"{"slug":"call-the-dentist-855py2","url":"https://hv.test/a/call-the-dentist-855py2","kind":"page","form":"note","title":"Call the dentist.","visibility":"private","duplicate":true,"message":"Already kept."}"#

    private func signedInClient(_ mock: MockTransport) -> HVClient {
        HVClient(baseURL: URL(string: "https://hv.test")!, transport: mock, tokens: StaticTokenProvider("t"))
    }

    func testSiriKeepsNothingWhileTheLockIsOnAndSaysNothingAboutTheVault() async throws {
        let mock = MockTransport(routes: [.json(.post, "/api/keep", keptJSON)])
        SharedConfig.isLockOn = true

        let outcome = try await KeepTextIntent.keep("Call the dentist.", using: signedInClient(mock))

        let sent = await mock.requests(matching: "/api/keep")
        XCTAssertTrue(sent.isEmpty, "nothing reaches the vault, so there is nothing to learn from the answer")
        XCTAssertEqual(OutboxStore.load().map(\.content), ["Call the dentist."])
        XCTAssertEqual(outcome.link, "")
        XCTAssertFalse(outcome.line.contains("Already"))
    }

    func testSiriKeepsAsBeforeWhileTheLockIsOff() async throws {
        let mock = MockTransport(routes: [.json(.post, "/api/keep", keptJSON)])

        let outcome = try await KeepTextIntent.keep("Call the dentist.", using: signedInClient(mock))

        let sent = await mock.requests(matching: "/api/keep")
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(OutboxStore.count, 0)
        XCTAssertTrue(outcome.link.hasSuffix("/a/call-the-dentist-855py2"))
        XCTAssertEqual(outcome.line, HVCopy.alreadyKeptLine)
    }
}
