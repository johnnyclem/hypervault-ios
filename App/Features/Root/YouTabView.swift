import HyperVaultKit
import SwiftUI

/// The fourth tab: the web's You page, `/vault/account`. A list of seven panes and the pane that is open, in the web's
/// order. On a phone it is one stack that opens on the vault, with the list one step back; on an iPad the list and the
/// pane show side by side.
///
/// Which of the two is decided once, by the kind of device (`AppRouter.youIsStack`), and not by the width the window has
/// at the moment. Swapping one for the other when a window is resized would tear the pane down with whatever it holds
/// (a sheet, typed values, a key that is shown once); the split view narrows to a stack by itself instead, and keeps the
/// pane.
///
/// The stack is the one every `Route` pushes onto, as in the other tabs, and the pane is the first thing on it. A split
/// view cannot sit inside a navigation stack, so beside the list the stack is the one inside the pane's column, and it
/// starts from the pane.
struct YouTabView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Which column shows when the split view is narrowed to one (Slide Over, a thin Split View): the pane, as on a phone,
    /// until the person goes back to the list.
    @State private var compactColumn: NavigationSplitViewColumn = .detail

    var body: some View {
        let router = model.router
        let open = router.accountPane
        if router.youIsStack {
            NavigationStack(path: router.path(for: .you)) {
                list(open: open, router: router, besideThePane: false)
                    .navigationDestination(for: AccountPane.self) { AccountPaneView(pane: $0) }
                    .navigationDestination(for: Route.self) { RouteDestination(route: $0) }
            }
        } else {
            NavigationSplitView(preferredCompactColumn: $compactColumn) {
                list(open: open, router: router, besideThePane: true)
            } detail: {
                NavigationStack(path: router.path(for: .you)) {
                    AccountPaneView(pane: open)
                        // Each pane is its own screen: a pane is not the same view with other content, and what it
                        // had loaded or pushed is not the next one's.
                        .id(open)
                        .navigationDestination(for: AccountPane.self) { AccountPaneView(pane: $0) }
                        .navigationDestination(for: Route.self) { RouteDestination(route: $0) }
                }
            }
            // A link can bring a pane forward too, and where the window is narrow it is the pane that has to show.
            .onChange(of: open) { _, _ in compactColumn = .detail }
        }
    }

    /// The panes, as buttons: a pane is chosen even when it is the one that is open, and the router makes the stack
    /// start from it.
    private func list(open: AccountPane, router: AppRouter, besideThePane: Bool) -> some View {
        List {
            ForEach(AccountPane.allCases) { pane in
                let isOpen = pane == open
                let marked = isOpen && besideThePane
                Button {
                    router.showPane(pane)
                    compactColumn = .detail
                } label: {
                    HStack(spacing: HV.Space.xs) {
                        paneLabel(pane)
                            .fontWeight(marked ? .semibold : nil)
                            .foregroundStyle(Palette.textPrimary)
                        Spacer(minLength: HV.Space.xs)
                        if marked {
                            // Not the fill alone: the raised paper is 1.1:1 against the list's.
                            HVIcon(HVSymbol.selected)
                                .font(.hvCaption.weight(.bold))
                                .foregroundStyle(Palette.sky)
                        } else if !besideThePane, !dynamicTypeSize.isAccessibilitySize {
                            HVIcon(HVSymbol.open)
                                .font(.hvCaption.weight(.semibold))
                                .foregroundStyle(Palette.textTertiary)
                        }
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // The pane that is open stands out where it is beside the list; on a phone the list is a step away from it.
                .listRowBackground(marked ? Palette.surfaceRaised : Palette.surface)
                .listRowSeparatorTint(Palette.hairline)
                .accessibilityAddTraits(marked ? .isSelected : [])
                .accessibilityIdentifier("you.pane.\(pane.rawValue)")
            }
        }
        .scrollContentBackground(.hidden)
        .hvScreenBackground()
        .navigationTitle(AppTab.you.title)
    }

    /// A pane's symbol and name. At an accessibility text size the symbol goes above the name and the chevron is left
    /// off, so the name has the row's whole width and is not broken in the middle of a word.
    @ViewBuilder
    private func paneLabel(_ pane: AccountPane) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: HV.Space.xs) {
                HVIcon(pane.symbol)
                Text(pane.label)
            }
        } else {
            Label(pane.label, systemImage: pane.symbol)
        }
    }
}

/// One pane of the You tab: the screen already built for it, under the pane's name. The web's panes are Settings, the
/// Vault, Agent keys, Models, Domain, Appearance and Import; the heading is the navigation title, and a pane whose
/// screen has a line to say under it says it above its first group.
///
/// The Vault and Domain screens name themselves (the same word, with the large title, and the Vault's own add button and
/// search), so the pane puts no second title on them. Every pane is shown inside a navigation stack, which those screens
/// need for their own toolbar and pushes.
struct AccountPaneView: View {
    let pane: AccountPane

    @Environment(AppEnvironment.self) private var env

    var body: some View {
        switch pane {
        case .vault: VaultItemsView()
        case .domain: RealmsRootView()
        case .general: titled(GeneralPane())
        case .keys: titled(AgentsAndKeysView())
        case .backends: titled(ChatModelsContent(env: env, onChange: nil, embedded: true))
        case .appearance: titled(AppearancePane())
        case .import: titled(ImportPane())
        }
    }

    private func titled<Content: View>(_ content: Content) -> some View {
        content
            .navigationTitle(pane.label)
            .keysLargeTitle()
    }
}
