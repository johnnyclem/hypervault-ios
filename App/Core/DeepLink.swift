import Foundation
import HyperVaultKit

/// The four places the app lives, in the order of the web's dock. The Yours panel is on Home; the Account sheet is
/// behind the avatar on Home.
enum AppTab: String, CaseIterable, Identifiable, Hashable {
    /// Home. The case keeps the engineering name for the page (the web's `/vault` renders the canvas), so nothing
    /// that is about the canvas has to change; the person sees "Home".
    case canvas, chat, memory, you

    var id: String { rawValue }

    var title: String {
        switch self {
        case .canvas: return "Home"
        case .chat: return "Chat"
        case .memory: return "Memory"
        case .you: return "You"
        }
    }

    var symbol: String {
        switch self {
        case .canvas: return HVSymbol.home
        case .chat: return HVSymbol.chat
        case .memory: return HVSymbol.memory
        case .you: return HVSymbol.you
        }
    }
}

/// A screen that can be pushed onto any tab's navigation stack. Features push
/// their own local destinations too; these are the ones other features and
/// links need to reach by name. `RouteDestination` maps each to its screen. The
/// screens that are panes of the You tab are not routes: they are `AccountPane`s.
enum Route: Hashable {
    case artifact(slug: String)
    case memory(id: String)
    case conversation(id: String)
    case room(id: String)
    case mailThread(id: String)
    case library
    /// The Library with a filter and a search already chosen (the web's `/vault/library?filter=&q=`).
    case libraryFiltered(filter: YoursFilter, query: String)
    case mail
    case truth
    case truthReview
    /// The review session, opened on the ledger a link names (the web's `/vault/truth/review?ledger=`).
    case truthReviewLedger(slug: String)
    case tools
    case importHistory
    case dreams
    case digest
    case taskBoards
    /// One board, pushed after it is made (and by anything that has its listing). It is a route, not a destination of
    /// the list's own, so it goes on the tab's path with every other screen: a destination the list presented itself
    /// (`navigationDestination(item:)`) was pushed again over the task opened from it.
    case taskBoard(slug: String, project: String, title: String)
    case admin
}

/// Where a link wants to go. Built from `hypervault://` links, from
/// `https://hypervault.store/...` universal links, from notifications, widgets
/// and Shortcuts.
///
/// These links drive the app and nothing else does: a page cannot name any of them
/// (`ArtifactLinkRouter` lets a page reach a page and a group only), and the ones
/// that widgets and Spotlight results already carry are kept for good.
enum DeepLink: Hashable {
    case tab(AppTab)
    case route(Route)
    /// The Memory tab in the view and on the branch the web's `/vault/memory?mode=&branch=` names. Either may be nil; a
    /// link that names neither is `.tab(.memory)`. The tab's own screen takes them from the router (`AppRouter.open`).
    case memoryTab(mode: MemoryMode?, branch: String?)
    /// A pane of the You tab. Nil is the page when nothing names a pane, which is the vault.
    case account(AccountPane?)
    /// Home, with the Yours panel open over it.
    case yours
    /// Chat, on its Group chats half.
    case groupChats
    /// Open the canvas with something already in the field.
    case keep(prefill: String?)
    /// Open the website's pairing page, where a person answers an agent that is asking for a key, over the Agent keys pane.
    case pair(code: String?)
    case invite(code: String?)

    /// The tab a link lands on, and what to push there. Every route has a home here, and a new one has to be given
    /// its own: there is no default.
    var destination: (tab: AppTab, route: Route?) {
        switch self {
        case .tab(let tab): return (tab, nil)
        case .memoryTab: return (.memory, nil)
        case .account, .pair: return (.you, nil)
        case .yours, .keep, .invite: return (.canvas, nil)
        case .groupChats: return (.chat, nil)
        case .route(let route):
            switch route {
            case .artifact, .library, .libraryFiltered, .mail, .mailThread, .taskBoards, .taskBoard, .admin: return (.canvas, route)
            case .memory, .truth, .truthReview, .truthReviewLedger, .dreams, .digest: return (.memory, route)
            case .conversation, .room, .tools, .importHistory: return (.chat, route)
            }
        }
    }

    // MARK: Parsing

