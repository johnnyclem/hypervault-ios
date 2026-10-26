import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HyperVaultKit

/// Fixtures follow app/api/rooms/**; the mention cases are lib/rooms/__tests__/mentions.test.ts.
final class RoomsTests: XCTestCase {
    let base = URL(string: "https://hv.test")!
    let roomHandles = ["grok", "gemini", "claude"]

    func client(_ transport: MockTransport) -> HVClient {
        HVClient(baseURL: base, transport: transport, tokens: StaticTokenProvider(), retry: .none, sleep: { _ in })
    }

    // MARK: models

    func testRoomListDecodes() async throws {
        let transport = MockTransport(routes: [.json(.get, "/api/rooms", """
        {"rooms":[{"id":"r1","title":"Features X & Y","pending":[{"handle":"gemini","reason":"The user spoke to the room."}],
          "created_at":"2026-10-20T10:00:00Z","updated_at":"2026-10-25T10:00:00Z",
          "members":[{"id":"mem1","room_id":"r1","backend_id":"b1","handle":"grok","role_brief":"You take X.","position":0,"backend":{"name":"Grok","provider":"xai","default_model":"grok-4"}},
                     {"id":"mem2","room_id":"r1","backend_id":"b2","handle":"claude","role_brief":"","position":1,"backend":null}]}]}
        """)])
        let rooms = try await client(transport).send(.rooms)
        XCTAssertEqual(rooms.count, 1)
        XCTAssertEqual(rooms[0].pending, [ChatRoomTurn(handle: "gemini", reason: "The user spoke to the room.")])
        XCTAssertEqual(rooms[0].members.map(\.handle), ["grok", "claude"])
        XCTAssertEqual(rooms[0].members[0].backend?.defaultModel, "grok-4")
        XCTAssertNil(rooms[0].members[1].backend)
    }

    func testRoomDetailAndPolling() async throws {
        let transport = MockTransport(routes: [.json(.get, "/api/rooms/r1", """
        {"room":{"id":"r1","title":"Features","pending":[],"budget":9,"running":true,"truth_ledgers":null,"created_at":"2026-10-20T10:00:00Z","updated_at":"2026-10-25T10:00:00Z"},
         "members":[{"id":"mem1","room_id":"r1","backend_id":"b1","handle":"grok","role_brief":"","position":0}],
         "messages":[
          {"id":"x1","room_id":"r1","position":0,"sender_kind":"human","sender_handle":null,"member_id":null,"content":"grok - take X","mentions":["grok"],"tool_turns":[],"model":null,"status":"complete","created_at":"2026-10-25T10:00:00Z"},
          {"id":"x2","room_id":"r1","position":1,"sender_kind":"agent","sender_handle":"grok","member_id":"mem1","content":"On it. Wrote the plan.","mentions":[],"tool_turns":[{"tool":"create_artifact","ok":true,"summary":"Created plan-x7k2","url":"https://hv.test/a/plan-x7k2","slug":"plan-x7k2"}],"model":"grok-4","status":"complete","created_at":"2026-10-25T10:00:30Z"},
          {"id":"x3","room_id":"r1","position":2,"sender_kind":"agent","sender_handle":"grok","member_id":"mem1","content":"(@grok couldn't reply: timeout)","mentions":[],"tool_turns":[],"model":null,"status":"error","created_at":"2026-10-25T10:01:00Z"},
          {"id":"x4","room_id":"r1","position":3,"sender_kind":"system","sender_handle":null,"member_id":null,"content":"Paused: this round used its 12-turn budget.","mentions":[],"tool_turns":[],"model":null,"status":"complete","created_at":"2026-10-25T10:02:00Z"}
         ]}
        """)])
        let api = client(transport)
        let detail = try await api.send(.room(id: "r1", after: 4))
        XCTAssertEqual(detail.room.budget, 9)
        XCTAssertTrue(detail.room.running)
        XCTAssertEqual(detail.messages.map(\.senderKind), [.human, .agent, .agent, .system])
        XCTAssertEqual(detail.messages[1].toolTurns.first?.slug, "plan-x7k2")
        XCTAssertTrue(detail.messages[2].failed)
        XCTAssertFalse(detail.messages[1].failed)
        let request = await transport.requests.first
        XCTAssertEqual(request?.url?.query, "after=4")
    }

