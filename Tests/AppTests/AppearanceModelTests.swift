import Foundation
import HyperVaultKit
import XCTest
@testable import HyperVault

private final class ThemeServer: @unchecked Sendable {
    private let lock = NSLock()
    private var theme: String?
    init(theme: String?) { self.theme = theme }

    var current: String? {
        lock.lock()
        defer { lock.unlock() }
        return theme
    }

    func set(_ next: String?) {
        lock.lock()
        theme = next
        lock.unlock()
    }
}

/// What `GET /api/dashboard-theme` answers for a theme: its kit when a fixture has one, and "unsupported" when none does.
private func themeBody(for theme: String?) -> String {
    guard let theme else { return #"{"theme":null,"kit":null}"# }
    let kit = StyleKitFixtures.all.first { $0.id == theme }
    guard let kit, let data = try? JSONEncoder().encode(kit) else {
        return #"{"theme":"\#(theme)","kit":null,"reason":"unsupported"}"#
    }
    return #"{"theme":"\#(theme)","kit":\#(String(decoding: data, as: UTF8.self))}"#
}

/// The `theme` of a `PATCH` body: the id, "null" for an explicit null, "missing" for no such key.
private func patchedTheme(_ body: Data?) -> String {
    guard let body, let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any], let value = object["theme"] else {
        return "missing"
    }
    return (value as? String) ?? "null"
}

/// What the Appearance pane holds: the theme the account wears, a change the server must agree to, the look the answer brings,
/// and the phone with no connection.
@MainActor
final class AppearanceModelTests: XCTestCase {
    /// The catalog `GET /api/capabilities` lists, as the server writes it.
    private let catalog: [Capabilities.ThemeInfo] = {
        let json = """
        [{"id":"modern-dark","name":"Modern Dark","mode":"dark"},{"id":"glassmorphism","name":"Glassmorphism","mode":"dark"},\
        {"id":"newsprint","name":"Newsprint","mode":"light"},{"id":"retro","name":"Retro","mode":"light"}]
        """
        return (try? JSONDecoder().decode([Capabilities.ThemeInfo].self, from: Data(json.utf8))) ?? []
    }()

    // MARK: Helpers

