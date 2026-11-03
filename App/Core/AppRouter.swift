import HyperVaultKit
import SwiftUI

/// A sheet the whole app can present from the root.
enum AppSheet: Identifiable, Hashable {
    case invite(code: String?)
    case connectAgent
    /// The Account sheet behind the avatar on every tab's first screen: its menu, and Settings on the same stack. (The
    /// pairing page is not one of these: the Agent keys pane presents it, over the sheet, once it is showing.)
    case account

    var id: String {
        switch self {
        case .invite(let code): return "invite-\(code ?? "")"
        case .connectAgent: return "connect-agent"
        case .account: return "account"
        }
    }
}

/// A step on the Account sheet's stack between its menu and a pane. The stack is `[]` for the menu, `[.settings]` for the list
/// of panes and `[.settings, .pane(p)]` for a pane; what a pane pushes (a `Route`) follows it.
enum AccountStep: Hashable {
    case settings
    case pane(AccountPane)
}

/// A pairing page that was asked for. A link with no code (`hypervault://pair`) is still a request, so this is not the code
/// alone. The Agent keys pane takes it (and clears `AppRouter.pairing`) when it shows.
struct PairingRequest: Equatable, Identifiable {
    let id = UUID()
    let code: String?
}

/// Which tab is showing, what is pushed on each, and what is waiting to be
/// shown. Features call `open(_:)`; they never reach into each other's stacks.
@MainActor
@Observable
final class AppRouter {
    var tab: AppTab = .home
    var sheet: AppSheet?

    /// The Account sheet's stack. `[]` is its menu, `[.settings]` the list of panes, `[.settings, .pane(p)]` a pane, and
    /// what a pane pushes follows. Settings has no tab and no stack of its own: it is this one, in one sheet on every device.
    var accountPath = NavigationPath()

    /// The pane of Settings that is showing, or that the list opened last.
    private(set) var accountPane: AccountPane = .default

    /// A link asked for the website's pairing page. The Agent keys pane takes it (and clears it) when it shows: the page is
    /// presented by the pane, once the pane is up, and not by the router over a sheet that is still on its way in.
    var pairing: PairingRequest?

    /// Text a link or a Shortcut wants in the canvas field. The canvas takes it
    /// (and clears it) when it appears.
    var canvasDraft: String?

    /// A link asked for the Yours panel. The canvas opens it (and clears this) when it sees it.
    var yoursPanel = false

    /// A Yours link came while a sheet was up: the panel is a sheet too, and opens once that one is gone (`sheetDidDismiss`).
    @ObservationIgnored private var yoursWaitsForSheet = false

    /// A sheet that was asked for while another was up: it presents once that one is gone (`sheetDidDismiss`), because a
    /// sheet does not present over one that is still on its way out.
    @ObservationIgnored private var queuedSheet: AppSheet?

    /// A link or the Account menu asked for Group chats. The chat list shows that half (and clears this) when it sees it.
    var groupChats = false

    /// A link named a way of looking at Memory (Search, Ask or Graph). The Memory screen takes it (and clears it) when it
    /// sees it, which may be as it is first built.
    var memoryMode: MemoryMode?

    /// A link named a branch of the mind. The Memory screen takes it (and clears it), and switches to it if the person has it.
    var memoryBranch: String?

    private var paths: [AppTab: NavigationPath] = [:]

    func path(for tab: AppTab) -> Binding<NavigationPath> {
        Binding(
            get: { self.paths[tab] ?? NavigationPath() },
            set: { self.paths[tab] = $0 }
        )
    }

