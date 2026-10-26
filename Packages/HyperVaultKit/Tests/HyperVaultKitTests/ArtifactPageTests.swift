import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HyperVaultKit

/// The loader gives a web view the markup of a page with a bearer token and no
/// cookie. Fixtures: app/a/[slug]/route.ts (the page, the file viewer),
/// lib/artifacts/lock-pages.ts (the lock pages), app/api/artifacts/[slug]/source,
/// app/api/artifact-groups/[slug].
final class ArtifactPageTests: XCTestCase {
    let base = URL(string: "https://hv.test")!

    func loader(_ transport: MockTransport, token: String? = "tok-1") -> ArtifactPageLoader {
        ArtifactPageLoader(baseURL: base, tokens: StaticTokenProvider(token), transport: transport)
    }

    func html(_ status: Int, _ body: String) -> MockRoute {
        MockRoute(.get, "/a/p-1") { _ in HTTPResponse(status: status, headers: ["content-type": "text/html; charset=utf-8"], data: Data(body.utf8)) }
    }

    let privatePage = #"<!DOCTYPE html><html><head><title>Private</title></head><body><p style="font-size:48px;margin:0">\#u{1F512}</p><h1>This is private</h1></body></html>"#
    let passwordPage = #"<!DOCTYPE html><html><body><h1>This needs a password</h1><form id="hv-unlock-form"></form></body></html>"#

    // MARK: Pages

    func testAPageIsFetchedWithTheBearerAndRenderedAgainstItsOwnAddress() async throws {
        let transport = MockTransport(routes: [html(200, "<h1>Hi</h1>")])
        let page = await loader(transport).load(slug: "p-1")
        XCTAssertEqual(page, .html("<h1>Hi</h1>", base: URL(string: "https://hv.test/a/p-1")!))
        let requests = await transport.requests
        let sent = try XCTUnwrap(requests.first)
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer tok-1")
        XCTAssertTrue(sent.value(forHTTPHeaderField: "Accept")?.hasPrefix("text/html") == true)
    }

