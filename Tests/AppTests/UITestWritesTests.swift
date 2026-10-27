import HyperVaultKit
import XCTest
@testable import HyperVault

/// What the canned server of the UI-test mode remembers (App/Core/UITestWorld+Writes.swift), read back through the Kit's own
/// endpoints, the way the app reads it: a page kept, edited, made public and deleted; a memory edited and forgotten; a vault
/// entry saved, renamed and deleted; a board made and worked on; a note sent and answered. A write that the canned server
/// answers in a shape a screen cannot decode fails here, in seconds, instead of as a sheet that never closes in a journey.
final class UITestWritesTests: XCTestCase {
    private func client(_ scenario: UITestScenario = .signedIn) -> HVClient {
        HVClient(baseURL: UITestWorld.appURL, transport: MockTransport(routes: UITestWorld.routes(for: scenario)), tokens: StaticTokenProvider(), retry: .none)
    }

    // MARK: Pages

    func testAPageIsKeptEditedMadePublicAndDeleted() async throws {
        let api = client()
        let made = try await api.send(.saveArtifact(ArtifactSaveRequest(
            content: "<h1>Spring menu</h1>", title: "Spring menu", mutable: true, visibility: .private
        )))
        XCTAssertEqual(made.slug, "spring-menu-p1")
        XCTAssertTrue(made.mutable)
        XCTAssertEqual(made.message, "Kept. Here's the link.")

        let listed = try await api.send(.artifacts).items
        XCTAssertEqual(listed.first?.slug, made.slug, "The page just kept is the newest.")
        XCTAssertEqual(listed.first?.visibility, .private)
        XCTAssertEqual(listed.count, 4)
        let yours = try await api.send(.yours(filter: .all, limit: 50)).results
        XCTAssertEqual(yours.first?.name, "Spring menu")
        XCTAssertEqual(yours.first?.slug, made.slug)

        let content = try await api.send(.artifactContent(slug: made.slug))
        XCTAssertEqual(content.content, "<h1>Spring menu</h1>")
        XCTAssertTrue(content.mutable)
        let written = try await api.send(.writeArtifact(slug: made.slug, ArtifactWriteRequest(
            content: "<h1>Spring menu, now with soup</h1>", message: "add soup", baseVersionId: content.headVersionId, forceHtml: true
        )))
        XCTAssertNotEqual(written.headVersionId, content.headVersionId)
        let reread = try await api.send(.artifactContent(slug: made.slug))
        XCTAssertEqual(reread.content, "<h1>Spring menu, now with soup</h1>")
        XCTAssertEqual(reread.headVersionId, written.headVersionId)
        let versions = try await api.send(.artifactVersions(slug: made.slug))
        XCTAssertEqual(versions.versions.count, 2)
        XCTAssertEqual(versions.versions.first?.message, "add soup")

        let patched = try await api.send(.setArtifactVisibility(slug: made.slug, to: .public))
        XCTAssertEqual(patched.artifact.visibility, .public)
        let afterPublic = try await api.send(.artifacts).items
        XCTAssertEqual(afterPublic.first?.visibility, .public)

        let deleted = try await api.send(.deleteArtifact(slug: made.slug))
        XCTAssertEqual(deleted.deleted.slug, made.slug)
        let afterDelete = try await api.send(.artifacts).items
        XCTAssertEqual(afterDelete.map(\.slug), ["bakery-landing-page-x1", "trip-to-lisbon-q7", "portfolio-site"])
        let yoursAfter = try await api.send(.yours(filter: .all, limit: 50)).results
        XCTAssertFalse(yoursAfter.contains { $0.name == "Spring menu" })

        // The pages the vault starts with take the same writes.
        _ = try await api.send(.setArtifactVisibility(slug: "trip-to-lisbon-q7", to: .public))
        let base = try await api.send(.artifacts).items.first { $0.slug == "trip-to-lisbon-q7" }
        XCTAssertEqual(base?.visibility, .public)
        _ = try await api.send(.deleteArtifact(slug: "trip-to-lisbon-q7"))
        let left = try await api.send(.yours(filter: .all, limit: 50)).results
        XCTAssertFalse(left.contains { $0.slug == "trip-to-lisbon-q7" })
    }

    func testAnEmptyPageIsRefused() async throws {
        do {
            _ = try await client().send(.saveArtifact(ArtifactSaveRequest(content: "  ")))
            XCTFail("There is nothing to keep.")
        } catch let error as HVError {
            XCTAssertEqual(error.status, 400)
        }
    }

