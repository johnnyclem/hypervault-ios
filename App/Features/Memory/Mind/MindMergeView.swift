import HyperVaultKit
import SwiftUI

/// Merge understanding: fold a branch into main. What only one side changed
/// merges by itself; what both changed is put to you, side by side, to keep
/// one, take the other, or write a version of your own.
struct MindMergeView: View {
    let list: MemoryListModel

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var model: MindMergeModel
    @State private var editing: MindMergeConflict?

    init(source: String, list: MemoryListModel, conflicts: [MindMergeConflict] = []) {
        self.list = list
        _model = State(initialValue: MindMergeModel(source: source, env: list.env, conflicts: conflicts))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HV.Space.l) {
                header
                content
            }
            .padding(HV.Space.m)
            .padding(.bottom, HV.Space.xl)
            .hvReadableWidth()
        }
        .hvScreenBackground()
        .navigationTitle("Merge")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.loadPreview() }
        .sheet(item: $editing) { conflict in
            MindCustomResolutionSheet(conflict: conflict) { title, content, tags in
                model.resolve(conflict.memoryId, .custom(title: title, content: content, tags: tags))
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: HV.Space.xs) {
            HStack(spacing: HV.Space.xs) {
                MindBranchPill(name: model.source)
                Image(systemName: "arrow.right")
                    .foregroundStyle(Palette.textTertiary)
                    .accessibilityLabel("into")
                MindBranchPill(name: model.target)
            }
            Text("Memories only one branch touched merge on their own. Links merge as sets and never conflict.")
                .font(.hvCallout)
                .foregroundStyle(Palette.textSecondary)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .previewing:
            HVLoadingState(message: "Reading what it would bring\u{2026}")
        case .failed(let message):
            HVErrorState(message: message) { Task { await model.loadPreview() } }
        case .ready(let diff):
            ready(diff)
        case .merging:
            HVLoadingState(message: "Merging\u{2026}")
        case .resolving:
            resolving
        case .merged(let result):
            merged(result)
        }
    }

    // MARK: Ready

    private func ready(_ diff: MindStateDiff) -> some View {
        VStack(alignment: .leading, spacing: HV.Space.l) {
            if diff.isEmpty {
                HVEmptyState(symbol: "checkmark.circle", title: "Already up to date", message: "\(model.target) has everything that is on \(model.source).")
            } else {
                Text("This would bring \(diff.summary).")
                    .font(.hvHeadline)
                    .foregroundStyle(Palette.textPrimary)
                MindStateDiffView(diff: diff)
            }
            if let notice = model.notice {
                Text(notice)
                    .font(.hvFootnote)
                    .foregroundStyle(Palette.danger)
            }
            Button {
                Task { await model.merge() }
            } label: {
                Text("Merge into \(model.target)")
            }
            .buttonStyle(.hvPrimary)
        }
    }

    // MARK: Conflicts

    private var resolving: some View {
        let session = model.session
        return VStack(alignment: .leading, spacing: HV.Space.l) {
            VStack(alignment: .leading, spacing: HV.Space.xs) {
                Text(session.conflicts.count == 1 ? "One memory needs your choice" : "\(session.conflicts.count) memories need your choice")
                    .font(.hvTitle3)
                    .foregroundStyle(Palette.textPrimary)
                if let notice = model.notice {
                    Text(notice)
                        .font(.hvFootnote)
                        .foregroundStyle(Palette.textSecondary)
                }
                ProgressView(value: Double(session.resolvedCount), total: Double(max(session.conflicts.count, 1)))
                    .tint(Palette.mint)
                Text("\(session.resolvedCount) of \(session.conflicts.count) settled")
                    .font(.hvCaption)
                    .foregroundStyle(Palette.textTertiary)
            }

            if session.conflicts.count > 1 {
                HStack(spacing: HV.Space.xs) {
                    Button("Keep \(model.target) for the rest") { model.resolveRemaining(.ours) }
                    Button("Take \(model.source) for the rest") { model.resolveRemaining(.theirs) }
                }
                .buttonStyle(.hvGhost)
                .font(.hvFootnote)
            }

            ForEach(session.conflicts) { conflict in
                MindConflictCard(
                    conflict: conflict,
                    session: session,
                    onPick: { model.resolve(conflict.memoryId, $0) },
                    onClear: { model.unresolve(conflict.memoryId) },
                    onEdit: { editing = conflict }
                )
            }

            VStack(alignment: .leading, spacing: HV.Space.xs) {
                HVSectionHeader(title: "Commit message")
                TextField("merge \(model.source) into \(model.target)", text: Binding(get: { session.message }, set: { model.setMessage($0) }))
                    .hvFieldChrome()
            }

            Button {
                Task { await model.merge() }
            } label: {
                Text(session.canMerge ? "Merge with \(session.resolvedCount) \(session.resolvedCount == 1 ? "choice" : "choices")" : "\(session.unresolved.count) left to settle")
            }
            .buttonStyle(.hvPrimary)
            .disabled(!session.canMerge)
        }
    }

    // MARK: Done

    private func merged(_ result: MindMergeResult) -> some View {
        VStack(spacing: HV.Space.l) {
            HVEmptyState(
                symbol: result.isNoOp ? "checkmark.circle" : "arrow.triangle.merge",
                title: result.isNoOp ? "Nothing to merge" : "Merged into \(model.target)",
                message: result.message
            )
            Button {
                list.switchBranch(to: model.target)
                dismiss()
            } label: {
                Text("Read \(model.target)")
            }
            .buttonStyle(.hvPrimary)
            Button("Done") { dismiss() }
                .buttonStyle(.hvGhost)
        }
        .onAppear {
            if !result.isNoOp { Haptics.success() }
            Task { await list.reloadBranches() }
        }
    }
}

