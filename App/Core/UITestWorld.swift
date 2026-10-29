#if DEBUG
import Foundation
import HyperVaultKit

/// The canned server behind the UI-test mode (`UITestHarness`): every route the journeys reach, answered in the
/// shapes the real routes send. It exists only in debug builds and only a launch with `-HV_UITEST` reads it.
///
/// Nothing here can reach a real server. Both addresses end in `.invalid`, which never resolves, and
/// `UITestURLProtocol` answers anything that bypasses the app's mock transport (the page loader, the Supabase
/// reads) from the same table and refuses every other host.
///
/// To teach it a route a new journey needs, add a `MockRoute` to `sharedRoutes` or `vaultRoutes`. Routes are tried
/// in order and the first match wins, so a specific route goes before a prefix route (`/api/foo/*`).
enum UITestWorld {
    // MARK: The person and the addresses

    static let appURL = URL(string: "https://uitest.hypervault.invalid")!
    static let supabaseURL = URL(string: "https://uitest-project.supabase.invalid")!
    static let anonKey = "uitest-anon-key"
    static let user = AuthUser(id: "ui-test-user", email: "sam@example.com", displayName: "Sam Rivers")

    /// The one invite code the `waitlisted` scenario lets in. Any other code is refused.
    static let inviteCode = "HV-OPEN-DOOR"

    /// What the `signedIn` scenario leaves on the pasteboard, for the canvas's Paste button: long enough, and in
    /// enough lines, to wait above the field as a chip instead of going into it.
    static let pasteText = [
        "Lisbon trip checklist",
        "- Passports in the grey folder",
        "- Printed ferry tickets for Friday",
        "- Phone charger and a power bank",
        "- Book the tasca near the market for 12:30",
        "Leave by seven so we make the early crossing.",
    ].joined(separator: "\n")

    /// The signed-in session the secure store starts with. It expires long after any test run.
    static func session() -> AuthSession {
        AuthSession(
            accessToken: "uitest-access", refreshToken: "uitest-refresh",
            expiresAt: Date().addingTimeInterval(10 * 365 * 86_400), user: user
        )
    }

    // MARK: Routes

    /// The routes for a scenario, most specific first.
    static func routes(for scenario: UITestScenario) -> [MockRoute] {
        switch scenario {
        case .signedOut:
            let own: [MockRoute] = [capabilitiesRoute(letIn: { false })]
            return signInRoutes + own + fallbackRoutes
        case .signedIn:
            return writeRoutes() + sharedRoutes(letIn: { true }) + vaultRoutes + screenRoutes + previewRoutes + fallbackRoutes
        case .signedInAdmin:
            return writeRoutes() + sharedRoutes(letIn: { true }, admin: true) + vaultRoutes + screenRoutes + previewRoutes + fallbackRoutes
        case .signedInEmpty:
            return sharedRoutes(letIn: { true }) + emptyVaultRoutes + previewRoutes + fallbackRoutes
        case .signedInNoKeys:
            return noKeysRoutes + sharedRoutes(letIn: { true }) + emptyVaultRoutes + previewRoutes + fallbackRoutes
        case .waitlisted:
            // Signed in but not let in, until the invite code is redeemed: then the same vault as `signedIn`.
            let gate = UITestGate()
            let gated: [MockRoute] = [redeemRoute(gate: gate), yoursGateRoute(gate: gate)]
            return gated + writeRoutes() + sharedRoutes(letIn: { gate.isOpen }) + vaultRoutes + screenRoutes + previewRoutes + fallbackRoutes
        }
    }

    /// What the app's own screens already use to stand on canned answers (previews and snapshot tests), for the
    /// screens a journey only passes through.
    private static var previewRoutes: [MockRoute] {
        var routes: [MockRoute] = []
        routes += KeysPreviewData.routes
        routes += MemoryPreviewData.routes
        routes += ChatPreviewData.routes
        routes += MailPreviewData.threadRoutes
        routes += ToolsFixtures.routes
        routes += VaultPreviewData.routes
        return routes
    }

