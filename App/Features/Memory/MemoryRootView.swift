import HyperVaultKit
import SwiftUI

/// The three ways into memory.
enum MemoryMode: String, CaseIterable, Identifiable {
    case search, ask, graph

    var id: String { rawValue }

    var title: String {
        switch self {
        case .search: return "Search"
        case .ask: return "Ask"
        case .graph: return "Graph"
        }
    }
}

/// Where the toolbar's menus lead inside the Memory tab.
enum MemoryDestination: Hashable {
    case branches, commits, compare, timeTravel, exportPrompt
}

/// The Memory tab: everything the person has kept to be remembered, found by
/// searching, by asking, or by looking at how it connects. The branch of the
/// mind being read is in the toolbar; every call carries it.
struct MemoryRootView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        MemoryTabScreen(env: env)
    }
}

/// The tab's screen. `MemoryRootView` is what the shell shows; previews and
/// snapshot tests build this directly to start in a given mode.
struct MemoryTabScreen: View {
    @Environment(AppModel.self) private var app
    @State private var list: MemoryListModel
    @State private var mode: MemoryMode
    @State private var query: String
    @State private var destination: MemoryDestination?
    @State private var showMemorize = false

    init(env: AppEnvironment, mode: MemoryMode = .search, query: String = "") {
        _list = State(initialValue: MemoryListModel(env: env))
        _mode = State(initialValue: mode)
        _query = State(initialValue: query)
    }

    var body: some View {
        VStack(spacing: 0) {
            // At the largest text sizes a segmented control stays small, so the choice becomes a menu.
            HVChoicePicker(title: "View", selection: $mode) {
                ForEach(MemoryMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .accessibilityIdentifier("memory.mode")
            .padding(.horizontal, HV.Space.m)
            .padding(.vertical, HV.Space.xs)
            .hvReadableWidth()

            switch mode {
            case .search:
                MemorySearchView(list: list, query: $query, onMemorize: { showMemorize = true })
            case .ask:
                MemoryAskView(list: list)
            case .graph:
                MemoryGraphScreen(list: list)
            }
        }
        .hvScreenBackground()
        .navigationTitle("Memory")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { branchMenu }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    showMemorize = true
                } label: {
                    Image(systemName: HVSymbol.add)
                }
                .accessibilityLabel("Memorize something")
                .accessibilityIdentifier("memory.memorize")
                moreMenu
            }
        }
        .navigationDestination(item: $destination) { destination in
            destinationView(destination)
        }
        .sheet(isPresented: $showMemorize) {
            MemorizeSheet(list: list)
        }
        .task(id: list.branch) { await list.load() }
        .task { await list.loadBranches() }
        .task { if !query.isEmpty { list.queryChanged(query) } }
        .onChange(of: query) { _, text in list.queryChanged(text) }
        // A link to the web's /vault/memory names a view and a branch (?mode=, ?branch=). They wait on the router until this
        // screen sees them, which may be as it is first built.
        .onChange(of: app.router.memoryMode, initial: true) { _, wanted in
            guard let wanted else { return }
            app.router.memoryMode = nil
            mode = wanted
        }
        .onChange(of: app.router.memoryBranch, initial: true) { _, wanted in
            guard let wanted else { return }
            app.router.memoryBranch = nil
            Task { await list.switchBranch(named: wanted) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .hvMemoryChanged)) { _ in
            Task { await list.refresh(app: nil) }
        }
    }

    // MARK: Toolbar

    private var branchMenu: some View {
        Menu {
            Picker("Branch", selection: Binding(get: { list.branch }, set: { name in
                Haptics.select()
                list.switchBranch(to: name)
            })) {
                ForEach(branchNames, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            Divider()
            Button {
                destination = .branches
            } label: {
                Label("Manage branches", systemImage: "arrow.triangle.branch")
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch")
                Text(list.branch)
                    .lineLimit(1)
            }
            .font(.system(.subheadline, weight: .semibold))
        }
        .accessibilityLabel("Branch: \(list.branch)")
        .accessibilityHint("Switch the branch of your memory you are reading")
    }

    private var branchNames: [String] {
        var names = list.branches.map(\.name)
        if !names.contains(list.branch) { names.append(list.branch) }
        if !names.contains(MindBranchName.defaultName) { names.insert(MindBranchName.defaultName, at: 0) }
        return names
    }

    private var moreMenu: some View {
        Menu {
            Section("Git for a mind") {
                Button { destination = .commits } label: { Label("History", systemImage: "clock.arrow.circlepath") }
                Button { destination = .compare } label: { Label("Compare", systemImage: "arrow.left.arrow.right") }
                Button { destination = .timeTravel } label: { Label("Time travel", systemImage: "calendar.badge.clock") }
                Button { destination = .branches } label: { Label("Branches", systemImage: "arrow.triangle.branch") }
            }
            Section(AccountMenu.beta) {
                Button { app.router.push(.dreams) } label: { Label(AccountMenu.dreams, systemImage: "moon.stars") }
                Button { app.router.push(.truth) } label: { Label(AccountMenu.truth, systemImage: "checkmark.seal") }
            }
            Section {
                Button { app.router.push(.digest) } label: { Label("Digest", systemImage: "scissors") }
                Button { destination = .exportPrompt } label: { Label("Bring memories from another AI", systemImage: HVSymbol.importData) }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("More")
        .accessibilityIdentifier("memory.more")
    }

    @ViewBuilder
    private func destinationView(_ destination: MemoryDestination) -> some View {
        switch destination {
        case .branches: MindBranchesView(list: list)
        case .commits: MindCommitLogView(list: list)
        case .compare: MindCompareView(list: list)
        case .timeTravel: MindTimeTravelView(list: list)
        case .exportPrompt: MemoryExportPromptView()
        }
    }
}
