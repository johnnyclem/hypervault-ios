#if DEBUG
import Foundation
import HyperVaultKit

/// The canned server's memory of what a journey did: a page kept, edited, shared or deleted, a memory edited or forgotten,
/// a login saved or renamed, a board made and a task added or ticked, a note sent. Each answers in the shape the real route
/// sends, so the screen that wrote it reads it back the way it reads the real one.
///
/// Every call of `writeRoutes` builds a fresh set of stores, so each launch starts as the first one did, and the unit tests
/// (`UITestWritesTests`) run the same routes through the Kit's own endpoints. These routes come before the static ones in
/// `UITestWorld.routes(for:)`: where a route here answers a path, it answers for the whole launch.
extension UITestWorld {
    static func writeRoutes() -> [MockRoute] {
        let memories = UITestMemories()
        let vault = UITestVault(memories: memories)
        let secrets = UITestSecrets()
        let boards = UITestBoards()
        let mail = UITestMail()
        let realms = UITestRealms()
        let dreams = UITestDreams()
        let digest = UITestDigest(memories: memories)
        let chats = UITestChats()
        let truth = UITestTruth()
        let rooms = UITestRooms()
        let shares = UITestShares()
        return pageRoutes(vault) + memoryRoutes(memories) + secretRoutes(secrets) + boardRoutes(boards) + mailRoutes(mail)
            + realmRoutes(realms) + thinkRoutes(dreams, digest) + chatRoutes(chats) + truthRoutes(truth)
            + roomRoutes(rooms) + shareRoutes(shares)
    }

    // MARK: Helpers

