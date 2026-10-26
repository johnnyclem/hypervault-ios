import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Getting a page's markup to a web view.
//
// A private page is served only to its owner, and the web decides who that is
// from a session cookie. The app has a bearer token and no cookie, and must
// not hand either to the page it is showing. So the app fetches the markup
// itself, with the token, and gives the web view the markup (with the page's
// address as its base, so relative links and requests resolve as they do on
// the web). The page never sees the token, and the web view keeps no cookies.
//
// `/a/<slug>` is asked first. Until the server's page route also reads the
// bearer token it answers 401 or 403 for a private page, even to its owner;
// the owner's own routes do read it, so the stored markup is fetched from
// `/api/artifacts/<slug>/source` instead. A group is read whole from
// `/api/artifact-groups/<slug>` and previewed as one document.

/// What the web view should be given for a page.
public enum ArtifactPage: Sendable, Equatable {
    /// Markup to render, with `base` as its address. The viewer page of a stored PDF
    /// or image comes this way too; `ArtifactEmbeddedFile.find(in:)` reads the file out of it.
    case html(String, base: URL)
    /// Let the web view load the address itself: a password prompt, or a group
    /// this person can only reach through the web.
    case navigate(URL)
    /// Nothing to show; say why, and offer Safari.
    case blocked(ArtifactBlock)
}

public enum ArtifactBlock: Sendable, Equatable {
    case notFound
    /// Private, and this account is not on it (or the server cannot tell the app apart from a visitor yet).
    case notAllowed
    case unavailable
    case offline
    case failed(String)

    public var title: String {
        switch self {
        case .notFound: return "Nothing here"
        case .notAllowed: return "This is private"
        case .unavailable: return "Temporarily unavailable"
        case .offline: return "You're offline"
        case .failed: return "This didn't open"
        }
    }

    /// A sentence for the screen. The first two are the web's own lock-page words.
    public var message: String {
        switch self {
        case .notFound:
            return "There is nothing at this link. It may be mistyped, or it may have been removed."
        case .notAllowed:
            return "This account cannot open it here. If it is yours, open it in Safari and sign in. Otherwise ask whoever sent you the link to add your email."
        case .unavailable:
            return "The vault couldn't be reached just now. Try again in a moment."
        case .offline:
            return "Network hiccup. Check your connection and try again."
        case .failed(let message):
            return message
        }
    }
}

public struct ArtifactPageLoader: Sendable {
    private let baseURL: URL
    private let tokens: TokenProvider
    private let transport: HTTPTransport
    private let userAgent: String

    public init(baseURL: URL, tokens: TokenProvider, transport: HTTPTransport = URLSessionTransport(), userAgent: String = "HyperVault-iOS") {
        self.baseURL = baseURL
        self.tokens = tokens
        self.transport = transport
        self.userAgent = userAgent
    }

    /// The permanent address of a page, which is the base its markup renders against.
    public func pageURL(slug: String, isGroup: Bool = false) -> URL {
        ArtifactLinks.url(slug: slug, isGroup: isGroup, appURL: baseURL)
    }

    /// Loads a page, or a group when `isGroup`. Never throws: every outcome is a case.
    public func load(slug: String, isGroup: Bool = false, visibility: ArtifactVisibility? = nil) async -> ArtifactPage {
        if isGroup { return await loadGroup(slug: slug, visibility: visibility) }
        return await loadPage(slug: slug)
    }

    // MARK: Pages

    func loadPage(slug: String) async -> ArtifactPage {
        let address = pageURL(slug: slug)
        let response: HTTPResponse
        do {
            response = try await get(address, accept: "text/html,application/xhtml+xml")
        } catch {
            return .blocked(Self.blocked(for: error))
        }

        switch response.status {
        case 200..<300:
            let html = String(decoding: response.data, as: UTF8.self)
            // A group has no markup of its own (the server only adds its head tags): its link is under /g/.
            if Self.isBlank(html) {
                return await loadGroup(slug: slug, visibility: nil)
            }
            return .html(html, base: address)
        case 404:
            return .blocked(.notFound)
        case 401, 403:
            let html = String(decoding: response.data, as: UTF8.self)
            if let stored = await storedMarkup(slug: slug, base: address) { return stored }
            // Nobody to blame but the password: the server's own prompt works in the web view.
            if html.contains("hv-unlock-form") { return .navigate(address) }
            return .blocked(.notAllowed)
        case 429, 502, 503, 504:
            return .blocked(.unavailable)
        default:
            return .blocked(.failed("The page didn't open (\(response.status))."))
        }
    }

