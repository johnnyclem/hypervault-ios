import HyperVaultKit
import SwiftUI
import UniformTypeIdentifiers

/// Admin: the owner's invite codes, waitlist and accounts. The server gives the
/// app no list of any of these (the web page reads them with a key the app can
/// never hold), so this screen is for acting: minting codes, and working on an
/// account whose id you have. It says so, and sends you to the web dashboard
/// for the lists.
struct AdminRootView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        AdminScreen(client: env.client, cache: env.cache, namespace: env.user.id, dashboard: env.webURL("admin"))
    }
}

enum AdminRoute: Hashable {
    case invite(String)
    case accounts
}

struct AdminScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(AppEnvironment.self) private var env
    @State private var model: AdminModel
    let dashboard: URL
    @FocusState private var noteFocused: Bool

    init(client: HVClient, cache: DiskCache, namespace: String, dashboard: URL) {
        _model = State(initialValue: AdminModel(client: client, cache: cache, namespace: namespace))
        self.dashboard = dashboard
    }

    /// For previews, which need a model already part way.
    init(model: AdminModel, dashboard: URL) {
        _model = State(initialValue: model)
        self.dashboard = dashboard
    }

    var body: some View {
        List {
            Section {
                notice
                    .listRowInsets(EdgeInsets(top: HV.Space.s, leading: HV.Space.m, bottom: HV.Space.s, trailing: HV.Space.m))
            }
            .hvListRow()

            Section(header: HVSectionHeader(title: "New invite code")) {
                mintForm
            }
            .hvListRow()

            if let minted = model.justMinted {
                Section(header: HVSectionHeader(title: "Just minted")) {
                    AdminMintedCard(invite: minted, server: env.server.baseURL) { model.dismissMinted() }
                        .listRowInsets(EdgeInsets(top: HV.Space.s, leading: HV.Space.m, bottom: HV.Space.s, trailing: HV.Space.m))
                }
                .hvListRow()
            }

            Section(
                header: HVSectionHeader(title: "Minted on this phone", detail: model.book.invites.isEmpty ? nil : "\(model.book.invites.count)"),
                footer: Text("Codes made elsewhere are in the web dashboard. The numbers here are as of the last time this phone heard from the server.").hvSectionNote()
            ) {
                if model.book.invites.isEmpty {
                    Text("Nothing yet. Codes you create here will be listed so you can turn them off or destroy them.")
                        .font(.hvFootnote)
                        .foregroundStyle(Palette.textSecondary)
                }
                ForEach(model.book.invites) { invite in
                    NavigationLink(value: AdminRoute.invite(invite.id)) {
                        AdminInviteRow(invite: invite)
                    }
                    .accessibilityIdentifier("admin.invite.\(invite.id)")
                }
            }
            .hvListRow()

            Section(header: HVSectionHeader(title: "People")) {
                NavigationLink(value: AdminRoute.accounts) {
                    HVRow(symbol: "person.2.badge.gearshape", tint: Palette.rose, title: "Accounts & waitlist", subtitle: "Approve, set a plan, remove or delete by account ID")
                }
                Link(destination: dashboard) {
                    HVRow(symbol: "safari", tint: Palette.blue, title: "Open the web dashboard", subtitle: "Every invite, the waitlist and all accounts") {
                        HVIcon("arrow.up.right").font(.footnote).foregroundStyle(Palette.textTertiary)
                    }
                }
            }
            .hvListRow()
        }
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .hvScreenBackground()
        .navigationTitle("Admin")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: AdminRoute.self) { route in
            switch route {
            case .invite(let id): AdminInviteDetailView(model: model, inviteID: id, server: env.server.baseURL)
            case .accounts: AdminAccountToolsView(client: env.client, ownID: env.user.id, dashboard: dashboard)
            }
        }
        .task {
            model.reportError = { app.toasts.show(error: $0) }
            model.reportSuccess = { app.toasts.success($0) }
            await model.load()
        }
    }

    private var notice: some View {
        HStack(alignment: .top, spacing: HV.Space.s) {
            HVIconBadge(symbol: "info.circle", tint: Palette.blue)
            VStack(alignment: .leading, spacing: HV.Space.xxs) {
                Text("About the lists").font(.hvHeadline)
                Text("HyperVault does not send the app its invite codes, its waitlist or its accounts, so they cannot be listed here yet. You can create codes and act on a code or an account you have the ID of.")
                    .font(.hvFootnote)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
    }

    private var mintForm: some View {
        VStack(alignment: .leading, spacing: HV.Space.s) {
            HVLabeledField(title: "Uses", footnote: "How many people can join with this code.") {
                TextField("How many people can use the code", text: $model.usesText, prompt: Text.hvPrompt("1"))
                    .keyboardType(.numberPad)
                    .accessibilityIdentifier("admin.uses")
            }
            HVLabeledField(title: "Note (optional)") {
                TextField("Note", text: $model.note, prompt: Text.hvPrompt("Launch batch"))
                    .accessibilityIdentifier("admin.note")
                    .focused($noteFocused)
                    .submitLabel(.done)
            }
            Button {
                noteFocused = false
                Task { await model.mint() }
            } label: {
                // The button is off while it works, and an off primary button is paper, so the spinner is grey.
                if model.isMinting { ProgressView().tint(Palette.textSecondary) } else { Text("Create code") }
            }
            .buttonStyle(.hvPrimary)
            .disabled(model.isMinting)
        }
        .padding(.vertical, HV.Space.xxs)
    }
}

/// One invite in the list.
struct AdminInviteRow: View {
    let invite: AdminInvite

    var body: some View {
        HStack(spacing: HV.Space.s) {
            HVIconBadge(symbol: "ticket", tint: tint, size: 36)
            VStack(alignment: .leading, spacing: HV.Space.xxs) {
                Text(invite.code)
                    .font(.system(.body, design: .monospaced, weight: .medium))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.hvFootnote)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: HV.Space.xs)
            HVTag(text: label, tint: tint)
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }

    private var tint: Color {
        switch invite.status {
        case .active: return Palette.mint
        case .usedUp: return Palette.textSecondary
        case .disabled: return Palette.amber
        }
    }

    private var label: String {
        switch invite.status {
        case .active: return "Active"
        case .usedUp: return "Used up"
        case .disabled: return "Off"
        }
    }

    private var subtitle: String {
        var text = "\(invite.useCount) of \(invite.maxUses) used"
        if let note = invite.note, !note.isEmpty { text += " · \(note)" }
        return text
    }
}

/// The code just minted, big enough to read out, with the two ways to hand it over.
struct AdminMintedCard: View {
    let invite: AdminInvite
    let server: URL
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: HV.Space.s) {
            Text(invite.code)
                .font(.system(.title, design: .monospaced, weight: .bold))
                .textSelection(.enabled)
                .accessibilityLabel("Invite code \(invite.code.map(String.init).joined(separator: " "))")
            Text("\(invite.maxUses) \(invite.maxUses == 1 ? "use" : "uses")" + (invite.note.map { $0.isEmpty ? "" : " · \($0)" } ?? ""))
                .font(.hvFootnote)
                .foregroundStyle(Palette.textSecondary)
            // Two buttons share this row, so each must be its own tap target: a bare button in a list row
            // takes the whole row, and both would fire together.
            HStack(spacing: HV.Space.s) {
                AdminCopyButton(text: invite.code, title: "Copy code", minHeight: 44)
                ShareLink(item: invite.shareURL(server: server), message: Text("Your HyperVault invite: \(invite.code)")) {
                    Label("Share link", systemImage: "square.and.arrow.up").hvRowLabel()
                        .frame(minHeight: 44)
                }
            }
            .font(.system(.subheadline, weight: .semibold))
            .buttonStyle(.borderless)
            Button("Done", action: onDismiss).buttonStyle(.hvGhost)
        }
    }
}

