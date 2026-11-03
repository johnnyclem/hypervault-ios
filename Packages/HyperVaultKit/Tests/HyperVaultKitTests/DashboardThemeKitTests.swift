import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HyperVaultKit

/// `GET /api/dashboard-theme` -> `{ theme, kit }`, the `PATCH` answer and `features.stylekit`.
final class DashboardThemeKitTests: XCTestCase {
    // MARK: Helpers

    private func hv(_ transport: MockTransport) -> HVClient {
        HVClient(baseURL: URL(string: "https://hv.test")!, transport: transport, tokens: StaticTokenProvider(), retry: .none)
    }

    /// The body `GET /api/dashboard-theme` answers for a golden.
    private func envelope(_ name: String = "newsprint", theme: String? = nil) throws -> String {
        let kit = String(decoding: try StyleKitFixtures.data(name), as: UTF8.self)
        return #"{"theme":"\#(theme ?? name)","kit":\#(kit)}"#
    }

    private func decodeState(_ text: String) throws -> DashboardThemeState {
        try StyleKitFixtures.decode(DashboardThemeState.self, from: Data(text.utf8))
    }

    // MARK: The state

    func testNoThemeIsTheDefaultLook() throws {
        let state = try decodeState(#"{"theme":null,"kit":null}"#)
        XCTAssertEqual(state, .stock)
        XCTAssertNil(state.theme)
        XCTAssertNil(state.kit)
        XCTAssertNil(state.reason)
        XCTAssertFalse(state.isWithheld)
        XCTAssertEqual(try decodeState("{}"), .stock, "nothing said is nothing chosen")
    }

    func testAThemeWithItsKit() throws {
        let state = try decodeState(try envelope())
        XCTAssertEqual(state.theme, "newsprint")
        XCTAssertEqual(state.kit, try StyleKitFixtures.kit("newsprint"))
        XCTAssertNil(state.reason)
        XCTAssertFalse(state.isWithheld)
    }

    func testRetroIsUnsupportedAndTheAppSaysSo() throws {
        let state = try decodeState(#"{"theme":"retro","kit":null,"reason":"unsupported"}"#)
        XCTAssertEqual(state.theme, "retro")
        XCTAssertNil(state.kit)
        XCTAssertEqual(state.reason, .unsupported)
        XCTAssertTrue(state.isWithheld)
    }

    func testAStoredIdTheServerNoLongerHasIsTheStockLookWithNoNote() throws {
        let state = try decodeState(#"{"theme":"gone","kit":null,"reason":"unknown"}"#)
        XCTAssertEqual(state.reason, .unknown)
        XCTAssertNil(state.kit)
        XCTAssertFalse(state.isWithheld, "the web shows its stock look for it as well")
    }

    func testAReasonThisBuildDoesNotKnowIsTreatedAsUnsupported() throws {
        let state = try decodeState(#"{"theme":"x","kit":null,"reason":"licensing"}"#)
        XCTAssertEqual(state.reason, .unsupported)
        let notAWord = try decodeState(#"{"theme":"x","kit":null,"reason":7}"#)
        XCTAssertEqual(notAWord.reason, .unsupported)
    }

    func testAThemeWithNoKitAndNoReasonIsOneTheServerDidNotExplain() throws {
        // What a server that predates kits answers to PATCH, and what a GET would carry if it left the reason out.
        let state = try decodeState(#"{"theme":"newsprint"}"#)
        XCTAssertEqual(state.reason, .unsupported)
        XCTAssertTrue(state.isWithheld)
        XCTAssertEqual(try decodeState(#"{"theme":"newsprint","kit":null}"#).reason, .unsupported)
    }

    func testAKitTheAppCannotReadIsTheDefaultLookAndThemeStillSaysWhatWasChosen() throws {
        let unreadable: [(String, Data)] = [
            ("another schema", try StyleKitFixtures.variant(["schema_version"], to: 2)),
            ("an unknown appearance", try StyleKitFixtures.variant(["appearance"], to: "sepia")),
            ("a missing colour", try StyleKitFixtures.variant(["colors", "action"], to: nil)),
            ("a translucent colour", try StyleKitFixtures.variant(["colors", "card"], to: "#fffdf480")),
            ("an rgba colour", try StyleKitFixtures.variant(["colors", "card"], to: "rgba(255, 255, 255, 0.06)")),
        ]
        for (why, kit) in unreadable {
            let body = #"{"theme":"newsprint","kit":\#(String(decoding: kit, as: UTF8.self))}"#
            let state = try decodeState(body)
            XCTAssertNil(state.kit, why)
            XCTAssertEqual(state.reason, .invalid, why)
            XCTAssertEqual(state.theme, "newsprint", why)
            XCTAssertTrue(state.isWithheld, why)
        }
        for junk in [#""newsprint""#, "5", "[]", "true", #"{"colors":{}}"#, "{}"] {
            let state = try decodeState(#"{"theme":"newsprint","kit":\#(junk)}"#)
            XCTAssertNil(state.kit, junk)
            XCTAssertEqual(state.reason, .invalid, junk)
        }
    }

    func testAKitThatFailsTheFloorsIsTheDefaultLookToo() throws {
        let tooFaint = try StyleKitFixtures.variant("modern-dark", ["colors", "foreground"], to: "#0b0f14")
        let state = try decodeState(#"{"theme":"modern-dark","kit":\#(String(decoding: tooFaint, as: UTF8.self))}"#)
        XCTAssertNil(state.kit)
        XCTAssertEqual(state.reason, .invalid)
        let wrongSide = try StyleKitFixtures.variant("modern-dark", ["appearance"], to: "light")
        let flipped = try decodeState(#"{"theme":"modern-dark","kit":\#(String(decoding: wrongSide, as: UTF8.self))}"#)
        XCTAssertNil(flipped.kit, "black system text on a near-black page")
        XCTAssertEqual(flipped.reason, .invalid)
    }

    func testAKitWithoutAThemeIsNotWorn() throws {
        let kit = String(decoding: try StyleKitFixtures.data("newsprint"), as: UTF8.self)
        let state = try decodeState(#"{"theme":null,"kit":\#(kit)}"#)
        XCTAssertEqual(state, .stock)
    }

    func testAResponseThatIsNotTheRightShapeFailsInsteadOfPassingForNoTheme() {
        for text in [#"{"theme":5}"#, #"{"theme":["newsprint"]}"#, "[]", "null", #""x""#] {
            XCTAssertThrowsError(try decodeState(text), text)
        }
    }

    func testTheMemberwiseInitHoldsTheSameLines() throws {
        let kit = try StyleKitFixtures.kit("newsprint")
        XCTAssertEqual(DashboardThemeState(theme: "newsprint", kit: kit).reason, nil)
        XCTAssertEqual(DashboardThemeState(theme: nil, kit: kit), .stock)
        XCTAssertEqual(DashboardThemeState(theme: "newsprint").reason, .unsupported)
        XCTAssertEqual(DashboardThemeState(theme: "retro", kit: nil, reason: .unsupported).reason, .unsupported)
        XCTAssertEqual(DashboardThemeState(theme: "gone", kit: nil, reason: .unknown).reason, .unknown)
        var illegible = kit
        illegible.colors.foreground = illegible.colors.background
        let refused = DashboardThemeState(theme: "newsprint", kit: illegible)
        XCTAssertNil(refused.kit)
        XCTAssertEqual(refused.reason, .invalid)
    }

    func testTheStateRoundTripsThroughTheCacheWritingWhatTheServerWrites() throws {
        let kit = try StyleKitFixtures.kit("glassmorphism")
        let states = [
            DashboardThemeState.stock,
            DashboardThemeState(theme: "glassmorphism", kit: kit),
            DashboardThemeState(theme: "retro", kit: nil, reason: .unsupported),
            DashboardThemeState(theme: "gone", kit: nil, reason: .unknown),
            DashboardThemeState(theme: "newsprint", kit: nil, reason: .invalid),
        ]
        for state in states {
            let written = try HVCoding.encoder(.verbatim).encode(state)
            XCTAssertEqual(try StyleKitFixtures.decode(DashboardThemeState.self, from: written), state, state.theme ?? "stock")
        }
        let wire = try HVCoding.decoder(.verbatim).decode(JSONValue.self, from: HVCoding.encoder(.verbatim).encode(states[1]))
        XCTAssertEqual(wire, ["theme": "glassmorphism", "kit": try StyleKitFixtures.json("glassmorphism")])
        let retro = try HVCoding.decoder(.verbatim).decode(JSONValue.self, from: HVCoding.encoder(.verbatim).encode(states[2]))
        XCTAssertEqual(retro, ["theme": "retro", "kit": nil, "reason": "unsupported"])
    }

    func testEveryPresetsAnswerIsReadAsTheServerMeantIt() throws {
        let all = try StyleKitFixtures.decode([DashboardThemeState].self, from: StyleKitFixtures.data("all-presets"))
        XCTAssertEqual(all.count, 39)
        for state in all {
            if state.theme == "retro" {
                XCTAssertNil(state.kit)
                XCTAssertEqual(state.reason, .unsupported)
                XCTAssertTrue(state.isWithheld)
            } else {
                XCTAssertEqual(state.kit?.id, state.theme, state.theme ?? "")
                XCTAssertNil(state.reason, "\(state.theme ?? ""): the app's own checks refused a kit the server clamped")
                XCTAssertFalse(state.isWithheld)
            }
        }
    }

    // MARK: GET

    func testTheEndpointIsTheDashboardThemeRouteWithVerbatimKeys() {
        let endpoint = Endpoint<DashboardThemeState>.dashboardTheme
        XCTAssertEqual(endpoint.method, .get)
        XCTAssertEqual(endpoint.path, "/api/dashboard-theme")
        XCTAssertEqual(endpoint.keys, .verbatim, "the kit spells its keys with underscores; the snake case strategy would rename them")
        XCTAssertTrue(endpoint.idempotent)
        XCTAssertEqual(Endpoint<DashboardThemeSaved>.setDashboardTheme("x").keys, .verbatim)
    }

    func testTheServersAnswerIsReadThroughTheClient() async throws {
        let transport = MockTransport(routes: [.json(.get, "/api/dashboard-theme", try envelope("glassmorphism"))])
        let state = try await hv(transport).dashboardThemeState()
        XCTAssertEqual(state?.theme, "glassmorphism")
        XCTAssertEqual(state?.kit?.colors.mutedForeground.hexString, "#9db1d4")
        XCTAssertEqual(state?.kit?.colors.actionForeground, .black)

        let sent = await transport.requests(matching: "/api/dashboard-theme")
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0].httpMethod, "GET")
        XCTAssertNil(sent[0].url?.query)
        XCTAssertEqual(sent[0].value(forHTTPHeaderField: "Authorization"), "Bearer preview-token", "the route needs the person, so it is sent the token")
    }

    func testNoThemeAndRetroAreReadThroughTheClientToo() async throws {
        let none = MockTransport(routes: [.json(.get, "/api/dashboard-theme", #"{"theme":null,"kit":null}"#)])
        let stock = try await hv(none).dashboardThemeState()
        XCTAssertEqual(stock, .stock)
        let retro = MockTransport(routes: [.json(.get, "/api/dashboard-theme", #"{"theme":"retro","kit":null,"reason":"unsupported"}"#)])
        let withheld = try await hv(retro).dashboardThemeState()
        XCTAssertEqual(withheld?.reason, .unsupported)
        XCTAssertNil(withheld?.kit)
    }

    func testAServerWithoutTheGETIsNoKitAndNotAnError() async throws {
        for status in [404, 405] {
            let transport = MockTransport(routes: [.failure(.get, "/api/dashboard-theme", status: status, message: "Method not allowed")])
            let state = try await hv(transport).dashboardThemeState()
            XCTAssertNil(state, "\(status)")
        }
    }

    func testAnyOtherFailureIsNotHiddenAsNoThemeBecauseTheAppWouldFlipToTheDefaultLook() async {
        for status in [500, 503, 429] {
            let transport = MockTransport(routes: [.failure(.get, "/api/dashboard-theme", status: status, message: "The server fell over.")])
            do {
                _ = try await hv(transport).dashboardThemeState()
                XCTFail("\(status) is not an answer")
            } catch {
                XCTAssertEqual((error as? HVError)?.failure?.status, status)
            }
        }
        let garbage = MockTransport(routes: [.json(.get, "/api/dashboard-theme", #"{"theme":5}"#)])
        do {
            _ = try await hv(garbage).dashboardThemeState()
            XCTFail("a theme that is not a string is not an answer")
        } catch {
            guard case .decoding? = error as? HVError else { return XCTFail("\(error)") }
        }
    }

    // MARK: PATCH

    func testTheSavedAnswerCarriesTheKitSoAChoiceCanBeWornAtOnce() async throws {
        let body = #"{"theme":"newsprint","kit":\#(String(decoding: try StyleKitFixtures.data("newsprint"), as: UTF8.self)),"message":"Your dashboard now wears newsprint."}"#
        let transport = MockTransport(routes: [.json(.patch, "/api/dashboard-theme", body)])
        let saved = try await hv(transport).send(.setDashboardTheme("newsprint"))
        XCTAssertEqual(saved.theme, "newsprint")
        XCTAssertEqual(saved.message, "Your dashboard now wears newsprint.")
        XCTAssertEqual(saved.state.kit, try StyleKitFixtures.kit("newsprint"))
        XCTAssertEqual(saved.state.theme, "newsprint")
    }

    func testTheSavedAnswerOfAServerWithoutKitsIsATitleOnly() async throws {
        let transport = MockTransport(routes: [.json(.patch, "/api/dashboard-theme", #"{"theme":"newsprint","message":"Your dashboard now wears newsprint."}"#)])
        let saved = try await hv(transport).send(.setDashboardTheme("newsprint"))
        XCTAssertEqual(saved.theme, "newsprint")
        XCTAssertEqual(saved.state, DashboardThemeState(theme: "newsprint", kit: nil, reason: .unsupported))
        let none = MockTransport(routes: [.json(.patch, "/api/dashboard-theme", #"{"theme":null,"message":"back"}"#)])
        let stock = try await hv(none).send(.setDashboardTheme(nil))
        XCTAssertNil(stock.theme)
        XCTAssertEqual(stock.state, .stock)
    }

    func testAKitTheAppCannotWearDoesNotUndoASavedChoice() async throws {
        let bad = String(decoding: try StyleKitFixtures.variant(["schema_version"], to: 2), as: UTF8.self)
        let transport = MockTransport(routes: [.json(.patch, "/api/dashboard-theme", #"{"theme":"newsprint","kit":\#(bad),"message":"ok"}"#)])
        let saved = try await hv(transport).send(.setDashboardTheme("newsprint"))
        XCTAssertEqual(saved.theme, "newsprint", "the server did save it; the website wears it")
        XCTAssertNil(saved.state.kit)
        XCTAssertEqual(saved.state.reason, .invalid)
    }

    // MARK: Capabilities

    func testTheStylekitFlagIsABoolThatIsFalseUntilTheServerSaysOtherwise() throws {
        let decode = { (features: String) throws -> Capabilities in
            try HVCoding.decoder().decode(Capabilities.self, from: Data(#"{"app_url":"https://hv.test","features":\#(features)}"#.utf8))
        }
        XCTAssertFalse(Capabilities().features.stylekit)
        XCTAssertFalse(Capabilities.Features().stylekit)
        XCTAssertFalse(try decode("{}").features.stylekit, "an older server does not mention it")
        XCTAssertTrue(try decode(#"{"stylekit":true}"#).features.stylekit)
        XCTAssertFalse(try decode(#"{"stylekit":false}"#).features.stylekit)
        // A number or a word is not "yes", and does not cost the app the rest of the document.
        let odd = try decode(#"{"stylekit":1,"realm_home_page":false}"#)
        XCTAssertFalse(odd.features.stylekit)
        XCTAssertFalse(odd.features.realmHomePage)
        XCTAssertFalse(try decode(#"{"stylekit":"true"}"#).features.stylekit)
        XCTAssertFalse(try decode(#"{"stylekit":null}"#).features.stylekit)
        // The other flags are as they were.
        let others = try decode(#"{"stylekit":true,"deep_memory":true}"#)
        XCTAssertTrue(others.features.deepMemory)
        XCTAssertTrue(others.features.dreaming)
    }

    func testTheStylekitFlagSurvivesTheCapabilitiesCache() throws {
        var capabilities = Capabilities()
        capabilities.features.stylekit = true
        let written = try HVCoding.encoder(.verbatim).encode(capabilities)
        XCTAssertTrue(try HVCoding.decoder(.verbatim).decode(Capabilities.self, from: written).features.stylekit)
    }
}
