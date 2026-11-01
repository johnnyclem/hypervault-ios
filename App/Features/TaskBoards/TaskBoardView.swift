import HyperVaultKit
import SwiftUI

extension BoardTaskStatus {
    var symbol: String {
        switch self {
        case .todo: return "circle"
        case .inProgress: return "circle.lefthalf.filled"
        case .blocked: return "exclamationmark.circle"
        case .review: return "eye.circle"
        case .done: return "checkmark.circle.fill"
        case .cancelled: return "xmark.circle"
        }
    }

    /// Blocked is the warning shade and review the web's accent; in progress is the accent blue. The symbol is
    /// different for every status, so the colour is never the only signal.
    var tint: Color {
        switch self {
        case .todo: return Palette.textTertiary
        case .inProgress: return Palette.blue
        case .blocked: return Palette.warning
        case .review: return Palette.sky
        case .done: return Palette.mint
        case .cancelled: return Palette.textTertiary
        }
    }
}

extension BoardAssignee {
    /// The mark for who holds a task: the key for an agent (as an agent's author line draws it in a page's history) and
    /// the person for a person. Both are outline, and the words beside it, or the label, name who it is.
    var holderSymbol: String { isAgent ? HVSymbol.agent : HVSymbol.contact }
}

struct TaskRef: Hashable, Identifiable {
    let id: String
}

/// A board, opened from anywhere that has a listing for it.
struct TaskBoardView: View {
    @Environment(AppEnvironment.self) private var env
    let listing: TaskBoardListing

    var body: some View {
        TaskBoardScreen(client: env.client, cache: env.cache, namespace: env.user.id, listing: listing)
    }
}