struct MindBranchPill: View {
    let name: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 11, weight: .semibold))
            Text(name)
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
        }
        .foregroundStyle(Palette.textPrimary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Palette.surfaceRaised, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.border, lineWidth: 1))
    }
}

/// One memory both branches changed: the two versions beside what they started from.
private struct MindConflictCard: View {
    let conflict: MindMergeConflict
    let session: MindMergeSession
    let onPick: (MindResolution) -> Void
    let onClear: () -> Void
    let onEdit: () -> Void

    @State private var showDiffs = false

    var body: some View {
        let resolution = session.resolution(for: conflict.memoryId)
        VStack(alignment: .leading, spacing: HV.Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: HV.Space.xs) {
                Text(conflict.title)
                    .font(.hvHeadline)
                    .foregroundStyle(Palette.textPrimary)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: HV.Space.xs)
                if resolution != nil {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Palette.success)
                        .accessibilityLabel("Settled")
                }
            }
            Text(situation)
                .font(.hvFootnote)
                .foregroundStyle(Palette.textSecondary)

            side(.ours, label: session.target, snapshot: conflict.ours, selected: resolution == .ours)
            side(.theirs, label: session.source, snapshot: conflict.theirs, selected: resolution == .theirs)

            Button {
                onEdit()
            } label: {
                HStack {
                    Image(systemName: "square.and.pencil")
                    Text(isCustom(resolution) ? "Edit your version" : "Write my own")
                    Spacer()
                    if isCustom(resolution) { Image(systemName: "checkmark").foregroundStyle(Palette.success) }
                }
                .font(.hvSubheadline.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, HV.Space.s)
                .frame(minHeight: 44)
                .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: HV.Radius.s, style: .continuous))
            }
            .buttonStyle(.plain)

            if conflict.hunksOurs.hasTextChanges || conflict.hunksTheirs.hasTextChanges {
                Button(showDiffs ? "Hide the changes" : "Show what each side changed") {
                    withAnimation(.easeInOut(duration: 0.2)) { showDiffs.toggle() }
                }
                .buttonStyle(.hvGhost)
                if showDiffs {
                    VStack(alignment: .leading, spacing: HV.Space.xs) {
                        Text("\(session.target), against where they split")
                            .font(.hvCaption.weight(.semibold))
                            .foregroundStyle(Palette.textSecondary)
                        MindDiffView(diff: conflict.hunksOurs)
                        Text("\(session.source), against where they split")
                            .font(.hvCaption.weight(.semibold))
                            .foregroundStyle(Palette.textSecondary)
                            .padding(.top, HV.Space.xs)
                        MindDiffView(diff: conflict.hunksTheirs)
                    }
                }
            }
            if let resolution {
                HStack {
                    Text(session.describe(resolution, for: conflict))
                        .font(.hvCaption)
                        .foregroundStyle(Palette.textSecondary)
                    Spacer()
                    Button("Undo", action: onClear)
                        .buttonStyle(.hvGhost)
                }
            }
        }
        .hvCard()
        .accessibilityElement(children: .contain)
    }

    private var situation: String {
        switch conflict.situation {
        case .bothEdited: return "Both branches changed it."
        case .forgottenHere: return "\(session.target) forgot it, and \(session.source) changed it."
        case .forgottenThere: return "\(session.source) forgot it, and \(session.target) changed it."
        }
    }

    private func isCustom(_ resolution: MindResolution?) -> Bool {
        if case .custom = resolution { return true }
        return false
    }

    private func side(_ kind: MindSide, label: String, snapshot: MindSnapshot?, selected: Bool) -> some View {
        Button {
            Haptics.select()
            onPick(kind == .ours ? .ours : .theirs)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    MindBranchPill(name: label)
                    Spacer()
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(selected ? Color.accentColor : Palette.textTertiary)
                        .accessibilityHidden(true)
                }
                if let snapshot {
                    Text(snapshot.title)
                        .font(.hvSubheadline.weight(.semibold))
                        .foregroundStyle(Palette.textPrimary)
                        .multilineTextAlignment(.leading)
                    Text(snapshot.content)
                        .font(.hvFootnote)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(5)
                        .multilineTextAlignment(.leading)
                } else {
                    Text("Forgotten here")
                        .font(.hvSubheadline.italic())
                        .foregroundStyle(Palette.textSecondary)
                }
            }
            .padding(HV.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.accentColor.opacity(0.08) : Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: HV.Radius.s, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: HV.Radius.s, style: .continuous).strokeBorder(selected ? Color.accentColor.opacity(0.6) : Color.clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(kind == .ours ? "Keeps the version on \(session.target)" : "Takes the version from \(session.source)")
    }
}

