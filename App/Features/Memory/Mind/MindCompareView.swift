import HyperVaultKit
import SwiftUI

/// Compare two points in the mind: two branches, two commits, or two moments.
/// What was added, edited (line by line) and forgotten, and which links moved.
struct MindCompareView: View {
    let list: MemoryListModel

    @Environment(AppModel.self) private var app
    @State private var model: MindCompareModel

    init(list: MemoryListModel, from: MindRef? = nil, to: MindRef? = nil) {
        self.list = list
        let current = list.branch
        // By default: what this branch has that main does not, or, on main, what changed this week.
        let defaultFrom: MindRef = current == MindBranchName.defaultName
            ? .moment(Date().addingTimeInterval(-7 * 86_400))
            : .branch(MindBranchName.defaultName)
        _model = State(initialValue: MindCompareModel(
            env: list.env, branch: current,
            from: from ?? defaultFrom,
            to: to ?? .branch(current)
        ))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HV.Space.l) {
                VStack(spacing: HV.Space.s) {
                    MindRefPicker(title: "From", ref: $model.from, branches: list.branches.map(\.name), commits: model.commits)
                    Button {
                        Haptics.select()
                        model.swap()
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Palette.textSecondary)
                            .frame(width: 44, height: 28)
                    }
                    .accessibilityLabel("Swap the two points")
                    MindRefPicker(title: "To", ref: $model.to, branches: list.branches.map(\.name), commits: model.commits)
                }

                Button {
                    Task { await model.compare() }
                } label: {
                    if model.phase == .loading { ProgressView().tint(.white) } else { Text("Compare") }
                }
                .buttonStyle(.hvPrimary)
                .disabled(model.phase == .loading)

                result
            }
            .padding(HV.Space.m)
            .padding(.bottom, HV.Space.xl)
            .hvReadableWidth()
        }
        .hvScreenBackground()
        .navigationTitle("Compare")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.loadCommits() }
        .task { await model.compare() }
    }

    @ViewBuilder
    private var result: some View {
        switch model.phase {
        case .idle, .loading:
            EmptyView()
        case .failed(let message):
            Text(message)
                .font(.hvFootnote)
                .foregroundStyle(Palette.danger)
        case .loaded(let diff):
            VStack(alignment: .leading, spacing: HV.Space.m) {
                if !diff.isEmpty {
                    Text(diff.summary)
                        .font(.hvHeadline)
                        .foregroundStyle(Palette.textPrimary)
                }
                MindStateDiffView(diff: diff, onRestore: { memory in bringBack(memory) }, restoringID: model.restoringID)
            }
        }
    }

    private func bringBack(_ memory: MindDiffMemory) {
        Task {
            do {
                let message = try await model.bringBack(memory)
                Haptics.success()
                app.toasts.success(message)
            } catch {
                app.toasts.show(error: error)
            }
        }
    }
}

/// Choose a branch, a commit or a moment.
struct MindRefPicker: View {
    let title: String
    @Binding var ref: MindRef
    let branches: [String]
    let commits: [MindCommit]

    var body: some View {
        VStack(alignment: .leading, spacing: HV.Space.xs) {
            HStack {
                Text(title)
                    .font(.hvSubheadline)
                    .foregroundStyle(Palette.textSecondary)
                    .frame(width: 44, alignment: .leading)
                Menu {
                    if !branches.isEmpty {
                        Section("Branches") {
                            ForEach(branches, id: \.self) { name in
                                Button { ref = .branch(name) } label: { Label(name, systemImage: "arrow.triangle.branch") }
                            }
                        }
                    }
                    if !commits.isEmpty {
                        Section("Recent commits") {
                            ForEach(commits.prefix(12)) { commit in
                                Button { ref = .commit(commit.id) } label: { Text("\(commit.message) (\(commit.shortId))") }
                            }
                        }
                    }
                    Section {
                        Button { ref = .moment(Date().addingTimeInterval(-7 * 86_400)) } label: { Label("A moment in time", systemImage: "calendar") }
                    }
                } label: {
                    HStack(spacing: HV.Space.xs) {
                        Image(systemName: symbol)
                            .foregroundStyle(Palette.textSecondary)
                        Text(label)
                            .font(.hvBody)
                            .foregroundStyle(Palette.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Palette.textTertiary)
                    }
                    .hvFieldChrome()
                }
                .accessibilityLabel("\(title): \(label)")
            }
            if case .moment(let date) = ref {
                DatePicker(
                    "\(title) moment",
                    selection: Binding(get: { date }, set: { ref = .moment($0) }),
                    in: ...Date(),
                    displayedComponents: [.date, .hourAndMinute]
                )
                .labelsHidden()
                .padding(.leading, 44)
            }
        }
    }

    private var symbol: String {
        switch ref {
        case .branch: return "arrow.triangle.branch"
        case .commit: return "circlebadge"
        case .moment: return "calendar"
        }
    }

    private var label: String { ref.fieldText(commits: commits) }
}