    // MARK: Memory

    func testAMemoryIsEditedAndForgotten() async throws {
        let api = client()
        let before = try await api.send(.memoryList()).memories
        XCTAssertEqual(before.count, 7)

        let page = try await api.send(.memoryPage(id: "m2", branch: "main"))
        XCTAssertEqual(page.memory.title, "Auth decision: passkeys first")
        let request = try XCTUnwrap(MemoryEditRequest.make(
            original: page.memory, title: "Auth decision: passkeys, then email", content: "Passkeys first. Email codes are the fallback.",
            tags: page.memory.tags, message: "", branch: "main"
        ))
        let edited = try await api.send(.memoryEdit(id: "m2", request))
        XCTAssertEqual(edited.title, "Auth decision: passkeys, then email")
        XCTAssertEqual(edited.message, "edit: Auth decision: passkeys, then email")

        let reread = try await api.send(.memoryPage(id: "m2", branch: "main"))
        XCTAssertEqual(reread.memory.title, "Auth decision: passkeys, then email")
        XCTAssertEqual(reread.memory.content, "Passkeys first. Email codes are the fallback.")
        XCTAssertEqual(reread.provenance?.message, "edit: Auth decision: passkeys, then email")
        let list = try await api.send(.memoryList()).memories
        XCTAssertEqual(list.first { $0.id == "m2" }?.title, "Auth decision: passkeys, then email")
        let yours = try await api.send(.yours(filter: .memory, limit: 50)).results
        XCTAssertEqual(yours.first { $0.id == "m2" }?.name, "Auth decision: passkeys, then email")

        let forgotten = try await api.send(.memoryForget(id: "m2", branch: "main"))
        XCTAssertEqual(forgotten.deleted, "m2")
        let after = try await api.send(.memoryList()).memories
        XCTAssertEqual(after.count, 6)
        XCTAssertFalse(after.contains { $0.id == "m2" })
        let yoursAfter = try await api.send(.yours(filter: .memory, limit: 50)).results
        XCTAssertEqual(yoursAfter.map(\.id), ["m1", "m3"])
        do {
            _ = try await api.send(.memoryPage(id: "m2", branch: "main"))
            XCTFail("A forgotten memory is not there.")
        } catch let error as HVError {
            XCTAssertEqual(error.status, 404)
        }

        // The first memory keeps its linked neighbour and page, with the edit on top.
        let first = try await api.send(.memoryPage(id: "m1", branch: "main"))
        XCTAssertEqual(first.related.map(\.id), ["m6"])
        XCTAssertEqual(first.artifacts.map(\.slug), ["trip-plan"])
    }

    // MARK: Logins, cards and keys

    func testAVaultEntryIsSavedRenamedReplacedAndDeletedWithoutItsValueEverComingBack() async throws {
        let api = client()
        let password = "hunter2-correct-horse"
        let value = VaultItems.serialize(.login, ["url": "https://gitlab.com", "username": "sam@example.com", "password": password])
        let made = try await api.send(.createVaultSecret(name: "gitlab.com", kind: .login, value: value, description: "Side project"))
        XCTAssertEqual(made.secret.name, "gitlab.com")
        XCTAssertEqual(made.secret.kind, .login)
        XCTAssertEqual(made.secret.hint, "sam@example.com", "The row says who the login is for and nothing else.")
        XCTAssertEqual(made.secret.description, "Side project")

        let listed = try await api.send(.vaultSecrets).secrets
        XCTAssertEqual(listed.count, 7)
        XCTAssertEqual(listed.last?.name, "gitlab.com")
        let grants = try await api.send(.secretGrants(name: "gitlab.com")).grants
        XCTAssertEqual(grants.map(\.apiKeyId), ["k1"])

        do {
            _ = try await api.send(.createVaultSecret(name: "gitlab.com", kind: .login, value: value))
            XCTFail("A name is taken once.")
        } catch let error as HVError {
            XCTAssertEqual(error.status, 409)
        }

        let renamed = try await api.send(.updateVaultSecret(name: "gitlab.com", newName: "gitlab-work", description: ""))
        XCTAssertEqual(renamed.secret.name, "gitlab-work")
        XCTAssertNil(renamed.secret.description, "An empty note clears it.")
        let replaced = try await api.send(.updateVaultSecret(
            name: "gitlab-work", value: VaultItems.serialize(.login, ["url": "https://gitlab.com", "username": "sam.new@example.com", "password": "another-one-9"])
        ))
        XCTAssertEqual(replaced.secret.hint, "sam.new@example.com")

        let everything = try await api.send(.vaultSecrets).secrets
        let encoded = try String(decoding: JSONEncoder().encode(everything), as: UTF8.self)
        XCTAssertFalse(encoded.contains(password), "The list never carries a value.")
        XCTAssertFalse(encoded.contains("another-one-9"))

        _ = try await api.send(.deleteVaultSecret(name: "gitlab-work"))
        let after = try await api.send(.vaultSecrets).secrets
        XCTAssertEqual(after.map(\.name), ["github.com", "visa-4242", "amex-0005", "contact", "home", "stripe-restricted-key"])
        do {
            _ = try await api.send(.deleteVaultSecret(name: "gitlab-work"))
            XCTFail("An entry that is gone cannot be deleted again.")
        } catch let error as HVError {
            XCTAssertEqual(error.status, 404)
        }
    }

