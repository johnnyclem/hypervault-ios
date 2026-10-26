import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HyperVaultKit

/// A Google sign-in returns through the website, which hands the code on to the app. These pin the address the
/// app asks for and the check that the website will do it, because a site that will not leaves the person in the
/// sign-in sheet on its own login page.
final class AppHandoffTests: XCTestCase {
    private let site = URL(string: "https://www.claudedamnit.com")!

    private func page(_ status: Int, location: String? = nil, body: String = "") -> MockRoute {
        MockRoute(.get, "/auth/callback") { _ in
            HTTPResponse(status: status, headers: location.map { ["Location": $0] } ?? [:], data: Data(body.utf8))
        }
    }

    private func verdict(_ route: MockRoute, returnURL: URL? = nil) async -> AppHandoff.Verdict {
        await AppHandoff.check(returnURL: returnURL ?? AppHandoff.returnURL(on: site), transport: MockTransport(routes: [route]))
    }

    // MARK: The address Supabase is asked to return to

    func testTheReturnAddressIsTheWebsitesCallbackToldItIsTheApp() {
        XCTAssertEqual(AppHandoff.returnURL(on: site).absoluteString, "https://www.claudedamnit.com/auth/callback?client=app")
    }

    func testTheReturnAddressKeepsTheHostAndPortAndDropsAnythingElse() {
        let origin = URL(string: "https://self.hosted.test:8443/vault/home?x=1#frag")!
        XCTAssertEqual(AppHandoff.returnURL(on: origin).absoluteString, "https://self.hosted.test:8443/auth/callback?client=app")
    }

    func testTheAppsOwnAddressIsTheSchemeTheSheetListensFor() {
        XCTAssertEqual(AppHandoff.callback.absoluteString, "hypervault://auth/callback")
    }

    // MARK: A site that hands the sign-in back

    func testARedirectToTheAppIsReady() async {
        let result = await verdict(page(302, location: "hypervault://auth/callback?code=handoff-check"))
        XCTAssertEqual(result, .ready)
    }

    func testAnyRedirectStatusToTheAppIsReady() async {
        for status in [301, 302, 303, 307, 308] {
            let result = await verdict(page(status, location: "hypervault://auth/callback?code=handoff-check"))
            XCTAssertEqual(result, .ready, "status \(status)")
        }
    }

    func testTheHeaderNameIsNotCaseSensitive() async {
        let route = MockRoute(.get, "/auth/callback") { _ in
            HTTPResponse(status: 302, headers: ["LOCATION": "hypervault://auth/callback?code=x"])
        }
        let result = await verdict(route)
        XCTAssertEqual(result, .ready)
    }

    func testItAsksTheCallbackPageWithAMadeUpCodeAndNothingElse() async throws {
        let transport = MockTransport(routes: [page(302, location: "hypervault://auth/callback")])
        _ = await AppHandoff.check(returnURL: AppHandoff.returnURL(on: site), transport: transport)

        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        let url = try XCTUnwrap(requests.first?.url)
        XCTAssertEqual(url.host, "www.claudedamnit.com")
        XCTAssertEqual(url.path, "/auth/callback")
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query, ["client": "app", "code": "handoff-check"])
        XCTAssertNil(requests.first?.value(forHTTPHeaderField: "Authorization"), "no credential goes with the question")
        XCTAssertNil(requests.first?.value(forHTTPHeaderField: "apikey"))
    }

    func testAnAddressThatAlreadyHasACodeIsAskedWithTheMadeUpOneOnly() async throws {
        let transport = MockTransport(routes: [page(302, location: "hypervault://auth/callback")])
        let url = URL(string: "https://www.claudedamnit.com/auth/callback?client=app&code=real-one")!
        _ = await AppHandoff.check(returnURL: url, transport: transport)

        let requests = await transport.requests
        let sent = try XCTUnwrap(requests.first?.url?.absoluteString)
        XCTAssertFalse(sent.contains("real-one"))
        XCTAssertTrue(sent.contains("code=handoff-check"))
    }

    func testItLooksAtWhereThePageWouldSendTheBrowserNotWhereItEnds() async {
        // A transport that follows redirects would show 200 here; the one that does not shows the redirect.
        let result = await AppHandoff.check(returnURL: AppHandoff.returnURL(on: site), transport: FollowingTransport())
        XCTAssertEqual(result, .ready, "the check must ask for the first answer, not the last")
    }

    // MARK: A site that does not

    func testTheWebsitesOwnLoginPageIsMissing() async {
        let result = await verdict(page(302, location: "https://www.claudedamnit.com/login?error=auth&reason=verifier"))
        XCTAssertEqual(result, .missing)
    }

    func testAPageThatAnswersWithoutRedirectingIsMissing() async {
        for status in [200, 204, 400, 401, 403, 404] {
            let result = await verdict(page(status, body: "<html>sign in</html>"))
            XCTAssertEqual(result, .missing, "status \(status)")
        }
    }

    func testARedirectWithoutALocationIsMissing() async {
        let result = await verdict(page(302))
        XCTAssertEqual(result, .missing)
    }

    func testARedirectToSomewhereElseInTheAppsSchemeIsMissing() async {
        for location in ["hypervault://auth/other", "hypervault://elsewhere/callback", "otherapp://auth/callback", "https://hypervault.store/auth/callback"] {
            let result = await verdict(page(302, location: location))
            XCTAssertEqual(result, .missing, location)
        }
    }

    // MARK: No answer worth acting on

    func testAServerErrorSaysNothingAboutThePage() async {
        for status in [500, 502, 503, 504] {
            let result = await verdict(page(status))
            XCTAssertEqual(result, .unknown, "status \(status)")
        }
    }

    func testNoConnectionSaysNothingAboutThePage() async {
        let result = await AppHandoff.check(returnURL: AppHandoff.returnURL(on: site), transport: OfflineTransport())
        XCTAssertEqual(result, .unknown)
    }

    func testAnAuthServiceAsksThroughItsOwnTransport() async {
        let transport = MockTransport(routes: [page(302, location: "hypervault://auth/callback?code=handoff-check")])
        let auth = AuthService(
            config: SupabaseConfig(url: URL(string: "https://proj.supabase.test")!, anonKey: "anon-key"),
            transport: transport,
            store: InMemorySecureStore()
        )
        let result = await auth.appHandoff(returnURL: AppHandoff.returnURL(on: site))
        XCTAssertEqual(result, .ready)
    }
}

/// Answers `send` as a client that followed the redirect would (the login page, 200) and `sendWithoutRedirect` with
/// the redirect itself.
private struct FollowingTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        HTTPResponse(status: 200, headers: [:], data: Data("<html>login</html>".utf8))
    }

    func sendWithoutRedirect(_ request: URLRequest) async throws -> HTTPResponse {
        HTTPResponse(status: 302, headers: ["Location": "hypervault://auth/callback?code=handoff-check"])
    }
}

private struct OfflineTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> HTTPResponse { throw URLError(.notConnectedToInternet) }
}
