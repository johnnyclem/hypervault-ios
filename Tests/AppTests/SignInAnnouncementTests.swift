import AuthenticationServices
import HyperVaultKit
import XCTest
@testable import HyperVault

/// A line about a failed sign-in appears without moving VoiceOver focus, so it has to be said as well as shown.
@MainActor
final class SignInAnnouncementTests: XCTestCase {
    private func make(_ routes: [MockRoute] = []) -> (controller: SignInController, speech: CoreRecordingAnnouncer) {
        let speech = CoreRecordingAnnouncer()
        let auth = AuthService(
            config: SupabaseConfig(url: URL(string: "https://proj.supabase.test")!, anonKey: "anon"),
            transport: MockTransport(routes: routes),
            store: InMemorySecureStore()
        )
        return (SignInController(auth: auth, announcer: speech), speech)
    }

    func testAnEmailThatIsNotOneIsSaidAndShown() async {
        let (controller, speech) = make()
        let sent = await controller.sendEmailCode("sam")
        XCTAssertFalse(sent)
        XCTAssertEqual(controller.message, "Enter the email you want to sign in with.")
        XCTAssertEqual(speech.spoken, ["Enter the email you want to sign in with."])
    }

    func testACodeTheServerRefusesIsSaidInThePagesWords() async {
        let (controller, speech) = make([
            .json(.post, "/auth/v1/otp", "{}"),
            .failure(.post, "/auth/v1/verify", status: 400, message: "Token has expired or is invalid"),
        ])
        let sent = await controller.sendEmailCode("sam@example.com")
        XCTAssertTrue(sent)
        XCTAssertTrue(speech.spoken.isEmpty, "a code that was sent is not bad news")

        await controller.verifyEmailCode("123456")
        XCTAssertEqual(controller.message, "That code has expired. Ask for a new one.")
        XCTAssertEqual(speech.spoken, ["That code has expired. Ask for a new one."])
    }

    func testACodeThatCouldNotBeSentIsSaid() async {
        let (controller, speech) = make([.failure(.post, "/auth/v1/otp", status: 429, message: "Email rate limit exceeded")])
        let sent = await controller.sendEmailCode("sam@example.com")
        XCTAssertFalse(sent)
        XCTAssertNotNil(controller.message)
        XCTAssertEqual(speech.spoken, [controller.message ?? ""])
    }

    func testAnAppleSignInThatDidNotFinishIsSaid() async {
        let (controller, speech) = make()
        await controller.handleApple(.failure(ASAuthorizationError(.failed)), rawNonce: "n")
        XCTAssertEqual(speech.spoken, ["Sign in with Apple did not finish. Try again."])
    }

    func testAnAppleSignInThePersonCancelledSaysNothing() async {
        let (controller, speech) = make()
        await controller.handleApple(.failure(ASAuthorizationError(.canceled)), rawNonce: "n")
        XCTAssertNil(controller.message)
        XCTAssertTrue(speech.spoken.isEmpty)
    }
}
