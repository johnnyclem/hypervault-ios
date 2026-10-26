import HyperVaultKit
import SwiftUI

/// Choosing an address: whether the name being typed is free, and the claim itself. The line that says a name
/// is free changes in place, away from the field VoiceOver is on, so what it settles is said aloud as well as
/// shown, and so is a claim that failed. A claim that worked swaps the whole page for the celebration, which
/// the screen moves VoiceOver to.
@MainActor
@Observable
final class RealmClaimFlow {
    enum Availability: Equatable {
        case idle
        case checking
        case available
        case unavailable(String)
    }

    private(set) var availability = Availability.idle
    private(set) var claiming = false
    private(set) var claimed: ClaimResult?
    /// Why the last claim failed, in the server's words; typing clears it.
    var failure: String?

    @ObservationIgnored private let checkName: (String, String) async throws -> ClaimAvailability
    @ObservationIgnored private let claimName: (String, String) async throws -> ClaimResult
    @ObservationIgnored private let announcer: FeatureAnnouncer
    @ObservationIgnored private let pause: UInt64

    /// `pause` is how long typing must rest before the server is asked.
    init(
        checkName: @escaping (String, String) async throws -> ClaimAvailability,
        claimName: @escaping (String, String) async throws -> ClaimResult,
        announcer: FeatureAnnouncer = VoiceOverFeatureAnnouncer.shared,
        pause: UInt64 = 350_000_000
    ) {
        self.checkName = checkName
        self.claimName = claimName
        self.announcer = announcer
        self.pause = pause
    }

    // MARK: Checking

    /// Run from a task keyed on the name and the domain: each change cancels the last, so a stale answer is
    /// dropped before it is shown or said. A name the app can see is wrong is shown at once and not said, or
    /// it would talk over the keys being typed.
    func check(name: String, base: String) async {
        guard !name.isEmpty else { availability = .idle; return }
        switch RealmRules.validate(name) {
        case .failure(let problem):
            availability = .unavailable(problem.message)
        case .success(let valid):
            availability = .checking
            try? await Task.sleep(nanoseconds: pause)
            if Task.isCancelled { return }
            do {
                let answer = try await checkName(valid, base)
                if Task.isCancelled { return }
                if answer.available {
                    availability = .available
                    announcer.announce("\(valid).\(base) is available.")
                } else {
                    let reason = answer.reason ?? "That name is taken."
                    availability = .unavailable(reason)
                    announcer.announce(reason)
                }
            } catch {
                // Rate limited or a hiccup: stay quiet, claiming still validates.
                if !Task.isCancelled { availability = .idle }
            }
        }
    }

    // MARK: Claiming

    func claim(name: String, base: String) async {
        guard case .success(let valid) = RealmRules.validate(name), !claiming else { return }
        claiming = true
        failure = nil
        defer { claiming = false }
        do {
            claimed = try await claimName(valid, base)
            Haptics.success()
        } catch {
            let message = keysMessage(for: error)
            failure = message
            Haptics.failure()
            announcer.announce(message)
        }
    }
}
