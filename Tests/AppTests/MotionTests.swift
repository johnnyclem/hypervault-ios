import SwiftUI
import XCTest
@testable import HyperVault

/// Motion is the web's (handoff 2.6): one ease-out family in three lengths (a press 0.15s, an entrance 0.2s, a sheet 0.3s),
/// the copied state lasts 1.5s, and Reduce Motion turns every custom animation off.
@MainActor
final class MotionTests: XCTestCase {
    func testAnEntranceIsEaseOutOverTwoTenthsOfASecond() {
        XCTAssertEqual(HV.Motion.entrance, Animation.easeOut(duration: 0.2))
    }

    func testAPressIsEaseOutOverFifteenHundredthsOfASecond() {
        XCTAssertEqual(HV.Motion.press, Animation.easeOut(duration: 0.15))
    }

    func testASheetIsEaseOutOverThreeTenthsOfASecond() {
        XCTAssertEqual(HV.Motion.sheet, Animation.easeOut(duration: 0.3))
    }

    func testTheCopiedStateLastsAsLongAsTheWebs() {
        XCTAssertEqual(HV.Motion.copiedHold, 1.5)
    }

    func testReduceMotionTakesTheAnimationAway() {
        XCTAssertNil(HV.Motion.resolved(.snappy, reduceMotion: true))
        XCTAssertNil(HV.Motion.resolved(nil, reduceMotion: true))
        XCTAssertEqual(HV.Motion.resolved(.snappy, reduceMotion: false), Animation.snappy)
        XCTAssertNil(HV.Motion.resolved(nil, reduceMotion: false))
    }

    func testAnimateStillMakesTheChange() {
        var changed = false
        HV.Motion.animate {
            changed = true
        }
        XCTAssertTrue(changed)
    }
}
