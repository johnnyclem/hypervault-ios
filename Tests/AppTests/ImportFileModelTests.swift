import HyperVaultKit
import XCTest
@testable import HyperVault

/// The Import pane's "A file": one entry, and each file goes where the web's side menu Import sends it by its type.
@MainActor
final class ImportFileModelTests: XCTestCase {
    private let base = URL(string: "https://hv.test")!

    private func model(_ routes: [MockRoute], limits: Capabilities.Limits = Capabilities.Limits()) -> (ImportFileModel, MockTransport) {
        let transport = MockTransport(routes: routes)
        let client = HVClient(baseURL: base, transport: transport, tokens: StaticTokenProvider(), retry: .none)
        return (ImportFileModel(client: client, limits: limits, transport: transport), transport)
    }

    /// What a server that takes a file by way of storage says: 10 MB in all, 4 MB in the request.
    private let newServer = Capabilities.Limits(importFileBytes: 10_000_000, importInlineFileBytes: 4_000_000)
    private let docxType = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    private let storagePath = "/storage/v1/object/upload/sign/import-staging/u1/3f2a.docx"
    private let keptDocument = #"{"id":"m5","title":"Report","summary":"s","tags":["file"],"source":"file","links":0,"branch":"draft","commit_id":"c5","message":"Imported the file. It is in your private wiki now."}"#

    /// The three requests of a file by way of storage: where to put it, the PUT, and the import that names it.
    private func stagingRoutes(put: Int = 200, importRoute: MockRoute? = nil) -> [MockRoute] {
        let ticket = #"{"path":"u1/3f2a.docx","signed_url":"https://p.supabase.test\#(storagePath)?token=t","token":"t","content_type":"\#(docxType)","max_bytes":10000000}"#
        return [
            .json(.post, "/api/memories/import/upload-url", ticket),
            MockRoute(.put, storagePath) { _ in HTTPResponse(status: put) },
            importRoute ?? .json(.post, "/api/memories/import", keptDocument),
        ]
    }

    private func paths(_ transport: MockTransport) async -> [String] {
        await transport.requests.map { ($0.httpMethod ?? "GET") + " " + ($0.url?.path ?? "") }
    }

    private let saved = #"{"url":"https://hv.test/a/landing-x1","slug":"landing-x1","is_jsx":false,"visibility":"private","mutable":false,"duplicate":false,"message":"Kept."}"#

