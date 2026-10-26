import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HyperVaultKit

/// Holds a value a mock route and the test both touch.
final class TestBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

func requestJSON(_ request: URLRequest?) -> JSONValue? {
    guard let data = request?.httpBody else { return nil }
    return try? JSONDecoder().decode(JSONValue.self, from: data)
}

/// Fixtures follow the routes' real output (app/api/chat/route.ts and friends).
final class ChatTests: XCTestCase {
    let base = URL(string: "https://hv.test")!

    func client(_ transport: MockTransport) -> HVClient {
        HVClient(baseURL: base, transport: transport, tokens: StaticTokenProvider(), retry: .none, sleep: { _ in })
    }

    // MARK: conversations (app/api/conversations/route.ts)

    func testConversationsDecodeAndFallBackWhenSharingColumnsAreMissing() async throws {
        let transport = MockTransport(routes: [.json(.get, "/api/conversations", """
        {"conversations":[
          {"id":"c1","title":"Trip to Lisbon","source_platform":"hypervault","model":"claude-opus-4-8","created_at":"2026-10-20T10:00:00.123456+00:00","updated_at":"2026-10-24T08:30:00.000Z","visibility":"shared","share_slug":"trip-to-lisbon-a1b2"},
          {"id":"c2","title":"Old ChatGPT thread","source_platform":"chatgpt","model":null,"created_at":"2025-01-02T03:04:05.000Z","updated_at":"2025-01-02T03:04:05.000Z"},
          {"id":"c3","title":"Odd","source_platform":"zork","updated_at":"2025-01-02T03:04:05Z","visibility":"surprise"}
        ]}
        """)])
        let list = try await client(transport).send(.conversations)
        XCTAssertEqual(list.map(\.id), ["c1", "c2", "c3"])
        XCTAssertEqual(list[0].visibility, .shared)
        XCTAssertEqual(list[0].sharePath, "/c/trip-to-lisbon-a1b2")
        XCTAssertEqual(list[0].platform, .hypervault)
        XCTAssertFalse(list[0].platform.isImported)
        XCTAssertNotNil(list[0].updatedAt)
        // A database from before sharing sends neither column: private, no link.
        XCTAssertEqual(list[1].visibility, .private)
        XCTAssertNil(list[1].sharePath)
        XCTAssertEqual(list[1].platform.label, "ChatGPT")
        XCTAssertTrue(list[1].platform.isImported)
        // Unknown values degrade instead of failing the list.
        XCTAssertEqual(list[2].visibility, .private)
        XCTAssertEqual(list[2].platform.label, "Imported")
    }

    func testConversationDetailHydratesLikeTheWeb() async throws {
        let toolResult = """
        ```tool-result
        {"intent":"list tasks","tool":"tasks.list","ok":true,"confidence":0.912,"tier":"high","content":"3 open tasks"}
        ```
        """
        let toolRequest = "Let me check.\n\n```tool\n{\"intent\":\"list tasks\",\"args\":{}}\n```"
        let silentRequest = "```tool\n{\"intent\":\"list tasks\",\"args\":{}}\n```"
        func message(_ id: String, _ role: String, _ content: String, position: Int, feedback: JSONValue = .null) -> JSONValue {
            ["id": .string(id), "role": .string(role), "content": .string(content), "attachments": [], "model": "m",
             "position": .int(position), "created_at": "2026-10-20T10:00:00Z", "feedback": feedback]
        }
        let body: JSONValue = [
            "conversation": ["id": "c1", "title": "Plan", "source_platform": "hypervault", "model": "m",
                             "created_at": "2026-10-20T10:00:00Z", "updated_at": "2026-10-20T10:05:00Z",
                             "visibility": "private", "share_slug": .null],
            "messages": [
                message("m0", "user", "what is on my list?", position: 0),
                message("m1", "assistant", toolRequest, position: 1),
                message("m2", "tool", toolResult, position: 2),
                message("m3", "assistant", silentRequest, position: 3),
                message("m4", "assistant", "<think>they want tasks</think>You have 3 open tasks.", position: 4, feedback: 1),
                message("m5", "user", "thanks", position: 5),
                message("m6", "assistant", "Anytime.", position: 6, feedback: -1),
                message("m7", "system", "internal", position: 7),
            ],
        ]
        let transport = MockTransport(routes: [.json(.get, "/api/conversations/c1", body.jsonString())])
        let detail = try await client(transport).send(.conversation(id: "c1"))
        XCTAssertEqual(detail.messages.count, 8)
        XCTAssertEqual(detail.messages[4].feedback, .up)
        XCTAssertEqual(detail.messages[6].feedback, .down)

        let rows = ChatThreadRow.hydrate(detail.messages)
        // The tool request keeps its words, the silent request goes, the system row goes.
        XCTAssertEqual(rows.map(\.id), ["m0", "m1", "m2", "m4", "m5", "m6"])
        XCTAssertEqual(rows[1].text, "Let me check.")
        XCTAssertEqual(rows[2].kind, .tool)
        XCTAssertEqual(rows[2].toolTurn?.tool, "tasks.list")
        XCTAssertEqual(rows[2].toolTurn?.preview, "3 open tasks")
        XCTAssertEqual(rows[2].toolTurn?.tierLabel, "high 91%")
        XCTAssertEqual(rows[3].text, "You have 3 open tasks.")
        XCTAssertEqual(rows[3].feedback, .up)
        XCTAssertEqual(rows[3].serverID, "m4")
    }