    func testACardEntryShowsItsBrandAndLastFourDigits() async throws {
        let api = client()
        let value = VaultItems.serialize(.card, ["number": "4242 4242 4242 4242", "expMonth": "12", "expYear": "2030"])
        let made = try await api.send(.createVaultSecret(name: "visa-travel", kind: .card, value: value))
        XCTAssertEqual(made.secret.hint, "Visa \u{2022}\u{2022}\u{2022}\u{2022} 4242")
    }

    // MARK: Task boards

    func testABoardIsMadeAndWorkedOn() async throws {
        let api = client()
        let made = try await api.send(.createTaskBoard(TaskBoardDraft(title: "Garden shed", plan: "- Order the wood\n- Buy screws")))
        XCTAssertEqual(made.project, "garden-shed")
        XCTAssertEqual(made.taskCount, 2)
        XCTAssertEqual(made.board.slug, "tasks-garden-shed")

        let boards = try await api.send(.taskBoards).boards
        XCTAssertEqual(boards.map(\.project), ["garden-shed", "eurorack-choir", "garden"], "The newest board is first.")
        XCTAssertEqual(boards.first?.displayTitle, "Garden shed")

        let fetched = try await api.send(.taskBoard(project: "garden-shed"))
        let board = try XCTUnwrap(fetched.board)
        XCTAssertEqual(board.tasks.map(\.title), ["Order the wood", "Buy screws"])
        XCTAssertEqual(board.version, 1)

        let added = try await api.send(TaskBoardEdit.add(title: "Paint it", parent: nil, tempID: "tmp-1").endpoint(project: "garden-shed", expectedVersion: board.version))
        XCTAssertEqual(added.task?.title, "Paint it")
        XCTAssertEqual(added.board?.tasks.count, 3)
        XCTAssertEqual(added.board?.version, 2)
        let taskID = try XCTUnwrap(added.task?.id)

        let done = try await api.send(TaskBoardEdit.complete(taskID: taskID, note: nil).endpoint(project: "garden-shed", expectedVersion: 2))
        XCTAssertNil(done.board, "Completing answers a summary, and the screen reads the list again.")
        XCTAssertEqual(done.summary?.done, 1)
        let summary = try await api.send(.taskBoardSummary(project: "garden-shed")).summary
        XCTAssertEqual(summary.total, 3)
        XCTAssertEqual(summary.done, 1)
        let rereadFetch = try await api.send(.taskBoard(project: "garden-shed"))
        let reread = try XCTUnwrap(rereadFetch.board)
        XCTAssertEqual(reread.tasks.first { $0.id == taskID }?.status, .done)

        let cancelled = try await api.send(TaskBoardEdit.setStatus(taskID: reread.tasks[0].id, to: .cancelled).endpoint(project: "garden-shed", expectedVersion: reread.version))
        XCTAssertEqual(cancelled.task?.status, .cancelled)

        // The boards the vault starts with read as they always did.
        let choir = try await api.send(.taskBoardSummary(project: "eurorack-choir")).summary
        XCTAssertEqual(choir.total, 7)
        XCTAssertEqual(choir.progress, 29)
        XCTAssertEqual(choir.claimed.count, 1)
        let garden = try await api.send(.taskBoardSummary(project: "garden")).summary
        XCTAssertEqual(garden.total, 4)
        XCTAssertEqual(garden.progress, 25)
    }

