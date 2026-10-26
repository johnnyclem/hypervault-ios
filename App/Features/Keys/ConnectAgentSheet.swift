import HyperVaultKit
import SwiftUI

/// Where the Connect sheet can push to.
private enum ConnectRoute: Hashable {
    case client(AgentClientInfo)
    case justAKey
}

/// Connect an agent: "Which AI do you use?", then a key for it and that app's steps and strings, with the
/// key filled in. The key is shown once and is gone when the sheet closes. Present it from anywhere:
///
///     .sheet(isPresented: $connecting) { ConnectAgentSheet() }
///
/// With `existingKey` it shows the steps of a key made earlier instead, with a placeholder where the key
/// goes (its value was shown once, and cannot be shown again).
struct ConnectAgentSheet: View {
    var existingKey: AgentKey?
    var challengeSlug: String?

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    @State private var model: ConnectAgentModel?
    @State private var confirmClose = false

    init(existingKey: AgentKey? = nil, challengeSlug: String? = nil) {
        self.existingKey = existingKey
        self.challengeSlug = challengeSlug
    }

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    ConnectPickerScreen(model: model, onClose: close)
                } else {
                    HVLoadingState()
                }
            }
            .hvScreenBackground()
        }
        .task {
            if model == nil {
                model = ConnectAgentModel(
                    client: env.client, rest: env.keysRest, cache: env.cache, userID: env.user.id,
                    origin: PairingCode.origin(of: env.server.baseURL), existingKey: existingKey, challengeSlug: challengeSlug
                )
            }
        }
        // A key that was never copied is not lost to a stray swipe: closing asks first.
        .interactiveDismissDisabled(model?.hasUncopiedKey ?? false)
        .confirmationDialog("Close without copying the key?", isPresented: $confirmClose, titleVisibility: .visible) {
            Button("Close and lose the key", role: .destructive) { finish() }
            Button("Stay", role: .cancel) {}
        } message: {
            Text("It is shown once. If you close now you will need to make another.")
        }
        .onDisappear { model?.wipe() }
    }

    private func close() {
        if model?.hasUncopiedKey == true { confirmClose = true } else { finish() }
    }

    private func finish() {
        model?.wipe()
        dismiss()
    }
}

// MARK: Picker

private struct PickerSection: Identifiable {
    let group: AgentClientGroup
    let clients: [AgentClientInfo]
    var id: String { group.rawValue }
}

private struct ConnectPickerScreen: View {
    @Bindable var model: ConnectAgentModel
    let onClose: () -> Void

    private var pickerSections: [PickerSection] {
        AgentClientCatalog.sections(model.results).map { PickerSection(group: $0.group, clients: $0.clients) }
    }

    var body: some View {
        List {
            if let fresh = model.fresh {
                Section {
                    FreshKeyBanner(model: model, fresh: fresh)
                        .listRowInsets(EdgeInsets(top: HV.Space.s, leading: HV.Space.m, bottom: HV.Space.s, trailing: HV.Space.m))
                }
            } else if let existing = model.existingKey {
                Section {
                    Text("Steps for \(existing.displayName ?? existing.prefixLabel). Its key was shown once, so the steps show where it goes.")
                        .font(.hvCallout)
                        .foregroundStyle(Palette.textSecondary)
                }
            } else {
                Section {
                    Text(ConnectCopy.line)
                        .font(.hvCallout)
                        .foregroundStyle(Palette.textSecondary)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: HV.Space.m, bottom: 0, trailing: HV.Space.m))
                }
            }

            if model.fresh == nil, model.existingKey == nil, model.query.isEmpty {
                Section {
                    NavigationLink(value: ConnectRoute.justAKey) {
                        HVRow(symbol: "key.horizontal", tint: Palette.amber, title: "Just make a key", subtitle: "For anything not listed. You choose where it goes.")
                    }
                }
            }

            let sections = pickerSections
            ForEach(sections) { section in
                Section {
                    ForEach(section.clients) { info in
                        NavigationLink(value: ConnectRoute.client(info)) {
                            ClientRow(info: info)
                        }
                    }
                } header: {
                    HVSectionHeader(title: section.group.title)
                } footer: {
                    if model.query.isEmpty { Text(section.group.blurb).font(.hvCaption) }
                }
            }

