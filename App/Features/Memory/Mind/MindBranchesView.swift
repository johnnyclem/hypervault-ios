import HyperVaultKit
import SwiftUI

/// Branch your ideas: switch between branches of the mind, fork a new one,
/// merge one into main, or drop it. Edits on a branch do not touch main until
/// they are merged.
struct MindBranchesView: View {
    let list: MemoryListModel

    @Environment(AppModel.self) private var app
    @State private var showNew = false
    @State private var mergeSource: MindBranch?
    @State private var compareSource: MindBranch?
    @State private var deleting: MindBranch?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HV.Space.m) {
                Text("A branch is a copy of your memory to think in. What you change there stays there until you merge it into main.")
                    .font(.hvCallout)
                    .foregroundStyle(Palette.textSecondary)

                if list.branches.isEmpty {
                    branchRow(MindBranch(id: list.branch, name: list.branch, isDefault: list.branch == MindBranchName.defaultName))
                } else {
                    ForEach(list.branches) { branch in
                        branchRow(branch)
                    }
                }

                Button {
                    showNew = true
                } label: {
                    Label("New branch from \(list.branch)", systemImage: "plus")
                }
                .buttonStyle(.hvPrimary)
                .padding(.top, HV.Space.xs)
            }
            .padding(HV.Space.m)
            .hvReadableWidth()
        }
        .hvScreenBackground()
        .navigationTitle("Branches")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await list.reloadBranches() }
        .task { await list.loadBranches() }
        .sheet(isPresented: $showNew) { NewBranchSheet(list: list) }
        .navigationDestination(item: $mergeSource) { branch in
            MindMergeView(source: branch.name, list: list)
        }
        .navigationDestination(item: $compareSource) { branch in
            MindCompareView(list: list, from: .branch(MindBranchName.defaultName), to: .branch(branch.name))
        }
        .confirmationDialog(
            "Delete this branch?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible,
            presenting: deleting
        ) { branch in
            Button("Delete \(branch.name)", role: .destructive) { delete(branch) }
        } message: { branch in
            Text("Its commits, memories and links on \(branch.name) go with it. Main is not touched.")
        }
    }

    private func branchRow(_ branch: MindBranch) -> some View {
        let isCurrent = branch.name == list.branch
        return HStack(spacing: HV.Space.s) {
            Button {
                Haptics.select()
                list.switchBranch(to: branch.name)
            } label: {
                HStack(spacing: HV.Space.s) {
                    HVIconBadge(symbol: branch.isDefault ? "house" : "arrow.triangle.branch", tint: isCurrent ? Palette.blue : Palette.textSecondary)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(branch.name)
                                .font(.hvHeadline)
                                .foregroundStyle(Palette.textPrimary)
                            if branch.isDefault { HVTag(text: "Default") }
                        }
                        Text("\(branch.memoryCount) \(branch.memoryCount == 1 ? "memory" : "memories")")
                            .font(.hvFootnote)
                            .foregroundStyle(Palette.textSecondary)
                    }
                    Spacer(minLength: HV.Space.xs)
                    if isCurrent {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.accentColor)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(isCurrent ? .isSelected : [])
            .accessibilityHint(isCurrent ? "You are reading this branch" : "Reads this branch")

            if !branch.isDefault {
                Menu {
                    Button { mergeSource = branch } label: { Label("Merge into main", systemImage: "arrow.triangle.merge") }
                    Button { compareSource = branch } label: { Label("Compare with main", systemImage: "arrow.left.arrow.right") }
                    Divider()
                    Button(role: .destructive) { deleting = branch } label: { Label("Delete branch", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 20))
                        .foregroundStyle(Palette.textSecondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Actions for \(branch.name)")
            }
        }
        .hvCard()
        .contextMenu {
            if !branch.isDefault {
                Button { mergeSource = branch } label: { Label("Merge into main", systemImage: "arrow.triangle.merge") }
                Button(role: .destructive) { deleting = branch } label: { Label("Delete branch", systemImage: "trash") }
            }
        }
    }

    private func delete(_ branch: MindBranch) {
        deleting = nil
        Task {
            do {
                let message = try await list.deleteBranch(branch)
                Haptics.success()
                app.toasts.success(message)
            } catch {
                app.toasts.show(error: error)
            }
        }
    }
}

/// Name a new branch. It forks from the branch being read.
struct NewBranchSheet: View {
    let list: MemoryListModel

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var isWorking = false
    @State private var problem: String?
    @FocusState private var focused: Bool

    private var normalized: String { MindBranchName.normalized(name) }
    private var existing: [String] { list.branches.map(\.name) }
    private var hint: String? { normalized.isEmpty ? nil : MindBranchName.validationMessage(for: normalized, existing: existing) }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: HV.Space.m) {
                Text("Forks from \(list.branch). Edits there will not touch \(list.branch) until you merge them.")
                    .font(.hvCallout)
                    .foregroundStyle(Palette.textSecondary)
                TextField("ideas", text: $name)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused($focused)
                    .onSubmit(create)
                    .hvFieldChrome(isFocused: focused)
                if let message = problem ?? hint {
                    Text(message)
                        .font(.hvFootnote)
                        .foregroundStyle(Palette.danger)
                } else if !normalized.isEmpty, normalized != name {
                    Text("Will be called \u{201C}\(normalized)\u{201D}")
                        .font(.hvFootnote)
                        .foregroundStyle(Palette.textSecondary)
                }
                Spacer()
                Button(action: create) {
                    if isWorking { ProgressView().tint(.white) } else { Text("Create branch") }
                }
                .buttonStyle(.hvPrimary)
                .disabled(normalized.isEmpty || hint != nil || isWorking)
            }
            .padding(HV.Space.m)
            .hvScreenBackground()
            .navigationTitle("New branch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium])
    }

    private func create() {
        guard !normalized.isEmpty, hint == nil, !isWorking else { return }
        isWorking = true
        problem = nil
        let target = normalized
        Task {
            do {
                let created = try await list.createBranch(named: target, from: list.branch)
                isWorking = false
                Haptics.success()
                app.toasts.success(created.message.isEmpty ? "Branched \u{201C}\(created.name)\u{201D}." : created.message)
                list.switchBranch(to: created.name)
                dismiss()
            } catch {
                isWorking = false
                if !MemoryErrors.isCancelled(error) { problem = MemoryErrors.message(error) }
            }
        }
    }
}
