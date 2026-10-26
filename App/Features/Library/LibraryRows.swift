import HyperVaultKit
import SwiftUI

enum LibraryRow {
    /// The mark at the head of every row, as wide as `HVIconBadge` is by default.
    static let markSize: CGFloat = 36
}

/// The shape every Library row shares: a mark 36 points square, a title, a line under it and whatever
/// trails. It sets type and spacing as `HVRow` does in Yours (two lines, any number at the accessibility
/// sizes), so a row here and a row there line up. The mark is the thing's own (a page's icon, a kind's
/// badge), which is why this is not `HVRow` itself.
struct LibraryRowFrame<Mark: View, Meta: View, Trailing: View>: View {
    let title: String
    let subtitle: String?
    let mark: Mark
    let meta: Meta
    let trailing: Trailing
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder mark: () -> Mark,
        @ViewBuilder meta: () -> Meta,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.mark = mark()
        self.meta = meta()
        self.trailing = trailing()
    }

    private var lineLimit: Int? { dynamicTypeSize.isAccessibilitySize ? nil : 2 }

    var body: some View {
        HStack(spacing: HV.Space.s + 2) {
            mark
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.hvBody)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(lineLimit)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.hvFootnote)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(lineLimit)
                }
                meta
            }
            Spacer(minLength: HV.Space.xs)
            trailing
        }
        .accessibilityElement(children: .combine)
    }
}

/// A row of the list behind Yours: what it is called, what kind of thing it is (or what it says),
/// and when it was last in use.
struct LibraryItemRow: View {
    let item: KeptItem
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        LibraryRowFrame(title: item.name, subtitle: subtitle) {
            mark
        } meta: {
            EmptyView()
        } trailing: {
            // Beside the title the time would take the room the name needs at the largest sizes.
            if let ago, !dynamicTypeSize.isAccessibilitySize {
                Text(ago)
                    .font(.hvCaption)
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
            }
        }
    }

    private var ago: String? { LibraryCopy.ago(for: item) }

    /// What the thing says, else what it is: the same line Yours puts there.
    private var subtitle: String {
        let line = item.summary.isEmpty ? item.kind.singular : item.summary
        guard dynamicTypeSize.isAccessibilitySize, let ago else { return line }
        return "\(line) \u{00B7} \(ago)"
    }

    @ViewBuilder
    private var mark: some View {
        switch item.kind {
        case .page, .file, .group:
            if let slug = item.slug {
                ArtifactGlyph(slug: slug, title: item.name, size: LibraryRow.markSize)
            } else {
                HVIconBadge(symbol: item.kind.symbol, tint: item.kind.tint)
            }
        case .memory, .key:
            HVIconBadge(symbol: item.kind.symbol, tint: item.kind.tint)
        }
    }
}

/// A row of the file manager: the page's icon, its name, its type and date, who can open it, its tags
/// and how many things it is connected to.
struct LibraryFileRow: View {
    let row: LibraryModel.FileRow

    var body: some View {
        let summary = row.summary
        LibraryRowFrame(title: summary.title, subtitle: subtitle) {
            ArtifactGlyph(slug: summary.slug, title: summary.title, icon: summary.icon, size: LibraryRow.markSize)
        } meta: {
            if !summary.tags.isEmpty || row.connections > 0 {
                ArtifactFlowLayout(spacing: HV.Space.xs) {
                    ForEach(summary.tags.prefix(2), id: \.self) { tag in
                        HVTag(text: "#\(tag)")
                    }
                    if summary.tags.count > 2 {
                        Text("+\(summary.tags.count - 2)")
                            .font(.hvCaption)
                            .foregroundStyle(Palette.textSecondary)
                    }
                    if row.connections > 0 {
                        Label("\(row.connections)", systemImage: "link")
                            .font(.hvCaption.weight(.medium))
                            .foregroundStyle(Palette.blue)
                            .accessibilityLabel(row.connections == 1 ? "1 connection" : "\(row.connections) connections")
                    }
                }
                .padding(.top, 2)
            }
        } trailing: {
            ArtifactVisibilityMark(visibility: summary.visibility)
        }
    }

    private var subtitle: String {
        var parts = [row.summary.typeName]
        if let date = row.summary.createdAt { parts.append(date.formatted(date: .abbreviated, time: .omitted)) }
        return parts.joined(separator: " \u{00B7} ")
    }
}

/// A page someone pinned: its icon and its name, with the pin that says why it is up here.
struct LibraryPinnedRow: View {
    let slug: String
    let title: String
    let icon: String?

    var body: some View {
        LibraryRowFrame(title: title) {
            ArtifactGlyph(slug: slug, title: title, icon: icon, size: LibraryRow.markSize)
        } meta: {
            EmptyView()
        } trailing: {
            Image(systemName: "pin.fill")
                .font(.system(size: 12))
                .foregroundStyle(Palette.textTertiary)
                .accessibilityLabel("Pinned")
        }
    }
}

/// A page another person shared: its name, its kind, whose it is and when.
struct LibrarySharedRow: View {
    let item: SharedWithYouItem

    var body: some View {
        LibraryRowFrame(title: item.title, subtitle: subtitle) {
            ArtifactGlyph(slug: item.slug, title: item.title, size: LibraryRow.markSize)
        } meta: {
            EmptyView()
        } trailing: {
            EmptyView()
        }
    }

    private var subtitle: String {
        var parts = [item.typeName]
        if let owner = item.owner { parts.append("from \(owner)") }
        if let date = item.createdAt { parts.append(date.formatted(date: .abbreviated, time: .omitted)) }
        return parts.joined(separator: " \u{00B7} ")
    }
}
