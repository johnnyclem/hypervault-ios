import HyperVaultKit
import XCTest
@testable import HyperVault

/// The Memorize sheet shows "Uploading the file…" and then "Reading the file…" while a big file goes to the server. A line that
/// appears or changes on the screen is not read out by VoiceOver, so each stage is spoken as well, in the words the eye reads.
@MainActor
final class MemorizeAnnouncementTests: XCTestCase {
    private let base = URL(string: "https://hv.test")!
    private let newServer = Capabilities.Limits(importFileBytes: 10_000_000, importInlineFileBytes: 4_000_000)
    private let storagePath = "/storage/v1/object/upload/sign/import-staging/u1/3f2a.pdf"

    private func importer(put: Int = 200) -> MemoryFileImporter {
        let ticket = #"{"path":"u1/3f2a.pdf","signed_url":"https://p.supabase.test\#(storagePath)?token=t","token":"t","content_type":"application/pdf","max_bytes":10000000}"#
        let kept = #"{"id":"m5","title":"Report","summary":"s","tags":[],"source":"file","links":0,"branch":"main","commit_id":"c5","message":"Imported."}"#
        let transport = MockTransport(routes: [
            .json(.post, "/api/memories/import/upload-url", ticket),
            MockRoute(.put, storagePath) { _ in HTTPResponse(status: put) },
            .json(.post, "/api/memories/import", kept),
        ])
        let client = HVClient(baseURL: base, transport: transport, tokens: StaticTokenProvider(), retry: .none)
        return MemoryFileImporter(client: client, limits: newServer, transport: transport)
    }

    func testEachStageIsSpokenInTheWordsTheSheetShows() {
        let speech = RecordingAnnouncer()
        speech.announce(stage: .uploading)
        speech.announce(stage: .reading)
        XCTAssertEqual(speech.spoken, ["Uploading the file…", "Reading the file…"])
        XCTAssertEqual(speech.spoken, [MemoryFileImporter.Stage.uploading.line, MemoryFileImporter.Stage.reading.line])
    }

    func testABigFileIsSpokenAboutOncePerStageInOrderAndAFileThatFitsTheRequestSaysNothing() async throws {
        let speech = RecordingAnnouncer()
        _ = try await importer().importFile(filename: "Report.pdf", data: Data(count: 5_000_000)) { speech.announce(stage: $0) }
        XCTAssertEqual(speech.spoken, ["Uploading the file…", "Reading the file…"])

        speech.clear()
        _ = try await importer().importFile(filename: "Report.pdf", data: Data(count: 3_000_000)) { speech.announce(stage: $0) }
        XCTAssertTrue(speech.spoken.isEmpty, "one request has no stages, and the toast that follows says it was kept")
    }

    func testAnUploadThatFailsNeverSpeaksOfReading() async {
        let speech = RecordingAnnouncer()
        do {
            _ = try await importer(put: 503).importFile(filename: "Report.pdf", data: Data(count: 5_000_000)) { speech.announce(stage: $0) }
            XCTFail("expected the upload to fail")
        } catch {
            XCTAssertEqual(speech.spoken, ["Uploading the file…"])
        }
    }
}
