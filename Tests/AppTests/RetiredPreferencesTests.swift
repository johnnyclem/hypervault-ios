import XCTest
@testable import HyperVault

/// The app used to store a person's appearance and accent. They are gone, so what an earlier version left behind is
/// removed, and nothing else.
final class RetiredPreferencesTests: XCTestCase {
    func testTheOldLookPreferencesAreRemovedAndTheOthersKept() throws {
        let suite = "hv.test.retired.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("light", forKey: "pref.appearance")
        defaults.set("rose", forKey: "pref.accent")
        defaults.set(false, forKey: PrefKey.haptics)

        RetiredPreferences.remove(from: defaults)

        XCTAssertNil(defaults.object(forKey: "pref.appearance"))
        XCTAssertNil(defaults.object(forKey: "pref.accent"))
        XCTAssertEqual(defaults.object(forKey: PrefKey.haptics) as? Bool, false)
    }
}
