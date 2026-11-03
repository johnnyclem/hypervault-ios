import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HyperVaultKit

/// The loader that keeps the person's look on disk for the next launch: the repo's cached-then-fresh pattern, in the
/// person's cache namespace, with the Supabase read of `profiles.theme` as the way to ask a server that sends no kits.
final class StyleKitLoaderTests: XCTestCase {
    private func hv(_ transport: MockTransport) -> HVClient {
        HVClient(baseURL: URL(string: "https://hv.test")!, transport: transport, tokens: StaticTokenProvider(), retry: .none)
    }

    private func rest(_ transport: MockTransport) -> AccountRest {
        AccountRest(client: HVClient(baseURL: URL(string: "https://proj.supabase.test")!, transport: transport, tokens: StaticTokenProvider(), retry: .none), anonKey: "anon-key")
    }

    private func tempCache() -> DiskCache {
        DiskCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("hv-stylekit-" + UUID().uuidString))
    }

    /// The body `GET /api/dashboard-theme` answers for a golden.
    private func envelope(_ name: String = "newsprint", theme: String? = nil) throws -> String {
        let kit = String(decoding: try StyleKitFixtures.data(name), as: UTF8.self)
        return #"{"theme":"\#(theme ?? name)","kit":\#(kit)}"#
    }

    // MARK: The loader

    private func makeLoader(
        _ api: MockTransport, _ profiles: MockTransport = MockTransport(), cache: DiskCache, user: String = "user-1", kits: Bool = true
    ) -> StyleKitLoader {
        StyleKitLoader(client: hv(api), rest: rest(profiles), cache: cache, userID: user, serverSendsKits: kits)
    }

    func testRefreshAsksTheServerKeepsTheAnswerAndReturnsIt() async throws {
        let cache = tempCache()
        let api = MockTransport(routes: [.json(.get, "/api/dashboard-theme", try envelope())])
        let profiles = MockTransport()
        let loader = makeLoader(api, profiles, cache: cache)

        let nothing = await loader.cached()
        XCTAssertNil(nothing, "nothing is on disk before the first refresh")
        let fresh = try await loader.refresh()
        XCTAssertEqual(fresh.kit, try StyleKitFixtures.kit("newsprint"))
        let kept = await loader.cached()
        XCTAssertEqual(kept, fresh)
        let asked = await profiles.requests.count
        XCTAssertEqual(asked, 0, "the server that sends kits is not asked the way an old one is")
    }

    func testTheCacheIsPerPersonAndSignOutWipesIt() async throws {
        let cache = tempCache()
        let api = MockTransport(routes: [.json(.get, "/api/dashboard-theme", try envelope())])
        _ = try await makeLoader(api, cache: cache, user: "user-1").refresh()

        let other = await makeLoader(api, cache: cache, user: "user-2").cached()
        XCTAssertNil(other, "another person on the same phone sees nothing of it")
        let mine = await makeLoader(api, cache: cache, user: "user-1").cached()
        XCTAssertEqual(mine?.theme, "newsprint")

        // Sign-out and a server switch clear the person's namespace and the whole cache.
        await cache.clear(namespace: "user-1")
        let gone = await makeLoader(api, cache: cache, user: "user-1").cached()
        XCTAssertNil(gone)

        _ = try await makeLoader(api, cache: cache, user: "user-1").refresh()
        await cache.clearAll()
        let wiped = await makeLoader(api, cache: cache, user: "user-1").cached()
        XCTAssertNil(wiped)
    }

    func testForgetDropsOnlyTheLook() async throws {
        let cache = tempCache()
        let api = MockTransport(routes: [.json(.get, "/api/dashboard-theme", try envelope())])
        let loader = makeLoader(api, cache: cache)
        _ = try await loader.refresh()
        await cache.store("kept", key: "something-else", namespace: "user-1")
        await loader.forget()
        let look = await loader.cached()
        XCTAssertNil(look)
        let other = await cache.entry(String.self, key: "something-else", namespace: "user-1")
        XCTAssertEqual(other?.value, "kept")
    }

    func testAFailedRefreshThrowsAndLeavesWhatIsWorn() async throws {
        let cache = tempCache()
        let good = MockTransport(routes: [.json(.get, "/api/dashboard-theme", try envelope())])
        let worn = try await makeLoader(good, cache: cache).refresh()

        let down = MockTransport(routes: [.failure(.get, "/api/dashboard-theme", status: 500, message: "The server fell over.")])
        do {
            _ = try await makeLoader(down, cache: cache).refresh()
            XCTFail("a blip is not an answer")
        } catch {
            XCTAssertEqual((error as? HVError)?.failure?.status, 500)
        }
        let kept = await makeLoader(down, cache: cache).cached()
        XCTAssertEqual(kept, worn)
    }

    func testAChangeOfThemeReplacesTheCachedLook() async throws {
        let cache = tempCache()
        let first = MockTransport(routes: [.json(.get, "/api/dashboard-theme", try envelope("newsprint"))])
        _ = try await makeLoader(first, cache: cache).refresh()
        let second = MockTransport(routes: [.json(.get, "/api/dashboard-theme", #"{"theme":null,"kit":null}"#)])
        let back = try await makeLoader(second, cache: cache).refresh()
        XCTAssertEqual(back, .stock)
        let kept = await makeLoader(second, cache: cache).cached()
        XCTAssertEqual(kept, .stock, "the default look is an answer too, and is what the next launch starts from")
    }

    func testAServerThatDoesNotSendKitsIsAskedForTheIdTheWayThePaneAlwaysDid() async throws {
        let cache = tempCache()
        let api = MockTransport(routes: [.json(.get, "/api/dashboard-theme", try envelope())])
        let profiles = MockTransport(routes: [.json(.get, "/rest/v1/profiles", #"[{"theme":"newsprint"}]"#)])
        let state = try await makeLoader(api, profiles, cache: cache, kits: false).refresh()
        XCTAssertEqual(state, DashboardThemeState(theme: "newsprint", kit: nil, reason: .unsupported))
        XCTAssertTrue(state.isWithheld)
        let tried = await api.requests.count
        XCTAssertEqual(tried, 0, "features.stylekit is false: the GET is not tried")
        let asked = await profiles.requests(matching: "/rest/v1/profiles")
        XCTAssertEqual(asked.count, 1)
        let kept = await makeLoader(api, profiles, cache: cache, kits: false).cached()
        XCTAssertEqual(kept, state)

        let unset = MockTransport(routes: [.json(.get, "/rest/v1/profiles", #"[{"theme":null}]"#)])
        let none = try await makeLoader(api, unset, cache: tempCache(), kits: false).refresh()
        XCTAssertEqual(none, .stock)
    }

    func testAFlagThatPromisedMoreThanTheServerHasFallsBackToo() async throws {
        for status in [404, 405] {
            let api = MockTransport(routes: [.failure(.get, "/api/dashboard-theme", status: status, message: "Method not allowed")])
            let profiles = MockTransport(routes: [.json(.get, "/rest/v1/profiles", #"[{"theme":"glassmorphism"}]"#)])
            let state = try await makeLoader(api, profiles, cache: tempCache()).refresh()
            XCTAssertEqual(state, DashboardThemeState(theme: "glassmorphism", kit: nil, reason: .unsupported), "\(status)")
            let tried = await api.requests(matching: "/api/dashboard-theme")
            XCTAssertEqual(tried.count, 1)
        }
    }

    func testAnOldServerWithNoColumnEitherIsTheDefaultLook() async throws {
        let profiles = MockTransport(routes: [MockRoute(.get, "/rest/v1/profiles") { _ in
            HTTPResponse(status: 400, data: Data(#"{"code":"42703","message":"column profiles.theme does not exist"}"#.utf8))
        }])
        let state = try await makeLoader(MockTransport(), profiles, cache: tempCache(), kits: false).refresh()
        XCTAssertEqual(state, .stock)
    }

    func testBothWaysFailingThrowsAndCachesNothing() async {
        let cache = tempCache()
        let api = MockTransport(routes: [.failure(.get, "/api/dashboard-theme", status: 405, message: "no")])
        let profiles = MockTransport(routes: [.failure(.get, "/rest/v1/profiles", status: 500, message: "The server fell over.")])
        do {
            _ = try await makeLoader(api, profiles, cache: cache).refresh()
            XCTFail("no answer is not the default look")
        } catch {
            XCTAssertEqual((error as? HVError)?.failure?.status, 500)
        }
        let nothing = await makeLoader(api, profiles, cache: cache).cached()
        XCTAssertNil(nothing)
    }

    func testASavedChoiceIsKeptWithoutAskingAgain() async throws {
        let cache = tempCache()
        let api = MockTransport()
        let loader = makeLoader(api, cache: cache)
        let saved = DashboardThemeState(theme: "newsprint", kit: try StyleKitFixtures.kit("newsprint"))
        await loader.remember(saved)
        let kept = await loader.cached()
        XCTAssertEqual(kept, saved)
        let asked = await api.requests.count
        XCTAssertEqual(asked, 0)
    }

    func testWhatIsOnDiskIsCheckedAgainWhenItIsReadBack() async throws {
        // A file an earlier build wrote, whose kit this build's floors do not accept: it comes back as the default look.
        let cache = tempCache()
        var illegible = try StyleKitFixtures.json("modern-dark")
        illegible = StyleKitFixtures.setting(illegible, ["colors", "muted_foreground"], to: "#121820")
        await cache.store(JSONValue.object(["theme": "modern-dark", "kit": illegible]), key: StyleKitLoader.cacheKey, namespace: "user-1")
        let read = await makeLoader(MockTransport(), cache: cache).cached()
        XCTAssertEqual(read, DashboardThemeState(theme: "modern-dark", kit: nil, reason: .invalid))

        // Nothing in the file is a nil, not a crash.
        await cache.store(JSONValue.string("not a state"), key: StyleKitLoader.cacheKey, namespace: "user-2")
        let junk = await makeLoader(MockTransport(), cache: cache, user: "user-2").cached()
        XCTAssertNil(junk)
    }

    func testLoadYieldsTheCachedLookThenTheFreshOne() async throws {
        let cache = tempCache()
        let before = MockTransport(routes: [.json(.get, "/api/dashboard-theme", try envelope("newsprint"))])
        _ = try await makeLoader(before, cache: cache).refresh()

        let after = MockTransport(routes: [.json(.get, "/api/dashboard-theme", try envelope("glassmorphism"))])
        var seen: [Loaded<DashboardThemeState>] = []
        for try await loaded in makeLoader(after, cache: cache).load() { seen.append(loaded) }
        XCTAssertEqual(seen.map(\.source), [.cache, .network])
        XCTAssertEqual(seen.map { $0.value.theme }, ["newsprint", "glassmorphism"])
        let now = await makeLoader(after, cache: cache).cached()
        XCTAssertEqual(now?.theme, "glassmorphism")
    }

    func testLoadKeepsTheCachedLookWhenTheNetworkFailsAndThrowsWhenThereIsNone() async throws {
        let cache = tempCache()
        let good = MockTransport(routes: [.json(.get, "/api/dashboard-theme", try envelope("newsprint"))])
        _ = try await makeLoader(good, cache: cache).refresh()

        let down = MockTransport(routes: [.failure(.get, "/api/dashboard-theme", status: 503, message: "Try later.")])
        var seen: [Loaded<DashboardThemeState>] = []
        for try await loaded in makeLoader(down, cache: cache).load() { seen.append(loaded) }
        XCTAssertEqual(seen.count, 2)
        XCTAssertEqual(seen.map { $0.value.theme }, ["newsprint", "newsprint"])
        XCTAssertNil(seen[0].refreshError)
        XCTAssertEqual(seen[1].refreshError?.failure?.status, 503)

        do {
            for try await _ in makeLoader(down, cache: tempCache()).load() {}
            XCTFail("nothing cached and nothing fetched")
        } catch {
            XCTAssertEqual((error as? HVError)?.failure?.status, 503)
        }
    }
}