    /// A JSON text as a value. The texts parsed here are the app's own canned answers, so a failure is a mistake to fix.
    static func parse(_ text: String) -> JSONValue {
        (try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))) ?? .null
    }

    /// The request's JSON object body, as values.
    static func body(_ request: URLRequest) -> [String: JSONValue] {
        guard let data = request.httpBody, let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return [:] }
        return value.object ?? [:]
    }

    /// The last path component, taken apart from the query and decoded (`github.com`, `m2`).
    static func lastComponent(_ request: URLRequest) -> String {
        request.url?.lastPathComponent ?? ""
    }

    /// The path components after `prefix` (`/api/secrets/github.com/grants` after `/api/secrets` is `github.com`, `grants`).
    static func components(_ request: URLRequest, after prefix: String) -> [String] {
        let path = request.url?.path ?? ""
        guard path.hasPrefix(prefix) else { return [] }
        return path.dropFirst(prefix.count).split(separator: "/").map(String.init)
    }

    static func notFound(_ what: String) -> HTTPResponse {
        reply(.object(["error": .string(what)]), status: 404)
    }

    static func empty(status: Int = 204) -> HTTPResponse {
        HTTPResponse(status: status, headers: [:], data: Data())
    }

    static func slug(from text: String, fallback: String = "note") -> String {
        let words = text.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) })
        let joined = words.prefix(6).joined(separator: "-")
        return joined.isEmpty ? fallback : joined
    }

    // MARK: Pages: Yours, the Library and a page

    /// What is kept, and the pages a journey keeps, edits and deletes. Yours and the Library read the same list, so a page
    /// kept in one is in the other.
    private static func pageRoutes(_ vault: UITestVault) -> [MockRoute] {
        [
            MockRoute(.get, "/api/yours") { request in yours(request: request, things: vault.things) },
            MockRoute(.get, "/api/artifacts") { _ in reply(raw: vault.artifactsJSON()) },
            MockRoute(.post, "/api/save") { request in
                let sent = body(request)
                let content = sent["content"]?.string ?? ""
                guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return reply(.object(["error": .string("content is required.")]), status: 400)
                }
                let visibility = sent["visibility"]?.string ?? "private"
                let made = vault.keep(
                    content: content, title: sent["title"]?.string, visibility: visibility,
                    mutable: sent["mutable"]?.bool ?? false
                )
                return reply(.object([
                    "url": .string(made.url), "slug": .string(made.slug), "is_jsx": .bool(false),
                    "visibility": .string(visibility), "mutable": .bool(made.mutable), "duplicate": .bool(false),
                    "connections": .object(["manual": .int(0), "auto": .int(0)]),
                    "message": .string("Kept. Here's the link."),
                ]), status: 201)
            },
            MockRoute(.patch, "/api/artifacts") { request in
                let sent = body(request)
                guard let slug = sent["slug"]?.string, let next = sent["visibility"]?.string,
                      let page = vault.setVisibility(slug: slug, to: next)
                else { return notFound("No such page.") }
                return reply(.object([
                    "artifact": .object([
                        "id": .string(page.id), "slug": .string(slug), "title": .string(page.title),
                        "visibility": .string(next), "icon": .null,
                    ]),
                    "message": .string(next == "public" ? "Anyone with the link can open it." : "Only you and people you add can open it."),
                ]))
            },
            MockRoute(.delete, "/api/artifacts") { request in
                guard let slug = body(request)["slug"]?.string, let gone = vault.delete(slug: slug) else {
                    return notFound("No such page.")
                }
                return reply(.object([
                    "deleted": .object(["id": .string(gone.id), "slug": .string(slug), "title": .string(gone.title)]),
                    "message": .string("Deleted."),
                ]))
            },
            MockRoute(.get, "/api/artifacts/*") { request in
                let parts = components(request, after: "/api/artifacts")
                guard parts.count >= 2, let page = vault.page(slug: parts[0]) else { return artifactDetail(request) }
                switch parts[1] {
                case "content":
                    return reply(.object([
                        "slug": .string(page.slug), "title": .string(page.title), "content": .string(page.content),
                        "is_jsx": .bool(false), "mutable": .bool(page.mutable), "content_hash": .string("h-\(page.head)"),
                        "head_version_id": .string(page.head),
                    ]))
                case "source":
                    return reply(.object(["content": .string(page.content)]))
                case "versions":
                    return reply(vault.versionsJSON(slug: page.slug))
                default:
                    return artifactDetail(request)
                }
            },
            MockRoute(.put, "/api/artifacts/*") { request in
                let parts = components(request, after: "/api/artifacts")
                let sent = body(request)
                guard parts.count == 2, parts[1] == "content", let content = sent["content"]?.string,
                      let written = vault.write(slug: parts[0], content: content, message: sent["message"]?.string)
                else { return notFound("No such page.") }
                return reply(.object([
                    "url": .string(written.url), "slug": .string(parts[0]), "is_jsx": .bool(false), "unchanged": .bool(false),
                    "rebased": .bool(false), "forced": .bool(false),
                    "version": .object([
                        "id": .string(written.head), "parent_version_id": written.parent.map(JSONValue.string) ?? .null,
                        "message": .string(written.message), "created_at": .string(date(1)), "is_head": .bool(true),
                    ]),
                    "head_version_id": .string(written.head),
                    "message": .string("Saved a new version."),
                ]))
            },
            MockRoute(.get, "/a/*") { request in
                let slug = lastComponent(request)
                let html = vault.page(slug: slug)?.content ?? pageHTML
                return HTTPResponse(status: 200, headers: ["content-type": "text/html; charset=utf-8"], data: Data(html.utf8))
            },
        ]
    }

    // MARK: Memory

    /// The memories, a memory's page, an edit of it and forgetting it.
    private static func memoryRoutes(_ memories: UITestMemories) -> [MockRoute] {
        [
            MockRoute(.get, "/api/memories") { request in
                let query = request.queryValue("q")
                if let query, !query.isEmpty { return reply(raw: MemoryPreviewData.recall) }
                return reply(raw: memories.listJSON())
            },
            MockRoute(.get, "/api/memories/*") { request in
                let parts = components(request, after: "/api/memories")
                guard let id = parts.first else { return notFound("Not found") }
                if parts.count == 2, parts[1] == "history" { return reply(raw: MemoryPreviewData.history) }
                guard let page = memories.pageJSON(id: id) else { return notFound("That memory is not here.") }
                return reply(raw: page)
            },
            MockRoute(.patch, "/api/memories/*") { request in
                let id = lastComponent(request)
                let sent = body(request)
                guard let edited = memories.edit(
                    id: id, title: sent["title"]?.string, content: sent["content"]?.string,
                    tags: sent["tags"]?.array?.compactMap(\.string), message: sent["message"]?.string
                ) else { return notFound("That memory is not here.") }
                return reply(edited)
            },
            MockRoute(.delete, "/api/memories/*") { request in
                let id = lastComponent(request)
                guard memories.forget(id: id) else { return notFound("That memory is not here.") }
                return reply(.object([
                    "deleted": .string(id), "branch": .string("main"), "message": .string("Forgotten. Its history stays, so you can bring it back."),
                ]))
            },
        ]
    }

    // MARK: Logins, cards and keys

    /// The vault entries, saving one, renaming it, replacing its value and deleting it. A value is read to make the hint and
    /// never kept or sent back.
    private static func secretRoutes(_ secrets: UITestSecrets) -> [MockRoute] {
        [
            MockRoute(.get, "/api/secrets") { _ in reply(.object(["secrets": .array(secrets.rows())])) },
            MockRoute(.post, "/api/secrets") { request in
                let sent = body(request)
                guard let name = sent["name"]?.string, let value = sent["value"]?.string else {
                    return reply(.object(["error": .string("name and value are required.")]), status: 400)
                }
                let kind = sent["kind"]?.string ?? "opaque"
                switch secrets.create(name: name, kind: kind, value: value, description: sent["description"]?.string) {
                case .success(let row): return reply(.object(["secret": row]), status: 201)
                case .failure(let problem): return reply(.object(["error": .string(problem.message)]), status: problem.status)
                }
            },
            MockRoute(.get, "/api/secrets/*") { request in
                let parts = components(request, after: "/api/secrets")
                if parts.count == 2, parts[1] == "grants" {
                    return reply(raw: #"{"grants":[{"id":"g1","api_key_id":"k1","created_at":"2026-10-24T10:00:00Z"}]}"#)
                }
                return notFound("No such secret.")
            },
            MockRoute(.patch, "/api/secrets/*") { request in
                let parts = components(request, after: "/api/secrets")
                let sent = body(request)
                guard let name = parts.first else { return notFound("No such secret.") }
                switch secrets.update(name: name, newName: sent["new_name"]?.string, description: sent["description"]?.string, value: sent["value"]?.string) {
                case .success(let row): return reply(.object(["secret": row]))
                case .failure(let problem): return reply(.object(["error": .string(problem.message)]), status: problem.status)
                }
            },
            MockRoute(.delete, "/api/secrets/*") { request in
                let parts = components(request, after: "/api/secrets")
                guard let name = parts.first, parts.count == 1, secrets.delete(name: name) else { return notFound("No such secret.") }
                return empty()
            },
        ]
    }

    // MARK: Task boards

    private static func boardRoutes(_ boards: UITestBoards) -> [MockRoute] {
        [
            MockRoute(.get, "/api/taskboards") { _ in reply(.object(["boards": .array(boards.listings()), "schema": .string("x")])) },
            MockRoute(.post, "/api/taskboards") { request in
                let sent = body(request)
                let title = sent["title"]?.string ?? ""
                guard !title.trimmingCharacters(in: .whitespaces).isEmpty else {
                    return reply(.object(["error": .string("title is required.")]), status: 400)
                }
                let tasks = (sent["tasks"]?.array ?? []).compactMap { $0["title"]?.string }
                let made = boards.create(title: title, tasks: tasks)
                return reply(.object([
                    "project": .string(made.project),
                    "data": .object(["slug": .string("tasklist-\(made.project)"), "url": .string(appURL.appendingPathComponent("a/tasklist-\(made.project)").absoluteString)]),
                    "board": .object(["slug": .string(made.slug), "url": .string(appURL.appendingPathComponent("a/\(made.slug)").absoluteString)]),
                    "version": .int(made.version), "taskCount": .int(tasks.count),
                    "message": .string("Board created."),
                ]), status: 201)
            },
            MockRoute(.get, "/api/tasklists/*") { request in
                let parts = components(request, after: "/api/tasklists")
                guard let project = parts.first, let board = boards.board(project) else { return notFound("No such board.") }
                if parts.count == 2, parts[1] == "summary" {
                    return reply(.object(["slug": .string(board.slug), "summary": boards.summary(project) ?? .null]))
                }
                if parts.count == 3, parts[1] == "tasks", let task = boards.task(project, id: parts[2]) {
                    return reply(.object(["task": task]))
                }
                guard parts.count == 1 else { return notFound("Not found") }
                return reply(.object(["slug": .string(board.slug), "tasklist": boards.boardJSON(project) ?? .null]))
            },
            MockRoute(.post, "/api/tasklists/*") { request in
                let parts = components(request, after: "/api/tasklists")
                let sent = body(request)
                guard parts.count >= 2, parts[1] == "tasks", let project = parts.first, boards.board(project) != nil else {
                    return notFound("No such board.")
                }
                if parts.count == 2 {
                    guard let title = sent["task"]?["title"]?.string else {
                        return reply(.object(["error": .string("task.title is required.")]), status: 400)
                    }
                    let task = boards.add(project, title: title, parent: sent["task"]?["parent"]?.string)
                    return reply(.object(["task": task, "tasklist": boards.boardJSON(project) ?? .null, "summary": boards.summary(project) ?? .null]), status: 201)
                }
                guard parts.count == 4 else { return notFound("Not found") }
                let id = parts[2]
                switch parts[3] {
                case "complete":
                    guard boards.setStatus(project, id: id, to: "done", note: sent["note"]?.string) != nil else { return notFound("No such task.") }
                    return reply(.object(["summary": boards.summary(project) ?? .null, "message": .string("Done.")]))
                case "claim":
                    let release = sent["release"]?.bool == true
                    guard let task = boards.claim(project, id: id, release: release) else { return notFound("No such task.") }
                    return reply(.object(["task": task, "tasklist": boards.boardJSON(project) ?? .null, "summary": boards.summary(project) ?? .null]))
                default:
                    return notFound("Not found")
                }
            },
            MockRoute(.patch, "/api/tasklists/*") { request in
                let parts = components(request, after: "/api/tasklists")
                let sent = body(request)
                guard parts.count == 3, parts[1] == "tasks", let project = parts.first, let patch = sent["patch"]?.object,
                      let task = boards.patch(project, id: parts[2], patch: patch)
                else { return notFound("No such task.") }
                return reply(.object(["task": task, "tasklist": boards.boardJSON(project) ?? .null, "summary": boards.summary(project) ?? .null]))
            },
        ]
    }

    // MARK: Sharing a page

    /// Who else can open a page: the Bakery page starts with one person, and a person is added by email and removed.
    private static func shareRoutes(_ shares: UITestShares) -> [MockRoute] {
        [
            MockRoute(.get, "/api/shares") { request in
                reply(.object([
                    "shares": .array(shares.people(of: request.queryValue("artifact") ?? "")),
                    "roles": .array([.string("view"), .string("use"), .string("edit")]), "roles_enforced": .bool(true),
                ]))
            },
            MockRoute(.post, "/api/shares") { request in
                let sent = body(request)
                guard let slug = sent["artifact"]?.string, let email = sent["email"]?.string, let role = sent["role"]?.string else {
                    return reply(.object(["error": .string("artifact, email and role are required.")]), status: 400)
                }
                shares.add(slug: slug, email: email, role: role)
                return reply(.object(["role": .string(role), "message": .string("Shared with \(email).")]), status: 201)
            },
            MockRoute(.delete, "/api/shares") { request in
                guard let id = body(request)["share_id"]?.string, shares.remove(id: id) else { return notFound("No such share.") }
                return reply(.object(["message": .string("Access removed.")]))
            },
        ]
    }

    // MARK: Rooms

    /// The rooms: one is made from the connected models, renamed, given another member or one fewer, and deleted. A room made
    /// on the phone takes the next of `UITestRooms.madeIDs`, whose routes are listed here one by one (a route matches a path, and
    /// the room the vault starts with, `r1`, has its own in `UITestWorld+Screens`).
    private static func roomRoutes(_ rooms: UITestRooms) -> [MockRoute] {
        var routes: [MockRoute] = [
            MockRoute(.get, "/api/rooms") { _ in reply(raw: rooms.listJSON()) },
            MockRoute(.post, "/api/rooms") { request in
                let sent = body(request)
                let members = (sent["members"]?.array ?? []).compactMap { member -> (backend: String, handle: String, brief: String)? in
                    guard let backend = member["backend_id"]?.string, let handle = member["handle"]?.string else { return nil }
                    return (backend, handle, member["role_brief"]?.string ?? "")
                }
                guard !members.isEmpty else { return reply(.object(["error": .string("A room needs at least one member.")]), status: 400) }
                guard let made = rooms.create(title: sent["title"]?.string, members: members) else {
                    return reply(.object(["error": .string("That is as many rooms as this canned server keeps.")]), status: 400)
                }
                return reply(.object(["room": .object(["id": .string(made.id), "title": .string(made.title)]), "members": .array(made.members)]), status: 201)
            },
        ]
        for id in UITestRooms.madeIDs {
            routes.append(MockRoute(.get, "/api/rooms/\(id)") { _ in
                guard let raw = rooms.detailJSON(id: id) else { return notFound("That room is not here.") }
                return reply(raw: raw)
            })
            routes.append(MockRoute(.patch, "/api/rooms/\(id)") { request in
                guard let title = body(request)["title"]?.string, rooms.rename(id: id, to: title) else { return notFound("That room is not here.") }
                return empty()
            })
            routes.append(MockRoute(.delete, "/api/rooms/\(id)") { _ in
                rooms.delete(id: id) ? empty() : notFound("That room is not here.")
            })
            routes.append(MockRoute(.post, "/api/rooms/\(id)/members") { request in
                let drafts = (body(request)["members"]?.array ?? []).compactMap { member -> (backend: String, handle: String, brief: String)? in
                    guard let backend = member["backend_id"]?.string, let handle = member["handle"]?.string else { return nil }
                    return (backend, handle, member["role_brief"]?.string ?? "")
                }
                switch rooms.addMembers(id: id, drafts) {
                case .success(let added): return reply(.object(["members": .array(added)]), status: 201)
                case .failure(let problem): return reply(.object(["error": .string(problem.message)]), status: problem.status)
                }
            })
            routes.append(MockRoute(.delete, "/api/rooms/\(id)/members") { request in
                guard let member = body(request)["member_id"]?.string, rooms.removeMember(id: id, memberID: member) else { return notFound("That member is not here.") }
                return empty()
            })
        }
        return routes
    }

    // MARK: Truth

    /// The ledger: what is asserted into it, and what is out of date and waits on the person.
    private static func truthRoutes(_ truth: UITestTruth) -> [MockRoute] {
        [
            MockRoute(.get, "/api/truth") { _ in reply(raw: truth.overviewJSON()) },
            MockRoute(.post, "/api/truth/entries") { request in
                let sent = body(request)
                guard let type = sent["type"]?.string, let ledger = sent["ledger"]?.string else {
                    return reply(.object(["error": .string("type and ledger are required.")]), status: 400)
                }
                let text = (type == "TB" ? sent["claim"]?.string : sent["assertion"]?.string) ?? ""
                guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
                    return reply(.object(["error": .string("Say what is being asserted.")]), status: 400)
                }
                let line = truth.assert(type: type, text: text, basis: sent["basis"]?.string, ledger: ledger)
                return reply(.object(["line": line, "standing": .string("sound")]), status: 201)
            },
            MockRoute(.get, "/api/truth/stale") { _ in reply(raw: truth.staleJSON()) },
            MockRoute(.post, "/api/truth/stale") { request in
                let sent = body(request)
                guard let kind = sent["kind"]?.string, let id = sent["id"]?.string,
                      let action = sent["action"]?.string, ["reaffirm", "relink", "unlink"].contains(action)
                else { return reply(.object(["error": .string("kind, id and action are required.")]), status: 400) }
                guard truth.resolve(kind: kind, id: id) else { return notFound("That item is not out of date.") }
                return reply(.object(["ok": .bool(true)]))
            },
        ]
    }

    // MARK: Chat

    /// The conversations: one begins with the first message sent to it, and one can be deleted.
    private static func chatRoutes(_ chats: UITestChats) -> [MockRoute] {
        [
            MockRoute(.get, "/api/conversations") { _ in reply(raw: chats.listJSON()) },
            MockRoute(.get, "/api/conversations/*") { request in
                guard let raw = chats.detailJSON(id: lastComponent(request)) else { return notFound("That chat is not here.") }
                return reply(raw: raw)
            },
            MockRoute(.delete, "/api/conversations/*") { request in
                guard chats.delete(id: lastComponent(request)) else { return notFound("That chat is not here.") }
                return empty()
            },
            MockRoute(.post, "/api/chat") { request in
                let sent = body(request)
                let message = sent["message"]?.string ?? ""
                // A turn with no conversation begins one; a turn in one the person made carries on with it.
                let conversation = chats.conversation(for: sent["conversation_id"]?.string, firstMessage: message)
                let answer = chatAnswer(request, conversation: conversation)
                let text = (try? JSONDecoder().decode(JSONValue.self, from: answer.data))?["reply"]?["content"]?.string ?? ""
                chats.record(conversation, user: message, assistant: text)
                return answer
            },
        ]
    }

    // MARK: Dreams and Digest

    /// The connections found overnight and the splits proposed, each waiting for a verdict.
    private static func thinkRoutes(_ dreams: UITestDreams, _ digest: UITestDigest) -> [MockRoute] {
        [
            MockRoute(.get, "/api/dreams") { _ in reply(raw: dreams.queueJSON()) },
            MockRoute(.post, "/api/dreams") { request in
                let sent = body(request)
                guard let verdict = sent["decision"]?.string, verdict == "accept" || verdict == "reject" else {
                    return reply(.object(["error": .string("decision must be accept or reject.")]), status: 400)
                }
                if let id = sent["id"]?.string {
                    guard let answer = dreams.decide(connections: [id], accept: verdict == "accept") else { return notFound("No such connection.") }
                    return reply(answer)
                }
                if let run = sent["runId"]?.string {
                    guard let answer = dreams.decide(run: run, accept: verdict == "accept") else { return notFound("No such dream.") }
                    return reply(answer)
                }
                return reply(.object(["error": .string("id or runId is required.")]), status: 400)
            },
            MockRoute(.get, "/api/digest") { _ in reply(raw: digest.queueJSON()) },
            MockRoute(.post, "/api/digest") { request in
                let sent = body(request)
                guard let verdict = sent["decision"]?.string, verdict == "accept" || verdict == "reject", let run = sent["runId"]?.string else {
                    return reply(.object(["error": .string("decision and runId are required.")]), status: 400)
                }
                guard let answer = digest.decide(run: run, accept: verdict == "accept") else { return notFound("No such proposal.") }
                return reply(answer)
            },
        ]
    }

    // MARK: Your address

    /// The claimed addresses and what is changed on them: the look and the page an address opens to.
    private static func realmRoutes(_ realms: UITestRealms) -> [MockRoute] {
        [
            MockRoute(.get, "/rest/v1/domain_claims") { _ in reply(.array(realms.rows())) },
            MockRoute(.patch, "/api/claim-domain") { request in
                let sent = body(request)
                guard let subdomain = sent["subdomain"]?.string, let base = sent["base_domain"]?.string else {
                    return reply(.object(["error": .string("subdomain and base_domain are required.")]), status: 400)
                }
                // A body without `theme` changes only the home page, and the other way round.
                guard let changed = realms.update(
                    subdomain: subdomain, base: base,
                    theme: sent["theme"].map { $0.string }, home: sent["default_artifact"].map { $0.string }
                ) else { return notFound("You have not claimed that address.") }
                var answer: [String: JSONValue] = [
                    "domain": .string("\(subdomain).\(base)"),
                    "theme": changed.theme.map(JSONValue.string) ?? .null,
                    "default_artifact": changed.home.map(JSONValue.string) ?? .null,
                    "url": .string("https://\(subdomain).\(base)/"),
                    "message": .string("Saved."),
                ]
                if changed.home == "trip-to-lisbon-q7" {
                    answer["warning"] = .string("That page is private, so visitors get its lock page. Make it public to serve it here.")
                }
                return reply(.object(answer))
            },
        ]
    }

    // MARK: Mail

    private static func mailRoutes(_ mail: UITestMail) -> [MockRoute] {
        [
            MockRoute(.get, "/api/mail/messages") { request in
                if let thread = request.queryValue("thread_id") {
                    return reply(.object(["messages": .array(mail.thread(thread)), "next_cursor": .null]))
                }
                let box = request.queryValue("box") ?? "inbox"
                return reply(.object(["box": .string(box), "messages": .array(mail.box(box, unreadOnly: request.queryValue("unread") == "1")), "next_cursor": .null]))
            },
            MockRoute(.post, "/api/mail/messages") { request in
                let sent = body(request)
                guard let text = sent["text"]?.string, !text.isEmpty else {
                    return reply(.object(["error": .string("text is required.")]), status: 400)
                }
                let message = mail.send(subject: sent["subject"]?.string ?? "", text: text)
                return reply(.object(["message": message, "thread_id": message["thread_id"] ?? .null]), status: 201)
            },
            MockRoute(.post, "/api/mail/messages/*") { request in
                let parts = components(request, after: "/api/mail/messages")
                guard parts.count == 2, parts[1] == "reply", let text = body(request)["text"]?.string, !text.isEmpty else {
                    return reply(.object(["error": .string("text is required.")]), status: 400)
                }
                guard let message = mail.reply(to: parts[0], text: text) else { return notFound("No such message.") }
                return reply(.object(["message": message, "thread_id": message["thread_id"] ?? .null]), status: 201)
            },
        ]
    }
}