    init?(url: URL) {
        let scheme = url.scheme?.lowercased() ?? ""
        let parts: [String]
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = components?.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
        /// A value as a web form writes it ("+" is a space, "%2B" a plus), trimmed. Nil when the name is not given, is
        /// given twice, is empty, or is not text once decoded: each of those names nothing.
        func given(_ name: String) -> String? {
            let matches = (components?.percentEncodedQueryItems ?? []).filter { $0.name == name }
            guard matches.count == 1, let encoded = matches[0].value,
                  let decoded = encoded.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
            else { return nil }
            let trimmed = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        /// The pane `?tab=` or the hash names, the vault when neither does (`/vault/account`, handoff 7).
        func pane() -> DeepLink { .account(AccountPane.resolve(queryItems: query, fragment: components?.percentEncodedFragment)) }
        /// `/vault/memory` as its query names it. `open` is one memory and wins; `mode` is a way of looking (Digest is a
        /// screen of its own) and `branch` a branch of the mind. A value that names nothing is left out, and a link with
        /// nothing left is the tab. (The memory opens on the branch the person is reading: a branch beside `open` is not used.)
        func memoryLink() -> DeepLink {
            if let id = given("open"), DeepLink.isPlainID(id) { return .route(.memory(id: id)) }
            let mode = given("mode")
            if mode == "digest" { return .route(.digest) }
            let view = mode.flatMap { MemoryMode(rawValue: $0) }
            let branch = given("branch").flatMap { MindBranchName.isValid($0) ? $0 : nil }
            return view == nil && branch == nil ? .tab(.memory) : .memoryTab(mode: view, branch: branch)
        }
        /// `/vault/library` as the web reads it (`parseLibraryParams`): `filter` is one of the four filters in any case, and
        /// a name that is not one is All; `q` is cut at 100 characters, and Files, which the web searches no other way, takes none.
        func libraryLink() -> DeepLink {
            let filter = given("filter").flatMap { YoursFilter(rawValue: $0.lowercased()) } ?? .all
            let typed = filter == .file ? "" : (given("q") ?? "")
            let text = String(typed.prefix(DeepLink.libraryQueryLimit)).trimmingCharacters(in: .whitespacesAndNewlines)
            if filter == .all, text.isEmpty { return .route(.library) }
            return .route(.libraryFiltered(filter: filter, query: text))
        }
        /// `/vault/truth/review`, on the ledger `?ledger=` names when that is a ledger's name (a slug).
        func reviewLink() -> DeepLink {
            guard let slug = given("ledger"), TruthLedgerSlug.problem(slug) == nil else { return .route(.truthReview) }
            return .route(.truthReviewLedger(slug: slug))
        }

        if scheme == "hypervault" {
            // hypervault://artifact/<slug>: the host is the first segment.
            parts = ([url.host] + url.pathComponents.filter { $0 != "/" }.map(Optional.init)).compactMap { $0 }
        } else if scheme == "https" || scheme == "http" {
            parts = url.pathComponents.filter { $0 != "/" }
        } else {
            return nil
        }
        guard let first = parts.first?.lowercased() else { return nil }
        let second = parts.dropFirst().first
        let third = parts.dropFirst(2).first

        switch first {
        case "a":
            guard let slug = second else { return nil }
            self = .route(.artifact(slug: slug))
        case "artifact", "g":
            // /g/<slug> is a group of files; a group opens in the same screen as a page.
            guard let slug = second else { return nil }
            self = .route(.artifact(slug: slug))
        case "memory":
            if let id = second { self = .route(.memory(id: id)) } else { self = memoryLink() }
        case "chat", "conversation":
            // The web pins a chat as /chat?c=<id>.
            if let id = second ?? value("c") { self = .route(.conversation(id: id)) } else { self = .tab(.chat) }
        case "rooms", "room":
            if let id = second { self = .route(.room(id: id)) } else { self = .groupChats }
        case "canvas", "keep":
            self = .keep(prefill: value("text"))
        case "yours":
            self = .yours
        case "library":
            self = libraryLink()
        case "pair":
            self = .pair(code: value("code") ?? value("user_code"))
        case "invite":
            self = .invite(code: value("code"))
        case "login":
            if let code = value("invite") { self = .invite(code: code) } else { return nil }
        case "tab":
            // Installed widgets and Spotlight results carry hypervault://tab/yours and tab/canvas: they open for good.
            switch second?.lowercased() {
            case "yours": self = .yours
            case "home": self = .tab(.canvas)
            case let name?:
                guard let tab = AppTab(rawValue: name) else { return nil }
                self = .tab(tab)
            case nil: return nil
            }
        case "mail":
            if let id = second { self = .route(.mailThread(id: id)) } else { self = .route(.mail) }
        case "truth":
            self = second?.lowercased() == "review" ? reviewLink() : .route(.truth)
        case "taskboards", "task-boards", "tasks":
            self = .route(.taskBoards)
        case "tools":
            self = .route(.tools)
        case "settings":
            self = .account(.general)
        case "account":
            self = pane()
        case "vault":
            // The web's /vault/<section> paths. /vault itself is the canvas: Home.
            switch second?.lowercased() {
            case nil: self = .tab(.canvas)
            case "memory": self = memoryLink()
            case "library": self = libraryLink()
            case "new": self = .route(.library)
            case "groups":
                // /vault/groups is where groups are listed, in the Library. /vault/groups/<slug> is the web's editor for one
                // group, which opens as the group does (/g/<slug>); /vault/groups/new makes one, and the Library has that.
                if let slug = third, slug.lowercased() != "new" { self = .route(.artifact(slug: slug)) } else { self = .route(.library) }
            case "mail": self = .route(.mail)
            case "truth": self = third?.lowercased() == "review" ? reviewLink() : .route(.truth)
            case "dreams": self = .route(.dreams)
            case "digest": self = .route(.digest)
            case "import": self = .route(.importHistory)
            case "account": self = pane()
            default: return nil
            }
        default:
            return nil
        }
    }

    /// The longest Library search a link may carry: the web's own cut (`LIBRARY_QUERY_MAX_CHARS`).
    static let libraryQueryLimit = 100

    /// A memory id as a link's query may carry it: letters, digits, "-" and "_". Anything else names nothing, so a link
    /// cannot steer the request for a memory to another path.
    static func isPlainID(_ id: String) -> Bool {
        (1...128).contains(id.count) && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}
