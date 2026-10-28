import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HyperVaultKit

/// The web dashboard's theme: app/api/dashboard-theme/route.ts, lib/dashboard-theme.ts and what the picker offers
/// (components/theme-switcher.tsx, `DashboardThemeRow`), minus the words that would say the app restyled.
final class DashboardThemeTests: XCTestCase {
    private let catalog = [
        Capabilities.ThemeInfo(id: "modern-dark", name: "Modern Dark", mode: "dark"),
        Capabilities.ThemeInfo(id: "glassmorphism", name: "Glassmorphism", mode: "dark"),
        Capabilities.ThemeInfo(id: "newsprint", name: "Newsprint", mode: "light"),
    ]

    private func hv(_ transport: MockTransport) -> HVClient {
        HVClient(baseURL: URL(string: "https://hv.test")!, transport: transport, tokens: StaticTokenProvider(), retry: .none)
    }

    private func rest(_ transport: MockTransport) -> AccountRest {
        AccountRest(client: HVClient(baseURL: URL(string: "https://proj.supabase.test")!, transport: transport, tokens: StaticTokenProvider(), retry: .none), anonKey: "anon-key")
    }

    // MARK: Choices

    func testTheStockLookComesFirstAndIsNotCalledGsap() {
        let choices = DashboardThemes.choices(from: catalog)
        XCTAssertEqual(choices.first, DashboardThemeChoice(themeID: nil, label: "HyperVault default"))
        XCTAssertFalse(choices.contains { $0.label.contains("Gsap") })
    }

    func testTheCatalogFollowsInTheServersOrderWithItsModeAsTheWebWritesIt() {
        let choices = DashboardThemes.choices(from: catalog)
        XCTAssertEqual(choices.map(\.themeID), [nil, "modern-dark", "glassmorphism", "newsprint"])
        XCTAssertEqual(choices.map(\.label), ["HyperVault default", "Modern Dark (dark)", "Glassmorphism (dark)", "Newsprint (light)"])
    }

    func testAnIdTheCatalogListsTwiceIsOfferedOnce() {
        let twice = catalog + [Capabilities.ThemeInfo(id: "newsprint", name: "Newsprint again", mode: "light")]
        XCTAssertEqual(DashboardThemes.choices(from: twice).map(\.themeID), [nil, "modern-dark", "glassmorphism", "newsprint"])
    }

    func testAnEmptyCatalogStillOffersTheStockLook() {
        XCTAssertEqual(DashboardThemes.choices(from: []).map(\.themeID), [nil])
    }

    func testAnIdTheCatalogDoesNotListIsShownAsTheStockLookBecauseThatIsWhatTheWebDraws() {
        XCTAssertEqual(DashboardThemes.selection(stored: "glassmorphism", in: catalog), "glassmorphism")
        XCTAssertNil(DashboardThemes.selection(stored: "retired-theme", in: catalog))
        XCTAssertNil(DashboardThemes.selection(stored: nil, in: catalog))
        XCTAssertNil(DashboardThemes.selection(stored: "glassmorphism", in: []))
    }

    func testTheNameOfATheme() {
        XCTAssertEqual(DashboardThemes.name(of: "glassmorphism", in: catalog), "Glassmorphism")
        XCTAssertNil(DashboardThemes.name(of: nil, in: catalog))
        XCTAssertNil(DashboardThemes.name(of: "retired-theme", in: catalog))
    }

    // MARK: Words

    func testNoWordSaysTheAppRestyledOrThatItWasSavedWithATick() {
        let said = [
            DashboardThemeCopy.line, DashboardThemeCopy.sectionTitle, DashboardThemeCopy.pickerLabel, DashboardThemeCopy.footer,
            DashboardThemeCopy.confirmation(for: nil, in: catalog), DashboardThemeCopy.confirmation(for: "newsprint", in: catalog),
        ]
        for line in said {
            XCTAssertFalse(line.contains("\u{2713}"), line)
            XCTAssertFalse(line.contains("Saved"), line)
            XCTAssertFalse(line.contains("Gsap"), line)
            XCTAssertFalse(line.contains("\u{2014}"), line)
            XCTAssertTrue(line.allSatisfy { $0.isASCII }, line)
        }
        XCTAssertTrue(DashboardThemeCopy.footer.contains("This app keeps the HyperVault default look"))
    }