// MARK: - The stores

/// What is kept (Yours and the Library) and the pages a journey keeps, edits and deletes.
final class UITestVault: @unchecked Sendable {
    struct Page {
        let id: String
        let slug: String
        var title: String
        var content: String
        var visibility: String
        var mutable: Bool
        var head: String
        var versions: [(id: String, parent: String?, message: String)]
        var kept = true
    }

    private let lock = NSLock()
    private let memories: UITestMemories
    private var pages: [String: Page] = [:]
    private var order: [String] = []
    private var made = 0
    private var versionCount = 0
    /// Pages of the canned vault that were deleted, and who can open each now.
    private var deleted: Set<String> = []
    private var visibility: [String: String] = [:]

    init(memories: UITestMemories) {
        self.memories = memories
    }

    private static let base: [(slug: String, title: String, type: String, ago: TimeInterval)] = [
        ("bakery-landing-page-x1", "Bakery landing page", "html", 7_200),
        ("trip-to-lisbon-q7", "Trip to Lisbon", "html", 1_300_000),
        ("portfolio-site", "Portfolio site", "group", 900_000),
    ]

    /// Everything kept: the canned things, less what was forgotten or deleted and as the memories were renamed, and the
    /// pages made since, newest first.
    var things: [UITestWorld.Thing] {
        lock.lock()
        defer { lock.unlock() }
        var list: [UITestWorld.Thing] = []
        for thing in UITestWorld.things {
            if thing.kind == "memory" {
                guard let current = memories.record(thing.id) else { continue }
                list.append(UITestWorld.Thing(id: thing.id, kind: "memory", name: current.title, summary: thing.summary, href: thing.href, updatedAgo: thing.updatedAgo, openedAgo: thing.openedAgo))
            } else if let slug = thing.slug, deleted.contains(slug) {
                continue
            } else {
                list.append(thing)
            }
        }
        let fresh = order.compactMap { pages[$0] }.filter(\.kept).reversed().map { page in
            UITestWorld.Thing(id: page.id, kind: "page", name: page.title, summary: "", href: "/a/\(page.slug)", updatedAgo: 5, openedAgo: nil)
        }
        return Array(fresh) + list
    }

