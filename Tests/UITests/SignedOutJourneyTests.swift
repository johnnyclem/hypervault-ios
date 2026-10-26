import XCTest

/// Nobody signed in: the welcome story, the way in, and the email code sheet. The canned auth settings offer Google and
/// email and not Apple.
@MainActor
final class SignedOutJourneyTests: HyperVaultUITestCase {
    private let pageTitles = [
        "Keep what your AI just made.",
        "You talk to your AI like usual.",
        "Not tied to one AI company.",
        "Save a login, a card or a key once.",
    ]

    func testTheStoryPlaysThroughToTheWayInAndBackAgain() {
        launch(.signedOut)
        let pages = element("welcome.pages")

        step("The story opens on its first page") {
            XCTAssertEqual(pages.label, "Page 1 of 4")
            waitUntil("the first page's words on screen") { isOnScreen(text(pageTitles[0])) }
            require(element("welcome.haveAccount"), "the \"I already have an account\" button on the first page")
        }

        for index in 1..<pageTitles.count {
            step("Continue moves to page \(index + 1)") {
                tap(element("welcome.continue"), "Continue")
                waitUntil("the dots to read page \(index + 1) of 4") { pages.label == "Page \(index + 1) of 4" }
                waitUntil("the words of page \(index + 1) on screen") { isOnScreen(text(pageTitles[index])) }
            }
        }

        step("The last page offers Get started") {
            waitUntil("the button on the last page to say Get started") { element("welcome.continue").label == "Get started" }
        }

        step("Get started leads to the way in") {
            tap(element("welcome.continue"), "Get started")
            require(text("Welcome to HyperVault"), "the sign-in screen")
            let google = element("signin.google")
            require(google, "Continue with Google")
            XCTAssertTrue(google.label.contains("Continue with Google"), "The Google button should be labelled for VoiceOver; it says \"\(google.label)\".")
            let email = element("signin.email")
            require(email, "Continue with email")
            XCTAssertTrue(email.label.contains("Continue with email"), "The email button should be labelled for VoiceOver; it says \"\(email.label)\".")
            XCTAssertFalse(element("signin.apple").exists, "The canned sign-in settings turn Apple off, so its button should be hidden.")
        }

        step("Back returns to the story") {
            tap(element("signin.back"), "the Back button")
            require(element("welcome.pages"), "the story again")
            requireGone(element("signin.google"), "the sign-in buttons")
        }
    }

    func testSkipGoesToTheWayInAndEmailOpensTheCodeSheet() {
        launch(.signedOut)

        step("Skip jumps past the story to the way in") {
            tap(element("welcome.skip"), "Skip")
            require(element("signin.email"), "Continue with email")
            require(element("signin.google"), "Continue with Google")
        }

        step("Email opens the code sheet") {
            tap(element("signin.email"), "Continue with email")
            require(text("Sign in with email"), "the email sheet's title")
            require(element("email.send"), "the Send me a code button")
            XCTAssertFalse(element("email.send").isEnabled, "There is nothing to send a code to yet, so the button should be off.")
        }

        step("An address gets a code sent") {
            let address = textField("email.address")
            enter("sam@example.com", into: address, "the email field")
            waitUntil("the Send me a code button to turn on, now that an address is typed") { element("email.send").isEnabled }
            // Return is the keyboard's Send key, as a person would press it.
            address.typeText("\n")
            require(text("Check your email"), "the sheet asking for the code")
            require(text("We sent a six-digit code to sam@example.com."), "the line saying where the code went")
        }

        step("A wrong code is turned down in plain words") {
            enter("000000", into: textField("email.code"), "the code field")
            let error = element("email.error")
            require(error, "the line that turns the code down")
            XCTAssertEqual(error.label, "That code has expired. Ask for a new one.")
        }

        step("Closing the sheet returns to the way in") {
            tap(button("Close"), "the sheet's close button")
            requireGone(text("Check your email"), "the code sheet")
            require(element("signin.email"), "the way in behind the sheet")
        }
    }
}
