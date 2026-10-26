import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HyperVaultKit

// What is left: stored files (PDF and image) through the storage stand-in, the canvas and the memory "Ask" turns,
// asking an agent room about a truth item, the connect documents, the waitlist and the routes that need a service
// that is not here (the sidecar, the public MCP registry).

final class LocalE2EMoreTests: LocalE2ECase {

    private func requireFakes() throws -> URL {
        guard let text = ProcessInfo.processInfo.environment["HV_E2E_FAKES"], let url = URL(string: text) else {
            throw XCTSkip("Set HV_E2E_FAKES (scripts/e2e/start.sh does) for the tests that talk to the local model.")
        }
        return url
    }

    private func connect(_ api: HVClient, name: String) async throws -> ChatBackend {
        let base = try requireFakes()
        let draft = ChatBackendDraft(provider: "custom", name: name, apiKey: "sk-test-0123456789", baseURL: base.appendingPathComponent("llm/v1").absoluteString, model: "fake-model")
        return try await send(.connectBackend(draft, serverCanStoreKeys: true), api).backend
    }

    // MARK: Stored files

    private let tinyPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
    private let tinyPDF = Data("%PDF-1.1\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 72 72]>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF\n".utf8)

    func testAnImageAndAPDFAreUploadedKeptAndServedBack() async throws {
        let (api, token) = member(24)
        let word = uniqueWord()
        let uploader = ArtifactUploader(client: api)

        // An image: ticket, PUT to the signed address, then a permanent link.
        let ticket = try await send(.artifactUploadTicket(filename: "dot-\(word).png", size: tinyPNG.count), api)
        XCTAssertEqual(ticket.contentType, "image/png")
        XCTAssertTrue(ticket.path.hasSuffix(".png"), ticket.path)
        XCTAssertNotNil(ticket.token)
        XCTAssertGreaterThan(ticket.maxBytes ?? 0, tinyPNG.count)
        XCTAssertNotNil(URL(string: ticket.signedUrl))

        let image = try await uploader.upload(data: tinyPNG, filename: "dot-\(word).png", title: "Dot \(word)", tags: ["e2e"])
        XCTAssertFalse(image.duplicate)
        XCTAssertEqual(image.visibility, .private)
        let pdf = try await uploader.upload(data: tinyPDF, filename: "paper-\(word).pdf", title: "Paper \(word)")

        // Both are pages of their own kind, in the list and in Yours.
        let list = try await send(.artifacts, api)
        let imageRow = try XCTUnwrap(list.items.first { $0.slug == image.slug })
        XCTAssertEqual(imageRow.type, "image")
        XCTAssertTrue(imageRow.isStoredFile)
        XCTAssertEqual(imageRow.title, "Dot \(word)")
        XCTAssertEqual(imageRow.tags, ["e2e"])
        let pdfRow = try XCTUnwrap(list.items.first { $0.slug == pdf.slug })
        XCTAssertEqual(pdfRow.type, "pdf")
        let yours = try await send(.yours(query: word), api)
        XCTAssertTrue(yours.results.contains { $0.slug == image.slug })

        // The page loader gets the viewer page, and the file in it is the bytes that went up.
        let loader = ArtifactPageLoader(baseURL: env.server.baseURL, tokens: LocalStaticToken(token: token))
        guard case .html(let viewer, _) = await loader.load(slug: image.slug) else { return XCTFail("the viewer page did not load") }
        let embedded = try XCTUnwrap(ArtifactEmbeddedFile.find(in: viewer), "no <img> in the viewer page: \(viewer.prefix(300))")
        XCTAssertEqual(embedded.kind, .image)
        let bytes = try await URLSessionTransport().send(URLRequest(url: embedded.url))
        XCTAssertEqual(bytes.status, 200)
        XCTAssertEqual(bytes.data, tinyPNG, "the stored file is not the file that was uploaded")
        guard case .html(let pdfViewer, _) = await loader.load(slug: pdf.slug) else { return XCTFail("the PDF viewer did not load") }
        XCTAssertEqual(ArtifactEmbeddedFile.find(in: pdfViewer)?.kind, .pdf)
        // The stored markup route answers with a storage path, which the Kit knows is not markup.
        let source = try await send(.artifactSource(slug: image.slug), api)
        XCTAssertTrue(ArtifactPageLoader.looksLikeStoragePath(source.content), source.content)

        // Refusals: an unsupported type, a file over the plan's limit, a path that is not the person's own.
        await expectFailure(415, .artifactUploadTicket(filename: "notes.docx", size: 10), api)
        let caps = try await send(.capabilities, api)
        _ = caps
        await expectFailure(413, .artifactUploadTicket(filename: "huge.pdf", size: 500 * 1024 * 1024), api)
        await expectFailure(400, .importArtifactFile(path: "\(UUID().uuidString.lowercased())/\(UUID().uuidString.lowercased()).pdf", title: "Not mine"), api)
        do {
            _ = try await uploader.upload(data: Data(), filename: "empty.pdf")
            XCTFail("an empty file was uploaded")
        } catch let error as HVError {
            XCTAssertFalse(error.userMessage.isEmpty)
        }
        _ = try await send(.deleteArtifact(slug: image.slug), api)
        _ = try await send(.deleteArtifact(slug: pdf.slug), api)
    }

