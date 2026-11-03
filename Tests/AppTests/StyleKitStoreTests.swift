import Foundation
import HyperVaultKit
import XCTest
@testable import HyperVault

/// Records what it is asked to wear, so the store is tried without the process's runtime. Only the main actor's tests use it.
final class RecordingWearer: StyleWearer {
    private(set) var asked: [StyleKit?] = []
    var last: StyleKit? { asked.last ?? nil }
    var calls: Int { asked.count }

    func wear(_ kit: StyleKit?) {
        asked.append(kit)
    }
}

/// The store that decides what the app wears: the look on disk first, then the server, per person, with the phone's own
/// switch, and dropping an answer that something newer has overtaken.
@MainActor
final class StyleKitStoreTests: XCTestCase {
    // MARK: Helpers

    private func hv(_ transport: any HTTPTransport) -> HVClient {
        HVClient(baseURL: URL(string: "https://hv.test")!, transport: transport, tokens: StaticTokenProvider(), retry: .none)
    }

    private func rest(_ transport: any HTTPTransport) -> AccountRest {
        AccountRest(client: HVClient(baseURL: URL(string: "https://proj.supabase.test")!, transport: transport, tokens: StaticTokenProvider(), retry: .none), anonKey: "anon-key")
    }

    private func tempCache() -> DiskCache {
        DiskCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("hv-style-" + UUID().uuidString))
    }

    private func defaults() -> UserDefaults {
        let name = "hv-style-tests-" + UUID().uuidString
        let suite = UserDefaults(suiteName: name)!
        suite.removePersistentDomain(forName: name)
        return suite
    }

    private func makeLoader(_ api: any HTTPTransport, cache: DiskCache, user: String = "user-1", kits: Bool = true, profiles: any HTTPTransport = MockTransport()) -> StyleKitLoader {
        StyleKitLoader(client: hv(api), rest: rest(profiles), cache: cache, userID: user, serverSendsKits: kits)
    }

    private func makeStore(_ wearer: RecordingWearer, defaults: UserDefaults? = nil, now: @escaping () -> Date = Date.init) -> StyleKitStore {
        StyleKitStore(defaults: defaults ?? self.defaults(), wearer: wearer, now: now)
    }

    private func json(_ kit: StyleKit) throws -> String {
        String(decoding: try JSONEncoder().encode(kit), as: UTF8.self)
    }

    /// The body `GET /api/dashboard-theme` answers for a kit.
    private func answer(_ kit: StyleKit) throws -> String {
        let body = try json(kit)
        return #"{"theme":"\#(kit.id)","kit":\#(body)}"#
    }

    private func canned(_ kit: StyleKit?) throws -> MockTransport {
        let body = try kit.map { try answer($0) } ?? #"{"theme":null,"kit":null}"#
        return MockTransport(routes: [.json(.get, "/api/dashboard-theme", body)])
    }

    // MARK: Wearing a state

    func testAKitIsWornAndTheLookSaysSo() {
        let wearer = RecordingWearer()
        let store = makeStore(wearer)
        store.adopt(DashboardThemeState(theme: "newsprint", kit: StyleKitFixtures.newsprint))
        XCTAssertEqual(wearer.last, StyleKitFixtures.newsprint)
        XCTAssertEqual(store.look, .worn(name: "Newsprint", adjusted: false))
        XCTAssertTrue(store.look.isWorn)
    }

    func testAnAdjustedBrandColourIsSaid() {
        let wearer = RecordingWearer()
        let store = makeStore(wearer)
        // Aurora Mesh's violet primary is moved to read as text.
        XCTAssertTrue(StyleKitFixtures.auroraMesh.hasNoticeableAdjustments)
        store.adopt(DashboardThemeState(theme: "aurora-mesh", kit: StyleKitFixtures.auroraMesh))
        XCTAssertEqual(store.look, .worn(name: StyleKitFixtures.auroraMesh.name, adjusted: true))
    }

    func testNoThemeIsTheAppsOwnLookAndWearsNothing() {
        let wearer = RecordingWearer()
        let store = makeStore(wearer)
        store.adopt(.stock)
        XCTAssertEqual(store.look, .standard)
        XCTAssertNil(wearer.last)
        XCTAssertEqual(wearer.calls, 0, "nothing was worn, so nothing is taken off")
    }

    func testAThemeWithNoKitKeepsTheAppsOwnLookAndTheLookSaysItCannotBeShown() {
        let wearer = RecordingWearer()
        let store = makeStore(wearer)
        store.adopt(DashboardThemeState(theme: "retro", kit: nil, reason: .unsupported))
        XCTAssertEqual(store.look, .withheld(themeID: "retro"))
        XCTAssertNil(wearer.last)

        // A kit this build cannot read arrives as one with no kit, too.
        store.adopt(DashboardThemeState(theme: "mystery", kit: nil, reason: .invalid))
        XCTAssertEqual(store.look, .withheld(themeID: "mystery"))
    }

    func testAStoredIdTheServerNoLongerHasIsTheAppsOwnLookWithNoNote() {
        let store = makeStore(RecordingWearer())
        store.adopt(DashboardThemeState(theme: "gone", kit: nil, reason: .unknown))
        XCTAssertEqual(store.look, .standard)
    }

    func testAKitThatFailsTheFloorsIsNeverWorn() {
        let wearer = RecordingWearer()
        let store = makeStore(wearer)
        var kit = StyleKitFixtures.newsprint
        kit.colors.foreground = kit.colors.background
        XCTAssertFalse(kit.violations.isEmpty)
        store.adopt(DashboardThemeState(theme: "newsprint", kit: kit))
        XCTAssertEqual(store.look, .withheld(themeID: "newsprint"), "the state made it `invalid`, and the store keeps the app's own look")
        XCTAssertNil(wearer.last)
    }

    func testTheSameStateAgainRepaintsNothing() {
        let wearer = RecordingWearer()
        let store = makeStore(wearer)
        let state = DashboardThemeState(theme: "newsprint", kit: StyleKitFixtures.newsprint)
        store.adopt(state)
        store.adopt(state)
        store.adopt(DashboardThemeState(theme: "newsprint", kit: StyleKitFixtures.newsprint))
        XCTAssertEqual(wearer.calls, 1)
    }

    func testAnotherKitReplacesTheOne() {
        let wearer = RecordingWearer()
        let store = makeStore(wearer)
        store.adopt(DashboardThemeState(theme: "newsprint", kit: StyleKitFixtures.newsprint))
        store.adopt(DashboardThemeState(theme: "glassmorphism", kit: StyleKitFixtures.glassmorphism))
        XCTAssertEqual(wearer.last, StyleKitFixtures.glassmorphism)
        store.adopt(.stock)
        XCTAssertNil(wearer.last)
        XCTAssertEqual(wearer.calls, 3)
    }

    // MARK: The phone's switch

    func testTheSwitchIsOnUntilTheyTurnItOff() {
        XCTAssertTrue(makeStore(RecordingWearer()).appliesToApp)
        XCTAssertEqual(PrefKey.styleKitInApp, "pref.styleKit.inApp")
    }

    func testTurningTheSwitchOffTakesTheThemeOffTheAppAndKeepsItInTheState() {
        let wearer = RecordingWearer()
        let suite = defaults()
        let store = makeStore(wearer, defaults: suite)
        store.adopt(DashboardThemeState(theme: "newsprint", kit: StyleKitFixtures.newsprint))

        store.setAppliesToApp(false)
        XCTAssertFalse(store.appliesToApp)
        XCTAssertNil(wearer.last, "the app keeps its own look")
        XCTAssertEqual(store.look, .off(name: "Newsprint"))
        XCTAssertEqual(store.state?.theme, "newsprint", "the website keeps the theme either way")
        XCTAssertEqual(suite.object(forKey: PrefKey.styleKitInApp) as? Bool, false, "kept on this phone")

        store.setAppliesToApp(true)
        XCTAssertEqual(wearer.last, StyleKitFixtures.newsprint)
        XCTAssertEqual(store.look, .worn(name: "Newsprint", adjusted: false))
    }

    func testTheSwitchIsReadBackAtTheNextLaunchAndAnAnswerRespectsIt() {
        let suite = defaults()
        makeStore(RecordingWearer(), defaults: suite).setAppliesToApp(false)

        let wearer = RecordingWearer()
        let next = makeStore(wearer, defaults: suite)
        XCTAssertFalse(next.appliesToApp)
        next.adopt(DashboardThemeState(theme: "newsprint", kit: StyleKitFixtures.newsprint))
        XCTAssertNil(wearer.last)
        XCTAssertEqual(next.look, .off(name: "Newsprint"))
    }

    func testTheSwitchWithNothingToWearChangesNothing() {
        let wearer = RecordingWearer()
        let store = makeStore(wearer)
        store.setAppliesToApp(false)
        store.setAppliesToApp(true)
        XCTAssertEqual(store.look, .standard)
        XCTAssertEqual(wearer.calls, 0)
    }

    // MARK: The disk first

    func testPreloadWearsTheCachedLookWithNoNetwork() async throws {
        let cache = tempCache()
        let transport = try canned(StyleKitFixtures.newsprint)
        _ = try await makeLoader(transport, cache: cache).refresh()
        let before = await transport.requests.count

        let wearer = RecordingWearer()
        let store = makeStore(wearer)
        await store.preload(cache: cache, userID: "user-1")
        XCTAssertEqual(wearer.last, StyleKitFixtures.newsprint)
        XCTAssertEqual(store.state?.theme, "newsprint")
        let after = await transport.requests.count
        XCTAssertEqual(after, before, "the first frame does not wait for the network")
    }

    func testPreloadFindsNothingForAnotherPersonOrAnEmptyCache() async throws {
        let cache = tempCache()
        _ = try await makeLoader(try canned(StyleKitFixtures.newsprint), cache: cache, user: "user-1").refresh()
        let wearer = RecordingWearer()
        let store = makeStore(wearer)
        await store.preload(cache: cache, userID: "user-2")
        XCTAssertNil(store.state)
        XCTAssertNil(wearer.last)
        XCTAssertEqual(store.look, .standard)
    }

    // MARK: The network

    func testRefreshWearsTheAnswerAndKeepsItOnDisk() async throws {
        let cache = tempCache()
        let transport = try canned(StyleKitFixtures.glassmorphism)
        let wearer = RecordingWearer()
        let store = makeStore(wearer)
        let loader = makeLoader(transport, cache: cache)

        try await store.refresh(using: loader)
        XCTAssertEqual(wearer.last, StyleKitFixtures.glassmorphism)
        let kept = await loader.cached()
        XCTAssertEqual(kept?.theme, "glassmorphism")
    }

    func testRefreshReplacesTheLookOnDisk() async throws {
        let cache = tempCache()
        _ = try await makeLoader(try canned(StyleKitFixtures.newsprint), cache: cache).refresh()
        let wearer = RecordingWearer()
        let store = makeStore(wearer)
        await store.preload(cache: cache, userID: "user-1")
        XCTAssertEqual(wearer.last, StyleKitFixtures.newsprint)

        let fresh = makeLoader(try canned(StyleKitFixtures.glassmorphism), cache: cache)
        try await store.refresh(using: fresh)
        XCTAssertEqual(wearer.last, StyleKitFixtures.glassmorphism)
        let kept = await fresh.cached()
        XCTAssertEqual(kept?.theme, "glassmorphism")
    }

    func testAnAnswerThatChangedNothingRepaintsNothing() async throws {
        let cache = tempCache()
        let loader = makeLoader(try canned(StyleKitFixtures.newsprint), cache: cache)
        let wearer = RecordingWearer()
        let store = makeStore(wearer)
        try await store.refresh(using: loader)
        try await store.refresh(using: loader)
        try await store.refresh(using: loader)
        XCTAssertEqual(wearer.calls, 1, "a foreground refresh that found the same theme does not repaint the tree")
    }

    func testAFailedRefreshThrowsAndLeavesTheLookWorn() async throws {
        let cache = tempCache()
        _ = try await makeLoader(try canned(StyleKitFixtures.newsprint), cache: cache).refresh()
        let wearer = RecordingWearer()
        let store = makeStore(wearer)
        await store.preload(cache: cache, userID: "user-1")

        let offline = makeLoader(OfflineTransport(), cache: cache)
        do {
            try await store.refresh(using: offline)
            XCTFail("an unreachable server is a failure")
        } catch {
            guard case .transport = error as? HVError else { return XCTFail("An unreachable server is a transport failure, not \(error)") }
        }
        XCTAssertEqual(wearer.last, StyleKitFixtures.newsprint)
        XCTAssertEqual(wearer.calls, 1)
        XCTAssertEqual(store.look, .worn(name: "Newsprint", adjusted: false))
    }

    func testAServerError500IsNotNoTheme() async throws {
        let cache = tempCache()
        let wearer = RecordingWearer()
        let store = makeStore(wearer)
        store.adopt(DashboardThemeState(theme: "newsprint", kit: StyleKitFixtures.newsprint))
        let broken = MockTransport(routes: [.failure(.get, "/api/dashboard-theme", status: 500, message: "Could not read your theme.")])
        do {
            try await store.refresh(using: makeLoader(broken, cache: cache))
            XCTFail("a 500 is a failure")
        } catch {}
        XCTAssertEqual(wearer.last, StyleKitFixtures.newsprint, "a blip does not flip the app to its default look")
    }

    func testAServerWithNoKitsIsAskedForTheIdAndTheThemeIsOneTheAppCannotShow() async throws {
        let cache = tempCache()
        let profiles = MockTransport(routes: [.json(.get, "/rest/v1/profiles", #"[{"theme":"glassmorphism"}]"#)])
        let api = MockTransport()
        let wearer = RecordingWearer()
        let store = makeStore(wearer)
        try await store.refresh(using: makeLoader(api, cache: cache, kits: false, profiles: profiles))
        let asked = await api.requests.count
        XCTAssertEqual(asked, 0, "the GET is not even tried")
        XCTAssertEqual(store.look, .withheld(themeID: "glassmorphism"))
        XCTAssertNil(wearer.last)
    }

    func testAKitOfAnotherSchemaIsWithheldNotHalfRead() async throws {
        let cache = tempCache()
        let body = #"{"theme":"newsprint","kit":{"schema_version":2,"id":"newsprint","appearance":"light","colors":{}}}"#
        let wearer = RecordingWearer()
        let store = makeStore(wearer)
        try await store.refresh(using: makeLoader(MockTransport(routes: [.json(.get, "/api/dashboard-theme", body)]), cache: cache))
        XCTAssertEqual(store.look, .withheld(themeID: "newsprint"))
        XCTAssertNil(wearer.last)
    }

    // MARK: Choosing

    func testKeepWearsASavedChoiceAndRemembersItWithoutAskingAgain() async throws {
        let cache = tempCache()
        let transport = MockTransport()
        let loader = makeLoader(transport, cache: cache)
        let wearer = RecordingWearer()
        let store = makeStore(wearer)
        await store.keep(DashboardThemeState(theme: "newsprint", kit: StyleKitFixtures.newsprint), using: loader, since: store.sessionMark)
        XCTAssertEqual(wearer.last, StyleKitFixtures.newsprint)
        let kept = await loader.cached()
        XCTAssertEqual(kept?.theme, "newsprint")
        let asked = await transport.requests.count
        XCTAssertEqual(asked, 0)
    }

    func testAnAnswerThatWasOvertakenByAChoiceIsDroppedAndNotKept() async throws {
        let cache = tempCache()
        let hold = RequestHold()
        await hold.arm()
        let base = try canned(StyleKitFixtures.newsprint)
        let held = HeldTransport(base: base, hold: hold, holds: { $0.url?.path == "/api/dashboard-theme" })
        let slow = makeLoader(held, cache: cache)
        let wearer = RecordingWearer()
        let store = makeStore(wearer)

        let refreshing = Task { try? await store.refresh(using: slow) }
        // The refresh is out; meanwhile the person chooses Glassmorphism.
        while await hold.waiting == 0 { await Task.yield() }
        await store.keep(DashboardThemeState(theme: "glassmorphism", kit: StyleKitFixtures.glassmorphism), using: slow, since: store.sessionMark)
        await hold.release()
        await refreshing.value

        XCTAssertEqual(wearer.last, StyleKitFixtures.glassmorphism, "the old answer does not undo the newer choice")
        let kept = await slow.cached()
        XCTAssertEqual(kept?.theme, "glassmorphism", "and is not written over it on disk")
    }

    func testAnAnswerThatWasOvertakenByASignOutIsDroppedAndNotKept() async throws {
        let cache = tempCache()
        let hold = RequestHold()
        await hold.arm()
        let held = HeldTransport(base: try canned(StyleKitFixtures.newsprint), hold: hold, holds: { $0.url?.path == "/api/dashboard-theme" })
        let slow = makeLoader(held, cache: cache)
        let wearer = RecordingWearer()
        let store = makeStore(wearer)

        let refreshing = Task { try? await store.refresh(using: slow) }
        while await hold.waiting == 0 { await Task.yield() }
        store.reset()
        await hold.release()
        await refreshing.value

        XCTAssertNil(wearer.last)
        XCTAssertNil(store.state)
        let kept = await slow.cached()
        XCTAssertNil(kept, "nothing of the account is written after it has gone")
    }

    func testAPatchAnswerThatArrivesAfterASignOutIsDroppedAndNotKept() async throws {
        let cache = tempCache()
        let loader = makeLoader(MockTransport(), cache: cache)
        let wearer = RecordingWearer()
        let store = makeStore(wearer)

        // The PATCH goes out in one session; the person signs out while it is on its way, and its answer comes in after.
        let mark = store.sessionMark
        store.reset()
        let kept = await store.keep(DashboardThemeState(theme: "newsprint", kit: StyleKitFixtures.newsprint), using: loader, since: mark)

        XCTAssertFalse(kept, "the answer belongs to the session that ended")
        XCTAssertNil(wearer.last, "the sign-in screen is not drawn in the old account's theme")
        XCTAssertNil(store.state)
        XCTAssertEqual(store.look, .standard)
        let onDisk = await loader.cached()
        XCTAssertNil(onDisk, "and the old account's theme is not written after its cache has gone")
    }

    // MARK: Signing out

    func testResetGoesBackToTheAppsOwnLookAndKeepsThePhonesSwitch() {
        let wearer = RecordingWearer()
        let store = makeStore(wearer)
        store.setAppliesToApp(false)
        store.setAppliesToApp(true)
        store.adopt(DashboardThemeState(theme: "newsprint", kit: StyleKitFixtures.newsprint))
        XCTAssertEqual(wearer.last, StyleKitFixtures.newsprint)

        store.reset()
        XCTAssertNil(wearer.last)
        XCTAssertNil(store.state)
        XCTAssertEqual(store.look, .standard)
        XCTAssertTrue(store.appliesToApp)

        // The next person starts from nothing, and the same state is news again.
        store.adopt(DashboardThemeState(theme: "newsprint", kit: StyleKitFixtures.newsprint))
        XCTAssertEqual(wearer.last, StyleKitFixtures.newsprint)
    }

    // MARK: Following the website

    func testTheForegroundAskIsRateLimited() async throws {
        let cache = tempCache()
        let transport = try canned(StyleKitFixtures.newsprint)
        let loader = makeLoader(transport, cache: cache)
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let store = makeStore(RecordingWearer(), now: { clock })

        await store.refreshIfStale(using: loader)
        var asked = await transport.requests.count
        XCTAssertEqual(asked, 1, "the first ask goes out")

        clock = clock.addingTimeInterval(60)
        await store.refreshIfStale(using: loader)
        asked = await transport.requests.count
        XCTAssertEqual(asked, 1, "a minute later it does not")

        clock = clock.addingTimeInterval(15 * 60)
        await store.refreshIfStale(using: loader)
        asked = await transport.requests.count
        XCTAssertEqual(asked, 2, "after fifteen minutes it does")
    }

    func testTheForegroundAskFailingSaysNothingAndLeavesTheLook() async {
        let wearer = RecordingWearer()
        let store = makeStore(wearer)
        store.adopt(DashboardThemeState(theme: "newsprint", kit: StyleKitFixtures.newsprint))
        await store.refreshIfStale(using: makeLoader(OfflineTransport(), cache: tempCache()))
        XCTAssertEqual(wearer.last, StyleKitFixtures.newsprint)
    }
}