    func testMissingConversationIsTheServersSentence() async {
        let transport = MockTransport(routes: [.failure(.get, "/api/conversations/nope", status: 404, message: "Conversation not found.")])
        do {
            _ = try await client(transport).send(.conversation(id: "nope"))
            XCTFail("expected 404")
        } catch let error as HVError {
            XCTAssertTrue(error.isNotFound)
            XCTAssertEqual(error.userMessage, "Conversation not found.")
        } catch { XCTFail("\(error)") }
    }

    func testVisibilityChangeAndDelete() async throws {
        let transport = MockTransport(routes: [
            .json(.patch, "/api/conversations/c1", """
            {"conversation":{"id":"c1","title":"Plan","source_platform":"hypervault","model":null,"created_at":"2026-10-20T10:00:00Z","updated_at":"2026-10-20T10:05:00Z","visibility":"shared","share_slug":"plan-x9"},
             "share_url":"/c/plan-x9","message":"Anyone with the link can now read this chat."}
            """),
            .json(.delete, "/api/conversations/c1", #"{"message":"Conversation deleted."}"#),
        ])
        let api = client(transport)
        let change = try await api.send(.setVisibility(conversationID: "c1", .shared))
        XCTAssertEqual(change.conversation.visibility, .shared)
        XCTAssertEqual(change.shareUrl, "/c/plan-x9")
        XCTAssertEqual(change.message, "Anyone with the link can now read this chat.")
        let sent = await transport.requests(matching: "/api/conversations/c1")
        XCTAssertEqual(requestJSON(sent.first), ["visibility": "shared"])

        _ = try await api.send(.deleteConversation(id: "c1"))
        let all = await transport.requests
        XCTAssertEqual(all.last?.httpMethod, "DELETE")
    }

    // MARK: POST /api/chat (app/api/chat/route.ts)

    static let turnJSON = """
    {"conversation_id":"c9","reply":{"id":"m12","role":"assistant","content":"<think>plan</think>Here is the plan.\\n\\n- one\\n- two","model":"claude-opus-4-8","truncated":false},
     "backend":{"id":"b1","name":"Claude","provider":"anthropic"},
     "recalled":[{"title":"Trip notes","slug":"trip-notes-ab12"}],
     "recalled_memories":["Co-parenting schedule","Passport numbers"],
     "pulled":[{"kind":"memory","id":"mem1","title":"Plans"}],
     "recall_branch":"main","smart_context":true,"deep_memory":["Lisbon, March"],
     "truth":{"cited":2,"contested":1,"flags":0,"drafted":1,"ledgers":["default"]},
     "tools":{"status":"ok","toolkit_id":"t1","turns":[{"intent":"list tasks","tool":"tasks.list","ok":true,"confidence":0.91,"tier":"high","preview":"3 tasks"},{"intent":"send mail","tool":null,"ok":false,"error":"Mail is not connected."}],
              "embedder":{"label":"onnx-minilm","lexical":false,"upgrade_available":false,"onnx_error":null}},
     "tool_selection":null}
    """

    func testChatTurnDecodes() async throws {
        let transport = MockTransport(routes: [.json(.post, "/api/chat", Self.turnJSON)])
        let turn = try await client(transport).send(.chat(backendID: "b1", message: "plan it", conversationID: nil))
        XCTAssertEqual(turn.conversationID, "c9")
        XCTAssertEqual(turn.reply.id, "m12")
        XCTAssertEqual(turn.reply.text, "Here is the plan.\n\n- one\n- two")
        XCTAssertEqual(turn.backend?.name, "Claude")
        XCTAssertEqual(turn.recalled, [ChatRecalledPage(title: "Trip notes", slug: "trip-notes-ab12")])
        XCTAssertEqual(turn.recalledMemories, ["Co-parenting schedule", "Passport numbers"])
        XCTAssertEqual(turn.pulled, [ChatPulledUse(kind: .memory, id: "mem1", title: "Plans")])
        XCTAssertEqual(turn.deepMemory, ["Lisbon, March"])
        XCTAssertEqual(turn.truth?.footnote, "Cited 2 ledger entries, 1 contested, 1 draft staged")
        XCTAssertEqual(turn.tools.status, .ok)
        XCTAssertEqual(turn.tools.turns.count, 2)
        XCTAssertEqual(turn.tools.turns[0].summary, "\u{201C}list tasks\u{201D} \u{2192} tasks.list")
        XCTAssertFalse(turn.tools.turns[1].ok)
        XCTAssertEqual(turn.tools.turns[1].detail, "Mail is not connected.")
        XCTAssertNil(turn.toolSelection)
        XCTAssertFalse(turn.grounding.isEmpty)

        let rows = ChatThreadRow.rows(for: turn)
        XCTAssertEqual(rows.map(\.kind), [.tool, .tool, .assistant])
        XCTAssertEqual(rows[2].serverID, "m12")
        XCTAssertEqual(rows[2].grounding.memories.count, 2)
    }

    func testChatSendsWhatTheRouteReads() async throws {
        let transport = MockTransport(routes: [.json(.post, "/api/chat", Self.turnJSON)])
        var options = ChatSendOptions(smartContext: true, deepMemory: false, truth: true, tools: false)
        options.pulled = [ChatPulledRef(kind: .page, id: "a1"), ChatPulledRef(kind: .key, id: "k1")]
        options.recallBranch = "work"
        _ = try await client(transport).send(.chat(backendID: "b1", message: "hello", conversationID: "c9", options: options))
        let body = requestJSON(await transport.requests(matching: "/api/chat").first)
        XCTAssertEqual(body?["backend_id"], "b1")
        XCTAssertEqual(body?["message"], "hello")
        XCTAssertEqual(body?["conversation_id"], "c9")
        XCTAssertEqual(body?["use_recall"], true)
        XCTAssertEqual(body?["recall_branch"], "work")
        XCTAssertEqual(body?["use_smart_context"], true)
        XCTAssertEqual(body?["use_deep_memory"], false)
        XCTAssertEqual(body?["use_truth"], true)
        XCTAssertEqual(body?["use_tools"], false)
        XCTAssertEqual(body?["pulled"], [["kind": "page", "id": "a1"], ["kind": "key", "id": "k1"]])
        let request = await transport.requests(matching: "/api/chat").first
        XCTAssertEqual(request?.timeoutInterval, chatTurnTimeout)
    }

    func testNewConversationOmitsTheIDAndRecallOffDropsTheBranch() async throws {
        let transport = MockTransport(routes: [.json(.post, "/api/chat", Self.turnJSON)])
        let options = ChatSendOptions(useRecall: false, recallBranch: "work")
        _ = try await client(transport).send(.chat(backendID: "b1", message: "hi", options: options))
        let body = requestJSON(await transport.requests(matching: "/api/chat").first)
        XCTAssertNil(body?["conversation_id"])
        XCTAssertEqual(body?["use_recall"], false)
        XCTAssertNil(body?["recall_branch"])
        XCTAssertNil(body?["use_tools"])
    }

    func testToolSelectionKeepsArgumentKeysAndRoundTripsAsAToolChoice() async throws {
        let json = """
        {"conversation_id":"c9","reply":{"id":"m3","role":"assistant","content":"I couldn't run that automatically.\\n1. Tasks: List Tasks","model":"m","truncated":true},
         "tools":{"status":"ok","toolkit_id":"t1","turns":[],"embedder":null},
         "tool_selection":{"intent":"list all tasks","question":"Pick one:","options":[{"label":"Tasks: List Tasks","canonical":"p1.list_tasks","args":{"max_results":5,"due_before":"2026-11-01"}}]}}
        """
        let transport = MockTransport(routes: [.json(.post, "/api/chat", json)])
        let api = client(transport)
        let turn = try await api.send(.chat(backendID: "b1", message: "list tasks"))
        XCTAssertTrue(turn.reply.truncated)
        let selection = try XCTUnwrap(turn.toolSelection)
        XCTAssertEqual(selection.options[0].args["max_results"], 5)
        XCTAssertEqual(selection.options[0].args["due_before"], "2026-11-01")

        var options = ChatSendOptions()
        options.toolChoice = ChatToolChoice(option: selection.options[0], intent: selection.intent)
        _ = try await api.send(.chat(backendID: "b1", message: "Use \u{201C}Tasks: List Tasks\u{201D}.", conversationID: "c9", options: options))
        let sent = requestJSON(await transport.requests(matching: "/api/chat").last)
        XCTAssertEqual(sent?["tool_choice"]?["canonical"], "p1.list_tasks")
        XCTAssertEqual(sent?["tool_choice"]?["intent"], "list all tasks")
        XCTAssertEqual(sent?["tool_choice"]?["args"]?["max_results"], 5)
    }

    func testStaleToolsExplainThemselves() throws {
        let json = #"{"status":"stale","toolkit_id":null,"turns":[],"embedder":{"label":"x","lexical":true,"upgrade_available":true,"detail":"Your toolkit was compiled with a different embedding setup. Recompile it under Tools."}}"#
        let report = try HVCoding.decoder(.verbatim).decode(ChatToolsReport.self, from: Data(json.utf8))
        XCTAssertEqual(report.status, .stale)
        XCTAssertEqual(report.notice, "Your toolkit was compiled with a different embedding setup. Recompile it under Tools.")
        XCTAssertNil(ChatToolsReport.off.notice)
    }

    func testChatErrorsAreTheServersOwnSentences() async {
        let cases: [(Int, String)] = [
            (400, "backend_id is required."),
            (404, "Backend not found \u{2014} connect one first."),
            (413, "Message is too long."),
            (502, "No response from https://api.example.com \u{2014} the endpoint may be offline."),
            (500, "Reply received but not saved: duplicate key"),
        ]
        for (status, message) in cases {
            let transport = MockTransport(routes: [.failure(.post, "/api/chat", status: status, message: message)])
            do {
                _ = try await client(transport).send(.chat(backendID: "b", message: "x"))
                XCTFail("expected \(status)")
            } catch let error as HVError {
                XCTAssertEqual(error.status, status)
                XCTAssertEqual(error.userMessage, message)
            } catch { XCTFail("\(error)") }
        }
    }

    func testChatIsNeverRetried() async {
        let calls = Counter()
        let transport = MockTransport(routes: [MockRoute(.post, "/api/chat") { _ in
            calls.bump()
            return HTTPResponse(status: 502, data: Data(#"{"error":"bad gateway"}"#.utf8))
        }])
        let api = HVClient(baseURL: base, transport: transport, tokens: StaticTokenProvider(), retry: RetryPolicy(maxAttempts: 3), sleep: { _ in })
        _ = try? await api.send(.chat(backendID: "b", message: "x"))
        XCTAssertEqual(calls.value, 1)
    }

    // MARK: Feedback, settings, toolkit

    func testFeedbackBody() async throws {
        let transport = MockTransport(routes: [.json(.post, "/api/messages/m1/feedback", #"{"id":"m1","feedback":"up","message":"Thanks — future replies will lean toward what you like."}"#)])
        let api = client(transport)
        let saved = try await api.send(.rate(messageID: "m1", .up))
        XCTAssertEqual(saved.message, "Thanks \u{2014} future replies will lean toward what you like.")
        _ = try await api.send(.rate(messageID: "m1", nil))
        let sent = await transport.requests(matching: "/api/messages/m1/feedback")
        XCTAssertEqual(requestJSON(sent[0]), ["feedback": "up"])
        XCTAssertEqual(requestJSON(sent[1]), ["feedback": .null])
    }

    func testSettingsRoundTrip() async throws {
        let transport = MockTransport(routes: [
            .json(.get, "/api/chat-settings", #"{"smart_context":true,"deep_memory":false,"polytician":true,"truth":true}"#),
            .json(.patch, "/api/chat-settings", #"{"smart_context":false,"deep_memory":false,"polytician":true,"truth":true}"#),
        ])
        let api = client(transport)
        let settings = try await api.send(.chatSettings)
        XCTAssertEqual(settings, ChatSettings(smartContext: true, deepMemory: false, polytician: true, truth: true))
        let updated = try await api.send(.updateChatSettings(smartContext: false))
        XCTAssertFalse(updated.smartContext)
        let sent = await transport.requests(matching: "/api/chat-settings").last
        XCTAssertEqual(requestJSON(sent), ["smart_context": false])
    }

    func testToolkitStatus() async throws {
        let none = MockTransport(routes: [.json(.get, "/api/toolkits", #"{"toolkit":null,"stale":false}"#)])
        let noStatus = try await client(none).send(.toolkitStatus)
        XCTAssertFalse(noStatus.hasToolkit)
        let some = MockTransport(routes: [.json(.get, "/api/toolkits", #"{"toolkit":{"id":"t1","stats":{},"embedder":{},"embedder_label":"x","compiled_at":"2026-10-01T00:00:00Z"},"stale":true}"#)])
        let status = try await client(some).send(.toolkitStatus)
        XCTAssertTrue(status.hasToolkit)
        XCTAssertTrue(status.stale)
        let broken = MockTransport(routes: [.json(.get, "/api/toolkits", #"{"error":"x"}"#)])
        let fallback = try await client(broken).send(.toolkitStatus)
        XCTAssertFalse(fallback.hasToolkit)
    }

    // MARK: On-device endpoints (app/api/chat/context, app/api/chat/turns)

    func testContextDecodesAndTurnsSavesWhatTheRouteReads() async throws {
        let transport = MockTransport(routes: [
            .json(.post, "/api/chat/context", """
            {"conversation_id":null,"system":"## Truth\\nThe flight is on the 3rd.","messages":[{"role":"user","content":"when do we fly?","attachments":[]}],
             "next_position":0,"recalled":[{"title":"Trip","slug":"trip-1"}],"recalled_memories":["Flights"],"pulled":[],
             "recall_branch":"main","smart_context":false,"deep_memory":null,"truth":{"cited":1,"contested":0,"flags":0,"ledgers":["default"]}}
            """),
            .json(.post, "/api/chat/turns", #"{"conversation_id":"c5","reply":{"id":"m9","role":"assistant","content":"On the 3rd.","model":"apple-on-device"}}"#),
        ])
        let api = client(transport)
        let context = try await api.send(.chatContext(message: "when do we fly?"))
        XCTAssertNil(context.conversationID)
        XCTAssertEqual(context.messages, [ChatWireMessage(role: .user, content: "when do we fly?")])
        XCTAssertEqual(context.grounding.pages.map(\.slug), ["trip-1"])
        XCTAssertEqual(context.grounding.truth?.cited, 1)

        let saved = try await api.send(.saveTurn(userMessage: "when do we fly?", assistantContent: "On the 3rd.", conversationID: nil, model: "apple-on-device"))
        XCTAssertEqual(saved.conversationID, "c5")
        XCTAssertEqual(saved.reply.id, "m9")
        let sent = requestJSON(await transport.requests(matching: "/api/chat/turns").first)
        XCTAssertEqual(sent?["user_message"], "when do we fly?")
        XCTAssertEqual(sent?["assistant_content"], "On the 3rd.")
        XCTAssertEqual(sent?["model"], "apple-on-device")
        XCTAssertNil(sent?["conversation_id"])
        let contextBody = requestJSON(await transport.requests(matching: "/api/chat/context").first)
        XCTAssertNil(contextBody?["use_tools"])
    }

    func testTurnsRefusalsAreVerbatim() async {
        let transport = MockTransport(routes: [.failure(.post, "/api/chat/turns", status: 404, message: "Conversation not found.")])
        do {
            _ = try await client(transport).send(.saveTurn(userMessage: "a", assistantContent: "b", conversationID: "gone"))
            XCTFail("expected 404")
        } catch let error as HVError {
            XCTAssertEqual(error.userMessage, "Conversation not found.")
        } catch { XCTFail("\(error)") }
    }
}