    func artifactsJSON() -> String {
        lock.lock()
        defer { lock.unlock() }
        func item(_ slug: String, _ title: String, type: String, ago: TimeInterval, visibility: String) -> JSONValue {
            .object([
                "slug": .string(slug), "title": .string(title), "type": .string(type), "tags": .array([]),
                "source_prompt": .null, "is_pwa": .bool(false), "is_jsx": .bool(false), "visibility": .string(visibility),
                "icon": .null, "created_at": .string(UITestWorld.date(ago)),
                "url": .string(UITestWorld.appURL.appendingPathComponent(type == "group" ? "g" : "a").appendingPathComponent(slug).absoluteString),
            ])
        }
        var items: [JSONValue] = order.compactMap { pages[$0] }.filter(\.kept).reversed().map {
            item($0.slug, $0.title, type: "html", ago: 5, visibility: $0.visibility)
        }
        for entry in Self.base where !deleted.contains(entry.slug) {
            items.append(item(entry.slug, entry.title, type: entry.type, ago: entry.ago, visibility: visibility[entry.slug] ?? "private"))
        }
        return JSONValue.object(["items": .array(items)]).jsonString()
    }

    /// Keeps a page and answers its link.
    func keep(content: String, title: String?, visibility: String, mutable: Bool) -> (slug: String, url: String, mutable: Bool) {
        lock.lock()
        defer { lock.unlock() }
        made += 1
        let heading = title.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } ?? "Untitled"
        let slug = "\(UITestWorld.slug(from: heading))-p\(made)"
        versionCount += 1
        let head = "pv\(versionCount)"
        pages[slug] = Page(
            id: "p\(made)", slug: slug, title: heading, content: content, visibility: visibility, mutable: mutable, head: head,
            versions: [(head, nil, "create")]
        )
        order.append(slug)
        return (slug, UITestWorld.appURL.appendingPathComponent("a").appendingPathComponent(slug).absoluteString, mutable)
    }

    func page(slug: String) -> Page? {
        lock.lock()
        defer { lock.unlock() }
        return pages[slug].flatMap { $0.kept ? $0 : nil }
    }

    func setVisibility(slug: String, to next: String) -> (id: String, title: String)? {
        lock.lock()
        defer { lock.unlock() }
        if var page = pages[slug], page.kept {
            page.visibility = next
            pages[slug] = page
            return (page.id, page.title)
        }
        guard let entry = Self.base.first(where: { $0.slug == slug }), !deleted.contains(slug) else { return nil }
        visibility[slug] = next
        return ("base-\(slug)", entry.title)
    }

    func delete(slug: String) -> (id: String, title: String)? {
        lock.lock()
        defer { lock.unlock() }
        if var page = pages[slug], page.kept {
            page.kept = false
            pages[slug] = page
            return (page.id, page.title)
        }
        guard let entry = Self.base.first(where: { $0.slug == slug }), !deleted.contains(slug) else { return nil }
        deleted.insert(slug)
        return ("base-\(slug)", entry.title)
    }

    /// A new version of a living page.
    func write(slug: String, content: String, message: String?) -> (url: String, head: String, parent: String?, message: String)? {
        lock.lock()
        defer { lock.unlock() }
        guard var page = pages[slug], page.kept, page.mutable else { return nil }
        versionCount += 1
        let parent = page.head
        let head = "pv\(versionCount)"
        page.content = content
        page.head = head
        let note = (message?.isEmpty == false ? message : nil) ?? "edit"
        page.versions.insert((head, parent, note), at: 0)
        pages[slug] = page
        return (UITestWorld.appURL.appendingPathComponent("a").appendingPathComponent(slug).absoluteString, head, parent, note)
    }

    func versionsJSON(slug: String) -> JSONValue {
        lock.lock()
        defer { lock.unlock() }
        guard let page = pages[slug] else { return .object(["slug": .string(slug), "mutable": .bool(false), "versions": .array([])]) }
        let list = page.versions.enumerated().map { index, version -> JSONValue in
            .object([
                "id": .string(version.id), "parent_version_id": version.parent.map(JSONValue.string) ?? .null,
                "title": .string(page.title), "message": .string(version.message), "author_kind": .string("user"),
                "author_key_prefix": .null, "content_hash": .string("h-\(version.id)"), "is_jsx": .bool(false),
                "is_head": .bool(index == 0), "created_at": .string(UITestWorld.date(TimeInterval(60 * (index + 1)))),
            ])
        }
        return .object(["slug": .string(slug), "mutable": .bool(page.mutable), "versions": .array(list)])
    }
}

/// The memories a person has: listed, read, edited and forgotten.
final class UITestMemories: @unchecked Sendable {
    struct Record {
        let id: String
        var title: String
        var content: String
        var summary: String
        var tags: [String]
        let source: String
        let createdAt: String
        var revisions = 1
    }

    private let lock = NSLock()
    private var records: [Record]
    private var commits = 0

    init() {
        let list = UITestWorld.parse(MemoryPreviewData.memories)["memories"]?.array ?? []
        let page = UITestWorld.parse(MemoryPreviewData.page)
        records = list.map { item in
            let id = item["id"]?.string ?? ""
            let summary = item["summary"]?.string ?? ""
            let content = id == "m1" ? (page["memory"]?["content"]?.string ?? summary) : summary
            return Record(
                id: id, title: item["title"]?.string ?? "", content: content, summary: summary,
                tags: (item["tags"]?.array ?? []).compactMap(\.string), source: item["source"]?.string ?? "manual",
                createdAt: item["created_at"]?.string ?? ""
            )
        }
    }

    func record(_ id: String) -> Record? {
        lock.lock()
        defer { lock.unlock() }
        return records.first { $0.id == id }
    }

    func listJSON() -> String {
        lock.lock()
        defer { lock.unlock() }
        let rows = records.map { record -> JSONValue in
            .object([
                "id": .string(record.id), "title": .string(record.title), "summary": .string(record.summary),
                "tags": .array(record.tags.map(JSONValue.string)), "source": .string(record.source), "created_at": .string(record.createdAt),
            ])
        }
        return JSONValue.object(["branch": .string("main"), "memories": .array(rows)]).jsonString()
    }

    /// `GET /api/memories/<id>`: the first memory has the full page of the previews (a neighbour, a linked page, a receipt,
    /// what it rests on); another is its text and nothing around it.
    func pageJSON(id: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let record = records.first(where: { $0.id == id }) else { return nil }
        let memory: JSONValue = .object([
            "id": .string(record.id), "title": .string(record.title), "content": .string(record.content), "summary": .string(record.summary),
            "tags": .array(record.tags.map(JSONValue.string)), "source": .string(record.source), "created_at": .string(record.createdAt),
        ])
        var page: [String: JSONValue]
        if id == "m1", let base = UITestWorld.parse(MemoryPreviewData.page).object {
            page = base
            page["memory"] = memory
            page["revision_count"] = .int(record.revisions + 2)
        } else {
            page = [
                "branch": .string("main"), "memory": memory, "related": .array([]), "artifacts": .array([]),
                "revision_count": .int(record.revisions),
            ]
        }
        if commits > 0 || id != "m1" {
            page["provenance"] = .object([
                "commit_id": .string("c0000000-0000-4000-8000-00000000000\(max(commits, 1))"),
                "message": .string(commits > 0 ? "edit: \(record.title)" : "memorize: \(record.title)"),
                "author_kind": .string("user"), "committed_at": .string(UITestWorld.date(commits > 0 ? 3 : 90_000)),
            ])
        }
        return JSONValue.object(page).jsonString()
    }

    /// `PATCH /api/memories/<id>`: a commit with the fields that were sent.
    func edit(id: String, title: String?, content: String?, tags: [String]?, message: String?) -> JSONValue? {
        lock.lock()
        defer { lock.unlock() }
        guard let index = records.firstIndex(where: { $0.id == id }) else { return nil }
        if let title { records[index].title = title }
        if let content {
            records[index].content = content
            records[index].summary = String(content.prefix(140))
        }
        if let tags { records[index].tags = tags }
        records[index].revisions += 1
        commits += 1
        let record = records[index]
        return .object([
            "id": .string(id), "title": .string(record.title), "summary": .string(record.summary),
            "tags": .array(record.tags.map(JSONValue.string)), "branch": .string("main"),
            "commit_id": .string("c0000000-0000-4000-8000-00000000000\(commits)"),
            "message": .string((message?.isEmpty == false ? message : nil) ?? "edit: \(record.title)"),
        ])
    }

