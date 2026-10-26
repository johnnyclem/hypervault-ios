import XCTest

/// Signed in but not let in: the waitlist, a refused code, and a code that opens the door.
@MainActor
final class WaitlistJourneyTests: HyperVaultUITestCase {
    func testTheWaitlistRefusesAWrongCodeAndAcceptsTheRightOne() {
        launch(.waitlisted)

        step("The waitlist greets the person by name") {
            let title = element("waitlist.title")
            require(title, "the waitlist's title")
            XCTAssertEqual(title.label, "You're on the list, Sam.")
            require(element("waitlist.redeem"), "the Use this code button")
            XCTAssertFalse(element("waitlist.redeem").isEnabled, "With no code typed, there is nothing to use.")
        }

        step("Check again says they are still waiting") {
            tap(element("waitlist.check"), "Check again")
            require(element("waitlist.status"), "the line that says they are still waiting")
            XCTAssertTrue(element("waitlist.status").label.hasPrefix("Still waiting"), "It says \"\(element("waitlist.status").label)\".")
        }

        step("The field takes a code, and a wrong one is refused") {
            let code = textField("waitlist.code")
            enter("HV-NOPE-NOPE", into: code, "the invite code field")
            waitUntil("the Use this code button to turn on, now that a code is typed") { element("waitlist.redeem").isEnabled }
            tap(element("waitlist.redeem"), "Use this code")
            let message = element("waitlist.message")
            require(message, "the line that refuses the code")
            XCTAssertEqual(message.label, "That invite code doesn't exist. Double-check for typos.")
            require(element("waitlist.title"), "the waitlist, which a refused code should leave them on")
        }

        step("The right code opens the door to the canvas") {
            let code = textField("waitlist.code")
            tap(code, "the invite code field")
            clear(code)
            code.typeText("HV-OPEN-DOOR")
            tap(element("waitlist.redeem"), "Use this code")
            require(element("canvas.field"), "the canvas, once the code is accepted")
            requireGone(element("waitlist.code"), "the waitlist")
        }
    }
}
