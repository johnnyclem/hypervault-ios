import SwiftUI
import XCTest
@testable import HyperVault

/// Dictation holds the microphone, lowers other audio and rewrites the draft, so it must end when the canvas is not what
/// the person is looking at.
final class CanvasDictationPolicyTests: XCTestCase {
    func testDictationGoesOnWhileTheCanvasIsInFrontAndTheAppIsActive() {
        XCTAssertFalse(DictationPolicy.mustStop(tab: .canvas, isCovered: false, phase: .active))
    }

    func testAnotherTabEndsIt() {
        for tab in AppTab.allCases where tab != .canvas {
            XCTAssertTrue(DictationPolicy.mustStop(tab: tab, isCovered: false, phase: .active), "\(tab)")
        }
    }

    func testASheetOrACoverOverTheCanvasEndsIt() {
        XCTAssertTrue(DictationPolicy.mustStop(tab: .canvas, isCovered: true, phase: .active))
    }

    func testLeavingTheAppEndsItButAPassingInterruptionDoesNot() {
        XCTAssertTrue(DictationPolicy.mustStop(tab: .canvas, isCovered: false, phase: .background))
        XCTAssertFalse(DictationPolicy.mustStop(tab: .canvas, isCovered: false, phase: .inactive), "Control Center and alerts pass through here")
    }
}
