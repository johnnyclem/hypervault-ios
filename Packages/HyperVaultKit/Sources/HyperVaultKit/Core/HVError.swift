import Foundation

/// What the server said when it refused a request. `message` is the server's own
/// sentence, shown to people verbatim.
public struct APIFailure: Sendable, Equatable {
    public let status: Int
    public let message: String
    /// The machine code some routes add next to `error` (`handle_required`, ...).
    public let code: String?
    /// The `recovery` object keep routes send: what to do next, as data.
    public let recovery: JSONValue?
    /// The whole JSON body, when there was one. Merge conflicts, truth
    /// refusals and the like carry their detail here.
    public let body: JSONValue?
    public let retryAfter: TimeInterval?

    public init(
        status: Int,
        message: String,
        code: String? = nil,
        recovery: JSONValue? = nil,
        body: JSONValue? = nil,
        retryAfter: TimeInterval? = nil
    ) {
        self.status = status
        self.message = message
        self.code = code
        self.recovery = recovery
        self.body = body
        self.retryAfter = retryAfter
    }
}

/// Every way a HyperVault call can fail, in one type.
public enum HVError: Error, Sendable, Equatable {
    /// The server answered with a non-2xx status.
    case api(APIFailure)
    /// The request never got an answer: offline, timed out, TLS, DNS.
    case transport(String)
    /// The answer arrived but was not the shape the app expects.
    case decoding(String)
    /// Signed out, or the session could not be refreshed.
    case unauthorized
    /// The request could not be built (bad URL, body too large).
    case invalidRequest(String)
    case cancelled
}

extension HVError: LocalizedError {
    public var errorDescription: String? { userMessage }

    /// A sentence safe to show in a toast or an inline state.
    public var userMessage: String {
        switch self {
        case .api(let failure): return failure.message
        case .transport: return "Network hiccup. Check your connection and try again."
        case .decoding: return "The server answered in a way this version of the app does not understand. Update the app and try again."
        case .unauthorized: return "Your session ended. Sign in again."
        case .invalidRequest(let message): return message
        case .cancelled: return "Cancelled."
        }
    }

    public var status: Int? {
        if case .api(let failure) = self { return failure.status }
        if case .unauthorized = self { return 401 }
        return nil
    }

    public var code: String? {
        if case .api(let failure) = self { return failure.code }
        return nil
    }

    public var failure: APIFailure? {
        if case .api(let failure) = self { return failure }
        return nil
    }

    public var isOffline: Bool {
        if case .transport = self { return true }
        return false
    }

    public var isUnauthorized: Bool { status == 401 }

    public var isNotFound: Bool { status == 404 }

    public var isRateLimited: Bool { status == 429 }

    /// The account has signed in but not been let in yet.
    public var isWaitlisted: Bool {
        guard status == 403, case .api(let failure) = self else { return false }
        return failure.message.localizedCaseInsensitiveContains("waitlist")
    }

    /// A route that answers 503 until a migration has been applied, or when the
    /// server is missing configuration.
    public var isUnavailable: Bool { status == 503 }
}
