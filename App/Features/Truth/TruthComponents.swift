import HyperVaultKit
import SwiftUI

// The small pieces of the Truth screens. Truth is precise and plain: standing is
// shown as an honest badge, in words, never as an alarm.

extension TruthStanding {
    var symbol: String {
        switch self {
        case .sound: return "checkmark.seal"
        case .clouded: return "cloud"
        case .unsupported: return "minus.circle"
        }
    }

    var tint: Color {
        switch self {
        case .sound: return Palette.mint
        case .clouded: return Palette.amber
        case .unsupported: return Palette.textSecondary
        }
    }
}

extension TruthStatusTone {
    var tint: Color {
        switch self {
        case .settled: return Palette.mint
        case .open: return Palette.blue
        case .attention: return Palette.amber
        case .history: return Palette.textSecondary
        }
    }
}

/// Tags side by side, wrapping onto the next line when the text is large.
struct TruthTagFlow: Layout {
    var spacing: CGFloat = HV.Space.xs
    /// The gap between lines, when it should differ from the gap between neighbours.
    var rowSpacing: CGFloat?

    private var lineGap: CGFloat { rowSpacing ?? spacing }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let limit = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > limit {
                x = 0
                y += rowHeight + lineGap
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + lineGap
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// The hint inside an empty field. The system's own is too faint to read; this is the quietest grey that
/// still passes, so it reads as a hint beside the typed text and not as a value.
func truthPrompt(_ text: String) -> Text {
    Text(text).foregroundStyle(Palette.textTertiary)
}

/// An action in a row of a list, beside others that read as buttons. On it is the accent; off it is a
/// readable grey, not the system's faded blue that looks like a caption.
struct TruthRowButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? AnyShapeStyle(TintShapeStyle()) : AnyShapeStyle(Palette.textSecondary))
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.55 : 1)
    }
}

extension ButtonStyle where Self == TruthRowButtonStyle {
    static var truthRow: TruthRowButtonStyle { TruthRowButtonStyle() }
}

/// The ledger's counts, each a number over its word. They wrap as units, so a number never ends a line
/// with its word on the next.
struct TruthSummaryStats: View {
    let summary: TruthSummary

    var body: some View {
        TruthTagFlow(spacing: HV.Space.l, rowSpacing: HV.Space.s) {
            ForEach(summary.stats) { stat in
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(stat.count)")
                        .font(.system(.title3, weight: .semibold))
                        .foregroundStyle(Palette.textPrimary)
                    Text(stat.label)
                        .font(.hvCaption)
                        .foregroundStyle(Palette.textSecondary)
                }
                .fixedSize()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary.sentence)
    }
}

/// "TB" or "UV".
struct TruthTypeTag: View {
    let type: TruthEntryType

    var body: some View {
        Text(type.tag)
            .font(.system(.caption2, design: .monospaced, weight: .bold))
            .foregroundStyle(type == .tb ? Color.white : Palette.textPrimary)
            .padding(.horizontal, HV.Space.xs)
            .padding(.vertical, HV.Space.xxs)
            // A signed truth is the one flat fill under white (5.17:1); an unverified claim is raised paper with an edge.
            .background(type == .tb ? Palette.action : Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(type == .tb ? Color.clear : Palette.border, lineWidth: 1))
            .accessibilityLabel(type.title)
    }
}

/// A status in words: Active, Open, Under appeal, Refuted.
struct TruthStatusBadge: View {
    let status: String?

    var body: some View {
        HVTag(text: TruthStatus.label(status), tint: TruthStatus.tone(status).tint)
    }
}

/// Standing, only when it is not simply sound.
struct TruthStandingBadge: View {
    let standing: TruthStanding?
    var showsSound = false

    var body: some View {
        if let standing, standing != .sound || showsSound {
            HStack(spacing: HV.Space.xxs) {
                HVIcon(standing.symbol).font(.system(size: 10, weight: .bold))
                Text(standing.title)
            }
            .font(.system(.caption2, weight: .semibold))
            .foregroundStyle(standing.tint)
            .padding(.horizontal, 8)
            .padding(.vertical, HV.Space.xxs)
            .background(standing.tint.opacity(HV.Tint.fill), in: Capsule())
            .accessibilityLabel("Standing: \(standing.title). \(standing.meaning)")
        }
    }
}

/// A claim's words, set a little more formally than the rest of the app.
struct TruthClaimText: View {
    let text: String
    var lines: Int? = 4
    var large = false

