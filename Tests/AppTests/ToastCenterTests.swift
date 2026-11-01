import HyperVaultKit
import XCTest
@testable import HyperVault

/// A toast is the app's one channel for results, so it has to reach people who do not see it appear.
@MainActor
final class ToastCenterTests: XCTestCase {
    private func make(assistive: Bool = false) -> (center: ToastCenter, speech: RecordingAnnouncer) {
        let speech = RecordingAnnouncer()
        return (ToastCenter(announcer: speech, usesAssistiveTechnology: { assistive }), speech)
    }

    func testAToastIsSpokenAsWellAsShown() {
        let (center, speech) = make()
        center.success("Link copied.")
        XCTAssertEqual(center.current?.message, "Link copied.")
        XCTAssertEqual(speech.spoken, ["Link copied."])
    }

    func testAnErrorIsSpokenAsAnError() {
        let (center, speech) = make()
        center.show("That could not be kept. Try again.", style: .error)
        XCTAssertEqual(speech.spoken, ["Error. That could not be kept. Try again."])
        XCTAssertEqual(center.current?.style, .error)
    }

    func testAnErrorFromTheServerIsSpokenInTheServersWords() {
        let (center, speech) = make()
        center.show(error: HVError.api(APIFailure(status: 429, message: "Slow down a little.")))
        XCTAssertEqual(speech.spoken.count, 1)
        XCTAssertTrue(speech.spoken[0].hasPrefix("Error. "))
        XCTAssertTrue(speech.spoken[0].contains("Slow down a little."))
    }

    func testACancelledRequestSaysNothing() {
        let (center, speech) = make()
        center.show(error: HVError.cancelled)
        center.show(error: CancellationError())
        XCTAssertNil(center.current)
        XCTAssertTrue(speech.spoken.isEmpty)
    }

    func testEachToastIsSpokenOnce() {
        let (center, speech) = make()
        center.show("One")
        center.show("Two")
        XCTAssertEqual(speech.spoken, ["One", "Two"])
    }

    func testAToastStaysUpLongerForVoiceOverAndSwitchControl() {
        XCTAssertEqual(ToastCenter.hold(style: .info, message: "Copied.", assistive: false), 3)
        XCTAssertEqual(ToastCenter.hold(style: .error, message: "Nope.", assistive: false), 4.5)
        XCTAssertEqual(ToastCenter.hold(style: .info, message: "Copied.", assistive: true), 10)
        XCTAssertEqual(ToastCenter.hold(style: .error, message: "Nope.", assistive: true), 10)
    }

    /// The host sits at the top of the safe area, which is where the navigation bar's buttons are, so a toast that began
    /// there would hide the button a person reaches for next. It starts under the bar, and the bar is 44 points.
    func testTheToastBeginsBelowTheNavigationBar() {
        XCTAssertGreaterThanOrEqual(ToastHost.barHeight, 44)
    }

    func testALongMessageGetsTimeToBeSpokenButNotForever() {
        let long = String(repeating: "word ", count: 30)
        let held = ToastCenter.hold(style: .error, message: long, assistive: true)
        XCTAssertGreaterThan(held, 10)
        XCTAssertEqual(ToastCenter.hold(style: .error, message: String(repeating: "x", count: 4000), assistive: true), 20)
    }
}
