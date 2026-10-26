import Foundation

/// What to do with a link tapped inside a page. A page is untrusted: it can
/// send the person to the web, never into the app by a side door, and what it
/// links to opens where a link should (Safari), except HyperVault's own pages.
public enum ArtifactLinkAction: Sendable, Equatable {
    /// The "Fix it" link a broken React page shows (`/vault?repair=<slug>&error=<message>`).
    case repair(slug: String?, error: String?)
    /// A link to another HyperVault page or group: the app opens it.
    case hyperVault(URL)
    /// Anywhere else on the web, or a mail, phone or message link.
    case external(URL)
    /// A scheme a page has no business navigating to (`javascript:`, `file:`, `data:`), or a link
    /// into one of the app's own actions (approving an agent, filling the canvas).
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

    /// The first segment of the paths a page may open inside the app: a page, a group, and the app's
    /// own `hypervault://artifact/<slug>`. Nothing else a link could name is a page's to send the person to.
    static let pageSegments: Set<String> = ["a", "g", "artifact"]

    /// The first segments that act on the person's account or fill their canvas (approve an agent, take an
    /// invite, sign in, keep some text). A page never reaches these, in the app or by handing the link on.
    static let actionSegments: Set<String> = ["pair", "keep", "canvas", "invite", "login"]

    /// `tapped` is false for a navigation the page started by itself (a script, a meta refresh, a redirect).
    /// That may still carry the person on to another HyperVault page, but it never leaves the app for Safari,
    /// Mail, Messages or the phone: only a tap does.
    public func action(for url: URL, tapped: Bool = true) -> ArtifactLinkAction {
        let action = destination(of: url)
        guard !tapped else { return action }
        if case .hyperVault = action { return action }
        return .blocked
    }

    private func destination(of url: URL) -> ArtifactLinkAction {
        let scheme = url.scheme?.lowercased() ?? ""
        switch scheme {
        case "hypervault":
            // The app's own scheme is how it is driven from outside, so only a page may be named by it.
            // Handing it to the system instead would bring the same link straight back to the app.
            return Self.pageSegments.contains(Self.firstSegment(of: url, scheme: scheme)) ? .hyperVault(url) : .blocked
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
            let first = Self.firstSegment(of: url, scheme: scheme)
            if Self.pageSegments.contains(first) { return .hyperVault(url) }
            // The web serves the rest (it asks for a sign-in where it must), but an action is not a page.
            return Self.actionSegments.contains(first) ? .blocked : .external(url)
        default:
            return .blocked
        }
    }

    /// What the app's own link parser reads as the first segment: for `hypervault://pair` the host, for a
    /// web address the first path component. Lowercased, as the parser does.
    static func firstSegment(of url: URL, scheme: String) -> String {
        let path = url.pathComponents.filter { $0 != "/" }
        let parts = scheme == "hypervault" ? ([url.host].compactMap { $0 } + path) : path
        return parts.first?.lowercased() ?? ""
    }
}