    /// A server that holds `server`'s theme, answers `GET` with its kit, and takes a `PATCH` for any theme but `rejecting`.
    private func transport(_ server: ThemeServer, rejecting: Set<String> = []) -> MockTransport {
        MockTransport(routes: [
            MockRoute(.get, "/api/dashboard-theme") { _ in
                HTTPResponse(status: 200, headers: ["content-type": "application/json"], data: Data(themeBody(for: server.current).utf8))
            },
            MockRoute(.patch, "/api/dashboard-theme") { request in
                let sent = patchedTheme(request.httpBody)
                if rejecting.contains(sent) {
                    return HTTPResponse(status: 400, headers: ["content-type": "application/json"], data: Data(#"{"error":"Unknown theme."}"#.utf8))
                }
                let next: String? = (sent == "null" || sent == "missing") ? nil : sent
                server.set(next)
                var reply = themeBody(for: next)
                reply.removeLast()
                reply += #","message":"Your dashboard now wears it."}"#
                return HTTPResponse(status: 200, headers: ["content-type": "application/json"], data: Data(reply.utf8))
            },
        ])
    }

    private struct Rig {
        let model: AppearanceModel
        let style: StyleKitStore
        let wearer: RecordingWearer
        let transport: any HTTPTransport
        let loader: StyleKitLoader
        let cache: DiskCache
    }

    private func makeRig(_ transport: any HTTPTransport, cache: DiskCache? = nil, style existing: StyleKitStore? = nil, wearer existingWearer: RecordingWearer? = nil) -> Rig {
        let cache = cache ?? DiskCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("hv-appearance-" + UUID().uuidString))
        let client = HVClient(baseURL: URL(string: "https://hv.test")!, transport: transport, tokens: StaticTokenProvider(), retry: .none)
        let profiles = AccountRest(client: HVClient(baseURL: URL(string: "https://proj.supabase.test")!, transport: transport, tokens: StaticTokenProvider(), retry: .none), anonKey: "anon-key")
        let loader = StyleKitLoader(client: client, rest: profiles, cache: cache, userID: "user-1", serverSendsKits: true)
        let wearer = existingWearer ?? RecordingWearer()
        let suite = "hv-appearance-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let style = existing ?? StyleKitStore(defaults: defaults, wearer: wearer)
        return Rig(model: AppearanceModel(client: client, loader: loader, style: style, catalog: catalog), style: style, wearer: wearer, transport: transport, loader: loader, cache: cache)
    }

    /// What each `PATCH` carried: the id, "null" or "missing".
    private func patches(_ transport: any HTTPTransport) async -> [String] {
        guard let mock = transport as? MockTransport else { return [] }
        let sent = await mock.requests(matching: "/api/dashboard-theme").filter { $0.httpMethod == "PATCH" }
        return sent.map { patchedTheme($0.httpBody) }
    }

    // MARK: Loading

    func testLoadShowsTheThemeTheAccountHoldsAndWearsItsKit() async {
        let rig = makeRig(transport(ThemeServer(theme: "glassmorphism")))
        await rig.model.load()
        XCTAssertEqual(rig.model.phase, .loaded)
        XCTAssertEqual(rig.model.stored, "glassmorphism")
        XCTAssertEqual(rig.model.selection, "glassmorphism")
        XCTAssertFalse(rig.model.isOffline)
        XCTAssertEqual(rig.wearer.last, StyleKitFixtures.glassmorphism)
        XCTAssertEqual(rig.model.wearingLine, "The app is wearing Glassmorphism.")
        // The server moved Glassmorphism's primary to read as text, which the person can see as the theme's colour.
        XCTAssertEqual(rig.model.adjustedLine, "Some colours are adjusted so text stays easy to read.")
    }

    func testNothingIsSaidAboutAColourOnlyAnErrorRedMoved() async {
        // Newsprint's only adjustment is its destructive red, not a colour the person sees as the theme's.
        let rig = makeRig(transport(ThemeServer(theme: "newsprint")))
        await rig.model.load()
        XCTAssertEqual(rig.model.wearingLine, "The app is wearing Newsprint.")
        XCTAssertNil(rig.model.adjustedLine)
    }

    func testNoThemeIsTheDefaultLookAndSaysSo() async {
        let rig = makeRig(transport(ThemeServer(theme: nil)))
        await rig.model.load()
        XCTAssertNil(rig.model.stored)
        XCTAssertNil(rig.model.selection)
        XCTAssertNil(rig.wearer.last)
        XCTAssertEqual(rig.model.wearingLine, "The app is wearing the HyperVault default look.")
    }

    func testAdjustedColoursAreSaid() async {
        let rig = makeRig(transport(ThemeServer(theme: "aurora-mesh")))
        await rig.model.load()
        // The picker only offers what the catalog lists; the look is still the server's answer.
        XCTAssertEqual(rig.model.adjustedLine, "Some colours are adjusted so text stays easy to read.")
    }

    func testATheWithNoKitIsNamedAndTheAppKeepsItsOwnLook() async {
        let rig = makeRig(transport(ThemeServer(theme: "retro")))
        await rig.model.load()
        XCTAssertEqual(rig.model.selection, "retro")
        XCTAssertNil(rig.wearer.last)
        XCTAssertEqual(rig.model.wearingLine, "Retro can't be shown in the app, so it keeps the HyperVault default look. Your website still wears it.")
    }

    func testTheSwitchOffIsSaidAndTheThemeStaysChosen() async {
        let rig = makeRig(transport(ThemeServer(theme: "newsprint")))
        await rig.model.load()
        rig.style.setAppliesToApp(false)
        XCTAssertEqual(rig.model.selection, "newsprint")
        XCTAssertNil(rig.wearer.last)
        XCTAssertEqual(rig.model.wearingLine, "The app keeps the HyperVault default look.")
    }

    func testAFirstReadThatFailsWithNothingKeptIsAFailure() async {
        let rig = makeRig(MockTransport(routes: [.failure(.get, "/api/dashboard-theme", status: 500, message: "Could not read your theme.")]))
        await rig.model.load()
        guard case .failed(let message) = rig.model.phase else { return XCTFail("\(rig.model.phase)") }
        XCTAssertEqual(message, "Could not read your theme.")
    }

    // MARK: Offline

    func testOfflineWithAKeptLookShowsItAndSaysTheServerIsOutOfReach() async throws {
        let cache = DiskCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("hv-appearance-" + UUID().uuidString))
        // The last launch kept Newsprint.
        let first = makeRig(transport(ThemeServer(theme: "newsprint")), cache: cache)
        await first.model.load()
        XCTAssertEqual(first.wearer.last, StyleKitFixtures.newsprint)

        // This one has the disk and no connection.
        let wearer = RecordingWearer()
        let suite = "hv-appearance-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let style = StyleKitStore(defaults: defaults, wearer: wearer)
        await style.preload(cache: cache, userID: "user-1")
        let offline = makeRig(OfflineTransport(), cache: cache, style: style, wearer: wearer)

        await offline.model.load()
        XCTAssertEqual(offline.model.phase, .loaded)
        XCTAssertTrue(offline.model.isOffline)
        XCTAssertEqual(offline.model.stored, "newsprint", "the pane shows what the phone kept")
        XCTAssertEqual(wearer.last, StyleKitFixtures.newsprint, "the look already worn is not touched")
        XCTAssertNil(offline.model.problem)
    }

