import Foundation

public enum HTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
}

public enum AuthMode: Sendable {
    /// Send the bearer token; a signed-out caller fails with `.unauthorized`.
    case required
    /// Send the token when there is one.
    case optional
    /// Never send a token (public routes).
    case none
}

public enum RequestBody: Sendable {
    case none
    /// An `Encodable` request struct, written with the endpoint's key strategy.
    case json(any (Encodable & Sendable))
    /// Open-ended JSON, written verbatim.
    case jsonValue(JSONValue)
    case multipart(MultipartForm)
    case raw(Data, contentType: String)
}

/// A response with nothing to read (a 204, or a body the app ignores).
public struct NoContent: Sendable, Equatable {
    public init() {}
}

/// One API call, described as a value: where it goes, what it carries and how
/// to read the answer. `HVClient.send` runs it. Endpoints are declared in
/// `Endpoints/<Domain>.swift` as static factories so call sites read
/// `client.send(.yours(filter: .memory))`.
public struct Endpoint<Response: Sendable>: Sendable {
    public var method: HTTPMethod
    public var path: String
    public var query: [URLQueryItem]
    public var body: RequestBody
    public var auth: AuthMode
    public var keys: KeyStrategy
    public var timeout: TimeInterval
    public var headers: [String: String]
    /// Whether a failed attempt may be repeated without changing the outcome.
    /// GET defaults to true; mutations default to false.
    public var idempotent: Bool
    public var decode: @Sendable (HTTPResponse, KeyStrategy) throws -> Response

    public init(
        method: HTTPMethod,
        path: String,
        query: [URLQueryItem] = [],
        body: RequestBody = .none,
        auth: AuthMode = .required,
        keys: KeyStrategy = .snakeCase,
        timeout: TimeInterval = 30,
        headers: [String: String] = [:],
        idempotent: Bool? = nil,
        decode: @escaping @Sendable (HTTPResponse, KeyStrategy) throws -> Response
    ) {
        self.method = method
        self.path = path
        self.query = query
        self.body = body
        self.auth = auth
        self.keys = keys
        self.timeout = timeout
        self.headers = headers
        self.idempotent = idempotent ?? (method == .get)
        self.decode = decode
    }
}

extension Endpoint where Response: Decodable {
    /// A call whose answer is JSON of type `Response`.
    public init(
        _ method: HTTPMethod,
        _ path: String,
        query: [URLQueryItem] = [],
        body: RequestBody = .none,
        auth: AuthMode = .required,
        keys: KeyStrategy = .snakeCase,
        timeout: TimeInterval = 30,
        headers: [String: String] = [:],
        idempotent: Bool? = nil
    ) {
        self.init(
            method: method, path: path, query: query, body: body, auth: auth, keys: keys,
            timeout: timeout, headers: headers, idempotent: idempotent
        ) { response, keys in
            do {
                return try HVCoding.decoder(keys).decode(Response.self, from: response.data)
            } catch {
                throw HVError.decoding(Self.describe(error, data: response.data))
            }
        }
    }

    private static func describe(_ error: Error, data: Data) -> String {
        if let error = error as? DecodingError {
            switch error {
            case .keyNotFound(let key, let context):
                return "Missing \(key.stringValue) at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
            case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
                return "\(context.debugDescription) at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
            @unknown default:
                return "\(error)"
            }
        }
        return "\(error)"
    }
}

extension Endpoint where Response == NoContent {
    public init(
        _ method: HTTPMethod,
        _ path: String,
        query: [URLQueryItem] = [],
        body: RequestBody = .none,
        auth: AuthMode = .required,
        keys: KeyStrategy = .snakeCase,
        timeout: TimeInterval = 30,
        headers: [String: String] = [:],
        idempotent: Bool? = nil
    ) {
        self.init(
            method: method, path: path, query: query, body: body, auth: auth, keys: keys,
            timeout: timeout, headers: headers, idempotent: idempotent
        ) { _, _ in NoContent() }
    }
}

extension Endpoint where Response == String {
    /// A call whose answer is plain text (`/start.md`, an export).
    public init(
        text method: HTTPMethod,
        _ path: String,
        query: [URLQueryItem] = [],
        auth: AuthMode = .required,
        timeout: TimeInterval = 30
    ) {
        self.init(method: method, path: path, query: query, auth: auth, timeout: timeout) { response, _ in
            String(decoding: response.data, as: UTF8.self)
        }
    }
}

extension Endpoint where Response == Data {
    /// A call whose answer is raw bytes (a file or an export to hand to the share sheet).
    public init(
        data method: HTTPMethod,
        _ path: String,
        query: [URLQueryItem] = [],
        auth: AuthMode = .required,
        timeout: TimeInterval = 60
    ) {
        self.init(method: method, path: path, query: query, auth: auth, timeout: timeout) { response, _ in response.data }
    }
}

extension Array where Element == URLQueryItem {
    /// Builds a query from optional values, leaving out the nil and empty ones.
    public static func make(_ pairs: [(String, String?)]) -> [URLQueryItem] {
        pairs.compactMap { name, value in
            guard let value, !value.isEmpty else { return nil }
            return URLQueryItem(name: name, value: value)
        }
    }
}