    func testAPrivatePageTheServerWillNotServeComesFromTheOwnersSourceRoute() async {
        let transport = MockTransport(routes: [
            html(401, privatePage),
            .json(.get, "/api/artifacts/p-1/source", #"{"content":"<h1>Mine</h1>"}"#),
        ])
        let page = await loader(transport).load(slug: "p-1")
        XCTAssertEqual(page, .html("<h1>Mine</h1>", base: URL(string: "https://hv.test/a/p-1")!))
    }

    func testAPrivatePageThatIsNotYoursIsBlocked() async {
        let transport = MockTransport(routes: [
            html(403, privatePage),
            .failure(.get, "/api/artifacts/p-1/source", status: 404, message: "Artifact not found."),
        ])
        let page = await loader(transport).load(slug: "p-1")
        XCTAssertEqual(page, .blocked(.notAllowed))
    }

    func testAPasswordPromptIsLeftToTheWebView() async {
        let transport = MockTransport(routes: [
            html(401, passwordPage),
            .failure(.get, "/api/artifacts/p-1/source", status: 404, message: "Artifact not found."),
        ])
        let page = await loader(transport).load(slug: "p-1")
        XCTAssertEqual(page, .navigate(URL(string: "https://hv.test/a/p-1")!))
    }

    func testAnOwnersPasswordPageStillRendersFromSource() async {
        let transport = MockTransport(routes: [
            html(401, passwordPage),
            .json(.get, "/api/artifacts/p-1/source", #"{"content":"<h1>Gated</h1>"}"#),
        ])
        let page = await loader(transport).load(slug: "p-1")
        XCTAssertEqual(page, .html("<h1>Gated</h1>", base: URL(string: "https://hv.test/a/p-1")!))
    }

    func testAStoredFilesPathIsNeverRenderedAsMarkup() async {
        let transport = MockTransport(routes: [
            html(401, privatePage),
            .json(.get, "/api/artifacts/p-1/source", #"{"content":"3f2a6c1e-0000-4000-8000-000000000001/9a8b7c6d-1111-4222-8333-444455556666.pdf"}"#),
        ])
        let page = await loader(transport).load(slug: "p-1")
        XCTAssertEqual(page, .blocked(.notAllowed))
        XCTAssertTrue(ArtifactPageLoader.looksLikeStoragePath("3f2a6c1e-0000-4000-8000-000000000001/9a8b7c6d-1111-4222-8333-444455556666.png"))
        XCTAssertFalse(ArtifactPageLoader.looksLikeStoragePath("<h1>hi</h1>"))
    }

    func testMissingAndUnavailablePages() async {
        let missing = await loader(MockTransport(routes: [html(404, "<h1>Nothing at /a/p-1</h1>")])).load(slug: "p-1")
        XCTAssertEqual(missing, .blocked(.notFound))
        let unavailable = await loader(MockTransport(routes: [html(503, "<h1>Temporarily unavailable</h1>")])).load(slug: "p-1")
        XCTAssertEqual(unavailable, .blocked(.unavailable))
        let odd = await loader(MockTransport(routes: [html(418, "teapot")])).load(slug: "p-1")
        XCTAssertEqual(odd, .blocked(.failed("The page didn't open (418).")))
    }

    func testSignedOutNeverTouchesTheNetwork() async {
        let transport = MockTransport(routes: [html(200, "<h1>Hi</h1>")])
        let page = await loader(transport, token: nil).load(slug: "p-1")
        guard case .blocked(.failed) = page else { return XCTFail("expected a blocked page, got \(page)") }
        let count = await transport.requests.count
        XCTAssertEqual(count, 0)
    }

    func testAnEmptyPageIsAGroupInDisguise() async {
        let group = #"{"slug":"p-1","title":"G","tags":[],"visibility":"private","files":[{"path":"index.html","content":"<h1>Group</h1>","size_bytes":15}]}"#
        let transport = MockTransport(routes: [html(200, ""), .json(.get, "/api/artifact-groups/p-1", group)])
        let page = await loader(transport).load(slug: "p-1")
        XCTAssertEqual(page, .html("<h1>Group</h1>", base: URL(string: "https://hv.test/g/p-1")!))
    }

    func testAGroupThePageRouteServesOnlyItsHeadTagsIsAGroupToo() async {
        let headOnly = "<head>\n<link rel=\"icon\" href=\"https://hv.test/a/p-1/icon?size=192\" />\n<meta property=\"og:title\" content=\"G\" />\n</head>\n"
        let group = #"{"slug":"p-1","title":"G","tags":[],"visibility":"private","files":[{"path":"index.html","content":"<h1>Group</h1>","size_bytes":15}]}"#
        let transport = MockTransport(routes: [html(200, headOnly), .json(.get, "/api/artifact-groups/p-1", group)])
        let page = await loader(transport).load(slug: "p-1")
        XCTAssertEqual(page, .html("<h1>Group</h1>", base: URL(string: "https://hv.test/g/p-1")!))
        XCTAssertTrue(ArtifactPageLoader.isBlank(headOnly))
        XCTAssertFalse(ArtifactPageLoader.isBlank("<head><title>x</title></head><body>hi</body>"))
        XCTAssertFalse(ArtifactPageLoader.isBlank("<h1>No head at all</h1>"))
    }

    func testBlankMeansNothingOutsideTheHeadWhateverTheCaseOrSpacing() {
        XCTAssertTrue(ArtifactPageLoader.isBlank(""))
        XCTAssertTrue(ArtifactPageLoader.isBlank(" \n\t "))
        XCTAssertTrue(ArtifactPageLoader.isBlank("<HEAD lang=\"en\">\n<title>x</title>\n</Head>\n"))
        XCTAssertTrue(ArtifactPageLoader.isBlank("\n<head></head>\n  <head data-x=\"1\">a > b</head>\n"), "more than one block, and a > inside the second")
        XCTAssertFalse(ArtifactPageLoader.isBlank("x<head></head>"))
        XCTAssertFalse(ArtifactPageLoader.isBlank("<head></head>x"))
        XCTAssertFalse(ArtifactPageLoader.isBlank("<head><title>never closed</title>"))
        XCTAssertFalse(ArtifactPageLoader.isBlank("<head"))
        XCTAssertFalse(ArtifactPageLoader.isBlank("<head>"))
        XCTAssertFalse(ArtifactPageLoader.isBlank("<body>hi</body>"))
    }

    func testAPageMadeOfUnclosedHeadTagsIsReadInOnePass() async {
        // Markup is anyone's to publish. Each of these is about 200 KB that a pattern which rescans from every
        // `<head` takes minutes over.
        let shapes = [
            String(repeating: "<head", count: 40_000),
            "<head>" + String(repeating: "<head", count: 40_000),
            String(repeating: "<head>", count: 33_000),
            String(repeating: "<head x=\"", count: 22_000) + ">",
            String(repeating: "<head></head ", count: 15_000),
        ]
        for markup in shapes {
            XCTAssertGreaterThan(markup.utf8.count, 190_000)
            let started = Date()
            XCTAssertFalse(ArtifactPageLoader.isBlank(markup))
            XCTAssertLessThan(Date().timeIntervalSince(started), 1.0, "read in one pass")
        }

        let started = Date()
        let transport = MockTransport(routes: [html(200, shapes[1])])
        let page = await loader(transport).load(slug: "p-1")
        XCTAssertEqual(page, .html(shapes[1], base: URL(string: "https://hv.test/a/p-1")!))
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.0, "the page opens")
    }

    // MARK: Files

    func testTheFileViewerGivesUpItsSignedAddress() {
        let pdf = #"<!DOCTYPE html><html><body><iframe src="https://p.supabase.co/storage/v1/object/sign/artifact-files/u/f.pdf?token=abc&amp;t=1" title="Doc" allow="fullscreen"></iframe></body></html>"#
        let found = ArtifactEmbeddedFile.find(in: pdf)
        XCTAssertEqual(found?.kind, .pdf)
        XCTAssertEqual(found?.url.absoluteString, "https://p.supabase.co/storage/v1/object/sign/artifact-files/u/f.pdf?token=abc&t=1")

        let image = #"<main><img src="https://p.supabase.co/x.png?token=a" alt="Pic" /></main>"#
        XCTAssertEqual(ArtifactEmbeddedFile.find(in: image)?.kind, .image)
        XCTAssertNil(ArtifactEmbeddedFile.find(in: "<h1>just a page</h1>"))
        XCTAssertNil(ArtifactEmbeddedFile.find(in: #"<iframe src="javascript:alert(1)"></iframe>"#), "only web addresses")
    }

    func testFileTypesTheServerTakes() {
        XCTAssertEqual(ArtifactFileType.forFilename("Report.PDF")?.kind, .pdf)
        XCTAssertEqual(ArtifactFileType.forFilename("a.b.jpeg")?.mime, "image/jpeg")
        XCTAssertEqual(ArtifactFileType.forFilename("logo.svg")?.kind, .image)
        XCTAssertNil(ArtifactFileType.forFilename("notes.txt"))
        XCTAssertNil(ArtifactFileType.forFilename("pdf"))
        XCTAssertNil(ArtifactFileType.forFilename(".png"))
    }

    // MARK: Groups

    func testAPrivateGroupIsReadWholeAndPreviewedAsOneDocument() async {
        let group = #"""
        {"slug":"trip-1","title":"Trip","tags":[],"visibility":"private","files":[
          {"path":"index.html","content":"<link rel=\"stylesheet\" href=\"styles.css\"><script src=\"app.js\"></script>","size_bytes":70},
          {"path":"styles.css","content":"body{}","size_bytes":6},{"path":"app.js","content":"go();","size_bytes":5}]}
        """#
        let transport = MockTransport(routes: [.json(.get, "/api/artifact-groups/trip-1", group)])
        let page = await loader(transport).load(slug: "trip-1", isGroup: true, visibility: .private)
        XCTAssertEqual(page, .html("<style>body{}</style><script>go();</script>", base: URL(string: "https://hv.test/g/trip-1")!))
    }

    func testAPublicGroupIsLoadedByTheWebViewItself() async {
        let transport = MockTransport()
        let page = await loader(transport).load(slug: "trip-1", isGroup: true, visibility: .public)
        XCTAssertEqual(page, .navigate(URL(string: "https://hv.test/g/trip-1")!))
        let count = await transport.requests.count
        XCTAssertEqual(count, 0, "a public group needs nothing from the app")
    }

    func testAGroupThatIsNotYoursFallsBackToTheWebView() async {
        let transport = MockTransport(routes: [.failure(.get, "/api/artifact-groups/trip-1", status: 404, message: "No artifact group matching \"trip-1\" in your vault.")])
        let page = await loader(transport).load(slug: "trip-1", isGroup: true)
        XCTAssertEqual(page, .navigate(URL(string: "https://hv.test/g/trip-1")!))
    }

    func testBlockedWordsAreCalm() {
        XCTAssertEqual(ArtifactBlock.notFound.message, "There is nothing at this link. It may be mistyped, or it may have been removed.")
        XCTAssertFalse(ArtifactBlock.offline.message.isEmpty)
        XCTAssertEqual(ArtifactBlock.failed("x").message, "x")
    }

    // MARK: Links

    func testLinksLiveOnAnyClaimedAddress() {
        let app = URL(string: "https://hypervault.store")!
        XCTAssertEqual(ArtifactLinks.url(slug: "p-1", appURL: app).absoluteString, "https://hypervault.store/a/p-1")
        XCTAssertEqual(ArtifactLinks.url(slug: "p-1", host: "nova.vault.cool", appURL: app).absoluteString, "https://nova.vault.cool/a/p-1")
        XCTAssertEqual(ArtifactLinks.url(slug: "trip", isGroup: true, appURL: app).absoluteString, "https://hypervault.store/g/trip")
        XCTAssertEqual(ArtifactLinks.url(slug: "p-1", appURL: URL(string: "https://hv.test/")!).absoluteString, "https://hv.test/a/p-1")
        XCTAssertEqual(ArtifactLinks.url(slug: "a b", appURL: app).absoluteString, "https://hypervault.store/a/a%20b")
        XCTAssertEqual(ArtifactLinks.primaryHost([ArtifactRealm(subdomain: "nova", baseDomain: "vault.cool"), ArtifactRealm(subdomain: "x", baseDomain: "vault.cool")]), "nova.vault.cool")
        XCTAssertNil(ArtifactLinks.primaryHost([]))
    }
}

final class ArtifactLinkRouterTests: XCTestCase {
    let router = ArtifactLinkRouter(serverHost: "hypervault.store", domains: ["vault.cool"])

    func action(_ text: String) -> ArtifactLinkAction { router.action(for: URL(string: text)!) }

    func testTheBrokenPagesFixItLinkOpensTheRepair() {
        XCTAssertEqual(
            action("https://hypervault.store/vault?repair=pomo-1&error=SyntaxError%3A%20Unexpected%20token"),
            .repair(slug: "pomo-1", error: "SyntaxError: Unexpected token")
        )
        XCTAssertEqual(action("https://nova.vault.cool/vault?repair=pomo-1"), .repair(slug: "pomo-1", error: nil))
        XCTAssertEqual(action("https://hypervault.store/vault/library?repair=pomo-1&error="), .repair(slug: "pomo-1", error: nil))
    }

    func testAnotherSitesRepairLinkIsJustALink() {
        let url = URL(string: "https://evil.example/vault?repair=pomo-1")!
        XCTAssertEqual(router.action(for: url), .external(url))
    }

    func testHyperVaultPagesStayInTheApp() {
        let page = URL(string: "https://hypervault.store/a/other-1")!
        XCTAssertEqual(router.action(for: page), .hyperVault(page))
        let group = URL(string: "https://hypervault.store/g/trip-1")!
        XCTAssertEqual(router.action(for: group), .hyperVault(group))
        let realm = URL(string: "https://nova.vault.cool/a/other-1")!
        XCTAssertEqual(router.action(for: realm), .hyperVault(realm))
        let apex = URL(string: "https://vault.cool/a/x")!
        XCTAssertEqual(router.action(for: apex), .hyperVault(apex))
        let scheme = URL(string: "hypervault://artifact/other-1")!
        XCTAssertEqual(router.action(for: scheme), .hyperVault(scheme))
        for text in ["hypervault://a/other-1", "hypervault://g/trip-1", "HyperVault://ARTIFACT/other-1"] {
            let url = URL(string: text)!
            XCTAssertEqual(router.action(for: url), .hyperVault(url), text)
        }
        let upper = URL(string: "https://hypervault.store/A/other-1")!
        XCTAssertEqual(router.action(for: upper), .hyperVault(upper), "the app reads the path without regard to case")
    }

    func testOtherHyperVaultPagesOnTheWebGoToTheWebNotIntoTheApp() {
        // The web asks for a sign-in where it must; the app does not act on a page's say-so.
        for text in ["https://vault.cool/d/x", "https://hypervault.store/pricing", "https://hypervault.store/vault/account", "https://nova.vault.cool/memory/m-1", "https://hypervault.store/"] {
            let url = URL(string: text)!
            XCTAssertEqual(router.action(for: url), .external(url), text)
        }
    }

    func testAPageCannotReachTheAppsOwnActions() {
        // Approving an agent and filling the canvas are done from the app's own links, never from a page.
        let actions = [
            "hypervault://pair?code=BCDF-2346", "hypervault://pair", "hypervault://keep?text=hello", "hypervault://canvas?text=hi",
            "hypervault://invite?code=abc", "hypervault://login?invite=abc", "hypervault://tab/you", "hypervault://settings",
            "hypervault://memory/m-1", "hypervault:///pair?code=BCDF-2346", "HYPERVAULT://PAIR?code=BCDF-2346", "hypervault://pair/a/x",
            "https://hypervault.store/pair?code=BCDF-2346", "https://hypervault.store/pair", "https://hypervault.store/keep?text=hello",
            "https://nova.vault.cool/keep?text=x", "https://vault.cool/canvas", "https://hypervault.store/invite?code=abc",
            "https://hypervault.store/login?invite=abc", "https://hypervault.store/%70air?code=BCDF-2346", "HTTPS://HYPERVAULT.STORE/PAIR?code=BCDF-2346",
        ]
        for text in actions {
            let url = URL(string: text)!
            let action = router.action(for: url)
            XCTAssertEqual(action, .blocked, "\(text) must not reach the app or Safari")
            XCTAssertEqual(router.action(for: url, tapped: false), .blocked, text)
        }
    }

    func testAnActionHiddenBehindAPageIsStillOnlyAPage() {
        // Only the first segment names where a link goes; a slug that reads like an action is just a slug.
        let page = URL(string: "https://hypervault.store/a/pair")!
        XCTAssertEqual(router.action(for: page), .hyperVault(page))
        let scheme = URL(string: "hypervault://a/keep")!
        XCTAssertEqual(router.action(for: scheme), .hyperVault(scheme))
    }

    func testLookalikesOfTheActionsAreNotOursEither() {
        for text in ["https://hypervault.store.evil.example/pair?code=BCDF-2346", "https://evilvault.cool/keep?text=x", "https://hypervault.store@evil.example/pair"] {
            let url = URL(string: text)!
            XCTAssertEqual(router.action(for: url), .external(url), text)
        }
    }

    func testAPageThatNavigatesByItselfNeverLeavesTheApp() {
        // A script or a meta refresh arrives as a navigation nobody tapped.
        for text in ["https://example.com/", "http://example.com", "mailto:sam@example.com", "tel:+15551234567", "sms:+15551234567", "facetime:sam@example.com", "https://hypervault.store/pricing"] {
            XCTAssertEqual(router.action(for: URL(string: text)!, tapped: false), .blocked, text)
        }
        let page = URL(string: "https://hypervault.store/a/other-1")!
        XCTAssertEqual(router.action(for: page, tapped: false), .hyperVault(page), "moving on to another page is not leaving")
        XCTAssertEqual(router.action(for: URL(string: "https://hypervault.store/vault?repair=pomo-1")!, tapped: false), .blocked, "the Fix it link is a link to tap")
    }

    func testLookalikeHostsAreNotOurs() {
        for text in ["https://hypervault.store.evil.example/a/x", "https://evilvault.cool/a/x", "https://vault.cool.evil.example/a/x"] {
            let url = URL(string: text)!
            XCTAssertEqual(router.action(for: url), .external(url), text)
        }
    }

    func testEverythingElseOnTheWebGoesToSafari() {
        for text in ["https://example.com/a/x", "http://example.com", "mailto:sam@example.com", "tel:+15551234567", "sms:+15551234567"] {
            let url = URL(string: text)!
            XCTAssertEqual(router.action(for: url), .external(url), text)
        }
    }

    func testAPageCannotNavigateToWhatItShouldNot() {
        for text in ["javascript:alert(1)", "file:///etc/passwd", "data:text/html,hi", "blob:https://x/1", "itms-services://?action=download-manifest&url=x", "x-apple-reminderkit://"] {
            XCTAssertEqual(router.action(for: URL(string: text)!), .blocked, text)
        }
    }
}
