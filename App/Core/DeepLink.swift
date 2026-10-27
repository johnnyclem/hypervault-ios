import Foundation

/// The five places the app lives.
enum AppTab: String, CaseIterable, Identifiable, Hashable {
    case canvas, yours, memory, chat, you

    var id: String { rawValue }

    var title: String {
        switch self {
        case .canvas: return "Canvas"
        case .yours: return "Yours"
        case .memory: return "Memory"
        case .chat: return "Chat"
        case .you: return "You"
        }
    }

    var symbol: String {
        switch self {
        case .canvas: return "sparkles"
        case .yours: return "square.stack.3d.up"
        case .memory: return "brain.head.profile"
        case .chat: return "bubble.left.and.bubble.right"
        case .you: return "person.crop.circle"
        }
    }
}

/// A screen that can be pushed onto any tab's navigation stack. Features push
/// their own local destinations too; these are the ones other features and
/// links need to reach by name. `RouteDestination` maps each to its screen.
enum Route: Hashable {
    case artifact(slug: String)
    case memory(id: String)
    case conversation(id: String)
    case room(id: String)
    case mailThread(id: String)
    case library
    case agentsAndKeys
    case vaultItems
    case mail
    case truth
    case truthReview
    case tools
    case realms
    case importHistory
    case dreams
    case digest
    case taskBoards
    /// One board, pushed after it is made (and by anything that has its listing). It is a route, not a destination of
    /// the list's own, so it goes on the tab's path with every other screen: a destination the list presented itself
    /// (`navigationDestination(item:)`) was pushed again over the task opened from it.
    case taskBoard(slug: String, project: String, title: String)
    case admin
    case settings
}

/// Where a link wants to go. Built from `hypervault://` links, from
/// `https://hypervault.store/...` universal links, from notifications, widgets
/// and Shortcuts.
enum DeepLink: Hashable {
    case tab(AppTab)
    case route(Route)
    /// Open the canvas with something already in the field.
    case keep(prefill: String?)
    /// Approve an agent that is asking for a key.
    case pair(code: String?)
    case invite(code: String?)

    /// The tab a link lands on, and what to push there.
    var destination: (tab: AppTab, route: Route?) {
        switch self {
        case .tab(let tab): return (tab, nil)
        case .keep: return (.canvas, nil)
        case .pair: return (.you, .agentsAndKeys)
        case .invite: return (.canvas, nil)
        case .route(let route):
            switch route {
            case .artifact, .library: return (.yours, route)
            case .memory: return (.memory, route)
            case .conversation, .room: return (.chat, route)
            default: return (.you, route)
            }
        }
    }

    // MARK: Parsing

    init?(url: URL) {
        let scheme = url.scheme?.lowercased() ?? ""
        let parts: [String]
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }

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

        switch first {
        case "a":
            guard let slug = second else { return nil }
            self = .route(.artifact(slug: slug))
        case "artifact", "g":
            // /g/<slug> is a group of files; a group opens in the same screen as a page.
            guard let slug = second else { return nil }
            self = .route(.artifact(slug: slug))
        case "memory":
            if let id = second { self = .route(.memory(id: id)) } else { self = .tab(.memory) }
        case "chat", "conversation":
            if let id = second { self = .route(.conversation(id: id)) } else { self = .tab(.chat) }
        case "rooms", "room":
            if let id = second { self = .route(.room(id: id)) } else { self = .tab(.chat) }
        case "canvas", "keep":
            self = .keep(prefill: value("text"))
        case "yours", "library":
            self = .tab(.yours)
        case "pair":
            self = .pair(code: value("code") ?? value("user_code"))
        case "invite":
            self = .invite(code: value("code"))
        case "login":
            if let code = value("invite") { self = .invite(code: code) } else { return nil }
        case "tab":
            if let name = second, let tab = AppTab(rawValue: name.lowercased()) { self = .tab(tab) } else { return nil }
        case "mail":
            if let id = second { self = .route(.mailThread(id: id)) } else { self = .route(.mail) }
        case "truth":
            self = second?.lowercased() == "review" ? .route(.truthReview) : .route(.truth)
        case "taskboards", "task-boards", "tasks":
            self = .route(.taskBoards)
        case "tools":
            self = .route(.tools)
        case "settings":
            self = .route(.settings)
        case "vault":
            // The web's /vault/<section> paths.
            switch second?.lowercased() {
            case "memory": self = .tab(.memory)
            case "library", nil: self = .tab(.yours)
            case "mail": self = .route(.mail)
            case "truth": self = .route(.truth)
            case "dreams": self = .route(.dreams)
            case "digest": self = .route(.digest)
            case "import": self = .route(.importHistory)
            case "account": self = .route(.agentsAndKeys)
            default: return nil
            }
        default:
            return nil
        }
    }
}
