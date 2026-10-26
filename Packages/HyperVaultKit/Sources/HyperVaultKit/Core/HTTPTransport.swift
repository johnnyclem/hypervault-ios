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
