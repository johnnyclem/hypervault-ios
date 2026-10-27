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