struct TaskBoardScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dynamicTypeSize) private var typeSize
    /// The add row's plus, in the size of the round mark at the left of a task (`TaskCheck`), so the two line up.
    @ScaledMetric(relativeTo: .title3) private var addGlyph: CGFloat = TaskCheck.glyphSize
    @State private var model: TaskBoardModel
    @State private var newTitle = ""
    @State private var collapsed: Set<BoardTaskStatus> = [.done, .cancelled]
    @FocusState private var addFocused: Bool
    let listing: TaskBoardListing

    init(client: HVClient, cache: DiskCache, namespace: String, listing: TaskBoardListing) {
        self.listing = listing
        _model = State(initialValue: TaskBoardModel(
            client: client, cache: cache, namespace: namespace, project: listing.project, title: listing.displayTitle
        ))
    }

    var body: some View {
        content
            .hvScreenBackground()
            .navigationTitle(listing.displayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: TaskRef.self) { ref in
                TaskDetailView(model: model, taskID: ref.id)
            }
            .task {
                model.onFailure = { sentence in app.toasts.show(sentence, style: .error) }
                await model.start()
            }
            .task { await pollWhileVisible() }
            .confirmationDialog(
                "This changed while you were editing",
                isPresented: Binding(get: { model.clash != nil }, set: { shown in
                    // Dismissed without choosing: let the change go, after any button has had its say.
                    if !shown { Task { @MainActor in model.resolveClash(keepMine: false) } }
                }),
                titleVisibility: .visible
            ) {
                Button("Keep my change") { model.resolveClash(keepMine: true) }
                Button("Use the latest", role: .cancel) { model.resolveClash(keepMine: false) }
            } message: {
                Text(model.clash?.reason ?? "")
            }
    }

    /// Looks again every half minute while the board is on screen; nothing comes
    /// back unless the revision moved.
    private func pollWhileVisible() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            if Task.isCancelled { return }
            await model.refresh()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            VStack {
                HVListSkeleton(rows: 5).padding(.top, HV.Space.m)
                Spacer()
            }
        case .failed(let message):
            HVErrorState(message: message) { Task { await model.load() } }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            board
        }
    }

    // MARK: The board

    private var board: some View {
        List {
            if model.isShowingSavedCopy {
                Section {
                    HVStaleBanner()
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }
            }
            Section {
                summaryRow
                filterRow
            }
            Section { addRow }
            if let current = model.board, current.tasks.isEmpty {
                Section {
                    HVEmptyState(symbol: "checklist", title: "Nothing here yet", message: "Add the first task above. Your agents will see it too.")
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            } else if model.groups.isEmpty {
                Section {
                    HVEmptyState(symbol: "line.3.horizontal.decrease.circle", title: "Nothing matches.", message: "Try another filter.")
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            }
            ForEach(model.groups) { group in
                Section {
                    if !collapsed.contains(group.status) {
                        ForEach(group.rows) { row in
                            taskRow(row)
                        }
                    }
                } header: {
                    groupHeader(group)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .refreshable { await model.refreshAndReport() }
        .hvAnimation(.spring(response: 0.4, dampingFraction: 0.85), value: model.board)
    }

    /// How far along the board is, and when it last moved. The row sits on the page, not on paper: it is
    /// the board's own heading, not one of its tasks.
    private var summaryRow: some View {
        VStack(alignment: .leading, spacing: HV.Space.s) {
            if let summary = model.summary {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: HV.Space.xs) {
                        progressFigures(summary)
                        Spacer(minLength: HV.Space.xs)
                        updatedLine
                    }
                    VStack(alignment: .leading, spacing: HV.Space.xxs) {
                        progressFigures(summary)
                        updatedLine
                    }
                }
                TaskProgressBar(done: summary.done, total: summary.countable)
                statusLine(summary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: HV.Space.xs, leading: HV.Space.m, bottom: HV.Space.xs, trailing: HV.Space.m))
    }

    private func progressFigures(_ summary: TaskBoardSummary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: HV.Space.xs) {
            Text("\(summary.progress)%")
                .font(.system(.title, weight: .semibold).monospacedDigit())
            Text("\(summary.done) of \(summary.countable) done")
                .font(.hvSubheadline.monospacedDigit())
                .foregroundStyle(Palette.textSecondary)
        }
    }

    /// When the board last changed, in a person's words. A revision number means nothing to them.
    @ViewBuilder
    private var updatedLine: some View {
        if let updated = model.board?.updatedAt {
            Text("Updated \(HVCopy.ago(since: updated).lowercased())")
                .font(.hvCaption.monospacedDigit())
                .foregroundStyle(Palette.textSecondary)
        }
    }

    @ViewBuilder
    private func statusLine(_ summary: TaskBoardSummary) -> some View {
        let parts: [String] = [
            summary.count(.inProgress) > 0 ? "\(summary.count(.inProgress)) in progress" : "",
            summary.count(.blocked) > 0 ? "\(summary.count(.blocked)) blocked" : "",
            summary.claimed.isEmpty ? "" : "\(summary.claimed.count) claimed",
        ].filter { !$0.isEmpty }
        if !parts.isEmpty {
            Text(parts.joined(separator: " · "))
                .font(.hvCaption.monospacedDigit())
                .foregroundStyle(Palette.textSecondary)
        }
    }

    /// The filter chips. The row has no side insets of its own so the chips can scroll out to the edge of
    /// the screen; the first one starts where the heading above it does. At an accessibility size the chips
    /// are too wide to scroll sideways and be seen to scroll, so they wrap onto as many lines as they need.
    private var filterRow: some View {
        filterChips
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
    }

    @ViewBuilder private var filterChips: some View {
        if typeSize.isAccessibilitySize {
            ChatFlowLayout(spacing: HV.Space.xs) { filterButtons }
                .padding(.horizontal, HV.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: HV.Space.xs) { filterButtons }
            }
            .contentMargins(.horizontal, HV.Space.m, for: .scrollContent)
            .scrollClipDisabled()
        }
    }

    @ViewBuilder private var filterButtons: some View {
        // The app's one filter component: it carries the haptic, the 44pt area and the selected trait itself.
        ForEach(TaskBoardFilter.allCases) { filter in
            HVFilterPill(title: filter.title, isSelected: model.filter == filter) {
                model.filter = filter
            }
        }
    }

    private var addRow: some View {
        HStack(spacing: HV.Space.s) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: HV.glyphBox(scaled: addGlyph, base: TaskCheck.glyphSize)))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            TextField("Add a task", text: $newTitle, prompt: Text.hvPrompt("Add a task"))
                .accessibilityIdentifier("taskboard.add")
                .focused($addFocused)
                .submitLabel(.done)
                .onSubmit { addTask() }
        }
        .frame(minHeight: 44)
        .hvListRow()
    }

    private func groupHeader(_ group: TaskBoardGroup) -> some View {
        let isCollapsed = collapsed.contains(group.status)
        return Button {
            Haptics.select()
            HV.Motion.animate {
                if isCollapsed { collapsed.remove(group.status) } else { collapsed.insert(group.status) }
            }
        } label: {
            HStack(spacing: HV.Space.xs) {
                HVIcon(group.status.symbol).foregroundStyle(group.status.tint)
                HVSectionHeader(title: group.status.title, detail: "\(group.rows.count)")
                    .frame(maxWidth: .infinity, alignment: .leading)
                HVIcon(HVSymbol.fold)
                    .font(.system(.caption2, weight: .bold))
                    .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                    .foregroundStyle(Palette.textSecondary)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .textCase(nil)
        .accessibilityLabel("\(group.status.title), \(group.rows.count)")
        .accessibilityHint(isCollapsed ? "Shows them" : "Hides them")
    }

    // MARK: A task

    private func taskRow(_ row: TaskBoardRow) -> some View {
        let task = row.task
        let temporary = TaskBoardModel.isTemporary(task.id)
        return HStack(alignment: .top, spacing: HV.Space.s) {
            TaskCheck(status: task.status) { tick(task) }
                .disabled(temporary)
                .accessibilityIdentifier("taskboard.check.\(task.id)")
            NavigationLink(value: TaskRef(id: task.id)) {
                TaskRowBody(task: task, rollup: model.board?.rollup(of: task.id), parentTitle: row.parentTitle)
            }
            .accessibilityIdentifier("taskboard.task.\(task.id)")
            .disabled(temporary)
        }
        .padding(.leading, CGFloat(min(row.depth, 3)) * HV.Space.l)
        .hvListRow()
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                tick(task)
            } label: {
                Label(task.status == .done ? "Reopen" : "Done", systemImage: task.status == .done ? "arrow.uturn.backward" : "checkmark")
            }
            .tint(task.status == .done ? Palette.blue : Palette.mint)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if task.lock != nil || task.assignee.kind != .unassigned {
                Button { model.enqueue(.release(taskID: task.id)); Haptics.tap() } label: { Label("Hand back", systemImage: "hand.raised") }
                    .tint(Palette.amber)
            } else {
                Button { model.enqueue(.claim(taskID: task.id, force: false)); Haptics.tap() } label: { Label("Mine", systemImage: "person.fill.checkmark") }
                    .tint(Palette.blue)
            }
        }
        .contextMenu { statusMenu(task) }
    }

    @ViewBuilder
    private func statusMenu(_ task: BoardTask) -> some View {
        ForEach(BoardTaskStatus.allCases.filter { $0 != task.status }) { status in
            Button {
                Haptics.select()
                model.enqueue(.setStatus(taskID: task.id, to: status))
            } label: {
                Label("Mark \(status.title.lowercased())", systemImage: status.symbol)
            }
        }
    }

    private func tick(_ task: BoardTask) {
        let next = task.status.cycled
        model.enqueue(.setStatus(taskID: task.id, to: next))
        if next == .done { Haptics.success() } else { Haptics.tap() }
    }

    private func addTask() {
        let title = newTitle
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        newTitle = ""
        Haptics.tap()
        model.add(title: title)
        addFocused = true
    }
}

