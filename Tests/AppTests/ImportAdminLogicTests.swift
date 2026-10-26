import HyperVaultKit
import SwiftUI
import XCTest
@testable import HyperVault

private func fixtureZip() throws -> URL {
    let data = try XCTUnwrap(Data(base64Encoded: ImportZipFixture.base64))
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("hv-export-\(UUID().uuidString).zip")
    try data.write(to: url)
    return url
}

/// A real export zip made by Python's zipfile: a folder, two deflated JSON files,
/// a stored image and a macOS resource fork.
enum ImportZipFixture {
    static let base64 = "UEsDBBQAAAAAADIOWl0AAAAAAAAAAAAAAAAHAAAAZXhwb3J0L1BLAwQUAAAACAAAACEALFbcUXUAAADLAAAAGQAAAGV4cG9ydC9jb252ZXJzYXRpb25zLmpzb26LrlbKTFGyUlBKNlTSUVAqySzJSQVxPVJzcvJBIrmJBQWZeelAsWqlRDAJUZ8IlkwtLk5MB2nIK83JAQoUJBal5pUg+MkZmTkpQCGgSHRsbS1IpLQIpCQ+Lz8lFWIOUBTuCCMURwSnJufnpaC5AoshIMtqYwFQSwMEFAAAAAgAAAAhAE3rQtEdAAAAHgAAABAAAABleHBvcnQvdXNlci5qc29uq1bKTFGyUlAqVdJRUErNTczMAfESHZL0kvOVagFQSwMEFAAAAAAAAAAhAGVKBAwwAAAAMAAAABcAAABleHBvcnQvaW1hZ2VzL3Bob3RvLnBuZ4lQTkcNChoKMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMFBLAwQUAAAAAAAAACEAOZz7BgQAAAAEAAAAJAAAAF9fTUFDT1NYL2V4cG9ydC8uX2NvbnZlcnNhdGlvbnMuanNvbmp1bmtQSwECFAMUAAAAAAAyDlpdAAAAAAAAAAAAAAAABwAAAAAAAAAAABAA/UEAAAAAZXhwb3J0L1BLAQIUAxQAAAAIAAAAIQAsVtxRdQAAAMsAAAAZAAAAAAAAAAAAAACAASUAAABleHBvcnQvY29udmVyc2F0aW9ucy5qc29uUEsBAhQDFAAAAAgAAAAhAE3rQtEdAAAAHgAAABAAAAAAAAAAAAAAAIAB0QAAAGV4cG9ydC91c2VyLmpzb25QSwECFAMUAAAAAAAAACEAZUoEDDAAAAAwAAAAFwAAAAAAAAAAAAAAgAEcAQAAZXhwb3J0L2ltYWdlcy9waG90by5wbmdQSwECFAMUAAAAAAAAACEAOZz7BgQAAAAEAAAAJAAAAAAAAAAAAAAAgAGBAQAAX19NQUNPU1gvZXhwb3J0Ly5fY29udmVyc2F0aW9ucy5qc29uUEsFBgAAAAAFAAUAUQEAAMcBAAAAAA=="

    /// What `export/conversations.json` holds once inflated.
    static let conversations = #"[{"id": "c1", "title": "Hello", "mapping": {"a": {"id": "a", "message": null, "parent": null, "children": []}}, "current_node": "a"}, {"id": "c2", "title": "Second", "mapping": {}, "current_node": null}]"#
}

