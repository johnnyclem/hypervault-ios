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
/// with `MockTransport`. It is the one PUT in the app: a memory file import (`MemoryFileImporter`) and a stored PDF or
/// image (`ArtifactUploader`) both go through it.
public enum SignedUpload {
    /// A PUT can take a while for a large file on a slow connection. The timeout of a `URLRequest` is the time the
    /// connection may go quiet, not the whole transfer, so this is generous without being unbounded.
    public static let defaultTimeout: TimeInterval = 300

    /// Whether this is an address worth sending a file to: a link with a host, over https, or over http only when the
    /// host is this machine (`localhost`, `127.0.0.1` or `[::1]`), which is where a server run in development puts its
    /// storage. Like the rule `ServerConfig` holds the app's own server to, with the IPv6 loopback too. Any other http address is refused: the
    /// bytes of a person's file would cross the network in the clear.
    public static func address(from text: String) -> URL? {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(), !host.isEmpty
        else { return nil }
        switch scheme {
        case "https": return url
        case "http": return isThisMachine(host) ? url : nil
        default: return nil
        }
    }

    /// `URL.host` gives an IPv6 address with its brackets on some platforms and without on others.
    private static func isThisMachine(_ host: String) -> Bool {
        ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
    }

    /// What to throw for an address `address(from:)` refused. A text that is not a link at all is the server answering in
    /// a way this version of the app does not understand. Plain http to another machine is a link that was refused on
    /// purpose, and says so, because updating the app would not help.
    public static func refusal(forAddress text: String) -> HVError {
        if let url = URL(string: text), url.scheme?.lowercased() == "http", let host = url.host, !host.isEmpty {
            return .invalidRequest("The upload address is not secure, so the file was not sent.")
        }
        return .decoding("The upload address was not a link.")
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
