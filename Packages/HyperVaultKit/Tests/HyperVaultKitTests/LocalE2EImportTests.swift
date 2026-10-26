import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HyperVaultKit

// Import: a tiny ChatGPT export, a Claude export, a pasted transcript and an export inside a zip. The Kit reads each
// file itself (ImportInspector), plans the batches and sends them (ImportRunner); what the server then holds is
// compared with what the Kit said it would import.

final class LocalE2EImportTests: LocalE2ECase {

    // MARK: Fixtures

    private func chatGPTExport(_ word: String) -> String {
        """
        [
          {
            "title": "Trip planning \(word)",
            "create_time": 1760000000.0,
            "update_time": 1760000100.0,
            "current_node": "n3",
            "conversation_id": "conv-\(word)-1",
            "mapping": {
              "root": {"id": "root", "message": null, "parent": null, "children": ["n1"]},
              "n1": {"id": "n1", "parent": "root", "children": ["n2"], "message": {"id": "n1", "author": {"role": "user"}, "create_time": 1760000001.0, "content": {"content_type": "text", "parts": ["Where should we go in autumn? \(word)"]}}},
              "n2": {"id": "n2", "parent": "n1", "children": ["n3"], "message": {"id": "n2", "author": {"role": "assistant"}, "create_time": 1760000002.0, "content": {"content_type": "text", "parts": ["Lisbon is lovely in October."]}, "metadata": {"model_slug": "gpt-4o"}}},
              "n3": {"id": "n3", "parent": "n2", "children": [], "message": {"id": "n3", "author": {"role": "user"}, "create_time": 1760000003.0, "content": {"content_type": "text", "parts": ["And the food?"]}}}
            }
          },
          {
            "title": "Empty chat \(word)",
            "create_time": 1760000200.0,
            "current_node": "root2",
            "conversation_id": "conv-\(word)-2",
            "mapping": {"root2": {"id": "root2", "message": null, "parent": null, "children": []}}
          }
        ]
        """
    }

    private func claudeExport(_ word: String) -> String {
        """
        [
          {"uuid": "claude-\(word)-1", "name": "Recipe ideas \(word)", "created_at": "2026-09-01T10:00:00.000Z", "updated_at": "2026-09-01T10:05:00.000Z",
           "chat_messages": [
             {"uuid": "m1", "sender": "human", "text": "A recipe with lentils \(word)", "created_at": "2026-09-01T10:00:00.000Z"},
             {"uuid": "m2", "sender": "assistant", "text": "Try a dal with lemon.", "created_at": "2026-09-01T10:00:05.000Z"}
           ]}
        ]
        """
    }

