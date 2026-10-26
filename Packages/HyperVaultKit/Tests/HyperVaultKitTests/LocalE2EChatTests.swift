import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HyperVaultKit

// Connected models, conversations, turns saved from a model on the device, chat settings and rooms of several
// agents. A model is the stand-in in scripts/e2e/fakes.mjs (an echo), so a turn is real in every way except the
// intelligence. The tests that need it skip when HV_E2E_FAKES is not set (or the server refuses local addresses).

final class LocalE2EChatTests: LocalE2ECase {

    private var fakes: URL? {
        ProcessInfo.processInfo.environment["HV_E2E_FAKES"].flatMap(URL.init(string:))
    }

    private func requireFakes() throws -> URL {
        guard let fakes else { throw XCTSkip("Set HV_E2E_FAKES (scripts/e2e/start.sh does) for the tests that talk to the local model.") }
        return fakes
    }

    /// The stand-in's request log, as JSON.
    private func fakeLog() async throws -> [JSONValue] {
        let base = try requireFakes()
        let api = HVClient(baseURL: base, transport: URLSessionTransport(), tokens: nil, retry: .none)
        let log = try await api.send(Endpoint<JSONValue>(.get, "/__log", auth: .none, keys: .verbatim))
        return log.array ?? []
    }

    private func connect(_ api: HVClient, name: String, model: String = "fake-model", key: String = "sk-test-0123456789") async throws -> ChatBackend {
        let base = try requireFakes()
        var draft = ChatBackendDraft(provider: "custom", name: name, apiKey: key, baseURL: base.appendingPathComponent("llm/v1").absoluteString, model: model)
        draft.skipTest = false
        let saved = try await send(.connectBackend(draft, serverCanStoreKeys: true), api)
        return saved.backend
    }

    // MARK: Backends

    func testConnectingAModelStoresItsKeyEncryptedAndNeverReturnsIt() async throws {
        let (api, token) = member(24)
        let capabilities = try await send(.capabilities, api)
        XCTAssertTrue(capabilities.features.keyEncryption)
        let spec = try XCTUnwrap(capabilities.providers.first { $0.id == "custom" })
        let base = try requireFakes()
        var draft = ChatBackendDraft(provider: "custom", name: "  My fake  ", apiKey: "sk-secret-abcdef123456", baseURL: base.appendingPathComponent("llm/v1").absoluteString, model: "fake-model")
        XCTAssertNil(draft.problem(spec: spec, serverCanStoreKeys: true))

        let (saved, raw) = try await fetch(.connectBackend(draft, serverCanStoreKeys: true), api)
        XCTAssertEqual(saved.backend.name, "My fake")
        XCTAssertEqual(saved.backend.provider, "custom")
        XCTAssertEqual(saved.backend.defaultModel, "fake-model")
        XCTAssertEqual(saved.backend.baseUrl, draft.baseURL)
        XCTAssertTrue(saved.backend.keyHint?.hasPrefix("sk-sec") ?? false && saved.backend.keyHint?.hasSuffix("…") ?? false, "hint: \(String(describing: saved.backend.keyHint))")
        XCTAssertFalse(saved.backend.keyHint?.contains("abcdef") ?? true)
        XCTAssertNotNil(saved.backend.createdAt)
        XCTAssertNotNil(saved.message, "the connect test's sentence")
        XCTAssertFalse(raw.jsonString().contains("abcdef123456"), "the key came back")

        // The list never carries it either, and the stored value is not the key.
        let (list, listRaw) = try await fetch(.backends, api)
        XCTAssertEqual(list.count, rawCount(listRaw, "backends"))
        XCTAssertFalse(listRaw.jsonString().contains("abcdef123456"))
        let row = try XCTUnwrap(list.first { $0.id == saved.backend.id })
        XCTAssertEqual(row.keyHint, saved.backend.keyHint)
        XCTAssertEqual(row.modelLine.isEmpty, false)
        let stored = try await inspect("llm_backends", [URLQueryItem(name: "id", value: "eq.\(saved.backend.id)")], select: "api_key_cipher")
        let cipher = try XCTUnwrap(stored.first?["api_key_cipher"]?.string, "no ciphertext was stored")
        XCTAssertTrue(cipher.hasPrefix("v2."), cipher)
        XCTAssertFalse(cipher.contains("abcdef"))
        _ = token

        // The connect test went to the model with the key.
        let log = try await fakeLog()
        XCTAssertTrue(log.contains { $0["authorization"]?.string == "Bearer sk-secret-abcdef123456" }, "the model was never called with the key")

        // Edit in place: a new name and model keep the stored key (a blank key keeps it).
        var edit = ChatBackendDraft(editing: saved.backend)
        edit.name = "Renamed fake"
        edit.model = "fake-model-2"
        XCTAssertEqual(edit.apiKey, "")
        let edited = try await send(.updateBackend(id: saved.backend.id, edit, supportsEmbeddings: spec.supportsEmbeddings, serverCanStoreKeys: true), api)
        XCTAssertEqual(edited.backend.name, "Renamed fake")
        XCTAssertEqual(edited.backend.defaultModel, "fake-model-2")
        XCTAssertEqual(edited.backend.keyHint, saved.backend.keyHint, "an edit with a blank key lost the stored key")
        let afterEdit = try await send(.backends, api)
        XCTAssertEqual(afterEdit.first { $0.id == saved.backend.id }?.name, "Renamed fake")

        // Refusals: a model that is down, a wrong key, a missing model, a cap on the key's presence, an unknown provider.
        var down = draft
        down.model = "always-fails"
        let downFailure = await expectFailure(400, .connectBackend(down, serverCanStoreKeys: true), api)
        XCTAssertFalse(downFailure?.message.isEmpty ?? true)
        var wrongKey = draft
        wrongKey.apiKey = "sk-wrong-key-000000"
        await expectFailure(400, .connectBackend(wrongKey, serverCanStoreKeys: true), api, message: "key")
        var noModel = draft
        noModel.model = ""
        XCTAssertNotNil(noModel.problem(spec: spec, serverCanStoreKeys: true))
        await expectFailure(400, .connectBackend(noModel, serverCanStoreKeys: true), api)
        await expectFailure(400, .connectBackend(ChatBackendDraft(provider: "not-a-provider", apiKey: "k"), serverCanStoreKeys: true), api)
        var skipped = down
        skipped.skipTest = true
        let kept = try await send(.connectBackend(skipped, serverCanStoreKeys: true), api)
        XCTAssertEqual(kept.backend.defaultModel, "always-fails", "skip_test saves without calling the model")

        // Disconnect.
        _ = try await send(.disconnectBackend(id: kept.backend.id), api)
        _ = try await send(.disconnectBackend(id: saved.backend.id), api)
        let after = try await send(.backends, api)
        XCTAssertNil(after.first { $0.id == saved.backend.id })
        // Another person disconnecting someone else's model changes nothing (the server answers ok and deletes no row).
        let other = try await connect(api, name: "Kept")
        let (bob, _) = try second()
        _ = try? await bob.send(.disconnectBackend(id: other.id))
        let still = try await send(.backends, api)
        XCTAssertNotNil(still.first { $0.id == other.id }, "another person disconnected this person's model")
        _ = try await send(.disconnectBackend(id: other.id), api)
    }