final class ImportZipInflaterTests: XCTestCase {
    func testInflatesWhatAZipStoresWithTheSystemFramework() throws {
        let archive = try ImportZipArchive(fileURL: fixtureZip())
        let entry = try XCTUnwrap(archive.entries.first { $0.name == "export/conversations.json" })
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("hv-inflate-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: out) }
        try archive.extract(entry, to: out, inflater: ImportZipInflater())
        XCTAssertEqual(String(decoding: try Data(contentsOf: out), as: UTF8.self), ImportZipFixture.conversations)
        XCTAssertEqual(UInt64(try Data(contentsOf: out).count), entry.uncompressedSize)
    }

    func testReadingAZipFindsTheConversationsAndSkipsTheRest() async throws {
        let result = try await ImportFileReader.read([fixtureZip()], chosen: .chatgpt)
        defer { ImportFileReader.remove(result.temporaryFiles) }
        XCTAssertEqual(result.documents.count, 1, "user.json holds no conversations")
        let document = try XCTUnwrap(result.documents.first)
        XCTAssertEqual(document.detected, .chatgpt)
        XCTAssertEqual(document.conversationCount, 2)
        XCTAssertEqual(document.sampleTitles, ["Hello", "Second"])
        XCTAssertEqual(result.notes.count, 1)
        XCTAssertTrue(result.notes[0].contains("2 JSON files"), result.notes[0])
        XCTAssertTrue(result.notes[0].hasSuffix("and used 1.") || result.notes[0].contains("and used 1."), result.notes[0])
    }

    func testTheCopyOfAZipGoesOnceItsConversationsAreOut() async throws {
        let zip = try fixtureZip()
        defer { try? FileManager.default.removeItem(at: zip) }
        let result = try await ImportFileReader.read([zip], chosen: .chatgpt)
        defer { ImportFileReader.remove(result.temporaryFiles) }
        XCTAssertEqual(result.documents.count, 1)
        let names = try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
        let leftCopies = names.filter { $0.hasPrefix(ImportFileReader.temporaryPrefix) && $0.hasSuffix(zip.lastPathComponent) }
        XCTAssertEqual(leftCopies, [], "the whole export is not kept while the person reads the review")
        XCTAssertEqual(result.temporaryFiles.count, 1, "only the extracted conversations are kept, for the documents that read them")
    }

    func testAPlainJSONFileIsReadAsItIs() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("conversations-\(UUID().uuidString).json")
        try Data(ImportZipFixture.conversations.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try await ImportFileReader.read([url], chosen: nil)
        defer { ImportFileReader.remove(result.temporaryFiles) }
        XCTAssertEqual(result.documents.first?.conversationCount, 2)
        XCTAssertTrue(result.notes.isEmpty)
    }

    func testSeveralFilesOfTheSameServiceAreAllKept() async throws {
        let a = FileManager.default.temporaryDirectory.appendingPathComponent("a-\(UUID().uuidString).json")
        let b = FileManager.default.temporaryDirectory.appendingPathComponent("b-\(UUID().uuidString).json")
        try Data(ImportFixtures.chatgpt(count: 3).utf8).write(to: a)
        try Data(ImportFixtures.chatgpt(count: 4).utf8).write(to: b)
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        let result = try await ImportFileReader.read([a, b], chosen: .chatgpt)
        defer { ImportFileReader.remove(result.temporaryFiles) }
        XCTAssertEqual(result.documents.map(\.conversationCount), [3, 4])
    }

    func testAFileOfAnotherKindDoesNotMixIn() {
        var notes: [String] = []
        let chat = ImportInspector.inspect(Data(ImportFixtures.chatgpt(count: 5).utf8), name: "conversations.json")
        let grok = ImportInspector.inspect(Data(#"[{"conversation_id":"g","responses":[]}]"#.utf8), name: "grok.json")
        let kept = ImportFileReader.keepTheMainService([grok, chat], notes: &notes)
        XCTAssertEqual(kept.map(\.name), ["conversations.json"])
        XCTAssertEqual(notes, ["Found more than one kind of history; importing the ChatGPT one."])
    }
}

@MainActor
final class ImportModelTests: XCTestCase {
    private func model(_ routes: [MockRoute], announcer: SpeechAnnouncer? = nil) -> ImportModel {
        model(transport: MockTransport(routes: routes), announcer: announcer)
    }

    private func model(transport: HTTPTransport, announcer: SpeechAnnouncer? = nil) -> ImportModel {
        let client = HVClient(baseURL: URL(string: "https://t.test")!, transport: transport, tokens: StaticTokenProvider(), retry: .none, sleep: { _ in })
        return ImportModel(client: client, importBytes: 50_000_000, announcer: announcer ?? RecordingAnnouncer())
    }

    private func history(_ count: Int) -> ImportDocument {
        ImportInspector.inspect(Data(ImportFixtures.chatgpt(count: count).utf8), name: "conversations.json", hint: .chatgpt)
    }

    /// What the app made in the temporary folder for the file with this token in its name.
    private func copies(of token: String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? []
        return names.filter { $0.hasPrefix(ImportFileReader.temporaryPrefix) && $0.contains(token) }
    }

    private func write(_ text: String, token: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(token).json")
        try Data(text.utf8).write(to: url)
        return url
    }

    private func settle(_ model: ImportModel, until done: (ImportModel.Stage) -> Bool) async {
        for _ in 0..<60 where !done(model.stage) { try? await Task.sleep(nanoseconds: 100_000_000) }
    }

    func testPastingAConversationAndSendingIt() async {
        let model = model([.json(.post, "/api/import", #"{"platform":"other","imported":1,"skipped":0,"messages":2,"message":"Imported 1 conversation (2 messages) from other."}"#)])
        model.source = .other
        model.pasted = "User: hi\nAssistant: hello"
        model.readPasted()
        XCTAssertEqual(model.stage, .review)
        XCTAssertEqual(model.conversationCount, 1)
        XCTAssertTrue(model.isPaste)
        model.start()
        await settle(model) { $0 == .done }
        XCTAssertEqual(model.stage, .done)
        XCTAssertEqual(model.totals.imported, 1)
        XCTAssertEqual(model.totals.messages, 2)
    }

    func testNothingToImportSaysSoInTheServersWords() {
        let model = model([])
        model.source = .other
        model.pasted = "just words, no speaker labels"
        model.readPasted()
        XCTAssertEqual(model.stage, .review)
        XCTAssertNil(model.plan)
        XCTAssertEqual(model.readError, ImportInspector.nothingFoundMessage)
    }

    func testAFailureStopsAndContinueFinishesTheJob() async {
        let calls = Tally()
        let route = MockRoute(.post, "/api/import") { _ in
            // The second of three parts fails once.
            let n = calls.hit()
            if n == 2 { return HTTPResponse(status: 500, data: Data(#"{"error":"The server had a problem. Try again in a moment."}"#.utf8)) }
            return HTTPResponse(status: 200, data: Data(#"{"platform":"chatgpt","imported":50,"skipped":0,"messages":200,"message":"ok"}"#.utf8))
        }
        let model = model([route])
        let document = ImportInspector.inspect(Data(ImportFixtures.chatgpt(count: 120).utf8), name: "conversations.json", hint: .chatgpt)
        model.previewSeedDocuments([document])
        XCTAssertEqual(model.partCount, 3)
        model.start()
        await settle(model) { if case .stopped = $0 { return true } else { return false } }
        XCTAssertEqual(model.stage, .stopped("The server had a problem. Try again in a moment."))
        XCTAssertEqual(model.totals.imported, 50)
        model.resume()
        await settle(model) { $0 == .done }
        XCTAssertEqual(model.stage, .done)
        XCTAssertEqual(model.totals.imported, 150, "the failed part was sent again, and counted once")
    }

    // MARK: Leaving, stopping and the screen's sleep

    func testTheScreenStaysAwakeOnlyWhileSendingAndSaysWhenTheImportEnds() async {
        let speech = RecordingAnnouncer()
        let model = model([.json(.post, "/api/import", #"{"platform":"other","imported":1,"skipped":0,"messages":2,"message":"ok"}"#)], announcer: speech)
        model.source = .other
        model.pasted = "User: hi\nAssistant: hello"
        model.readPasted()
        XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled)
        model.start()
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled, "kept awake while it sends")
        await settle(model) { $0 == .done }
        XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled)
        XCTAssertEqual(ImportAwake.holds, 0)
        XCTAssertEqual(speech.spoken.first, "Importing 1 conversation. Keep HyperVault open.")
        XCTAssertEqual(speech.spoken.last?.hasPrefix("Import finished. Imported 1 conversation (2 messages)"), true, "\(speech.spoken)")
    }

    func testAFailureGivesTheScreenItsSleepBackAndSaysSo() async {
        let speech = RecordingAnnouncer()
        let model = model([.failure(.post, "/api/import", status: 500, message: "The server had a problem. Try again in a moment.")], announcer: speech)
        model.previewSeedDocuments([history(3)])
        model.start()
        await settle(model) { if case .stopped = $0 { return true } else { return false } }
        XCTAssertEqual(model.stage, .stopped("The server had a problem. Try again in a moment."))
        XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled)
        XCTAssertEqual(speech.spoken.last, "The import stopped. The server had a problem. Try again in a moment. 0 of 3 conversations are in. You can continue it.")
    }

    func testStoppingGivesTheScreenItsSleepBackAndSaysSo() async {
        let speech = RecordingAnnouncer()
        let model = model(transport: ImportHangingTransport(), announcer: speech)
        model.previewSeedDocuments([history(3)])
        model.start()
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled)
        model.stop()
        await settle(model) { if case .stopped = $0 { return true } else { return false } }
        XCTAssertEqual(model.stage, .stopped("You stopped the import."))
        XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled)
        XCTAssertEqual(ImportAwake.holds, 0)
        XCTAssertEqual(speech.spoken.last, "Import stopped. 0 of 3 conversations are in. You can continue it.")
    }

    func testLeavingTheScreenMidImportCancelsTheRunAndGivesTheScreenItsSleepBack() async {
        let hanging = ImportHangingTransport()
        var model: ImportModel? = model(transport: hanging)
        model?.previewSeedDocuments([history(3)])
        model?.start()
        for _ in 0..<200 where hanging.started == 0 { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(hanging.started, 1, "a request is on its way")
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled)

        // The screen is popped: nothing else holds the model.
        weak var gone = model
        model = nil
        XCTAssertNil(gone)

        for _ in 0..<200 where UIApplication.shared.isIdleTimerDisabled { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled, "the run ended with nobody to tell, and still gave the sleep back")
        XCTAssertEqual(ImportAwake.holds, 0)
        XCTAssertEqual(hanging.cancelled, 1, "the request in flight was cancelled, not left to finish unseen")
    }

    func testLeavingTheScreenRemovesTheCopyOfTheExport() async throws {
        let token = UUID().uuidString
        let source = try write(ImportFixtures.chatgpt(count: 3), token: token)
        defer { try? FileManager.default.removeItem(at: source) }
        var model: ImportModel? = model([])
        model?.read([source])
        for _ in 0..<200 where model?.stage != .review { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(model?.stage, .review)
        XCTAssertEqual(copies(of: token).count, 1, "the copy lives while the review is on screen")
        try? await Task.sleep(nanoseconds: 50_000_000)

        model = nil
        XCTAssertEqual(copies(of: token), [])
    }

    func testAFileWithNothingToImportIsNotKept() async throws {
        let token = UUID().uuidString
        let source = try write(#"{"user":{"userId":"u"},"sessions":[]}"#, token: token)
        defer { try? FileManager.default.removeItem(at: source) }
        let model = model([])
        model.read([source])
        await settle(model) { $0 == .review }
        XCTAssertEqual(model.stage, .review)
        XCTAssertNil(model.plan)
        XCTAssertEqual(copies(of: token), [], "nothing will be sent, so the copy goes at once")
    }

    func testStartingOverRemovesTheCopyToo() async throws {
        let token = UUID().uuidString
        let source = try write(ImportFixtures.chatgpt(count: 3), token: token)
        defer { try? FileManager.default.removeItem(at: source) }
        let model = model([])
        model.read([source])
        await settle(model) { $0 == .review }
        XCTAssertEqual(copies(of: token).count, 1)
        model.backToChoose()
        XCTAssertEqual(copies(of: token), [])
    }
}

/// Never answers; says when a request arrived and when one was cancelled, as URLSession does.
private final class ImportHangingTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var arrived = 0
    private var cancellations = 0

    var started: Int { lock.lock(); defer { lock.unlock() }; return arrived }
    var cancelled: Int { lock.lock(); defer { lock.unlock() }; return cancellations }

    private func count(arrival: Bool) {
        lock.lock()
        if arrival { arrived += 1 } else { cancellations += 1 }
        lock.unlock()
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        count(arrival: true)
        do {
            try await Task.sleep(nanoseconds: 60_000_000_000)
        } catch {
            count(arrival: false)
            throw error
        }
        return HTTPResponse(status: 200)
    }
}

/// A counter that closures on any thread may bump.
private final class Tally: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    @discardableResult
    func hit() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }
}

@MainActor
final class AdminLogicTests: XCTestCase {
    private func environment(_ transport: MockTransport) -> AppEnvironment {
        let server = ServerConfig(baseURL: URL(string: "https://t.test")!)
        let client = HVClient(baseURL: server.baseURL, transport: transport, tokens: StaticTokenProvider(), retry: .none, sleep: { _ in })
        let auth = AuthService(
            config: SupabaseConfig(url: URL(string: "https://s.test")!, anonKey: "k"),
            transport: transport, store: InMemorySecureStore()
        )
        let cache = DiskCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("hv-admin-\(UUID().uuidString)"))
        return AppEnvironment(
            client: client, auth: auth, capabilities: Capabilities(),
            user: AuthUser(id: "u1", email: "owner@example.com", displayName: nil), server: server, cache: cache
        )
    }

    func testAnAdminIsRecognisedWithoutWritingAnything() async {
        let transport = MockTransport(routes: [.failure(.patch, "/api/admin/invites/*", status: 400, message: "Pass { disabled: boolean }.")])
        let env = environment(transport)
        XCTAssertFalse(env.isAdmin)
        await env.probeAdmin()
        XCTAssertTrue(env.isAdmin)
        let sent = await transport.requests
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0].httpMethod, "PATCH")
        XCTAssertEqual(String(decoding: sent[0].httpBody ?? Data(), as: UTF8.self), "{}")

        // Asked again at once, it answers from memory.
        await env.probeAdmin()
        let after = await transport.requests
        XCTAssertEqual(after.count, 1)
    }

    func testSomeoneElseIsNotAnAdminAndNothingIsShown() async {
        let transport = MockTransport(routes: [.failure(.patch, "/api/admin/invites/*", status: 403, message: "Admin access required.")])
        let env = environment(transport)
        await env.probeAdmin()
        XCTAssertFalse(env.isAdmin)
        await env.probeAdmin()
        let sent = await transport.requests
        XCTAssertEqual(sent.count, 1, "a clear answer is kept for hours")
    }

    func testAnUnclearAnswerChangesNothingAndIsNotRepeatedAtOnce() async {
        let transport = MockTransport(routes: [.failure(.patch, "/api/admin/invites/*", status: 500, message: "Boom.")])
        let env = environment(transport)
        await env.probeAdmin()
        await env.probeAdmin()
        XCTAssertFalse(env.isAdmin)
        let sent = await transport.requests
        XCTAssertEqual(sent.count, 1)
    }

    func testMintingACodeKeepsItInTheListAndSurvivesARestart() async throws {
        let transport = MockTransport(routes: [.json(.post, "/api/admin/invites", #"{"invite":{"id":"i9","code":"HV-ABCD-EFGH","note":"Beta","max_uses":3,"use_count":0,"disabled":false,"created_at":"2026-10-24T01:02:03.000Z"}}"#)])
        let env = environment(transport)
        let model = AdminModel(client: env.client, cache: env.cache, namespace: env.user.id)
        model.usesText = "3"
        model.note = "Beta"
        await model.mint()
        XCTAssertEqual(model.justMinted?.code, "HV-ABCD-EFGH")
        XCTAssertEqual(model.book.invites.map(\.id), ["i9"])
        XCTAssertEqual(model.usesText, "1", "the form is ready for the next one")

        try await Task.sleep(nanoseconds: 300_000_000)
        let again = AdminModel(client: env.client, cache: env.cache, namespace: env.user.id)
        await again.load()
        XCTAssertEqual(again.book.invites.first?.code, "HV-ABCD-EFGH")
    }

    func testDestroyingAndTurningOffUpdateTheList() async {
        let transport = MockTransport(routes: [
            .json(.patch, "/api/admin/invites/i3", #"{"invite":{"id":"i3","code":"HV-K7QM-2XPA","max_uses":25,"use_count":11,"disabled":true}}"#),
            .json(.delete, "/api/admin/invites/i2", #"{"ok":true}"#),
        ])
        let env = environment(transport)
        let model = AdminModel(client: env.client, cache: env.cache, namespace: env.user.id)
        model.previewSeed()
        await model.setDisabled(true, inviteID: "i3")
        XCTAssertEqual(model.invite(id: "i3")?.disabled, true)
        XCTAssertEqual(model.invite(id: "i3")?.useCount, 11, "the answer carries the current count")
        let gone = await model.destroy(inviteID: "i2")
        XCTAssertTrue(gone)
        XCTAssertNil(model.invite(id: "i2"))
    }

    func testTheAccountToolsKnowTheirOwnAccount() {
        let env = environment(MockTransport())
        let model = AdminAccountModel(client: env.client, ownID: "3F1C1A2E-0000-4000-8000-000000000001")
        model.idText = "  3f1c1a2e-0000-4000-8000-000000000001 "
        XCTAssertTrue(model.isSelf)
        model.idText = "3f1c1a2e-0000-4000-8000-000000000002"
        XCTAssertFalse(model.isSelf)
        XCTAssertEqual(model.shortID, "3f1c1a2e…")
        model.idText = "not an id"
        XCTAssertNil(model.accountID)
    }

    func testDeletingAnAccountIsReportedAndForgotten() async {
        let transport = MockTransport(routes: [.json(.delete, "/api/admin/accounts/*", #"{"ok":true}"#)])
        let env = environment(transport)
        let model = AdminAccountModel(client: env.client, ownID: "u1")
        model.idText = "3f1c1a2e-0000-4000-8000-000000000002"
        let deleted = await model.deleteAccount()
        XCTAssertTrue(deleted)
        XCTAssertEqual(model.idText, "")
        XCTAssertEqual(model.log, ["Deleted the account 3f1c1a2e…."])
        let sent = await transport.requests
        XCTAssertEqual(sent.first?.url?.path, "/api/admin/accounts/3f1c1a2e-0000-4000-8000-000000000002")
    }
}