    /// Replaces a memory by the smaller ones it was split into, in its place in the list.
    func split(id: String, into parts: [(title: String, summary: String, tags: [String])]) -> [String]? {
        lock.lock()
        defer { lock.unlock() }
        guard let index = records.firstIndex(where: { $0.id == id }), !parts.isEmpty else { return nil }
        let source = records.remove(at: index)
        commits += 1
        var ids: [String] = []
        for (offset, part) in parts.enumerated() {
            let newID = "\(id)-part\(offset + 1)"
            ids.append(newID)
            records.insert(
                Record(
                    id: newID, title: part.title, content: part.summary, summary: part.summary, tags: part.tags,
                    source: source.source, createdAt: UITestWorld.date(30)
                ),
                at: index + offset
            )
        }
        return ids
    }

    func forget(id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let before = records.count
        records.removeAll { $0.id == id }
        return records.count < before
    }
}

/// The logins, cards, contacts and keys in the vault.
final class UITestSecrets: @unchecked Sendable {
    struct Problem: Error {
        let status: Int
        let message: String
    }

    private let lock = NSLock()
    private var secrets: [JSONValue]
    private var made = 0

    init() {
        secrets = UITestWorld.parse(VaultPreviewData.secretsJSON)["secrets"]?.array ?? []
    }

    func rows() -> [JSONValue] {
        lock.lock()
        defer { lock.unlock() }
        return secrets
    }

    private func index(of name: String) -> Int? {
        secrets.firstIndex { $0["name"]?.string == name }
    }

    func create(name: String, kind: String, value: String, description: String?) -> Result<JSONValue, Problem> {
        lock.lock()
        defer { lock.unlock() }
        guard VaultItems.isValidName(name) else { return .failure(Problem(status: 400, message: VaultItems.nameHint)) }
        guard index(of: name) == nil else { return .failure(Problem(status: 409, message: "A secret named \(name) already exists.")) }
        guard let secretKind = SecretKind(rawValue: kind) else { return .failure(Problem(status: 400, message: "Unknown kind.")) }
        var hint: JSONValue = .null
        if let itemKind = secretKind.vaultItemKind {
            switch VaultItems.parse(itemKind, value: value) {
            case .success(let fields): hint = .string(VaultItems.deriveHint(itemKind, fields))
            case .failure(let problem): return .failure(Problem(status: 400, message: problem.message))
            }
        }
        made += 1
        let row: JSONValue = .object([
            "id": .string("s-new\(made)"), "name": .string(name), "kind": .string(kind),
            "description": description.map(JSONValue.string) ?? .null, "hint": hint,
            "created_at": .string(UITestWorld.date(2)), "updated_at": .string(UITestWorld.date(2)), "last_accessed_at": .null,
        ])
        secrets.append(row)
        return .success(row)
    }

    func update(name: String, newName: String?, description: String?, value: String?) -> Result<JSONValue, Problem> {
        lock.lock()
        defer { lock.unlock() }
        guard let at = index(of: name), case .object(var fields)? = Optional(secrets[at]) else {
            return .failure(Problem(status: 404, message: "No such secret."))
        }
        if let newName, newName != name {
            guard VaultItems.isValidName(newName) else { return .failure(Problem(status: 400, message: VaultItems.nameHint)) }
            guard index(of: newName) == nil else { return .failure(Problem(status: 409, message: "A secret named \(newName) already exists.")) }
            fields["name"] = .string(newName)
        }
        if let description { fields["description"] = description.isEmpty ? .null : .string(description) }
        if let value, let kind = fields["kind"]?.string.flatMap(SecretKind.init(rawValue:)), let itemKind = kind.vaultItemKind {
            switch VaultItems.parse(itemKind, value: value) {
            case .success(let parsed): fields["hint"] = .string(VaultItems.deriveHint(itemKind, parsed))
            case .failure(let problem): return .failure(Problem(status: 400, message: problem.message))
            }
        }
        fields["updated_at"] = .string(UITestWorld.date(1))
        secrets[at] = .object(fields)
        return .success(secrets[at])
    }

    func delete(name: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let at = index(of: name) else { return false }
        secrets.remove(at: at)
        return true
    }
}

/// The task boards: the two the vault starts with, and boards made on the phone, with their tasks.
final class UITestBoards: @unchecked Sendable {
    struct Board {
        let slug: String
        let project: String
        var title: String
        var version: Int
        var tasks: [JSONValue]
        let createdAt: String
    }

    private let lock = NSLock()
    private var boards: [String: Board] = [:]
    private var order: [String] = []
    private var made = 0
    private var added = 0

    init() {
        let choir = UITestWorld.parse(#"{"tasklist":\#(TaskBoardPreviewData.boardJSON)}"#)["tasklist"]
        boards["eurorack-choir"] = Board(
            slug: "tasks-eurorack-choir", project: "eurorack-choir", title: "Eurorack Choir Module", version: 42,
            tasks: choir?["tasks"]?.array ?? [], createdAt: "2026-10-20T09:00:00.000Z"
        )
        func task(_ id: String, _ title: String, _ status: String) -> JSONValue {
            .object(["id": .string(id), "title": .string(title), "type": .string("task"), "status": .string(status), "assignee": .object(["kind": .string("unassigned")])])
        }
        boards["garden"] = Board(
            slug: "tasks-garden", project: "garden", title: "Spring garden", version: 3,
            tasks: [task("g1", "Dig the beds", "todo"), task("g2", "Order the seeds", "todo"), task("g3", "Build the cold frame", "todo"), task("g4", "Buy compost", "done")],
            createdAt: "2026-10-12T09:00:00.000Z"
        )
        // Oldest first: the list is newest first, so the board made on the phone stands above the two the vault starts with.
        order = ["garden", "eurorack-choir"]
    }

    func board(_ project: String) -> Board? {
        lock.lock()
        defer { lock.unlock() }
        return boards[project]
    }

    func listings() -> [JSONValue] {
        lock.lock()
        defer { lock.unlock() }
        return order.reversed().compactMap { boards[$0] }.map { board in
            .object([
                "slug": .string(board.slug), "project": .string(board.project), "title": .string("Tasks \u{2014} \(board.title)"),
                "url": .string(UITestWorld.appURL.appendingPathComponent("a/\(board.slug)").absoluteString),
                "created_at": .string(board.createdAt), "updated_at": .null,
            ])
        }
    }

    func create(title: String, tasks: [String]) -> (project: String, slug: String, version: Int) {
        lock.lock()
        defer { lock.unlock() }
        made += 1
        var project = UITestWorld.slug(from: title, fallback: "board")
        if boards[project] != nil { project += "-\(made)" }
        let list = tasks.enumerated().map { index, text -> JSONValue in
            .object(["id": .string("t-\(project)-\(index + 1)"), "title": .string(text), "type": .string("task"), "status": .string("todo"), "assignee": .object(["kind": .string("unassigned")])])
        }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        boards[project] = Board(slug: "tasks-\(project)", project: project, title: trimmed, version: 1, tasks: list, createdAt: HVDate.format(Date()))
        order.append(project)
        return (project, "tasks-\(project)", 1)
    }

    func boardJSON(_ project: String) -> JSONValue? {
        lock.lock()
        defer { lock.unlock() }
        return boardValue(project)
    }

    private func boardValue(_ project: String) -> JSONValue? {
        guard let board = boards[project] else { return nil }
        return .object([
            "$schema": .string("https://hypervault.store/schemas/tasklist-v1.json"), "schemaVersion": .int(1), "id": .string(project),
            "title": .string(board.title), "version": .int(board.version), "settings": .object([:]),
            "createdAt": .string(board.createdAt), "updatedAt": .string(HVDate.format(Date().addingTimeInterval(-720))),
            "tasks": .array(board.tasks),
        ])
    }

    func task(_ project: String, id: String) -> JSONValue? {
        lock.lock()
        defer { lock.unlock() }
        return boards[project]?.tasks.first { $0["id"]?.string == id }
    }

    func summary(_ project: String) -> JSONValue? {
        lock.lock()
        defer { lock.unlock() }
        return summaryValue(project)
    }

    private func summaryValue(_ project: String) -> JSONValue? {
        guard let board = boards[project] else { return nil }
        let tasks = board.tasks
        var counts: [String: Int] = [:]
        for status in ["todo", "in_progress", "blocked", "review", "done", "cancelled"] { counts[status] = 0 }
        for task in tasks { counts[task["status"]?.string ?? "todo", default: 0] += 1 }
        let countable = tasks.count - (counts["cancelled"] ?? 0)
        let done = counts["done"] ?? 0
        let progress = countable > 0 ? Int((Double(done) / Double(countable) * 100).rounded()) : 0
        let epics = tasks.filter { $0["type"]?.string == "epic" }.map { epic -> JSONValue in
            let ids = Set((epic["children"]?.array ?? []).compactMap(\.string))
            let children = tasks.filter { ids.contains($0["id"]?.string ?? "") }
            let finished = children.filter { $0["status"]?.string == "done" }.count
            return .object([
                "id": epic["id"] ?? .null, "title": epic["title"] ?? .null, "total": .int(children.count), "done": .int(finished),
                "progress": .int(children.isEmpty ? 0 : Int((Double(finished) / Double(children.count) * 100).rounded())),
            ])
        }
        let claimed = tasks.compactMap { task -> JSONValue? in
            guard let claim = task["lock"], let by = claim["by"]?.string else { return nil }
            return .object(["taskId": task["id"] ?? .null, "by": .string(by), "agentType": claim["agentType"] ?? .null])
        }
        let unassigned = tasks.filter {
            $0["type"]?.string != "epic" && $0["assignee"]?["kind"]?.string == "unassigned" && !["done", "cancelled"].contains($0["status"]?.string ?? "")
        }.count
        return .object([
            "id": .string(project), "title": .string(board.title), "version": .int(board.version), "total": .int(tasks.count),
            "byStatus": .object(counts.mapValues { JSONValue.int($0) }), "progress": .int(progress),
            "epics": .array(epics), "claimed": .array(claimed), "unassigned": .int(unassigned),
        ])
    }

    func add(_ project: String, title: String, parent: String?) -> JSONValue {
        lock.lock()
        defer { lock.unlock() }
        added += 1
        var fields: [String: JSONValue] = [
            "id": .string("t-new\(added)"), "title": .string(title), "type": .string("task"), "status": .string("todo"),
            "assignee": .object(["kind": .string("unassigned")]),
            "createdAt": .string(HVDate.format(Date())), "updatedAt": .string(HVDate.format(Date())),
        ]
        if let parent { fields["parent"] = .string(parent) }
        let task: JSONValue = .object(fields)
        boards[project]?.tasks.append(task)
        boards[project]?.version += 1
        return task
    }

    @discardableResult
    func setStatus(_ project: String, id: String, to status: String, note: String?) -> JSONValue? {
        patch(project, id: id, patch: ["status": .string(status)] + (note.map { ["note": JSONValue.string($0)] } ?? [:]))
    }

    func claim(_ project: String, id: String, release: Bool) -> JSONValue? {
        if release {
            return patchRaw(project, id: id) { task in
                task["assignee"] = .object(["kind": .string("unassigned")])
                task.removeValue(forKey: "lock")
                if task["status"]?.string == "in_progress" { task["status"] = .string("todo") }
            }
        }
        return patchRaw(project, id: id) { task in
            task["assignee"] = .object(["kind": .string("human"), "name": .string(UITestWorld.user.displayName ?? "Sam")])
            if task["status"]?.string != "blocked" { task["status"] = .string("in_progress") }
        }
    }

    func patch(_ project: String, id: String, patch: [String: JSONValue]) -> JSONValue? {
        patchRaw(project, id: id) { task in
            for (field, value) in patch {
                switch field {
                case "note":
                    var notes = task["notes"]?.array ?? []
                    notes.append(.object([
                        "id": .string("n\(notes.count + 1)"), "author": .string(UITestWorld.user.displayName ?? "Sam"),
                        "authorKind": .string("human"), "body": value, "createdAt": .string(HVDate.format(Date())),
                    ]))
                    task["notes"] = .array(notes)
                case "status":
                    task["status"] = value
                    if value.string == "done" {
                        task["completedAt"] = .string(HVDate.format(Date()))
                        task.removeValue(forKey: "lock")
                    } else {
                        task.removeValue(forKey: "completedAt")
                    }
                default:
                    task[field] = value
                }
            }
            task["updatedAt"] = .string(HVDate.format(Date()))
        }
    }

    private func patchRaw(_ project: String, id: String, _ change: (inout [String: JSONValue]) -> Void) -> JSONValue? {
        lock.lock()
        defer { lock.unlock() }
        guard var board = boards[project], let at = board.tasks.firstIndex(where: { $0["id"]?.string == id }),
              case .object(var fields) = board.tasks[at]
        else { return nil }
        change(&fields)
        board.tasks[at] = .object(fields)
        board.version += 1
        boards[project] = board
        return board.tasks[at]
    }
}

/// Merges two dictionaries of values, the right one winning.
private func + (left: [String: JSONValue], right: [String: JSONValue]) -> [String: JSONValue] {
    left.merging(right) { _, new in new }
}

/// The conversations: the ones the vault starts with, and the ones begun on the phone.
final class UITestChats: @unchecked Sendable {
    private struct Line {
        let role: String
        let content: String
    }