    func testChangingTheThemeNeedsAConnection() async {
        let cache = DiskCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("hv-appearance-" + UUID().uuidString))
        let wearer = RecordingWearer()
        let suite = "hv-appearance-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let style = StyleKitStore(defaults: defaults, wearer: wearer)
        style.adopt(DashboardThemeState(theme: "newsprint", kit: StyleKitFixtures.newsprint))
        let offline = makeRig(OfflineTransport(), cache: cache, style: style, wearer: wearer)
        await offline.model.load()
        XCTAssertTrue(offline.model.isOffline)

        await offline.model.choose("glassmorphism")
        XCTAssertEqual(offline.model.stored, "newsprint")
        XCTAssertFalse(offline.model.isSaving)
        XCTAssertNil(offline.model.confirmation)
        XCTAssertEqual(wearer.last, StyleKitFixtures.newsprint)
    }

    func testTryingAgainOnceTheServerAnswersLeavesOfflineMode() async {
        let cache = DiskCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("hv-appearance-" + UUID().uuidString))
        let wearer = RecordingWearer()
        let suite = "hv-appearance-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let style = StyleKitStore(defaults: defaults, wearer: wearer)
        style.adopt(DashboardThemeState(theme: "newsprint", kit: StyleKitFixtures.newsprint))

        let offline = makeRig(OfflineTransport(), cache: cache, style: style, wearer: wearer)
        await offline.model.load()
        XCTAssertTrue(offline.model.isOffline)

        let online = makeRig(transport(ThemeServer(theme: "glassmorphism")), cache: cache, style: style, wearer: wearer)
        await online.model.load()
        XCTAssertFalse(online.model.isOffline)
        XCTAssertEqual(online.model.stored, "glassmorphism")
        XCTAssertEqual(wearer.last, StyleKitFixtures.glassmorphism)
    }

    func testTryingAgainAndMeetingAServerErrorSaysSoAndIsNoLongerOffline() async {
        let wearer = RecordingWearer()
        let suite = "hv-appearance-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let style = StyleKitStore(defaults: defaults, wearer: wearer)
        style.adopt(DashboardThemeState(theme: "newsprint", kit: StyleKitFixtures.newsprint))
        let server = Flaky(inner: MockTransport(routes: [.failure(.get, "/api/dashboard-theme", status: 500, message: "Could not read your theme.")]))
        await server.setOnline(false)
        let rig = makeRig(server, style: style, wearer: wearer)

        await rig.model.load()
        XCTAssertTrue(rig.model.isOffline)
        XCTAssertNil(rig.model.problem)

        // Try again: the phone is back, and the server answers with an error. That is not "no connection", and it is not silent.
        await server.setOnline(true)
        await rig.model.load()
        XCTAssertEqual(rig.model.phase, .loaded)
        XCTAssertFalse(rig.model.isOffline)
        XCTAssertEqual(rig.model.problem, "Could not read your theme.")
        XCTAssertEqual(wearer.last, StyleKitFixtures.newsprint, "the look already worn is not touched")
    }

    // MARK: Choosing

    func testChoosingSendsItWearsTheAnswersKitAndConfirmsInWords() async {
        let server = ThemeServer(theme: "glassmorphism")
        let rig = makeRig(transport(server))
        await rig.model.load()

        await rig.model.choose("newsprint")
        let sent = await patches(rig.transport)
        XCTAssertEqual(sent, ["newsprint"])
        XCTAssertEqual(rig.model.stored, "newsprint")
        XCTAssertEqual(rig.wearer.last, StyleKitFixtures.newsprint, "the answer carried the kit, so the app wears it now")
        XCTAssertEqual(rig.model.confirmation, "Your website and this app now wear Newsprint.")
        XCTAssertNil(rig.model.problem)
        let kept = await rig.loader.cached()
        XCTAssertEqual(kept?.theme, "newsprint", "and the phone keeps it for the next launch")
    }

    func testTheConfirmationDoesNotClaimTheAppWhenThePhoneKeepsItOut() async {
        let rig = makeRig(transport(ThemeServer(theme: nil)))
        await rig.model.load()
        rig.style.setAppliesToApp(false)
        await rig.model.choose("newsprint")
        XCTAssertEqual(rig.model.confirmation, "Your website now wears Newsprint.")
        XCTAssertNil(rig.wearer.last)
    }

    func testATheWithNoKitIsConfirmedForTheWebsiteOnly() async {
        let rig = makeRig(transport(ThemeServer(theme: nil)))
        await rig.model.load()
        await rig.model.choose("retro")
        XCTAssertEqual(rig.model.confirmation, "Your website now wears Retro.")
        XCTAssertNil(rig.wearer.last)
        XCTAssertEqual(rig.model.wearingLine, "Retro can't be shown in the app, so it keeps the HyperVault default look. Your website still wears it.")
    }

    func testARefusedChangeLeavesTheThemeAndTheLookAlone() async {
        let rig = makeRig(transport(ThemeServer(theme: "glassmorphism"), rejecting: ["newsprint"]))
        await rig.model.load()

        await rig.model.choose("newsprint")
        XCTAssertEqual(rig.model.stored, "glassmorphism")
        XCTAssertEqual(rig.model.problem, "Unknown theme.")
        XCTAssertNil(rig.model.confirmation)
        XCTAssertNil(rig.model.undo)
        XCTAssertEqual(rig.wearer.last, StyleKitFixtures.glassmorphism)
        XCTAssertEqual(rig.wearer.calls, 1, "nothing was re-worn")
    }

    func testAChangeAnsweredAfterTheSessionEndedIsNeitherWornNorSaid() async {
        let hold = RequestHold()
        await hold.arm()
        let base = transport(ThemeServer(theme: "glassmorphism"))
        let held = HeldTransport(base: base, hold: hold, holds: { $0.httpMethod == "PATCH" })
        let rig = makeRig(held)
        await rig.model.load()
        XCTAssertEqual(rig.wearer.last, StyleKitFixtures.glassmorphism)

        // The person picks Newsprint, and signs out while the server is still answering.
        let choosing = Task { await rig.model.choose("newsprint") }
        while await hold.waiting == 0 { await Task.yield() }
        rig.style.reset()
        await hold.release()
        await choosing.value

        XCTAssertNil(rig.wearer.last, "the sign-in screen is not drawn in the old account's theme")
        XCTAssertNil(rig.style.state)
        XCTAssertNil(rig.model.confirmation, "and nothing is announced about an account that has gone")
        XCTAssertFalse(rig.model.isSaving)
        let onDisk = await rig.loader.cached()
        XCTAssertEqual(onDisk?.theme, "glassmorphism", "nor written to the phone: the disk holds what the first read left")
    }

    func testChoosingTheOneAlreadyChosenSendsNothing() async {
        let rig = makeRig(transport(ThemeServer(theme: "newsprint")))
        await rig.model.load()
        await rig.model.choose("newsprint")
        let sent = await patches(rig.transport)
        XCTAssertEqual(sent, [])
    }

    func testTheDefaultLookIsNullOnTheWireAndTheAppTakesItsLookBack() async {
        let rig = makeRig(transport(ThemeServer(theme: "newsprint")))
        await rig.model.load()
        XCTAssertEqual(rig.wearer.last, StyleKitFixtures.newsprint)

        await rig.model.choose(nil)
        let sent = await patches(rig.transport)
        XCTAssertEqual(sent, ["null"], "an explicit null, not a missing key")
        XCTAssertNil(rig.model.stored)
        XCTAssertNil(rig.wearer.last)
        XCTAssertEqual(rig.model.confirmation, "Your website and this app are back on the HyperVault default look.")
    }

    // MARK: Undo

    func testUndoPutsThePreviousChoiceBackOnceAndThenIsGone() async {
        let rig = makeRig(transport(ThemeServer(theme: "glassmorphism")))
        await rig.model.load()
        XCTAssertNil(rig.model.undo)

        await rig.model.choose("newsprint")
        XCTAssertEqual(rig.model.undo, AppearanceModel.Undo(themeID: "glassmorphism"))

        await rig.model.undoLastChange()
        XCTAssertEqual(rig.model.stored, "glassmorphism")
        XCTAssertEqual(rig.wearer.last, StyleKitFixtures.glassmorphism)
        XCTAssertNil(rig.model.undo, "there is no undo of an undo")
        let sent = await patches(rig.transport)
        XCTAssertEqual(sent, ["newsprint", "glassmorphism"])
    }

    func testUndoFromTheDefaultLookGoesBackToIt() async {
        let rig = makeRig(transport(ThemeServer(theme: nil)))
        await rig.model.load()
        await rig.model.choose("newsprint")
        XCTAssertEqual(rig.model.undo, AppearanceModel.Undo(themeID: nil))
        await rig.model.undoLastChange()
        XCTAssertNil(rig.model.stored)
        XCTAssertNil(rig.wearer.last)
    }
}