/// The round mark at the left of a task. One tap moves it along: to do, in
/// progress, done, and back.
struct TaskCheck: View {
    let status: BoardTaskStatus
    let action: () -> Void
    /// One size for the round glyphs of a board: this mark, the add rows' plus and the note's send. It grows with the
    /// type by no more than a quarter and stops at 44 (`HV.glyphBox`), inside the 44pt target.
    static let glyphSize: CGFloat = 24
    @ScaledMetric(relativeTo: .title3) private var glyph: CGFloat = TaskCheck.glyphSize

    var body: some View {
        Button(action: action) {
            Image(systemName: status.symbol)
                .font(.system(size: HV.glyphBox(scaled: glyph, base: Self.glyphSize), weight: .regular))
                .foregroundStyle(status.tint)
                .hvBounce(value: status == .done)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(status.title)
        .accessibilityHint("Moves it along")
    }
}

/// A task's title and the quiet line under it: who has it, how far, how many notes.
struct TaskRowBody: View {
    let task: BoardTask
    let rollup: (done: Int, total: Int)?
    let parentTitle: String?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: HV.Space.xxs) {
            Text(task.title)
                .font(.hvBody)
                .foregroundStyle(task.status == .done || task.status == .cancelled ? Palette.textTertiary : Palette.textPrimary)
                .strikethrough(task.status == .done || task.status == .cancelled, color: Palette.textTertiary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 3)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let line = detailLine {
                Text(line)
                    .font(.hvCaption)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
            }
            if let holder = task.holder {
                HStack(spacing: 4) {
                    HVIcon(task.assignee.holderSymbol).font(.system(.caption2, weight: .semibold))
                    Text(holder).lineLimit(1)
                }
                .font(.hvCaption)
                .foregroundStyle(Palette.textSecondary)
            }
        }
        .padding(.vertical, HV.Space.xxs)
        // A task with only a title is a line of text: 20 points to tap. The row is at least a finger tall, and all of
        // it opens the task.
        .frame(minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var detailLine: String? {
        var parts: [String] = []
        if let parentTitle { parts.append("in \(parentTitle)") }
        if task.status == .inProgress, let active = task.activeForm, !active.isEmpty { parts.append(active) }
        if let rollup { parts.append("\(rollup.done)/\(rollup.total) subtasks") }
        if let priority = task.priority, priority == .high || priority == .critical { parts.append(priority.title) }
        if !task.notes.isEmpty { parts.append(task.notes.count == 1 ? "1 note" : "\(task.notes.count) notes") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

#if DEBUG
#Preview("Board") {
    PreviewHost(routes: TaskBoardPreviewData.boardRoutes) {
        TaskBoardView(listing: TaskBoardPreviewData.listing)
    }
}
#endif
