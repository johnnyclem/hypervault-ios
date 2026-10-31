import HyperVaultKit
import SwiftUI

/// Lists the person shares with their agents. Light to look at, satisfying to tick.
struct TaskBoardsRootView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        TaskBoardsScreen(client: env.client, cache: env.cache, namespace: env.user.id)
    }
}

struct TaskBoardsScreen: View {
    @Environment(AppModel.self) private var app
    @State private var model: TaskBoardsModel
    @State private var showCreate = false
    private let client: HVClient
    private let cache: DiskCache
    private let namespace: String

    init(client: HVClient, cache: DiskCache, namespace: String) {
        self.client = client
        self.cache = cache
        self.namespace = namespace
        _model = State(initialValue: TaskBoardsModel(client: client, cache: cache, namespace: namespace))
    }

    var body: some View {
        content
            .hvScreenBackground()
            .navigationTitle("Task boards")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showCreate = true
                    } label: {
                        Image(systemName: HVSymbol.add).frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("New board")
                }
            }
            .task { await model.start() }
            .navigationDestination(for: TaskBoardListing.self) { listing in
                TaskBoardScreen(client: client, cache: cache, namespace: namespace, listing: listing)
            }
            .sheet(isPresented: $showCreate) {
                TaskBoardCreateView { draft in
                    let listing = try await model.create(draft)
                    Haptics.success()
                    app.router.push(.taskBoard(slug: listing.slug, project: listing.project, title: listing.title))
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            VStack {
                HVListSkeleton(rows: 4).padding(.top, HV.Space.m)
                Spacer()
            }
        case .failed(let message):
            HVErrorState(message: message) { Task { await model.load() } }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            if model.boards.isEmpty {
                HVEmptyState(
                    symbol: "checklist",
                    title: "No boards yet.",
                    message: "A board is a list you share with your agents. They tick things off; you steer.",
                    actionTitle: "Start a board"
                ) { showCreate = true }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
        }
    }

    private var list: some View {
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
                ForEach(model.boards) { board in
                    NavigationLink(value: board) {
                        TaskBoardRowView(board: board, summary: model.summaries[board.project])
                    }
                    .accessibilityIdentifier("taskboards.row.\(board.project)")
                    .hvListRow()
                    .task { await model.loadSummary(for: board) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .refreshable { await model.refresh() }
    }
}

/// A board in the list: its name and how far along it is.
struct TaskBoardRowView: View {
    let board: TaskBoardListing
    let summary: TaskBoardSummary?

    var body: some View {
        HStack(spacing: HV.Space.s) {
            HVIconBadge(symbol: "checklist", tint: Palette.mint, size: 36)
            VStack(alignment: .leading, spacing: 6) {
                Text(board.displayTitle)
                    .font(.hvBody)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(2)
                if let summary {
                    TaskProgressBar(done: summary.done, total: summary.countable)
                    Text(line(for: summary))
                        .font(.hvCaption)
                        .foregroundStyle(Palette.textSecondary)
                } else {
                    HVSkeleton(height: 8, width: 140)
                }
            }
        }
        .padding(.vertical, HV.Space.xxs)
        .accessibilityElement(children: .combine)
    }

    private func line(for summary: TaskBoardSummary) -> String {
        if summary.total == 0 { return "Nothing on it yet" }
        var parts = ["\(summary.done) of \(summary.countable) done"]
        let active = summary.count(.inProgress)
        if active > 0 { parts.append("\(active) in progress") }
        let blocked = summary.count(.blocked)
        if blocked > 0 { parts.append("\(blocked) blocked") }
        return parts.joined(separator: " · ")
    }
}

/// A thin bar that fills as work is done.
struct TaskProgressBar: View {
    let done: Int
    let total: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.surfaceRaised)
                Capsule()
                    .fill(Palette.mint)
                    .frame(width: max(fraction > 0 ? 8 : 0, proxy.size.width * fraction))
                    .animation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.8), value: fraction)
            }
        }
        .frame(height: 8)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue("\(done) of \(total) done")
    }
}

/// Start a board: a name, and if you like a first plan, one task per line.
struct TaskBoardCreateView: View {
    @Environment(\.dismiss) private var dismiss
    let onCreate: (TaskBoardDraft) async throws -> Void

    @State private var draft = TaskBoardDraft()
    @State private var isCreating = false
    @State private var errorMessage: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: HV.Space.m) {
                    Text("A board is a list you share with your agents. They claim tasks and tick them off; you can do the same.")
                        .font(.hvCallout)
                        .foregroundStyle(Palette.textSecondary)
                    // The footnote says why the button below is off until there is a name.
                    HVLabeledField(title: "Name", footnote: draft.canCreate ? nil : "Give it a name to start.") {
                        TextField("What is it for?", text: $draft.title, prompt: Text.hvPrompt("What is it for?"))
                            .accessibilityIdentifier("taskboards.new.title")
                            .focused($focused)
                            .submitLabel(.next)
                    }
                    HVLabeledField(title: "A first plan (optional)", footnote: "One task per line. Your agents see them too.") {
                        TextField("Order the front panels", text: $draft.plan, prompt: Text.hvPrompt("Order the front panels"), axis: .vertical)
                            .accessibilityIdentifier("taskboards.new.plan")
                            .lineLimit(5...12)
                    }
                    if let errorMessage {
                        Text(errorMessage).font(.hvFootnote).foregroundStyle(Palette.danger)
                    }
                    Button {
                        create()
                    } label: {
                        if isCreating { ProgressView().tint(.white) } else { Text("Create board") }
                    }
                    .buttonStyle(.hvPrimary)
                    .disabled(!draft.canCreate || isCreating)
                }
                .padding(HV.Space.m)
                .hvReadableWidth()
            }
            .scrollDismissesKeyboard(.interactively)
            .hvScreenBackground()
            .navigationTitle("New board")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isCreating)
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(isCreating)
    }

    private func create() {
        guard draft.canCreate, !isCreating else { return }
        isCreating = true
        errorMessage = nil
        Task {
            do {
                try await onCreate(draft)
                dismiss()
            } catch {
                errorMessage = (error as? HVError)?.userMessage ?? error.localizedDescription
                Haptics.failure()
                isCreating = false
            }
        }
    }
}

#if DEBUG
#Preview("Boards") {
    PreviewHost(routes: TaskBoardPreviewData.indexRoutes) { TaskBoardsRootView() }
}

#Preview("No boards") {
    PreviewHost(routes: [.json(.get, "/api/taskboards", #"{"boards":[]}"#)]) { TaskBoardsRootView() }
}
#endif
