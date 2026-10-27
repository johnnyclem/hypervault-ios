import XCTest
@testable import HyperVaultKit

/// components/jsx-import-button.tsx: which files the Import pane takes, and what it saves them as.
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

    func testAnythingElseIsNeither() {
        for name in ["photo.png", "notes.txt", "page.html", "jsx", "pdf", "app.jsx.txt", "app.js", ".jsxx", ""] {
            XCTAssertNil(FileImport.kind(ofFilename: name), name)
        }
        XCTAssertEqual(FileImport.pickAFile, "Pick a .jsx, .tsx, or .pdf file.")
    }

    func testAPdfIsHeldToTheHighestPlansCeilingAndTheServerHoldsEachPlanToItsOwn() {
        XCTAssertFalse(FileImport.isOverTheCeiling(bytes: 50_000_000))
        XCTAssertTrue(FileImport.isOverTheCeiling(bytes: 50_000_001))
        XCTAssertFalse(FileImport.isOverTheCeiling(bytes: 0))
        XCTAssertEqual(FileImport.pdfTooBig, "PDF is over the 50 MB limit.")
    }

    func testTheTitleIsTheNameWithoutItsExtension() {
        XCTAssertEqual(FileImport.title(ofComponent: "Pomodoro.jsx"), "Pomodoro")
        XCTAssertEqual(FileImport.title(ofComponent: "Pomodoro.TSX"), "Pomodoro")
        XCTAssertEqual(FileImport.title(ofComponent: "a.b.jsx"), "a.b")
        XCTAssertEqual(FileImport.title(ofComponent: "notes.txt"), "notes.txt")
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
}
