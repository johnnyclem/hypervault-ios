import XCTest
@testable import HyperVault

/// What tells a first launch after an install from every other launch, so the Keychain's leftover session is ended once.
final class InstallMarkerTests: XCTestCase {
    private func preferences() -> UserDefaults {
        let suite = "hv.test.marker.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testAPhoneThatHasNeverRunTheAppIsANewInstallUntilItIsMarked() {
        let defaults = preferences()
        let marker = InstallMarker(defaults: defaults)
        XCTAssertTrue(marker.isNewInstall)
        marker.mark()
        XCTAssertFalse(marker.isNewInstall)
        XCTAssertFalse(InstallMarker(defaults: defaults).isNewInstall, "the mark is in the preferences, not in the value")
    }

    func testAnUpdateFromABuildWithoutTheMarkerIsNotANewInstall() {
        let defaults = preferences()
        defaults.set(true, forKey: PrefKey.onboarded)
        XCTAssertFalse(InstallMarker(defaults: defaults).isNewInstall, "the story was seen on this phone, so someone signed in here")
    }

    func testMarkingChangesNothingElseInThePreferences() {
        let defaults = preferences()
        defaults.set(true, forKey: PrefKey.haptics)
        InstallMarker(defaults: defaults).mark()
        XCTAssertNil(defaults.object(forKey: PrefKey.onboarded), "a new install is not taken for one that has seen the story")
        XCTAssertEqual(defaults.bool(forKey: PrefKey.haptics), true)
    }
}