    /// A link lands where it says, from the first screen of its tab: what covers the app gives way (only a link that
    /// presents a sheet of its own keeps one), and so does whatever was pushed on the tab the link names. A link to Settings
    /// or to the pairing page names no tab: it presents the Account sheet over the tab that shows (`showSettings`).
    func open(_ link: DeepLink) {
        let hadSheet = sheet != nil
        // The latest link wins over a pairing page an earlier one asked for and the Agent keys pane has not taken yet (the
        // sheet was still on its way in, or never showed): a `pair` link makes its own request below.
        pairing = nil
        switch link {
        case .pair, .invite, .account:
            // The latest link wins over a panel that was waiting for a sheet to go.
            yoursWaitsForSheet = false
        default:
            sheet = nil
            queuedSheet = nil
        }
        switch link {
        case .keep(let prefill):
            if let prefill, !prefill.isEmpty { canvasDraft = prefill }
            popToRoot(.home)
        case .pair(let code):
            pairing = PairingRequest(code: code)
            showSettings(.keys)
        case .invite(let code):
            present(.invite(code: code))
        case .account(let pane):
            showSettings(pane)
        case .yours:
            // The panel is a sheet of Home's. With another sheet still on its way out it would not present, so it waits.
            if hadSheet { yoursWaitsForSheet = true } else { yoursPanel = true }
            popToRoot(.home)
        case .groupChats:
            groupChats = true
            popToRoot(.home)
        case .memoryTab(let mode, let branch):
            // What the link names is all that waits: a view or a branch an earlier link left behind is not this one's.
            memoryMode = mode
            memoryBranch = branch
            popToRoot(.memory)
        case .tab(let named):
            popToRoot(named)
        case .route:
            break
        }
        let destination = link.destination
        if let named = destination.tab { tab = named }
        if let route = destination.route, let target = destination.tab {
            // Start from the tab's root so the link lands where it says.
            var path = NavigationPath()
            path.append(route)
            paths[target] = path
        }
    }

    /// Presents a sheet. Where none is up (or this one is) it shows at once; where another is, that one goes first and this
    /// one presents when it has (`sheetDidDismiss`), since a sheet set while another is leaving does not present.
    func present(_ next: AppSheet) {
        if sheet == nil || sheet == next {
            // Nothing is up to wait for, so a sheet that was queued by an earlier ask is not this one's: the latest ask wins.
            queuedSheet = nil
            sheet = next
        } else {
            queuedSheet = next
            sheet = nil
        }
    }

    /// The router's sheet has been dismissed. A Yours link that arrived while it was up opens its panel now, and so does a
    /// sheet that was asked for. A pairing page that no Account sheet is coming for is forgotten.
    func sheetDidDismiss() {
        if yoursWaitsForSheet {
            yoursWaitsForSheet = false
            yoursPanel = true
        }
        let next = queuedSheet
        queuedSheet = nil
        if let next { sheet = next }
        // With no Account sheet on its way (the person closed it before the Agent keys pane showed), a pairing page that was
        // asked for is not shown later, when they open that pane by hand.
        if next != .account { pairing = nil }
    }

    /// Pushes a screen where the person is looking: with the Account sheet up, on its stack (a screen the sheet shows, like
    /// the page Import kept, pushes there and not on the tab behind the sheet, where it would be out of sight), otherwise on
    /// the stack of the tab that shows. A call that names a tab pushes on that tab's stack.
    func push(_ route: Route, on tab: AppTab? = nil) {
        if tab == nil, sheet == .account {
            pushInAccount(route)
            return
        }
        let target = tab ?? self.tab
        var path = paths[target] ?? NavigationPath()
        path.append(route)
        paths[target] = path
    }

    func popToRoot(_ tab: AppTab) {
        paths[tab] = NavigationPath()
    }

    /// The Account sheet, on its menu. The avatar on every tab's first screen calls this.
    func showAccountMenu() {
        accountPath = NavigationPath()
        present(.account)
    }

    /// The Account sheet, on a pane of Settings (the vault when none is named), from the pane's first screen with the list
    /// of panes one step back. Where the sheet is up already it is the stack that moves, and the sheet stays.
    func showSettings(_ pane: AccountPane? = nil) {
        let shown = pane ?? .default
        accountPane = shown
        var path = NavigationPath()
        path.append(AccountStep.settings)
        path.append(AccountStep.pane(shown))
        accountPath = path
        present(.account)
    }

    /// A pane chosen from the list of Settings: pushed on the Account sheet's stack.
    func openPane(_ pane: AccountPane) {
        accountPane = pane
        accountPath.append(AccountStep.pane(pane))
    }

    /// A screen a pane of Settings shows another screen on (Import's chats and pages): pushed on the Account sheet's stack, not
    /// on the stack of the tab behind it, where it would be out of sight.
    func pushInAccount(_ route: Route) {
        accountPath.append(route)
    }

    /// Back to a fresh canvas with nothing pushed, presented or waiting, for when the person who was here is gone.
    func reset() {
        accountPane = .default
        accountPath = NavigationPath()
        pairing = nil
        paths = [:]
        sheet = nil
        queuedSheet = nil
        canvasDraft = nil
        yoursPanel = false
        yoursWaitsForSheet = false
        groupChats = false
        memoryMode = nil
        memoryBranch = nil
        tab = .home
    }
}
