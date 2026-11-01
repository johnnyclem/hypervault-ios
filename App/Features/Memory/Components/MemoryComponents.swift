import HyperVaultKit
import SwiftUI

// Small pieces the Memory screens share: how a source, a commit or a date
// looks, the tag chips, the text of a memory, and the card a memory is in a list.

extension Notification.Name {
    /// A memory was written, edited, forgotten or restored somewhere. Lists listen and reload.
    static let hvMemoryChanged = Notification.Name("hv.memory.changed")
}

/// Which branch of the mind the Memory screens read and write, remembered per person.
enum MemoryBranchStore {
    static func key(for userID: String) -> String { "hv.memory.branch.\(userID)" }

    static func current(for userID: String) -> String {
        UserDefaults.standard.string(forKey: key(for: userID)) ?? MindBranchName.defaultName
    }

    static func set(_ branch: String, for userID: String) {
        UserDefaults.standard.set(branch, forKey: key(for: userID))
    }
}

enum MemoryErrors {
    /// The server's own sentence, or what the system says when it was not the server.
    static func message(_ error: Error) -> String {
        if let hv = error as? HVError { return hv.userMessage }
        return error.localizedDescription
    }

    static func isCancelled(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let hv = error as? HVError, case .cancelled = hv { return true }
        return false
    }
}

enum MemoryStyle {
    static func symbol(forSource source: String) -> String {
        switch source {
        case "manual": return "square.and.pencil"
        case "chat": return HVSymbol.chat
        case "coding": return "chevron.left.forwardslash.chevron.right"
        case "agent": return HVSymbol.agent
        case "file": return "doc.text"
        case "github": return "shippingbox"
        case "web": return "globe"
        default: return HVSymbol.memory
        }
    }

    /// What a source's dot and node are drawn in on the graph and its legend. Four hues that sit well apart on the colour
    /// wheel (You blue, Chat violet, File mint, Agent amber, the same four `KeptKind` draws a map in) and everything else
    /// in the grey text role, so Coding, Repository and Web look alike on the map and the legend and the callout name
    /// them. A hue is never the only signal, and each is 3:1 or better on the page and on paper in both looks.
    static func graphTint(forSource source: String) -> Color {
        switch source {
        case "manual": return Palette.blue
        case "chat": return Palette.violet
        case "agent": return Palette.amber
        case "file": return Palette.mint
        default: return Palette.textSecondary
        }
    }
}

extension MindCommitKind {
    var symbol: String {
        switch self {
        case .memorize: return "plus.circle"
        case .edit: return "pencil.circle"
        case .forget: return "minus.circle"
        case .merge: return "arrow.triangle.merge"
        case .revert: return "arrow.uturn.backward.circle"
        case .importing: return HVSymbol.importData
        case .link: return "link"
        case .other: return "circle.dashed"
        }
    }
}

extension MindAuthorKind {
    var symbol: String {
        switch self {
        case .user: return HVSymbol.contact
        case .agent: return HVSymbol.agent
        case .system: return HVSymbol.general
        }
    }
}

enum MemoryDates {
    /// A quiet date for a card: "Today", "Yesterday", "Tuesday", "Mar 4", "Mar 4, 2025".
    static func quiet(_ date: Date?, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let date else { return "" }
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days > 0, days < 7 { return date.formatted(.dateTime.weekday(.wide)) }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) { return date.formatted(.dateTime.month(.abbreviated).day()) }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    static func full(_ date: Date?) -> String {
        guard let date else { return "" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    static func relative(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "" }
        return date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }
}

/// Lays chips out in rows, wrapping where the width runs out.
struct MemoryFlowLayout: Layout {
    var spacing: CGFloat = 6
    /// The gap between rows, when it should differ from the gap between chips in a row.
    var lineSpacing: CGFloat?

    private var rowGap: CGFloat { lineSpacing ?? spacing }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let limit = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > limit {
                x = 0
                y += rowHeight + rowGap
                rowHeight = 0
            }
            x += size.width
            widest = max(widest, x)
            x += spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + rowGap
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Where a memory came from, as a small chip.
struct MemorySourceChip: View {
    let source: String

    var body: some View {
        HStack(spacing: 4) {
            HVIcon(MemoryStyle.symbol(forSource: source))
                .font(.system(.caption2, weight: .semibold))
            Text(MemorySource.label(source))
                .font(.system(.caption2, weight: .semibold))
        }
        // Grey like the tags beside it, on the tint ladder's one fill: the glyph and the word name the source, not a hue.
        .foregroundStyle(Palette.textSecondary)
        .padding(.horizontal, 8)
        .padding(.vertical, HV.Space.xxs)
        .background(Palette.textSecondary.opacity(HV.Tint.fill), in: Capsule())
    }
}

/// A hairline between rows that share a card.
struct MemoryRowDivider: View {
    var body: some View {
        Rectangle()
            .fill(Palette.hairline)
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

/// The small arrow at the end of a row that opens something.
struct MemoryChevron: View {
    var body: some View {
        Image(systemName: HVSymbol.open)
            .font(.system(.footnote, weight: .semibold))
            .foregroundStyle(Palette.textTertiary)
            .accessibilityHidden(true)
    }
}

extension View {
    /// Rows that belong together, on one sheet of paper with a hairline border: the card a list of rows sits in.
    func memoryRowCard() -> some View {
        self
            .padding(.horizontal, HV.Space.m)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: HV.Radius.l, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: HV.Radius.l, style: .continuous).strokeBorder(Palette.border, lineWidth: 1))
    }
}

/// A list of rows in one card, a hairline between them.
struct MemoryRowStack<Item: Identifiable, Row: View>: View {
    let items: [Item]
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { MemoryRowDivider() }
                row(item)
            }
        }
        .memoryRowCard()
    }
}