    // MARK: Mail

    func testANoteIsSentAndAThreadIsAnswered() async throws {
        let api = client()
        let sent = try await api.send(.mailSend(subject: "Shopping", text: "Buy oat milk."))
        XCTAssertEqual(sent.message.text, "Buy oat milk.")
        XCTAssertEqual(sent.message.author.type, .owner)

        let outbox = try await api.send(.mailMessages(box: .sent)).messages
        XCTAssertEqual(outbox.map(\.subject), ["Shopping"])
        let inbox = try await api.send(.mailMessages(box: .inbox)).messages
        XCTAssertEqual(inbox.count, 4, "What the person sends is not in the inbox.")
        let thread = try await api.send(.mailThread(threadId: sent.threadId)).messages
        XCTAssertEqual(thread.map(\.text), ["Buy oat milk."])

        let reply = try await api.send(.mailReply(id: "m1", text: "Friday is perfect."))
        XCTAssertEqual(reply.threadId, MailPreviewData.threadID)
        XCTAssertEqual(reply.message.subject, "Re: Weekly plan")
        let talk = try await api.send(.mailThread(threadId: MailPreviewData.threadID)).messages
        XCTAssertEqual(talk.count, 4)
        XCTAssertEqual(talk.last?.text, "Friday is perfect.")
        let outboxAfter = try await api.send(.mailMessages(box: .sent)).messages
        XCTAssertEqual(outboxAfter.count, 2)
    }

    func testEachLaunchStartsAsTheFirstOneDid() async throws {
        _ = try await client().send(.saveArtifact(ArtifactSaveRequest(content: "<p>x</p>", title: "One")))
        let fresh = try await client().send(.artifacts).items
        XCTAssertEqual(fresh.count, 3)
        _ = try await client().send(.memoryForget(id: "m1", branch: "main"))
        let memories = try await client().send(.memoryList()).memories
        XCTAssertEqual(memories.count, 7)
    }

    // MARK: Rooms

    func testARoomIsMadeRenamedGivenAMemberTakenOneAndDeleted() async throws {
        let api = client()
        let before = try await api.send(.rooms)
        XCTAssertEqual(before.map(\.id), ["r1", "r2"])

        let made = try await api.send(.createRoom(title: "Garden club", members: [ChatRoomMemberDraft(backendID: "b1", handle: "claude", roleBrief: "The plan.")]))
        XCTAssertEqual(made.room.id, "rn1")
        XCTAssertEqual(made.room.title, "Garden club")
        XCTAssertEqual(made.members.map(\.handle), ["claude"])
        let listed = try await api.send(.rooms)
        XCTAssertEqual(listed.first?.id, "rn1", "A room just made is the newest.")
        XCTAssertEqual(listed.first?.members.first?.roleBrief, "The plan.")

        let detail = try await api.send(.room(id: "rn1"))
        XCTAssertEqual(detail.room.title, "Garden club")
        XCTAssertEqual(detail.members.count, 1)
        XCTAssertTrue(detail.messages.isEmpty)

        _ = try await api.send(.renameRoom(id: "rn1", title: "Garden club 2026"))
        let renamed = try await api.send(.room(id: "rn1"))
        XCTAssertEqual(renamed.room.title, "Garden club 2026")

        let added = try await api.send(.addRoomMembers(roomID: "rn1", members: [ChatRoomMemberDraft(backendID: "b2", handle: "gpt")]))
        XCTAssertEqual(added.map(\.handle), ["gpt"])
        let both = try await api.send(.room(id: "rn1")).members.map(\.handle)
        XCTAssertEqual(both, ["claude", "gpt"])
        do {
            _ = try await api.send(.addRoomMembers(roomID: "rn1", members: [ChatRoomMemberDraft(backendID: "b2", handle: "gpt")]))
            XCTFail("A handle taken is refused.")
        } catch let error as HVError {
            XCTAssertEqual(error.status, 409)
        }

        _ = try await api.send(.removeRoomMember(roomID: "rn1", memberID: try XCTUnwrap(added.first).id))
        let left = try await api.send(.room(id: "rn1")).members.map(\.handle)
        XCTAssertEqual(left, ["claude"])

        _ = try await api.send(.deleteRoom(id: "rn1"))
        let after = try await api.send(.rooms)
        XCTAssertEqual(after.map(\.id), ["r1", "r2"])
    }