    // MARK: Canvas and Ask

    func testTheCanvasTurnPullsThingsInAndTheMemoryAskCitesWhatItRecalled() async throws {
        let (api, _) = member(25)
        let word = uniqueWord()
        let backend = try await connect(api, name: "Canvas model")
        let page = try await send(.keep(content: "Notes about \(word) harvest dates.", title: "Harvest \(word)"), api)
        let card = try await send(.card(slug: page.slug), api)
        let memory = try await send(.memoryCreate(MemoryDraft(content: "The \(word) harvest is in September.", title: "Harvest memory \(word)")), api)

        let backends = try await send(.canvasBackends, api)
        XCTAssertTrue(backends.contains { $0.id == backend.id && $0.name == "Canvas model" && $0.defaultModel == "fake-model" })

        let turn = try await send(.canvasChat(backendId: backend.id, message: "When is the \(word) harvest?", conversationId: nil, pulled: [CardRef(kind: .page, id: card.id)]), api)
        XCTAssertFalse(turn.conversationId.isEmpty)
        XCTAssertTrue(turn.content.hasPrefix("Echo ("), turn.content)
        XCTAssertNotNil(turn.replyId)
        XCTAssertFalse(turn.truncated)
        XCTAssertEqual(turn.pulledTitles, ["Harvest \(word)"], "the pulled page's name should come back")
        let more = try await send(.canvasChat(backendId: backend.id, message: "And then?", conversationId: turn.conversationId, pulled: []), api)
        XCTAssertEqual(more.conversationId, turn.conversationId)
        await expectFailure(404, .canvasChat(backendId: "00000000-0000-4000-8000-000000000000", message: "hi", conversationId: nil, pulled: []), api)

        // Ask: a turn with wiki recall; the answer names the memories it drew on.
        let askBackends = try await send(.memoryAskBackends, api)
        XCTAssertTrue(askBackends.contains { $0.id == backend.id })
        let answer = try await send(.memoryAsk(backendId: backend.id, message: "When is the \(word) harvest?"), api)
        XCTAssertFalse(answer.conversationId.isEmpty)
        XCTAssertTrue(answer.text.hasPrefix("Echo ("), answer.text)
        XCTAssertEqual(answer.model, "fake-model")
        XCTAssertTrue(answer.recalled.contains("Harvest memory \(word)"), "recalled: \(answer.recalled)")
        _ = memory
        for id in [turn.conversationId, answer.conversationId] { _ = try await send(.deleteConversation(id: id), api) }
        _ = try await send(.disconnectBackend(id: backend.id), api)
        _ = try await send(.deleteArtifact(slug: page.slug), api)
    }

    // MARK: Asking an agent room about a truth item

    func testAskingAnAgentRoomAboutATruthItemBringsTheRepliesBack() async throws {
        let fresh = try await freshMember("asker")
        let api = fresh.client
        _ = try await send(.setTruthHandle(unique("asker")), api)
        let slug = unique("askcase")
        _ = try await send(.createTruthLedger(slug: slug, kind: .hosted), api)
        let key = try await send(.createAgentKey(name: unique("asking agent")), api)
        var draft = TruthAssertDraft(type: .uv)
        draft.text = "The warehouse closes at nine"
        draft.basis = "the sign on the door"
        let uvResult = try await send(.assertTruth(draft, ledger: slug), client(key.key))
        let uv = try XCTUnwrap(uvResult.line)

        let backend = try await connect(api, name: "Verifier")
        let room = try await send(.createRoom(title: "Fact check", members: [ChatRoomMemberDraft(backendID: backend.id, handle: "verifier", roleBrief: "You check facts.")]), api)
        let rooms = try await send(.truthRooms, api)
        XCTAssertEqual(rooms.rooms.map(\.id), [room.room.id])
        XCTAssertEqual(rooms.rooms.first?.title, "Fact check")

        let review = try await send(.truthReview(ledger: slug), api)
        let item = try XCTUnwrap(review.docket.items.first { $0.id == uv.id })
        let ask = TruthDocketRules.state(of: .ask, for: item, in: review.ledger)
        XCTAssertTrue(ask.isAvailable, ask.unavailableReason ?? "")
        var decision = TruthDecisionDraft()
        decision.roomID = room.room.id
        decision.question = "Is this right?"
        XCTAssertNil(TruthDocketRules.problem(with: .ask, for: item, draft: decision))
        let answer = try await send(.askTruth(target: item.id, body: TruthDocketRules.body(of: .ask, for: item, ledger: slug, draft: decision)), api)
        let replies = try XCTUnwrap(answer.replies, "no replies; pending=\(answer.pending) rooms=\(answer.rooms)")
        XCTAssertEqual(replies.count, 1)
        XCTAssertEqual(replies[0].handle, "verifier")
        XCTAssertTrue(replies[0].content.hasPrefix("Echo ("), replies[0].content)
        XCTAssertFalse(answer.pending)
        // The question, the claim and its basis went to the room as the person.
        let detail = try await send(.room(id: room.room.id), api)
        XCTAssertEqual(detail.messages.first?.senderKind, .human)
        XCTAssertTrue(detail.messages.first?.content.contains("The warehouse closes at nine") ?? false)
        XCTAssertTrue(detail.messages.first?.content.contains("the sign on the door") ?? false)

        // Without a room the server offers the rooms there are.
        let noRoom = try await send(.askTruth(target: item.id, body: ["ledger": .string(slug)]), api)
        XCTAssertNil(noRoom.replies)
        XCTAssertEqual(noRoom.rooms.map(\.id), [room.room.id])
        _ = try await send(.deleteRoom(id: room.room.id), api)
        _ = try await send(.disconnectBackend(id: backend.id), api)
    }

