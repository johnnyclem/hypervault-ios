import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One canned answer for `MockTransport`.
public struct MockRoute: Sendable {
    public var method: HTTPMethod?
    /// An exact path, or a path ending in `*` that matches by prefix.
    public var path: String
    public var handler: @Sendable (URLRequest) -> HTTPResponse

    public init(_ method: HTTPMethod? = nil, _ path: String, handler: @escaping @Sendable (URLRequest) -> HTTPResponse) {
        self.method = method
        self.path = path
        self.handler = handler
    }

    /// Answers with `json` text.
    public static func json(_ method: HTTPMethod? = nil, _ path: String, _ json: String, status: Int = 200) -> MockRoute {
        MockRoute(method, path) { _ in HTTPResponse(status: status, headers: ["content-type": "application/json"], data: Data(json.utf8)) }
    }

    /// Answers with an error body in the server's `{ "error": ... }` shape.
    public static func failure(_ method: HTTPMethod? = nil, _ path: String, status: Int, message: String) -> MockRoute {
        let escaped = message.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return .json(method, path, "{\"error\":\"\(escaped)\"}", status: status)
    }

    func matches(method requestMethod: String, path requestPath: String) -> Bool {
        if let method, method.rawValue != requestMethod { return false }
        if path.hasSuffix("*") { return requestPath.hasPrefix(String(path.dropLast())) }
        return path == requestPath
    }
}

/// A fake network for unit tests and SwiftUI previews. Routes are tried in the
/// order given (later `add`s win); a request with no route gets a 404 and is
/// recorded like the rest.
public actor MockTransport: HTTPTransport {
    private var routes: [MockRoute]
    private let delay: TimeInterval
    public private(set) var requests: [URLRequest] = []

    public init(routes: [MockRoute] = [], delay: TimeInterval = 0) {
        self.routes = routes
        self.delay = delay
    }

    public func add(_ route: MockRoute) {
        routes.insert(route, at: 0)
    }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? ""
        if let route = routes.first(where: { $0.matches(method: method, path: path) }) {
            return route.handler(request)
        }
        return HTTPResponse(
            status: 404,
            headers: ["content-type": "application/json"],
            data: Data("{\"error\":\"No mock for \(method) \(path)\"}".utf8)
        )
    }

    public func requests(matching path: String) -> [URLRequest] {
        requests.filter { $0.url?.path == path }
    }
}
