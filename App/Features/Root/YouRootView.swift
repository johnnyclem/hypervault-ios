import HyperVaultKit
import SwiftUI

/// The fifth tab: who you are, and everything that is not the canvas, the list
/// of what is kept, memory or chat. It is the native version of the web app's
/// account drawer, in the same words.
struct YouRootView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        List {
            Section {
                profileCard
                    .listRowInsets(EdgeInsets(top: HV.Space.s, leading: HV.Space.m, bottom: HV.Space.s, trailing: HV.Space.m))
            }

            Section(header: HVSectionHeader(title: "Keep")) {
                link(.library, symbol: "folder", tint: Palette.blue, title: "Library", subtitle: "Everything kept, with its graph")
                link(.vaultItems, symbol: "lock.rectangle.stack", tint: Palette.violet, title: "Logins, cards & keys", subtitle: "Saved once, used by your agents")
                link(.taskBoards, symbol: "checklist", tint: Palette.mint, title: "Task boards", subtitle: "Lists you share with your agents")
            }

            Section(header: HVSectionHeader(title: "Agents")) {
                link(.agentsAndKeys, symbol: "key.horizontal", tint: Palette.amber, title: "Account & keys", subtitle: "Connect an agent, manage its keys")
                link(.tools, symbol: "wrench.and.screwdriver", tint: Palette.coral, title: "Tools", subtitle: "Services your chats can use")
                link(.mail, symbol: "tray.full", tint: Palette.sky, title: "Mail", subtitle: "Notes between you and your agents")
            }

            Section(header: HVSectionHeader(title: "Think")) {
                link(.dreams, symbol: "moon.stars", tint: Palette.violet, title: "Dreams", subtitle: "Connections found overnight")
                link(.digest, symbol: "scissors", tint: Palette.cyan, title: "Digest", subtitle: "Split big memories into small ones")
                link(.truth, symbol: "checkmark.seal", tint: Palette.mint, title: "Truth", subtitle: "What you have asserted, and what rests on it")
            }

            Section(header: HVSectionHeader(title: "Account")) {
                link(.realms, symbol: "globe", tint: Palette.blue, title: "Your address", subtitle: "Claim you.vault.cool and more")
                link(.importHistory, symbol: "square.and.arrow.down", tint: Palette.coral, title: "Import", subtitle: "Bring a ChatGPT, Claude, Gemini or Grok history")
                link(.settings, symbol: "gearshape", tint: Palette.textSecondary, title: "Settings", subtitle: "Look, security, server")
                if env.isAdmin {
                    link(.admin, symbol: "person.badge.shield.checkmark", tint: Palette.rose, title: "Admin", subtitle: "Invites, waitlist, accounts")
                }
            }

            Section {
                Button(role: .destructive) {
                    Task { await model.signOut() }
                } label: {
                    Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                }
            } footer: {
                Text("HyperVault \(Self.versionText)")
                    .font(.hvCaption)
                    .foregroundStyle(Palette.textTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, HV.Space.s)
            }
        }
        .scrollContentBackground(.hidden)
        .hvScreenBackground()
        .navigationTitle("You")
        .task { await env.probeAdmin() }
    }

    private func link(_ route: Route, symbol: String, tint: Color, title: String, subtitle: String) -> some View {
        NavigationLink(value: route) {
            HVRow(symbol: symbol, tint: tint, title: title, subtitle: subtitle)
        }
    }

    private var profileCard: some View {
        HStack(spacing: HV.Space.m) {
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
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }

    private static var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}
