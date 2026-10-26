import HyperVaultKit
import XCTest
@testable import HyperVault

/// The line that says whether a name is free changes in place, away from the field VoiceOver is on.
@MainActor
final class RealmClaimFlowTests: XCTestCase {
    private struct Hiccup: Error {}

    private let won = #"{"domain":"nova.vault.cool","url":"https://nova.vault.cool","claimed":1,"max_subdomains":10,"message":"It is live now."}"#

    private func makeFlow(
        check: @escaping (String, String) async throws -> ClaimAvailability = { _, _ in ClaimAvailability(available: true) },
        claim: @escaping (String, String) async throws -> ClaimResult
            = { _, _ in throw HVError.api(APIFailure(status: 500, message: "not used")) },
        speech: FeaturesRecordingAnnouncer
    ) -> RealmClaimFlow {
        RealmClaimFlow(checkName: check, claimName: claim, announcer: speech, pause: 0)
    }

    func testAFreeNameIsSaidOnceTheTypingHasRested() async {
        let speech = FeaturesRecordingAnnouncer()
        let flow = makeFlow(speech: speech)
        await flow.check(name: "nova", base: "vault.cool")
        XCTAssertEqual(flow.availability, .available)
        XCTAssertEqual(speech.spoken, ["nova.vault.cool is available."])
    }

    func testATakenNameIsSaidInTheServersWords() async {
        let speech = FeaturesRecordingAnnouncer()
        let flow = makeFlow(check: { _, _ in ClaimAvailability(available: false, reason: "nova.vault.cool is already claimed.") }, speech: speech)
        await flow.check(name: "nova", base: "vault.cool")
        XCTAssertEqual(flow.availability, .unavailable("nova.vault.cool is already claimed."))
        XCTAssertEqual(speech.spoken, ["nova.vault.cool is already claimed."])

        let plain = makeFlow(check: { _, _ in ClaimAvailability(available: false) }, speech: speech)
        await plain.check(name: "nova", base: "vault.cool")
        XCTAssertEqual(speech.spoken.last, "That name is taken.")
    }

    func testANameThatIsWrongOnSightIsShownAtOnceAndNotSaidOverTheKeys() async {
        let speech = FeaturesRecordingAnnouncer()
        let asked = RealmsTestCounter()
        let flow = makeFlow(check: { _, _ in asked.bump(); return ClaimAvailability(available: true) }, speech: speech)
        await flow.check(name: "a", base: "vault.cool")
        XCTAssertEqual(flow.availability, .unavailable("Pick at least 2 characters."))
        XCTAssertTrue(speech.spoken.isEmpty)
        XCTAssertEqual(asked.value, 0, "the server is not asked about it")
    }

    func testAnAnswerThatArrivesAfterTheNameChangedIsNeitherShownNorSaid() async {
        let speech = FeaturesRecordingAnnouncer()
        let flow = makeFlow(check: { _, _ in
            try? await Task.sleep(nanoseconds: 150_000_000)
            return ClaimAvailability(available: true)
        }, speech: speech)
        let stale = Task { await flow.check(name: "nova", base: "vault.cool") }
        try? await Task.sleep(nanoseconds: 30_000_000)
        stale.cancel()
        await stale.value
        XCTAssertTrue(speech.spoken.isEmpty)
        XCTAssertEqual(flow.availability, .checking, "the next check will settle it")
    }

    func testAHiccupWhileCheckingIsQuiet() async {
        let speech = FeaturesRecordingAnnouncer()
        let flow = makeFlow(check: { _, _ in throw Hiccup() }, speech: speech)
        await flow.check(name: "nova", base: "vault.cool")
        XCTAssertEqual(flow.availability, .idle)
        XCTAssertTrue(speech.spoken.isEmpty)
    }

    func testAClaimThatFailedIsSaidInTheServersWords() async {
        let speech = FeaturesRecordingAnnouncer()
        let flow = makeFlow(claim: { _, _ in throw HVError.api(APIFailure(status: 403, message: "Free accounts can claim one address.")) }, speech: speech)
        await flow.claim(name: "nova", base: "vault.cool")
        XCTAssertNil(flow.claimed)
        XCTAssertFalse(flow.claiming)
        XCTAssertEqual(flow.failure, "Free accounts can claim one address.")
        XCTAssertEqual(speech.spoken, ["Free accounts can claim one address."])
    }

    func testAClaimThatWorkedShowsTheResultAndLeavesTheSpeakingToTheScreensFocus() async throws {
        let speech = FeaturesRecordingAnnouncer()
        let result = try HVCoding.decoder().decode(ClaimResult.self, from: Data(won.utf8))
        let flow = makeFlow(claim: { name, base in
            XCTAssertEqual(name, "nova")
            XCTAssertEqual(base, "vault.cool")
            return result
        }, speech: speech)
        await flow.claim(name: "Nova", base: "vault.cool")
        XCTAssertEqual(flow.claimed?.domain, "nova.vault.cool")
        XCTAssertNil(flow.failure)
        XCTAssertTrue(speech.spoken.isEmpty)
    }
}

/// Counts calls from any thread.
private final class RealmsTestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func bump() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
