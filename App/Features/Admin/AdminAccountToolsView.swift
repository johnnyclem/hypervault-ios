import HyperVaultKit
import SwiftUI

/// Work on one account by its ID: let it in, shut it out, set its plan, rename
/// it, take it off the waitlist, or delete it. The app cannot list accounts, so
/// the ID comes from the web dashboard.
struct AdminAccountToolsView: View {
    @Environment(AppModel.self) private var app
    @State private var model: AdminAccountModel
    let dashboard: URL
    @FocusState private var idFocused: Bool
    @State private var confirm: Confirmation?
    @State private var deleting = false

    /// Each of these asks first and says exactly what it will do.
    enum Confirmation: Identifiable {
        case revoke, dropFromWaitlist

        var id: Int { self == .revoke ? 0 : 1 }
    }

    init(client: HVClient, ownID: String, dashboard: URL) {
        _model = State(initialValue: AdminAccountModel(client: client, ownID: ownID))
        self.dashboard = dashboard
    }

    var body: some View {
        List {
            Section {
                intro
                    .listRowInsets(EdgeInsets(top: HV.Space.s, leading: HV.Space.m, bottom: HV.Space.s, trailing: HV.Space.m))
            }

            Section(header: HVSectionHeader(title: "Account ID"), footer: idFooter) {
                idField
            }

            if let id = model.accountID {
                actions(for: id)
            }

            if !model.log.isEmpty {
                Section(header: HVSectionHeader(title: "Done in this visit")) {
                    ForEach(model.log, id: \.self) { line in
                        Label(line, systemImage: "checkmark.circle.fill")
                            .font(.hvFootnote)
                            .foregroundStyle(Palette.textSecondary)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .hvScreenBackground()
        .navigationTitle("Accounts")
        .navigationBarTitleDisplayMode(.inline)
        .task { model.reportError = { app.toasts.show(error: $0) } }
        .confirmationDialog(
            confirmTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
            titleVisibility: .visible, presenting: confirm
        ) { action in
            switch action {
            case .revoke:
                Button("Revoke access", role: .destructive) {
                    Task { await model.change(.revoke, done: "Revoked access for \(model.shortID).") }
                }
            case .dropFromWaitlist:
                Button("Remove from the waitlist", role: .destructive) {
                    Task { await model.dropFromWaitlist() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            Text(confirmMessage(action))
        }
        .sheet(isPresented: $deleting) {
            if let id = model.accountID {
                AdminDeleteAccountSheet(accountID: id) {
                    let deleted = await model.deleteAccount()
                    if deleted { deleting = false }
                    return deleted
                }
            }
        }
    }

    // MARK: Pieces

    private var intro: some View {
        VStack(alignment: .leading, spacing: HV.Space.s) {
            HStack(alignment: .top, spacing: HV.Space.s) {
                HVIconBadge(symbol: "person.text.rectangle", tint: Palette.rose)
                Text("HyperVault does not send the app a list of accounts or of the waitlist. Open the web dashboard, copy the account's ID, and paste it here.")
                    .font(.hvFootnote)
                    .foregroundStyle(Palette.textSecondary)
            }
            Link(destination: dashboard) {
                Label("Open the web dashboard", systemImage: "safari")
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .frame(minHeight: 44, alignment: .leading)
            }
        }
    }

    private var idField: some View {
        VStack(alignment: .leading, spacing: HV.Space.xs) {
            TextField("3f1c1a2e-…", text: $model.idText)
                .font(.hvMono)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($idFocused)
                .hvFieldChrome(isFocused: idFocused)
                .accessibilityLabel("Account ID")
            PasteButton(payloadType: String.self) { strings in
                if let text = strings.first { model.idText = text }
            }
            .labelStyle(.titleAndIcon)
            .buttonBorderShape(.capsule)
        }
        .padding(.vertical, HV.Space.xxs)
    }

    @ViewBuilder
    private var idFooter: some View {
        if model.idText.trimmingCharacters(in: .whitespaces).isEmpty {
            Text("It looks like 3f1c1a2e-0000-4000-8000-000000000001.")
        } else if model.accountID == nil {
            Text("That is not an account ID.").foregroundStyle(Palette.danger)
        } else if model.isSelf {
            Text("That is your own account. Revoking or deleting it is not allowed.")
        }
    }

    // MARK: Actions

    @ViewBuilder
    private func actions(for id: String) -> some View {
        Section(header: HVSectionHeader(title: "Access")) {
            Button {
                Task { await model.change(.approve, done: "Approved \(model.shortID).") }
            } label: {
                Label("Approve (let them in)", systemImage: "checkmark.seal")
            }
            Button(role: .destructive) { confirm = .revoke } label: {
                Label("Revoke access", systemImage: "hand.raised")
            }
            .disabled(model.isSelf)
            Button(role: .destructive) { confirm = .dropFromWaitlist } label: {
                Label("Remove from the waitlist", systemImage: "person.fill.xmark")
            }
        }
        .disabled(model.isWorking)

        Section(header: HVSectionHeader(title: "Plan")) {
            Picker("Plan", selection: $model.plan) {
                ForEach(AdminPlan.allCases) { plan in Text(plan.title).tag(plan) }
            }
            .pickerStyle(.segmented)
            Button {
                let plan = model.plan
                Task { await model.change(.plan(plan), done: "Set \(model.shortID) to \(plan.title).") }
            } label: {
                Label("Set the plan to \(model.plan.title)", systemImage: "creditcard")
            }
        }
        .disabled(model.isWorking)

        Section(header: HVSectionHeader(title: "Name")) {
            TextField("Display name", text: $model.displayName)
                .hvFieldChrome()
                .accessibilityLabel("Display name")
            Button {
                let name = model.displayName
                Task { await model.change(.displayName(name), done: "Renamed \(model.shortID).") }
            } label: {
                Label("Save the name", systemImage: "pencil")
            }
            .disabled(model.displayName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .disabled(model.isWorking)

        Section(header: HVSectionHeader(title: "Danger"), footer: Text("Deleting removes the sign-in and everything the person saved. There is no undo.")) {
            Button(role: .destructive) { deleting = true } label: {
                Label("Delete this account…", systemImage: "trash")
            }
            .disabled(model.isSelf || model.isWorking)
        }
    }

    private var confirmTitle: String {
        switch confirm {
        case .revoke: return "Revoke access for \(model.shortID)?"
        case .dropFromWaitlist: return "Remove \(model.shortID) from the waitlist?"
        case nil: return ""
        }
    }

    private func confirmMessage(_ action: Confirmation) -> String {
        switch action {
        case .revoke:
            return "They are put back behind the invite gate and cannot open their vault until you approve them again. Nothing they saved is deleted."
        case .dropFromWaitlist:
            return "They are taken off the list without being approved. If they sign in again, they join the list again."
        }
    }
}

/// The last step before an account is deleted for good: say what it is, and
/// make the owner type a word to go on.
struct AdminDeleteAccountSheet: View {
    @Environment(\.dismiss) private var dismiss
    let accountID: String
    /// Returns whether the account was deleted.
    var onDelete: () async -> Bool

    @State private var typed = ""
    @State private var isWorking = false
    @FocusState private var focused: Bool

    private var matches: Bool { typed.trimmingCharacters(in: .whitespaces) == "DELETE" }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: HV.Space.l) {
                    VStack(alignment: .leading, spacing: HV.Space.s) {
                        Label("This cannot be undone", systemImage: "exclamationmark.triangle.fill")
                            .font(.hvHeadline)
                            .foregroundStyle(Palette.danger)
                        Text("This deletes the sign-in for the account below, and with it everything that person saved: their memories, files, keys and chats. They are signed out everywhere.")
                            .font(.hvCallout)
                            .foregroundStyle(Palette.textSecondary)
                        Text(accountID)
                            .font(.hvMono)
                            .textSelection(.enabled)
                            .hvCard(padding: HV.Space.s)
                    }

                    VStack(alignment: .leading, spacing: HV.Space.xs) {
                        Text("Type DELETE to go on").font(.hvFootnote).foregroundStyle(Palette.textSecondary)
                        TextField("DELETE", text: $typed)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .focused($focused)
                            .hvFieldChrome(isFocused: focused)
                            .accessibilityLabel("Type DELETE to confirm")
                    }

                    VStack(spacing: HV.Space.xs) {
                        Button(role: .destructive) {
                            isWorking = true
                            Task {
                                _ = await onDelete()
                                isWorking = false
                            }
                        } label: {
                            HStack {
                                if isWorking { ProgressView().tint(.white) }
                                Text("Delete the account forever")
                            }
                            .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Palette.danger)
                        .disabled(!matches || isWorking)

                        Button("Cancel") { dismiss() }.buttonStyle(.hvGhost).disabled(isWorking)
                    }
                }
                .padding(HV.Space.l)
                .hvReadableWidth()
            }
            .hvScreenBackground()
            .navigationTitle("Delete account")
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled(isWorking)
        .presentationDetents([.large])
    }
}

#if DEBUG
#Preview("Accounts") {
    PreviewHost { AdminAccountsPreview() }
}

struct AdminAccountsPreview: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        AdminAccountToolsView(client: env.client, ownID: env.user.id, dashboard: env.webURL("admin"))
    }
}
#endif
