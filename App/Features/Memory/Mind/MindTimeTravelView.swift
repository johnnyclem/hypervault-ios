import HyperVaultKit
import SwiftUI

/// Time travel: your whole memory as it stood at a moment. A memory that has
/// changed since can be put back as it was then; one that was forgotten can be
/// brought back. Both land as new commits, so nothing is lost either way.
struct MindTimeTravelView: View {
    let list: MemoryListModel

    @Environment(AppModel.self) private var app
    @State private var model: MindTimeTravelModel
    @State private var moment: Date
    @State private var confirming: MindStateMemory?

    init(list: MemoryListModel) {
        self.list = list
        _model = State(initialValue: MindTimeTravelModel(env: list.env, branch: list.branch))
        _moment = State(initialValue: Date().addingTimeInterval(-7 * 86_400))
    }

    private static let presets: [(String, TimeInterval)] = [
        ("Yesterday", 86_400), ("Last week", 7 * 86_400), ("Last month", 30 * 86_400), ("Three months", 90 * 86_400),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HV.Space.l) {
                picker
                result
            }
            .padding(HV.Space.m)
            .padding(.bottom, HV.Space.xl)
            .hvReadableWidth()
        }
        .hvScreenBackground()
        .navigationTitle("Time travel")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: moment) {
            // Wait for the wheel to stop turning.
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            await model.load(at: moment)
        }
        .confirmationDialog(
            "Put it back as it was?",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            titleVisibility: .visible,
            presenting: confirming
        ) { memory in
            Button(isCurrent(memory) ? "Restore this version" : "Bring it back") { restore(memory) }
        } message: { memory in
            Text("\u{201C}\(memory.title)\u{201D} goes back to how it stood on \(moment.formatted(date: .abbreviated, time: .shortened)). It is saved as a new commit, so the version it has now stays in history.")
        }
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: HV.Space.s) {
            Text("See your memory on \(list.branch) as it stood at a moment, and put things back if you want them.")
                .font(.hvCallout)
                .foregroundStyle(Palette.textSecondary)
            DatePicker("Moment", selection: $moment, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.compact)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: HV.Space.xs) {
                    ForEach(Self.presets, id: \.0) { preset in
                        Button {
                            Haptics.select()
                            moment = Date().addingTimeInterval(-preset.1)
                        } label: {
                            HVChip(title: preset.0)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .hvCard()
    }

    @ViewBuilder
    private var result: some View {
        switch model.phase {
        case .loading:
            HVLoadingState(message: "Going back\u{2026}")
        case .failed(let message):
            VStack(spacing: HV.Space.s) {
                Text(message)
                    .font(.hvFootnote)
                    .foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.center)
                Button("Try again") { Task { await model.load(at: moment) } }
                    .buttonStyle(.hvGhost)
            }
            .frame(maxWidth: .infinity)
        case .loaded(let state):
            VStack(alignment: .leading, spacing: HV.Space.s) {
                if state.memories.isEmpty {
                    HVEmptyState(symbol: "calendar.badge.clock", title: "Nothing yet", message: state.message.isEmpty ? "Your memory was empty at that moment." : state.message)
                } else {
                    Text(state.message)
                        .font(.hvHeadline)
                        .foregroundStyle(Palette.textPrimary)
                    ForEach(state.memories) { memory in
                        row(memory)
                    }
                }
            }
        }
    }

    private func isCurrent(_ memory: MindStateMemory) -> Bool {
        list.items.contains { $0.id == memory.id }
    }

    private func row(_ memory: MindStateMemory) -> some View {
        let exists = isCurrent(memory)
        return VStack(alignment: .leading, spacing: HV.Space.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(memory.title)
                    .font(.hvHeadline)
                    .foregroundStyle(Palette.textPrimary)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: HV.Space.xs)
                if !exists { HVTag(text: "Forgotten since", tint: Palette.rose) }
            }
            if !memory.summary.isEmpty {
                Text(memory.summary)
                    .font(.hvSubheadline)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(2)
            }
            HStack(spacing: HV.Space.xs) {
                if exists {
                    NavigationLink(value: Route.memory(id: memory.id)) {
                        Text("Open now")
                            .font(.hvSubheadline.weight(.semibold))
                    }
                    .buttonStyle(.hvGhost)
                }
                Button(exists ? "Restore this version" : "Bring it back") { confirming = memory }
                    .buttonStyle(.hvGhost)
                    .disabled(model.restoringID != nil)
                Spacer(minLength: 0)
                if model.restoringID == memory.id { ProgressView() }
            }
            .padding(.leading, -HV.Space.s)
        }
        .hvCard()
    }

    private func restore(_ memory: MindStateMemory) {
        confirming = nil
        let at = moment
        Task {
            do {
                let message = try await model.restore(memory, at: at)
                Haptics.success()
                app.toasts.success(message)
                await list.refresh(app: nil)
            } catch {
                app.toasts.show(error: error)
            }
        }
    }
}
