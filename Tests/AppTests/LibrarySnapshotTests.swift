import HyperVaultKit
import SwiftUI
import XCTest
@testable import HyperVault

/// The Library and the page screens, on canned answers. The web view itself is
/// not drawn by a snapshot; what is checked here is the chrome around it.
@MainActor
final class LibrarySnapshotTests: XCTestCase {
    // MARK: Fixtures

    static let yours = #"""
    {"recent":[],"results":[
     {"id":"m1","kind":"memory","name":"Co-parenting notes","summary":"Pickup on Tuesdays, swim on Thursday.","updated_at":"2026-10-25T20:00:00.000Z","last_opened_at":null,"href":"/vault/memory?open=m1"},
     {"id":"a1","kind":"page","name":"Pomodoro Timer","summary":"","updated_at":"2026-10-20T10:00:00.000Z","last_opened_at":"2026-10-25T21:30:00.000Z","href":"/a/pomodoro-timer-x7k2p9"},
     {"id":"g1","kind":"group","name":"Trip planner","summary":"","updated_at":"2026-10-18T10:00:00.000Z","last_opened_at":null,"href":"/g/trip-planner-abc123"},
     {"id":"f1","kind":"file","name":"Lease.pdf","summary":"","updated_at":"2026-09-01T10:00:00.000Z","last_opened_at":null,"href":"/a/lease-pdf-123456"},
     {"id":"k1","kind":"key","name":"OPENAI_API_KEY","summary":"2 agents allowed","updated_at":"2026-08-01T10:00:00.000Z","last_opened_at":null,"href":"/vault/account#secrets"}
    ]}
    """#

    static let artifacts = #"""
    {"items":[
     {"slug":"pomodoro-timer-x7k2p9","title":"Pomodoro Timer","type":"react","tags":["timer","focus","work"],"source_prompt":"Make a pomodoro timer with a short break.","is_pwa":true,"is_jsx":true,"visibility":"private","icon":null,"created_at":"2026-10-20T10:00:00.000Z","url":"https://preview.hypervault.test/a/pomodoro-timer-x7k2p9"},
     {"slug":"trip-planner-abc123","title":"Trip planner","type":"group","tags":["travel"],"source_prompt":null,"is_pwa":false,"is_jsx":false,"visibility":"public","created_at":"2026-10-18T10:00:00.000Z"},
     {"slug":"budget-2026-q4","title":"Budget 2026 Q4","type":"html","tags":[],"source_prompt":null,"is_pwa":true,"is_jsx":false,"visibility":"password","created_at":"2026-10-02T10:00:00.000Z"},
     {"slug":"lease-pdf-123456","title":"Lease.pdf","type":"pdf","tags":[],"source_prompt":null,"is_pwa":false,"is_jsx":false,"visibility":"private","created_at":"2026-09-01T10:00:00.000Z"}
    ]}
    """#

    static let connections = #"""
    {"connections":[{"id":"e1","a_id":"a1","b_id":"x1","kind":"manual","created_at":"2026-10-21T00:00:00.000Z"},{"id":"e2","a_id":"a1","b_id":"x2","kind":"auto","created_at":"2026-10-21T00:00:00.000Z"}],
     "memory_links":[],"memory_artifact_links":[{"id":"b1","memory_id":"m1","artifact_id":"a1","kind":"manual","created_at":"2026-10-21T00:00:00.000Z"}]}
    """#

    static let card = #"{"id":"a1","kind":"page","name":"Pomodoro Timer","href":"/a/pomodoro-timer-x7k2p9","updated_at":"2026-10-20T10:00:00.000Z"}"#

    static var routes: [MockRoute] {
        [
            .json(.get, "/api/yours", yours),
            .json(.get, "/api/artifacts", artifacts),
            .json(.get, "/api/connections", connections),
            .json(.get, "/api/yours/card", card),
            .json(.get, "/api/artifacts/pomodoro-timer-x7k2p9/feedback", #"{"feedback":"up"}"#),
        ]
    }

    // MARK: Hosts

    /// The Library, with a pinned page and a page someone shared when `shortcuts` (those are read from the
    /// person's own rows in Supabase, which a snapshot has no server for, so they are put in by hand).
    private struct LibraryHost: View {
        @Environment(AppEnvironment.self) private var env
        let filter: YoursFilter
        var shortcuts = true

        var body: some View { LibraryScreen(model: model, filter: filter) }

        private var model: LibraryModel {
            let model = LibraryModel(env: env)
            guard shortcuts else { return model }
            model.seed(
                pins: SidebarPins(pins: [.artifact("pomodoro-timer-x7k2p9")]),
                sharedWithYou: [
                    SharedWithYouItem(
                        shareId: "s1", slug: "launch-notes-k3m9", title: "Launch notes", type: "html", owner: "Maya Chen",
                        createdAt: Date(timeIntervalSince1970: 1_792_700_000)
                    ),
                ]
            )
            return model
        }
    }

    /// A page screen whose page is served from canned markup rather than the network. The model reads
    /// the page first and the screen is drawn once it has, so what is drawn is the page's state and not
    /// how long the canned answers took.
    private struct DetailHost: View {
        @Environment(AppEnvironment.self) private var env
        let status: Int
        let body_: String
        @State private var model: ArtifactDetailModel?

        var body: some View {
            Group {
                if let model { ArtifactDetailScreen(model: model) } else { Color.clear }
            }
            .task {
                let transport = MockTransport(routes: [
                    MockRoute(.get, "/a/pomodoro-timer-x7k2p9") { _ in HTTPResponse(status: status, data: Data(body_.utf8)) },
                ])
                let loader = ArtifactPageLoader(baseURL: env.server.baseURL, tokens: StaticTokenProvider(), transport: transport)
                let created = ArtifactDetailModel(slug: "pomodoro-timer-x7k2p9", env: env, loader: loader)
                await created.load()
                model = created
            }
        }
    }

    /// What a kept page looks like when it opens: a small page of its own, in its own colours.
    static let pomodoroPage = """
    <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">
    <style>
    body{margin:0;min-height:100vh;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:10px;
    font-family:-apple-system,sans-serif;background:#fff7ed;color:#7c2d12}
    h1{font-size:88px;margin:0;font-weight:700}p{margin:0;font-size:20px}
    </style>
    <p>Focus</p><h1>25:00</h1><p>A short break comes after this round.</p>
    """

    /// Builds a sheet that needs the page's model.
    private struct SheetHost<Sheet: View>: View {
        @Environment(AppEnvironment.self) private var env
        let make: (ArtifactDetailModel) -> Sheet
        @State private var model: ArtifactDetailModel?

        var body: some View {
            Group {
                if let model { make(model) } else { Color.clear }
            }
            .task {
                let created = ArtifactDetailModel(slug: "pomodoro-timer-x7k2p9", env: env)
                await created.load()
                model = created
            }
        }
    }

    // MARK: Library

    func testLibraryAll() throws {
        try snapshot(PreviewHost(routes: Self.routes) { LibraryHost(filter: .all) }, named: "library-all")
    }

    func testLibraryWithoutShortcuts() throws {
        try snapshot(PreviewHost(routes: Self.routes) { LibraryHost(filter: .all, shortcuts: false) }, named: "library-plain")
    }

    func testLibraryFiles() throws {
        try snapshot(PreviewHost(routes: Self.routes) { LibraryHost(filter: .file) }, named: "library-files")
    }

    /// The largest accessibility type: rows wrap rather than cut, and the filter becomes a menu.
    func testLibraryAtTheLargestType() throws {
        try snapshot(
            PreviewHost(routes: Self.routes) { LibraryHost(filter: .all).environment(\.dynamicTypeSize, .accessibility3) },
            named: "library-large", schemes: [.light]
        )
        try snapshot(
            PreviewHost(routes: Self.routes) { LibraryHost(filter: .file).environment(\.dynamicTypeSize, .accessibility3) },
            named: "library-files-large", schemes: [.light]
        )
    }

    func testLibraryEmptyAndFailed() throws {
        try snapshot(
            PreviewHost(routes: [.json(.get, "/api/yours", #"{"recent":[],"results":[]}"#)]) { LibraryHost(filter: .all, shortcuts: false) },
            named: "library-empty"
        )
        try snapshot(
            PreviewHost(routes: [.failure(.get, "/api/yours", status: 500, message: "Could not list what you have kept. Try again.")]) { LibraryHost(filter: .memory, shortcuts: false) },
            named: "library-failed"
        )
    }

    // MARK: A page

    func testPageScreen() throws {
        try snapshot(
            PreviewHost(routes: Self.routes, delay: 0.05) { DetailHost(status: 200, body_: Self.pomodoroPage) },
            named: "page-ready", settle: 4
        )
    }

    func testPageThatCannotBeShown() throws {
        try snapshot(
            PreviewHost(routes: Self.routes, delay: 0.05) { DetailHost(status: 403, body_: "<h1>This is private</h1>") },
            named: "page-blocked", settle: 3
        )
    }

    // MARK: Sheets

    func testShareSheet() throws {
        let routes = Self.routes + [
            .json(.get, "/api/shares", #"{"shares":[{"id":"s1","email":"maya@example.com","display_name":"Maya","role":"edit","created_at":"2026-10-01T00:00:00.000Z"},{"id":"s2","email":"jon@example.com","display_name":null,"role":"view","created_at":"2026-10-02T00:00:00.000Z"}],"roles":["view","use","edit"],"roles_enforced":true}"#),
        ]
        try snapshot(PreviewHost(routes: routes, embedInNavigation: false) { SheetHost { ArtifactShareSheet(detail: $0) } }, named: "page-share")
    }

    func testShareSheetAtALargeType() throws {
        let routes = Self.routes + [
            .json(.get, "/api/shares", #"{"shares":[{"id":"s1","email":"maya@example.com","display_name":"Maya","role":"edit","created_at":"2026-10-01T00:00:00.000Z"}],"roles":["view","use","edit"],"roles_enforced":true}"#),
        ]
        try snapshot(
            PreviewHost(routes: routes, embedInNavigation: false) { SheetHost { ArtifactShareSheet(detail: $0) }.environment(\.dynamicTypeSize, .accessibility2) },
            named: "page-share-large", settle: 3, schemes: [.light]
        )
    }

    func testSourceSheet() throws {
        let routes = Self.routes + [
            .json(.get, "/api/artifacts/pomodoro-timer-x7k2p9/content", #"{"slug":"pomodoro-timer-x7k2p9","title":"Pomodoro Timer","content":"export default function App() {\n  const [seconds, setSeconds] = useState(25 * 60);\n  return <h1>{seconds}</h1>;\n}\n","is_jsx":true,"mutable":true,"content_hash":"h","version":{"id":"v3","parent_version_id":"v2","message":"shorter break","created_at":"2026-10-20T10:00:00.000Z","is_head":true},"head_version_id":"v3"}"#),
        ]
        try snapshot(PreviewHost(routes: routes, embedInNavigation: false) { SheetHost { ArtifactSourceSheet(detail: $0) } }, named: "page-source")
    }

    func testHistorySheet() throws {
        let routes = Self.routes + [
            .json(.get, "/api/artifacts/pomodoro-timer-x7k2p9/versions", #"{"slug":"pomodoro-timer-x7k2p9","mutable":true,"versions":[{"id":"v3","parent_version_id":"v2","title":"Pomodoro Timer","message":"shorter break","author_kind":"agent","author_key_prefix":"hv_ab12cd34","author_name":"grok","content_hash":"h3","is_jsx":true,"is_head":true,"created_at":"2026-10-25T10:00:00.000Z","rebased_from_version_id":"v1"},{"id":"v2","parent_version_id":"v1","title":"Pomodoro Timer","message":"add sounds","author_kind":"user","content_hash":"h2","is_jsx":true,"is_head":false,"created_at":"2026-10-22T10:00:00.000Z"},{"id":"v1","parent_version_id":null,"title":"Pomodoro Timer","message":"create","author_kind":"user","content_hash":"h1","is_jsx":true,"is_head":false,"created_at":"2026-10-20T10:00:00.000Z"}]}"#),
        ]
        try snapshot(PreviewHost(routes: routes, embedInNavigation: false) { SheetHost { ArtifactHistorySheet(detail: $0) } }, named: "page-history")
    }

    func testDetailsSheet() throws {
        try snapshot(PreviewHost(routes: Self.routes, embedInNavigation: false) { SheetHost { ArtifactInfoSheet(detail: $0) } }, named: "page-details")
    }

    func testConnectionsSheet() throws {
        // Each end of a connection is looked up by its own id and answers with its own name; a page
        // looked up by its slug is the Pomodoro Timer itself. This route is first because the first match wins.
        let cards = MockRoute(.get, "/api/yours/card") { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let id = query.first { $0.name == "id" }?.value
            let json: String
            switch id {
            case "x1": json = #"{"id":"x1","kind":"page","name":"Focus playlist","href":"/a/focus-playlist-1","updated_at":"2026-10-20T10:00:00.000Z"}"#
            case "x2": json = #"{"id":"x2","kind":"page","name":"Meal prep for the week","href":"/a/meal-prep-9z","updated_at":"2026-10-19T10:00:00.000Z"}"#
            case "m1": json = #"{"id":"m1","kind":"memory","name":"Co-parenting notes","href":"/vault/memory?open=m1","updated_at":"2026-10-25T20:00:00.000Z"}"#
            default: json = Self.card
            }
            return HTTPResponse(status: 200, headers: ["content-type": "application/json"], data: Data(json.utf8))
        }
        let routes = [cards] + Self.routes
        try snapshot(PreviewHost(routes: routes, embedInNavigation: false) { SheetHost { ArtifactConnectionsSheet(detail: $0) } }, named: "page-connections", settle: 3)
    }

    func testPasswordsScreen() throws {
        let routes = [
            MockRoute.json(.get, "/api/artifacts/budget-2026-q4/passwords", #"{"passwords":[{"id":"p1","label":"Team","max_uses":5,"use_count":2,"disabled":false,"created_at":"2026-10-01T00:00:00.000Z"},{"id":"p2","label":"Old","max_uses":null,"use_count":9,"disabled":true,"created_at":"2026-09-01T00:00:00.000Z"}],"recentVisits":[{"id":"v1","artifact_password_id":"p1","label":"Team","created_at":"2026-10-24T09:00:00.000Z"}]}"#),
        ]
        try snapshot(PreviewHost(routes: routes) { PasswordsHost() }, named: "page-passwords")
    }

    private struct PasswordsHost: View {
        @Environment(AppEnvironment.self) private var env
        var body: some View { ArtifactPasswordsScreen(client: env.client, slug: "budget-2026-q4") }
    }

    func testRepairSheet() throws {
        try snapshot(
            PreviewHost(routes: Self.routes, embedInNavigation: false) {
                SheetHost { ArtifactRepairSheet(detail: $0, renderError: "SyntaxError: Unexpected token '<' (line 12)") }
            },
            named: "page-repair"
        )
    }

    // MARK: New

    private struct NewHost: View {
        @Environment(AppEnvironment.self) private var env
        var body: some View { NewArtifactView(env: env) { _ in } }
    }

    private struct KeptHost: View {
        var body: some View {
            NavigationStack {
                ArtifactKeptView(
                    result: try! HVCoding.decoder().decode(ArtifactSaveResult.self, from: Data(#"{"url":"https://hypervault.store/a/hi-abc123","slug":"hi-abc123","is_jsx":true,"visibility":"private","mutable":false,"message":"Kept. Here's the link. It was a React component, so it now runs as a page of its own. Only you can open it."}"#.utf8)),
                    onOpen: {}, onAnother: {}
                )
                .hvScreenBackground()
                .navigationTitle("Kept")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }

    func testNewPage() throws {
        try snapshot(PreviewHost(embedInNavigation: false) { NewHost() }, named: "new-page")
        try snapshot(PreviewHost(embedInNavigation: false) { KeptHost() }, named: "new-page-kept")
    }

    private struct GroupHost: View {
        @Environment(AppEnvironment.self) private var env
        var body: some View { GroupEditorView(env: env, slug: nil) { _ in } }
    }

    func testGroupEditor() throws {
        try snapshot(PreviewHost(embedInNavigation: false) { GroupHost() }, named: "group-new")
    }
}