    /// The markup as stored, from the owner's own route. A stored file's content is a Storage path, not markup.
    private func storedMarkup(slug: String, base: URL) async -> ArtifactPage? {
        guard let url = URL(string: baseURL.absoluteString.trimmingTrailingSlash + "/api/artifacts/\(slug.pathEncoded)/source"),
              let response = try? await get(url, accept: "application/json"),
              (200..<300).contains(response.status),
              let source = try? HVCoding.decoder().decode(ArtifactSource.self, from: response.data),
              !source.content.isEmpty,
              !Self.looksLikeStoragePath(source.content)
        else { return nil }
        return .html(source.content, base: base)
    }

    /// Nothing outside the head: no page to show. One pass over the markup, however it is made: the markup is
    /// anyone's to publish, and a pattern that looks for `<head ...>...</head>` backtracks for minutes on a
    /// megabyte of `<head` with no end.
    static func isBlank(_ html: String) -> Bool {
        let text = Array(html.unicodeScalars)
        let space = CharacterSet.whitespacesAndNewlines
        var index = 0
        while index < text.count {
            if space.contains(text[index]) {
                index += 1
            } else if let end = endOfHead(in: text, from: index) {
                index = end
            } else {
                return false
            }
        }
        return true
    }

    /// Where a `<head ...>...</head>` that starts at `start` ends, or nil when one does not start there or is never closed.
    private static func endOfHead(in text: [Unicode.Scalar], from start: Int) -> Int? {
        guard hasTag("<head", in: text, at: start) else { return nil }
        var index = start + 5
        while index < text.count, text[index] != ">" { index += 1 }
        index += 1
        while index < text.count {
            if hasTag("</head>", in: text, at: index) { return index + 7 }
            index += 1
        }
        return nil
    }

    private static func hasTag(_ tag: StaticString, in text: [Unicode.Scalar], at index: Int) -> Bool {
        let length = tag.utf8CodeUnitCount
        guard index + length <= text.count else { return false }
        return tag.withUTF8Buffer { expected in
            for offset in 0..<length {
                let found = text[index + offset].value
                // ASCII letters match in either case.
                let folded = found >= 0x41 && found <= 0x5A ? found + 0x20 : found
                if folded != UInt32(expected[offset]) { return false }
            }
            return true
        }
    }

    static func looksLikeStoragePath(_ content: String) -> Bool {
        content.range(of: #"^[0-9a-f-]{36}/[0-9a-f-]{36}\.[a-z0-9]+$"#, options: .regularExpression) != nil
    }

    // MARK: Groups

    /// A group, read whole and previewed as one document: its sibling files sit
    /// behind the same lock as the page, and a web view has no token to open them with.
    func loadGroup(slug: String, visibility: ArtifactVisibility?) async -> ArtifactPage {
        let address = pageURL(slug: slug, isGroup: true)
        if visibility == .public { return .navigate(address) }

        guard let url = URL(string: baseURL.absoluteString.trimmingTrailingSlash + "/api/artifact-groups/\(slug.pathEncoded)") else {
            return .blocked(.notFound)
        }
        let response: HTTPResponse
        do {
            response = try await get(url, accept: "application/json")
        } catch {
            return .blocked(Self.blocked(for: error))
        }
        switch response.status {
        case 200..<300:
            guard let group = try? HVCoding.decoder().decode(ArtifactGroupDetail.self, from: response.data),
                  let index = group.files.first(where: { $0.path == ArtifactGroupRules.indexFile })
            else { return .blocked(.failed("This group has no index.html to show.")) }
            let document = ArtifactGroupPreview.document(indexHTML: index.content, files: group.files)
            return .html(document, base: address)
        case 404:
            // Not this person's own: it may be public, or shared with them. The web view asks for it as a visitor.
            return .navigate(address)
        case 429, 502, 503, 504:
            return .blocked(.unavailable)
        default:
            return .blocked(.failed("The group didn't open (\(response.status))."))
        }
    }

    // MARK: Transport

    private func get(_ url: URL, accept: String) async throws -> HTTPResponse {
        guard let token = try await tokens.accessToken() else { throw HVError.unauthorized }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "GET"
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return try await transport.send(request)
    }

    static func blocked(for error: Error) -> ArtifactBlock {
        if let error = error as? HVError {
            switch error {
            case .unauthorized: return .failed(error.userMessage)
            case .cancelled: return .failed("Cancelled.")
            default: return .offline
            }
        }
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
                return .offline
            default:
                break
            }
        }
        return .offline
    }
}

private extension String {
    var trimmingTrailingSlash: String { hasSuffix("/") ? String(dropLast()) : self }

    var pathEncoded: String { addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? self }
}
