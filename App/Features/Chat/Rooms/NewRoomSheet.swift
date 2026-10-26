import HyperVaultKit
import SwiftUI

/// Starts a room: pick which of your connected models join, give each a handle
/// the room will address it by, and optionally a standing brief.
@MainActor
@Observable
final class ChatNewRoomModel {
    struct Seat: Identifiable, Equatable {
        let backend: ChatBackend
        var isOn: Bool
        var handle: String
        var brief: String
        var id: String { backend.id }
    }

    enum Phase: Equatable {
        case loading
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    var seats: [Seat] = []
    var title = ""
    private(set) var isCreating = false
    var errorText: String?

    private let client: HVClient
    private let cache: DiskCache
    private let namespace: String

    init(client: HVClient, cache: DiskCache, namespace: String) {
        self.client = client
        self.cache = cache
        self.namespace = namespace
    }

    var chosen: [Seat] { seats.filter(\.isOn) }

    /// What is wrong with the roster, in plain words, or nil.
    var problem: String? {
        ChatRoomHandles.problem(in: chosen.map(\.handle))
    }

    var canCreate: Bool { !chosen.isEmpty && problem == nil && !isCreating }

    func load() async {
        let client = self.client
        do {
            let stream = cachedLoad(cache: cache, namespace: namespace, key: ChatBackendsModel.cacheKey) {
                try await client.send(.backends)
            }
            for try await loaded in stream {
                let handles = ChatRoomHandles.defaultHandles(for: loaded.value)
                // Keep what the person already typed when the fresh list arrives.
                let existing = Dictionary(uniqueKeysWithValues: seats.map { ($0.id, $0) })
                seats = loaded.value.map { backend in
                    existing[backend.id] ?? Seat(backend: backend, isOn: true, handle: handles[backend.id] ?? backend.provider, brief: "")
                }
                phase = .ready
            }
        } catch {
            if seats.isEmpty { phase = .failed((error as? HVError)?.userMessage ?? error.localizedDescription) }
        }
    }

    func create() async -> ChatRoomSummary? {
        guard canCreate else { return nil }
        isCreating = true
        errorText = nil
        defer { isCreating = false }
        let members = chosen.map {
            ChatRoomMemberDraft(backendID: $0.backend.id, handle: $0.handle, roleBrief: String($0.brief.prefix(ChatRoomHandles.maxRoleBrief)))
        }
        do {
            let created = try await client.send(.createRoom(title: title, members: members))
            await cache.remove(key: ChatRoomsListModel.cacheKey, namespace: namespace)
            return ChatRoomSummary(id: created.room.id, title: created.room.title, updatedAt: Date(), members: created.members)
        } catch let error as HVError {
            errorText = error.sentence(offline: "Network hiccup. The room was not made. Try again.")
            return nil
        } catch {
            errorText = error.localizedDescription
            return nil
        }
    }
}

struct ChatNewRoomSheet: View {
    var onCreated: (ChatRoomSummary) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var model: ChatNewRoomModel

    init(client: HVClient, cache: DiskCache, namespace: String, onCreated: @escaping (ChatRoomSummary) -> Void) {
        self.onCreated = onCreated
        _model = State(initialValue: ChatNewRoomModel(client: client, cache: cache, namespace: namespace))
    }

    var body: some View {
        NavigationStack {
            content
                .scrollContentBackground(.hidden)
                .hvScreenBackground()
                .navigationTitle("New room")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                }
                .navigationDestination(for: ChatDestination.self) { _ in ChatModelsScreen() }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task { await model.load() }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading:
            HVLoadingState(message: "Loading your models")
        case .failed(let message):
            HVErrorState(message: message) { Task { await model.load() } }
        case .ready:
            if model.seats.isEmpty {
                VStack(spacing: HV.Space.m) {
                    HVEmptyState(
                        symbol: "cpu",
                        title: "Connect a model first.",
                        message: "Rooms are made of your connected models. Connect at least one, then come back to start a room."
                    )
                    NavigationLink(value: ChatDestination.models) { Text(HVCopy.connectAILabel) }
                        .buttonStyle(.hvPrimary)
                        .padding(.horizontal, HV.Space.xl)
                }
                .frame(maxHeight: .infinity)
            } else {
                form
            }
        }
    }

    private var form: some View {
        @Bindable var model = model
        return Form {
            Section {
                HVLabeledField(title: "Room name (optional)") {
                    TextField("Room name", text: $model.title, prompt: chatPrompt("Weekly review"))
                        .onChange(of: model.title) { if model.title.count > ChatRoomHandles.maxTitle { model.title = String(model.title.prefix(ChatRoomHandles.maxTitle)) } }
                }
                .padding(.vertical, HV.Space.xs)
            } footer: {
                ChatFooter("Pick who joins. The handle is how you, and the others, address each one.")
            }
            .hvListRow()
            ForEach($model.seats) { $seat in
                Section {
                    Toggle(isOn: $seat.isOn) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(seat.backend.name).font(.hvBody)
                            Text(seat.backend.modelLine).font(.hvCaption).foregroundStyle(Palette.textSecondary)
                        }
                    }
                    .frame(minHeight: 44)
                    if seat.isOn {
                        VStack(alignment: .leading, spacing: HV.Space.m) {
                            HVLabeledField(title: "Handle") {
                                HStack(spacing: 2) {
                                    Text("@").foregroundStyle(Palette.textSecondary)
                                    TextField("Handle", text: $seat.handle, prompt: chatPrompt("claude"))
                                        .textInputAutocapitalization(.never)
                                        .autocorrectionDisabled()
                                }
                            }
                            HVLabeledField(title: "Role (optional)") {
                                TextField(
                                    "Role", text: $seat.brief,
                                    prompt: chatPrompt("What \(ChatRoomHandles.normalize(seat.handle).map { "@" + $0 } ?? "this member") owns here"),
                                    axis: .vertical
                                )
                                .lineLimit(1...4)
                            }
                        }
                        .padding(.vertical, HV.Space.xs)
                    }
                }
                .hvListRow()
            }
            Section {
                VStack(alignment: .leading, spacing: HV.Space.s) {
                    Button {
                        Task {
                            if let created = await model.create() {
                                Haptics.success()
                                dismiss()
                                onCreated(created)
                            }
                        }
                    } label: {
                        if model.isCreating {
                            ProgressView().tint(.white)
                        } else {
                            Text("Start room with \(model.chosen.count) member\(model.chosen.count == 1 ? "" : "s")")
                        }
                    }
                    .buttonStyle(.hvPrimary)
                    .disabled(!model.canCreate)

                    // The note under the button starts on the same line as the notes under the cards above.
                    if let text = model.errorText ?? model.problem {
                        Text(text)
                            .font(.hvFootnote)
                            .foregroundStyle(model.errorText != nil ? Palette.danger : Palette.textSecondary)
                            .padding(.horizontal, HV.Space.m)
                    } else if model.chosen.isEmpty {
                        Text("Choose at least one member.")
                            .font(.hvFootnote)
                            .foregroundStyle(Palette.textSecondary)
                            .padding(.horizontal, HV.Space.m)
                    }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
        }
    }
}
