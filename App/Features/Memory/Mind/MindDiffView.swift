import HyperVaultKit
import SwiftUI

/// The lines that changed in one memory: additions in green, removals in red,
/// the lines around them quiet, and a fold where unchanged lines were left out.
struct MindDiffView: View {
    let diff: MindTextDiff
    /// Most rows drawn at once; a diff longer than this says how many it left out.
    var rowLimit = 400

    var body: some View {
        let rows = diff.rows
        VStack(alignment: .leading, spacing: 0) {
            if diff.oversize {
                note("Replaced. The text is too large to compare line by line.")
            } else if rows.isEmpty {
                note("No text changes. Only the title or the tags changed.")
            } else {
                ForEach(rows.prefix(rowLimit)) { row in
                    MindDiffRowView(row: row)
                }
                if rows.count > rowLimit {
                    note("\(rows.count - rowLimit) more lines not shown.")
                }
            }
        }
        .background(Palette.surfaceRaised.opacity(0.5), in: RoundedRectangle(cornerRadius: HV.Radius.s, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: HV.Radius.s, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: HV.Radius.s, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.hvFootnote)
            .foregroundStyle(Palette.textSecondary)
            .padding(HV.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MindDiffRowView: View {
    let row: MindDiffRow

    var body: some View {
        switch row.kind {
        case .gap:
            HStack(spacing: HV.Space.xs) {
                HVIcon("ellipsis")
                    .font(.system(size: 11, weight: .semibold))
                Text(gapText)
                    .font(.hvCaption)
            }
            .foregroundStyle(Palette.textTertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .background(Palette.surfaceRaised)
            .accessibilityLabel(gapText)
        case .add, .del, .ctx:
            HStack(alignment: .top, spacing: 6) {
                Text(row.oldLine.map { String($0) } ?? "")
                    .frame(width: 26, alignment: .trailing)
                Text(row.newLine.map { String($0) } ?? "")
                    .frame(width: 26, alignment: .trailing)
                Text(marker)
                    .fontWeight(.bold)
                    .frame(width: 12)
                Text(row.text.isEmpty ? " " : row.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(textColor)
            .padding(.vertical, 2)
            .padding(.horizontal, 6)
            .background(background)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
        }
    }

    private var gapText: String {
        let count = row.skipped ?? 0
        return count == 1 ? "1 unchanged line" : "\(count) unchanged lines"
    }

    private var marker: String {
        switch row.kind {
        case .add: return "+"
        case .del: return "\u{2212}"
        default: return ""
        }
    }

    // Text on a tint of its own color: inked darker in light mode. Removals use rose, which stays
    // above 4.5:1 on its tint in dark mode where the plain red does not.
    private var textColor: Color {
        switch row.kind {
        case .add: return Palette.success
        case .del: return Palette.rose
        default: return Palette.textSecondary
        }
    }

    private var background: Color {
        switch row.kind {
        case .add: return Palette.success.opacity(0.12)
        case .del: return Palette.rose.opacity(0.10)
        default: return .clear
        }
    }

    private var accessibilityText: String {
        switch row.kind {
        case .add: return "Added: \(row.text)"
        case .del: return "Removed: \(row.text)"
        default: return row.text
        }
    }
}

/// The plus-and-minus tally that heads a diff: "+3 −1".
struct MindDiffTally: View {
    let added: Int
    let removed: Int

    var body: some View {
        HStack(spacing: 6) {
            Text("+\(added)").foregroundStyle(Palette.success)
            Text("\u{2212}\(removed)").foregroundStyle(Palette.rose)
        }
        .font(.system(.caption, design: .monospaced, weight: .semibold))
        .accessibilityLabel("\(added) lines added, \(removed) removed")
    }
}

/// What changed in the whole mind between two points: memories added,
/// edited with their lines, forgotten, and links changed.
struct MindStateDiffView: View {
    let diff: MindStateDiff
    /// Offered for a memory that was forgotten: bring it back.
    var onRestore: ((MindDiffMemory) -> Void)?
    var restoringID: String?
    var words = Words.changes

    @State private var expanded: Set<String> = []
    /// The width `hvIconSlot(22)` gives the symbol of a row, so what hangs under a title can start where the title does.
    @ScaledMetric(relativeTo: .body) private var slot: CGFloat = 22

    /// What the three kinds of memory are called. A change between two points added, edited or forgot them; two
    /// branches set side by side only have some that the other has not.
    struct Words {
        var added: String
        var changed: String
        var removed: String
        var removedLink: String

        static let changes = Words(added: "Added", changed: "Edited", removed: "Forgotten", removedLink: "removed")

        static func branches(source: String, target: String) -> Words {
            Words(added: "Only on \(source)", changed: "Different on the two", removed: "Only on \(target)", removedLink: "only on \(target)")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HV.Space.l) {
            if diff.isEmpty {
                HVEmptyState(symbol: "equal.circle", title: "No difference", message: "Nothing changed between these two points.")
            }
            if !diff.added.isEmpty { addedSection }
            if !diff.changed.isEmpty { changedSection }
            if !diff.removed.isEmpty { removedSection }
            if !diff.linksAdded.isEmpty || !diff.linksRemoved.isEmpty { linksSection }
        }
    }

    private var addedSection: some View {
        VStack(alignment: .leading, spacing: HV.Space.xs) {
            HVSectionHeader(title: words.added, detail: "\(diff.added.count)")
            ForEach(diff.added) { memory in
                diffRow(symbol: "plus.circle.fill", tint: Palette.success, title: memory.title, trailing: nil)
            }
        }
    }

    private var removedSection: some View {
        VStack(alignment: .leading, spacing: HV.Space.xs) {
            HVSectionHeader(title: words.removed, detail: "\(diff.removed.count)")
            ForEach(diff.removed) { memory in
                diffRow(symbol: "minus.circle.fill", tint: Palette.rose, title: memory.title, trailing: restoreButton(for: memory))
            }
        }
    }

    private var changedSection: some View {
        VStack(alignment: .leading, spacing: HV.Space.xs) {
            HVSectionHeader(title: words.changed, detail: "\(diff.changed.count)")
            ForEach(diff.changed) { change in
                changeCard(change)
            }
        }
    }

    private var linksSection: some View {
        let titles = diff.titles
        return VStack(alignment: .leading, spacing: HV.Space.xs) {
            HVSectionHeader(title: "Links", detail: "\(diff.linksAdded.count + diff.linksRemoved.count)")
            ForEach(diff.linksAdded) { link in
                diffRow(symbol: "link", tint: Palette.success, title: linkTitle(link, titles), trailing: nil)
            }
            ForEach(diff.linksRemoved) { link in
                diffRow(symbol: "link.badge.plus", tint: Palette.rose, title: linkTitle(link, titles) + " (\(words.removedLink))", trailing: nil)
            }
        }
    }

    private func linkTitle(_ link: MindLinkRef, _ titles: [String: String]) -> String {
        "\(titles[link.aId] ?? shortID(link.aId)) \u{2194} \(titles[link.bId] ?? shortID(link.bId))"
    }

    private func shortID(_ id: String) -> String { String(id.prefix(6)) }

    private func diffRow(symbol: String, tint: Color, title: String, trailing: AnyView?) -> some View {
        HStack(spacing: HV.Space.s) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .hvIconSlot(22)
                .accessibilityHidden(true)
            Text(title)
                .font(.hvBody)
                .foregroundStyle(Palette.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let trailing { trailing }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }

    private func restoreButton(for memory: MindDiffMemory) -> AnyView? {
        guard let onRestore else { return nil }
        return AnyView(
            Button {
                onRestore(memory)
            } label: {
                if restoringID == memory.id {
                    ProgressView()
                } else {
                    Text("Bring back")
                }
            }
            .buttonStyle(.hvGhost)
            .disabled(restoringID != nil)
            .accessibilityLabel("Bring back \(memory.title)")
        )
    }

    private func changeCard(_ change: MindMemoryChange) -> some View {
        let isOpen = expanded.contains(change.id)
        return VStack(alignment: .leading, spacing: HV.Space.xs) {
            Button {
                HV.Motion.animate(.easeInOut(duration: 0.2)) {
                    if isOpen { expanded.remove(change.id) } else { expanded.insert(change.id) }
                }
            } label: {
                HStack(spacing: HV.Space.s) {
                    Image(systemName: "pencil.circle.fill")
                        .foregroundStyle(Palette.blue)
                        .hvIconSlot(22)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: HV.Space.xxs) {
                        Text(change.titleTo.isEmpty ? change.titleFrom : change.titleTo)
                            .font(.hvBody)
                            .foregroundStyle(Palette.textPrimary)
                            .multilineTextAlignment(.leading)
                        if change.renamed {
                            Text("Was \u{201C}\(change.titleFrom)\u{201D}")
                                .font(.hvCaption)
                                .foregroundStyle(Palette.textSecondary)
                        }
                    }
                    Spacer(minLength: HV.Space.xs)
                    if change.contentChanged {
                        MindDiffTally(added: change.diff.addedLines, removed: change.diff.removedLines)
                    }
                    HVIcon(HVSymbol.fold)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.textTertiary)
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(isOpen ? "Hides the changed lines" : "Shows the changed lines")

            if !change.tagsAdded.isEmpty || !change.tagsRemoved.isEmpty {
                MemoryFlowLayout(spacing: 6) {
                    ForEach(change.tagsAdded, id: \.self) { HVTag(text: "+ \($0)", tint: Palette.success) }
                    ForEach(change.tagsRemoved, id: \.self) { HVTag(text: "\u{2212} \($0)", tint: Palette.rose) }
                }
                .padding(.leading, slot + HV.Space.s)
            }
            if isOpen {
                MindDiffView(diff: change.diff)
                    .padding(.top, HV.Space.xxs)
            }
        }
        .padding(.vertical, 6)
    }
}
