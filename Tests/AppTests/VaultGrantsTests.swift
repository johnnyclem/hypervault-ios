import XCTest
@testable import HyperVault

final class VaultGrantsTests: XCTestCase {
    func testASwitchSetsOnlyItself() {
        let start = VaultGrantsPhase.loaded(["a"])
        XCTAssertEqual(start.setting("b", to: true).granted, ["a", "b"])
        XCTAssertEqual(start.setting("a", to: false).granted, [])
        XCTAssertEqual(start.setting("a", to: true), start, "already on")
    }

    func testAFailedSwitchGoesBackWithoutUndoingOneTurnedAndAcceptedSince() {
        // Key A is turned on and its request is slow. Key B is turned on and accepted. Then A is refused.
        var phase = VaultGrantsPhase.loaded([])
        phase = phase.setting("a", to: true)
        phase = phase.setting("b", to: true)
        phase = phase.setting("a", to: false)
        XCTAssertEqual(phase.granted, ["b"], "the server holds B, and the switch must say so")
    }

    func testTwoFailuresInARowEachPutBackOnlyTheirOwnSwitch() {
        var phase = VaultGrantsPhase.loaded(["c"])
        phase = phase.setting("a", to: true)
        phase = phase.setting("b", to: true)
        phase = phase.setting("a", to: false)
        phase = phase.setting("b", to: false)
        XCTAssertEqual(phase.granted, ["c"], "A is not left on because B's snapshot had it on")
    }

    func testNothingIsSetWhileTheKeysAreLoadingOrWhenTheyFailedToLoad() {
        XCTAssertEqual(VaultGrantsPhase.loading.setting("a", to: true), .loading)
        XCTAssertEqual(VaultGrantsPhase.failed.setting("a", to: false), .failed)
    }
}
