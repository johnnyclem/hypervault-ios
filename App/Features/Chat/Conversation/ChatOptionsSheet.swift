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
                    ChatModelsScreen { model.backendsChanged($0) }
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
    }

    private func choiceRow(title: String, subtitle: String, symbol: String, selected: Bool, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.select()
            action()
        } label: {
            HStack(spacing: HV.Space.s) {
                HVIconBadge(symbol: symbol, tint: selected ? Color.accentColor : Palette.textSecondary, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.hvBody).foregroundStyle(Palette.textPrimary).lineLimit(1)
                    Text(subtitle).font(.hvCaption).foregroundStyle(Palette.textSecondary).lineLimit(3)
                }
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).foregroundStyle(Color.accentColor)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
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
    }

    private var toolsSection: some View {
        Section {
            if model.hasToolkit {
                toggle(
                    "Use my tools", detail: "Let the model act through the services you have connected.",
                    isOn: $model.useTools
                )
                .disabled(model.isOnDevice)
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
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.textTertiary)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } header: {
            HVSectionHeader(title: "Tools")
        } footer: {
            if model.isOnDevice {
                Text("A model on this iPhone can't use tools. Choose a connected model for that.")
            }
        }
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
                Section(footer: Text("Chats start private. A link you share stays the same if you turn sharing off and on again.")) {
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
                                    Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).foregroundStyle(Color.accentColor)
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
                            Label("Copy link", systemImage: "doc.on.doc").frame(minHeight: 44, alignment: .leading)
                        }
                    }
                }
            }
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