    private struct Made {
        let id: String
        let title: String
        var lines: [Line]
    }

    private let lock = NSLock()
    private var made: [Made] = []
    private var deleted: Set<String> = []
    private var count = 0

    private var base: [JSONValue] { UITestWorld.parse(ChatPreviewData.conversationsJSON)["conversations"]?.array ?? [] }

    private func row(_ chat: Made) -> JSONValue {
        .object([
            "id": .string(chat.id), "title": .string(chat.title), "source_platform": .string("hypervault"),
            "model": .string("claude-opus-4-8"), "created_at": .string(UITestWorld.date(60)), "updated_at": .string(UITestWorld.date(5)),
            "visibility": .string("private"), "share_slug": .null,
        ])
    }

    func listJSON() -> String {
        lock.lock()
        defer { lock.unlock() }
        let kept = base.filter { !deleted.contains($0["id"]?.string ?? "") }
        return JSONValue.object(["conversations": .array(made.filter { !deleted.contains($0.id) }.reversed().map(row) + kept)]).jsonString()
    }

    func detailJSON(id: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard !deleted.contains(id) else { return nil }
        if let chat = made.first(where: { $0.id == id }) {
            let messages = chat.lines.enumerated().map { position, line -> JSONValue in
                .object([
                    "id": .string("\(id)-m\(position)"), "role": .string(line.role), "content": .string(line.content),
                    "attachments": .array([]), "model": line.role == "user" ? .null : .string("claude-opus-4-8"),
                    "position": .int(position), "created_at": .string(UITestWorld.date(TimeInterval(60 - position))), "feedback": .null,
                ])
            }
            return JSONValue.object(["conversation": row(chat), "messages": .array(messages)]).jsonString()
        }
        return id == "c1" ? ChatPreviewData.detailJSON : nil
    }

    func delete(id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let known = made.contains { $0.id == id } || base.contains { $0["id"]?.string == id }
        guard known, !deleted.contains(id) else { return false }
        deleted.insert(id)
        return true
    }

    /// The conversation a turn belongs to: the one it names, or a new one begun with this message.
    func conversation(for named: String?, firstMessage: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        if let named { return named }
        count += 1
        let id = "n\(count)"
        made.append(Made(id: id, title: String(firstMessage.prefix(80)), lines: []))
        return id
    }

    func record(_ id: String, user: String, assistant: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let at = made.firstIndex(where: { $0.id == id }) else { return }
        made[at].lines.append(Line(role: "user", content: user))
        made[at].lines.append(Line(role: "assistant", content: assistant))
    }
}

/// The ledger a person keeps: the entries asserted into it from the phone, and the memories and pages whose facts moved.
final class UITestTruth: @unchecked Sendable {
    private let lock = NSLock()
    private var asserted: [JSONValue] = []
    private var resolved: Set<String> = []

    private static func entry(_ id: String, _ status: String, _ text: String) -> String {
        #"{"id":"\#(id)","type":"TB","status":"\#(status)","standing":"sound","reasons":[],"text":"\#(text)","signedBy":"johnnyclem","answerableBy":"johnnyclem"}"#
    }

