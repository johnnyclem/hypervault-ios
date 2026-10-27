#if DEBUG
import Foundation
import HyperVaultKit

/// What the screens behind the You tab (and what they open) are shown, in the shapes the real routes send: the keys, the
/// address, the ledger, the task boards, a room, the admin's codes. `UITestWorld.routes(for:)` puts these before the
/// canned answers the previews use, so a route a journey needs is answered here first.
///
/// Anything that changes while a journey plays (a key is made, a key is revoked, a message is sent to a room) lives in a
/// small object that one launch owns: every call of `screenRoutes` builds a fresh set, so a launch starts as the first one did.
extension UITestWorld {
    /// Every route the screens below need, for a person who has things kept.
    static var screenRoutes: [MockRoute] {
        var routes: [MockRoute] = []
        routes += keysRoutes(UITestKeys())
        // Before the addresses: this answers the profile row, which carries the website's theme as well as the plan.
        routes += dashboardThemeRoutes(UITestDashboardTheme())
        routes += realmsRoutes
        routes += roomRoutes(UITestRoom())
        routes += truthRoutes
        routes += TaskBoardPreviewData.indexRoutes
        routes += TaskBoardPreviewData.boardRoutes
        routes += importRoutes
        routes += artifactSharingRoutes
        return routes
    }

    // MARK: Account & keys

    /// A key, as `rest/v1/api_keys` lists it.
    static func keyRow(_ id: String, prefix: String, name: String, madeAgo: TimeInterval, usedAgo: TimeInterval?, canSendMail: Bool = false) -> JSONValue {
        .object([
            "id": .string(id), "key_prefix": .string(prefix), "name": .string(name),
            "created_at": .string(date(madeAgo)),
            "last_used_at": usedAgo.map { JSONValue.string(date($0)) } ?? JSONValue.null,
            "scopes": .array(canSendMail ? [.string("mail:read"), .string("mail:send")] : [.string("mail:read")]),
            "mail_claim_id": .null, "mail_pin_cleared": .bool(false),
        ])
    }

