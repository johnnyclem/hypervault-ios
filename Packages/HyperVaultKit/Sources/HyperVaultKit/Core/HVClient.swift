import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Supplies the bearer token and refreshes it. `AuthService` is the real one.
public protocol TokenProvider: Sendable {
    /// A token that is valid now (refreshed first if it is about to expire), or
    /// nil when nobody is signed in.
    func accessToken() async throws -> String?
    /// The server refused `rejected`. Returns a different, fresh token, or nil
    /// when the session is over.
    func refreshAfterUnauthorized(rejected: String?) async throws -> String?
}

/// Settings for retrying a request that is safe to repeat.
public struct RetryPolicy: Sendable {
    public var maxAttempts: Int
    public var baseDelay: TimeInterval
    public var maxDelay: TimeInterval

    public init(maxAttempts: Int = 3, baseDelay: TimeInterval = 0.4, maxDelay: TimeInterval = 4) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
    }

    public static let none = RetryPolicy(maxAttempts: 1)
}

/// The typed HyperVault API client. One per signed-in server. It adds the
/// bearer token, refreshes it once on a 401, retries safe requests on
/// transient failures and turns every failure into an `HVError`.
public final class HVClient: Sendable {
    public let baseURL: URL
    private let transport: HTTPTransport
    private let tokens: TokenProvider?
    private let userAgent: String
    private let retry: RetryPolicy
    private let sleep: @Sendable (TimeInterval) async -> Void

    public init(
        baseURL: URL,
        transport: HTTPTransport = URLSessionTransport(),
        tokens: TokenProvider? = nil,
        userAgent: String = "HyperVault-iOS",
        retry: RetryPolicy = RetryPolicy(),
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    ) {
        self.baseURL = baseURL
        self.transport = transport
        self.tokens = tokens
        self.userAgent = userAgent
        self.retry = retry
        self.sleep = sleep
    }

    /// Runs the call and reads its answer.
    public func send<Response: Sendable>(_ endpoint: Endpoint<Response>) async throws -> Response {
        let response = try await sendRaw(endpoint)
        return try endpoint.decode(response, endpoint.keys)
    }

    /// Runs the call and returns the raw response after status checking.
    public func sendRaw<Response: Sendable>(_ endpoint: Endpoint<Response>) async throws -> HTTPResponse {
        var token: String? = nil
        if endpoint.auth != .none, let tokens {
            token = try await tokens.accessToken()
            if token == nil, endpoint.auth == .required { throw HVError.unauthorized }
        } else if endpoint.auth == .required {
            throw HVError.unauthorized
        }

        var refreshed = false
        var attempt = 0
        while true {
            attempt += 1
            if Task.isCancelled { throw HVError.cancelled }
            do {
                let request = try makeRequest(endpoint, token: token)
                let response = try await transport.send(request)

                if response.status == 401, endpoint.auth != .none, !refreshed, let tokens, !Self.isToolSignInChallenge(response) {
                    refreshed = true
                    let fresh = try await tokens.refreshAfterUnauthorized(rejected: token)
                    guard let fresh else { throw HVError.unauthorized }
                    token = fresh
                    continue
                }
                if (200..<300).contains(response.status) { return response }

                let failure = Self.failure(from: response)
                if endpoint.idempotent, attempt < retry.maxAttempts, Self.isTransient(status: response.status), failure.code == nil {
                    await sleep(delay(attempt: attempt, retryAfter: failure.retryAfter))
                    continue
                }
                // A 401 after a successful refresh is the route refusing a good
                // token (a route that only takes a web session, say), not a
                // signed-out person: show the server's own sentence.
                throw HVError.api(failure)
            } catch let error as HVError {
                throw error
            } catch is CancellationError {
                throw HVError.cancelled
            } catch let error as URLError where error.code == .cancelled {
                throw HVError.cancelled
            } catch {
                if endpoint.idempotent, attempt < retry.maxAttempts, Self.isTransient(error: error) {
                    await sleep(delay(attempt: attempt, retryAfter: nil))
                    continue
                }
                throw HVError.transport(error.localizedDescription)
            }
        }
    }

    // MARK: Request building