    // MARK: Conversations

    func testATurnWithAConnectedModelIsSavedAndGroundedInRecalledMemories() async throws {
        let (api, _) = member(25)
        let word = uniqueWord()
        _ = try await send(.memoryCreate(MemoryDraft(content: "The \(word) festival happens every autumn in Lisbon.", title: "Festival \(word)")), api)
        let backend = try await connect(api, name: "Echo \(word)")
        XCTAssertNotNil(backend.id)

        let first = try await send(.chat(backendID: backend.id, message: "When is the \(word) festival?"), api)
        XCTAssertFalse(first.conversationID.isEmpty)
        XCTAssertTrue(first.reply.content.hasPrefix("Echo ("), first.reply.content)
        XCTAssertTrue(first.reply.content.contains("\(word) festival"), "the model never saw the question")
        XCTAssertNotNil(first.reply.id)
        XCTAssertEqual(first.reply.model, "fake-model")
        XCTAssertFalse(first.reply.truncated)
        XCTAssertEqual(first.backend?.id, backend.id)
        XCTAssertEqual(first.backend?.name, "Echo \(word)")
        XCTAssertTrue(first.recalledMemories.contains("Festival \(word)"), "recalled: \(first.recalledMemories)")
        XCTAssertTrue(first.reply.content.contains("system yes"), "the memory's context should have gone to the model as its system prompt")
        let log = try await fakeLog()
        let sent = log.last { $0["path"]?.string == "/llm/v1/chat/completions" && ($0["body"]?["messages"]?.array?.contains { ($0["content"]?.string ?? "").contains("Lisbon") } ?? false) }
        XCTAssertNotNil(sent, "the recalled memory's text did not reach the model")

        // A second turn continues the thread.
        let followUp = try await send(.chat(backendID: backend.id, message: "Thanks, and where?", conversationID: first.conversationID), api)
        XCTAssertEqual(followUp.conversationID, first.conversationID)
        XCTAssertTrue(followUp.reply.content.contains("3 messages"), followUp.reply.content)

        // The conversation, with both turns, in order.
        let (detail, raw) = try await fetch(.conversation(id: first.conversationID), api)
        XCTAssertEqual(detail.messages.count, rawCount(raw, "messages"))
        XCTAssertEqual(detail.messages.map(\.role), [.user, .assistant, .user, .assistant])
        XCTAssertEqual(detail.messages.map(\.position), [0, 1, 2, 3])
        XCTAssertEqual(detail.messages[0].content, "When is the \(word) festival?")
        XCTAssertEqual(detail.messages[3].content, followUp.reply.content)
        XCTAssertEqual(detail.messages[1].id, first.reply.id)
        XCTAssertEqual(detail.conversation.visibility, .private)
        XCTAssertEqual(detail.conversation.platform, .hypervault)
        XCTAssertEqual(detail.conversation.model, "fake-model")
        XCTAssertFalse(detail.conversation.title.isEmpty)

        let (list, listRaw) = try await fetch(.conversations, api)
        XCTAssertEqual(list.count, rawCount(listRaw, "conversations"))
        XCTAssertEqual(list.first?.id, first.conversationID, "newest first")

        // Rate a reply, then clear it.
        let rated = try await send(.rate(messageID: try XCTUnwrap(first.reply.id), .up), api)
        XCTAssertNotNil(rated.message ?? rated.id)
        let afterRate = try await send(.conversation(id: first.conversationID), api)
        XCTAssertEqual(afterRate.messages[1].feedback, .up)
        _ = try await send(.rate(messageID: try XCTUnwrap(first.reply.id), nil), api)
        let cleared = try await send(.conversation(id: first.conversationID), api)
        XCTAssertNil(cleared.messages[1].feedback)

        // Share: the first move away from private mints a link.
        let shared = try await send(.setVisibility(conversationID: first.conversationID, .shared), api)
        XCTAssertEqual(shared.conversation.visibility, .shared)
        XCTAssertNotNil(shared.conversation.shareSlug)
        XCTAssertNotNil(shared.conversation.sharePath)
        let back = try await send(.setVisibility(conversationID: first.conversationID, .private), api)
        XCTAssertEqual(back.conversation.visibility, .private)

        // The turn's refusals.
        await expectFailure(404, .chat(backendID: "00000000-0000-4000-8000-000000000000", message: "hi"), api)
        await expectFailure(400, .chat(backendID: backend.id, message: "   "), api)
        let caps = try await send(.capabilities, api)
        let tooLong = String(repeating: "x", count: caps.limits.chatMessageChars + 1)
        await expectFailure(413, .chat(backendID: backend.id, message: tooLong), api)
        let (bob, _) = try second()
        await expectFailure(404, .conversation(id: first.conversationID), bob)

        // Delete.
        _ = try await send(.deleteConversation(id: first.conversationID), api)
        await expectFailure(404, .conversation(id: first.conversationID), api)
        _ = try await send(.disconnectBackend(id: backend.id), api)
    }

