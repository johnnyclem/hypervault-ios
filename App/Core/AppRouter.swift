import HyperVaultKit
import SwiftUI
import UIKit

/// A sheet the whole app can present from the root.
enum AppSheet: Identifiable, Hashable {
    case pair(code: String?)
    case invite(code: String?)
    case connectAgent
    /// The Account menu behind the avatar on Home: what the tab bar does not carry.
    case account

    var id: String {
        switch self {
        case .pair(let code): return "pair-\(code ?? "")"
        case .invite(let code): return "invite-\(code ?? "")"
        case .connectAgent: return "connect-agent"
        case .account: return "account"
        }
    }
}

/// Which tab is showing, what is pushed on each, and what is waiting to be
/// shown. Features call `open(_:)`; they never reach into each other's stacks.
@MainActor
@Observable
final class AppRouter {
    var tab: AppTab = .canvas
    var sheet: AppSheet?

    /// The pane of the You tab that is showing, or that the list will open on.
    private(set) var accountPane: AccountPane = .default

    /// Whether the You tab is one stack (a phone: the list, then a pane pushed on it) rather than a list beside a pane (an
    /// iPad). In a stack the tab's path starts with the pane, and what the pane pushes follows it; beside a list it holds
    /// only what the pane pushes. It is chosen once, by the kind of device, and never by the width the window has at the
    /// moment: a window that is resized (Split View, Slide Over) would otherwise swap one layout for the other and take the
    /// pane down with a sheet, typed values or a key shown once.
    let youIsStack: Bool

    /// Text a link or a Shortcut wants in the canvas field. The canvas takes it
    /// (and clears it) when it appears.
    var canvasDraft: String?

    /// A link asked for the Yours panel. The canvas opens it (and clears this) when it sees it.
    var yoursPanel = false

    /// A Yours link came while a sheet was up: the panel is a sheet too, and opens once that one is gone (`sheetDidDismiss`).
    @ObservationIgnored private var yoursWaitsForSheet = false

    /// A link or the Account menu asked for Group chats. Chat shows that half (and clears this) when it sees it.
    var groupChats = false

    private var paths: [AppTab: NavigationPath]

    init(youIsStack: Bool) {
        self.youIsStack = youIsStack
        paths = [.you: youIsStack ? Self.panePath(.default) : NavigationPath()]
    }

    /// A phone is a stack; an iPad has the room for the list beside the pane.
    convenience init() {
        self.init(youIsStack: UIDevice.current.userInterfaceIdiom != .pad)
    }

    /// A path that holds the pane a stack opens on.
    private static func panePath(_ pane: AccountPane) -> NavigationPath {
        var path = NavigationPath()
        path.append(pane)
        return path
    }

    func path(for tab: AppTab) -> Binding<NavigationPath> {
        Binding(
            get: { self.paths[tab] ?? NavigationPath() },
            set: { self.paths[tab] = $0 }
        )
    }

    /// A link lands where it says, from the first screen of its tab: what covers the app gives way (only a link that
    /// presents a sheet of its own keeps one), and so does whatever was pushed on the tab the link names. The You tab's
    /// own path is the pane's (`showPane`).
    func open(_ link: DeepLink) {
        let hadSheet = sheet != nil
        switch link {
        case .pair, .invite:
            break
        default:
            sheet = nil
        }
        switch link {
        case .keep(let prefill):
            if let prefill, !prefill.isEmpty { canvasDraft = prefill }
            popToRoot(.canvas)
        case .pair(let code):
            sheet = .pair(code: code)
            showPane(.keys)
        case .invite(let code):
            sheet = .invite(code: code)
        case .account(let pane):
            showPane(pane ?? .default)
        case .yours:
            // The panel is a sheet of Home's. With another sheet still on its way out it would not present, so it waits.
            if hadSheet { yoursWaitsForSheet = true } else { yoursPanel = true }
            popToRoot(.canvas)
        case .groupChats:
            groupChats = true
            popToRoot(.chat)
        case .tab(let named):
            if named != .you { popToRoot(named) }
        case .route:
            break
        }
        let destination = link.destination
        tab = destination.tab
        if let route = destination.route {
            // Start from the tab's root so the link lands where it says.
            var path = NavigationPath()
            path.append(route)
            paths[destination.tab] = path
        }
    }

    /// The router's sheet has been dismissed. A Yours link that arrived while it was up opens its panel now.
    func sheetDidDismiss() {
        guard yoursWaitsForSheet else { return }
        yoursWaitsForSheet = false
        yoursPanel = true
    }

    func push(_ route: Route, on tab: AppTab? = nil) {
        let target = tab ?? self.tab
        var path = paths[target] ?? NavigationPath()
        path.append(route)
        paths[target] = path
    }

    func popToRoot(_ tab: AppTab) {
        paths[tab] = NavigationPath()
    }

    /// Brings a pane of the You tab forward, from its first screen. The tab's list uses this too.
    func showPane(_ pane: AccountPane) {
        accountPane = pane
        paths[.you] = youIsStack ? Self.panePath(pane) : NavigationPath()
    }

    /// Back to a fresh canvas with nothing pushed, presented or waiting, for when the person who was here is gone.
    func reset() {
        accountPane = .default
        paths = [.you: youIsStack ? Self.panePath(.default) : NavigationPath()]
        sheet = nil
        canvasDraft = nil
        yoursPanel = false
        yoursWaitsForSheet = false
        groupChats = false
        tab = .canvas
    }
}