    /// A path with whatever needs escaping escaped, and escapes already in it left alone. A branch called
    /// `research/quantum` goes in as `research%2Fquantum` and must reach the server that way; setting
    /// `URLComponents.path` would turn that `%` into `%25`. A lone `%`, a space or a `?` is escaped.
    static func encodedPath(_ path: String) -> String {
        let characters = Array(path)
        var result = ""
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "%", index + 2 < characters.count,
               characters[index + 1].isHexDigit, characters[index + 2].isHexDigit {
                result += String(characters[index...index + 2])
                index += 3
                continue
            }
            let text = String(character)
            result += text.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? text
            index += 1
        }
        return result
    }

    func makeRequest<Response>(_ endpoint: Endpoint<Response>, token: String?) throws -> URLRequest {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw HVError.invalidRequest("Bad server address.")
        }
        let basePath = components.percentEncodedPath.hasSuffix("/") ? String(components.percentEncodedPath.dropLast()) : components.percentEncodedPath
        components.percentEncodedPath = basePath + Self.encodedPath(endpoint.path.hasPrefix("/") ? endpoint.path : "/" + endpoint.path)
        if !endpoint.query.isEmpty {
            components.queryItems = endpoint.query
            // URLComponents leaves "+" alone in a query, and the server reads a "+" there as a space, so
            // a search for "c++ notes" would arrive as "c   notes". Everything else it escapes already.
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        guard let url = components.url else { throw HVError.invalidRequest("Bad request address.") }

        var request = URLRequest(url: url, timeoutInterval: endpoint.timeout)
        request.httpMethod = endpoint.method.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }

        switch endpoint.body {
        case .none:
            break
        case .json(let value):
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            do {
                request.httpBody = try HVCoding.encoder(endpoint.keys).encode(value)
            } catch {
                throw HVError.invalidRequest("Could not write the request.")
            }
        case .jsonValue(let value):
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? HVCoding.encoder(.verbatim).encode(value)
        case .multipart(let form):
            request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
            request.httpBody = form.encoded()
        case .raw(let data, let contentType):
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            request.httpBody = data
        }
        for (name, value) in endpoint.headers { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }

    // MARK: Failures

    static func failure(from response: HTTPResponse) -> APIFailure {
        let retryAfter = response.header("retry-after").flatMap { TimeInterval($0) }
        let body = try? HVCoding.decoder(.verbatim).decode(JSONValue.self, from: response.data)
        let message = body?["error"]?.string
            ?? body?["message"]?.string
            ?? body?["msg"]?.string
            ?? Self.defaultMessage(for: response.status)
        return APIFailure(
            status: response.status,
            message: message,
            code: body?["code"]?.string,
            recovery: body?["recovery"],
            body: body,
            retryAfter: retryAfter
        )
    }

    static func defaultMessage(for status: Int) -> String {
        switch status {
        case 400: return "That request was not accepted."
        case 401: return "Sign in again."
        case 403: return "You do not have access to that."
        case 404: return "Not found."
        case 413: return "That is too large."
        case 429: return "Too many requests. Wait a moment and try again."
        case 500...599: return "The server had a problem. Try again in a moment."
        default: return "Request failed (\(status))."
        }
    }

    /// A 401 that says a connected tool's own sign-in ended (`auth_required: true` in the body) is not about
    /// this person's session, so refreshing their token would change nothing and only cost a round trip.
    static func isToolSignInChallenge(_ response: HTTPResponse) -> Bool {
        failure(from: response).body?["auth_required"]?.bool == true
    }

    /// A busy or restarting server: 429 and the gateway statuses. An answer that names its own machine code
    /// is the route's decision (`503 mail_unavailable`: the mail tables are not there), not a passing
    /// condition, so `sendRaw` does not wait and ask again.
    static func isTransient(status: Int) -> Bool {
        status == 429 || status == 502 || status == 503 || status == 504
    }

    static func isTransient(error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        switch error.code {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
             .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed:
            return true
        default:
            return false
        }
    }

    private func delay(attempt: Int, retryAfter: TimeInterval?) -> TimeInterval {
        if let retryAfter { return min(retryAfter, retry.maxDelay) }
        let exponential = retry.baseDelay * pow(2, Double(attempt - 1))
        let jitter = Double.random(in: 0...(retry.baseDelay / 2))
        return min(exponential + jitter, retry.maxDelay)
    }
}
