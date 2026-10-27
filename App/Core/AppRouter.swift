import HyperVaultKit
import SwiftUI

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

    /// Whether the You tab is one stack (a phone: the list, then a pane pushed on it) rather than a list beside a pane.
    /// In a stack the tab's path starts with the pane, and what the pane pushes follows it; beside a list it holds only
    /// what the pane pushes. The tab says which it is.
    private(set) var youIsStack = true

    /// Text a link or a Shortcut wants in the canvas field. The canvas takes it
    /// (and clears it) when it appears.
    var canvasDraft: String?

    /// A link asked for the Yours panel. The canvas opens it (and clears this) when it sees it.
    var yoursPanel = false

    /// A link or the Account menu asked for Group chats. Chat shows that half (and clears this) when it sees it.
    var groupChats = false

    private var paths: [AppTab: NavigationPath] = [.you: AppRouter.panePath(.default)]

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

    func open(_ link: DeepLink) {
        switch link {
        case .keep(let prefill):
            if let prefill, !prefill.isEmpty { canvasDraft = prefill }
        case .pair(let code):
            sheet = .pair(code: code)
            showPane(.keys)
        case .invite(let code):
            sheet = .invite(code: code)
        case .account(let pane):
            showPane(pane ?? .default)
        case .yours:
            yoursPanel = true
        case .groupChats:
            groupChats = true
        case .tab, .route:
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

    /// The You tab is a stack or a list beside a pane, and says so when it appears and when its width changes: what is
    /// pushed moves to the shape of the path the new layout reads, and the pane stays.
    func youLayout(isStack: Bool) {
        guard isStack != youIsStack else { return }
        youIsStack = isStack
        paths[.you] = isStack ? Self.panePath(accountPane) : NavigationPath()
    }

    /// Back to a fresh canvas with nothing pushed, presented or waiting, for when the person who was here is gone.
    func reset() {
        accountPane = .default
        paths = [.you: youIsStack ? Self.panePath(.default) : NavigationPath()]
        sheet = nil
        canvasDraft = nil
        yoursPanel = false
        groupChats = false
        tab = .canvas
    }
}
