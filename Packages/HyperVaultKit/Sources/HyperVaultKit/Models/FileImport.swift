import Foundation

// The Import pane's second row, "A file": one entry that takes any supported file and sends it where it belongs by its
// type, as the web's side menu "Import" does (components/import-anything-button.tsx): a `.jsx`, `.tsx` or `.html` file is
// kept through the same pipeline a paste goes through (it becomes a running, installable page), a PDF or an image is stored
// as it is, and a `.txt`, `.md` or `.docx` file becomes a memory. A `.zip` or `.json` is a data export from another AI,
// which the history importer reads: it is pointed there. The limits are lib/artifacts/files.ts and lib/ingest/files.ts.

public enum FileImport {
    public enum Kind: Sendable, Equatable {
        /// A `.jsx` or `.tsx` file: its text is saved, typed as a component.
        case component
        /// An `.html` or `.htm` file: its text is saved as a page, pinned as HTML so a real page is not mistaken for React.
        case html
        case pdf
        /// A png, jpg, gif, webp or svg: stored as it is, like a PDF.
        case image
        /// A `.txt`, `.md` or `.docx` file: its text becomes a memory.
        case document
        /// A `.zip` or `.json`: a data export for the history importer.
        case export
    }

    /// `MAX_FILE_BYTES`: the highest plan's ceiling, which the page checks before it uploads. The server holds each plan
    /// to its own (a free account is stopped at 1 MB with the server's own sentence). The row's line on the web still
    /// says 10 MB, which is older than the code.
    public static let maxPDFBytes = 50_000_000
    public static let maxPDFLabel = "50 MB"

    /// What a person is told when the file is none of these. The web's sentence also offers a .zip or .json, which the web's
    /// menu takes; this pane sends those to the history importer instead, so its sentence says that.
    public static let pickAFile = "Unsupported file type \u{2014} try .jsx, .html, .pdf, an image, or .txt/.md/.docx. A data export from another AI goes under Your AI history."

    /// What a person is told when the file is a data export: the importer for those is under Your AI history.
    public static let exportElsewhere = "That is a data export from another AI. Pick it under Your AI history, above, which reads it."

    /// What the file is by its name, matched without regard to case as the web does (`detectKind`).
    public static func kind(ofFilename name: String) -> Kind? {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
        switch name[name.index(after: dot)...].lowercased() {
        case "jsx", "tsx": return .component
        case "html", "htm": return .html
        case "pdf": return .pdf
        case "png", "jpg", "jpeg", "gif", "webp", "svg": return .image
        case "txt", "md", "markdown", "mdx", "docx": return .document
        case "zip", "json": return .export
        default: return nil
        }
    }

    /// The extensions the file picker offers.
    public static let extensions = [
        "jsx", "tsx", "html", "htm", "pdf", "png", "jpg", "jpeg", "gif", "webp", "svg", "txt", "md", "markdown", "mdx", "docx",
    ]

    /// A PDF or an image over the ceiling is refused before a byte of it is sent.
    public static func isOverTheCeiling(bytes: Int) -> Bool { bytes > maxPDFBytes }

    public static var pdfTooBig: String { "PDF is over the \(maxPDFLabel) limit." }
    public static var fileTooBig: String { "That file is over the \(maxPDFLabel) limit." }

    /// The sentence for a file that would be refused before it is sent, or nil: the kind says what is checked. A document
    /// is held to the memory import's own limit and its own sentence.
    public static func refusal(forFilename name: String, kind: Kind, byteCount: Int) -> String? {
        switch kind {
        case .pdf: return isOverTheCeiling(bytes: byteCount) ? pdfTooBig : nil
        case .image: return isOverTheCeiling(bytes: byteCount) ? fileTooBig : nil
        case .document: return MemoryImportPolicy.problem(filename: name, byteCount: byteCount)
        case .export: return exportElsewhere
        case .component, .html: return nil
        }
    }

    /// The page's title: the file's name without its `.jsx` or `.tsx`.
    public static func title(ofComponent name: String) -> String {
        let lower = name.lowercased()
        guard lower.hasSuffix(".jsx") || lower.hasSuffix(".tsx") else { return name }
        return String(name.dropLast(4))
    }

    /// The page's title: the file's name without its extension, whatever it is (`file.name.replace(/\.[a-z0-9]+$/i, "")`).
    public static func title(ofFilename name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return name }
        let ext = name[name.index(after: dot)...].lowercased()
        guard !ext.isEmpty, ext.unicodeScalars.allSatisfy({ ($0.value >= 48 && $0.value <= 57) || ($0.value >= 97 && $0.value <= 122) }) else {
            return name
        }
        return String(name[..<dot])
    }

    /// The request that keeps a component file: typed as `jsx`, so the server runs it as a component even when it
    /// cannot tell, as `saveJsx` does on the web.
    public static func saveRequest(componentText text: String, filename: String) -> ArtifactSaveRequest {
        ArtifactSaveRequest(content: text, title: title(ofComponent: filename), type: "jsx")
    }

    /// The request that keeps an HTML file: typed as `html` and pinned as it, since a real page can trip the heuristics that
    /// look for React.
    public static func saveRequest(htmlText text: String, filename: String) -> ArtifactSaveRequest {
        ArtifactSaveRequest(content: text, title: title(ofFilename: filename), type: "html", forceHtml: true)
    }
}
