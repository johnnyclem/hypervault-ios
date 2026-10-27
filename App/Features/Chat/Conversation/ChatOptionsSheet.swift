import HyperVaultKit
import SwiftUI

/// Which model answers, and what comes along: memory, context, tools. The
/// history lives on the server, so switching the model between messages loses
/// nothing.
struct ChatOptionsSheet: View {
    @Bindable var model: ChatConversationModel
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app

    var body: some View {
        NavigationStack {
            List {
                modelSection
                memorySection
                toolsSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .hvScreenBackground()
            .navigationTitle("Model and options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(for: ChatDestination.self) { destination in
                switch destination {
                case .models, .newConversation:
                    ChatModelsScreen(onChange: { model.backendsChanged($0) }, onLocalChange: { model.localModelsChanged($0) })
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: Model

    private var modelSection: some View {
        Section(header: HVSectionHeader(title: "Answers from")) {
            ForEach(model.backends) { backend in
                choiceRow(
                    title: backend.name, subtitle: backend.modelLine, symbol: "cpu",
                    selected: model.choice == .server(backend.id), enabled: true
                ) {
                    model.select(.server(backend.id))
                }
            }
            ForEach(model.localModels) { local in
                choiceRow(
                    title: local.displayName, subtitle: "On your network \u{00B7} \(local.model)", symbol: "desktopcomputer",
                    selected: model.choice == .local(local.id), enabled: true
                ) {
                    model.select(.local(local.id))
                }
            }
            if model.onDeviceUsable || !model.onDeviceStatus.isAvailable {
                choiceRow(
                    title: ChatOnDeviceModels.title,
                    subtitle: model.onDeviceUsable ? ChatOnDeviceModels.subtitle : model.onDeviceStatus.explanation,
                    symbol: "iphone", selected: model.choice == .onDevice, enabled: model.onDeviceUsable
                ) {
                    model.select(.onDevice)
                }
            }
            NavigationLink(value: ChatDestination.models) {
                Label(model.backends.isEmpty ? "Connect a model" : "Connect or edit models", systemImage: "plus.circle")
                    .frame(minHeight: 44, alignment: .leading)
            }
        }
        .hvListRow()
    }

    /// A model to answer with. One that is not available is not a button: it keeps the reason in plain
    /// sight, and only its badge is dimmed.
    @ViewBuilder
    private func choiceRow(title: String, subtitle: String, symbol: String, selected: Bool, enabled: Bool, action: @escaping () -> Void) -> some View {
        let label = HStack(spacing: HV.Space.s) {
            HVIconBadge(symbol: symbol, tint: selected ? Color.accentColor : Palette.textSecondary, size: 32)
                .opacity(enabled ? 1 : 0.5)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.hvBody).foregroundStyle(enabled ? Palette.textPrimary : Palette.textSecondary).lineLimit(2)
                Text(subtitle).font(.hvCaption).foregroundStyle(Palette.textSecondary).lineLimit(4)
            }
            Spacer(minLength: 0)
            if selected {
                HVIcon("checkmark").font(.hvCallout.weight(.bold)).foregroundStyle(Color.accentColor)
            }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())

        if enabled {
            Button {
                Haptics.select()
                action()
            } label: { label }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(selected ? .isSelected : [])
        } else {
            label.accessibilityElement(children: .combine)
        }
    }

    // MARK: Memory

    private var memorySection: some View {
        Section(header: HVSectionHeader(title: "Memory")) {
            toggle(
                "Recall", detail: "Ground replies in memories and pages you have kept.",
                isOn: $model.useRecall
            )
            toggle(
                "Smart context", detail: "Squeeze the older parts of long chats so the model remembers more with fewer words.",
                isOn: setting(.smartContext)
            )
            if model.showsDeepMemory {
                toggle(
                    "Deep memory", detail: "Recall decisions, people and topics from across all your conversations.",
                    isOn: setting(.deepMemory)
                )
            }
            if model.showsTruth {
                toggle(
                    "Truth", detail: "Cite what you have asserted ahead of everything else.",
                    isOn: setting(.truth)
                )
            }
        }
        .hvListRow()
    }

    private var toolsSection: some View {
        Section {
            if model.hasToolkit {
                toggle(
                    "Use my tools", detail: "Let the model act through the services you have connected.",
                    isOn: $model.useTools
                )
                .disabled(model.runsLocally)
            } else {
                Button {
                    dismiss()
                    app.router.open(.route(.tools))
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Set up tools").foregroundStyle(Palette.textPrimary)
                            Text("Connect a service and your chats can use it.")
                                .font(.hvCaption)
                                .foregroundStyle(Palette.textSecondary)
                        }
                        Spacer()
                        HVIcon(HVSymbol.open).font(.hvCaption.weight(.semibold)).foregroundStyle(Palette.textTertiary)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } header: {
            HVSectionHeader(title: "Tools")
        } footer: {
            if model.runsLocally {
                ChatFooter("A model that answers on this iPhone or your network can't use tools. Choose a connected model for that.")
            }
        }
        .hvListRow()
    }

    private func toggle(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.hvBody)
                Text(detail).font(.hvCaption).foregroundStyle(Palette.textSecondary)
            }
        }
        .frame(minHeight: 44)
    }

    private func setting(_ setting: ChatSetting) -> Binding<Bool> {
        Binding(
            get: { model.value(of: setting) },
            set: { newValue in
                Task {
                    do { try await model.set(setting, to: newValue) } catch { app.toasts.show(error: error) }
                }
            }
        )
    }
}

/// Who can read a chat, and its link.
struct ChatVisibilitySheet: View {
    let model: ChatConversationModel
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app
    @State private var working: ChatVisibility?

