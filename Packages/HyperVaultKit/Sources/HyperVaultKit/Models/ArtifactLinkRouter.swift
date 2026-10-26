import Foundation

/// What to do with a link tapped inside a page. A page is untrusted: it can
/// send the person to the web, never into the app by a side door, and what it
/// links to opens where a link should (Safari), except HyperVault's own.
public enum ArtifactLinkAction: Sendable, Equatable {
    /// The "Fix it" link a broken React page shows (`/vault?repair=<slug>&error=<message>`).
    case repair(slug: String?, error: String?)
    /// A link to HyperVault itself (a page, a group, the app's scheme): the app decides what it opens.
    case hyperVault(URL)
    /// Anywhere else on the web, or a mail, phone or message link.
    case external(URL)
    /// A scheme a page has no business navigating to (`javascript:`, `file:`, `data:`).
    case blocked
}

public struct ArtifactLinkRouter: Sendable {
    private let serverHost: String?
    private let domains: [String]

    /// `serverHost` is the app's own address; `domains` are the portfolio's base domains (`vault.cool`),
    /// each of which also serves every claimed name under it.
    public init(serverHost: String?, domains: [String] = []) {
        self.serverHost = serverHost?.lowercased()
        self.domains = domains.map { $0.lowercased() }
    }

    public func isHyperVault(host: String?) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty else { return false }
        if host == serverHost { return true }
        return domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    public func action(for url: URL) -> ArtifactLinkAction {
        let scheme = url.scheme?.lowercased() ?? ""
        switch scheme {
        case "hypervault":
            return .hyperVault(url)
        case "mailto", "tel", "sms", "facetime":
            return .external(url)
        case "http", "https":
            guard isHyperVault(host: url.host) else { return .external(url) }
            if url.path == "/vault" || url.path == "/vault/" || url.path.hasPrefix("/vault/library"),
               let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
               let repair = items.first(where: { $0.name == "repair" })?.value, !repair.isEmpty {
                let message = items.first(where: { $0.name == "error" })?.value
                return .repair(slug: repair, error: (message?.isEmpty ?? true) ? nil : message)
            }
            return .hyperVault(url)
        default:
            return .blocked
        }
    }
}
