import Foundation

// The first-run card on the canvas that asks for one thing: give an agent a key (the web's `ConnectAgentCard`). The
// card is shown to a person who has no agent key and has not chosen "I'll look around first". That choice is kept on
// the profile (`PATCH /api/onboarding`, `Endpoint.recordOnboarding`), so it follows the person from the web to the phone.

/// The words of the card. The sheet it opens has its own (`ConnectCopy`).
public enum ConnectCardCopy {
    public static let title = "Hand this to your agent"
    /// The line under the title is the one the Connect sheet opens with, so the card promises what the sheet does.
    public static let line = ConnectCopy.line
    public static let connectLabel = "Connect an agent"
    public static let dismissLabel = "I'll look around first"
}

/// What the profile remembers about the first run (`profiles.onboarding`). Only the part the card needs: no field
/// here says that an agent connected, since no route reports the server's check of that.
public struct OnboardingState: Sendable, Equatable {
    /// "I'll look around first" was chosen, on this phone or anywhere else (`connect_dismissed_at` is stamped).
    public let connectDismissed: Bool

    public init(connectDismissed: Bool = false) {
        self.connectDismissed = connectDismissed
    }
}

/// `profiles.onboarding` is a JSON object whose stamps are written once by the server. A shape this does not expect
/// reads as nothing stamped, not as a failed read.
private struct OnboardingStamps: Decodable, Sendable {
    let connectDismissedAt: JSONValue?

    enum Keys: String, CodingKey { case connectDismissedAt }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        connectDismissedAt = try? c.decodeIfPresent(JSONValue.self, forKey: .connectDismissedAt)
    }

    /// A stamp is a time as text; any value that is not null or empty counts as set.
    var isConnectDismissed: Bool {
        guard let stamp = connectDismissedAt else { return false }
        switch stamp {
        case .null: return false
        case .string(let text): return !text.trimmingCharacters(in: .whitespaces).isEmpty
        default: return true
        }
    }
}

private struct ProfileOnboardingRow: Decodable, Sendable {
    let onboarding: OnboardingStamps?

    enum Keys: String, CodingKey { case onboarding }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        onboarding = try? c.decodeIfPresent(OnboardingStamps.self, forKey: .onboarding)
    }
}

extension AccountRest {
    /// What the person's profile remembers about the first run (`profiles.onboarding`), read with their own token as
    /// the account page reads its rows. A database from before the column, or a person with no profile row, has
    /// nothing stamped: that is "not dismissed", not an error. Any other failure is thrown, so a caller does not take
    /// an unreadable profile for an empty one.
    public func onboarding(userID: String) async throws -> OnboardingState {
        do {
            let found: [ProfileOnboardingRow] = try await rows(
                from: "profiles",
                query: [
                    URLQueryItem(name: "select", value: "onboarding"),
                    URLQueryItem(name: "id", value: "eq.\(userID)"),
                    URLQueryItem(name: "limit", value: "1"),
                ]
            )
            return OnboardingState(connectDismissed: found.first?.onboarding?.isConnectDismissed ?? false)
        } catch where Self.isMissingColumn(error) {
            return OnboardingState()
        }
    }
}
