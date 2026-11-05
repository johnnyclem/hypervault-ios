import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HyperVaultKit

/// A file import by way of storage: shaped by app/api/memories/import/route.ts and
/// app/api/memories/import/upload-url/route.ts. The numbers are the server's (10 MB in all, 4 MB in the request).
final class MemoryFileImporterTests: XCTestCase {
    private let base = URL(string: "https://hv.test")!
    private let newServer = Capabilities.Limits(importFileBytes: 10_000_000, importInlineFileBytes: 4_000_000)

    private let kept = #"{"id":"m5","title":"Quarterly report","summary":"s","tags":["pdf","notes"],"source":"file","links":0,"branch":"main","commit_id":"c5","message":"Imported the file — it's in your private wiki now."}"#
    private let storagePath = "/storage/v1/object/upload/sign/import-staging/u1/3f2a.pdf"

    private func ticket(contentType: String? = "application/pdf", maxBytes: Int? = 10_000_000, signedURL: String? = nil) -> String {
        let address = signedURL ?? "https://p.supabase.test\(storagePath)?token=t"
        var fields = ["\"path\":\"u1/3f2a.pdf\"", "\"signed_url\":\"\(address)\"", "\"token\":\"t\""]
        if let contentType { fields.append("\"content_type\":\"\(contentType)\"") }
        if let maxBytes { fields.append("\"max_bytes\":\(maxBytes)") }
        return "{" + fields.joined(separator: ",") + "}"
    }

