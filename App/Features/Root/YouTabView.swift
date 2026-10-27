import HyperVaultKit
import SwiftUI

/// The fourth tab: the web's You page, `/vault/account`. A list of seven panes and the pane that is open, in the web's
/// order. On a phone it opens on the vault with the list one step back; on an iPad both columns show.
///
/// A split view cannot sit inside a navigation stack, so this tab has no `TabRoot`: the stack that every `Route`
/// pushes onto is the one inside the detail column, and it is made again for each pane.
struct YouTabView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// The column a phone shows. The panes are in the detail column, which is where it starts.
    @State private var compact = NavigationSplitViewColumn.detail

    var body: some View {
        let router = model.router
        let open = router.accountPane
        NavigationSplitView(preferredCompactColumn: $compact) {
            list(open: open, router: router)
        } detail: {
            NavigationStack(path: router.path(for: .you)) {
                AccountPaneView(pane: open)
                    .navigationDestination(for: Route.self) { route in
                        RouteDestination(route: route)
                    }
            }
            // Each pane is its own screen: a pane is not the same view with other content, and what it had loaded or
            // pushed is not the next one's.
            .id(open)
        }
        // A link that names a pane brings it forward even when it is the one already open under the list.
        .onChange(of: router.accountOpens) { _, _ in compact = .detail }
    }

    /// The panes, as buttons: a row of a selection list that is already selected does not navigate on a phone, so going
    /// back to the list and choosing the same pane again would do nothing.
    private func list(open: AccountPane, router: AppRouter) -> some View {
        List {
            ForEach(AccountPane.allCases) { pane in
                let isOpen = pane == open
                Button {
                    router.showPane(pane)
                    compact = .detail
                } label: {
                    HStack(spacing: HV.Space.xs) {
                        Label(pane.label, systemImage: pane.symbol)
                            .foregroundStyle(Palette.textPrimary)
                        Spacer(minLength: HV.Space.xs)
                        if sizeClass == .compact {
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
                // The pane that is open stands out where both columns show; on a phone the list is a step away from it.
                .listRowBackground(isOpen && sizeClass == .regular ? Palette.surfaceRaised : Palette.surface)
                .listRowSeparatorTint(Palette.hairline)
                .accessibilityAddTraits(isOpen ? .isSelected : [])
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