    func testCreateRoomBody() async throws {
        let transport = MockTransport(routes: [.json(.post, "/api/rooms", """
        {"room":{"id":"r2","title":"Untitled room","created_at":"2026-10-26T10:00:00Z","truth_ledgers":null},
         "members":[{"id":"m1","room_id":"r2","backend_id":"b1","handle":"claude","role_brief":"","position":0}]}
        """, status: 201)])
        let created = try await client(transport).send(.createRoom(title: "  ", members: [
            ChatRoomMemberDraft(backendID: "b1", handle: "claude"),
            ChatRoomMemberDraft(backendID: "b2", handle: "grok", roleBrief: " Own the API. "),
        ]))
        XCTAssertEqual(created.room.id, "r2")
        let body = requestJSON(await transport.requests.first)
        XCTAssertNil(body?["title"])
        XCTAssertEqual(body?["members"], [
            ["backend_id": "b1", "handle": "claude"],
            ["backend_id": "b2", "handle": "grok", "role_brief": "Own the API."],
        ])
    }

    func testMembersAndRename() async throws {
        let transport = MockTransport(routes: [
            .json(.post, "/api/rooms/r1/members", #"{"members":[{"id":"m9","room_id":"r1","backend_id":"b3","handle":"gemini","role_brief":"","position":2}]}"#, status: 201),
            .json(.delete, "/api/rooms/r1/members", #"{"ok":true}"#),
            .json(.patch, "/api/rooms/r1", #"{"ok":true,"title":"New"}"#),
            .failure(.delete, "/api/rooms/nope", status: 404, message: "Room not found."),
        ])
        let api = client(transport)
        let added = try await api.send(.addRoomMembers(roomID: "r1", members: [ChatRoomMemberDraft(backendID: "b3", handle: "gemini")]))
        XCTAssertEqual(added.map(\.handle), ["gemini"])
        _ = try await api.send(.removeRoomMember(roomID: "r1", memberID: "m9"))
        _ = try await api.send(.renameRoom(id: "r1", title: "New"))
        let all = await transport.requests
        XCTAssertEqual(requestJSON(all[1]), ["member_id": "m9"])
        XCTAssertEqual(requestJSON(all[2]), ["title": "New"])
        do {
            _ = try await api.send(.deleteRoom(id: "nope"))
            XCTFail("expected 404")
        } catch let error as HVError {
            XCTAssertEqual(error.userMessage, "Room not found.")
        }
    }

    func testRoomRefusalsAreTheServersSentences() async {
        let taken = "Handle \u{201C}grok\u{201D} is already taken in this room."
        let transport = MockTransport(routes: [.failure(.post, "/api/rooms/r1/members", status: 400, message: taken)])
        do {
            _ = try await client(transport).send(.addRoomMembers(roomID: "r1", members: [ChatRoomMemberDraft(backendID: "b", handle: "grok")]))
            XCTFail("expected 400")
        } catch let error as HVError {
            XCTAssertEqual(error.userMessage, taken)
        } catch { XCTFail("\(error)") }
    }

    // MARK: handles and mentions (lib/rooms/mentions.ts)

    func testNormalizeHandle() {
        XCTAssertEqual(ChatRoomHandles.normalize("@Grok "), "grok")
        XCTAssertEqual(ChatRoomHandles.normalize("My Claude!"), "my-claude")
        XCTAssertNil(ChatRoomHandles.normalize("   "))
        XCTAssertNil(ChatRoomHandles.normalize("-"))
        XCTAssertNil(ChatRoomHandles.normalize(String(repeating: "a", count: 33)))
        XCTAssertEqual(ChatRoomHandles.normalize("gpt_4"), "gpt_4")
    }

    func testDefaultHandles() {
        XCTAssertEqual(ChatRoomHandles.defaultHandle(provider: "anthropic", name: "Work Claude"), "claude")
        XCTAssertEqual(ChatRoomHandles.defaultHandle(provider: "xai", name: "x"), "grok")
        XCTAssertEqual(ChatRoomHandles.defaultHandle(provider: "openai", name: "x"), "gpt")
        XCTAssertEqual(ChatRoomHandles.defaultHandle(provider: "ollama", name: "Local Llama"), "local-llama")
        let backends = [
            ChatBackend(id: "a", name: "One", provider: "anthropic"),
            ChatBackend(id: "b", name: "Two", provider: "anthropic"),
            ChatBackend(id: "c", name: "Three", provider: "xai"),
        ]
        XCTAssertEqual(ChatRoomHandles.defaultHandles(for: backends), ["a": "claude", "b": "claude2", "c": "grok"])
    }

    func testHandleProblems() {
        XCTAssertNil(ChatRoomHandles.problem(in: ["grok", "claude"]))
        XCTAssertEqual(ChatRoomHandles.problem(in: ["grok", "@Grok"]), "Two members can't both be @grok.")
        XCTAssertEqual(ChatRoomHandles.problem(in: ["!!"]), "\u{201C}!!\u{201D} isn't a usable handle. Use letters, digits, - and _.")
        XCTAssertEqual(ChatRoomHandles.problem(in: ["grok"], alreadyTaken: ["grok"]), "Two members can't both be @grok.")
    }

    func testMentionsParseTheKickoffInAddressOrder() {
        let text = "we're building features X&Y; grok- you take X; gemini - you take Y; claude you do the architecture first for both then hand it off, and when X&Y are done claude will do the code review"
        XCTAssertEqual(ChatRoomHandles.mentions(in: text, handles: roomHandles), ["grok", "gemini", "claude"])
    }

    func testMentionsFindAtHandlesOnceInFirstMentionOrder() {
        XCTAssertEqual(ChatRoomHandles.mentions(in: "done. @gemini the UI is yours, then @claude reviews. cc @gemini", handles: roomHandles), ["gemini", "claude"])
        XCTAssertEqual(ChatRoomHandles.mentions(in: "claude: sketch the schema\ngrok, wire the API", handles: roomHandles), ["claude", "grok"])
    }

    func testMentionsIgnoreTalkingAbout() {
        XCTAssertEqual(ChatRoomHandles.mentions(in: "I think the thing grok built yesterday is fine", handles: roomHandles), [])
        XCTAssertEqual(ChatRoomHandles.mentions(in: "Gemini already finished the UI. Grok built the API yesterday.", handles: roomHandles), [])
        XCTAssertEqual(ChatRoomHandles.mentions(in: "Gemini you take the UI. Grok, the API is yours.", handles: roomHandles), ["gemini", "grok"])
        XCTAssertEqual(ChatRoomHandles.mentions(in: "claude please review both", handles: roomHandles), ["claude"])
        XCTAssertEqual(ChatRoomHandles.mentions(in: "@GPT and @Claude please", handles: roomHandles), ["claude"])
        XCTAssertEqual(ChatRoomHandles.mentions(in: "@geminis are great", handles: roomHandles), [])
        XCTAssertEqual(ChatRoomHandles.mentions(in: "@grok-2 is old", handles: roomHandles), [])
        XCTAssertEqual(ChatRoomHandles.mentions(in: "", handles: roomHandles), [])
        XCTAssertEqual(ChatRoomHandles.mentions(in: "@grok", handles: []), [])
    }

    // MARK: the driver

    /// A scripted server: each POST .../run answers with the next prepared run.
    func scriptedRoom(_ runs: [String]) -> (MockTransport, Counter) {
        let counter = Counter()
        let script = TestBox(runs)
        let transport = MockTransport(routes: [
            .json(.post, "/api/rooms/r1/messages", #"{"messages":[{"id":"h1","position":0,"sender_kind":"human","content":"hello","mentions":[]}],"pending":[{"handle":"grok","reason":""},{"handle":"gemini","reason":""}],"budget":12}"#),
            MockRoute(.post, "/api/rooms/r1/run") { _ in
                counter.bump()
                var queue = script.value
                let next = queue.isEmpty ? #"{"messages":[],"pending":[],"budget":0}"# : queue.removeFirst()
                script.value = queue
                return HTTPResponse(status: 200, data: Data(next.utf8))
            },
        ])
        return (transport, counter)
    }

    func message(_ id: String, _ handle: String) -> String {
        #"{"id":"\#(id)","position":1,"sender_kind":"agent","sender_handle":"\#(handle)","content":"hi","mentions":[]}"#
    }

    func testTheDriverKeepsRunningUntilTheQueueDrains() async throws {
        let (transport, runs) = scriptedRoom([
            #"{"messages":[\#(message("a1", "grok"))],"pending":[{"handle":"gemini","reason":""}],"budget":10}"#,
            #"{"messages":[\#(message("a2", "gemini"))],"pending":[],"budget":9}"#,
        ])
        let driver = ChatRoomDriver(client: client(transport), roomID: "r1", sleep: { _ in })
        let seen = TestBox<[String]>([])
        let outcome = try await driver.send("hello") { run in
            seen.value += run.messages.map(\.id)
        }
        XCTAssertEqual(outcome, .finished)
        XCTAssertEqual(seen.value, ["h1", "a1", "a2"])
        XCTAssertEqual(runs.value, 2)
    }

    func testBusyMeansWaitAndAskAgain() async throws {
        let (transport, runs) = scriptedRoom([
            #"{"messages":[],"pending":[{"handle":"grok","reason":""}],"budget":11,"busy":true}"#,
            #"{"messages":[],"pending":[{"handle":"grok","reason":""}],"budget":11,"busy":true}"#,
            #"{"messages":[\#(message("a1", "grok"))],"pending":[],"budget":10}"#,
        ])
        let slept = Counter()
        let driver = ChatRoomDriver(client: client(transport), roomID: "r1", sleep: { _ in slept.bump() })
        let outcome = try await driver.send("hello") { _ in }
        XCTAssertEqual(outcome, .finished)
        XCTAssertEqual(runs.value, 3)
        XCTAssertGreaterThanOrEqual(slept.value, 2)
    }

    func testAStalledRoomStopsInsteadOfLooping() async throws {
        let stall = #"{"messages":[],"pending":[{"handle":"grok","reason":""}],"budget":5}"#
        let (transport, runs) = scriptedRoom([stall, stall, stall, stall, stall, stall])
        let driver = ChatRoomDriver(client: client(transport), roomID: "r1", sleep: { _ in })
        let outcome = try await driver.send("hello") { _ in }
        XCTAssertEqual(outcome, .stalled)
        XCTAssertEqual(runs.value, 3)
    }

    func testResumeWithNothingQueuedIsOneQuietRequest() async throws {
        let (transport, runs) = scriptedRoom([])
        let driver = ChatRoomDriver(client: client(transport), roomID: "r1", sleep: { _ in })
        let outcome = try await driver.resume { _ in }
        XCTAssertEqual(outcome, .finished)
        XCTAssertEqual(runs.value, 1)
    }

    func testADriverFailureCarriesTheServersSentence() async {
        let transport = MockTransport(routes: [
            .json(.post, "/api/rooms/r1/messages", #"{"messages":[],"pending":[{"handle":"grok","reason":""}],"budget":12}"#),
            .failure(.post, "/api/rooms/r1/run", status: 503, message: "The database is missing agent-room support."),
        ])
        let driver = ChatRoomDriver(client: client(transport), roomID: "r1", sleep: { _ in })
        do {
            _ = try await driver.send("hi") { _ in }
            XCTFail("expected 503")
        } catch let error as HVError {
            XCTAssertEqual(error.userMessage, "The database is missing agent-room support.")
        } catch { XCTFail("\(error)") }
    }
}
