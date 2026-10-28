import Foundation

// The Import pane's second row, "A file": a `.jsx` or `.tsx` React component is kept through the same pipeline a paste
// goes through (it becomes a running, installable page), and a PDF is stored as it is. The web's one shared entry for
// both is components/jsx-import-button.tsx; its limits are lib/artifacts/files.ts.

public enum FileImport {
    public enum Kind: Sendable, Equatable {
        /// A `.jsx` or `.tsx` file: its text is saved, typed as a component.
        case component
        case pdf
    }

    /// `MAX_FILE_BYTES`: the highest plan's ceiling, which the page checks before it uploads. The server holds each plan
    /// to its own (a free account is stopped at 1 MB with the server's own sentence). The row's line on the web still
    /// says 10 MB, which is older than the code.
    public static let maxPDFBytes = 50_000_000
    public static let maxPDFLabel = "50 MB"

    /// What a person is told when the file is neither (the web's sentence).
    public static let pickAFile = "Pick a .jsx, .tsx, or .pdf file."

    /// What the file is by its name, matched without regard to case as the web does (`/\.(jsx|tsx)$/i`, `/\.pdf$/i`).
    public static func kind(ofFilename name: String) -> Kind? {
        let lower = name.lowercased()
        if lower.hasSuffix(".pdf") { return .pdf }
        if lower.hasSuffix(".jsx") || lower.hasSuffix(".tsx") { return .component }
        return nil
    }

    /// A PDF over the ceiling is refused before a byte of it is sent.
    public static func isOverTheCeiling(bytes: Int) -> Bool { bytes > maxPDFBytes }

    public static var pdfTooBig: String { "PDF is over the \(maxPDFLabel) limit." }

    /// The page's title: the file's name without its `.jsx` or `.tsx`.
    public static func title(ofComponent name: String) -> String {
        let lower = name.lowercased()
        guard lower.hasSuffix(".jsx") || lower.hasSuffix(".tsx") else { return name }
        return String(name.dropLast(4))
    }

    /// The request that keeps a component file: typed as `jsx`, so the server runs it as a component even when it
    /// cannot tell, as `saveJsx` does on the web.
    public static func saveRequest(componentText text: String, filename: String) -> ArtifactSaveRequest {
        ArtifactSaveRequest(content: text, title: title(ofComponent: filename), type: "jsx")
    }
}
