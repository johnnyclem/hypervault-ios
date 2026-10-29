import HyperVaultKit
import SwiftUI

/// The Account menu, behind the avatar on Home: the native version of the web's account drawer
/// (components/canvas/account-menu.tsx). The tab bar carries Home, Chat, Memory and You, so this holds what it does not: the
/// Library, Mail, task boards, the account and its keys, group chats, Tools, Import, the Beta features, Admin for an admin,
/// and signing out. A row closes the menu and goes there, on the tab that has it.
struct AccountMenuSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(AppEnvironment.self) private var env

    /// Unread mail, and what waits in Dreams for a decision, read once when the menu opens. Nothing polls them, and a read
    /// that fails shows no badge.
    @State private var unread = 0
    @State private var dreamsWaiting = 0

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row("library", AccountMenu.library, symbol: "folder", tint: Palette.blue, to: .route(.library))
                    row("mail", AccountMenu.mail, symbol: "tray.full", tint: Palette.sky, to: .route(.mail), badge: unread)
                    row("taskBoards", AccountMenu.taskBoards, symbol: "checklist", tint: Palette.mint, to: .route(.taskBoards))
                    row("accountAndKeys", AccountMenu.accountAndKeys, symbol: HVSymbol.agentKeys, tint: Palette.amber, to: .account(nil))
                    row("groupChats", AccountMenu.groupChats, symbol: "person.2", tint: Palette.violet, to: .groupChats)
                    row("tools", AccountMenu.tools, symbol: "wrench.and.screwdriver", tint: Palette.coral, to: .route(.tools))
                    row("import", AccountMenu.importAnything, symbol: HVSymbol.importData, tint: Palette.coral, to: .account(.import))
                }
                .hvListRow()

                Section(header: HVSectionHeader(title: AccountMenu.beta)) {
                    row(
                        "dreams", AccountMenu.dreams, symbol: "moon.stars", tint: Palette.violet, to: .route(.dreams),
                        badge: dreamsWaiting, badgeLabel: AccountMenu.pendingBadgeLabel
                    )
                    row("truth", AccountMenu.truth, symbol: "checkmark.seal", tint: Palette.mint, to: .route(.truth))
                }
                .hvListRow()

                if env.isAdmin {
                    Section {
                        row("admin", AccountMenu.admin, symbol: "person.badge.shield.checkmark", tint: Palette.rose, to: .route(.admin))
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
            // Whether this account is an admin decides whether Admin is here; the answer is kept for hours.
            .task { await env.probeAdmin() }
            .task { await loadUnread() }
            .task { await loadDreamsWaiting() }
        }
    }

    private func row(
        _ id: String, _ title: String, symbol: String, tint: Color, to link: DeepLink, badge: Int = 0,
        badgeLabel: @escaping (Int) -> String = AccountMenu.mailBadgeLabel
    ) -> some View {
        Button {
            app.router.sheet = nil
            app.router.open(link)
        } label: {
            HVRow(symbol: symbol, tint: tint, title: title) {
                if badge > 0 {
                    Text(AccountMenu.badgeText(badge))
                        .font(.hvCaption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, HV.Space.xs)
                        .padding(.vertical, 2)
                        // Small white text: on the gradient it is 5.1:1 or better, and on the flat primary 3.68.
                        .background(Palette.softGradient, in: Capsule())
                        .accessibilityLabel(badgeLabel(badge))
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("account.\(id)")
    }

    private func loadUnread() async {
        guard let list = try? await env.client.send(.mailMailboxes) else { return }
        unread = list.totalUnread
    }

    /// Its own read, so a slow mail read does not hold the badge back.
    private func loadDreamsWaiting() async {
        guard let queue = try? await env.client.send(.dreamQueue) else { return }
        dreamsWaiting = queue.pendingCount
    }
}