    func testATurnWrittenOnTheDeviceIsSavedWithItsContext() async throws {
        let (api, _) = member(26)
        let word = uniqueWord()
        _ = try await send(.memoryCreate(MemoryDraft(content: "Our \(word) policy: refunds within 30 days.", title: "Policy \(word)")), api)

        // The context a turn needs before the model on the device answers.
        let (context, raw) = try await fetch(.chatContext(message: "What is the \(word) policy?"), api)
        XCTAssertNil(context.conversationID)
        XCTAssertEqual(context.messages.last?.role, .user)
        XCTAssertEqual(context.messages.last?.content, "What is the \(word) policy?")
        XCTAssertTrue(context.system.contains("refunds within 30 days"), "recall did not reach the system prompt")
        XCTAssertTrue(context.recalledMemories.contains("Policy \(word)"))
        XCTAssertEqual(context.recalledMemories.count, rawCount(raw, "recalled_memories"))
        XCTAssertEqual(context.nextPosition, raw["next_position"]?.int)
        XCTAssertFalse(context.grounding.isEmpty)

        // Then the turn the device wrote is saved: the message and the reply together.
        let saved = try await send(.saveTurn(userMessage: "What is the \(word) policy?", assistantContent: "Refunds within 30 days.", title: "Policy chat", model: "on-device"), api)
        XCTAssertFalse(saved.conversationID.isEmpty)
        XCTAssertEqual(saved.reply.content, "Refunds within 30 days.")
        XCTAssertEqual(saved.reply.model, "on-device")
        XCTAssertNotNil(saved.reply.id)
        let more = try await send(.saveTurn(userMessage: "And exchanges?", assistantContent: "Within 14 days.", conversationID: saved.conversationID, model: "on-device"), api)
        XCTAssertEqual(more.conversationID, saved.conversationID)
        let detail = try await send(.conversation(id: saved.conversationID), api)
        XCTAssertEqual(detail.messages.map(\.content), ["What is the \(word) policy?", "Refunds within 30 days.", "And exchanges?", "Within 14 days."])
        XCTAssertEqual(detail.conversation.title, "Policy chat")
        XCTAssertEqual(detail.messages.map(\.position), [0, 1, 2, 3])
        XCTAssertEqual(detail.messages[1].model, "on-device")
        // A follow-up's context carries the thread so far.
        let next = try await send(.chatContext(message: "Anything else?", conversationID: saved.conversationID), api)
        XCTAssertEqual(next.conversationID, saved.conversationID)
        XCTAssertEqual(next.nextPosition, 4)
        XCTAssertGreaterThanOrEqual(next.messages.count, 5)
        await expectFailure(400, .saveTurn(userMessage: "", assistantContent: "x"), api)
        await expectFailure(404, .saveTurn(userMessage: "hi", assistantContent: "yo", conversationID: "00000000-0000-4000-8000-000000000000"), api)
        _ = try await send(.deleteConversation(id: saved.conversationID), api)
    }