/// Copies to the pasteboard for ten minutes, then lets go. It takes the look of whatever holds it: a
/// plain label in a list row, sized by the caller anywhere else.
struct AdminCopyButton: View {
    let text: String
    let title: String
    /// Zero in a list row, which is already tall enough; the tap target a card needs elsewhere.
    var minHeight: CGFloat = 0
    @State private var copied = false

    var body: some View {
        Button {
            UIPasteboard.general.setItems(
                [[UTType.utf8PlainText.identifier: text]],
                options: [.expirationDate: Date().addingTimeInterval(600)]
            )
            Haptics.tap()
            copied = true
            Task {
                try? await Task.sleep(nanoseconds: UInt64(HV.Motion.copiedHold * 1_000_000_000))
                copied = false
            }
        } label: {
            Label(copied ? "Copied" : title, systemImage: copied ? HVSymbol.copied : HVSymbol.copy).hvRowLabel()
                .frame(minHeight: minHeight)
        }
    }
}

#if DEBUG
#Preview("Admin") {
    PreviewHost { AdminPreviewHost(minted: true) }
}

/// The Admin screen with a few codes already minted, for previews and snapshots. `minted` shows the
/// code just made, as it is straight after "Create code".
struct AdminPreviewHost: View {
    @Environment(AppEnvironment.self) private var env
    var minted = false

    var body: some View {
        let model = AdminModel(client: env.client, cache: env.cache, namespace: env.user.id)
        model.previewSeed(minted: minted ? AdminFixtures.invites.first : nil)
        return AdminScreen(model: model, dashboard: env.webURL("admin"))
    }
}
#endif
