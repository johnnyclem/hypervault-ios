import HyperVaultKit
import SwiftUI

/// One task: its state, who has it, its subtasks and its notes.
struct TaskDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let model: TaskBoardModel
    let taskID: String

    @State private var title = ""
    @State private var newSubtask = ""
    @State private var newNote = ""
    @State private var progress = 0.0
    @State private var isSliding = false
    @State private var confirmTakeOver = false
    @FocusState private var focus: Field?

    private enum Field: Hashable { case title, subtask, note }

    private var task: BoardTask? { model.board?.task(taskID) }

    var body: some View {
        Group {
            if let task {
                form(task)
            } else {
                HVEmptyState(symbol: "checklist", title: "That task is gone.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .hvScreenBackground()
        .navigationTitle("Task")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { syncFields(force: true) }
        .onChange(of: task) { _, _ in syncFields(force: false) }
    }

    /// Fills the fields from the task: at first, and again when it changes under
    /// the person (an agent renamed it, say) unless they are in the middle of editing.
    private func syncFields(force: Bool) {
        guard let task else { return }
        if force || focus != .title { title = task.title }
        if force || !isSliding { progress = Double(task.progress ?? 0) }
    }

    private func form(_ task: BoardTask) -> some View {
        Form {
            Section {
                TextField("Title", text: $title, axis: .vertical)
                    .focused($focus, equals: .title)
                    .submitLabel(.done)
                    .onSubmit { commitTitle(task) }
                    .font(.hvTitle3)
                    .onChange(of: focus) { _, new in if new != .title { commitTitle(task) } }
                    .hvListRow()
            }

            Section {
                Group {
                    Picker("Status", selection: Binding(get: { task.status }, set: { setStatus($0, task) })) {
                        ForEach(BoardTaskStatus.allCases) { status in
                            Label(status.title, systemImage: status.symbol).tag(status)
                        }
                    }
                    Picker("Priority", selection: Binding(get: { task.priority }, set: { model.enqueue(.setPriority(taskID: task.id, to: $0)) })) {
                        Text("None").tag(BoardTaskPriority?.none)
                        ForEach(BoardTaskPriority.allCases) { priority in
                            Text(priority.title).tag(BoardTaskPriority?.some(priority))
                        }
                    }
                    if task.status == .inProgress || task.progress != nil {
                        VStack(alignment: .leading, spacing: HV.Space.xs) {
                            HStack {
                                Text("Progress")
                                Spacer()
                                Text("\(Int(progress))%").foregroundStyle(Palette.textSecondary).monospacedDigit()
                            }
                            Slider(value: $progress, in: 0...100, step: 5) { editing in
                                isSliding = editing
                                if !editing { model.enqueue(.setProgress(taskID: task.id, to: Int(progress))) }
                            }
                            .accessibilityLabel("Progress")
                            .accessibilityValue("\(Int(progress)) percent")
                        }
                    }
                }
                .hvListRow()
            }

            holderSection(task)

            if let description = task.description, !description.isEmpty {
                Section {
                    Text(description).font(.hvBody).hvListRow()
                } header: {
                    HVSectionHeader(title: "About")
                }
            }

            if let activeForm = task.activeForm, task.status == .inProgress {
                Section {
                    Text(activeForm).font(.hvBody).hvListRow()
                } header: {
                    HVSectionHeader(title: "Right now")
                }
            }

            subtasksSection(task)
            notesSection(task)
            linksSection(task)

            if task.status.isOpen {
                Section {
                    Button("Mark done") { complete(task) }
                        .buttonStyle(.hvPrimary)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                } footer: {
                    Text("What you wrote under Notes goes with it as the closing note.")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .confirmationDialog("Take this over?", isPresented: $confirmTakeOver, titleVisibility: .visible) {
            Button("Take it over") { model.enqueue(.claim(taskID: task.id, force: true)) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(task.holder ?? "Someone") has it right now. Only take it if they are clearly gone.")
        }
    }

    // MARK: Who has it

    @ViewBuilder
    private func holderSection(_ task: BoardTask) -> some View {
        Section {
            Group {
                if let holder = task.holder {
                    LabeledContent {
                        Text(holder).foregroundStyle(task.assignee.isAgent ? Palette.violet : Palette.blue)
                    } label: {
                        Label(task.assignee.isAgent ? "Claimed by an agent" : "Yours", systemImage: task.assignee.isAgent ? "sparkle" : "person.fill")
                    }
                    if let expires = task.lock?.expiresAt, task.lock?.isLive() == true {
                        Text("Held until \(expires.formatted(date: .omitted, time: .shortened))")
                            .font(.hvCaption)
                            .foregroundStyle(Palette.textSecondary)
                    }
                } else {
                    Text("Nobody has this yet.").foregroundStyle(Palette.textSecondary)
                }
                if task.status.isOpen {
                    if task.assignee.isHuman {
                        Button("Hand it back") { model.enqueue(.release(taskID: task.id)) }
                    } else if task.lock?.isLive() == true {
                        Button("Take it over", role: .destructive) { confirmTakeOver = true }
                    } else {
                        Button("I'll take it") {
                            Haptics.tap()
                            model.enqueue(.claim(taskID: task.id, force: false))
                        }
                    }
                }
            }
            .hvListRow()
        }
    }

    // MARK: Subtasks, notes, links

    private func subtasksSection(_ task: BoardTask) -> some View {
        let subtasks = model.board?.subtasks(of: task.id) ?? []
        let temporary = TaskBoardModel.isTemporary(task.id)
        return Section {
            Group {
                ForEach(subtasks) { sub in
                    subtaskRow(sub)
                }
                addSubtaskRow(task, temporary: temporary)
            }
            .hvListRow()
        } header: {
            HVSectionHeader(title: "Subtasks")
        }
    }

    private func subtaskRow(_ sub: BoardTask) -> some View {
        HStack(spacing: HV.Space.s) {
            TaskCheck(status: sub.status) {
                model.enqueue(.setStatus(taskID: sub.id, to: sub.status.cycled))
                if sub.status.cycled == .done { Haptics.success() } else { Haptics.tap() }
            }
            .disabled(TaskBoardModel.isTemporary(sub.id))
            NavigationLink(value: TaskRef(id: sub.id)) {
                Text(sub.title)
                    .strikethrough(sub.status == .done, color: Palette.textTertiary)
                    .foregroundStyle(sub.status == .done ? Palette.textTertiary : Palette.textPrimary)
            }
            .disabled(TaskBoardModel.isTemporary(sub.id))
        }
    }

    private func addSubtaskRow(_ task: BoardTask, temporary: Bool) -> some View {
        HStack(spacing: HV.Space.s) {
            Image(systemName: "plus.circle.fill").foregroundStyle(.tint).accessibilityHidden(true)
            TextField("Add a subtask", text: $newSubtask)
                .focused($focus, equals: .subtask)
                .submitLabel(.done)
                .onSubmit {
                    model.add(title: newSubtask, parent: task.id)
                    newSubtask = ""
                    Haptics.tap()
                }
                .disabled(temporary)
        }
        .frame(minHeight: 44)
    }

    private func notesSection(_ task: BoardTask) -> some View {
        Section {
            Group {
                ForEach(task.notes) { note in
                    noteRow(note)
                }
                addNoteRow(task)
            }
            .hvListRow()
        } header: {
            HVSectionHeader(title: "Notes")
        }
    }

    private func noteRow(_ note: BoardNote) -> some View {
        // Side by side while there is room. At an accessibility size three things on one line leave each a sliver ("Clau/de
        // Cod/e", "age/nt"), so the author, the tag and the time each take a line.
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(spacing: HV.Space.xs))
        return VStack(alignment: .leading, spacing: 3) {
            layout {
                Text(note.author ?? "Someone").font(.hvFootnote.weight(.semibold))
                if note.isFromAgent { HVTag(text: "agent", tint: Palette.violet) }
                if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                if let when = note.createdAt {
                    Text(when.formatted(date: .abbreviated, time: .shortened))
                        .font(.hvCaption)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text(verbatim: note.body).font(.hvBody)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private func addNoteRow(_ task: BoardTask) -> some View {
        let isEmpty = newNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(alignment: .bottom, spacing: HV.Space.s) {
            TextField("Leave a note", text: $newNote, axis: .vertical)
                .focused($focus, equals: .note)
                .lineLimit(1...5)
            Button {
                let text = newNote.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                model.enqueue(.addNote(taskID: task.id, text: text))
                newNote = ""
                Haptics.tap()
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 28))
            }
            .buttonStyle(.plain)
            .foregroundStyle(isEmpty ? Palette.textTertiary : Color.accentColor)
            .disabled(isEmpty)
            .frame(width: 44, height: 44)
            .accessibilityLabel("Add note")
        }
    }

    @ViewBuilder
    private func linksSection(_ task: BoardTask) -> some View {
        let waitingOn = task.dependsOn.compactMap { model.board?.task($0) }
        let holdingUp = task.blocks.compactMap { model.board?.task($0) }
        if !waitingOn.isEmpty || !holdingUp.isEmpty {
            Section {
                Group {
                    ForEach(waitingOn) { other in
                        Label("Waits on \(other.title)", systemImage: "arrow.turn.down.right").hvRowLabel()
                            .font(.hvSubheadline)
                    }
                    ForEach(holdingUp) { other in
                        Label("Holds up \(other.title)", systemImage: "arrow.turn.up.right").hvRowLabel()
                            .font(.hvSubheadline)
                    }
                }
                .hvListRow()
            } header: {
                HVSectionHeader(title: "Connected")
            }
        }
    }

    // MARK: Actions

    private func commitTitle(_ task: BoardTask) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { title = task.title; return }
        if trimmed != task.title { model.enqueue(.rename(taskID: task.id, to: trimmed)) }
    }

    private func setStatus(_ status: BoardTaskStatus, _ task: BoardTask) {
        guard status != task.status else { return }
        model.enqueue(.setStatus(taskID: task.id, to: status))
        if status == .done { Haptics.success() } else { Haptics.select() }
    }

    private func complete(_ task: BoardTask) {
        let note = newNote.trimmingCharacters(in: .whitespacesAndNewlines)
        model.enqueue(.complete(taskID: task.id, note: note.isEmpty ? nil : note))
        newNote = ""
        Haptics.success()
        dismiss()
    }
}