    func testTheConfirmationNamesTheThemeTheCatalogGivesIt() {
        XCTAssertEqual(DashboardThemeCopy.confirmation(for: "newsprint", in: catalog), "Your website now wears Newsprint.")
        XCTAssertEqual(DashboardThemeCopy.confirmation(for: nil, in: catalog), "Your website is back on the HyperVault default look.")
        XCTAssertEqual(DashboardThemeCopy.confirmation(for: "retired-theme", in: catalog), "Your website now wears retired-theme.")
    }

    // MARK: Wire

    func testChoosingATheme() async throws {
        let transport = MockTransport(routes: [
            .json(.patch, "/api/dashboard-theme", #"{"theme":"newsprint","message":"Your dashboard now wears newsprint."}"#)
        ])
        let saved = try await hv(transport).send(.setDashboardTheme("newsprint"))
        XCTAssertEqual(saved.theme, "newsprint")

        let sent = await transport.requests(matching: "/api/dashboard-theme")
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0].httpMethod, "PATCH")
        let body = try HVCoding.decoder(.verbatim).decode(JSONValue.self, from: try XCTUnwrap(sent[0].httpBody))
        XCTAssertEqual(body, ["theme": "newsprint"])
    }

    func testTheStockLookIsNullOnTheWire() async throws {
        let transport = MockTransport(routes: [
            .json(.patch, "/api/dashboard-theme", #"{"theme":null,"message":"Your dashboard is back on the stock HyperVault look."}"#)
        ])
        let saved = try await hv(transport).send(.setDashboardTheme(nil))
        XCTAssertNil(saved.theme)
        let sent = await transport.requests(matching: "/api/dashboard-theme")
        let body = try HVCoding.decoder(.verbatim).decode(JSONValue.self, from: try XCTUnwrap(sent[0].httpBody))
        XCTAssertEqual(body, ["theme": nil], "null, not a missing key: a body without the key means null to the route too, but say it")
    }

    func testAnUnknownThemeIsTheServersSentenceAnd400() async {
        let sentence = "Unknown theme. Pick one of: modern-dark, glassmorphism - or null for the HyperVault default."
        let transport = MockTransport(routes: [.failure(.patch, "/api/dashboard-theme", status: 400, message: sentence)])
        do {
            _ = try await hv(transport).send(.setDashboardTheme("nope"))
            XCTFail("The server refused it.")
        } catch let error as HVError {
            XCTAssertEqual(error.failure?.status, 400)
            XCTAssertEqual(error.failure?.message, sentence)
        } catch {
            XCTFail("\(error)")
        }
    }

    // MARK: Reading what the profile holds

    func testTheProfilesThemeIsReadForThisPersonOnly() async throws {
        let transport = MockTransport(routes: [.json(.get, "/rest/v1/profiles", #"[{"theme":"glassmorphism"}]"#)])
        let theme = try await rest(transport).dashboardTheme(userID: "user-1")
        XCTAssertEqual(theme, "glassmorphism")

        let requests = await transport.requests(matching: "/rest/v1/profiles")
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: try XCTUnwrap(requests.first?.url), resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["select"], "theme")
        XCTAssertEqual(items["id"], "eq.user-1")
        XCTAssertEqual(items["limit"], "1")
    }

    func testAProfileWithNoThemeIsTheStockLook() async throws {
        let none = MockTransport(routes: [.json(.get, "/rest/v1/profiles", #"[{"theme":null}]"#)])
        let unset = try await rest(none).dashboardTheme(userID: "user-1")
        XCTAssertNil(unset)
        let noRow = MockTransport(routes: [.json(.get, "/rest/v1/profiles", "[]")])
        let missing = try await rest(noRow).dashboardTheme(userID: "user-1")
        XCTAssertNil(missing)
    }

    func testADatabaseFromBeforeTheColumnIsTheStockLookToo() async throws {
        let transport = MockTransport(routes: [MockRoute(.get, "/rest/v1/profiles") { _ in
            HTTPResponse(status: 400, data: Data(#"{"code":"42703","message":"column profiles.theme does not exist"}"#.utf8))
        }])
        let theme = try await rest(transport).dashboardTheme(userID: "user-1")
        XCTAssertNil(theme)
    }

    func testAnotherFailureIsNotHiddenAsTheStockLook() async {
        let transport = MockTransport(routes: [.failure(.get, "/rest/v1/profiles", status: 500, message: "The server fell over.")])
        do {
            _ = try await rest(transport).dashboardTheme(userID: "user-1")
            XCTFail("A failed read is not an answer.")
        } catch {
            XCTAssertEqual((error as? HVError)?.failure?.status, 500)
        }
    }
}
