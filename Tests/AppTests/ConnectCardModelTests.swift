import HyperVaultKit
import XCTest
@testable import HyperVault

/// The first-run card on Home that asks for one thing, a key for an agent: it shows only when the keys have been read and
/// are none and "I'll look around first" has not been chosen, here or on the profile; choosing it hides the card at once,
/// is remembered on this phone, and is sent to the profile.
@MainActor
final class ConnectCardModelTests: XCTestCase {
    private let base = URL(string: "https://t.test")!
    /// What this phone remembers lives in a suite of this test's own, empty to begin with and removed after.
    private let suite = "hv.test.connectcard.\(UUID().uuidString)"
    private var defaults: UserDefaults { UserDefaults(suiteName: suite) ?? .standard }

    override func tearDown() {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private let noStamp = #"[{"onboarding":{}}]"#
    private let stamped = #"[{"onboarding":{"connect_dismissed_at":"2026-10-27T09:30:00.123456+00:00"}}]"#

    /// The server of a person with no key and a profile that has stamped nothing, unless a test says otherwise.
    private func routes(keys: String = "[]", profile: String? = nil) -> [MockRoute] {
        [
            .json(.get, "/rest/v1/api_keys", keys),
            .json(.get, "/rest/v1/profiles", profile ?? noStamp),
            .json(.patch, "/api/onboarding", #"{"persisted":true,"onboarding":{}}"#),
        ]
    }

    private func client(_ transport: any HTTPTransport) -> HVClient {
        HVClient(baseURL: base, transport: transport, tokens: StaticTokenProvider(), retry: .none)
    }

    private func model(_ transport: any HTTPTransport, userID: String = "u1") -> ConnectCardModel {
        let api = client(transport)
        return ConnectCardModel(client: api, rest: AccountRest(client: api, anonKey: "preview"), userID: userID, defaults: defaults)
    }

    private func eventually(_ what: String, file: StaticString = #filePath, line: UInt = #line, _ condition: () async -> Bool) async {
        for _ in 0..<300 {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Never happened: \(what)", file: file, line: line)
    }

    private func onboardingBodies(_ transport: MockTransport) async throws -> [JSONValue] {
        try await transport.requests(matching: "/api/onboarding").map {
            try HVCoding.decoder(.verbatim).decode(JSONValue.self, from: try XCTUnwrap($0.httpBody))
        }
    }

    // MARK: When it shows

    func testNothingShowsUntilTheKeysHaveBeenRead() async {
        let mock = MockTransport(routes: routes())
        let hold = RequestHold()
        await hold.arm()
        let card = model(HeldTransport(base: mock, hold: hold, holds: { $0.url?.path == "/rest/v1/api_keys" }))
        XCTAssertFalse(card.isVisible, "before anything has been asked")

        let look = Task { await card.refresh() }
        await eventually("the keys read to be on its way") { await hold.waiting == 1 }
        XCTAssertFalse(card.isVisible, "while the list of keys is not known, the card is not on the page")
        XCTAssertFalse(card.hasLooked, "and the hints above it hold back their own Connect button, since the card may still come")

        await hold.release()
        await look.value
        XCTAssertTrue(card.isVisible)
        XCTAssertTrue(card.hasLooked)
    }

    func testAPersonWithNoKeyAndNothingStampedIsAsked() async {
        let card = model(MockTransport(routes: routes()))
        await card.refresh()
        XCTAssertTrue(card.isVisible)
        XCTAssertFalse(card.isDismissedHere)
    }

    func testAPersonWithAKeyIsNotAsked() async {
        let mock = MockTransport(routes: routes(keys: KeysPreviewData.keysJSON))
        let card = model(mock)
        await card.refresh()
        XCTAssertFalse(card.isVisible)
        XCTAssertTrue(card.hasLooked, "a look that found a key is a look that decided")
        let profileReads = await mock.requests(matching: "/rest/v1/profiles")
        XCTAssertTrue(profileReads.isEmpty, "someone with a key is not asked whether they would rather look around")
    }

    func testAFailedKeysReadShowsNothingAndTheNextLookTriesAgain() async {
        let flaky = Flaky(inner: MockTransport(routes: routes()))
        await flaky.setOnline(false)
        let card = model(flaky)
        await card.refresh()
        XCTAssertFalse(card.isVisible, "a list that could not be read says nothing about keys")
        XCTAssertTrue(card.hasLooked, "but the look is over, so the hints may offer their own Connect button")

        await flaky.setOnline(true)
        await card.refresh()
        XCTAssertTrue(card.isVisible)
    }

    func testAServerThatRefusesTheKeysShowsNothing() async {
        let card = model(MockTransport(routes: [.failure(.get, "/rest/v1/api_keys", status: 500, message: "Down"), .json(.get, "/rest/v1/profiles", noStamp)]))
        await card.refresh()
        XCTAssertFalse(card.isVisible)
    }

    func testAProfileThatCannotBeReadShowsNothing() async {
        let card = model(MockTransport(routes: [.json(.get, "/rest/v1/api_keys", "[]"), .failure(.get, "/rest/v1/profiles", status: 500, message: "Down")]))
        await card.refresh()
        XCTAssertFalse(card.isVisible, "it cannot be told that the person has not already waved the card off")
    }

    // MARK: A dismissal made somewhere else

    func testADismissalOnTheProfileCarriesOverAndIsRemembered() async {
        let card = model(MockTransport(routes: routes(profile: stamped)))
        await card.refresh()
        XCTAssertFalse(card.isVisible)
        XCTAssertTrue(card.isDismissedHere, "what the profile says is remembered, so the next launch asks nothing")

        let silent = MockTransport(routes: [])
        let later = model(silent)
        await later.refresh()
        XCTAssertFalse(later.isVisible)
        let asked = await silent.requests
        XCTAssertTrue(asked.isEmpty, "a card waved off on this phone is not looked up at all")
    }

    func testTheMemoryBelongsToThePersonWhoDismissed() async {
        let first = model(MockTransport(routes: routes()), userID: "u1")
        await first.refresh()
        first.dismiss()
        XCTAssertTrue(first.isDismissedHere)

        let other = model(MockTransport(routes: routes()), userID: "u2")
        XCTAssertFalse(other.isDismissedHere)
        await other.refresh()
        XCTAssertTrue(other.isVisible, "another account on the same phone is asked on its own")
    }

    // MARK: Looking around first

    func testDismissingHidesTheCardAtOnceAndRemembersBeforeTheRequestIsAnswered() async throws {
        let mock = MockTransport(routes: routes())
        let hold = RequestHold()
        let card = model(HeldTransport(base: mock, hold: hold, holds: { $0.httpMethod == "PATCH" }))
        await card.refresh()
        XCTAssertTrue(card.isVisible)

        await hold.arm()
        let sending = card.dismiss()
        XCTAssertFalse(card.isVisible, "the card goes before anything is sent")
        XCTAssertTrue(card.isDismissedHere, "and this phone remembers before the server has answered")

        await eventually("the request to be on its way") { await hold.waiting == 1 }
        XCTAssertFalse(card.isVisible, "while the request is out, the card stays away")
        await hold.release()
        await sending.value
        XCTAssertFalse(card.isVisible)
    }

    func testDismissingSendsTheConnectFlagToTheProfileAndNothingMore() async throws {
        let mock = MockTransport(routes: routes())
        let card = model(mock)
        await card.refresh()
        await card.dismiss().value

        let sent = await mock.requests(matching: "/api/onboarding")
        XCTAssertEqual(sent.map { $0.httpMethod }, ["PATCH"])
        let bodies = try await onboardingBodies(mock)
        XCTAssertEqual(bodies, [["connect_dismissed": true]], "the app never says that an agent connected")
    }

    func testADismissalThatTheServerRefusesStaysDismissedOnThisPhone() async {
        let refusing = MockTransport(routes: [
            .json(.get, "/rest/v1/api_keys", "[]"), .json(.get, "/rest/v1/profiles", noStamp),
            .failure(.patch, "/api/onboarding", status: 500, message: "Down"),
        ])
        let card = model(refusing)
        await card.refresh()
        await card.dismiss().value
        XCTAssertFalse(card.isVisible)
        XCTAssertTrue(card.isDismissedHere)

        // The next launch: the server still has nothing stamped, and the phone's word is enough.
        let next = model(MockTransport(routes: routes()))
        await next.refresh()
        XCTAssertFalse(next.isVisible, "a failed request does not bring the card back")
    }

    func testTheRequestSaysWhetherTheServerTookIt() async {
        let took = await ConnectOnboarding.recordDismissed(client: client(MockTransport(routes: routes())))
        XCTAssertTrue(took)
        let refused = await ConnectOnboarding.recordDismissed(client: client(MockTransport(routes: [.failure(.patch, "/api/onboarding", status: 400, message: "Nothing to record")])))
        XCTAssertFalse(refused)
    }

    func testADismissalMadeWhileTheKeysAreBeingReadWins() async {
        let mock = MockTransport(routes: routes())
        let hold = RequestHold()
        await hold.arm()
        let card = model(HeldTransport(base: mock, hold: hold, holds: { $0.url?.path == "/rest/v1/api_keys" }))

        let look = Task { await card.refresh() }
        await eventually("the keys read to be on its way") { await hold.waiting == 1 }
        card.dismiss()
        await hold.release()
        await look.value
        XCTAssertFalse(card.isVisible, "an answer that arrives after the dismissal does not bring the card back")
    }

    // MARK: Looking again

    func testAKeyMadeLaterEndsTheCardAndTheCardIsNotAskedAboutAgain() async {
        let made = MadeFlag()
        let mock = MockTransport(routes: [
            MockRoute(.get, "/rest/v1/api_keys") { _ in
                HTTPResponse(status: 200, headers: ["content-type": "application/json"], data: Data((made.isOn ? KeysPreviewData.keysJSON : "[]").utf8))
            },
            .json(.get, "/rest/v1/profiles", noStamp),
        ])
        let card = model(mock)
        await card.refresh()
        XCTAssertTrue(card.isVisible)

        // The Connect sheet made a key and closed.
        made.turnOn()
        await card.refresh()
        XCTAssertFalse(card.isVisible)

        let reads = await mock.requests(matching: "/rest/v1/api_keys").count
        await card.refresh()
        await card.refresh()
        let after = await mock.requests(matching: "/rest/v1/api_keys").count
        XCTAssertEqual(after, reads, "once the person has a key, coming back to Home asks the server nothing")
    }

    func testALookThatFindsAKeyWinsOverAnEarlierLookStillWaitingOnTheProfile() async {
        let made = MadeFlag()
        let mock = MockTransport(routes: [
            MockRoute(.get, "/rest/v1/api_keys") { _ in
                HTTPResponse(status: 200, headers: ["content-type": "application/json"], data: Data((made.isOn ? KeysPreviewData.keysJSON : "[]").utf8))
            },
            .json(.get, "/rest/v1/profiles", noStamp),
        ])
        let hold = RequestHold()
        await hold.arm()
        let card = model(HeldTransport(base: mock, hold: hold, holds: { $0.url?.path == "/rest/v1/profiles" }))

        // The first look found no key and is waiting on the profile.
        let first = Task { await card.refresh() }
        await eventually("the profile read to be on its way") { await hold.waiting == 1 }

        // A key is made and a second look finds it.
        made.turnOn()
        await card.refresh()
        XCTAssertFalse(card.isVisible)

        // The first look's answer arrives late and does not put the card back for someone who has a key.
        await hold.release()
        await first.value
        XCTAssertFalse(card.isVisible, "an answer that arrives after a look found a key does not show the card")
    }

    func testTheCardIsLookedUpAgainWhileItIsShowing() async {
        let mock = MockTransport(routes: routes())
        let card = model(mock)
        await card.refresh()
        await card.refresh()
        let reads = await mock.requests(matching: "/rest/v1/api_keys").count
        XCTAssertEqual(reads, 2, "a card that is showing may be ended by a key made elsewhere, so it is checked again")
        XCTAssertTrue(card.isVisible)
    }
}

/// A flag a route handler on another thread reads and a test turns on.
private final class MadeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false

    var isOn: Bool {
        lock.lock()
        defer { lock.unlock() }
        return on
    }

    func turnOn() {
        lock.lock()
        on = true
        lock.unlock()
    }
}