            if sections.isEmpty {
                Section {
                    HVEmptyState(
                        symbol: "magnifyingglass", title: "Nothing called that",
                        message: "Try the name of the app, or choose Any agent that can make HTTP requests for a script or curl."
                    )
                    .listRowBackground(Color.clear)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .searchable(text: $model.query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search apps, like Cursor or curl")
        .navigationTitle(ConnectCopy.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(model.fresh == nil ? "Cancel" : "Done", action: onClose)
            }
        }
        .navigationDestination(for: ConnectRoute.self) { route in
            switch route {
            case .client(let info): ConnectClientScreen(info: info, model: model)
            case .justAKey: ConnectClientScreen(info: nil, model: model)
            }
        }
    }
}

private struct ClientRow: View {
    let info: AgentClientInfo

    var body: some View {
        HStack(spacing: HV.Space.s + 2) {
            HVIconBadge(symbol: info.group.symbol, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(info.name)
                    .font(.hvBody)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(2)
                Text(info.detailLine)
                    .font(.hvFootnote)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: HV.Space.xs)
            if !info.verified { HVTag(text: "Untested", tint: Palette.warning) }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(info.verified ? info.name : "\(info.name), untested")
    }

    private var tint: Color {
        switch info.group {
        case .chatApps: return Palette.violet
        case .codingAgents: return Palette.blue
        case .automation: return Palette.mint
        }
    }
}

/// The key that was just made, kept on the picker so picking another app reuses it.
private struct FreshKeyBanner: View {
    let model: ConnectAgentModel
    let fresh: ConnectAgentModel.FreshKey

