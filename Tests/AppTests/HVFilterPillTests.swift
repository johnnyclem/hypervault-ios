import XCTest
@testable import HyperVault

/// A filter says its count when it has one and its name alone when it has none, so VoiceOver never reads a number that
/// is not drawn, and the UI tests that look a filter up by its name find the same words after a count is added or taken
/// away.
@MainActor
final class HVFilterPillTests: XCTestCase {
    func testAFilterWithACountSpeaksItAfterTheTitle() {
        XCTAssertEqual(HVFilterPill.spokenLabel(title: "Logins", count: 4), "Logins, 4")
    }

    func testAFilterWithoutACountSpeaksTheTitleAlone() {
        XCTAssertEqual(HVFilterPill.spokenLabel(title: "All", count: nil), "All")
    }

    func testAZeroIsStillACount() {
        XCTAssertEqual(HVFilterPill.spokenLabel(title: "Unread", count: 0), "Unread, 0")
    }

    /// Every call that existed before the count was optional passes one and still compiles and reads as it did.
    func testTheInitializerKeepsItsOldShape() {
        let pill = HVFilterPill(title: "All", count: 9, isSelected: true) {}
        XCTAssertEqual(pill.count, 9)
        XCTAssertTrue(pill.isSelected)
        let bare = HVFilterPill(title: "Open") {}
        XCTAssertNil(bare.count)
        XCTAssertFalse(bare.isSelected)
    }

    func testACountIsTextAndSoIsAShortFact() {
        XCTAssertEqual(HVCount(12).text, "12")
        XCTAssertEqual(HVCount("2 of 3 on").text, "2 of 3 on")
    }
}