/// The label above a field that is more than one text field (the tags, with their chips). It matches
/// the label HVLabeledField puts above a plain one, so a form reads the same all the way down.
struct MemoryFieldLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(.footnote, weight: .medium))
            .foregroundStyle(Palette.textSecondary)
    }
}

/// A memory's tags, wrapping, optionally cut to the first few.
struct MemoryTagList: View {
    let tags: [String]
    var source: String?
    var limit: Int?

    var body: some View {
        let shown = limit.map { Array(tags.prefix($0)) } ?? tags
        MemoryFlowLayout(spacing: 6) {
            if let source { MemorySourceChip(source: source) }
            ForEach(shown, id: \.self) { tag in
                HVTag(text: tag)
            }
            if let limit, tags.count > limit {
                HVTag(text: "+\(tags.count - limit)", tint: Palette.textTertiary)
            }
        }
    }
}

/// A memory in a list: its title, two lines of what it says, its tags and a quiet date.
struct MemoryCard: View {
    let item: MemoryItem
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var isLarge: Bool { dynamicTypeSize.isAccessibilitySize }

    var body: some View {
        VStack(alignment: .leading, spacing: HV.Space.xs) {
            // The date beside the title while the title has the room. At an accessibility size it would leave the title a
            // sliver ("Trip to…"), so it goes under it and the title takes the whole width.
            if isLarge {
                VStack(alignment: .leading, spacing: HV.Space.xxs) {
                    title
                    date
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: HV.Space.s) {
                    title
                    Spacer(minLength: HV.Space.xs)
                    date
                }
            }
            if !item.summary.isEmpty {
                Text(item.summary)
                    .font(.hvSubheadline)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(isLarge ? 4 : 2)
                    .multilineTextAlignment(.leading)
            }
            MemoryTagList(tags: item.tags, source: item.source, limit: 3)
                .padding(.top, HV.Space.xxs)
        }
        .hvCard()
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens this memory")
    }

    private var title: some View {
        Text(item.title)
            .font(.hvHeadline)
            .foregroundStyle(Palette.textPrimary)
            .lineLimit(isLarge ? 4 : 2)
            .multilineTextAlignment(.leading)
    }

    private var date: some View {
        Text(MemoryDates.quiet(item.createdAt))
            .font(.hvCaption)
            .foregroundStyle(Palette.textTertiary)
            .fixedSize()
    }
}

/// A memory's text, shown as the document it is.
struct MemoryMarkdownView: View {
    let blocks: [MarkdownBlock]

    var body: some View {
        LazyVStack(alignment: .leading, spacing: HV.Space.s) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            inline(text)
                .font(headingFont(level))
                .foregroundStyle(Palette.textPrimary)
                .padding(.top, level <= 2 ? HV.Space.xs : HV.Space.xxs)
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let text):
            inline(text)
                .font(.hvBody)
                .foregroundStyle(Palette.textPrimary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        case .list(let items, let ordered):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: HV.Space.xs) {
                        Text(ordered ? "\(item.number ?? index + 1)." : "\u{2022}")
                            .font(.hvBody)
                            .foregroundStyle(Palette.textSecondary)
                            .frame(minWidth: 18, alignment: .trailing)
                        inline(item.text)
                            .font(.hvBody)
                            .foregroundStyle(Palette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(item.depth) * 16)
                }
            }
        case .quote(let text):
            HStack(alignment: .top, spacing: HV.Space.s) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Palette.border)
                    .frame(width: 3)
                inline(text)
                    .font(.hvBody)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .code(_, let text):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(.hvMono)
                    .foregroundStyle(Palette.textPrimary)
                    .padding(HV.Space.s)
            }
            .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: HV.Radius.s, style: .continuous))
        case .rule:
            Divider().padding(.vertical, HV.Space.xs)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        // Three sizes under the memory's own title (title, 28): a first heading at 20, then the headline role at 17.
        case 1: return .system(.title3, weight: .medium)
        default: return .hvHeadline
        }
    }

    /// Bold, italics, code and links inside a line; line breaks are kept.
    private func inline(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        if let attributed = try? AttributedString(markdown: text, options: options) {
            return Text(attributed)
        }
        return Text(text)
    }
}

/// A line of small print with an icon, for receipts and meta rows.
struct MemoryMetaLine: View {
    let symbol: String
    let text: String
    var tint: Color = Palette.textSecondary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .font(.system(.caption, weight: .semibold))
                .foregroundStyle(tint)
                .hvIconSlot(16)
                .accessibilityHidden(true)
            Text(text)
                .font(.hvFootnote)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
