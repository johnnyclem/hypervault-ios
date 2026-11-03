import HyperVaultKit
import SwiftUI

/// The Account sheet, behind the avatar on every tab's first screen: the native version of the web's account drawer
/// (components/canvas/account-menu.tsx), with Settings on the same stack. The tab bar carries Home, Projects, Memory and Mail,
/// so the menu holds what it does not: Settings first (the web's You page, whose panes are the account and its keys), then the
/// Library, group chats, Tools, the Beta features, Admin for an admin, and signing out.
///
/// The sheet has one navigation stack, on a phone and on an iPad (where the sheet is page-sized): the menu, then Settings, then a
/// pane, then whatever the pane pushes (`AppRouter.accountPath`). The Settings row pushes; every other row closes the sheet and
/// goes there, on the tab that has it.
struct AccountMenuSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(AppEnvironment.self) private var env

    /// What waits in Dreams for a decision, read once when the menu opens. Nothing polls it, and a read that fails shows no badge.
    @State private var dreamsWaiting = 0

    var body: some View {
        @Bindable var router = app.router
        NavigationStack(path: $router.accountPath) {
            List {
                Section {
                    NavigationLink(value: AccountStep.settings) {
                        HVRow(symbol: HVSymbol.general, title: AccountMenu.settings)
                    }
                    .accessibilityIdentifier("account.settings")
                    row("library", AccountMenu.library, symbol: "folder", to: .route(.library))
                    row("groupChats", AccountMenu.groupChats, symbol: "person.2", to: .groupChats)
                    row("tools", AccountMenu.tools, symbol: "wrench.and.screwdriver", to: .route(.tools))
                }
                .hvListRow()

                Section(header: HVSectionHeader(title: AccountMenu.beta)) {
                    row(
                        "dreams", AccountMenu.dreams, symbol: "moon.stars", to: .route(.dreams),
                        badge: dreamsWaiting, badgeLabel: AccountMenu.pendingBadgeLabel
                    )
                    row("truth", AccountMenu.truth, symbol: "checkmark.seal", to: .route(.truth))
                }
                .hvListRow()

                if env.isAdmin {
                    Section {
                        row("admin", AccountMenu.admin, symbol: "person.badge.shield.checkmark", to: .route(.admin))
                    }
                    .hvListRow()
                }

                Section {
                    SignOutButton(identifier: "account.signOut")
                }
                .hvListRow()
            }
            .scrollContentBackground(.hidden)
            .hvScreenBackground()
            .navigationTitle(AccountMenu.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        app.router.sheet = nil
                    } label: {
                        Image(systemName: HVSymbol.close)
                    }
                    .accessibilityLabel("Close")
                    .accessibilityIdentifier("account.close")
                }
            }
            // Settings, then a pane of it; and the screens a pane shows (Import's chats and pages) resolve here too.
            .navigationDestination(for: AccountStep.self) { step in
                switch step {
                case .settings: SettingsListView()
                case .pane(let pane): AccountPaneView(pane: pane)
                }
            }
            .navigationDestination(for: Route.self) { route in
                RouteDestination(route: route)
            }
            // Whether this account is an admin decides whether Admin is here; the answer is kept for hours.
            .task { await env.probeAdmin() }
            .task { await loadDreamsWaiting() }
        }
    }

    private func row(
        _ id: String, _ title: String, symbol: String, to link: DeepLink, badge: Int = 0,
        badgeLabel: @escaping (Int) -> String = AccountMenu.pendingBadgeLabel
    ) -> some View {
        Button {
            app.router.sheet = nil
            app.router.open(link)
        } label: {
            HVRow(symbol: symbol, title: title) {
                if badge > 0 {
                    Text(AccountMenu.badgeText(badge))
                        .font(.hvCaption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, HV.Space.xs)
                        .padding(.vertical, 2)
                        // Small white text: on the flat action fill it is 5.17:1 in both looks (on the primary 3.68).
                        .background(Palette.action, in: Capsule())
                        .accessibilityLabel(badgeLabel(badge))
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("account.\(id)")
    }

    private func loadDreamsWaiting() async {
        guard let queue = try? await env.client.send(.dreamQueue) else { return }
        dreamsWaiting = queue.pendingCount
    }
}