    /// Answers for anything no route above knows, so a screen that reads a list we did not think of gets an empty one
    /// rather than an error.
    private static var fallbackRoutes: [MockRoute] {
        [
            .json(.get, "/rest/v1/*", "[]"),
            .json(.post, "/rest/v1/waitlist", "", status: 201),
            .json(.get, "/api/jobs", #"{"jobs":[]}"#),
        ]
    }

    // MARK: Sign-in

    /// The auth server: what it offers (Google and email, not Apple), an email code that is accepted for sending
    /// and refused for verifying, and sign-out.
    private static var signInRoutes: [MockRoute] {
        [
            .json(.get, "/auth/v1/settings", #"{"external":{"google":true,"apple":false,"email":true},"disable_signup":false}"#),
            .json(.post, "/auth/v1/otp", "{}"),
            .json(.post, "/auth/v1/verify", #"{"code":403,"error_code":"otp_expired","msg":"Token has expired or is invalid"}"#, status: 403),
            .json(.post, "/auth/v1/logout", "", status: 204),
        ]
    }

    /// `GET /api/capabilities`. The `user` block is what tells the app the gate let this person in.
    private static func capabilitiesRoute(letIn: @escaping @Sendable () -> Bool) -> MockRoute {
        MockRoute(.get, "/api/capabilities") { _ in
            var body: [String: JSONValue] = [
                "app_url": .string(appURL.absoluteString),
                "api_version": .string("2026-07-15"),
                "auth": .object([
                    "supabase_url": .string(supabaseURL.absoluteString),
                    "supabase_anon_key": .string(anonKey),
                    "invite_gated": .bool(true),
                ]),
                "features": .object([:]),
                "limits": .object([:]),
                "providers": .array([]),
                "domains": .array([
                    .object(["domain": .string("vault.cool"), "tagline": .string("The legendary original. you.vault.cool"), "featured": .bool(true), "available": .bool(true)]),
                    .object(["domain": .string("agentvault.cloud"), "tagline": .string("For agents with their heads in the cloud"), "available": .bool(true)]),
                    .object(["domain": .string("cleon.wiki"), "tagline": .string("For knowledge bases and living documents"), "available": .bool(true)]),
                    .object(["domain": .string("later.example"), "tagline": .string("Not open yet"), "available": .bool(false)]),
                ]),
                "themes": .array([
                    .object(["id": .string("modern-dark"), "name": .string("Modern Dark"), "mode": .string("dark")]),
                    .object(["id": .string("glassmorphism"), "name": .string("Glassmorphism"), "mode": .string("dark")]),
                    .object(["id": .string("newsprint"), "name": .string("Newsprint"), "mode": .string("light")]),
                ]),
            ]
            if letIn() {
                body["user"] = .object(["id": .string(user.id), "email": .string(user.email ?? ""), "via": .string("bearer")])
            }
            return reply(.object(body))
        }
    }

    // MARK: Waitlist

    /// `redeem_invite_code`: the right code opens the gate, anything else is "invalid".
    private static func redeemRoute(gate: UITestGate) -> MockRoute {
        MockRoute(.post, "/rest/v1/rpc/redeem_invite_code") { request in
            let sent = String(decoding: request.httpBody ?? Data(), as: UTF8.self).uppercased()
            if sent.contains(inviteCode) {
                gate.open()
                return reply(raw: "\"ok\"")
            }
            return reply(raw: "\"invalid\"")
        }
    }

    /// The gate itself: Yours refuses with the waitlist sentence until the code has been redeemed.
    private static func yoursGateRoute(gate: UITestGate) -> MockRoute {
        MockRoute(.get, "/api/yours") { request in
            guard gate.isOpen else {
                let message = "Your account is on the waitlist \u{2014} redeem an invite code to unlock the API."
                return reply(.object(["error": .string(message)]), status: 403)
            }
            return yours(request: request, things: things)
        }
    }

    // MARK: Signed in, with things kept

    private static func sharedRoutes(letIn: @escaping @Sendable () -> Bool, admin: Bool = false) -> [MockRoute] {
        let counter = UITestCounter()
        let own: [MockRoute] = [
            capabilitiesRoute(letIn: letIn),
            keepRoute(counter: counter),
            chatRoute,
            .json(.post, "/api/yours/open", #"{"persisted":true}"#),
            yoursCardRoute,
            artifactPageRoute,
        ]
        return signInRoutes + own + adminRoutes(isAdmin: admin)
    }

    /// What a signed-in person with a few things kept, a connected model and some history sees.
    private static var vaultRoutes: [MockRoute] {
        [
            MockRoute(.get, "/api/yours") { request in yours(request: request, things: things) },
            .json(.get, "/api/backends", backendsJSON),
            artifactsRoute,
            .json(.get, "/api/artifact-groups", artifactGroupsJSON),
            artifactDetailRoute,
        ]
    }

    /// Who has the Bakery page, and how it has changed: what its Share and History sheets list.
    private static func versionsJSON(slug: String) -> JSONValue {
        func version(_ id: String, parent: String?, message: String, kind: String, ago: TimeInterval, head: Bool) -> JSONValue {
            .object([
                "id": .string(id), "parent_version_id": parent.map(JSONValue.string) ?? .null, "title": .string("Bakery landing page"),
                "message": .string(message), "author_kind": .string(kind), "author_key_prefix": .null, "content_hash": .string("h-\(id)"),
                "is_jsx": .bool(false), "is_head": .bool(head), "created_at": .string(date(ago)),
            ])
        }
        return .object([
            "slug": .string(slug), "mutable": .bool(true),
            "versions": .array([
                version("v3", parent: "v2", message: "Open at seven on weekdays", kind: "user", ago: 7_200, head: true),
                version("v2", parent: "v1", message: "Add the opening hours", kind: "user", ago: 90_000, head: false),
                version("v1", parent: nil, message: "create", kind: "system", ago: 400_000, head: false),
            ]),
        ])
    }

    /// A person with no agent key, whose profile has stamped nothing, and the route that records "I'll look around first"
    /// (`PATCH /api/onboarding`). They go before the preview routes, which list three keys.
    private static var noKeysRoutes: [MockRoute] {
        [
            .json(.get, "/rest/v1/api_keys", "[]"),
            .json(.get, "/rest/v1/profiles", #"[{"onboarding":{}}]"#),
            .json(.patch, "/api/onboarding", #"{"persisted":true,"onboarding":{}}"#),
        ]
    }

    /// A person who has kept nothing and connected no model.
    private static var emptyVaultRoutes: [MockRoute] {
        [
            .json(.get, "/api/yours", #"{"recent":[],"results":[]}"#),
            .json(.get, "/api/backends", #"{"backends":[],"providers":[]}"#),
            .json(.get, "/api/memories", #"{"branch":"main","memories":[]}"#),
            .json(.get, "/api/conversations", #"{"conversations":[]}"#),
            .json(.get, "/api/rooms", #"{"rooms":[]}"#),
            .json(.get, "/api/artifacts", #"{"items":[]}"#),
            .json(.get, "/api/artifact-groups", #"{"items":[]}"#),
            .json(.get, "/api/connections", #"{"connections":[],"memory_links":[],"memory_artifact_links":[]}"#),
        ]
    }

    // MARK: Things kept

    struct Thing {
        let id: String
        let kind: String
        let name: String
        let summary: String
        let href: String
        let updatedAgo: TimeInterval
        let openedAgo: TimeInterval?

        /// The artifact slug of a page, file or group (`/a/<slug>`, `/g/<slug>`).
        var slug: String? {
            let parts = href.split(separator: "/").map(String.init)
            guard parts.count >= 2, parts[0] == "a" || parts[0] == "g" else { return nil }
            return parts[1]
        }

        /// Whether the Yours filter (`all`, `memory`, `file`, `key`) shows this: Files are every artifact.
        func shown(by filter: String) -> Bool {
            switch filter {
            case "memory": return kind == "memory"
            case "key": return kind == "key"
            case "file": return kind == "page" || kind == "file" || kind == "group"
            default: return true
            }
        }

        var json: JSONValue {
            .object([
                "id": .string(id),
                "kind": .string(kind),
                "name": .string(name),
                "summary": .string(summary),
                "updated_at": .string(UITestWorld.date(updatedAgo)),
                "last_opened_at": openedAgo.map { JSONValue.string(UITestWorld.date($0)) } ?? JSONValue.null,
                "href": .string(href),
            ])
        }
    }

    static let things: [Thing] = [
        Thing(id: "a1", kind: "page", name: "Bakery landing page", summary: "", href: "/a/bakery-landing-page-x1", updatedAgo: 7_200, openedAgo: 1_800),
        Thing(id: "m1", kind: "memory", name: "Trip to Lisbon: ferry and passports", summary: "Book the Friday ferry across the Tagus.", href: "/vault/memory?open=m1", updatedAgo: 90_000, openedAgo: 9_000),
        Thing(id: "k1", kind: "key", name: "OPENAI_API_KEY", summary: "2 agents allowed", href: "/vault/account", updatedAgo: 400_000, openedAgo: 20_000),
        Thing(id: "g1", kind: "group", name: "Portfolio site", summary: "", href: "/g/portfolio-site", updatedAgo: 900_000, openedAgo: nil),
        Thing(id: "a2", kind: "page", name: "Trip to Lisbon", summary: "", href: "/a/trip-to-lisbon-q7", updatedAgo: 1_300_000, openedAgo: nil),
        Thing(id: "m2", kind: "memory", name: "Auth decision: passkeys first", summary: "We chose passkeys with email codes as the fallback.", href: "/vault/memory?open=m2", updatedAgo: 1_800_000, openedAgo: nil),
        Thing(id: "m3", kind: "memory", name: "Planning chat with Sam", summary: "Budget is set at 40k, ship in March.", href: "/vault/memory?open=m3", updatedAgo: 2_400_000, openedAgo: nil),
    ]

    /// `GET /api/yours?kind=&q=&limit=`: what is kept, narrowed the way the server narrows it. The head of the list
    /// (Recent) is only sent for the plain, unfiltered read.
    static func yours(request: URLRequest, things: [Thing]) -> HTTPResponse {
        let filter = request.queryValue("kind") ?? "all"
        let text = (request.queryValue("q") ?? "").lowercased()
        let limit = Int(request.queryValue("limit") ?? "") ?? 50
        var results = things.filter { $0.shown(by: filter) }
        if !text.isEmpty {
            results = results.filter { $0.name.lowercased().contains(text) || $0.summary.lowercased().contains(text) }
        }
        let plain = filter == "all" && text.isEmpty
        let recent = plain ? things.filter { $0.openedAgo != nil }.sorted { ($0.openedAgo ?? 0) < ($1.openedAgo ?? 0) } : []
        return reply(.object([
            "recent": .array(recent.map(\.json)),
            "results": .array(results.prefix(limit).map(\.json)),
        ]))
    }

    /// `GET /api/yours/card?kind=&id=` (or `?slug=`): what a card on the canvas says about a thing.
    private static var yoursCardRoute: MockRoute {
        MockRoute(.get, "/api/yours/card") { request in
            let id = request.queryValue("id")
            let slug = request.queryValue("slug")
            guard let thing = things.first(where: { $0.id == id || (slug != nil && $0.slug == slug) }) else {
                return reply(.object(["error": .string("Not found")]), status: 404)
            }
            var card: [String: JSONValue] = [
                "id": .string(thing.id),
                "kind": .string(thing.kind),
                "name": .string(thing.name),
                "href": .string(thing.href),
                "updated_at": .string(date(thing.updatedAgo)),
            ]
            if thing.kind == "memory" { card["digest"] = .string(thing.summary) }
            if thing.kind == "key" {
                card["agents"] = .array([.object(["id": .string("ag1"), "name": .string("Claude Code"), "key_prefix": .string("hv_Zk3pQ9vL")])])
            }
            return reply(.object(card))
        }
    }

    // MARK: Keeping and chatting

    /// `POST /api/keep`: keeps whatever was sent and answers with a private link. The title is the first line, the
    /// slug the title and a count, so two keeps are two things.
    private static func keepRoute(counter: UITestCounter) -> MockRoute {
        MockRoute(.post, "/api/keep") { request in
            let content = request.jsonBody?["content"] as? String ?? ""
            let title = keptTitle(for: content)
            let slug = "\(slugify(title))-k\(counter.next())"
            return reply(.object([
                "slug": .string(slug),
                "url": .string(appURL.appendingPathComponent("a").appendingPathComponent(slug).absoluteString),
                "kind": .string("page"),
                "form": .string("note"),
                "title": .string(title),
                "visibility": .string("private"),
                "duplicate": .bool(false),
                "message": .string("Kept. Here's the link."),
            ]))
        }
    }

    /// What Memory's Ask mode is told when it asks, and the memory it says it drew from.
    static let askAnswer = "Your Lisbon notes say to book the Friday ferry across the Tagus and to bring both passports."
    static let askSource = "Trip to Lisbon: ferry and passports"

    /// `POST /api/chat`: the connected model's reply, which says what it was told (short, so its title is all of it).
    /// Memory's Ask mode is the one asker that turns recall on without anything else a chat turn sends (the smart-context
    /// switch, tools), and it is answered from the memory it recalls.
    private static var chatRoute: MockRoute {
        MockRoute(.post, "/api/chat") { request in
            chatAnswer(request, conversation: request.jsonBody?["conversation_id"] as? String ?? "c-uitest")
        }
    }

    /// The model's answer to a turn sent in `conversation`.
    static func chatAnswer(_ request: URLRequest, conversation: String) -> HTTPResponse {
        let body = request.jsonBody
        let message = body?["message"] as? String ?? ""
        let asksMemory = body?["use_recall"] as? Bool == true && body?["use_smart_context"] == nil && body?["use_tools"] == nil
        var answer: [String: JSONValue] = [
            "conversation_id": .string(conversation),
            "reply": .object([
                "id": .string("r-uitest"),
                "role": .string("assistant"),
                "content": .string(asksMemory ? askAnswer : "Noted: \(message)"),
                "model": .string("claude-opus-4-8"),
                "truncated": .bool(false),
            ]),
            "backend": .object(["id": .string("b1"), "name": .string("My Claude"), "provider": .string("anthropic")]),
            "recalled": .array([]),
            "recalled_memories": .array(asksMemory ? [.string(askSource)] : []),
            "pulled": .array([]),
        ]
        if asksMemory {
            // What the ledger and the conversation graph add to an answer, which Ask shows under it.
            answer["truth"] = .object([
                "cited": .int(2), "contested": .int(1), "flags": .int(0), "drafted": .int(0), "ledgers": .array([.string("main")]),
            ])
            answer["deep_memory"] = .array([.string("Lisbon trip")])
        }
        return reply(.object(answer))
    }

    private static var backendsJSON: String {
        #"{"backends":[{"id":"b1","name":"My Claude","provider":"anthropic","default_model":"claude-opus-4-8","key_hint":"sk-ant-\#u{2026}abcd","created_at":"2026-10-01T00:00:00Z","last_used_at":null}],"providers":[]}"#
    }

    private static func keptTitle(for content: String) -> String {
        let first = content.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let plain = first.trimmingCharacters(in: CharacterSet(charactersIn: "#*` ").union(.whitespaces))
        let clipped = String(plain.prefix(48)).trimmingCharacters(in: .whitespaces)
        return clipped.isEmpty ? "Untitled" : clipped
    }

    private static func slugify(_ title: String) -> String {
        let words = title.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) })
        let joined = words.prefix(6).joined(separator: "-")
        return joined.isEmpty ? "note" : joined
    }

    // MARK: Pages

    private static var artifactsJSON: String {
        func item(_ slug: String, _ title: String, type: String, secondsAgo: TimeInterval) -> JSONValue {
            .object([
                "slug": .string(slug),
                "title": .string(title),
                "type": .string(type),
                "tags": .array([]),
                "source_prompt": .null,
                "is_pwa": .bool(false),
                "is_jsx": .bool(false),
                "visibility": .string("private"),
                "icon": .null,
                "created_at": .string(date(secondsAgo)),
                "url": .string(appURL.appendingPathComponent(type == "group" ? "g" : "a").appendingPathComponent(slug).absoluteString),
            ])
        }
        return JSONValue.object(["items": .array([
            item("bakery-landing-page-x1", "Bakery landing page", type: "html", secondsAgo: 7_200),
            item("trip-to-lisbon-q7", "Trip to Lisbon", type: "html", secondsAgo: 1_300_000),
            item("portfolio-site", "Portfolio site", type: "group", secondsAgo: 900_000),
        ])]).jsonString()
    }

    private static var artifactGroupsJSON: String {
        JSONValue.object(["items": .array([
            .object([
                "id": .string("g1"), "slug": .string("portfolio-site"), "title": .string("Portfolio site"), "tags": .array([]),
                "visibility": .string("private"), "created_at": .string(date(900_000)),
                "url": .string(appURL.appendingPathComponent("g").appendingPathComponent("portfolio-site").absoluteString),
            ]),
        ])]).jsonString()
    }

    private static var artifactsRoute: MockRoute {
        MockRoute(.get, "/api/artifacts") { _ in reply(raw: artifactsJSON) }
    }

    /// `/api/artifacts/<slug>/content`, `/feedback` and the like, by what the path ends with.
    private static var artifactDetailRoute: MockRoute {
        MockRoute(.get, "/api/artifacts/*", handler: artifactDetail)
    }

    /// The reads under a page, by what the path ends with (the page the journeys open is the Bakery page).
    static func artifactDetail(_ request: URLRequest) -> HTTPResponse {
        let path = request.url?.path ?? ""
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 4 else { return reply(.object(["error": .string("Not found")]), status: 404) }
        let slug = parts[2]
        switch parts[3] {
        case "content":
            return reply(.object([
                "slug": .string(slug),
                "title": .string("Bakery landing page"),
                "content": .string("<h1>Fresh bread daily</h1>\n<p>Open at seven.</p>"),
                "is_jsx": .bool(false),
                "mutable": .bool(true),
                "content_hash": .string("h1"),
                "head_version_id": .string("v1"),
            ]))
        case "source":
            return reply(.object(["content": .string(pageHTML)]))
        case "feedback":
            return reply(.object(["feedback": .null]))
        case "versions":
            return reply(versionsJSON(slug: slug))
        default:
            return reply(.object(["error": .string("Not found")]), status: 404)
        }
    }

    static let pageHTML = """
    <!doctype html>
    <html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Bakery landing page</title></head>
    <body><h1>Fresh bread daily</h1><p>Open at seven.</p></body></html>
    """

    /// `GET /a/<slug>`: the page itself, which the app fetches with its own loader and hands to the web view.
    /// (This one is answered through `UITestURLProtocol`, not the mock transport.)
    private static var artifactPageRoute: MockRoute {
        MockRoute(.get, "/a/*") { _ in
            HTTPResponse(status: 200, headers: ["content-type": "text/html; charset=utf-8"], data: Data(pageHTML.utf8))
        }
    }

    // MARK: Helpers

    static func reply(_ value: JSONValue, status: Int = 200) -> HTTPResponse {
        reply(raw: value.jsonString(), status: status)
    }

    static func reply(raw text: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["content-type": "application/json"], data: Data(text.utf8))
    }

    /// A timestamp this many seconds in the past, so "2 hr ago" is true whenever the test runs.
    static func date(_ secondsAgo: TimeInterval) -> String {
        HVDate.format(Date().addingTimeInterval(-secondsAgo))
    }
}

// MARK: - Small pieces the routes share

/// Something a route flips while a scenario plays out, from whatever thread the request arrives on.
final class UITestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false

    var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return opened
    }

    func open() {
        lock.lock()
        opened = true
        lock.unlock()
    }
}

/// A count a route reads and bumps, so two keeps get two slugs.
final class UITestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

extension URLRequest {
    func queryValue(_ name: String) -> String? {
        guard let url, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        return items.first { $0.name == name }?.value
    }

    var jsonBody: [String: Any]? {
        guard let httpBody else { return nil }
        return (try? JSONSerialization.jsonObject(with: httpBody)) as? [String: Any]
    }
}
#endif