    // MARK: The documents agents read, the waitlist, and what needs services that are not here

    func testTheConnectDocumentsArePublicAndKeyFree() async throws {
        let anonymous = client(nil)
        for clientID in AgentClientCatalog.all.map { $0.id } {
            let text = try await send(.connectDocument(clientID: clientID), anonymous)
            XCTAssertGreaterThan(text.count, 100, clientID)
            XCTAssertTrue(text.contains(ConnectKey.placeholder), "\(clientID): the document has nowhere to put the key")
            XCTAssertFalse(text.contains("hv_") && !text.contains(ConnectKey.placeholder), clientID)
        }
        let filled = ConnectKey.fill("Use \(ConnectKey.placeholder) here", key: "hv_abc")
        XCTAssertEqual(filled, "Use hv_abc here")
        let explain = try await send(Endpoint<String>(text: .get, "/explain.md", auth: .none), anonymous)
        XCTAssertFalse(explain.isEmpty)
    }

    func testTheAdminDropsAnEntryFromTheWaitlist() async throws {
        let (admin, _) = try admin()
        let fresh = try await freshMember("waiting")
        // A new sign-up is let in by freshMember; put them back on the waitlist, then drop the entry.
        _ = try await send(.changeAccount(id: fresh.userID, .revoke), admin)
        await expectFailure(403, .yours(), fresh.client, message: "waitlist")
        let dropped = try await send(.dropFromWaitlist(id: fresh.userID), admin)
        XCTAssertEqual(dropped.ok, true)
        let rows = try await inspect("waitlist", [URLQueryItem(name: "user_id", value: "eq.\(fresh.userID)")])
        XCTAssertTrue(rows.isEmpty, "the waitlist entry is still there")
        let (member, _) = self.member(0)
        await expectFailure(403, .dropFromWaitlist(id: fresh.userID), member)
        // And an account the administrator deletes is gone for good.
        let removed = try await send(.deleteAccount(id: fresh.userID), admin)
        XCTAssertEqual(removed.ok, true)
        await expectFailure(401, .yours(), fresh.client)
    }

    func testRoutesThatNeedAServiceThatIsNotHereAnswerPlainly() async throws {
        let api = try await freshMember("sidecar").client
        // The truth sidecar: the person must have chosen a handle first (the Kit knows that refusal), then there is no sidecar.
        let handleFirst = await expectFailure(409, .dismissSidecarProposal(id: "01ZZZZZZZZZZZZZZZZZZZZZZZZ", reason: "no"), api)
        XCTAssertTrue(HVError.api(try XCTUnwrap(handleFirst)).isTruthHandleRequired, "\(String(describing: handleFirst?.body))")
        _ = try await send(.setTruthHandle(unique("sidecar")), api)
        await expectFailure(503, .dismissSidecarProposal(id: "01ZZZZZZZZZZZZZZZZZZZZZZZZ", reason: "no"), api, message: "sidecar")
        // MCP OAuth against a server that has none: the discovery fails with a sentence.
        let base = try requireFakes()
        let oauth = await expectFailure(409, .startMcpOAuth(McpOAuthStartRequest(url: base.appendingPathComponent("mcp").absoluteString, name: "No OAuth")), api, message: "doesn't require authorization")
        report("mcp oauth start against a server with no OAuth", [("status", oauth?.status ?? 0)])
    }
}
