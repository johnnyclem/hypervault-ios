import Foundation

/// The address the server is reached at, as text: `https://host[:port]` with no path. It is the base of the
/// fetch command a vault entry shows and of the pointer in a connect prompt. It is only text for a person or an
/// agent to copy: nothing here is sent as a header.
public enum ServerOrigin {
    public static func string(of baseURL: URL) -> String {
        var origin = "\(baseURL.scheme ?? "https")://\(baseURL.host ?? "")"
        if let port = baseURL.port { origin += ":\(port)" }
        return origin
    }
}