    private func routes(ticket: String? = nil, put: Int = 200) -> [MockRoute] {
        [
            .json(.post, "/api/memories/import/upload-url", ticket ?? self.ticket()),
            MockRoute(.put, storagePath) { _ in HTTPResponse(status: put, data: Data(#"{"Key":"import-staging/u1/3f2a.pdf"}"#.utf8)) },
            .json(.post, "/api/memories/import", kept),
        ]
    }

    private func setup(
        _ routes: [MockRoute], limits: Capabilities.Limits? = nil, retry: RetryPolicy = .none
    ) -> (MemoryFileImporter, MockTransport) {
        let transport = MockTransport(routes: routes)
        let client = HVClient(baseURL: base, transport: transport, tokens: StaticTokenProvider("app-token"), retry: retry, sleep: { _ in })
        return (MemoryFileImporter(client: client, limits: limits ?? newServer, transport: transport), transport)
    }

    private func paths(_ transport: MockTransport) async -> [String] {
        await transport.requests.map { ($0.httpMethod ?? "GET") + " " + ($0.url?.path ?? "") }
    }

    private func json(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
    }

    private func failure(_ work: () async throws -> MemoryKept, file: StaticString = #filePath, line: UInt = #line) async -> HVError? {
        do {
            _ = try await work()
            XCTFail("expected a refusal", file: file, line: line)
            return nil
        } catch let error as HVError {
            return error
        } catch {
            XCTFail("wrong error \(error)", file: file, line: line)
            return nil
        }
    }

    // MARK: Which way a file goes

    func testAFileThatFitsInTheRequestIsSentInIt() async throws {
        let (importer, transport) = setup(routes())
        let log = StageLog()
        let memory = try await importer.importFile(filename: "Quarterly report.pdf", data: Data(count: 3_000_000), branch: "main") { log.add($0) }
        XCTAssertEqual(memory.source, "file")
        let sent = await paths(transport)
        XCTAssertEqual(sent, ["POST /api/memories/import"], "no address is asked for and nothing is put in storage")
        let sentRequests = await transport.requests
        let request = try XCTUnwrap(sentRequests.first)
        XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
        XCTAssertEqual(request.url?.query, "branch=main")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer app-token")
        XCTAssertEqual(log.stages, [], "one request has no stages to report")
    }

    func testTheInlineLimitIsInclusiveAndOneByteMoreIsStaged() async throws {
        let (atLimit, atTransport) = setup(routes())
        _ = try await atLimit.importFile(filename: "a.pdf", data: Data(count: 4_000_000))
        let inline = await paths(atTransport)
        XCTAssertEqual(inline, ["POST /api/memories/import"])

        let (over, overTransport) = setup(routes())
        _ = try await over.importFile(filename: "a.pdf", data: Data(count: 4_000_001))
        let staged = await paths(overTransport)
        XCTAssertEqual(staged, ["POST /api/memories/import/upload-url", "PUT \(storagePath)", "POST /api/memories/import"])
    }

    func testTheMostTheServerTakesIsStagedAndOneByteMoreIsRefusedBeforeAnythingIsSent() async throws {
        let (importer, transport) = setup(routes())
        _ = try await importer.importFile(filename: "a.docx", data: Data(count: 10_000_000))
        let allowed = await paths(transport)
        XCTAssertEqual(allowed.count, 3)

        let (strict, untouched) = setup(routes())
        let error = await failure { try await strict.importFile(filename: "book.pdf", data: Data(count: 10_000_001)) }
        XCTAssertEqual(error?.userMessage, "\"book.pdf\" is over the 10 MB import limit — split it or trim it down.")
        let none = await paths(untouched)
        XCTAssertEqual(none, [])
    }

    func testAFileOfAnotherKindIsRefusedBeforeAnythingIsSent() async {
        let (importer, transport) = setup(routes())
        let error = await failure { try await importer.importFile(filename: "photo.png", data: Data(count: 6_000_000)) }
        XCTAssertEqual(error?.userMessage, "Unsupported file type — import a PDF, DOCX, .md, or .txt file.")
        let none = await paths(transport)
        XCTAssertEqual(none, [])
    }

    // MARK: The staged import, request by request

    func testAStagedFileIsAskedForPutAndNamedWithTheRightRequests() async throws {
        let (importer, transport) = setup(routes())
        let log = StageLog()
        let data = Data((0..<4_500_000).map { UInt8(truncatingIfNeeded: $0) })
        let memory = try await importer.importFile(filename: "Quarterly report.pdf", data: data, branch: "draft") { log.add($0) }
        XCTAssertEqual(memory.title, "Quarterly report")
        XCTAssertEqual(memory.message, "Imported the file — it's in your private wiki now.")
        XCTAssertEqual(log.stages, [.uploading, .reading])

        let requests = await transport.requests
        XCTAssertEqual(requests.count, 3)

        // 1. Where to put it: the name and the size, as the app's signed-in client.
        let ask = requests[0]
        XCTAssertEqual(ask.url?.path, "/api/memories/import/upload-url")
        XCTAssertEqual(ask.httpMethod, "POST")
        XCTAssertEqual(ask.value(forHTTPHeaderField: "Authorization"), "Bearer app-token")
        XCTAssertEqual(ask.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(String(decoding: try XCTUnwrap(ask.httpBody), as: UTF8.self), #"{"filename":"Quarterly report.pdf","size":4500000}"#)

        // 2. The bytes, to the signed address, as the type the server named and with no token of the app's.
        let put = requests[1]
        XCTAssertEqual(put.httpMethod, "PUT")
        XCTAssertEqual(put.url?.absoluteString, "https://p.supabase.test\(storagePath)?token=t")
        XCTAssertEqual(put.value(forHTTPHeaderField: "Content-Type"), "application/pdf")
        XCTAssertNil(put.value(forHTTPHeaderField: "Authorization"), "the signed address carries its own permission; the app's token stays home")
        XCTAssertEqual(put.allHTTPHeaderFields?.keys.sorted(), ["Content-Type"], "nothing else that storage could read as a second credential")
        XCTAssertEqual(put.httpBody, data)

        // 3. The path it was given back, and the name, on the branch asked for.
        let name = requests[2]
        XCTAssertEqual(name.url?.path, "/api/memories/import")
        XCTAssertEqual(name.url?.query, "branch=draft")
        XCTAssertEqual(name.value(forHTTPHeaderField: "Authorization"), "Bearer app-token")
        XCTAssertEqual(name.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(String(decoding: try XCTUnwrap(name.httpBody), as: UTF8.self), #"{"filename":"Quarterly report.pdf","upload":"u1/3f2a.pdf"}"#)
    }

    func testThePutCarriesTheTypeTheServerNamedAndFallsBackToTheFilesOwn() async throws {
        let (named, namedTransport) = setup(routes(ticket: ticket(contentType: "text/plain")))
        _ = try await named.importFile(filename: "notes.md", data: Data(count: 4_500_000))
        let namedRequests = await namedTransport.requests
        let first = try XCTUnwrap(namedRequests.first { $0.httpMethod == "PUT" })
        XCTAssertEqual(first.value(forHTTPHeaderField: "Content-Type"), "text/plain", "the server's word, not the file name's")

        let (silent, silentTransport) = setup(routes(ticket: ticket(contentType: nil)))
        _ = try await silent.importFile(filename: "report.docx", data: Data(count: 4_500_000))
        let silentRequests = await silentTransport.requests
        let second = try XCTUnwrap(silentRequests.first { $0.httpMethod == "PUT" })
        XCTAssertEqual(second.value(forHTTPHeaderField: "Content-Type"), "application/vnd.openxmlformats-officedocument.wordprocessingml.document")
    }

    func testAFileWithoutABranchNamesNoneAndALocalStorageAddressIsAllowed() async throws {
        let local = ticket(signedURL: "http://127.0.0.1:54321\(storagePath)?token=t")
        let (importer, transport) = setup(routes(ticket: local))
        _ = try await importer.importFile(filename: "a.pdf", data: Data(count: 5_000_000))
        let requests = await transport.requests
        XCTAssertNil(requests[2].url?.query)
        XCTAssertEqual(requests[1].url?.host, "127.0.0.1")
    }

    func testAskingForAnAddressIsNeverRepeatedBecauseAnAddressIsWorthAFewAnHour() async {
        // The client repeats a safe call on a busy server; this one is not safe to repeat.
        let (importer, transport) = setup(
            [.failure(.post, "/api/memories/import/upload-url", status: 503, message: "Storage is not available right now.")],
            retry: RetryPolicy(maxAttempts: 3, baseDelay: 0, maxDelay: 0)
        )
        let error = await failure { try await importer.importFile(filename: "a.pdf", data: Data(count: 5_000_000)) }
        XCTAssertEqual(error?.userMessage, "Storage is not available right now.")
        let sent = await paths(transport)
        XCTAssertEqual(sent, ["POST /api/memories/import/upload-url"])
    }

    // MARK: Each step failing, in words

    func testTheServersRefusalsToHandOutAnAddressAreItsOwnSentences() async {
        let cases: [(Int, String)] = [
            (400, "A file name and its size are required."),
            (413, "That file is over the 10 MB import limit."),
            (415, "Unsupported file type — import a PDF, DOCX, .md, or .txt file."),
            (429, "You have too many uploads waiting. Finish or wait for those, then try again."),
            (503, "File storage isn't available right now. Try again in a moment."),
        ]
        for (status, sentence) in cases {
            let (importer, transport) = setup([.failure(.post, "/api/memories/import/upload-url", status: status, message: sentence)])
            let error = await failure { try await importer.importFile(filename: "a.pdf", data: Data(count: 5_000_000)) }
            XCTAssertEqual(error?.userMessage, sentence, "\(status)")
            XCTAssertEqual(error?.status, status)
            let sent = await paths(transport)
            XCTAssertEqual(sent, ["POST /api/memories/import/upload-url"], "nothing is put when there was nowhere to put it (\(status))")
        }
    }

    func testAnAddressThatIsNotALinkIsNotSentAFile() async {
        for bad in ["not a link", "ftp://p.supabase.test/x", "file:///etc/hosts", "/relative/path"] {
            let (importer, transport) = setup(routes(ticket: ticket(signedURL: bad)))
            let error = await failure { try await importer.importFile(filename: "a.pdf", data: Data(count: 5_000_000)) }
            XCTAssertEqual(error, .decoding("The upload address was not a link."), bad)
            let sent = await paths(transport)
            XCTAssertEqual(sent, ["POST /api/memories/import/upload-url"], bad)
        }
    }

    func testStorageTurningThePutAwayIsSaidInWordsAndNothingIsImported() async throws {
        for status in [400, 401, 403, 404, 500, 503] {
            let (importer, transport) = setup(routes(put: status))
            let refusal = await failure { try await importer.importFile(filename: "a.pdf", data: Data(count: 5_000_000)) }
            let error = try XCTUnwrap(refusal)
            XCTAssertEqual(error.userMessage, "The upload to storage didn't go through. Try again in a moment.", "\(status)")
            XCTAssertEqual(MemoryImportPolicy.message(for: error, limits: newServer), MemoryFileImporter.storageFailedLine)
            XCTAssertFalse(error.userMessage.contains("\(status)"), "a status code means nothing to a person")
            let sent = await paths(transport)
            XCTAssertEqual(sent.count, 2, "the import is not asked for a file that is not there (\(status))")
        }
    }

    func testStorageSayingTheFileIsTooBigNamesTheLimitItEnforces() async throws {
        let (importer, _) = setup(routes(ticket: ticket(maxBytes: 10_000_000), put: 413))
        let refusal = await failure { try await importer.importFile(filename: "big.pdf", data: Data(count: 5_000_000)) }
        let error = try XCTUnwrap(refusal)
        XCTAssertEqual(error.userMessage, "\"big.pdf\" is over the 10 MB import limit — split it or trim it down.")
        // Not the sentence for the platform's plain-text 413, which this is not.
        XCTAssertEqual(MemoryImportPolicy.message(for: error, limits: newServer), error.userMessage)

        let (lower, _) = setup(routes(ticket: ticket(maxBytes: 6_500_000), put: 413))
        let narrower = await failure { try await lower.importFile(filename: "big.pdf", data: Data(count: 5_000_000)) }
        XCTAssertEqual(narrower?.userMessage, "\"big.pdf\" is over the 6.5 MB import limit — split it or trim it down.")
    }

    func testAPutThatNeverGetsAnAnswerIsAConnectionProblemAndNothingIsImported() async {
        let inner = MockTransport(routes: routes())
        let client = HVClient(baseURL: base, transport: inner, tokens: StaticTokenProvider(), retry: .none)
        let offline = MemoryFileImporter(client: client, limits: newServer, transport: FailingPut(inner: inner, error: URLError(.networkConnectionLost)))
        let error = await failure { try await offline.importFile(filename: "a.pdf", data: Data(count: 5_000_000)) }
        XCTAssertEqual(error?.isOffline, true)
        XCTAssertEqual(error?.userMessage, "Network hiccup. Check your connection and try again.")
        let sent = await paths(inner)
        XCTAssertEqual(sent, ["POST /api/memories/import/upload-url"])
    }

    func testCancellingDuringThePutIsACancellationAndNotAProblemToShow() async {
        for thrown in [CancellationError() as any Error, URLError(.cancelled)] {
            let inner = MockTransport(routes: routes())
            let client = HVClient(baseURL: base, transport: inner, tokens: StaticTokenProvider(), retry: .none)
            let cancelled = MemoryFileImporter(client: client, limits: newServer, transport: FailingPut(inner: inner, error: thrown))
            let error = await failure { try await cancelled.importFile(filename: "a.pdf", data: Data(count: 5_000_000)) }
            XCTAssertEqual(error, .cancelled)
        }
    }

    func testTheServersRefusalsToReadTheStagedFileAreItsOwnSentences() async {
        let cases: [(Int, String)] = [
            (400, "No readable text found in that file."),
            (404, "That upload wasn't found — it may have expired. Upload it again."),
            (413, "That file is over the 10 MB import limit."),
            (415, "Unsupported file type — import a PDF, DOCX, .md, or .txt file."),
            (429, "Import rate limit reached — try again in a minute."),
        ]
        for (status, sentence) in cases {
            let (importer, transport) = setup([
                .json(.post, "/api/memories/import/upload-url", ticket()),
                MockRoute(.put, storagePath) { _ in HTTPResponse(status: 200) },
                .failure(.post, "/api/memories/import", status: status, message: sentence),
            ])
            let error = await failure { try await importer.importFile(filename: "a.pdf", data: Data(count: 5_000_000)) }
            XCTAssertEqual(error.map { MemoryImportPolicy.message(for: $0, limits: self.newServer) }, sentence, "\(status)")
            let sent = await paths(transport)
            XCTAssertEqual(sent.count, 3, "the import ran last (\(status))")
        }
    }

    func testEachStageHasALineToShowWhileItRuns() {
        XCTAssertEqual(MemoryFileImporter.Stage.uploading.line, "Uploading the file…")
        XCTAssertEqual(MemoryFileImporter.Stage.reading.line, "Reading the file…")
    }

    // MARK: An older server

    func testAServerThatSaysNothingOfTheseLimitsStaysMultipartOnlyAt4MB() async throws {
        let old = try HVCoding.decoder().decode(Capabilities.self, from: Data(#"{"limits":{"memory_bytes":500000,"import_bytes":50000000}}"#.utf8)).limits
        XCTAssertEqual(old.importFileBytes, 4_000_000)
        XCTAssertEqual(old.importInlineFileBytes, 4_000_000)

        let (importer, transport) = setup(routes(), limits: old)
        _ = try await importer.importFile(filename: "a.pdf", data: Data(count: 4_000_000))
        let fits = await paths(transport)
        XCTAssertEqual(fits, ["POST /api/memories/import"], "up to 4 MB goes in the request, as before")

        let (strict, untouched) = setup(routes(), limits: old)
        let error = await failure { try await strict.importFile(filename: "big.pdf", data: Data(count: 4_000_001)) }
        XCTAssertEqual(error?.userMessage, "\"big.pdf\" is over the 4 MB import limit — split it or trim it down.", "the sentence an older build said")
        let none = await paths(untouched)
        XCTAssertEqual(none, [], "an older server has no address to hand out, so none is asked for")
    }

    func testTheDefaultLimitsAreAnOlderServers() async {
        let (importer, transport) = setup(routes(), limits: Capabilities.Limits())
        let error = await failure { try await importer.importFile(filename: "big.pdf", data: Data(count: 5_000_000)) }
        XCTAssertEqual(error?.userMessage, "\"big.pdf\" is over the 4 MB import limit — split it or trim it down.")
        let none = await paths(transport)
        XCTAssertEqual(none, [])
    }

    func testAnotherLimitFromTheServerIsTheLimitThatIsUsed() async throws {
        let roomy = Capabilities.Limits(importFileBytes: 25_000_000, importInlineFileBytes: 1_000_000)
        let (importer, transport) = setup(routes(), limits: roomy)
        _ = try await importer.importFile(filename: "a.pdf", data: Data(count: 1_000_001))
        let staged = await paths(transport)
        XCTAssertEqual(staged.count, 3, "past the server's own inline limit it is staged, whatever the old number was")
        let (strict, _) = setup(routes(), limits: roomy)
        let error = await failure { try await strict.importFile(filename: "big.pdf", data: Data(count: 25_000_001)) }
        XCTAssertEqual(error?.userMessage, "\"big.pdf\" is over the 25 MB import limit — split it or trim it down.")
    }
}

/// Collects what a progress callback is told, from wherever it is told it.
private final class StageLog: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [MemoryFileImporter.Stage] = []

    func add(_ stage: MemoryFileImporter.Stage) {
        lock.lock()
        defer { lock.unlock() }
        seen.append(stage)
    }

    var stages: [MemoryFileImporter.Stage] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }
}

/// A network that answers everything as `inner` does except a PUT, which it fails to get an answer to.
private struct FailingPut: HTTPTransport {
    let inner: MockTransport
    let error: any Error

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        if request.httpMethod == "PUT" { throw error }
        return try await inner.send(request)
    }
}

final class SignedUploadTests: XCTestCase {
    func testTheRequestIsAPutWithATypeAndNothingElse() {
        let url = URL(string: "https://p.supabase.test/storage/v1/object/upload/sign/import-staging/u1/a.pdf?token=t")!
        let request = SignedUpload.request(to: url, contentType: "application/pdf", data: Data("%PDF".utf8))
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.url, url)
        XCTAssertEqual(request.allHTTPHeaderFields, ["Content-Type": "application/pdf"])
        XCTAssertEqual(request.httpBody, Data("%PDF".utf8))
        XCTAssertEqual(request.timeoutInterval, SignedUpload.defaultTimeout)
        XCTAssertGreaterThanOrEqual(SignedUpload.defaultTimeout, 120, "a big file on a slow connection")
    }

    func testPutReturnsTheAnswerWhateverItsStatus() async throws {
        let transport = MockTransport(routes: [MockRoute(.put, "/up") { _ in HTTPResponse(status: 403, data: Data("no".utf8)) }])
        let response = try await SignedUpload.put(Data("x".utf8), to: URL(string: "https://s.test/up")!, contentType: "text/plain", using: transport)
        XCTAssertEqual(response.status, 403)
        XCTAssertEqual(String(decoding: response.data, as: UTF8.self), "no")
    }

    func testOnlyAWebAddressWithAHostIsOneToSendAFileTo() {
        XCTAssertNotNil(SignedUpload.address(from: "https://p.supabase.co/storage/v1/object/upload/sign/b/p?token=t"))
        XCTAssertNotNil(SignedUpload.address(from: "http://localhost:54321/storage/x"))
        for bad in ["", "not a link", "ftp://p.supabase.co/x", "file:///etc/hosts", "/storage/x", "https://", "javascript:alert(1)"] {
            XCTAssertNil(SignedUpload.address(from: bad), bad)
        }
    }
}