    var body: some View {
        Text(verbatim: text)
            .font(.system(large ? .title3 : .body, design: .serif, weight: .regular))
            .foregroundStyle(Palette.textPrimary)
            .lineLimit(lines)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A row of the ledger page.
struct TruthEntryRowView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let row: TruthEntryRow

    var body: some View {
        VStack(alignment: .leading, spacing: HV.Space.xs) {
            TruthTagFlow {
                TruthTypeTag(type: row.type)
                TruthStatusBadge(status: row.status)
                TruthStandingBadge(standing: row.standing)
                if row.isStale { HVTag(text: "Stale", tint: Palette.amber) }
                if row.corroborated { HVTag(text: "Agents agree", tint: Palette.violet) }
            }
            TruthClaimText(text: row.line.text, lines: 4)
            if let reason = row.reasonSentence {
                Text(reason)
                    .font(.hvFootnote)
                    .foregroundStyle(Palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let detail = detailLine {
                Text(detail)
                    .font(.hvCaption)
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
            }
            ForEach(row.contestedBy) { uv in
                HStack(alignment: .top, spacing: HV.Space.xs) {
                    Image(systemName: "arrow.turn.down.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.amber)
                        .accessibilityHidden(true)
                    Text("Contested by \(uv.author ?? "someone"): \(uv.text)")
                        .font(.hvFootnote)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 3)
                }
                .padding(.leading, HV.Space.xs)
            }
        }
        .padding(.vertical, HV.Space.xxs)
        .accessibilityElement(children: .combine)
    }

    private var detailLine: String? {
        var parts: [String] = []
        if row.type == .tb {
            if let signer = row.line.signedBy { parts.append("Signed by \(signer)") }
            if let answers = row.answerableBy, answers != row.line.signedBy { parts.append("answerable: \(answers)") }
        } else if let author = row.line.author {
            parts.append("By \(author)")
        }
        if let ts = row.line.ts { parts.append(ts.formatted(date: .abbreviated, time: .omitted)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// A piece of evidence: its kind and what it points at.
struct TruthEvidenceRow: View {
    let evidence: TruthEvidence

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: HV.Space.xs) {
            Text(evidence.kind)
                .font(.system(.caption, design: .monospaced, weight: .semibold))
                .foregroundStyle(evidence.isSettling ? Palette.textPrimary : Palette.textSecondary)
            VStack(alignment: .leading, spacing: HV.Space.xxs) {
                Text(verbatim: evidence.ref).font(.hvFootnote).foregroundStyle(Palette.textPrimary)
                if let detail = evidence.detail, !detail.isEmpty {
                    Text(verbatim: detail).font(.hvCaption).foregroundStyle(Palette.textSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Evidence for a decision or an assertion: a kind, what it points at, what it shows.
struct TruthEvidenceEditor: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Binding var rows: [TruthEvidenceDraft]
    var label = "Evidence"

    var body: some View {
        VStack(alignment: .leading, spacing: HV.Space.s) {
            Text(label).font(.hvFootnote.weight(.semibold)).foregroundStyle(Palette.textSecondary)
            ForEach($rows) { $row in
                VStack(alignment: .leading, spacing: HV.Space.xs) {
                    // At a large text size the kind and the reference each need the whole width.
                    if dynamicTypeSize.isAccessibilitySize {
                        kindMenu($row)
                        refField($row)
                    } else {
                        HStack(spacing: HV.Space.xs) {
                            kindMenu($row)
                            refField($row)
                        }
                    }
                    TextField("What it shows (optional)", text: $row.detail, prompt: truthPrompt("What it shows (optional)"))
                        .font(.hvFootnote)
                        .hvFieldChrome()
                }
            }
            Button {
                rows.append(TruthEvidenceDraft())
            } label: {
                Label("Add evidence", systemImage: HVSymbol.add)
            }
            .buttonStyle(.hvGhost)
        }
    }

    private func kindMenu(_ row: Binding<TruthEvidenceDraft>) -> some View {
        Menu {
            Picker("Kind", selection: row.kind) {
                ForEach(TruthEvidenceKind.allCases) { kind in
                    Text(kind.isSettling ? kind.title : "\(kind.title) (a question)").tag(kind)
                }
            }
        } label: {
            HStack(spacing: HV.Space.xxs) {
                Text(row.wrappedValue.kind.title).font(.system(.footnote, design: .monospaced, weight: .semibold))
                HVIcon("chevron.up.chevron.down").font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(Palette.textPrimary)
            .padding(.horizontal, HV.Space.s)
            .frame(minHeight: 44)
            .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: HV.Radius.m, style: .continuous))
        }
        .accessibilityLabel("Evidence kind: \(row.wrappedValue.kind.title)")
    }

    private func refField(_ row: Binding<TruthEvidenceDraft>) -> some View {
        TextField("What it points at", text: row.ref, prompt: truthPrompt("sha, path:line, test name"))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .hvFieldChrome()
    }
}

/// One row of a trace: indented under the entry it supports, the failing premise marked.
struct TruthTraceRowView: View {
    let row: TruthTraceRow

    var body: some View {
        let node = row.node
        HStack(alignment: .top, spacing: HV.Space.xs) {
            if row.depth > 0 {
                Rectangle()
                    .fill(node.failing == nil ? Palette.border : Palette.amber)
                    .frame(width: 2)
                    .padding(.leading, CGFloat(min(row.depth - 1, 4)) * HV.Space.m)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                TruthTagFlow {
                    Text(node.typeTag)
                        .font(.system(.caption2, design: .monospaced, weight: .bold))
                        .foregroundStyle(Palette.textPrimary)
                        .padding(.horizontal, HV.Space.xs).padding(.vertical, HV.Space.xxs)
                        .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    HVTag(text: node.statusLabel, tint: node.missing ? Palette.textSecondary : TruthStatus.tone(node.status).tint)
                    TruthStandingBadge(standing: node.standing)
                }
                if let phrase = node.failingPhrase {
                    Text("Fails here: this premise \(phrase).")
                        .font(.hvCaption.weight(.semibold))
                        .foregroundStyle(Palette.amber)
                }
                Text(verbatim: node.missing ? "\(TruthID.short(node.id)) is not in this ledger." : (node.text.isEmpty ? node.id : node.text))
                    .font(.system(.footnote, design: .serif))
                    .foregroundStyle(node.missing ? Palette.textSecondary : Palette.textPrimary)
                    .italic(node.missing)
                Text(provenance(node))
                    .font(.hvCaption)
                    .foregroundStyle(Palette.textTertiary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private func provenance(_ node: TruthTraceNode) -> String {
        var parts = [TruthID.short(node.id)]
        if let signer = node.signedBy { parts.append("signed by \(signer)") }
        if let answers = node.answerableBy { parts.append("answerable: \(answers)") }
        if node.kind == "wiki" { parts.append("cited, not pinned") }
        return parts.joined(separator: " · ")
    }
}

/// The trace of an entry: its premises, one row each, and what rests on it.
struct TruthTraceView: View {
    let derivation: TruthDerivation
    /// The entries resting on this one. The entry screen shows them in its own section, from the ripple, so
    /// it leaves them out here; they would be the same rows twice.
    var showsDependents = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(derivation.rows) { row in
                TruthTraceRowView(row: row)
                Divider().opacity(0.4)
            }
            if !TruthTrace.hasPremises(derivation.root) {
                Text("No pinned premises: an observed claim, not a derived one.")
                    .font(.hvCaption)
                    .foregroundStyle(Palette.textSecondary)
                    .padding(.top, HV.Space.xs)
            }
            if showsDependents, !derivation.dependents.isEmpty {
                Text("Rests on it")
                    .font(.system(.caption, weight: .semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(Palette.textSecondary)
                    .padding(.top, HV.Space.s)
                ForEach(derivation.dependents) { entry in
                    TruthBriefRow(entry: entry)
                    Divider().opacity(0.4)
                }
            }
        }
    }
}

/// An entry in brief: a dependent, a ripple entry, a successor.
struct TruthBriefRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let entry: TruthEntryBrief
    /// Claims by entry id, so a row can name the entry it was reached through and not show its id.
    var claims: [String: String] = [:]
    /// An entry the row is listed under: "rests on" it says nothing a heading has not already said.
    var listedUnder: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TruthTagFlow {
                TruthTypeTag(type: entry.type)
                TruthStatusBadge(status: entry.status)
                TruthStandingBadge(standing: entry.standing)
            }
            // The statement is the content, so at an accessibility size (where three lines hold a few words of it) it is
            // not cut, and a row that is measured short cannot squeeze it to one line.
            Text(verbatim: entry.text.isEmpty ? entry.id : entry.text)
                .font(.system(.footnote, design: .serif))
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 3)
                .fixedSize(horizontal: false, vertical: true)
            if let sentence = entry.reasonSentence {
                Text(sentence).font(.hvCaption).foregroundStyle(Palette.textSecondary)
            }
            if let via = entry.via, let depth = entry.depth, via != listedUnder {
                Text(viaPhrase(via: via, depth: depth))
                    .font(.hvCaption)
                    .foregroundStyle(Palette.textTertiary)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    /// "Rests on" the entry it was reached through, named by what it says when that is known.
    private func viaPhrase(via: String, depth: Int) -> String {
        let name = claims[via].map { TruthWords.quoted($0, limit: 48) } ?? TruthID.short(via)
        return (depth == 1 ? "Rests on " : "Reached through ") + name
    }
}
