import HyperVaultKit
import SwiftUI

/// The fourth tab: the web's You page, `/vault/account`. A list of seven panes and the pane that is open, in the web's
/// order. On a phone it is one stack that opens on the vault, with the list one step back; where there is the width (an
/// iPad) the list and the pane show side by side.
///
/// The stack is the one every `Route` pushes onto, as in the other tabs, and the pane is the first thing on it. A split
/// view cannot sit inside a navigation stack, so beside the list the stack is the one inside the pane's column, and it
/// starts from the pane.
struct YouTabView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let router = model.router
        let open = router.accountPane
        let besideTheList = sizeClass == .regular
        Group {
            if besideTheList {
                NavigationSplitView {
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
            } else {
                NavigationStack(path: router.path(for: .you)) {
                    list(open: open, router: router, besideThePane: false)
                        .navigationDestination(for: AccountPane.self) { AccountPaneView(pane: $0) }
                        .navigationDestination(for: Route.self) { RouteDestination(route: $0) }
                }
            }
        }
        .onChange(of: besideTheList, initial: true) { _, beside in router.youLayout(isStack: !beside) }
    }

    /// The panes, as buttons: a pane is chosen even when it is the one that is open, and the router makes the stack
    /// start from it.
    private func list(open: AccountPane, router: AppRouter, besideThePane: Bool) -> some View {
        List {
            ForEach(AccountPane.allCases) { pane in
                let isOpen = pane == open
                Button {
                    router.showPane(pane)
                } label: {
                    HStack(spacing: HV.Space.xs) {
                        Label(pane.label, systemImage: pane.symbol)
                            .foregroundStyle(Palette.textPrimary)
                        Spacer(minLength: HV.Space.xs)
                        if !besideThePane {
                            Image(systemName: "chevron.right")
                                .font(.hvCaption.weight(.semibold))
                                .foregroundStyle(Palette.textTertiary)
                                .accessibilityHidden(true)
                        }
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // The pane that is open stands out where it is beside the list; on a phone the list is a step away from it.
                .listRowBackground(isOpen && besideThePane ? Palette.surfaceRaised : Palette.surface)
                .listRowSeparatorTint(Palette.hairline)
                .accessibilityAddTraits(isOpen && besideThePane ? .isSelected : [])
                .accessibilityIdentifier("you.pane.\(pane.rawValue)")
            }
        }
        .scrollContentBackground(.hidden)
        .hvScreenBackground()
        .navigationTitle(AppTab.you.title)
    }
}

/// One pane of the You tab: the screen already built for it, under the pane's name. The web's panes are Settings, the
/// Vault, Agent keys, Models, Domain, Appearance and Import; the heading is the navigation title, and a pane whose
/// screen has a line to say under it says it above its first group.
struct AccountPaneView: View {
    let pane: AccountPane

    @Environment(AppEnvironment.self) private var env

    var body: some View {
        content
            .navigationTitle(pane.label)
            .keysLargeTitle()
    }

    @ViewBuilder
    private var content: some View {
        switch pane {
        case .general: GeneralPane()
        case .vault: VaultItemsView()
        case .keys: AgentsAndKeysView()
        case .backends: ChatModelsContent(env: env, onChange: nil, embedded: true)
        case .domain: RealmsRootView()
        case .appearance: AppearancePane()
        case .import: ImportPane()
        }
    }
}
