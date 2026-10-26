import HyperVaultKit
import SwiftUI

/// Passwords for a page whose door is a password: mint one (or let the server
/// make one), see how often each is used and by whom, switch one off, remove
/// one. A password is shown once, when it is made, and never kept.
@MainActor
@Observable
final class ArtifactPasswordsModel {
    private(set) var phase: ArtifactLoad<ArtifactPasswordList> = .loading
    /// The password just made. It is on screen until the person says they have it.
    private(set) var minted: ArtifactPasswordMinted?
    private(set) var pending = false
    private(set) var error: String?

    private let client: HVClient
    private let slug: String

    init(client: HVClient, slug: String) {
        self.client = client
        self.slug = slug
    }

    func load() async {
        do {
            phase = .loaded(try await client.send(.artifactPasswords(slug: slug)))
        } catch {
            phase = .failed(ArtifactErrors.message(error))
        }
    }

    func mint(password: String, label: String, maxUses: Int?) async -> Bool {
        let typed = password.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty, typed.count < ArtifactPasswordRules.minimumLength {
            error = "Passwords must be at least \(ArtifactPasswordRules.minimumLength) characters."
            return false
        }
        pending = true
        error = nil
        defer { pending = false }
        do {
            minted = try await client.send(.mintArtifactPassword(
                slug: slug, password: typed, label: label.trimmingCharacters(in: .whitespacesAndNewlines), maxUses: maxUses
            ))
            await load()
            return true
        } catch {
            self.error = ArtifactErrors.message(error)
            return false
        }
    }

    /// The person has copied it: forget it.
    func clearMinted() {
        minted = nil
    }

    func setDisabled(_ password: ArtifactPassword, disabled: Bool) async {
        error = nil
        do {
            let updated = try await client.send(.setArtifactPasswordDisabled(slug: slug, id: password.id, disabled: disabled))
            if case .loaded(let list) = phase {
                phase = .loaded(ArtifactPasswordList(
                    passwords: list.passwords.map { $0.id == updated.id ? updated : $0 }, recentVisits: list.recentVisits
                ))
            }
        } catch {
            self.error = ArtifactErrors.message(error)
        }
    }

    func delete(_ password: ArtifactPassword) async -> Bool {
        error = nil
        do {
            _ = try await client.send(.deleteArtifactPassword(slug: slug, id: password.id))
            if case .loaded(let list) = phase {
                phase = .loaded(ArtifactPasswordList(passwords: list.passwords.filter { $0.id != password.id }, recentVisits: list.recentVisits))
            }
            return true
        } catch {
            self.error = ArtifactErrors.message(error)
            return false
        }
    }
}

struct ArtifactPasswordsScreen: View {
    @Environment(AppModel.self) private var app
    @State private var model: ArtifactPasswordsModel
    @State private var password = ""
    @State private var label = ""
    @State private var maxUses = ""
    @State private var deleting: ArtifactPassword?

    init(client: HVClient, slug: String) {
        _model = State(initialValue: ArtifactPasswordsModel(client: client, slug: slug))
    }

