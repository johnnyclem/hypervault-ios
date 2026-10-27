import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPResponse: Sendable {
    public let status: Int
    /// Header names are lowercased.
    public let headers: [String: String]
    public let data: Data

    public init(status: Int, headers: [String: String] = [:], data: Data = Data()) {
        self.status = status
        self.headers = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
        self.data = data
    }

    public func header(_ name: String) -> String? { headers[name.lowercased()] }
}

/// The one seam between the client and the network. The app uses
/// `URLSessionTransport`; tests and SwiftUI previews use `MockTransport`.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse

    /// Like `send`, but a redirect is the answer rather than something to follow: the status and `Location` of the
    /// first response come back as they are. For asking where a page would send a browser.
    func sendWithoutRedirect(_ request: URLRequest) async throws -> HTTPResponse
}

extension HTTPTransport {
    /// A transport that has no redirects to follow (a fake network) answers as `send` does.
    public func sendWithoutRedirect(_ request: URLRequest) async throws -> HTTPResponse {
        try await send(request)
    }
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key] = value }
        }
        return HTTPResponse(status: http.statusCode, headers: headers, data: data)
    }
}

#if !canImport(FoundationNetworking)
// Linux has no use for this (the Kit's tests there run against `MockTransport`), and its Foundation's delegate
// protocol is not spelled the way Apple's is, so the redirect refusal is Apple's alone and Linux takes `send`.
extension URLSessionTransport {
    public func sendWithoutRedirect(_ request: URLRequest) async throws -> HTTPResponse {
        // A session of its own, so the refusal to follow does not touch what the shared one does.
        let session = URLSession(configuration: .ephemeral, delegate: RedirectRefuser(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key] = value }
        }
        return HTTPResponse(status: http.statusCode, headers: headers, data: data)
    }
}

/// Answers every redirect with "no", which makes the redirect itself the response.
private final class RedirectRefuser: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
#endif

/// A `multipart/form-data` body: text fields and files.
public struct MultipartForm: Sendable {
    public struct Part: Sendable {
        let name: String
        let filename: String?
        let mimeType: String?
        let data: Data
    }

    public let boundary: String
    private var parts: [Part] = []

    public init(boundary: String = "hv-" + UUID().uuidString) {
        self.boundary = boundary
    }

    public mutating func addField(_ name: String, _ value: String) {
        parts.append(Part(name: name, filename: nil, mimeType: nil, data: Data(value.utf8)))
    }

    public mutating func addFile(_ name: String, filename: String, mimeType: String, data: Data) {
        parts.append(Part(name: name, filename: filename, mimeType: mimeType, data: data))
    }

    public var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    public func encoded() -> Data {
        var body = Data()
        let crlf = "\r\n"
        for part in parts {
            body.append(Data("--\(boundary)\(crlf)".utf8))
            var disposition = "Content-Disposition: form-data; name=\"\(Self.escape(part.name))\""
            if let filename = part.filename { disposition += "; filename=\"\(Self.escape(filename))\"" }
            body.append(Data((disposition + crlf).utf8))
            if let mimeType = part.mimeType { body.append(Data("Content-Type: \(mimeType)\(crlf)".utf8)) }
            body.append(Data(crlf.utf8))
            body.append(part.data)
            body.append(Data(crlf.utf8))
        }
        body.append(Data("--\(boundary)--\(crlf)".utf8))
        return body
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "%22").replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
    }
}