    var body: some View {
        VStack(alignment: .leading, spacing: HV.Space.xs) {
            Label("Your key is ready", systemImage: "checkmark.circle.fill")
                .font(.hvHeadline)
                .foregroundStyle(Palette.success)
            Text("Pick the app to see its steps with this key filled in. It is shown once and goes when you close this.")
                .font(.hvFootnote)
                .foregroundStyle(Palette.textSecondary)
            KeysCopyButton(title: "Copy key", text: fresh.key, isSecret: true) { model.markCopied() }
        }
    }
}

// MARK: One app

private struct ConnectClientScreen: View {
    let info: AgentClientInfo?
    @Bindable var model: ConnectAgentModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var title: String { info?.name ?? "A key" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HV.Space.l) {
                if model.fresh == nil, model.existingKey == nil {
                    configure
                } else {
                    ready
                }
                if let info { guideSection(info) }
            }
            .padding(HV.Space.m)
            .hvReadableWidth()
        }
        .scrollDismissesKeyboard(.interactively)
        .hvScreenBackground()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            model.prepare(for: info)
            if let info { await model.loadDocument(for: info) }
        }
        .task(id: model.fresh?.prefix) {
            await model.watchSetup()
        }
    }

    // MARK: Before the key

    private var configure: some View {
        VStack(alignment: .leading, spacing: HV.Space.m) {
            VStack(alignment: .leading, spacing: HV.Space.xxs) {
                Text(info.map { "A key for \($0.name)" } ?? "A key of its own").font(.hvTitle)
                Text("One key per agent, so you can turn one off without touching the others.")
                    .font(.hvCallout)
                    .foregroundStyle(Palette.textSecondary)
            }

            VStack(alignment: .leading, spacing: HV.Space.xs) {
                Text("Name").font(.hvFootnote.weight(.semibold)).foregroundStyle(Palette.textSecondary)
                TextField("What do you call it?", text: $model.keyName)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .hvFieldChrome()
                    .onChange(of: model.keyName) { _, value in
                        if value.count > AgentKeyRules.nameMaxLength { model.keyName = String(value.prefix(AgentKeyRules.nameMaxLength)) }
                    }
            }

            Toggle(isOn: $model.canSendMail) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(AccountWords.mailSendLabel).font(.hvBody)
                    Text("Reading its mailbox is always allowed. Sending is your choice.")
                        .font(.hvCaption)
                        .foregroundStyle(Palette.textSecondary)
                }
            }

            if case .failed(let message) = model.make {
                KeysInlineMessage(text: message)
            }

            Button {
                Task { await model.makeKey() }
            } label: {
                if case .making = model.make {
                    HStack(spacing: HV.Space.xs) { ProgressView().tint(.white); Text(ConnectCopy.makingLine) }
                } else {
                    Text("Make the key")
                }
            }
            .buttonStyle(.hvPrimary)
            .disabled(isMaking)
            .accessibilityHint("Makes a key that is shown once.")
        }
    }

    private var isMaking: Bool {
        if case .making = model.make { return true }
        return false
    }

    // MARK: With the key

    @ViewBuilder
    private var ready: some View {
        if let fresh = model.fresh {
            VStack(alignment: .leading, spacing: HV.Space.m) {
                VStack(alignment: .leading, spacing: HV.Space.xs) {
                    Text(ConnectCopy.keyLine).font(.hvFootnote).foregroundStyle(Palette.textSecondary)
                    Text(fresh.key)
                        .font(.system(.footnote, design: .monospaced, weight: .medium))
                        .foregroundStyle(Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(HV.Space.s + 2)
                        .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: HV.Radius.m, style: .continuous))
                        .accessibilityLabel("Your key, shown once. Use the copy button.")
                    KeysCopyButton(title: "Copy key", text: fresh.key, isSecret: true) { model.markCopied() }
                }

                if let info { promptCard(info) }
                statusLine
            }
        } else if let existing = model.existingKey {
            VStack(alignment: .leading, spacing: HV.Space.m) {
                KeysNotice(
                    text: "\(existing.displayName ?? existing.prefixLabel) was shown once, so these steps hold \(ConnectKey.placeholder) where its key goes. Paste the key there, or make a new one.",
                    symbol: "info.circle.fill", tint: Palette.blue
                )
                if let info { promptCard(info) }
                statusLine
            }
        }
    }

    private func promptCard(_ info: AgentClientInfo) -> some View {
        VStack(alignment: .leading, spacing: HV.Space.s) {
            KeysCopyButton(
                title: ConnectCopy.promptLabel, text: model.prompt(for: info), isSecret: model.fresh != nil,
                style: .primary, accessibilityHint: "Copies a prompt for \(info.name) that holds the key."
            ) { model.markCopied() }
            Text(ConnectCopy.promptLine(info.name)).font(.hvCallout)
            if model.fresh != nil {
                Text(ConnectCopy.privateLine).font(.hvFootnote).foregroundStyle(Palette.textSecondary)
            }
        }
        .hvCard()
    }

    @ViewBuilder
    private var statusLine: some View {
        if model.isConnected {
            Label("Agent connected", systemImage: "checkmark.seal.fill")
                .font(.hvHeadline)
                .foregroundStyle(Palette.success)
        } else if model.canWatch {
            HStack(spacing: HV.Space.xs) {
                ProgressView()
                Text("Waiting for the agent to write back").font(.hvFootnote).foregroundStyle(Palette.textSecondary)
                Spacer(minLength: 0)
                Button("Check again") { Task { await model.checkConnected() } }.buttonStyle(.hvGhost)
            }
            Text(ConnectCopy.doneLine).font(.hvCaption).foregroundStyle(Palette.textTertiary)
        }
    }

    // MARK: The steps

    @ViewBuilder
    private func guideSection(_ info: AgentClientInfo) -> some View {
        if model.fresh != nil || model.existingKey != nil {
            if let state = model.documents[info.id] {
                switch state {
                case .loading:
                    HVLoadingState(message: "Getting the steps for \(info.name)")
                case .failed(let message):
                    VStack(alignment: .leading, spacing: HV.Space.s) {
                        KeysInlineMessage(text: message)
                        Button("Try again") { Task { await model.loadDocument(for: info) } }.buttonStyle(.hvGhost)
                        Text("The prompt above still points your AI at the steps.").font(.hvFootnote).foregroundStyle(Palette.textSecondary)
                    }
                case .loaded:
                    if let guide = model.guide(for: info) {
                        ConnectGuideView(guide: guide, info: info, key: model.fresh?.key)
                    }
                }
            } else {
                HVLoadingState(message: "Getting the steps for \(info.name)")
            }
        } else {
            // Before there is a key, say what it will be for and what the steps are like.
            VStack(alignment: .leading, spacing: HV.Space.xs) {
                if !info.verified { KeysNotice(text: ConnectCopy.untestedNote) }
                if info.keyInUrl { KeysNotice(text: ConnectCopy.urlKeyWarning) }
            }
        }
    }
}

#if DEBUG
#Preview("Connect, picker") {
    KeysPreviewHost(embedInNavigation: false) { ConnectAgentSheet() }
}
#endif