    /// The keys a person has, a key made from the Connect sheet, and a key revoked from Account & keys: the list the
    /// next read answers with is the one the journey has made.
    private static func keysRoutes(_ keys: UITestKeys) -> [MockRoute] {
        [
            MockRoute(.get, "/rest/v1/api_keys") { _ in reply(raw: keys.json) },
            MockRoute(.post, "/api/keys") { request in
                let name = (request.jsonBody?["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "default"
                let made = keys.mint(name: name)
                return reply(.object([
                    "key": .string(made.key), "prefix": .string(made.prefix),
                    "challenge": .object(["slug": .string("agent-setup-\(made.id)"), "url": .string(appURL.appendingPathComponent("a/agent-setup-\(made.id)").absoluteString)]),
                    "message": .string("Copy this key now."),
                ]))
            },
            MockRoute(.delete, "/api/keys") { request in
                guard let id = request.jsonBody?["id"] as? String, keys.revoke(id: id) else {
                    return reply(.object(["error": .string("No such key.")]), status: 404)
                }
                return reply(.object(["revoked": .string(id)]))
            },
            // The setup challenges of the keys: the same table holds the pages a realm can open to, told apart by the filter.
            MockRoute(.get, "/rest/v1/artifacts") { request in
                if request.url?.query?.contains("type=neq.group") == true { return reply(raw: homeOptionsJSON) }
                return reply(raw: KeysPreviewData.pagesJSON)
            },
            .json(.get, "/rest/v1/artifact_versions", KeysPreviewData.versionsJSON),
            // The steps for the app a key is made for (the server's registry page for it).
            MockRoute(.get, "/connect.md") { _ in
                HTTPResponse(status: 200, headers: ["content-type": "text/markdown"], data: Data(ConnectPreviewData.cursorMarkdown.utf8))
            },
        ]
    }

    // MARK: Your address

    private static let homeOptionsJSON = JSONValue.array([
        .object(["slug": .string("bakery-landing-page-x1"), "title": .string("Bakery landing page"), "type": .string("html"), "visibility": .string("public")]),
        .object(["slug": .string("trip-to-lisbon-q7"), "title": .string("Trip to Lisbon"), "type": .string("html"), "visibility": .string("private")]),
    ]).jsonString()

    /// A Pro plan with two addresses claimed, one with a look and a home page and one with neither.
    private static var realmsRoutes: [MockRoute] {
        [
            MockRoute(.get, "/rest/v1/domain_claims") { _ in
                reply(.array([
                    .object([
                        "id": .string("c1"), "subdomain": .string("nova"), "base_domain": .string("vault.cool"), "theme": .string("glassmorphism"),
                        "default_artifact_slug": .string("bakery-landing-page-x1"), "claimed_at": .string(date(2_000_000)),
                    ]),
                    .object([
                        "id": .string("c2"), "subdomain": .string("nova"), "base_domain": .string("cleon.wiki"), "theme": .null,
                        "default_artifact_slug": .null, "claimed_at": .string(date(1_000_000)),
                    ]),
                ]))
            },
            .json(.get, "/api/claim-domain", #"{"available":true}"#),
        ]
    }

    // MARK: The website's theme

    /// The person's profile row, a Pro plan with the website wearing Glassmorphism, and the route that changes the theme. The
    /// themes it takes are the three the canned capabilities list.
    private static func dashboardThemeRoutes(_ theme: UITestDashboardTheme) -> [MockRoute] {
        let known: Set<String> = ["modern-dark", "glassmorphism", "newsprint"]
        return [
            MockRoute(.get, "/rest/v1/profiles") { _ in
                reply(.array([.object([
                    "plan": .string("pro"), "vanity_subdomain": .string("nova"),
                    "theme": theme.current.map(JSONValue.string) ?? .null,
                ])]))
            },
            MockRoute(.patch, "/api/dashboard-theme") { request in
                let next = body(request)["theme"]?.string
                if let next, !known.contains(next) {
                    return reply(.object(["error": .string("Unknown theme. Pick one of: modern-dark, glassmorphism, newsprint - or null for the HyperVault default.")]), status: 400)
                }
                theme.set(next)
                return reply(.object(["theme": next.map(JSONValue.string) ?? .null, "message": .string("Your dashboard now wears \(next ?? "the stock look").")]))
            },
        ]
    }

    // MARK: Rooms

    private static let roomMembers: [JSONValue] = {
        func member(_ id: String, _ handle: String, _ name: String, _ provider: String, _ model: String, _ position: Int, _ brief: String) -> JSONValue {
            .object([
                "id": .string(id), "room_id": .string("r1"), "backend_id": .string("b-\(handle)"), "handle": .string(handle),
                "role_brief": .string(brief), "position": .int(position),
                "backend": .object(["name": .string(name), "provider": .string(provider), "default_model": .string(model)]),
            ])
        }
        return [
            member("m1", "grok", "Grok", "xai", "grok-4", 0, "The importer and the API contract."),
            member("m3", "claude", "Claude", "anthropic", "claude-opus-4-8", 1, "Architecture first, then review both."),
        ]
    }()

    static func roomMessage(_ id: String, position: Int, kind: String, handle: String?, content: String, mentions: [String] = [], ago: TimeInterval) -> JSONValue {
        .object([
            "id": .string(id), "room_id": .string("r1"), "position": .int(position), "sender_kind": .string(kind),
            "sender_handle": handle.map(JSONValue.string) ?? JSONValue.null, "member_id": .null, "content": .string(content),
            "mentions": .array(mentions.map(JSONValue.string)), "tool_turns": .array([]), "model": .null,
            "status": .string("complete"), "created_at": .string(date(ago)),
        ])
    }

    /// The Features X and Y room: three messages already, and what is said to it joins them with an answer from `claude`.
    private static func roomRoutes(_ room: UITestRoom) -> [MockRoute] {
        let started: [JSONValue] = [
            roomMessage("x1", position: 0, kind: "human", handle: nil, content: "grok - you take the importer; claude - architecture first, then review it.", mentions: ["grok", "claude"], ago: 900),
            roomMessage("x2", position: 1, kind: "agent", handle: "claude", content: "Schema is up. The importer reads one file at a time.\n\n@grok the API contract is yours now.", mentions: ["grok"], ago: 800),
            roomMessage("x3", position: 2, kind: "agent", handle: "grok", content: "On it. Contract committed as v3; the importer streams rows in batches of 500.", ago: 700),
        ]
        return [
            MockRoute(.get, "/api/rooms/r1") { _ in
                reply(.object([
                    "room": .object([
                        "id": .string("r1"), "title": .string("Features X and Y"), "pending": .array([]), "budget": .int(12), "running": .bool(false),
                        "truth_ledgers": .null, "created_at": .string(date(90_000)), "updated_at": .string(date(600)),
                    ]),
                    "members": .array(roomMembers),
                    "messages": .array(started + room.messages()),
                ]))
            },
            MockRoute(.post, "/api/rooms/r1/messages") { request in
                let content = request.jsonBody?["content"] as? String ?? ""
                let sent = room.say(content, startingAt: started.count)
                return reply(.object(["messages": .array(sent), "pending": .array([]), "budget": .int(11), "busy": .bool(false)]))
            },
            MockRoute(.post, "/api/rooms/r1/run") { _ in
                reply(.object(["messages": .array([]), "pending": .array([]), "budget": .int(11), "busy": .bool(false)]))
            },
        ]
    }

    // MARK: Truth

    /// The ledger, its review docket and the entry with something beneath it. (The review's own room list is left to the
    /// chat's, which comes later in the table.)
    private static var truthRoutes: [MockRoute] {
        var routes = TruthPreviewData.ledgerRoutes
        routes += TruthPreviewData.reviewRoutes.filter { $0.path != "/api/rooms" }
        routes += TruthPreviewData.entryRoutes
        routes += TruthPreviewData.draftRoutes
        routes += TruthPreviewData.noticeRoutes
        routes += TruthPreviewData.staleRoutes
        routes += TruthPreviewData.signerRoutes
        return routes
    }

    // MARK: Import

    /// `POST /api/import`: every conversation sent is taken, with two messages in it.
    private static var importRoutes: [MockRoute] {
        [.json(.post, "/api/import", #"{"platform":"other","imported":1,"skipped":0,"messages":2,"message":"Imported 1 conversation."}"#)]
    }

    // MARK: Sharing a page

    /// Who else can open the Bakery page.
    private static var artifactSharingRoutes: [MockRoute] {
        [
            MockRoute(.get, "/api/shares") { _ in
                reply(.object([
                    "shares": .array([
                        .object(["id": .string("s1"), "email": .string("maya@example.com"), "display_name": .string("Maya"), "role": .string("edit"), "created_at": .string(date(500_000))]),
                    ]),
                    "roles": .array([.string("view"), .string("use"), .string("edit")]),
                    "roles_enforced": .bool(true),
                ]))
            },
        ]
    }

    // MARK: Admin

    /// The admin check the You tab makes (an empty `PATCH` to an invite that does not exist) and the codes an admin mints.
    /// Every admin route refuses a person who is not an admin with a 403, which is what the check reads; an admin gets past
    /// the guard and is refused for the empty body (a 400).
    static func adminRoutes(isAdmin: Bool) -> [MockRoute] {
        guard isAdmin else {
            return [MockRoute(nil, "/api/admin/*") { _ in reply(.object(["error": .string("Forbidden")]), status: 403) }]
        }
        let invites = UITestInvites()
        return [
            MockRoute(.patch, "/api/admin/invites/*") { request in
                let id = request.url?.lastPathComponent ?? ""
                guard let disabled = request.jsonBody?["disabled"] as? Bool else {
                    return reply(.object(["error": .string("Pass { disabled: boolean }.")]), status: 400)
                }
                guard let row = invites.setDisabled(disabled, id: id) else {
                    return reply(.object(["error": .string("No such invite code.")]), status: 404)
                }
                return reply(.object(["invite": row]))
            },
            MockRoute(.post, "/api/admin/invites") { request in
                let uses = request.jsonBody?["maxUses"] as? Int ?? 1
                let note = request.jsonBody?["note"] as? String
                return reply(.object(["invite": invites.mint(maxUses: uses, note: note)]), status: 201)
            },
            MockRoute(.delete, "/api/admin/invites/*") { request in
                invites.remove(id: request.url?.lastPathComponent ?? "")
                return reply(.object(["ok": .bool(true)]))
            },
            MockRoute(nil, "/api/admin/*") { _ in reply(.object(["ok": .bool(true)])) },
        ]
    }
}

// MARK: - What changes while a journey plays

/// The theme the person's website dashboard wears (`profiles.theme`).
final class UITestDashboardTheme: @unchecked Sendable {
    private let lock = NSLock()
    private var theme: String? = "glassmorphism"

    var current: String? {
        lock.lock()
        defer { lock.unlock() }
        return theme
    }

    func set(_ next: String?) {
        lock.lock()
        theme = next
        lock.unlock()
    }
}

/// The keys a person has. Made from the Connect sheet, revoked from Account & keys.
final class UITestKeys: @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [JSONValue] = [
        UITestWorld.keyRow("k1", prefix: "hv_Zk3pQ9vL", name: "Claude Code", madeAgo: 450_000, usedAgo: 3_600, canSendMail: true),
        UITestWorld.keyRow("k2", prefix: "hv_Aa1Bb2Cc", name: "Paired: Cursor on Sam's Mac", madeAgo: 600_000, usedAgo: nil),
        UITestWorld.keyRow("k3", prefix: "hv_Dd3Ee4Ff", name: "default", madeAgo: 1_200_000, usedAgo: 900_000),
    ]
    private var made = 0

    /// What `GET /rest/v1/api_keys` answers: newest first.
    var json: String {
        lock.lock()
        defer { lock.unlock() }
        return JSONValue.array(rows).jsonString()
    }

    /// A key the server makes: `hv_` and 32 characters, shown once.
    func mint(name: String) -> (id: String, key: String, prefix: String) {
        lock.lock()
        defer { lock.unlock() }
        made += 1
        let prefix = "hv_Qm7TnB4\(made)"
        let key = prefix + "V2cLp9RsYd3KfJ8aWz6NeHu1"
        let id = "k\(3 + made)"
        rows.insert(UITestWorld.keyRow(id, prefix: prefix, name: name, madeAgo: 5, usedAgo: nil), at: 0)
        return (id, key, prefix)
    }

    /// Whether there was such a key.
    func revoke(id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let before = rows.count
        rows.removeAll { $0["id"]?.string == id }
        return rows.count < before
    }
}

/// What has been said in the room, after what it started with.
final class UITestRoom: @unchecked Sendable {
    private let lock = NSLock()
    private var said: [JSONValue] = []

    func messages() -> [JSONValue] {
        lock.lock()
        defer { lock.unlock() }
        return said
    }

    /// Records what the person said and the answer `claude` gives, and returns both as the run that carried them.
    func say(_ content: String, startingAt first: Int) -> [JSONValue] {
        lock.lock()
        defer { lock.unlock() }
        let position = first + said.count
        let mine = UITestWorld.roomMessage("h\(position)", position: position, kind: "human", handle: nil, content: content, mentions: ["claude"], ago: 5)
        let answer = UITestWorld.roomMessage("a\(position + 1)", position: position + 1, kind: "agent", handle: "claude", content: "Noted: \(content)", ago: 2)
        said += [mine, answer]
        return [mine, answer]
    }
}

/// The invite codes an admin has minted from the phone.
final class UITestInvites: @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [String: JSONValue] = [:]
    private var made = 0

    func mint(maxUses: Int, note: String?) -> JSONValue {
        lock.lock()
        defer { lock.unlock() }
        made += 1
        let id = "3f1c1a2e-0000-4000-8000-00000000000\(made)"
        let row: JSONValue = .object([
            "id": .string(id), "code": .string("HV-UIT\(made)-K7QM"), "note": note.map(JSONValue.string) ?? JSONValue.null,
            "max_uses": .int(maxUses), "use_count": .int(0), "disabled": .bool(false),
            "created_by": .string(UITestWorld.user.id), "created_at": .string(UITestWorld.date(1)),
        ])
        rows[id] = row
        return row
    }

    func setDisabled(_ disabled: Bool, id: String) -> JSONValue? {
        lock.lock()
        defer { lock.unlock() }
        guard case .object(var fields)? = rows[id] else { return nil }
        fields["disabled"] = .bool(disabled)
        rows[id] = .object(fields)
        return rows[id]
    }

    func remove(id: String) {
        lock.lock()
        defer { lock.unlock() }
        rows[id] = nil
    }
}
#endif