    // MARK: Truth

    func testAUVIsAssertedIntoTheLedgerAndTheOutOfDateItemsAreResolved() async throws {
        let api = client()
        let before = try await api.send(.truth(ledger: "team"))
        XCTAssertEqual(before.sections.unverified.count, 1)

        var draft = TruthAssertDraft(type: .uv)
        draft.text = "Retries are bounded by the budget."
        draft.basis = "The retry design doc."
        let made = try await api.send(.assertTruth(draft, ledger: "team"))
        XCTAssertEqual(made.line?.id, "01M2UITEST0000000000000001")
        XCTAssertEqual(made.line?.type, .uv)

        let after = try await api.send(.truth(ledger: "team"))
        XCTAssertEqual(after.sections.unverified.count, 2)
        XCTAssertTrue(after.sections.unverified.contains { $0.id == "01M2UITEST0000000000000001" })
        XCTAssertEqual(after.summary.total, before.summary.total + 1)

        var tb = TruthAssertDraft(type: .tb)
        tb.text = "Writes are retried twice."
        tb.evidence = [TruthEvidenceDraft(kind: .file, ref: "src/retry.ts")]
        _ = try await api.send(.assertTruth(tb, ledger: "team"))
        let standing = try await api.send(.truth(ledger: "team")).sections.standing
        XCTAssertTrue(standing.contains { $0.line.id == "01M2UITEST0000000000000002" })

        let worklist = try await api.send(.truthStale())
        XCTAssertEqual(worklist.items.map(\.key), ["memory:mem1", "memory:mem2", "artifact:a-retry"])
        XCTAssertEqual(worklist.items.first?.edges.first?.successor?.id, "E9")
        XCTAssertNil(worklist.items[1].edges.first?.successor)
        let moved = worklist.items[0]
        _ = try await api.send(.resolveTruthStale(.relink, item: try XCTUnwrap(moved.item), entries: ["E1"], to: ["E9"], ledger: "team"))
        _ = try await api.send(.resolveTruthStale(.reaffirm, item: try XCTUnwrap(worklist.items[1].item), entries: ["E2"], ledger: "team"))
        let left = try await api.send(.truthStale())
        XCTAssertEqual(left.items.map(\.key), ["artifact:a-retry"])
        _ = try await api.send(.resolveTruthStale(.unlink, item: try XCTUnwrap(left.items[0].item), entries: ["E3"], ledger: "team"))
        let none = try await api.send(.truthStale())
        XCTAssertTrue(none.items.isEmpty)
        do {
            _ = try await api.send(.resolveTruthStale(.unlink, item: try XCTUnwrap(left.items[0].item), entries: ["E3"], ledger: "team"))
            XCTFail("An item that was resolved is not out of date any more.")
        } catch let error as HVError {
            XCTAssertEqual(error.status, 404)
        }
    }

    // MARK: Chat

    func testAChatIsBegunByItsFirstMessageAndDeleted() async throws {
        let api = client()
        let before = try await api.send(.conversations)
        XCTAssertEqual(before.count, 7)

        let first = try await api.send(.chat(backendID: "b1", message: "Plan the balcony garden", options: ChatSendOptions(smartContext: true)))
        XCTAssertEqual(first.conversationID, "n1")
        XCTAssertEqual(first.reply.content, "Noted: Plan the balcony garden")
        let listed = try await api.send(.conversations)
        XCTAssertEqual(listed.count, 8)
        XCTAssertEqual(listed.first?.id, "n1", "A chat just begun is the newest.")
        XCTAssertEqual(listed.first?.title, "Plan the balcony garden")

        // The next turn goes on in the same chat.
        let second = try await api.send(.chat(backendID: "b1", message: "And the pots", conversationID: "n1", options: ChatSendOptions(smartContext: true)))
        XCTAssertEqual(second.conversationID, "n1")
        let detail = try await api.send(.conversation(id: "n1"))
        XCTAssertEqual(detail.messages.map(\.role), [ChatRole.user, .assistant, .user, .assistant])
        XCTAssertEqual(detail.messages.last?.content, "Noted: And the pots")

        // A chat the vault starts with takes a turn without becoming a new one.
        let old = try await api.send(.chat(backendID: "b1", message: "Add a fado night", conversationID: "c1", options: ChatSendOptions(smartContext: true)))
        XCTAssertEqual(old.conversationID, "c1")
        let still = try await api.send(.conversations)
        XCTAssertEqual(still.count, 8)

        _ = try await api.send(.deleteConversation(id: "n1"))
        _ = try await api.send(.deleteConversation(id: "c2"))
        let after = try await api.send(.conversations)
        XCTAssertEqual(after.map(\.id), ["c1", "c3", "c4", "c5", "c6", "c7"])
        do {
            _ = try await api.send(.conversation(id: "n1"))
            XCTFail("A deleted chat is gone.")
        } catch let error as HVError {
            XCTAssertEqual(error.status, 404)
        }
    }

