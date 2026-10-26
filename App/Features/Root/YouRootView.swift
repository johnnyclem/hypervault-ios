import HyperVaultKit
import SwiftUI

/// The fifth tab: who you are, and everything that is not the canvas, the list
/// of what is kept, memory or chat. It is the native version of the web app's
/// account drawer, in the same words.
struct YouRootView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppEnvironment.self) private var env

    @State private var waiting = 0
    @State private var confirmSignOut = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        List {
            Section {
                profileCard
                    .listRowInsets(EdgeInsets(top: HV.Space.s, leading: HV.Space.m, bottom: HV.Space.s, trailing: HV.Space.m))
            }.hvListRow()

            Section(header: HVSectionHeader(title: "Keep")) {
                link(.library, id: "library", symbol: "folder", tint: Palette.blue, title: "Library", subtitle: "Everything kept, with its graph")
                link(.vaultItems, id: "vaultItems", symbol: "lock.rectangle.stack", tint: Palette.violet, title: "Logins, cards & keys", subtitle: "Saved once, used by your agents")
                link(.taskBoards, id: "taskBoards", symbol: "checklist", tint: Palette.mint, title: "Task boards", subtitle: "Lists you share with your agents")
            }.hvListRow()

            Section(header: HVSectionHeader(title: "Agents")) {
                link(.agentsAndKeys, id: "agentsAndKeys", symbol: "key.horizontal", tint: Palette.amber, title: "Account & keys", subtitle: "Connect an agent, manage its keys")
                link(.tools, id: "tools", symbol: "wrench.and.screwdriver", tint: Palette.coral, title: "Tools", subtitle: "Services your chats can use")
                link(.mail, id: "mail", symbol: "tray.full", tint: Palette.sky, title: "Mail", subtitle: "Notes between you and your agents")
            }.hvListRow()

            Section(header: HVSectionHeader(title: "Think")) {
                link(.dreams, id: "dreams", symbol: "moon.stars", tint: Palette.violet, title: "Dreams", subtitle: "Connections found overnight")
                link(.digest, id: "digest", symbol: "scissors", tint: Palette.cyan, title: "Digest", subtitle: "Split big memories into small ones")
                link(.truth, id: "truth", symbol: "checkmark.seal", tint: Palette.mint, title: "Truth", subtitle: "What you have asserted, and what rests on it")
            }.hvListRow()

            Section(header: HVSectionHeader(title: "Account")) {
                link(.realms, id: "realms", symbol: "globe", tint: Palette.blue, title: "Your address", subtitle: "Claim you.vault.cool and more")
                link(.importHistory, id: "importHistory", symbol: "square.and.arrow.down", tint: Palette.coral, title: "Import", subtitle: "Bring a ChatGPT, Claude, Gemini or Grok history")
                link(.settings, id: "settings", symbol: "gearshape", tint: Palette.textSecondary, title: "Settings", subtitle: "Look, security, server")
                if env.isAdmin {
                    link(.admin, id: "admin", symbol: "person.badge.shield.checkmark", tint: Palette.rose, title: "Admin", subtitle: "Invites, waitlist, accounts")
                }
            }.hvListRow()

            Section {
                Button(role: .destructive) {
                    // Signing out clears what is still waiting to be kept, so say so first rather than lose it quietly.
                    waiting = OutboxStore.count
                    if waiting > 0 {
                        confirmSignOut = true
                    } else {
                        Task { await model.signOut() }
                    }
                } label: {
                    Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                }
                .accessibilityIdentifier("you.signOut")
            } footer: {
                Text("HyperVault \(Self.versionText)")
                    .font(.hvCaption)
                    .foregroundStyle(Palette.textTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, HV.Space.s)
            }.hvListRow()
        }
        .scrollContentBackground(.hidden)
        .hvScreenBackground()
        .navigationTitle("You")
        .task { await env.probeAdmin() }
        .confirmationDialog("Sign out?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out and discard", role: .destructive) {
                Task { await model.signOut() }
            }
        } message: {
            Text(waiting == 1
                ? "One thing you shared is still waiting to be kept. Signing out discards it."
                : "\(waiting) things you shared are still waiting to be kept. Signing out discards them.")
        }
    }

    private func link(_ route: Route, id: String, symbol: String, tint: Color, title: String, subtitle: String) -> some View {
        NavigationLink(value: route) {
            HVRow(symbol: symbol, tint: tint, title: title, subtitle: subtitle)
        }
        .accessibilityIdentifier("you.\(id)")
    }

    private var profileCard: some View {
        // Beside the words while they have the room. At an accessibility size the avatar would leave them a narrow
        // column, and an email address would be broken mid-word ("sam@ex-ample.com"), so it goes above them.
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: HV.Space.s))
            : AnyLayout(HStackLayout(spacing: HV.Space.m))
        return layout {
            HVAvatar(
                name: env.user.displayName ?? env.user.email ?? "?",
                imageURL: env.user.avatarUrl.flatMap(URL.init(string:)),
                size: 56
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(env.user.displayName ?? env.user.firstName ?? "You")
                    .font(.hvTitle3)
                if let email = env.user.email {
                    Text(email).font(.hvFootnote).foregroundStyle(Palette.textSecondary)
                }
            }
            if !dynamicTypeSize.isAccessibilitySize { Spacer() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("you.profile")
    }

    private static var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}
