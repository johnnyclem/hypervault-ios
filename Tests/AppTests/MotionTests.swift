import SwiftUI
import XCTest
@testable import HyperVault

/// Motion is the web's (handoff 2.6): an entrance is ease-out over 0.2s, the copied state lasts 1.5s, and Reduce Motion
/// turns every custom animation off.
@MainActor
final class MotionTests: XCTestCase {
    func testAnEntranceIsEaseOutOverTwoTenthsOfASecond() {
        XCTAssertEqual(HV.Motion.entrance, Animation.easeOut(duration: 0.2))
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