    // MARK: Dreams and Digest

    func testDreamsAreAcceptedAndRejectedOneByOneAndTheQueueFollows() async throws {
        let api = client()
        let before = try await api.send(.dreamQueue)
        XCTAssertEqual(before.pendingCount, 4)
        XCTAssertEqual(before.runs.first?.connections.map(\.id), ["d1", "d2", "d3", "d4"])

        let accepted = try await api.send(.dreamDecide(connection: "d1", .accept))
        XCTAssertEqual(accepted.accepted, 1)
        XCTAssertEqual(accepted.rejected, 0)
        XCTAssertTrue(accepted.failures.isEmpty)
        let rejected = try await api.send(.dreamDecide(connection: "d3", .reject))
        XCTAssertEqual(rejected.rejected, 1)

        let after = try await api.send(.dreamQueue)
        XCTAssertEqual(after.pendingCount, 2)
        XCTAssertEqual(after.runs.first?.connections.map(\.id), ["d2", "d4"])

        let rest = try await api.send(.dreamDecide(run: "run1", .reject))
        XCTAssertEqual(rest.rejected, 2, "A verdict on a run reaches only the connections still waiting.")
        let empty = try await api.send(.dreamQueue)
        XCTAssertTrue(empty.runs.isEmpty)
        XCTAssertEqual(empty.pendingCount, 0)

        do {
            _ = try await api.send(.dreamDecide(connection: "nope", .accept))
            XCTFail("A connection nobody proposed should be refused.")
        } catch let error as HVError {
            XCTAssertEqual(error.status, 404)
        }
    }

    func testASplitIsAppliedAndTheMemoryIsReplacedByItsParts() async throws {
        let api = client()
        let queue = try await api.send(.digestQueue)
        XCTAssertEqual(queue.runs.map(\.id), ["dg1"])
        XCTAssertEqual(queue.runs.first?.segments.count, 3)

        let decision = try await api.send(.digestDecide(run: "dg1", .accept))
        XCTAssertTrue(decision.applied)
        XCTAssertEqual(decision.created, 3)
        XCTAssertEqual(decision.links, 3)

        let after = try await api.send(.digestQueue)
        XCTAssertTrue(after.runs.isEmpty)
        let memories = try await api.send(.memoryList()).memories
        XCTAssertFalse(memories.contains { $0.id == "m3" }, "The memory that was split is replaced.")
        XCTAssertEqual(memories.filter { $0.id.hasPrefix("m3-part") }.map(\.title), ["Budget is set at 40k", "Ship in March", "Hire one more engineer"])
        XCTAssertEqual(memories.count, 9)
        let part = try await api.send(.memoryPage(id: "m3-part2", branch: "main"))
        XCTAssertEqual(part.memory.title, "Ship in March")

        do {
            _ = try await api.send(.digestDecide(run: "dg1", .accept))
            XCTFail("A split that was applied is not proposed again.")
        } catch let error as HVError {
            XCTAssertEqual(error.status, 404)
        }
    }

    func testAKeptWholeMemoryStaysAsItWas() async throws {
        let api = client()
        let decision = try await api.send(.digestDecide(run: "dg1", .reject))
        XCTAssertFalse(decision.applied)
        XCTAssertEqual(decision.created, 0)
        let memories = try await api.send(.memoryList()).memories
        XCTAssertTrue(memories.contains { $0.id == "m3" })
        XCTAssertEqual(memories.count, 7)
    }

    // MARK: Your address

