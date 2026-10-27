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
        return pageRoutes(vault) + memoryRoutes(memories) + secretRoutes(secrets) + boardRoutes(boards) + mailRoutes(mail)
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