    private var current: ChatVisibility { model.conversation?.visibility ?? .private }

    var body: some View {
        NavigationStack {
            List {
                Section(footer: ChatFooter("Chats start private. A link you share stays the same if you turn sharing off and on again.")) {
                    ForEach(ChatVisibility.allCases, id: \.self) { visibility in
                        Button { choose(visibility) } label: {
                            HStack(spacing: HV.Space.s) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(visibility.title).font(.hvBody).foregroundStyle(Palette.textPrimary)
                                    Text(visibility.detail).font(.hvCaption).foregroundStyle(Palette.textSecondary)
                                }
                                Spacer(minLength: 0)
                                if working == visibility {
                                    ProgressView()
                                } else if current == visibility {
                                    HVIcon("checkmark").font(.hvCallout.weight(.bold)).foregroundStyle(Color.accentColor)
                                }
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(working != nil)
                        .accessibilityAddTraits(current == visibility ? .isSelected : [])
                    }
                }
                .hvListRow()
                if let url = model.shareURL, current.hasLink {
                    Section(header: HVSectionHeader(title: "Link")) {
                        Text(url.absoluteString)
                            .font(.hvMono)
                            .foregroundStyle(Palette.textSecondary)
                            .textSelection(.enabled)
                        ShareLink(item: url) {
                            Label("Share link", systemImage: "square.and.arrow.up").frame(minHeight: 44, alignment: .leading)
                        }
                        Button {
                            UIPasteboard.general.string = url.absoluteString
                            app.toasts.success("Link copied.")
                        } label: {
                            Label("Copy link", systemImage: HVSymbol.copy).frame(minHeight: 44, alignment: .leading)
                        }
                    }
                    .hvListRow()
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .hvScreenBackground()
            .navigationTitle("Who can read this")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func choose(_ visibility: ChatVisibility) {
        guard visibility != current else { return }
        working = visibility
        Task {
            defer { working = nil }
            do {
                try await model.setVisibility(visibility)
                Haptics.success()
            } catch {
                app.toasts.show(error: error)
            }
        }
    }
}
