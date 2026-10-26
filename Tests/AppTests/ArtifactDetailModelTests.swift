import HyperVaultKit
import XCTest
@testable import HyperVault

/// What a page screen works out about a page, and the changes made from its bar.
@MainActor
final class ArtifactDetailModelTests: XCTestCase {
    private let artifacts = #"""
    {"items":[{"slug":"pomo-1","title":"Pomodoro Timer","type":"react","tags":[],"is_pwa":true,"is_jsx":true,"visibility":"private","created_at":"2026-10-20T10:00:00.000Z"}]}
    """#

    private func page(_ slug: String, status: Int = 200, body: String) -> MockRoute {
        MockRoute(.get, "/a/\(slug)") { _ in HTTPResponse(status: status, data: Data(body.utf8)) }
    }

    private func model(
        slug: String = "pomo-1", routes: [MockRoute], pageRoutes: [MockRoute]
    ) -> ArtifactDetailModel {
        let env = AppEnvironment.preview(routes: routes)
        let loader = ArtifactPageLoader(
            baseURL: env.server.baseURL, tokens: StaticTokenProvider(), transport: MockTransport(routes: pageRoutes)
        )
        return ArtifactDetailModel(slug: slug, env: env, loader: loader)
    }

    private func html(_ model: ArtifactDetailModel) -> String? {
        if case .ready(let content) = model.pageState, case .html(let html, _) = content.source { return html }
        return nil
    }

    // MARK: Whose page, what kind

    func testAPageInTheListIsTheOwnersAndRendersFromTheMarkup() async {
        let model = model(
            routes: [.json(.get, "/api/artifacts", artifacts), .json(.get, "/api/artifacts/pomo-1/feedback", #"{"feedback":"down"}"#)],
            pageRoutes: [page("pomo-1", body: "<h1>Pomodoro</h1>")]
        )
        await model.load()
        XCTAssertEqual(model.isOwner, true)
        XCTAssertEqual(model.title, "Pomodoro Timer")
        XCTAssertEqual(model.visibility, .private)
        XCTAssertEqual(model.feedback, .down)
        XCTAssertEqual(html(model), "<h1>Pomodoro</h1>")
        XCTAssertFalse(model.isGroup)
    }

    func testAPageThatIsNotTheirsIsKnownByTheCardsRefusal() async {
        let model = model(
            slug: "theirs-1",
            routes: [
                .json(.get, "/api/artifacts", artifacts),
                .failure(.get, "/api/yours/card", status: 404, message: "Not found."),
            ],
            pageRoutes: [page("theirs-1", body: "<h1>Shared with me</h1>")]
        )
        await model.load()
        XCTAssertEqual(model.isOwner, false)
        XCTAssertFalse(model.canManage, "no sharing, deleting or settings for someone else's page")
        XCTAssertEqual(html(model), "<h1>Shared with me</h1>")
        XCTAssertEqual(model.title, "Page")
    }

    func testAGroupNotSeenBeforeIsAskedAboutBeforeItIsRead() async {
        let group = #"{"slug":"trip-1","title":"Trip","tags":[],"visibility":"private","files":[{"path":"index.html","content":"<link rel=\"stylesheet\" href=\"s.css\"><p>hi</p>","size_bytes":50},{"path":"s.css","content":"p{color:red}","size_bytes":12}]}"#
        let model = model(
            slug: "trip-1",
            routes: [
                .json(.get, "/api/artifacts", #"{"items":[]}"#),
                .json(.get, "/api/yours/card", #"{"id":"G1","kind":"group","name":"Trip","href":"/g/trip-1","updated_at":"2026-10-18T10:00:00.000Z","files":[]}"#),
            ],
            pageRoutes: [
                page("trip-1", body: "<head><meta property=\"og:title\" content=\"Trip\" /></head>"),
                .json(.get, "/api/artifact-groups/trip-1", group),
            ]
        )
        await model.load()
        XCTAssertTrue(model.isGroup)
        XCTAssertEqual(html(model), "<style>p{color:red}</style><p>hi</p>")
    }

    func testAPageThePersonCannotOpenHereOffersSafariNotAnEmptyScreen() async {
        let model = model(
            routes: [.json(.get, "/api/artifacts", artifacts)],
            pageRoutes: [page("pomo-1", status: 403, body: "<h1>This is private</h1>")]
        )
        await model.load()
        guard case .blocked(let block) = model.pageState else { return XCTFail("expected a blocked page") }
        XCTAssertEqual(block, .notAllowed)
        XCTAssertEqual(model.safariURL.absoluteString, "https://preview.hypervault.test/a/pomo-1")
    }

    func testReturningToTheScreenDoesNotReloadThePage() async {
        let hits = LibraryTestBox<Int>(0)
        let model = model(
            routes: [.json(.get, "/api/artifacts", artifacts)],
            pageRoutes: [MockRoute(.get, "/a/pomo-1") { _ in
                hits.value += 1
                return HTTPResponse(status: 200, data: Data("<h1>x</h1>".utf8))
            }]
        )
        await model.load()
        await model.load()
        XCTAssertEqual(hits.value, 1)
        await model.reload()
        XCTAssertEqual(hits.value, 2)
    }

    // MARK: Links

    func testALinkLivesOnTheAppUnlessAnAddressIsChosen() async {
        let model = model(routes: [.json(.get, "/api/artifacts", artifacts)], pageRoutes: [page("pomo-1", body: "x")])
        await model.load()
        XCTAssertEqual(model.shareURL.absoluteString, "https://preview.hypervault.test/a/pomo-1")
        XCTAssertEqual(model.link(host: "nova.vault.cool").absoluteString, "https://nova.vault.cool/a/pomo-1")
    }

    // MARK: Changes

    func testChangingWhoCanOpenItIsShownAtOnceAndTakenBackIfRefused() async {
        let toasts = ToastCenter()
        let model = model(
            routes: [.json(.get, "/api/artifacts", artifacts), .failure(.patch, "/api/artifacts", status: 403, message: "Only the owner can change that.")],
            pageRoutes: [page("pomo-1", body: "x")]
        )
        await model.load()
        await model.setVisibility(.public, toasts: toasts)
        XCTAssertEqual(model.visibility, .private)
        XCTAssertEqual(toasts.current?.message, "Only the owner can change that.")
    }

    func testARefusedVisibilityChangeDoesNotUndoAnIconThatWentThrough() async {
        // Who can open it is refused after a pause; the icon is set at once, in between.
        let env = LibraryStaggeredTransport.environment(
            routes: [
                MockRoute(.patch, "/api/artifacts") { request in
                    let text = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
                    if text.contains("visibility") { return HTTPResponse(status: 503, data: Data(#"{"error":"The database is missing artifact privacy."}"#.utf8)) }
                    return HTTPResponse(status: 200, data: Data(#"{"artifact":{"id":"A1","slug":"pomo-1","title":"Pomodoro Timer","visibility":"private","icon":"P"},"message":"Icon set."}"#.utf8))
                },
                .json(.get, "/api/artifacts", artifacts),
            ],
            pause: { request in String(decoding: request.httpBody ?? Data(), as: UTF8.self).contains("visibility") ? 0.3 : 0 }
        )
        let loader = ArtifactPageLoader(baseURL: env.server.baseURL, tokens: StaticTokenProvider(), transport: MockTransport(routes: [page("pomo-1", body: "x")]))
        let model = ArtifactDetailModel(slug: "pomo-1", env: env, loader: loader)
        let toasts = ToastCenter()
        await model.load()

        let refused = Task { await model.setVisibility(.public, toasts: toasts) }
        try? await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(model.visibility, .public, "shown at once")
        let set = await model.setIcon("P", toasts: toasts)
        await refused.value

        XCTAssertTrue(set)
        XCTAssertEqual(model.visibility, .private, "the refused change went back")
        XCTAssertEqual(model.summary?.icon, ArtifactIcon.normalizedGlyph("P"), "the icon that went through stays")
    }

    func testAThumbGivenTwiceIsTakenBack() async {
        let toasts = ToastCenter()
        let bodies = LibraryTestBox<[String]>([])
        let model = model(
            routes: [
                .json(.get, "/api/artifacts", artifacts),
                MockRoute(.post, "/api/artifacts/pomo-1/feedback") { request in
                    bodies.value.append(String(decoding: request.httpBody ?? Data(), as: UTF8.self))
                    return HTTPResponse(status: 200, data: Data(#"{"slug":"pomo-1","feedback":"up","message":"Rating saved."}"#.utf8))
                },
            ],
            pageRoutes: [page("pomo-1", body: "x")]
        )
        await model.load()
        await model.rate(.up, toasts: toasts)
        XCTAssertEqual(model.feedback, .up)
        await model.rate(.up, toasts: toasts)
        XCTAssertNil(model.feedback)
        XCTAssertEqual(bodies.value, [#"{"feedback":"up"}"#, #"{"feedback":null}"#])
    }

    func testAThumbTheServerRefusesIsTakenBack() async {
        let toasts = ToastCenter()
        let model = model(
            routes: [.json(.get, "/api/artifacts", artifacts), .failure(.post, "/api/artifacts/pomo-1/feedback", status: 503, message: "Artifact ratings aren't enabled on this server yet.")],
            pageRoutes: [page("pomo-1", body: "x")]
        )
        await model.load()
        await model.rate(.down, toasts: toasts)
        XCTAssertNil(model.feedback)
        XCTAssertTrue(toasts.current?.message.contains("aren't enabled") == true)
    }

    func testPinningSendsTheWholeList() async {
        let toasts = ToastCenter()
        let sent = LibraryTestBox<String?>(nil)
        let model = model(
            routes: [
                .json(.get, "/api/artifacts", artifacts),
                MockRoute(.patch, "/api/sidebar-pins") { request in
                    sent.value = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
                    return HTTPResponse(status: 200, data: Data(#"{"pins":[]}"#.utf8))
                },
            ],
            pageRoutes: [page("pomo-1", body: "x")]
        )
        await model.load()
        await model.togglePin(toasts: toasts)
        XCTAssertTrue(model.isPinned)
        XCTAssertEqual(sent.value, #"{"pins":[{"kind":"artifact","ref":"pomo-1"}]}"#)
    }

    func testDeletingAPageDropsItFromTheSavedList() async throws {
        let env = AppEnvironment.preview(routes: [
            .json(.get, "/api/artifacts", artifacts),
            .json(.delete, "/api/artifacts", #"{"deleted":{"slug":"pomo-1","title":"Pomodoro Timer"},"message":"Deleted."}"#),
        ])
        let loader = ArtifactPageLoader(baseURL: env.server.baseURL, tokens: StaticTokenProvider(), transport: MockTransport(routes: [page("pomo-1", body: "x")]))
        let model = ArtifactDetailModel(slug: "pomo-1", env: env, loader: loader)
        await model.load()
        try await model.delete()
        let saved = await env.cache.entry(ArtifactList.self, key: LibraryCache.artifactsKey, namespace: env.user.id)
        XCTAssertEqual(saved?.value.items.map(\.slug), [])
    }
}