    func testAnAddressTakesANewLookAndHomePageAndTheListRemembersThem() async throws {
        let net = MockTransport(routes: UITestWorld.routes(for: .signedIn))
        let api = HVClient(baseURL: UITestWorld.appURL, transport: net, tokens: StaticTokenProvider(), retry: .none)
        let tables = AccountRest(
            client: HVClient(baseURL: UITestWorld.supabaseURL, transport: net, tokens: StaticTokenProvider(), retry: .none),
            anonKey: UITestWorld.anonKey
        )
        let userID = UITestWorld.user.id
        let before = try await RealmDirectory.snapshot(rest: tables, userID: userID)
        let second = try XCTUnwrap(before.claims.last)
        XCTAssertEqual(second.host, "nova.cleon.wiki")
        XCTAssertNil(second.theme)

        let themed = try await api.send(.setRealmTheme(subdomain: second.subdomain, base: second.baseDomain, theme: "newsprint"))
        XCTAssertEqual(themed.theme, "newsprint")
        XCTAssertNil(themed.defaultArtifact)
        XCTAssertNil(themed.warning)

        let homed = try await api.send(.setRealmHome(subdomain: second.subdomain, base: second.baseDomain, artifactSlug: "trip-to-lisbon-q7"))
        XCTAssertEqual(homed.theme, "newsprint", "Setting the home page leaves the look alone.")
        XCTAssertEqual(homed.defaultArtifact, "trip-to-lisbon-q7")
        XCTAssertNotNil(homed.warning, "A private page as the home page comes with the server's warning.")

        let after = try await RealmDirectory.snapshot(rest: tables, userID: userID)
        XCTAssertEqual(after.claims.last?.theme, "newsprint")
        XCTAssertEqual(after.claims.last?.defaultArtifactSlug, "trip-to-lisbon-q7")
        XCTAssertEqual(after.claims.first?.theme, "glassmorphism", "The other address is as it was.")

        let cleared = try await api.send(.setRealmTheme(subdomain: second.subdomain, base: second.baseDomain, theme: nil))
        XCTAssertNil(cleared.theme)
        XCTAssertEqual(cleared.defaultArtifact, "trip-to-lisbon-q7")
        // A fresh launch starts as the first one did.
        let fresh = MockTransport(routes: UITestWorld.routes(for: .signedIn))
        let freshTables = AccountRest(
            client: HVClient(baseURL: UITestWorld.supabaseURL, transport: fresh, tokens: StaticTokenProvider(), retry: .none),
            anonKey: UITestWorld.anonKey
        )
        let again = try await RealmDirectory.snapshot(rest: freshTables, userID: userID)
        XCTAssertNil(again.claims.last?.defaultArtifactSlug)
    }

    // MARK: The record of writes

    func testTheWriteLogNamesTheFieldsAndHidesWhatCouldBeASecret() throws {
        var request = URLRequest(url: URL(string: "https://uitest.hypervault.invalid/api/secrets?branch=main")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "name": "gitlab.com", "value": "{\"password\":\"hunter2\"}", "password": "hunter2", "uses": 1, "enabled": true,
            "tags": ["a", "b"], "nested": ["x": 1],
            "task": ["title": "Paint it"], "patch": ["status": "done", "password": "hunter2"],
            "tasks": [["title": "One"], ["title": "Two"]], "deep": ["a": ["b": ["c": 1]]],
        ])
        let line = UITestWriteLog.describe(request)
        let entry = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(entry["method"] as? String, "POST")
        XCTAssertEqual(entry["path"] as? String, "/api/secrets")
        XCTAssertEqual(entry["query"] as? String, "branch=main")
        let fields = try XCTUnwrap(entry["fields"] as? [String: String])
        XCTAssertEqual(fields["name"], "gitlab.com")
        XCTAssertEqual(fields["value"], "<redacted>")
        XCTAssertEqual(fields["password"], "<redacted>")
        XCTAssertEqual(fields["uses"], "1")
        XCTAssertEqual(fields["enabled"], "true")
        XCTAssertEqual(fields["tags"], "[a|b]")
        XCTAssertEqual(fields["nested"], "{x=1}")
        XCTAssertEqual(fields["task"], "{title=Paint it}", "A small object is told with its values, so a journey can see what was sent.")
        XCTAssertEqual(fields["patch"], "{password=<redacted>,status=done}")
        XCTAssertEqual(fields["tasks"], "[{title=One}|{title=Two}]")
        XCTAssertEqual(fields["deep"], "{a={b={c}}}", "Below two levels only the names are kept.")
        XCTAssertFalse(line.contains("hunter2"), "A password never reaches the record.")
    }
}
