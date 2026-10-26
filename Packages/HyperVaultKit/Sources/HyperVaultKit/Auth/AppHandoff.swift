import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// How a Google sign-in gets from the web back into the app.
///
/// The app cannot ask Supabase to return straight to `hypervault://`: Supabase only returns to an address on its
/// Redirect URLs list, and sends the code to its Site URL when the address is not on it, which is the website's own
/// sign-in page, in the sign-in sheet, with no way back. So the app asks for an address on the website that is
/// already allowed (`returnURL`), and that page hands the code on to the app's own address (`callback`).
///
/// A website that does not have that page yet (an older deployment) treats the visit as its own sign-in, fails for
/// want of a verifier and ends on its login page, and the person is left in the sheet. `check` asks the page first.
public enum AppHandoff {
    public enum Verdict: Equatable, Sendable {
        /// The page answered with a redirect to the app.
        case ready
        /// The page answered, and not with a redirect to the app: this site cannot hand a sign-in back.
        case missing
        /// No answer worth acting on (offline, busy, a server error). Go ahead; the sheet will show what is wrong.
        case unknown
    }

    /// Where the app's web sign-in session listens (`ASWebAuthenticationSession`, scheme `hypervault`).
    public static let callback = URL(string: "hypervault://auth/callback")!

    /// The address Supabase is asked to return to: the website's callback page, told the sign-in is the app's.
    public static func returnURL(on origin: URL) -> URL {
        var components = URLComponents(url: origin, resolvingAgainstBaseURL: false) ?? URLComponents()
        components.path = "/auth/callback"
        components.queryItems = [URLQueryItem(name: "client", value: "app")]
        components.fragment = nil
        return components.url ?? origin
    }

    /// Visits `returnURL` with a made-up code and looks at where it would be sent, without following it. Nothing is
    /// signed in or written: the page only forwards what it is given.
    public static func check(returnURL: URL, transport: HTTPTransport) async -> Verdict {
        guard var components = URLComponents(url: returnURL, resolvingAgainstBaseURL: false) else { return .unknown }
        var items = (components.queryItems ?? []).filter { $0.name != "code" }
        items.append(URLQueryItem(name: "code", value: "handoff-check"))
        components.queryItems = items
        guard let url = components.url else { return .unknown }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        guard let response = try? await transport.sendWithoutRedirect(request) else { return .unknown }
        // A server that is down, timing out or rate limiting says nothing about whether the page is there.
        if response.status == 408 || response.status == 429 || response.status >= 500 { return .unknown }
        if (300..<400).contains(response.status), let location = response.header("location"), isApp(location) {
            return .ready
        }
        return .missing
    }

    private static func isApp(_ location: String) -> Bool {
        guard let url = URL(string: location) else { return false }
        return url.scheme?.lowercased() == callback.scheme
            && url.host?.lowercased() == callback.host
            && url.path == callback.path
    }
}
