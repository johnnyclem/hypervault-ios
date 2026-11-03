import HyperVaultKit
import SwiftUI

/// A project, as `Route.project(id:)` shows it: the board in brief, who is working on it, and what else goes with it.
struct ProjectOverviewView: View {
    @Environment(AppEnvironment.self) private var env
    let project: String
    /// Opens with the guesses showing, for a snapshot of them.
    var showPossibly = false

    var body: some View {
        ProjectOverviewScreen(env: env, project: project, showPossibly: showPossibly)
    }
}

struct ProjectOverviewScreen: View {
    @State private var model: ProjectOverviewModel
    /// "Show possibly related" is open: the pages and memories the server only guessed at.
    @State private var showPossibly: Bool
    /// The sections opened out past their first few rows ("Show 3 more").
    @State private var opened: Set<String> = []

    init(env: AppEnvironment, project: String, showPossibly: Bool = false) {
        _model = State(initialValue: ProjectOverviewModel(env: env, project: project))
        _showPossibly = State(initialValue: showPossibly)
    }

    var body: some View {
        List {
            if model.boardIsStale || model.relatedIsStale {
                Section {
                    HVStaleBanner()
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }
            }
            boardSections
            if !model.boardFailed { relatedSections }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .hvScreenBackground()
        .navigationTitle(model.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.start() }
        .onAppear { Task { await model.refreshIfStarted() } }
        .refreshable { await model.refresh() }
    }

    // MARK: The board

    @ViewBuilder private var boardSections: some View {
        switch model.board {
        case .loading:
            Section {
                HVListSkeleton(rows: 3)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        case .failed(let message):
            Section {
                HVErrorState(message: message) { Task { await model.retryBoard() } }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        case .loaded(let digest):
            boardSection(digest)
            if !digest.agents.isEmpty {
                Section {
                    ForEach(digest.agents) { agent in
                        HVRow(symbol: HVSymbol.agent, title: agent.name, subtitle: agent.tasks == 1 ? "1 open task" : "\(agent.tasks) open tasks")
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("project.agent.\(agent.id)")
                            .hvListRow()
                    }
                } header: {
                    HVSectionHeader(title: ProjectsCopy.agentsSection)
                }
            }
        }
    }

    private func boardSection(_ digest: ProjectBoardDigest) -> some View {
        Section {
            if digest.summary.total == 0 {
                Text(ProjectsCopy.boardEmpty)
                    .font(.hvCallout)
                    .foregroundStyle(Palette.textSecondary)
                    .hvListRow()
            } else {
                VStack(alignment: .leading, spacing: HV.Space.s) {
                    Text("\(digest.summary.progress)%")
                        .font(.system(.title, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Palette.textPrimary)
                    TaskProgressBar(done: digest.summary.done, total: digest.summary.countable)
                    Text(digest.statusLine)
                        .font(.hvSubheadline)
                        .foregroundStyle(Palette.textSecondary)
                }
                .padding(.vertical, HV.Space.xxs)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("project.progress")
                .hvListRow()
                ForEach(digest.focus) { task in
                    HStack(alignment: .top, spacing: HV.Space.s) {
                        Image(systemName: task.status.symbol)
                            .foregroundStyle(task.status.tint)
                            .frame(minWidth: 24, minHeight: 44)
                            .accessibilityHidden(true)
                        TaskRowBody(task: task, rollup: nil, parentTitle: nil)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(task.status.title)
                    .accessibilityIdentifier("project.task.\(task.id)")
                    .hvListRow()
                }
                if digest.focus.isEmpty {
                    Text(ProjectsCopy.boardAllDone)
                        .font(.hvCallout)
                        .foregroundStyle(Palette.textSecondary)
                        .hvListRow()
                }
            }
            NavigationLink(value: Route.taskBoard(slug: "tasks-\(model.project)", project: model.project, title: model.title)) {
                HVRow(symbol: "checklist", title: ProjectsCopy.openBoard)
            }
            .accessibilityIdentifier("project.openBoard")
            .hvListRow()
        } header: {
            HVSectionHeader(title: ProjectsCopy.boardSection)
        }
    }

    // MARK: What else goes with it

    @ViewBuilder private var relatedSections: some View {
        switch model.related {
        case .loading:
            Section {
                HVListSkeleton(rows: 3)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        case .failed(let message):
            Section {
                HVErrorState(message: message) { Task { await model.loadRelated() } }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        case .loaded(let related):
            if related.confirmedTotal == 0, model.unavailable.isEmpty {
                Section {
                    HVEmptyBox(message: ProjectsCopy.nothingRelated)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .accessibilityIdentifier("project.related.empty")
                }
            }
            relatedSection("pages", title: ProjectsCopy.pagesSection, items: related.pages, total: related.pageTotal, failed: model.unavailable.contains(.pages), library: .file)
            relatedSection("memories", title: ProjectsCopy.memoriesSection, items: related.memories, total: related.memoryTotal, failed: model.unavailable.contains(.memories), library: .memory)
            relatedSection("chats", title: ProjectsCopy.chatsSection, items: related.chats, total: related.chatTotal, failed: model.unavailable.contains(.chats), library: nil)
            possiblySections(related)
            footer(related)
        }
    }

    /// One section: its first rows, "Show 3 more" for the rest it kept, and, for what it did not keep at all, the Library.
    @ViewBuilder
    private func relatedSection(
        _ key: String, title: String, items: [ProjectRelatedItem], total: Int, failed: Bool, library: YoursFilter?
    ) -> some View {
        if failed {
            Section {
                HVErrorState(message: ProjectsCopy.couldntReadSection) { Task { await model.loadRelated() } }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } header: {
                HVSectionHeader(title: title)
            }
        } else if !items.isEmpty {
            let rows = ProjectRelated.shown(items, opened: opened.contains(key))
            Section {
                ForEach(rows) { item in
                    relatedRow(item)
                }
                if rows.count < items.count {
                    Button {
                        Haptics.select()
                        HV.Motion.animate { _ = opened.insert(key) }
                    } label: {
                        Text(ProjectsCopy.showMore(items.count - rows.count))
                            .font(.hvCallout)
                            .foregroundStyle(Palette.textPrimary)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("project.more.\(key)")
                    .hvListRow()
                }
                if total > items.count, let library {
                    NavigationLink(value: Route.libraryFiltered(filter: library, query: model.title)) {
                        Text(ProjectsCopy.seeAll(total - items.count))
                            .font(.hvCallout)
                            .foregroundStyle(Palette.textPrimary)
                    }
                    .accessibilityIdentifier("project.library.\(key)")
                    .hvListRow()
                }
            } header: {
                HVSectionHeader(title: title, detail: "\(total)")
            }
        }
    }

    private func relatedRow(_ item: ProjectRelatedItem) -> some View {
        NavigationLink(value: route(for: item)) {
            HVRow(symbol: symbol(for: item), title: item.title, subtitle: subtitle(for: item))
        }
        .accessibilityIdentifier("project.related.\(item.id)")
        .hvListRow()
    }

    /// Why the row is here, then what it is: "Linked · HTML page".
    private func subtitle(for item: ProjectRelatedItem) -> String {
        item.detail.isEmpty ? item.relation.label : "\(item.relation.label) \u{00B7} \(item.detail)"
    }

    private func route(for item: ProjectRelatedItem) -> Route {
        switch item.kind {
        case .page: return .artifact(slug: item.key)
        case .memory: return .memory(id: item.key)
        case .chat: return .conversation(id: item.key)
        }
    }

    private func symbol(for item: ProjectRelatedItem) -> String {
        switch item.kind {
        case .page: return "doc.text"
        case .memory: return HVSymbol.memory
        case .chat: return HVSymbol.chat
        }
    }

    // MARK: The server's guesses

    /// Pages and memories the server joined to the board page from shared tags and words. They may not belong, so they wait
    /// behind a row, and say what they are when it is open.
    @ViewBuilder
    private func possiblySections(_ related: ProjectRelated) -> some View {
        if related.possiblyTotal > 0 {
            Section {
                Button {
                    Haptics.select()
                    HV.Motion.animate { showPossibly.toggle() }
                } label: {
                    HStack(spacing: HV.Space.xs) {
                        Text(showPossibly ? ProjectsCopy.hidePossiblyRelated : ProjectsCopy.showPossiblyRelated)
                            .font(.hvBody)
                            .foregroundStyle(Palette.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(related.possiblyTotal)")
                            .font(.hvCaption.monospacedDigit())
                            .foregroundStyle(Palette.textTertiary)
                        HVIcon(HVSymbol.fold)
                            .font(.system(.caption2, weight: .bold))
                            .rotationEffect(.degrees(showPossibly ? 180 : 0))
                            .foregroundStyle(Palette.textSecondary)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(showPossibly ? ProjectsCopy.hidePossiblyRelated : ProjectsCopy.showPossiblyRelated), \(related.possiblyTotal)")
                .accessibilityHint(showPossibly ? "Hides them" : "Shows them")
                .accessibilityIdentifier("project.possibly")
                .hvListRow()
            }
            if showPossibly {
                Section {
                    ForEach(related.possibly) { item in
                        relatedRow(item)
                    }
                } header: {
                    HVSectionHeader(title: ProjectsCopy.possiblySection, detail: "\(related.possiblyTotal)")
                } footer: {
                    Text(ProjectsCopy.possiblyFooter)
                }
            }
        }
    }

    // MARK: Footer

    @ViewBuilder
    private func footer(_ related: ProjectRelated) -> some View {
        let linksMissing = model.unavailable.contains(.links)
        if related.confirmedTotal > 0 || linksMissing {
            Section {
                VStack(alignment: .leading, spacing: HV.Space.xs) {
                    if related.confirmedTotal > 0 { Text(ProjectsCopy.relatedFooter) }
                    if linksMissing { Text(ProjectsCopy.linksUnavailable) }
                }
                .font(.hvFootnote)
                .foregroundStyle(Palette.textSecondary)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
    }
}

#if DEBUG
#Preview("Project") {
    PreviewHost(routes: ProjectPreviewData.overviewRoutes) { ProjectOverviewView(project: "eurorack-choir") }
}

#Preview("Project, only the board") {
    PreviewHost(routes: ProjectPreviewData.emptyRoutes) { ProjectOverviewView(project: "eurorack-choir") }
}
#endif
