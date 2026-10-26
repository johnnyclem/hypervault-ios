import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What `redeem_invite_code` answered.
public enum InviteResult: String, Sendable, Equatable {
    case ok
    case alreadyApproved = "already_approved"
    case invalid
    case disabled
    case exhausted
    case notAuthenticated = "not_authenticated"

    public var isAccepted: Bool { self == .ok || self == .alreadyApproved }

    /// The sentence to show; the web app's own words.
    public var message: String {
        switch self {
        case .ok: return "You are in."
        case .alreadyApproved: return "You are already in."
        case .invalid: return "That invite code doesn't exist. Double-check for typos."
        case .disabled: return "That invite code has been deactivated."
        case .exhausted: return "That invite code has already been used up."
        case .notAuthenticated: return "Sign in first, then enter your invite code."
        }
    }
}

public enum InviteCode {
    /// "hv-ab12-cd34" -> "HV-AB12-CD34"; the server compares case-insensitively.
    public static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    /// Pulls a code out of pasted text or a link (`?invite=HV-XXXX-XXXX`).
    public static func extract(from text: String) -> String? {
        let pattern = #"HV-[A-Z0-9]{4}-[A-Z0-9]{4}"#
        guard let range = text.uppercased().range(of: pattern, options: .regularExpression) else { return nil }
        return String(text.uppercased()[range])
    }
}

/// Redeems an invite code through Supabase directly: the database function is
/// callable by any signed-in account and the web app's own route is a thin
/// wrapper around it, so a bearer-only app can call it as is.
public struct InviteRedeemer: Sendable {
    private let config: SupabaseConfig
    private let transport: HTTPTransport
    private let tokens: TokenProvider

    public init(config: SupabaseConfig, transport: HTTPTransport = URLSessionTransport(), tokens: TokenProvider) {
        self.config = config
        self.transport = transport
        self.tokens = tokens
    }

    public func redeem(_ code: String) async throws -> InviteResult {
        guard let token = try await tokens.accessToken() else { throw HVError.unauthorized }
        var request = URLRequest(url: config.url.appendingPathComponent("rest/v1/rpc/redeem_invite_code"), timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONEncoder().encode(["p_code": InviteCode.normalize(code)])

        let response: HTTPResponse
        do {
            response = try await transport.send(request)
        } catch {
            throw HVError.transport(error.localizedDescription)
        }
        guard (200..<300).contains(response.status) else {
            if response.status == 404 || response.status == 400 {
                throw HVError.api(APIFailure(status: 503, message: "Invite redemption isn't set up on this server yet. Please try again later."))
            }
            throw HVError.api(HVClient.failure(from: response))
        }
        guard let text = try? JSONDecoder().decode(String.self, from: response.data),
              let result = InviteResult(rawValue: text)
        else {
            throw HVError.decoding("Unexpected answer from invite redemption.")
        }
        return result
    }
}
