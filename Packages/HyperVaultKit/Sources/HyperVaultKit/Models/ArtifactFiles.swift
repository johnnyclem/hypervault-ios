import Foundation

// Stored files: a PDF or an image kept as a page of its own. The bytes never
// pass through the app server (too big for a serverless body); the flow is
// `POST /api/artifacts/upload-url`, a PUT to the signed address it returns,
// then `POST /api/artifacts/import-file` to give the file a permanent link
// (`lib/artifacts/files.ts`, `app/api/artifacts/{upload-url,import-file}`).

public enum ArtifactFileKind: String, Sendable, Hashable {
    case pdf, image
}

public struct ArtifactFileType: Sendable, Equatable {
    public let ext: String
    public let mime: String
    public let kind: ArtifactFileKind

    private static let table: [String: (String, ArtifactFileKind)] = [
        "pdf": ("application/pdf", .pdf),
        "png": ("image/png", .image),
        "jpg": ("image/jpeg", .image),
        "jpeg": ("image/jpeg", .image),
        "gif": ("image/gif", .image),
        "webp": ("image/webp", .image),
        "svg": ("image/svg+xml", .image),
    ]

    /// The type a filename uploads as, or nil when the server would refuse it (415).
    public static func forFilename(_ filename: String) -> ArtifactFileType? {
        guard let dot = filename.lastIndex(of: "."), dot != filename.startIndex else { return nil }
        let ext = filename[filename.index(after: dot)...].lowercased()
        guard let entry = table[ext] else { return nil }
        return ArtifactFileType(ext: ext, mime: entry.0, kind: entry.1)
    }

    /// The extensions the picker offers.
    public static var supportedExtensions: [String] { table.keys.sorted() }
}

/// `POST /api/artifacts/upload-url`.
public struct ArtifactUploadTicket: Sendable, Decodable {
    /// The Storage path, which import-file takes back.
    public let path: String
    public let signedUrl: String
    public let token: String?
    public let contentType: String
    public let maxBytes: Int?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        path = try c.decode(String.self, forKey: .path)
        signedUrl = try c.decode(String.self, forKey: .signedUrl)
        token = try c.decodeIfPresent(String.self, forKey: .token)
        contentType = try c.decodeIfPresent(String.self, forKey: .contentType) ?? "application/octet-stream"
        maxBytes = try c.decodeIfPresent(Int.self, forKey: .maxBytes)
    }

    enum Keys: String, CodingKey { case path, signedUrl, token, contentType, maxBytes }
}

/// The file a stored-file page embeds, read from the viewer page the server
/// serves for it (`fileViewerHtml` in `app/a/[slug]/route.ts`): an iframe for a
/// PDF, an img for an image, with a signed address that lasts an hour.
public struct ArtifactEmbeddedFile: Sendable, Equatable {
    public let url: URL
    public let kind: ArtifactFileKind

    public init(url: URL, kind: ArtifactFileKind) {
        self.url = url
        self.kind = kind
    }

    public static func find(in html: String) -> ArtifactEmbeddedFile? {
        let patterns: [(String, ArtifactFileKind)] = [
            (#"<iframe\s+src="([^"]+)""#, .pdf),
            (#"<img\s+src="([^"]+)""#, .image),
        ]
        for (pattern, kind) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: html)
            else { continue }
            let address = unescape(String(html[range]))
            if let url = URL(string: address), url.scheme == "https" || url.scheme == "http" {
                return ArtifactEmbeddedFile(url: url, kind: kind)
            }
        }
        return nil
    }

    /// The server escapes `& < > "` where it writes the address into the page.
    static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
