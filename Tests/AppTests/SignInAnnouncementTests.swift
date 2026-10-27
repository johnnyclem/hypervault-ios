import AuthenticationServices
import HyperVaultKit
import XCTest
@testable import HyperVault

/// A line about a failed sign-in appears without moving VoiceOver focus, so it has to be said as well as shown.
@MainActor
final class SignInAnnouncementTests: XCTestCase {
    private func make(_ routes: [MockRoute] = []) -> (controller: SignInController, speech: RecordingAnnouncer) {
        let speech = RecordingAnnouncer()
        let auth = AuthService(
            config: SupabaseConfig(url: URL(string: "https://proj.supabase.test")!, anonKey: "anon"),
            transport: MockTransport(routes: routes),
            store: InMemorySecureStore()
        )
        return (SignInController(auth: auth, announcer: speech), speech)
    }

    func testGoogleReturnsThroughTheWebsiteSoTheSheetCanClose() {
        let url = SignInController.oauthRedirect(on: URL(string: "https://www.claudedamnit.com/vault?x=1")!)
        XCTAssertEqual(url.absoluteString, "https://www.claudedamnit.com/auth/callback?client=app")
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
        XCTAssertEqual(controller.message, "That code did not work, or it has expired. Check it, or ask for a new one.")
        XCTAssertEqual(speech.spoken, ["That code did not work, or it has expired. Check it, or ask for a new one."])
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

/// Google sign-in asks the website whether it will hand the code back to the app before it opens the sheet: a
/// site that will not leaves the person on its own login page, inside the sheet, with no way to the app.
@MainActor
final class GoogleHandoffTests: XCTestCase {
    private static let tokenJSON = """
    {"access_token":"A1","token_type":"bearer","expires_in":3600,"expires_at":4000000000,"refresh_token":"R1",
     "user":{"id":"u1","email":"sam@example.com","app_metadata":{"provider":"google"},"user_metadata":{"full_name":"Sam Rivers"}}}
    """

    /// What the stand-in for the sign-in sheet was asked to open, and what the website would send it back with.
    private final class Sheet {
        var opened: [URL] = []
        let answer = URL(string: "hypervault://auth/callback?code=real-code")!
    }

    private func callbackPage(_ status: Int, location: String? = nil) -> MockRoute {
        MockRoute(.get, "/auth/callback") { _ in
            HTTPResponse(status: status, headers: location.map { ["Location": $0] } ?? [:])
        }
    }

    private func make(page: MockRoute) -> (controller: SignInController, auth: AuthService, speech: RecordingAnnouncer, sheet: Sheet) {
        let auth = AuthService(
            config: SupabaseConfig(url: URL(string: "https://proj.supabase.test")!, anonKey: "anon"),
            transport: MockTransport(routes: [.json(.post, "/auth/v1/token", Self.tokenJSON), page]),
            store: InMemorySecureStore()
        )
        let speech = RecordingAnnouncer()
        let sheet = Sheet()
        let controller = SignInController(
            auth: auth,
            oauthOrigin: URL(string: "https://hypervault.store")!,
            announcer: speech,
            sheet: { url in
                sheet.opened.append(url)
                return sheet.answer
            }
        )
        return (controller, auth, speech, sheet)
    }

    func testASiteThatHandsTheSignInBackOpensTheSheetAndSignsIn() async throws {
        let (controller, auth, speech, sheet) = make(page: callbackPage(302, location: "hypervault://auth/callback?code=handoff-check"))
        await controller.signInWithGoogle()

        XCTAssertEqual(sheet.opened.count, 1)
        let opened = try XCTUnwrap(sheet.opened.first)
        let parts = try XCTUnwrap(URLComponents(url: opened, resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.host, "proj.supabase.test")
        XCTAssertEqual(parts.path, "/auth/v1/authorize")
        let query = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["provider"], "google")
        XCTAssertEqual(query["redirect_to"], "https://hypervault.store/auth/callback?client=app", "Supabase is asked to return through the website, not to the scheme")
        XCTAssertNotNil(query["code_challenge"])
        XCTAssertNil(controller.message)
        XCTAssertTrue(speech.spoken.isEmpty)
        let user = await auth.currentUser
        XCTAssertEqual(user?.id, "u1")
    }

    func testASiteThatCannotHandItBackIsSaidAndNoSheetOpens() async {
        let (controller, auth, speech, sheet) = make(page: callbackPage(302, location: "https://hypervault.store/login?error=auth&reason=verifier"))
        await controller.signInWithGoogle()

        XCTAssertTrue(sheet.opened.isEmpty, "the sheet would have stranded the person on the website's login page")
        XCTAssertEqual(controller.message, SignInController.handoffMissingMessage)
        XCTAssertEqual(speech.spoken, [SignInController.handoffMissingMessage])
        XCTAssertEqual(controller.work, .idle)
        let user = await auth.currentUser
        XCTAssertNil(user)
    }

    func testTappingGoogleAgainGoesAheadSoAWrongCheckCannotLockItOut() async {
        let (controller, auth, speech, sheet) = make(page: callbackPage(200))
        await controller.signInWithGoogle()
        XCTAssertTrue(sheet.opened.isEmpty)
        XCTAssertEqual(speech.spoken.count, 1)

        await controller.signInWithGoogle()
        XCTAssertEqual(sheet.opened.count, 1)
        XCTAssertNil(controller.message)
        XCTAssertEqual(speech.spoken.count, 1, "nothing more to say once it has gone ahead")
        let user = await auth.currentUser
        XCTAssertEqual(user?.id, "u1")
    }

    func testAnAnswerThatIsNoAnswerGoesAheadWithoutAWarning() async {
        let (controller, _, speech, sheet) = make(page: callbackPage(503))
        await controller.signInWithGoogle()

        XCTAssertEqual(sheet.opened.count, 1)
        XCTAssertNil(controller.message)
        XCTAssertTrue(speech.spoken.isEmpty)
    }
}
