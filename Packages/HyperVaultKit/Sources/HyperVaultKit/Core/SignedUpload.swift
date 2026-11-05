import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A PUT of raw bytes to an address that carries its own permission: a storage signed upload URL.
///
/// It is not an `Endpoint` and does not go through `HVClient` on purpose. The client adds the person's bearer token
/// to every request, and a signed address that also gets an `Authorization` header can be refused by storage, which
/// reads that header as a second, different credential. So this builds the request by hand with a `Content-Type`
/// and nothing else, and sends it through the same `HTTPTransport` seam as everything else, which keeps it testable
/// with `MockTransport`.
public enum SignedUpload {
    /// A PUT can take a while for a large file on a slow connection. The timeout of a `URLRequest` is the time the
    /// connection may go quiet, not the whole transfer, so this is generous without being unbounded.
    public static let defaultTimeout: TimeInterval = 300

    /// Whether this is an address worth sending a file to: a link with a host, over https (or http, which a server
    /// on the same machine uses in development).
    public static func address(from text: String) -> URL? {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty
        else { return nil }
        return url
    }

    public static func request(to url: URL, contentType: String, data: Data, timeout: TimeInterval = defaultTimeout) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = HTTPMethod.put.rawValue
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        return request
    }

    /// Sends the bytes and returns the answer as it is, whatever its status: what a refusal means is for the caller,
    /// who knows what was being uploaded. A failure to get an answer at all throws what the transport threw.
    public static func put(
        _ data: Data, to url: URL, contentType: String, using transport: HTTPTransport, timeout: TimeInterval = defaultTimeout
    ) async throws -> HTTPResponse {
        try await transport.send(request(to: url, contentType: contentType, data: data, timeout: timeout))
    }
}