    private func sentBody(_ transport: MockTransport, _ path: String) async -> [String: Any]? {
        let sent = await transport.requests.filter { $0.url?.path == path }
        guard let data = sent.last?.httpBody else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    func testAnHtmlFileBecomesAPagePinnedAsHtml() async {
        let (model, transport) = model([.json(.post, "/api/save", saved)])
        let outcome = await model.keep(name: "landing.html", data: Data("<!doctype html><title>Hi</title>".utf8))
        XCTAssertEqual(outcome, .page(slug: "landing-x1", duplicate: false))
        let body = await sentBody(transport, "/api/save")
        XCTAssertEqual(body?["type"] as? String, "html")
        XCTAssertEqual(body?["title"] as? String, "landing")
        XCTAssertEqual(body?["force_html"] as? Bool, true, "a real page can trip the heuristics that look for React")
        XCTAssertEqual(body?["content"] as? String, "<!doctype html><title>Hi</title>")
        XCTAssertFalse(model.isBusy)
    }

    func testAComponentFileIsStillSavedAsJsx() async {
        let (model, transport) = model([.json(.post, "/api/save", saved)])
        let outcome = await model.keep(name: "Pomodoro.tsx", data: Data("export default function A() { return null }".utf8))
        XCTAssertEqual(outcome, .page(slug: "landing-x1", duplicate: false))
        let body = await sentBody(transport, "/api/save")
        XCTAssertEqual(body?["type"] as? String, "jsx")
        XCTAssertEqual(body?["title"] as? String, "Pomodoro")
        XCTAssertNotEqual(body?["force_html"] as? Bool, true, "a component is not pinned as HTML")
    }

    func testAPageThatWasAlreadyKeptSaysSo() async {
        let (model, _) = model([.json(.post, "/api/save", saved.replacingOccurrences(of: "\"duplicate\":false", with: "\"duplicate\":true"))])
        let outcome = await model.keep(name: "landing.html", data: Data("<p>x</p>".utf8))
        XCTAssertEqual(outcome, .page(slug: "landing-x1", duplicate: true))
    }

    func testAMarkdownOrWordFileBecomesAMemoryAndAnswersWithTheServersSentence() async {
        let kept = #"{"id":"m9","title":"Notes","summary":"s","tags":["file"],"source":"file","links":0,"branch":"main","commit_id":"c9","message":"Imported the file — it's in your private wiki now."}"#
        let (model, transport) = model([.json(.post, "/api/memories/import", kept)])
        let outcome = await model.keep(name: "Notes.md", data: Data("# Notes\n\nFerry on Friday.".utf8))
        XCTAssertEqual(outcome, .memory(id: "m9", message: "Imported the file \u{2014} it's in your private wiki now."))
        let sent = await transport.requests.filter { $0.url?.path == "/api/memories/import" }
        XCTAssertEqual(sent.count, 1)
        XCTAssertTrue(sent[0].value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data") == true)
        XCTAssertNil(sent[0].url?.query, "no branch named: the server reads main")
    }

    func testADocumentIsKeptOnTheBranchThePersonIsReadingSoThatTheMemoryThatOpensIsThere() async {
        let kept = #"{"id":"m9","title":"Notes","summary":"s","tags":[],"source":"file","links":0,"branch":"draft","commit_id":"c9","message":"Imported."}"#
        let (model, transport) = model([.json(.post, "/api/memories/import", kept)])
        _ = await model.keep(name: "Notes.txt", data: Data("Ferry on Friday.".utf8), branch: "draft")
        let sent = await transport.requests.filter { $0.url?.path == "/api/memories/import" }
        XCTAssertEqual(sent.last?.url?.query, "branch=draft")
    }

    // MARK: A document up to what the server takes

    func testADocumentOverWhatARequestCarriesIsPutInStorageFirstWhenTheServerTakesIt() async throws {
        let (model, transport) = model(stagingRoutes(), limits: newServer)
        let data = Data(count: 4_500_000)
        let outcome = await model.keep(name: "Report.docx", data: data, branch: "draft")
        XCTAssertEqual(outcome, .memory(id: "m5", message: "Imported the file. It is in your private wiki now."))
        let sent = await paths(transport)
        XCTAssertEqual(sent, ["POST /api/memories/import/upload-url", "PUT \(storagePath)", "POST /api/memories/import"])

        let requests = await transport.requests
        guard requests.count == 3 else { return XCTFail("expected the ask, the PUT and the import, got \(requests.count) requests") }
        let put = requests[1]
        XCTAssertEqual(put.value(forHTTPHeaderField: "Content-Type"), docxType)
        XCTAssertNil(put.value(forHTTPHeaderField: "Authorization"), "the signed address carries its own permission")
        XCTAssertEqual(put.httpBody, data)
        let named = requests[2]
        XCTAssertEqual(named.url?.query, "branch=draft", "the memory is made on the branch the person is reading")
        XCTAssertEqual(String(decoding: try XCTUnwrap(named.httpBody), as: UTF8.self), #"{"filename":"Report.docx","upload":"u1/3f2a.docx"}"#)
        XCTAssertFalse(model.isBusy)
    }

    func testADocumentThatFitsTheRequestStillGoesInItOnAServerThatTakesMore() async {
        let (model, transport) = model(stagingRoutes(), limits: newServer)
        let outcome = await model.keep(name: "Notes.md", data: Data(count: 4_000_000))
        XCTAssertEqual(outcome, .memory(id: "m5", message: "Imported the file. It is in your private wiki now."))
        let sent = await paths(transport)
        XCTAssertEqual(sent, ["POST /api/memories/import"], "up to the request's own limit, nothing is staged")
    }

    func testADocumentOverWhatTheServerTakesIsRefusedBeforeAnythingIsSent() async {
        let (model, transport) = model(stagingRoutes(), limits: newServer)
        let outcome = await model.keep(name: "book.docx", data: Data(count: 10_000_001))
        XCTAssertEqual(outcome, .refused("\"book.docx\" is over the 10 MB import limit \u{2014} split it or trim it down."))
        let sent = await paths(transport)
        XCTAssertTrue(sent.isEmpty)
    }

    func testAnOlderServerThatStatesNoLimitsHoldsADocumentTo4MBInTheRequestAsBefore() async {
        // `Capabilities.Limits()` is what a server that does not say decodes to (the Kit tests decode one).
        let (model, transport) = model(stagingRoutes())
        let outcome = await model.keep(name: "book.docx", data: Data(count: 4_000_001))
        XCTAssertEqual(outcome, .refused("\"book.docx\" is over the 4 MB import limit \u{2014} split it or trim it down."))
        let sent = await paths(transport)
        XCTAssertTrue(sent.isEmpty, "no address is asked for from a server that does not hand them out")
    }

    func testAFileOnDiskIsSizedAgainstTheServersLimitsAndStagedWhenItIsPastTheRequests() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let report = folder.appendingPathComponent("Report.docx")
        try Data(count: 4_500_000).write(to: report)
        let huge = folder.appendingPathComponent("huge.docx")
        try Data(count: 10_000_001).write(to: huge)

        let (model, transport) = model(stagingRoutes(), limits: newServer)
        let refused = await model.keep(huge)
        XCTAssertEqual(refused, .refused("\"huge.docx\" is over the 10 MB import limit \u{2014} split it or trim it down."))
        let sentAfterRefusal = await paths(transport)
        XCTAssertTrue(sentAfterRefusal.isEmpty, "a file over the limit is refused without being read or sent")
        let kept = await model.keep(report, branch: "draft")
        XCTAssertEqual(kept, .memory(id: "m5", message: "Imported the file. It is in your private wiki now."))
        let sent = await paths(transport)
        XCTAssertEqual(sent.count, 3)

        // The same file on a server that says nothing is over its 4 MB.
        let (older, olderTransport) = self.model([])
        let tooBig = await older.keep(report)
        XCTAssertEqual(tooBig, .refused("\"Report.docx\" is over the 4 MB import limit \u{2014} split it or trim it down."))
        let none = await paths(olderTransport)
        XCTAssertTrue(none.isEmpty)
    }

    func testAFailedUploadToStorageIsSaidInWordsAndTheImportIsNotAsked() async {
        let (model, transport) = model(stagingRoutes(put: 503), limits: newServer)
        let outcome = await model.keep(name: "Report.docx", data: Data(count: 4_500_000))
        XCTAssertEqual(outcome, .refused(MemoryFileImporter.storageFailedLine))
        let sent = await paths(transport)
        XCTAssertEqual(sent, ["POST /api/memories/import/upload-url", "PUT \(storagePath)"])
        XCTAssertFalse(model.isBusy, "it is not left busy")
    }

    func testTheServersSentenceForAStagedFileItCouldNotReadIsWhatIsSaid() async {
        let expired = MockRoute.failure(.post, "/api/memories/import", status: 404, message: "That upload wasn't found \u{2014} it may have expired. Upload it again.")
        let (model, _) = model(stagingRoutes(importRoute: expired), limits: newServer)
        let outcome = await model.keep(name: "Report.docx", data: Data(count: 4_500_000))
        XCTAssertEqual(outcome, .refused("That upload wasn't found \u{2014} it may have expired. Upload it again."))
        XCTAssertFalse(model.isBusy)
    }

    func testADocumentThatTheServerTurnsAwayAsTooBigSaysWhatTheMemoryImportSays() async {
        let (model, _) = model([.json(.post, "/api/memories/import", "Request Entity Too Large", status: 413)])
        let outcome = await model.keep(name: "Notes.md", data: Data("x".utf8))
        XCTAssertEqual(outcome, .refused("That upload is too large \u{2014} the import limit is 4 MB."))
    }

    func testABareTooBigAnswerNamesTheLimitOfTheRequestThisServerStated() async {
        // The platform's plain-text 413 can only come from a request that carried the file, so the number in the sentence
        // is the request's limit as the server stated it, not the 10 MB that staging allows and not a built-in 4 MB.
        let limits = Capabilities.Limits(importFileBytes: 10_000_000, importInlineFileBytes: 4_500_000)
        let (model, _) = model([.json(.post, "/api/memories/import", "Request Entity Too Large", status: 413)], limits: limits)
        let outcome = await model.keep(name: "Notes.md", data: Data("x".utf8))
        XCTAssertEqual(outcome, .refused("That upload is too large \u{2014} the import limit is 4.5 MB."))
    }

    func testAPdfOrImageOverTheCeilingIsRefusedBeforeAnythingIsSentAndAnEmptyOneIsToo() async {
        let (model, transport) = model([])
        let pdf = await model.keep(name: "paper.pdf", data: Data(count: 50_000_001))
        XCTAssertEqual(pdf, .refused(FileImport.pdfTooBig))
        let image = await model.keep(name: "photo.png", data: Data(count: 50_000_001))
        XCTAssertEqual(image, .refused(FileImport.fileTooBig))
        let empty = await model.keep(name: "photo.png", data: Data())
        XCTAssertEqual(empty, .refused("That file is empty."))
        let sent = await transport.requests
        XCTAssertTrue(sent.isEmpty)
    }

    func testAFileOnDiskIsReadByItsNameAndSizeBeforeItIsRead() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let big = folder.appendingPathComponent("big.md")
        try Data(count: 4_000_001).write(to: big)
        let small = folder.appendingPathComponent("landing.html")
        try Data("<p>hello</p>".utf8).write(to: small)

        let (model, transport) = model([.json(.post, "/api/save", saved)])
        let refused = await model.keep(big)
        XCTAssertEqual(refused, .refused(MemoryImportPolicy.problem(filename: "big.md", byteCount: 4_000_001) ?? ""))
        let kept = await model.keep(small)
        XCTAssertEqual(kept, .page(slug: "landing-x1", duplicate: false))
        let missing = await model.keep(folder.appendingPathComponent("gone.html"))
        XCTAssertEqual(missing, .refused("That file couldn't be read."))
        let sent = await transport.requests
        XCTAssertEqual(sent.count, 1, "only the page that could be read was sent")
    }

    func testADataExportIsPointedAtTheHistoryImporter() async {
        let (model, transport) = model([])
        for name in ["export.zip", "conversations.json"] {
            let outcome = await model.keep(name: name, data: Data("{}".utf8))
            XCTAssertEqual(outcome, .refused(FileImport.exportElsewhere), name)
        }
        let sent = await transport.requests
        XCTAssertTrue(sent.isEmpty, "nothing is sent for a file this pane does not take")
    }

    func testAFileOfAnotherTypeIsRefusedWithTheWebsSentenceAndNothingIsSent() async {
        let (model, transport) = model([])
        let outcome = await model.keep(name: "movie.mp4", data: Data([0, 1, 2]))
        XCTAssertEqual(outcome, .refused(FileImport.pickAFile))
        let sent = await transport.requests
        XCTAssertTrue(sent.isEmpty)
    }

    func testADocumentOverTheMemoryLimitIsRefusedBeforeItIsSent() async {
        let (model, transport) = model([])
        let outcome = await model.keep(name: "book.docx", data: Data(count: 4_000_001))
        XCTAssertEqual(outcome, .refused(MemoryImportPolicy.problem(filename: "book.docx", byteCount: 4_000_001) ?? ""))
        let sent = await transport.requests
        XCTAssertTrue(sent.isEmpty)
    }

    func testAPageThatIsNotTextIsRefusedAsSuch() async {
        let (model, transport) = model([])
        let outcome = await model.keep(name: "page.html", data: Data([0xFF, 0xFE, 0xFD]))
        XCTAssertEqual(outcome, .refused("That file isn't text, so it can't be kept as a page."))
        let sent = await transport.requests
        XCTAssertTrue(sent.isEmpty)
    }

    func testTheServersSentenceIsWhatAFailedKeepSays() async {
        let (model, _) = model([.failure(.post, "/api/save", status: 413, message: "Artifact is over the 1 MB limit. Trim embedded assets and try again.")])
        let outcome = await model.keep(name: "big.html", data: Data("<p>x</p>".utf8))
        XCTAssertEqual(outcome, .refused("Artifact is over the 1 MB limit. Trim embedded assets and try again."))
        XCTAssertFalse(model.isBusy, "it is not left busy")
    }
}
