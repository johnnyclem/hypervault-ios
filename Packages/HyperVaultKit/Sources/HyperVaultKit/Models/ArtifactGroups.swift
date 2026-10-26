import Foundation

// Groups are small multi-file web apps (HTML, CSS, JS, JSX) that route through
// a root index.html. The wire is `app/api/artifact-groups`; the rules are the
// web's `lib/artifacts/group-files.ts`, ported so the editor can say no before
// the server does, and the preview is `lib/artifacts/group-preview.ts`.

/// A group in `GET /api/artifact-groups`.
public struct ArtifactGroupSummary: Sendable, Codable, Identifiable, Hashable {
    public let id: String
    public let slug: String
    public let title: String
    public let tags: [String]
    public let visibility: ArtifactVisibility
    public let createdAt: Date?
    public let url: String?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        slug = try c.decode(String.self, forKey: .slug)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Untitled group"
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        visibility = try c.decodeIfPresent(ArtifactVisibility.self, forKey: .visibility) ?? .private
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        url = try c.decodeIfPresent(String.self, forKey: .url)
    }

    enum Keys: String, CodingKey { case id, slug, title, tags, visibility, createdAt, url }
}

public struct ArtifactGroupList: Sendable, Decodable, Equatable {
    public let items: [ArtifactGroupSummary]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        items = try c.decodeIfPresent([ArtifactGroupSummary].self, forKey: .items) ?? []
    }

    enum Keys: String, CodingKey { case items }

    public static func == (lhs: ArtifactGroupList, rhs: ArtifactGroupList) -> Bool {
        lhs.items.map(\.slug) == rhs.items.map(\.slug)
    }
}

/// One file of a group, with its content.
public struct ArtifactGroupFile: Sendable, Codable, Identifiable, Hashable {
    public var id: String { path }
    public let path: String
    public var content: String
    public let sizeBytes: Int

    public init(path: String, content: String, sizeBytes: Int? = nil) {
        self.path = path
        self.content = content
        self.sizeBytes = sizeBytes ?? content.utf8.count
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        path = try c.decode(String.self, forKey: .path)
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        sizeBytes = try c.decodeIfPresent(Int.self, forKey: .sizeBytes) ?? content.utf8.count
    }

    enum Keys: String, CodingKey { case path, content, sizeBytes }
}

/// `GET /api/artifact-groups/[slug]`: the group and every file's editable content.
public struct ArtifactGroupDetail: Sendable, Decodable, Equatable {
    public let slug: String
    public let title: String
    public let tags: [String]
    public let visibility: ArtifactVisibility
    public let url: String?
    public let createdAt: Date?
    public let files: [ArtifactGroupFile]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        slug = try c.decode(String.self, forKey: .slug)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Untitled group"
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        visibility = try c.decodeIfPresent(ArtifactVisibility.self, forKey: .visibility) ?? .private
        url = try c.decodeIfPresent(String.self, forKey: .url)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        files = try c.decodeIfPresent([ArtifactGroupFile].self, forKey: .files) ?? []
    }

    enum Keys: String, CodingKey { case slug, title, tags, visibility, url, createdAt, files }
}

/// What creating a group answers.
public struct ArtifactGroupCreated: Sendable, Decodable {
    public let slug: String
    public let title: String
    public let url: String
    public let visibility: ArtifactVisibility
    public let files: [String]
    public let message: String

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        slug = try c.decode(String.self, forKey: .slug)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Untitled group"
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        visibility = try c.decodeIfPresent(ArtifactVisibility.self, forKey: .visibility) ?? .private
        files = try c.decodeIfPresent([String].self, forKey: .files) ?? []
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
    }

    enum Keys: String, CodingKey { case slug, title, url, visibility, files, message }
}

// MARK: Rules

public enum ArtifactGroupRules {
    /// The root file every group needs; it can be edited and never removed.
    public static let indexFile = "index.html"
    public static let allowedExtensions = ["html", "css", "js", "jsx"]
    public static let maxFileBytes = 500_000
    public static let maxGroupBytes = 2_000_000
    public static let maxFiles = 50
    public static let maxPathLength = 200

    /// The rules in the web's own words (`GROUP_FILE_INSTRUCTIONS`).
    public static let instructions = """
        Artifact groups are small multi-file web apps:
        \u{2022} Every group must contain exactly one root file named "index.html". That's what the link serves and what browsers load first, so it can never be removed (only edited).
        \u{2022} Allowed file types: .html, .css, .js, .jsx. Anything else is rejected.
        \u{2022} Paths are relative (no leading "/"), forward-slash separated, and may not contain "..", backslashes, or characters outside letters, numbers, "_", "-", "." and "/". Two paths that differ only by case are treated as a collision.
        \u{2022} Reference other files from index.html the same way you would on any static host: <link rel="stylesheet" href="styles.css">, <script src="app.js">.
        \u{2022} .jsx files aren't transpiled on the server. Load Babel Standalone and React from a CDN in index.html and reference the file with <script type="text/babel" src="app.jsx">.
        \u{2022} Limits: \(maxFiles) files per group, \(maxFileBytes.formatted(.number)) bytes per file, \(maxGroupBytes.formatted(.number)) bytes total.
        """

