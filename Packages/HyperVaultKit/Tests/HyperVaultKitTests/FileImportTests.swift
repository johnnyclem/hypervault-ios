import XCTest
@testable import HyperVaultKit

/// components/import-anything-button.tsx and jsx-import-button.tsx: which files the Import pane takes, where each one goes,
/// and what it is saved as.
final class FileImportTests: XCTestCase {
    func testAComponentIsAJsxOrTsxFileWhateverTheCase() {
        for name in ["App.jsx", "App.tsx", "app.JSX", "Notes.Tsx", "my page.jsx", "a.b.jsx"] {
            XCTAssertEqual(FileImport.kind(ofFilename: name), .component, name)
        }
    }

    func testAPdfIsAPdfWhateverTheCase() {
        for name in ["paper.pdf", "Paper.PDF", "a.b.Pdf"] {
            XCTAssertEqual(FileImport.kind(ofFilename: name), .pdf, name)
        }
    }

    func testEveryTypeTheWebsOneStopImportTakesGoesWhereTheWebSendsIt() {
        let expected: [(String, FileImport.Kind)] = [
            ("page.html", .html), ("page.HTM", .html),
            ("photo.png", .image), ("photo.JPG", .image), ("photo.jpeg", .image), ("anim.gif", .image), ("pic.webp", .image), ("logo.svg", .image),
            ("notes.txt", .document), ("README.md", .document), ("post.markdown", .document), ("post.mdx", .document), ("brief.DOCX", .document),
            ("conversations.json", .export), ("export.zip", .export), ("Archive.ZIP", .export),
        ]
        for (name, kind) in expected { XCTAssertEqual(FileImport.kind(ofFilename: name), kind, name) }
    }

    func testAnythingElseIsNoneOfThem() {
        for name in ["jsx", "pdf", "html", "app.jsx.txt.bak", "app.js", ".jsxx", "", "movie.mp4", "sheet.xlsx", "notes.rtf", ".txt"] {
            XCTAssertNil(FileImport.kind(ofFilename: name), name)
        }
        XCTAssertEqual(
            FileImport.pickAFile,
            "Unsupported file type \u{2014} try a data-export .zip/.json, .jsx, .html, .pdf, an image, or .txt/.md/.docx."
        )
    }

    func testTheFilePickerOffersExactlyTheTypesThatAreKept() {
        for ext in FileImport.extensions {
            let kind = FileImport.kind(ofFilename: "file.\(ext)")
            XCTAssertNotNil(kind, ext)
            XCTAssertNotEqual(kind, .export, "an export is not offered here: the history importer takes it")
        }
    }

    func testAPdfIsHeldToTheHighestPlansCeilingAndTheServerHoldsEachPlanToItsOwn() {
        XCTAssertFalse(FileImport.isOverTheCeiling(bytes: 50_000_000))
        XCTAssertTrue(FileImport.isOverTheCeiling(bytes: 50_000_001))
        XCTAssertFalse(FileImport.isOverTheCeiling(bytes: 0))
        XCTAssertEqual(FileImport.pdfTooBig, "PDF is over the 50 MB limit.")
        XCTAssertEqual(FileImport.fileTooBig, "That file is over the 50 MB limit.")
    }

    func testEachKindIsRefusedBeforeItIsSentWithItsOwnSentence() {
        XCTAssertEqual(FileImport.refusal(forFilename: "a.pdf", kind: .pdf, byteCount: 50_000_001), "PDF is over the 50 MB limit.")
        XCTAssertEqual(FileImport.refusal(forFilename: "a.png", kind: .image, byteCount: 50_000_001), "That file is over the 50 MB limit.")
        XCTAssertNil(FileImport.refusal(forFilename: "a.png", kind: .image, byteCount: 49_000_000))
        XCTAssertNil(FileImport.refusal(forFilename: "a.html", kind: .html, byteCount: 60_000_000), "text pages are limited by the server, not here")
        let big = FileImport.refusal(forFilename: "book.docx", kind: .document, byteCount: 4_000_001)
        XCTAssertEqual(big, MemoryImportPolicy.problem(filename: "book.docx", byteCount: 4_000_001), "a document has the memory import's own limit")
        XCTAssertNotNil(big)
        XCTAssertNil(FileImport.refusal(forFilename: "a.md", kind: .document, byteCount: 4_000_000))
        XCTAssertEqual(FileImport.refusal(forFilename: "x.zip", kind: .export, byteCount: 10), FileImport.exportElsewhere)
    }

    func testTheTitleIsTheNameWithoutItsExtension() {
        XCTAssertEqual(FileImport.title(ofComponent: "Pomodoro.jsx"), "Pomodoro")
        XCTAssertEqual(FileImport.title(ofComponent: "Pomodoro.TSX"), "Pomodoro")
        XCTAssertEqual(FileImport.title(ofComponent: "a.b.jsx"), "a.b")
        XCTAssertEqual(FileImport.title(ofComponent: "notes.txt"), "notes.txt")

        XCTAssertEqual(FileImport.title(ofFilename: "index.html"), "index")
        XCTAssertEqual(FileImport.title(ofFilename: "My Page.HTM"), "My Page")
        XCTAssertEqual(FileImport.title(ofFilename: "a.b.html"), "a.b")
        XCTAssertEqual(FileImport.title(ofFilename: "README"), "README")
        XCTAssertEqual(FileImport.title(ofFilename: ".hidden"), ".hidden")
        XCTAssertEqual(FileImport.title(ofFilename: "v1.0 notes"), "v1.0 notes", "a dot in the middle of words is not an extension")
    }

    func testAComponentIsSavedTypedAsJsxThroughThePastePipeline() throws {
        let request = FileImport.saveRequest(componentText: "export default function App() { return null }", filename: "Pomodoro.jsx")
        XCTAssertEqual(request.type, "jsx")
        XCTAssertEqual(request.title, "Pomodoro")
        XCTAssertEqual(request.content, "export default function App() { return null }")
        XCTAssertFalse(request.forceHtml)
        XCTAssertEqual(request.visibility, .private)
        XCTAssertTrue(request.tags.isEmpty)

        let endpoint = Endpoint<ArtifactSaveResult>.saveArtifact(request)
        XCTAssertEqual(endpoint.method, .post)
        XCTAssertEqual(endpoint.path, "/api/save")
    }

    func testAnHtmlFileIsSavedTypedAsHtmlAndPinnedAsItSoItIsNotTakenForReact() throws {
        let request = FileImport.saveRequest(htmlText: "<!doctype html><title>x</title><script>const a = <b/>;</script>", filename: "landing.html")
        XCTAssertEqual(request.type, "html")
        XCTAssertEqual(request.title, "landing")
        XCTAssertTrue(request.forceHtml)
        XCTAssertEqual(request.visibility, .private)

        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: HVCoding.encoder().encode(request)) as? [String: Any])
        XCTAssertEqual(encoded["type"] as? String, "html")
        XCTAssertEqual(encoded["force_html"] as? Bool, true, "the web's `force_html`")
    }
}