/// Write the version that goes in: a title, the text, and tags. It starts from
/// both sides' lines, so nothing has to be typed from scratch.
private struct MindCustomResolutionSheet: View {
    let conflict: MindMergeConflict
    let onSave: (String, String, [String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var content: String
    @State private var tags: [String]

    init(conflict: MindMergeConflict, onSave: @escaping (String, String, [String]) -> Void) {
        self.conflict = conflict
        self.onSave = onSave
        _title = State(initialValue: conflict.ours?.title ?? conflict.theirs?.title ?? "")
        _content = State(initialValue: conflict.combinedContent)
        _tags = State(initialValue: conflict.combinedTags)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: HV.Space.m) {
                    Text("Both versions' lines are here to start from. Cut what you do not want.")
                        .font(.hvCallout)
                        .foregroundStyle(Palette.textSecondary)
                    TextField("Title", text: $title)
                        .font(.hvHeadline)
                        .hvFieldChrome()
                    TextEditor(text: $content)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 240)
                        .padding(HV.Space.xs)
                        .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: HV.Radius.m, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: HV.Radius.m, style: .continuous).strokeBorder(Palette.border, lineWidth: 1))
                    VStack(alignment: .leading, spacing: HV.Space.xs) {
                        HVSectionHeader(title: "Tags")
                        MemoryTagEditor(tags: $tags)
                    }
                }
                .padding(HV.Space.m)
                .hvReadableWidth()
            }
            .hvScreenBackground()
            .navigationTitle("Your version")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use this") {
                        onSave(title.trimmingCharacters(in: .whitespacesAndNewlines), content.trimmingCharacters(in: .whitespacesAndNewlines), tags)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.large])
    }
}