    var body: some View {
        List {
            if let minted = model.minted { mintedSection(minted) }
            newSection
            switch model.phase {
            case .loading:
                Section { HVLoadingState().listRowBackground(Color.clear) }
            case .failed(let message):
                Section {
                    HVErrorState(message: message) { Task { await model.load() } }
                        .listRowBackground(Color.clear)
                }
            case .loaded(let list):
                passwordsSection(list)
                if !list.recentVisits.isEmpty { visitsSection(list) }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .hvScreenBackground()
        .navigationTitle("Passwords")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .onDisappear { model.clearMinted() }
        .confirmationDialog(
            "Delete this password?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible, presenting: deleting
        ) { item in
            Button("Delete", role: .destructive) { remove(item) }
        } message: { _ in
            Text("Anyone who has it can no longer open the page with it.")
        }
    }

    // MARK: Sections

    private func mintedSection(_ minted: ArtifactPasswordMinted) -> some View {
        Section {
            VStack(alignment: .leading, spacing: HV.Space.s) {
                Text("Copy this password now. It won't be shown again.")
                    .font(.hvCallout.weight(.semibold))
                // Not selectable: the Copy button below is the way out, and it keeps the copy on this device.
                Text(minted.plaintext)
                    .font(.system(.title3, design: .monospaced, weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: HV.Space.xs) {
                    Button {
                        ArtifactPasteboard.copySecret(minted.plaintext)
                        Haptics.success()
                        app.toasts.show("Copied. It stays on this device for two minutes.", style: .info)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.hvPrimary)
                    Button("I have it") { model.clearMinted() }
                        .buttonStyle(.hvSecondary)
                }
            }
            .padding(.vertical, HV.Space.xs)
        }
        // Paper first, then the tint: the tint alone would take the page's colour in dark mode.
        .listRowBackground(ZStack { Palette.surface; Palette.mint.opacity(0.14) })
        .listRowSeparatorTint(Palette.hairline)
    }

    private var newSection: some View {
        Section {
            HVLabeledField(title: "Password", footnote: "Leave it blank and one is made for you.") {
                TextField("Password", text: $password, prompt: artifactPrompt("Optional"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .privacySensitive()
            }
            .listRowSeparator(.hidden)
            HVLabeledField(title: "Label", footnote: "A name for you, to tell passwords apart.") {
                TextField("Label", text: $label, prompt: artifactPrompt("Optional"))
            }
            .listRowSeparator(.hidden)
            HVLabeledField(title: "Most visits", footnote: "It stops working after this many.") {
                TextField("Most visits", text: $maxUses, prompt: artifactPrompt("No limit"))
                    .keyboardType(.numberPad)
            }
            if let error = model.error { ArtifactErrorLine(message: error).listRowBackground(Color.clear) }
            Button {
                create()
            } label: {
                if model.pending { ProgressView() } else { Text("Create password") }
            }
            .disabled(model.pending)
        } header: {
            HVSectionHeader(title: "New password")
        } footer: {
            Text("Share it with whoever should be able to open this page. Each use is counted.")
        }
        .hvListRow()
    }

    private func passwordsSection(_ list: ArtifactPasswordList) -> some View {
        Section {
            if list.passwords.isEmpty {
                Text("No passwords yet. Make one above and share it with the people who should open this.")
                    .font(.hvFootnote)
                    .foregroundStyle(Palette.textSecondary)
            }
            ForEach(list.passwords) { item in
                HStack(spacing: HV.Space.s) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.displayLabel).font(.hvBody).foregroundStyle(Palette.textPrimary).lineLimit(1)
                        Text(item.usageLine).font(.hvFootnote).foregroundStyle(Palette.textSecondary)
                    }
                    Spacer(minLength: HV.Space.xs)
                    if item.disabled {
                        HVTag(text: "Deactivated", tint: Palette.amber)
                    } else if item.isUsedUp {
                        HVTag(text: "Used up", tint: Palette.textSecondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { deleting = item } label: { Label("Delete", systemImage: "trash") }
                    Button {
                        Task { await model.setDisabled(item, disabled: !item.disabled) }
                    } label: {
                        Label(item.disabled ? "Reactivate" : "Deactivate", systemImage: item.disabled ? "play" : "pause")
                    }
                    .tint(Palette.amber)
                }
                .contextMenu {
                    Button {
                        Task { await model.setDisabled(item, disabled: !item.disabled) }
                    } label: {
                        Label(item.disabled ? "Reactivate" : "Deactivate", systemImage: item.disabled ? "play" : "pause")
                    }
                    Button(role: .destructive) { deleting = item } label: { Label("Delete", systemImage: "trash") }
                }
            }
        } header: {
            HVSectionHeader(title: "Passwords", detail: "\(list.passwords.count) of \(ArtifactPasswordRules.maxPasswords)")
        }
        .hvListRow()
    }

    private func visitsSection(_ list: ArtifactPasswordList) -> some View {
        Section {
            ForEach(list.recentVisits.prefix(8)) { visit in
                HStack {
                    Text(visit.label ?? "Untitled password").font(.hvFootnote).foregroundStyle(Palette.textPrimary)
                    Spacer()
                    if let date = visit.createdAt {
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                            .font(.hvCaption)
                            .foregroundStyle(Palette.textSecondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            HVSectionHeader(title: "Recent visits")
        }
        .hvListRow()
    }

    // MARK: Actions

    private func create() {
        let uses = Int(maxUses.trimmingCharacters(in: .whitespaces))
        if !maxUses.trimmingCharacters(in: .whitespaces).isEmpty, (uses ?? 0) < 1 {
            return
        }
        Task {
            if await model.mint(password: password, label: label, maxUses: uses) {
                password = ""
                label = ""
                maxUses = ""
                Haptics.success()
            } else {
                Haptics.failure()
            }
        }
    }

    private func remove(_ item: ArtifactPassword) {
        Task {
            if await model.delete(item) { Haptics.success() } else { Haptics.failure() }
        }
    }
}