    /// Strips a leading "./" or "/" so "./index.html", "/index.html" and "index.html" are the same file.
    public static func normalize(_ rawPath: String) -> String {
        var path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        while true {
            if path.hasPrefix("./") { path.removeFirst(2) } else if path.hasPrefix("/") { path.removeFirst() } else { break }
        }
        return path
    }

    /// A path the server will take, or the sentence it would refuse it with.
    public static func validate(path rawPath: String) -> Result<String, ArtifactGroupRuleError> {
        let path = normalize(rawPath)
        if path.isEmpty { return .failure(.init("A file path is required.")) }
        if path.count > maxPathLength {
            return .failure(.init("\"\(rawPath)\" is over the \(maxPathLength)-character path limit."))
        }
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-/")
        if path.contains(where: { !allowed.contains($0) }) {
            return .failure(.init("\"\(rawPath)\" has characters that aren't allowed. Use letters, numbers, \"_\", \"-\", \".\" and \"/\"."))
        }
        if path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) {
            return .failure(.init("\"\(rawPath)\" isn't a valid relative path (no empty segments or \"..\")."))
        }
        guard let ext = fileExtension(path), allowedExtensions.contains(ext) else {
            return .failure(.init("\"\(rawPath)\" has an unsupported file type. Only \(allowedExtensions.map { ".\($0)" }.joined(separator: ", ")) are allowed."))
        }
        return .success(path)
    }

    /// Whether the content fits the per-file cap.
    public static func validate(path: String, content: String) -> ArtifactGroupRuleError? {
        let size = content.utf8.count
        if size > maxFileBytes {
            return .init("\"\(path)\" is \(size.formatted(.number)) bytes, over the \(maxFileBytes.formatted(.number))-byte per-file limit.")
        }
        return nil
    }

    /// The whole set, as the server checks it before creating or after an edit.
    public static func validate(files: [ArtifactGroupFile]) -> ArtifactGroupRuleError? {
        if files.isEmpty { return .init("At least one file is required. Every group needs a root index.html.") }
        if files.count > maxFiles { return .init("Too many files (\(files.count)). The limit is \(maxFiles) per group.") }
        var seen: [String: String] = [:]
        var total = 0
        for file in files {
            switch validate(path: file.path) {
            case .failure(let error): return error
            case .success(let path):
                if let other = seen[path.lowercased()] {
                    return other == path
                        ? .init("Duplicate file path: \"\(path)\".")
                        : .init("\"\(path)\" and \"\(other)\" collide. Paths that differ only by case aren't allowed.")
                }
                seen[path.lowercased()] = path
            }
            if let error = validate(path: file.path, content: file.content) { return error }
            total += file.content.utf8.count
        }
        if total > maxGroupBytes {
            return .init("The group is \(total.formatted(.number)) bytes, over the \(maxGroupBytes.formatted(.number))-byte total limit.")
        }
        if !files.contains(where: { normalize($0.path) == indexFile }) {
            return .init("Every group needs a root \"\(indexFile)\" file. That's what visitors load first.")
        }
        return nil
    }

    public static func isRemovable(_ path: String) -> Bool { normalize(path) != indexFile }

    static func fileExtension(_ path: String) -> String? {
        guard let dot = path.lastIndex(of: "."), dot != path.startIndex else { return nil }
        let ext = path[path.index(after: dot)...]
        guard !ext.isEmpty, ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return ext.lowercased()
    }

    /// Index first, then the rest by path, like the server lists them.
    public static func sorted(_ files: [ArtifactGroupFile]) -> [ArtifactGroupFile] {
        files.sorted { lhs, rhs in
            if lhs.path == indexFile { return true }
            if rhs.path == indexFile { return false }
            return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }
    }

    /// The three files a new group starts with.
    public static var starterFiles: [ArtifactGroupFile] {
        [
            ArtifactGroupFile(path: "index.html", content: """
                <!DOCTYPE html>
                <html lang="en">
                <head>
                  <meta charset="UTF-8" />
                  <meta name="viewport" content="width=device-width, initial-scale=1" />
                  <title>My artifact group</title>
                  <link rel="stylesheet" href="styles.css" />
                </head>
                <body>
                  <h1>Hello from HyperVault</h1>
                  <p id="clicks">Clicked 0 times</p>
                  <button id="btn">Click me</button>
                  <script src="app.js"></script>
                </body>
                </html>

                """),
            ArtifactGroupFile(path: "styles.css", content: "body {\n  font-family: system-ui, sans-serif;\n  padding: 2rem;\n}\n"),
            ArtifactGroupFile(
                path: "app.js",
                content: "let count = 0;\nconst el = document.getElementById(\"clicks\");\ndocument.getElementById(\"btn\").addEventListener(\"click\", () => {\n  count += 1;\n  el.textContent = `Clicked ${count} times`;\n});\n"
            ),
        ]
    }
}

