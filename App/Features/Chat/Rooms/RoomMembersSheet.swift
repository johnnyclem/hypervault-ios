import HyperVaultKit
import SwiftUI

/// Who is in the room: see each member's role, add another of your models, or
/// take one out.
struct ChatRoomMembersSheet: View {
    let model: ChatRoomModel
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app
    @State private var backends: ChatBackendsModel
    @State private var pendingRemoval: ChatRoomMember?
    @State private var adding = false
    @State private var newHandle = ""
    @State private var newBrief = ""
    @State private var chosenBackend: String?
    @State private var errorText: String?
    @State private var isWorking = false

    init(model: ChatRoomModel, env: AppEnvironment) {
        self.model = model
        _backends = State(initialValue: ChatBackendsModel(client: env.client, cache: env.cache, namespace: env.user.id))
    }

    private var taken: Set<String> { Set(model.members.map(\.handle)) }

    private var palette: ChatRoomPalette { ChatRoomPalette(members: model.members) }

    private var problem: String? {
        guard adding, chosenBackend != nil else { return nil }
        return ChatRoomHandles.problem(in: [newHandle], alreadyTaken: taken)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.members) { member in
                        memberRow(member, color: palette.color(for: member))
                            .accessibilityIdentifier("room.member.\(member.handle)")
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) { pendingRemoval = member } label: {
                                    Label("Remove", systemImage: "person.badge.minus")
                                }
                            }
                    }
                } header: {
                    HVSectionHeader(title: "In this room")
                }
                .hvListRow()
                addSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .hvScreenBackground()
            .navigationTitle("Members")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .confirmationDialog(
                "Remove this member?",
                isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
                titleVisibility: .visible, presenting: pendingRemoval
            ) { member in
                Button("Remove @\(member.handle)", role: .destructive) { remove(member) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("What they said stays in the room. Any turn they were waiting for is skipped.")
            }
            .task { await backends.load() }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func memberRow(_ member: ChatRoomMember, color: Color) -> some View {
        VStack(alignment: .leading, spacing: HV.Space.xxs) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8).accessibilityHidden(true)
                Text("@\(member.handle)").font(.hvBody.weight(.medium))
                if let model = member.backend?.defaultModel, !model.isEmpty {
                    Text(model).font(.hvCaption).foregroundStyle(Palette.textTertiary).lineLimit(1)
                }
            }
            if let name = member.backend?.name, !name.isEmpty {
                Text(name).font(.hvFootnote).foregroundStyle(Palette.textSecondary)
            }
            if !member.roleBrief.isEmpty {
                Text(member.roleBrief).font(.hvFootnote).foregroundStyle(Palette.textSecondary).lineLimit(3)
            }
        }
        .padding(.vertical, HV.Space.xxs)
        .frame(minHeight: 44, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var addSection: some View {
        if !adding {
            Section {
                Button { startAdding() } label: {
                    Label("Add a member", systemImage: "plus.circle").hvRowLabel().frame(minHeight: 44, alignment: .leading)
                }
                .disabled(backends.backends.isEmpty)
            } footer: {
                if backends.backends.isEmpty, backends.phase == .loaded {
                    ChatFooter("Connect a model under Chat, Models, then add it here.")
                }
            }
            .hvListRow()
        } else {
            Section {
                Picker("Model", selection: Binding(get: { chosenBackend ?? "" }, set: { choose($0) })) {
                    ForEach(backends.backends) { backend in
                        Text("\(backend.name) \u{00B7} \(backend.modelLine)").tag(backend.id)
                    }
                }
                VStack(alignment: .leading, spacing: HV.Space.m) {
                    HVLabeledField(title: "Handle") {
                        HStack(spacing: 2) {
                            Text("@").foregroundStyle(Palette.textSecondary)
                            TextField("Handle", text: $newHandle, prompt: chatPrompt("claude"))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .accessibilityIdentifier("room.member.handle")
                        }
                    }
                    HVLabeledField(title: "Role (optional)") {
                        TextField("Role", text: $newBrief, prompt: chatPrompt("What they own here"), axis: .vertical)
                            .lineLimit(1...4)
                    }
                }
                .padding(.vertical, HV.Space.xs)
            }
            .hvListRow()
            Section {
                VStack(alignment: .leading, spacing: HV.Space.s) {
                    Button {
                        add()
                    } label: {
                        if isWorking { ProgressView().tint(.white) } else { Text("Add to the room") }
                    }
                    .buttonStyle(.hvPrimary)
                    .disabled(isWorking || chosenBackend == nil || problem != nil || newHandle.trimmingCharacters(in: .whitespaces).isEmpty)
                    if let text = errorText ?? problem {
                        Text(text)
                            .font(.hvFootnote)
                            .foregroundStyle(errorText != nil ? Palette.danger : Palette.textSecondary)
                            .padding(.horizontal, HV.Space.m)
                    }
                    Button("Cancel") { adding = false; errorText = nil }
                        .buttonStyle(.hvGhost)
                        .padding(.horizontal, HV.Space.m)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
        }
    }

    private func startAdding() {
        adding = true
        errorText = nil
        if let first = backends.backends.first { choose(first.id) }
    }

    private func choose(_ id: String) {
        chosenBackend = id
        guard let backend = backends.backends.first(where: { $0.id == id }) else { return }
        var handle = ChatRoomHandles.defaultHandle(provider: backend.provider, name: backend.name)
        var n = 2
        let base = handle
        while taken.contains(handle) {
            handle = "\(base)\(n)"
            n += 1
        }
        newHandle = handle
    }

    private func add() {
        guard let backend = chosenBackend else { return }
        isWorking = true
        errorText = nil
        let draft = ChatRoomMemberDraft(backendID: backend, handle: newHandle, roleBrief: String(newBrief.prefix(ChatRoomHandles.maxRoleBrief)))
        Task {
            defer { isWorking = false }
            do {
                try await model.addMembers([draft])
                Haptics.success()
                adding = false
                newBrief = ""
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    private func remove(_ member: ChatRoomMember) {
        Task {
            do {
                try await model.remove(member)
                Haptics.success()
            } catch {
                app.toasts.show(error: error)
            }
        }
    }
}