    func testChatSettingsRoundTripAndTheToolkitStatus() async throws {
        let (api, _) = member(27)
        let (initial, raw) = try await fetch(.chatSettings, api)
        XCTAssertEqual(raw.object?.count, 4, "chat settings grew a field the Kit does not know: \(raw.jsonString())")
        XCTAssertEqual(initial.smartContext, raw["smart_context"]?.bool)
        XCTAssertEqual(initial.deepMemory, raw["deep_memory"]?.bool)
        XCTAssertEqual(initial.polytician, raw["polytician"]?.bool)
        XCTAssertEqual(initial.truth, raw["truth"]?.bool)

        let flipped = try await send(.updateChatSettings(smartContext: !initial.smartContext, truth: !initial.truth), api)
        XCTAssertEqual(flipped.smartContext, !initial.smartContext)
        XCTAssertEqual(flipped.truth, !initial.truth)
        XCTAssertEqual(flipped.deepMemory, initial.deepMemory, "a field left out is left alone")
        let reread = try await send(.chatSettings, api)
        XCTAssertEqual(reread, flipped)
        _ = try await send(.updateChatSettings(smartContext: initial.smartContext, truth: initial.truth), api)

        let toolkit = try await send(.toolkitStatus, api)
        XCTAssertFalse(toolkit.hasToolkit, "this person has compiled no tools")
        let canvas = try await send(.canvasBackends, api)
        report("canvas backends", [("count", canvas.count)])
    }

    // MARK: Rooms