    private func stored(zip entries: [(name: String, data: Data)]) -> Data {
        func crc32(_ data: Data) -> UInt32 {
            var table = [UInt32](repeating: 0, count: 256)
            for n in 0..<256 {
                var c = UInt32(n)
                for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
                table[n] = c
            }
            var crc: UInt32 = 0xFFFFFFFF
            for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
            return crc ^ 0xFFFFFFFF
        }
        func le16(_ v: UInt16) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8)]) }
        func le32(_ v: UInt32) -> Data { Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)]) }
        var out = Data()
        var central = Data()
        for entry in entries {
            let name = Data(entry.name.utf8)
            let crc = crc32(entry.data)
            let offset = UInt32(out.count)
            var local = Data()
            local += le32(0x04034b50) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0)
            local += le32(crc) + le32(UInt32(entry.data.count)) + le32(UInt32(entry.data.count))
            local += le16(UInt16(name.count)) + le16(0) + name + entry.data
            out += local
            var dir = Data()
            dir += le32(0x02014b50) + le16(20) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0)
            dir += le32(crc) + le32(UInt32(entry.data.count)) + le32(UInt32(entry.data.count))
            dir += le16(UInt16(name.count)) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0) + le32(offset) + name
            central += dir
        }
        let centralOffset = UInt32(out.count)
        out += central
        out += le32(0x06054b50) + le16(0) + le16(0) + le16(UInt16(entries.count)) + le16(UInt16(entries.count))
        out += le32(UInt32(central.count)) + le32(centralOffset) + le16(0)
        return out
    }

    // MARK: Journeys

    func testAChatGPTExportIsInspectedPlannedSentAndReadBack() async throws {
        let (api, _) = member(30)
        let word = uniqueWord()
        let document = ImportInspector.inspect(Data(chatGPTExport(word).utf8), name: "conversations.json")
        XCTAssertEqual(document.detected, .chatgpt)
        XCTAssertEqual(document.kind, .json)
        XCTAssertEqual(document.conversationCount, 2)
        XCTAssertEqual(document.sampleTitles.first, "Trip planning \(word)")
        XCTAssertTrue(document.isImportable)

        let plan = ImportPlan(documents: [document])
        XCTAssertEqual(plan.conversationTotal, 2)
        let client = api
        let totals = try await ImportRunner.run(plan: plan, send: { request in try await client.send(.importHistory(request)) })
        // One conversation has messages; the empty one is left out.
        XCTAssertEqual(totals.imported, 1)
        XCTAssertEqual(totals.skipped, 1)
        XCTAssertEqual(totals.messages, 3)
        XCTAssertEqual(totals.batches, 1)
        XCTAssertTrue(totals.summary(platform: .chatgpt, locale: Locale(identifier: "en_US")).contains("1 conversation (3 messages) from ChatGPT"), totals.summary(platform: .chatgpt))

        // It is a conversation now, in order, with the thread reconstructed from the tree.
        let list = try await send(.conversations, api)
        let imported = try XCTUnwrap(list.first { $0.title == "Trip planning \(word)" })
        XCTAssertEqual(imported.platform, .chatgpt)
        XCTAssertTrue(imported.platform.isImported)
        XCTAssertEqual(imported.visibility, .private)
        let detail = try await send(.conversation(id: imported.id), api)
        XCTAssertEqual(detail.messages.map(\.role), [.user, .assistant, .user])
        XCTAssertEqual(detail.messages.map(\.content), ["Where should we go in autumn? \(word)", "Lisbon is lovely in October.", "And the food?"])
        XCTAssertEqual(detail.messages.map(\.position), [0, 1, 2])
        XCTAssertEqual(detail.messages[1].model, "gpt-4o")
        XCTAssertNotNil(imported.createdAt)

        // Sending the same file again replaces rather than duplicates.
        let again = try await ImportRunner.run(plan: plan, send: { request in try await client.send(.importHistory(request)) })
        XCTAssertEqual(again.imported, 1)
        let after = try await send(.conversations, api)
        XCTAssertEqual(after.filter { $0.title == "Trip planning \(word)" }.count, 1, "an import twice made two conversations")

        // The second import replaced the conversation (it has a new id), and it is a conversation like any other.
        let replaced = try XCTUnwrap(after.first { $0.title == "Trip planning \(word)" })
        XCTAssertNotEqual(replaced.id, imported.id, "a re-import replaces the conversation it already has")
        await expectFailure(404, .conversation(id: imported.id), api)
        let shared = try await send(.setVisibility(conversationID: replaced.id, .shared), api)
        XCTAssertEqual(shared.conversation.visibility, .shared)
        _ = try await send(.deleteConversation(id: replaced.id), api)
    }

    func testAClaudeExportAndAPastedTranscript() async throws {
        let (api, _) = member(30)
        let word = uniqueWord()
        let claude = ImportInspector.inspect(Data(claudeExport(word).utf8), name: "conversations.json")
        XCTAssertEqual(claude.detected, .claude)
        XCTAssertEqual(claude.conversationCount, 1)
        let client = api
        let totals = try await ImportRunner.run(plan: ImportPlan(documents: [claude]), send: { request in try await client.send(.importHistory(request)) })
        XCTAssertEqual(totals.imported, 1)
        XCTAssertEqual(totals.messages, 2)
        let list = try await send(.conversations, api)
        let row = try XCTUnwrap(list.first { $0.title == "Recipe ideas \(word)" })
        XCTAssertEqual(row.platform, .claude)
        let detail = try await send(.conversation(id: row.id), api)
        XCTAssertEqual(detail.messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(detail.messages.first?.content, "A recipe with lentils \(word)")

        // A pasted transcript: "You:" / "Assistant:" lines become messages, the title is the person's own.
        let transcript = "You: What is a quokka \(word)?\nAssistant: A small marsupial from Western Australia.\nYou: Are they friendly?\nAssistant: Famously."
        let pasted = ImportInspector.inspect(text: transcript)
        XCTAssertEqual(pasted.kind, .transcript)
        XCTAssertEqual(pasted.conversationCount, 1)
        let plan = ImportPlan(documents: [pasted], title: "Quokkas \(word)")
        let pastedTotals = try await ImportRunner.run(plan: plan, send: { request in try await client.send(.importHistory(request)) })
        XCTAssertEqual(pastedTotals.imported, 1)
        XCTAssertEqual(pastedTotals.messages, 4)
        let after = try await send(.conversations, api)
        let quokkas = try XCTUnwrap(after.first { $0.title == "Quokkas \(word)" })
        let quokkaChat = try await send(.conversation(id: quokkas.id), api)
        XCTAssertEqual(quokkaChat.messages.count, 4)

        // Gemini and Grok shapes the Kit says it recognises are accepted by the server too.
        let grok = #"[{"conversation_id":"g-\#(word)","title":"Grok chat \#(word)","responses":[{"sender":"human","message":"hello grok"},{"sender":"grok","message":"hello human"}]}]"#
        let grokDoc = ImportInspector.inspect(Data(grok.utf8), name: "conversations.json", hint: .grok)
        XCTAssertEqual(grokDoc.conversationCount, 1, "detected: \(String(describing: grokDoc.detected))")
        let grokOutcome = try await send(.importHistory(ImportRequest(data: grokDoc.text(for: grokDoc.batches().first!), platform: .grok)), api)
        XCTAssertEqual(grokOutcome.platform, .grok)
        XCTAssertEqual(grokOutcome.imported, 1, "\(grokOutcome)")

        // The refusals: nothing to import, not an export, a body over the limit.
        await expectFailure(400, .importHistory(ImportRequest(data: "")), api)
        // A JSON object that is no export is not an error: the server counts it as one skipped conversation.
        let notAnExport = try await send(.importHistory(ImportRequest(data: "{\"not\": \"an export\"}", platform: .chatgpt)), api)
        XCTAssertEqual(notAnExport.imported, 0)
        XCTAssertEqual(notAnExport.skipped, 1)
        for cleanup in [row.id, quokkas.id] { _ = try await send(.deleteConversation(id: cleanup), api) }
    }

    func testAnExportInsideAZipIsFoundAndImported() async throws {
        let (api, _) = member(31)
        let word = uniqueWord()
        let archive = stored(zip: [
            (name: "export/", data: Data()),
            (name: "export/readme.txt", data: Data("not json".utf8)),
            (name: "export/conversations.json", data: Data(claudeExport(word).utf8)),
        ])
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("hv-e2e-\(word).zip")
        try archive.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let zip = try ImportZipArchive(fileURL: file)
        XCTAssertEqual(zip.entries.count, 3)
        XCTAssertEqual(zip.jsonEntries.map(\.lastComponent), ["conversations.json"])
        let entry = try XCTUnwrap(zip.jsonEntries.first)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("hv-e2e-\(word).json")
        defer { try? FileManager.default.removeItem(at: out) }
        try zip.extract(entry, to: out, inflater: nil)
        let document = ImportInspector.inspect(try Data(contentsOf: out), name: entry.lastComponent)
        XCTAssertEqual(document.detected, .claude)
        let client = api
        let totals = try await ImportRunner.run(plan: ImportPlan(documents: [document]), send: { request in try await client.send(.importHistory(request)) })
        XCTAssertEqual(totals.imported, 1)
        let list = try await send(.conversations, api)
        XCTAssertNotNil(list.first { $0.title == "Recipe ideas \(word)" })
    }

    func testABigHistoryGoesInBatchesAndAnOverlargeOneIsRetriedInHalves() async throws {
        let (api, _) = member(31)
        let word = uniqueWord()
        var conversations: [String] = []
        for index in 0..<7 {
            conversations.append(#"{"uuid":"c\#(index)-\#(word)","name":"Batch \#(index) \#(word)","created_at":"2026-09-01T10:00:00.000Z","chat_messages":[{"sender":"human","text":"question \#(index) \#(word)"},{"sender":"assistant","text":"answer \#(index)"}]}"#)
        }
        let document = ImportInspector.inspect(Data("[\(conversations.joined(separator: ","))]".utf8), name: "conversations.json")
        XCTAssertEqual(document.conversationCount, 7)
        // Three conversations to a batch makes three requests.
        let plan = ImportPlan(documents: [document], maxBatchBytes: ImportInspector.defaultBatchBytes, maxBatchConversations: 3)
        XCTAssertEqual(plan.items.count, 3)
        let client = api
        let counter = BatchCounter()
        let totals = try await ImportRunner.run(plan: plan, send: { request in
            counter.bump()
            return try await client.send(.importHistory(request))
        }, progress: { _ in })
        XCTAssertEqual(totals.imported, 7)
        XCTAssertEqual(totals.batches, 3)
        XCTAssertEqual(counter.value, 3)
        let list = try await send(.conversations, api)
        XCTAssertEqual(list.filter { $0.title.hasPrefix("Batch ") && $0.title.hasSuffix(word) }.count, 7)
    }
}

private final class BatchCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func bump() { lock.lock(); count += 1; lock.unlock() }
}