    private static func item(
        kind: String, id: String, title: String, slug: String?, entry: (id: String, text: String), summary: String, successor: (id: String, text: String)?
    ) -> JSONValue {
        let slugPart = slug.map { #","slug":"\#($0)""# } ?? ""
        let next = successor.map { Self.entry($0.id, "active", $0.text) } ?? "null"
        return UITestWorld.parse(#"""
        {"item":{"kind":"\#(kind)","id":"\#(id)","title":"\#(title)"\#(slugPart)},"key":"\#(kind):\#(id)","ledger":{"id":"l1","slug":"team","name":"Team","kind":"hosted"},
         "edges":[{"link":{"entry_id":"\#(entry.id)","relation":"rests_on","seen_status":"active","seen_standing":"sound","stale_since":"2026-10-24T10:00:00.000Z","stale_kind":"overturned","stale_by":null,"stale_summary":"\#(summary)","note":null},
                   "entry":\#(Self.entry(entry.id, "overridden", entry.text)),"successor":\#(next)}]}
        """#)
    }

    /// Three that moved: a memory with a newer entry to move to, a memory that is fine as it is, and a page to stop tracking.
    private static let staleItems: [JSONValue] = [
        UITestTruth.item(kind: "memory", id: "mem1", title: "Retry policy, as of October", slug: nil, entry: ("E1", "Retries are capped at 3."),
             summary: "The retry cap TB was overridden by a newer one.", successor: ("E9", "Retries are capped at 5; the old cap of 3 is dead.")),
        UITestTruth.item(kind: "memory", id: "mem2", title: "Budget notes", slug: nil, entry: ("E2", "The budget is 40k."),
             summary: "The budget TB is under appeal.", successor: nil),
        UITestTruth.item(kind: "artifact", id: "a-retry", title: "Retry ledger", slug: "retry-ledger", entry: ("E3", "Writes are retried once."),
             summary: "The retry TB was overridden by a newer one.", successor: nil),
    ]

    func staleJSON() -> String {
        lock.lock()
        defer { lock.unlock() }
        let waiting = Self.staleItems.filter { !resolved.contains($0["key"]?.string ?? "") }
        return JSONValue.object(["ledger": .null, "items": .array(waiting), "total": .int(waiting.count), "as_of": .string(UITestWorld.date(60))]).jsonString()
    }

    /// Whether there was such an item, still out of date.
    func resolve(kind: String, id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let key = "\(kind):\(id)"
        guard Self.staleItems.contains(where: { $0["key"]?.string == key }), !resolved.contains(key) else { return false }
        resolved.insert(key)
        return true
    }

    /// A line asserted from the phone, as the route answers it. A UV is open and goes to the unverified list.
    func assert(type: String, text: String, basis: String?, ledger: String) -> JSONValue {
        lock.lock()
        defer { lock.unlock() }
        let id = "01M2UITEST" + String(format: "%016d", asserted.count + 1)
        var line: [String: JSONValue] = [
            "id": .string(id), "type": .string(type), "ts": .string(UITestWorld.date(2)), "author": .string("johnnyclem"),
            "status": .string(type == "TB" ? "active" : "open"),
        ]
        if type == "TB" {
            line["claim"] = .string(text)
            line["evidence"] = .array([])
            line["signedBy"] = .string("johnnyclem")
            line["answerableBy"] = .string("johnnyclem")
        } else {
            line["assertion"] = .string(text)
            line["basis"] = .string(basis ?? "")
            line["verifyBy"] = .object(["kind": .string("inspect"), "value": .string("(unspecified)")])
        }
        asserted.append(.object(line))
        return .object(line)
    }

    /// The ledger page: the canned ledger and what was asserted into it since.
    func overviewJSON() -> String {
        lock.lock()
        defer { lock.unlock() }
        var root = UITestWorld.parse(TruthPreviewData.overview).object ?? [:]
        let uvs = asserted.filter { $0["type"]?.string == "UV" }
        let tbs = asserted.filter { $0["type"]?.string == "TB" }
        let flags: [JSONValue] = (root["flags"]?.array ?? []) + uvs
        root["flags"] = .array(flags)
        var citable: [JSONValue] = root["citable"]?.array ?? []
        for line in tbs {
            var row: [String: JSONValue] = ["entry": line, "standing": .string("sound"), "reasons": .array([]), "contested_by": .array([])]
            row["answerable_by"] = line["answerableBy"] ?? .null
            citable.append(.object(row))
        }
        root["citable"] = .array(citable)
        var entries: [JSONValue] = root["entries"]?.array ?? []
        for line in asserted {
            var row: [String: JSONValue] = [:]
            row["id"] = line["id"] ?? .null
            row["type"] = line["type"] ?? .null
            row["status"] = line["status"] ?? .null
            row["standing"] = .string("sound")
            row["reasons"] = .array([])
            row["corroborated"] = .bool(false)
            row["freshness"] = .null
            row["answerable_by"] = line["answerableBy"] ?? .null
            row["author"] = line["author"] ?? .null
            row["ts"] = line["ts"] ?? .null
            row["source"] = .string("manual")
            entries.append(.object(row))
        }
        root["entries"] = .array(entries)
        if case .object(var summary)? = root["summary"] {
            summary["total"] = .int((summary["total"]?.int ?? 0) + asserted.count)
            summary["flags"] = .int((summary["flags"]?.int ?? 0) + uvs.count)
            root["summary"] = .object(summary)
        }
        return JSONValue.object(root).jsonString()
    }
}

/// The people each page is shared with.
final class UITestShares: @unchecked Sendable {
    private let lock = NSLock()
    private var shares: [String: [JSONValue]] = [
        "bakery-landing-page-x1": [
            .object(["id": .string("s1"), "email": .string("maya@example.com"), "display_name": .string("Maya"), "role": .string("edit"), "created_at": .string(UITestWorld.date(500_000))]),
        ],
    ]
    private var made = 0

    func people(of slug: String) -> [JSONValue] {
        lock.lock()
        defer { lock.unlock() }
        return shares[slug] ?? []
    }

    /// A person with that address gets the role; adding them again changes it.
    func add(slug: String, email: String, role: String) {
        lock.lock()
        defer { lock.unlock() }
        var list = shares[slug] ?? []
        if let at = list.firstIndex(where: { $0["email"]?.string == email }), case .object(var fields) = list[at] {
            fields["role"] = .string(role)
            list[at] = .object(fields)
        } else {
            made += 1
            list.append(.object(["id": .string("sh-\(made)"), "email": .string(email), "display_name": .null, "role": .string(role), "created_at": .string(UITestWorld.date(2))]))
        }
        shares[slug] = list
    }

    func remove(id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        for (slug, list) in shares where list.contains(where: { $0["id"]?.string == id }) {
            shares[slug] = list.filter { $0["id"]?.string != id }
            return true
        }
        return false
    }
}

/// The group chats: the two the vault starts with, and rooms made on the phone.
final class UITestRooms: @unchecked Sendable {
    /// The ids rooms made on the phone get, in turn.
    static let madeIDs = ["rn1", "rn2", "rn3"]

    struct Problem: Error {
        let status: Int
        let message: String
    }

    private struct Made {
        let id: String
        var title: String
        var members: [JSONValue]
        var memberCount: Int
    }

    private let lock = NSLock()
    private var made: [Made] = []
    private var deleted: Set<String> = []

    private var base: [JSONValue] { UITestWorld.parse(ChatPreviewData.roomsJSON)["rooms"]?.array ?? [] }

    private static let backends: [String: (name: String, provider: String, model: String)] = [
        "b1": ("My Claude", "anthropic", "claude-opus-4-8"),
        "b2": ("GPT", "openai", "gpt-4o"),
        "b3": ("Office Llama", "ollama", "llama3.3"),
    ]

    private func member(room: String, id: String, backend: String, handle: String, brief: String, position: Int) -> JSONValue {
        let known = Self.backends[backend] ?? (name: backend, provider: "anthropic", model: "")
        return .object([
            "id": .string(id), "room_id": .string(room), "backend_id": .string(backend), "handle": .string(handle),
            "role_brief": .string(brief), "position": .int(position),
            "backend": .object(["name": .string(known.name), "provider": .string(known.provider), "default_model": .string(known.model)]),
        ])
    }

    private func summary(_ room: Made) -> JSONValue {
        .object([
            "id": .string(room.id), "title": .string(room.title), "pending": .array([]), "members": .array(room.members),
            "created_at": .string(UITestWorld.date(120)), "updated_at": .string(UITestWorld.date(10)),
        ])
    }

    func listJSON() -> String {
        lock.lock()
        defer { lock.unlock() }
        let kept = base.filter { !deleted.contains($0["id"]?.string ?? "") }
        let fresh: [JSONValue] = made.filter { !deleted.contains($0.id) }.reversed().map { summary($0) }
        return JSONValue.object(["rooms": .array(fresh + kept)]).jsonString()
    }

    func create(title: String?, members: [(backend: String, handle: String, brief: String)]) -> (id: String, title: String, members: [JSONValue])? {
        lock.lock()
        defer { lock.unlock() }
        guard made.count < Self.madeIDs.count else { return nil }
        let id = Self.madeIDs[made.count]
        let name = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = name.isEmpty ? "Room with " + members.map { "@" + $0.handle }.joined(separator: ", ") : name
        var count = 0
        let seated: [JSONValue] = members.enumerated().map { position, entry in
            count += 1
            return member(room: id, id: "\(id)-m\(count)", backend: entry.backend, handle: entry.handle, brief: entry.brief, position: position)
        }
        made.append(Made(id: id, title: shown, members: seated, memberCount: count))
        return (id, shown, seated)
    }

    func detailJSON(id: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let room = made.first(where: { $0.id == id }), !deleted.contains(id) else { return nil }
        let header: JSONValue = .object([
            "id": .string(id), "title": .string(room.title), "pending": .array([]), "budget": .int(12), "running": .bool(false),
            "truth_ledgers": .null, "created_at": .string(UITestWorld.date(120)), "updated_at": .string(UITestWorld.date(10)),
        ])
        return JSONValue.object(["room": header, "members": .array(room.members), "messages": .array([])]).jsonString()
    }

    func rename(id: String, to title: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let at = made.firstIndex(where: { $0.id == id }), !deleted.contains(id) else { return false }
        made[at].title = title
        return true
    }

    func delete(id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard made.contains(where: { $0.id == id }), !deleted.contains(id) else { return false }
        deleted.insert(id)
        return true
    }

    func addMembers(id: String, _ drafts: [(backend: String, handle: String, brief: String)]) -> Result<[JSONValue], Problem> {
        lock.lock()
        defer { lock.unlock() }
        guard let at = made.firstIndex(where: { $0.id == id }), !deleted.contains(id) else { return .failure(Problem(status: 404, message: "That room is not here.")) }
        var added: [JSONValue] = []
        for draft in drafts {
            let taken = made[at].members.compactMap { $0["handle"]?.string }
            guard !taken.contains(draft.handle) else { return .failure(Problem(status: 409, message: "@\(draft.handle) is already in this room.")) }
            made[at].memberCount += 1
            let seat = member(
                room: id, id: "\(id)-m\(made[at].memberCount)", backend: draft.backend, handle: draft.handle, brief: draft.brief,
                position: made[at].members.count
            )
            made[at].members.append(seat)
            added.append(seat)
        }
        return .success(added)
    }

    func removeMember(id: String, memberID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let at = made.firstIndex(where: { $0.id == id }) else { return false }
        let before = made[at].members.count
        made[at].members.removeAll { $0["id"]?.string == memberID }
        return made[at].members.count < before
    }
}

/// The connections a dream proposed, and which of them have had a verdict.
final class UITestDreams: @unchecked Sendable {
    private let lock = NSLock()
    private var accepted: Set<String> = []
    private var rejected: Set<String> = []

    private var base: [String: JSONValue] { UITestWorld.parse(MemoryPreviewData.dreams).object ?? [:] }

    /// The queue as the route sends it: only the connections still waiting, a run with none left dropped.
    func queueJSON() -> String {
        lock.lock()
        defer { lock.unlock() }
        var root = base
        let runs = (root["runs"]?.array ?? []).compactMap { run -> JSONValue? in
            guard case .object(var fields) = run else { return nil }
            let waiting = (fields["connections"]?.array ?? []).filter { !isDecided($0["id"]?.string ?? "") }
            guard !waiting.isEmpty else { return nil }
            fields["connections"] = .array(waiting)
            return .object(fields)
        }
        root["runs"] = .array(runs)
        root["pending_count"] = .int(runs.reduce(0) { $0 + ($1["connections"]?.array?.count ?? 0) })
        return JSONValue.object(root).jsonString()
    }

    private func isDecided(_ id: String) -> Bool { accepted.contains(id) || rejected.contains(id) }

    private var everyConnection: [String] {
        (base["runs"]?.array ?? []).flatMap { ($0["connections"]?.array ?? []).compactMap { $0["id"]?.string } }
    }

    func decide(connections ids: [String], accept: Bool) -> JSONValue? {
        lock.lock()
        defer { lock.unlock() }
        let known = Set(everyConnection)
        guard ids.allSatisfy({ known.contains($0) }) else { return nil }
        let fresh = ids.filter { !isDecided($0) }
        if accept { accepted.formUnion(fresh) } else { rejected.formUnion(fresh) }
        return answer(accepted: accept ? fresh.count : 0, rejected: accept ? 0 : fresh.count)
    }

    func decide(run id: String, accept: Bool) -> JSONValue? {
        let ids = (base["runs"]?.array ?? []).first { $0["id"]?.string == id }.map { ($0["connections"]?.array ?? []).compactMap { $0["id"]?.string } }
        guard let ids else { return nil }
        return decide(connections: ids, accept: accept)
    }

    private func answer(accepted: Int, rejected: Int) -> JSONValue {
        let message = accepted > 0
            ? "Wove \(accepted) \(accepted == 1 ? "connection" : "connections") into your graph."
            : "Filed away \(rejected) \(rejected == 1 ? "connection" : "connections"). They will not be proposed again."
        return .object(["accepted": .int(accepted), "rejected": .int(rejected), "failures": .array([]), "message": .string(message)])
    }
}

/// The splits proposed for big memories, and what applying one does to the memories.
final class UITestDigest: @unchecked Sendable {
    private let lock = NSLock()
    private let memories: UITestMemories
    private var decided: Set<String> = []

    init(memories: UITestMemories) {
        self.memories = memories
    }

    private var base: [String: JSONValue] { UITestWorld.parse(MemoryPreviewData.digest).object ?? [:] }

    func queueJSON() -> String {
        lock.lock()
        defer { lock.unlock() }
        var root = base
        let runs = (root["runs"]?.array ?? []).filter { !decided.contains($0["id"]?.string ?? "") }
        root["runs"] = .array(runs)
        root["pending_count"] = .int(runs.count)
        return JSONValue.object(root).jsonString()
    }

    /// Applies the split (the source memory is replaced by its segments) or keeps the memory whole.
    func decide(run id: String, accept: Bool) -> JSONValue? {
        lock.lock()
        defer { lock.unlock() }
        guard !decided.contains(id), let run = (base["runs"]?.array ?? []).first(where: { $0["id"]?.string == id }) else { return nil }
        decided.insert(id)
        guard accept else {
            return .object(["status": .string("rejected"), "created": .int(0), "links": .int(0), "message": .string("Kept whole.")])
        }
        let segments = (run["segments"]?.array ?? []).map { segment in
            (title: segment["title"]?.string ?? "", summary: segment["summary"]?.string ?? "", tags: (segment["tags"]?.array ?? []).compactMap(\.string))
        }
        let links = run["links"]?.array?.count ?? 0
        _ = memories.split(id: run["source_memory_id"]?.string ?? "", into: segments)
        return .object([
            "status": .string("applied"), "created": .int(segments.count), "links": .int(links),
            "message": .string("Split into \(segments.count) memories."),
        ])
    }
}

/// The addresses a person has claimed, with the look and the home page each has now.
final class UITestRealms: @unchecked Sendable {
    private struct Claim {
        let id: String
        let subdomain: String
        let base: String
        var theme: String?
        var home: String?
        let claimedAgo: TimeInterval
    }

    private let lock = NSLock()
    private var claims: [Claim] = [
        Claim(id: "c1", subdomain: "nova", base: "vault.cool", theme: "glassmorphism", home: "bakery-landing-page-x1", claimedAgo: 2_000_000),
        Claim(id: "c2", subdomain: "nova", base: "cleon.wiki", theme: nil, home: nil, claimedAgo: 1_000_000),
    ]

    func rows() -> [JSONValue] {
        lock.lock()
        defer { lock.unlock() }
        return claims.map { claim in
            .object([
                "id": .string(claim.id), "subdomain": .string(claim.subdomain), "base_domain": .string(claim.base),
                "theme": claim.theme.map(JSONValue.string) ?? .null,
                "default_artifact_slug": claim.home.map(JSONValue.string) ?? .null,
                "claimed_at": .string(UITestWorld.date(claim.claimedAgo)),
            ])
        }
    }

    /// `theme` and `home` are nil when the body did not carry them; a `.some(nil)` is a value taken off.
    func update(subdomain: String, base: String, theme: String??, home: String??) -> (theme: String?, home: String?)? {
        lock.lock()
        defer { lock.unlock() }
        guard let at = claims.firstIndex(where: { $0.subdomain == subdomain && $0.base == base }) else { return nil }
        if let theme { claims[at].theme = theme }
        if let home { claims[at].home = home }
        return (claims[at].theme, claims[at].home)
    }
}

/// The mail: what the canned mailbox starts with, and what the person sends and replies.
final class UITestMail: @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [JSONValue] = []
    private var count = 0

    private let inboxBase: [JSONValue] = UITestWorld.parse(MailPreviewData.inbox)["messages"]?.array ?? []
    private let threadBase: [JSONValue] = UITestWorld.parse(MailPreviewData.thread)["messages"]?.array ?? []

    /// A box, newest first. The inbox is what the agents wrote; Sent is what the person did.
    func box(_ name: String, unreadOnly: Bool) -> [JSONValue] {
        lock.lock()
        defer { lock.unlock() }
        switch name {
        case "sent": return Array(sent.reversed())
        case "inbox": return unreadOnly ? inboxBase.filter { $0["unread"]?.bool == true } : inboxBase
        default: return []
        }
    }

    /// A thread's messages, oldest first: the canned thread, then what was said in it.
    func thread(_ id: String) -> [JSONValue] {
        lock.lock()
        defer { lock.unlock() }
        let base = id == MailPreviewData.threadID ? threadBase : []
        return base + sent.filter { $0["thread_id"]?.string == id }
    }

    private func make(thread: String, subject: String, text: String) -> JSONValue {
        count += 1
        let id = "s-\(count)"
        let json = MailPreviewData.message(id, thread: thread, subject: subject, minutesAgo: 0, agent: nil, text: text, folder: "sent", from: "ana@vault.cool")
        let message = UITestWorld.parse(json)
        sent.append(message)
        return message
    }

    func send(subject: String, text: String) -> JSONValue {
        lock.lock()
        defer { lock.unlock() }
        let thread = String(format: "%08lx-0000-4000-8000-%012lx", 0x5e000000 + count + 1, count + 1)
        let title = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        return make(thread: thread, subject: title.isEmpty ? String(text.prefix(40)) : title, text: text)
    }

    func reply(to id: String, text: String) -> JSONValue? {
        lock.lock()
        defer { lock.unlock() }
        let everything = threadBase + inboxBase + sent
        guard let original = everything.first(where: { $0["id"]?.string == id }), let thread = original["thread_id"]?.string else { return nil }
        let subject = original["subject"]?.string ?? ""
        return make(thread: thread, subject: subject.hasPrefix("Re: ") ? subject : "Re: \(subject)", text: text)
    }
}
#endif