    func testARoomOfTwoAgentsTakesTurnsAndKeepsATranscript() async throws {
        let (api, _) = member(28)
        let word = uniqueWord()
        let a = try await connect(api, name: "Alpha \(word)")
        let b = try await connect(api, name: "Beta \(word)")
        let members = [
            ChatRoomMemberDraft(backendID: a.id, handle: "alpha", roleBrief: "You are the optimist."),
            ChatRoomMemberDraft(backendID: b.id, handle: "beta", roleBrief: "You are the sceptic."),
        ]
        let (created, raw) = try await fetch(.createRoom(title: "Debate \(word)", members: members), api)
        XCTAssertEqual(created.room.title, "Debate \(word)")
        XCTAssertEqual(created.members.count, rawCount(raw, "members"))
        XCTAssertEqual(created.members.map(\.handle), ["alpha", "beta"])
        XCTAssertEqual(created.members.map(\.position), [0, 1])
        XCTAssertEqual(created.members[0].roleBrief, "You are the optimist.")
        XCTAssertEqual(created.members[0].backendId, a.id)

        let (rooms, roomsRaw) = try await fetch(.rooms, api)
        XCTAssertEqual(rooms.count, rawCount(roomsRaw, "rooms"))
        let row = try XCTUnwrap(rooms.first { $0.id == created.room.id })
        XCTAssertEqual(row.members.count, 2)
        XCTAssertEqual(row.members.first?.backend?.name, "Alpha \(word)")
        XCTAssertTrue(row.pending.isEmpty)

        // Say something to everyone: both answer in turn, in order.
        let run = try await send(.postRoomMessage(roomID: created.room.id, content: "Is a hot dog a sandwich?"), api)
        XCTAssertFalse(run.busy)
        XCTAssertEqual(run.messages.count, 3, "the person's message and two replies: \(run.messages.map { $0.content })")
        XCTAssertEqual(run.messages.map(\.senderKind), [.human, .agent, .agent])
        XCTAssertEqual(run.messages.compactMap(\.senderHandle).filter { $0 == "alpha" || $0 == "beta" }.sorted(), ["alpha", "beta"])
        XCTAssertTrue(run.messages.dropFirst().allSatisfy { $0.content.hasPrefix("Echo (") }, run.messages.map { $0.content }.joined(separator: " | "))
        XCTAssertTrue(run.messages.dropFirst().allSatisfy { !$0.failed })
        XCTAssertEqual(run.messages.map(\.position), run.messages.map(\.position).sorted())
        XCTAssertTrue(run.pending.isEmpty)

        // Addressing one by @handle makes only that one answer.
        let addressed = try await send(.postRoomMessage(roomID: created.room.id, content: "@beta why so sure?"), api)
        XCTAssertEqual(addressed.messages.count, 2, addressed.messages.map { "\($0.senderKind) \($0.senderHandle ?? "-")" }.joined(separator: ","))
        XCTAssertEqual(addressed.messages[0].mentions, ["beta"])
        XCTAssertEqual(addressed.messages[1].senderHandle, "beta")

        // The transcript, whole and then past a position.
        let (detail, detailRaw) = try await fetch(.room(id: created.room.id), api)
        XCTAssertEqual(detail.messages.count, rawCount(detailRaw, "messages"))
        XCTAssertEqual(detail.messages.count, 5)
        XCTAssertEqual(detail.room.title, "Debate \(word)")
        XCTAssertEqual(detail.members.count, 2)
        let after = detail.messages[2].position
        let poll = try await send(.room(id: created.room.id, after: after), api)
        XCTAssertEqual(poll.messages.map(\.id), detail.messages.filter { $0.position > after }.map(\.id))

        // The chat route's room-aware prompts reached the model: each member's role brief was in its system prompt.
        let log = try await fakeLog()
        XCTAssertTrue(log.contains { entry in
            entry["body"]?["messages"]?.array?.contains { ($0["content"]?.string ?? "").contains("You are the sceptic.") } ?? false
        }, "no member's brief reached its model")

        // Rename, add a member, remove a member.
        _ = try await send(.renameRoom(id: created.room.id, title: "Debate renamed"), api)
        let renamed = try await send(.room(id: created.room.id), api)
        XCTAssertEqual(renamed.room.title, "Debate renamed")
        let c = try await connect(api, name: "Gamma \(word)")
        let added = try await send(.addRoomMembers(roomID: created.room.id, members: [ChatRoomMemberDraft(backendID: c.id, handle: "gamma")]), api)
        XCTAssertEqual(added.map(\.handle), ["gamma"])
        await expectFailure(400, .addRoomMembers(roomID: created.room.id, members: [ChatRoomMemberDraft(backendID: c.id, handle: "gamma")]), api, message: "already taken")
        let withThree = try await send(.room(id: created.room.id), api)
        XCTAssertEqual(withThree.members.count, 3)
        let gamma = try XCTUnwrap(withThree.members.first { $0.handle == "gamma" })
        _ = try await send(.removeRoomMember(roomID: created.room.id, memberID: gamma.id), api)
        let withTwo = try await send(.room(id: created.room.id), api)
        XCTAssertEqual(withTwo.members.count, 2)

        // Continuing an empty queue does nothing.
        let idle = try await send(.runRoom(id: created.room.id), api)
        XCTAssertTrue(idle.messages.isEmpty)
        XCTAssertFalse(idle.busy)

        // Refusals: no members, a duplicate handle, another person's backend, another person's room.
        await expectFailure(400, .createRoom(title: "Empty", members: []), api)
        await expectFailure(400, .createRoom(title: "Twins", members: [ChatRoomMemberDraft(backendID: a.id, handle: "same"), ChatRoomMemberDraft(backendID: b.id, handle: "same")]), api)
        let (bob, _) = try second()
        await expectFailure(404, .room(id: created.room.id), bob)
        await expectFailure(400, .createRoom(title: "Borrowed", members: [ChatRoomMemberDraft(backendID: a.id, handle: "mine")]), bob)

        _ = try await send(.deleteRoom(id: created.room.id), api)
        await expectFailure(404, .room(id: created.room.id), api)
        for backend in [a, b, c] { _ = try await send(.disconnectBackend(id: backend.id), api) }
    }
}
