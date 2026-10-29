import HyperVaultKit
import XCTest
@testable import HyperVault

/// Share on a card of the Home canvas: which cards offer it, what the sheet is told about the page, what is read for it (and
/// that the page itself is not), and that the sheet's own model does its work when the page it was given came from a card.
@MainActor
final class CanvasShareTests: XCTestCase {
    private let jsonHeaders: [String: String] = ["content-type": "application/json"]

    private let artifacts = #"""
    {"items":[
    {"slug":"bakery-1","title":"Bakery landing page","type":"html","tags":[],"is_pwa":false,"is_jsx":false,"visibility":"public","created_at":"2026-10-20T10:00:00.000Z"},
    {"slug":"portfolio","title":"Portfolio site","type":"group","tags":[],"is_pwa":false,"is_jsx":false,"visibility":"private","created_at":"2026-10-21T10:00:00.000Z"}
    ]}
    """#

    private let maya = #"{"id":"s1","email":"maya@example.com","display_name":"Maya","role":"edit","created_at":"2026-10-01T00:00:00.000Z"}"#
    private let sam = #"{"id":"s2","email":"sam@home.invalid","display_name":null,"role":"view","created_at":"2026-10-02T00:00:00.000Z"}"#

    private func shares(_ people: String...) -> String {
        #"{"shares":[\#(people.joined(separator: ","))],"roles":["view","use","edit"],"roles_enforced":true}"#
    }

    private func target(_ card: CanvasCard, env: AppEnvironment = AppEnvironment.preview()) -> CanvasShareTarget? {
        CanvasShare.target(for: card, env: env)
    }

    // MARK: Which cards offer it

    func testAPageAFileAndAGroupOfferShare() throws {
        for kind in [KeptKind.page, .file, .group] {
            let card = CanvasState.artifactCard(slug: "thing-1", title: "A thing", kind: kind)
            let found = try XCTUnwrap(target(card), "a \(kind.singular.lowercased()) card should offer Share")
            XCTAssertEqual(found.id, "thing-1")
            XCTAssertEqual(found.detail.slug, "thing-1")
        }
    }

    func testACardThatWasJustKeptOffersShareToo() throws {
        let kept = KeptThing(slug: "lisbon-trip-checklist-k1", url: "", kind: .page, form: "note", title: "Lisbon trip checklist", visibility: "private", duplicate: false, message: "")
        let card = CanvasState.keptCard(kept, origin: URL(string: "https://hypervault.store")!)
        XCTAssertNotNil(card.kept)
        XCTAssertEqual(try XCTUnwrap(target(card)).detail.slug, "lisbon-trip-checklist-k1")
    }

    func testAMemoryAndAKeyOfferNoShare() {
        let memory = CanvasState.itemCard(KeptItem(id: "m1", kind: .memory, name: "Trip notes", href: "/vault/memory?open=m1"))
        let key = CanvasState.itemCard(KeptItem(id: "k1", kind: .key, name: "OPENAI_API_KEY", href: "/vault/account"))
        XCTAssertNil(target(memory), "a memory has no link to give")
        XCTAssertNil(target(key), "a key is never shared, and nothing it holds is shown")
    }

    func testAPageThatCameOntoThePageFromYoursOffersShareByItsSlug() throws {
        let item = KeptItem(id: "a1", kind: .page, name: "Bakery landing page", href: "/a/bakery-landing-page-x1")
        XCTAssertEqual(try XCTUnwrap(target(CanvasState.itemCard(item))).id, "bakery-landing-page-x1")
    }

    // MARK: What the sheet is told

    func testAGroupsLinkIsOnTheGroupAddressBeforeAnythingIsRead() throws {
        let group = try XCTUnwrap(target(CanvasState.artifactCard(slug: "portfolio", title: "Portfolio site", kind: .group)))
        XCTAssertTrue(group.detail.isGroup)
        XCTAssertEqual(group.detail.link().absoluteString, "https://preview.hypervault.test/g/portfolio")

        let page = try XCTUnwrap(target(CanvasState.artifactCard(slug: "bakery-1", title: "Bakery landing page")))
        XCTAssertFalse(page.detail.isGroup)
        XCTAssertEqual(page.detail.link().absoluteString, "https://preview.hypervault.test/a/bakery-1")
    }

    // MARK: What is read for it

    func testReadingForTheSheetFindsTheTitleAndWhoCanOpenItAndLeavesThePageUnfetched() async throws {
        let env = AppEnvironment.preview(routes: [.json(.get, "/api/artifacts", artifacts)])
        let pageTransport = MockTransport()
        let loader = ArtifactPageLoader(baseURL: env.server.baseURL, tokens: StaticTokenProvider(), transport: pageTransport)
        let detail = ArtifactDetailModel(slug: "bakery-1", env: env, loader: loader, kindHint: .page)
        XCTAssertEqual(detail.title, "Page", "nothing is known before the read")
        XCTAssertNil(detail.visibility)

        await detail.loadForSharing()

        XCTAssertEqual(detail.title, "Bakery landing page")
        XCTAssertEqual(detail.visibility, .public)
        XCTAssertEqual(detail.isOwner, true)
        let fetched = await pageTransport.requests
        XCTAssertTrue(fetched.isEmpty, "the sheet has no use for the page's markup")
        if case .loading = detail.pageState {} else { XCTFail("the page was read") }
    }

    func testAGroupInTheListIsKnownAsOne() async {
        let env = AppEnvironment.preview(routes: [.json(.get, "/api/artifacts", artifacts)])
        let detail = ArtifactDetailModel(slug: "portfolio", env: env, kindHint: .group)
        await detail.loadForSharing()
        XCTAssertTrue(detail.isGroup)
        XCTAssertEqual(detail.title, "Portfolio site")
        XCTAssertEqual(detail.visibility, .private)
    }

    func testAPagePastTheListIsFoundByItsCard() async {
        let env = AppEnvironment.preview(routes: [
            .json(.get, "/api/artifacts", #"{"items":[]}"#),
            .json(.get, "/api/yours/card", #"{"id":"G1","kind":"group","name":"Trip","href":"/g/trip-1","updated_at":"2026-10-18T10:00:00.000Z","files":[]}"#),
        ])
        let detail = ArtifactDetailModel(slug: "trip-1", env: env, kindHint: .group)
        await detail.loadForSharing()
        XCTAssertEqual(detail.title, "Trip")
        XCTAssertTrue(detail.isGroup)
        XCTAssertEqual(detail.isOwner, true)
        XCTAssertEqual(detail.rowID, "G1")
    }

    func testAPageThatIsNotTheirsIsKnownAsSuch() async {
        let env = AppEnvironment.preview(routes: [
            .json(.get, "/api/artifacts", #"{"items":[]}"#),
            .failure(.get, "/api/yours/card", status: 404, message: "Not found."),
        ])
        let detail = ArtifactDetailModel(slug: "theirs-1", env: env, kindHint: .page)
        await detail.loadForSharing()
        XCTAssertEqual(detail.isOwner, false)
        XCTAssertFalse(detail.canManage)
    }

    func testAReadThatFindsNothingKeepsTheKindTheCardGave() async {
        let env = AppEnvironment.preview(routes: [
            .failure(.get, "/api/artifacts", status: 404, message: "Not found."),
            .failure(.get, "/api/yours/card", status: 404, message: "Not found."),
        ])
        let detail = ArtifactDetailModel(slug: "portfolio", env: env, kindHint: .group)
        await detail.loadForSharing()
        XCTAssertTrue(detail.isGroup, "the card said what it is")
        XCTAssertEqual(detail.link().absoluteString, "https://preview.hypervault.test/g/portfolio")
    }

    // MARK: The sheet's own model, from a card

    private func shareModel(for card: CanvasCard, env: AppEnvironment) throws -> ArtifactShareModel {
        let found = try XCTUnwrap(CanvasShare.target(for: card, env: env))
        // As ArtifactShareSheet builds it.
        return ArtifactShareModel(client: found.detail.env.client, slug: found.detail.slug)
    }

    func testWhoHasAPageIsReadAndAPersonIsAddedFromACanvasCard() async throws {
        let added = LibraryTestBox<Bool>(false)
        let sent = LibraryTestBox<String?>(nil)
        let asked = LibraryTestBox<[String]>([])
        let headers = jsonHeaders
        let mayaJSON = maya
        let bothJSON = "\(maya),\(sam)"
        let env = AppEnvironment.preview(routes: [
            MockRoute(.get, "/api/shares") { request in
                asked.value.append(request.url?.query ?? "")
                let people = added.value ? bothJSON : mayaJSON
                let body = #"{"shares":[\#(people)],"roles":["view","use","edit"],"roles_enforced":true}"#
                return HTTPResponse(status: 200, headers: headers, data: Data(body.utf8))
            },
            MockRoute(.post, "/api/shares") { request in
                sent.value = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
                added.value = true
                return HTTPResponse(status: 201, headers: headers, data: Data(#"{"role":"view","message":"Shared with sam@home.invalid."}"#.utf8))
            },
        ])
        let model = try shareModel(for: CanvasState.artifactCard(slug: "bakery-1", title: "Bakery landing page"), env: env)

        await model.load()
        XCTAssertTrue(model.canManage)
        XCTAssertEqual(model.list.value?.people.map(\.id), ["s1"])
        XCTAssertEqual(model.list.value?.offeredRoles, [.view, .use, .edit])
        XCTAssertEqual(asked.value, ["artifact=bakery-1"], "the page's slug is what the list is asked for")

        let message = await model.add(email: "sam@home.invalid", role: .view)
        XCTAssertEqual(message, "Shared with sam@home.invalid.")
        XCTAssertNil(model.error)
        let body = try XCTUnwrap(sent.value)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: String])
        XCTAssertEqual(fields, ["artifact": "bakery-1", "email": "sam@home.invalid", "role": "view"])
        XCTAssertEqual(model.list.value?.people.map(\.id), ["s1", "s2"], "the list is read again after an add")
    }

    func testARoleTheServerRefusesIsSaidInItsWordsAndNothingIsAdded() async throws {
        let env = AppEnvironment.preview(routes: [
            .json(.get, "/api/shares", shares(maya)),
            .failure(.post, "/api/shares", status: 403, message: "Only the owner can share this page."),
        ])
        let model = try shareModel(for: CanvasState.artifactCard(slug: "bakery-1", title: "Bakery landing page"), env: env)
        await model.load()

        let message = await model.add(email: "sam@home.invalid", role: .edit)
        XCTAssertNil(message)
        XCTAssertEqual(model.error, "Only the owner can share this page.")
        XCTAssertEqual(model.list.value?.people.map(\.id), ["s1"])
        XCTAssertFalse(model.pending)
    }

    func testAPersonRemovedComesBackIfTheServerRefuses() async throws {
        let env = AppEnvironment.preview(routes: [
            .json(.get, "/api/shares", shares(maya)),
            .failure(.delete, "/api/shares", status: 403, message: "Only the owner can remove people."),
        ])
        let model = try shareModel(for: CanvasState.artifactCard(slug: "bakery-1", title: "Bakery landing page"), env: env)
        await model.load()
        let person = try XCTUnwrap(model.list.value?.people.first)

        let removed = await model.remove(person)
        XCTAssertFalse(removed)
        XCTAssertEqual(model.list.value?.people.map(\.id), ["s1"], "back in the list")
        XCTAssertEqual(model.error, "Only the owner can remove people.")
    }

    func testAPageThatIsNotTheirsShowsOnlyTheLink() async throws {
        let env = AppEnvironment.preview(routes: [.failure(.get, "/api/shares", status: 404, message: "Not found.")])
        let model = try shareModel(for: CanvasState.artifactCard(slug: "theirs-1", title: "Shared with me"), env: env)
        await model.load()
        XCTAssertFalse(model.canManage, "the people section is left out")
        guard case .failed = model.list else { return XCTFail("expected the list to say it could not be read") }
    }
}
