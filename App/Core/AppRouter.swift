import HyperVaultKit
import SwiftUI

/// A sheet the whole app can present from the root.
enum AppSheet: Identifiable, Hashable {
    case pair(code: String?)
    case invite(code: String?)
    case connectAgent

    var id: String {
        switch self {
        case .pair(let code): return "pair-\(code ?? "")"
        case .invite(let code): return "invite-\(code ?? "")"
        case .connectAgent: return "connect-agent"
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

    /// Text a link or a Shortcut wants in the canvas field. The canvas takes it
    /// (and clears it) when it appears.
    var canvasDraft: String?

    /// A thing from Yours that should be put on the canvas page. The canvas takes it when it appears.
    var canvasPull: KeptItem?

    /// "New" in Yours asks the canvas what to keep.
    var canvasAsk = false

    private var paths: [AppTab: NavigationPath] = [:]

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
        case .invite(let code):
            sheet = .invite(code: code)
        default:
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
}