/// The requests that turn the files a group holds into the files the editor shows, one file at a time, in an
/// order the server accepts. Adding a path that is there answers 409 and removing one that is gone answers 404,
/// so the editor plans from what is saved and records each step as it lands.
public struct ArtifactGroupChanges: Sendable, Equatable {
    public enum Step: Sendable, Equatable {
        case add(ArtifactGroupFile)
        case write(ArtifactGroupFile)
        case remove(String)
    }

    public let steps: [Step]

    public init(saved: [ArtifactGroupFile], now files: [ArtifactGroupFile]) {
        let before = Dictionary(saved.map { ($0.path, $0.content) }, uniquingKeysWith: { _, last in last })
        let paths = Set(files.map(\.path))
        let added = files.filter { before[$0.path] == nil }
        let written = files.filter { file in before[file.path].map { $0 != file.content } ?? false }
        let removed = saved.map(\.path).filter { !paths.contains($0) }

        // A path whose only difference from an added one is case still stands on the server, and the server
        // refuses the new spelling beside it. The group may also be too full to hold the old files and the new.
        let addedLowercased = Set(added.map { $0.path.lowercased() })
        let respelled = Set(removed.filter { addedLowercased.contains($0.lowercased()) })
        let grows = added.reduce(0) { $0 + $1.content.utf8.count }
            + written.reduce(0) { $0 + $1.content.utf8.count - (before[$1.path]?.utf8.count ?? 0) }
        let tooFull = saved.count + added.count > ArtifactGroupRules.maxFiles
            || saved.reduce(0) { $0 + $1.content.utf8.count } + grows > ArtifactGroupRules.maxGroupBytes

        // Otherwise files go last: until the new ones are in, the live group is never missing one.
        let early = removed.filter { tooFull || respelled.contains($0) }
        let late = removed.filter { !early.contains($0) }
        steps = early.map(Step.remove) + written.map(Step.write) + added.map(Step.add) + late.map(Step.remove)
    }

    public var isEmpty: Bool { steps.isEmpty }
}

public struct ArtifactGroupRuleError: Error, Sendable, Equatable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }
}

// MARK: Preview

/// Builds the one document a group previews as: each file index.html names is
/// inlined (`<link rel="stylesheet" href="styles.css">` becomes a `<style>`,
/// `<script src="app.js">` an inline script), so the preview needs nothing from
/// the server and works for a private group too. External references (a CDN,
/// a data: URI) are left alone. String rewriting, not an HTML parser, like the web's.
public enum ArtifactGroupPreview {
    public static func document(indexHTML: String, files: [ArtifactGroupFile]) -> String {
        var byPath: [String: String] = [:]
        for file in files { byPath[file.path] = file.content }

        var out = replacing(
            indexHTML,
            pattern: #"<script\b([^>]*)\bsrc\s*=\s*("([^"]*)"|'([^']*)')([^>]*)>\s*</script\s*>"#,
            groups: (before: 1, double: 3, single: 4, after: 5)
        ) { before, raw, after in
            guard !isExternal(raw), let content = byPath[ArtifactGroupRules.normalize(raw)] else { return nil }
            let attributes = [before.trimmingCharacters(in: .whitespaces), after.trimmingCharacters(in: .whitespaces)]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            return "<script\(attributes.isEmpty ? "" : " " + attributes)>\(content)</script>"
        }

        out = replacing(
            out,
            pattern: #"<link\b([^>]*)\bhref\s*=\s*("([^"]*)"|'([^']*)')([^>]*?)/?>"#,
            groups: (before: 1, double: 3, single: 4, after: 5)
        ) { before, raw, after in
            let tag = "\(before) \(after)"
            guard tag.range(of: #"\brel\s*=\s*("stylesheet"|'stylesheet')"#, options: [.regularExpression, .caseInsensitive]) != nil,
                  !isExternal(raw),
                  let content = byPath[ArtifactGroupRules.normalize(raw)]
            else { return nil }
            return "<style>\(content)</style>"
        }
        return out
    }

    static func isExternal(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return true }
        return trimmed.range(of: #"^([a-z][a-z0-9+.-]*:|//)"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Replaces each match the closure answers for; leaves the others as they were.
    private static func replacing(
        _ text: String,
        pattern: String,
        groups: (before: Int, double: Int, single: Int, after: Int),
        transform: (_ before: String, _ reference: String, _ after: String) -> String?
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        let source = text as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            func group(_ index: Int) -> String? {
                let range = match.range(at: index)
                return range.location == NSNotFound ? nil : source.substring(with: range)
            }
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let whole = source.substring(with: match.range)
            let reference = group(groups.double) ?? group(groups.single) ?? ""
            if let replacement = transform(group(groups.before) ?? "", reference, group(groups.after) ?? "") {
                result += replacement
            } else {
                result += whole
            }
            cursor = match.range.location + match.range.length
        }
        result += source.substring(from: cursor)
        return result
    }
}
