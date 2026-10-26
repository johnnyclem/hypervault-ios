import HyperVaultKit
import SwiftUI

/// A row of the list behind Yours: what it is called, what kind of thing it is,
/// and when it was last in use.
struct LibraryItemRow: View {
    let item: KeptItem

    var body: some View {
        HStack(spacing: HV.Space.s + 2) {
            leading
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.hvBody)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                HStack(spacing: HV.Space.xs) {
                    Text(item.kind.singular.uppercased())
                        .font(.system(.caption2, design: .rounded, weight: .semibold))
                        .tracking(0.5)
                        .foregroundStyle(Palette.textTertiary)
                    if !item.summary.isEmpty {
                        Text(item.summary)
                            .font(.hvFootnote)
                            .foregroundStyle(Palette.textSecondary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: HV.Space.xs)
            if let ago = LibraryCopy.ago(for: item) {
                Text(ago)
                    .font(.hvCaption)
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var leading: some View {
        switch item.kind {
        case .page, .file, .group:
            if let slug = item.slug {
                ArtifactGlyph(slug: slug, title: item.name, size: 38)
            } else {
                HVIconBadge(symbol: item.kind.librarySymbol, tint: item.kind.libraryTint, size: 38)
            }
        case .memory, .key:
            HVIconBadge(symbol: item.kind.librarySymbol, tint: item.kind.libraryTint, size: 38)
        }
    }
}

/// A row of the file manager: the page's icon, its name, its type, who can open
/// it, its date, its tags and how many things it is connected to.
struct LibraryFileRow: View {
    let row: LibraryModel.FileRow

    var body: some View {
        let summary = row.summary
        HStack(spacing: HV.Space.s + 2) {
            ArtifactGlyph(slug: summary.slug, title: summary.title, icon: summary.icon, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(summary.title)
                    .font(.hvBody.weight(.medium))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(metaLine)
                        .font(.hvFootnote)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                    ArtifactVisibilityMark(visibility: summary.visibility)
                }
                if !summary.tags.isEmpty || row.connections > 0 {
                    HStack(spacing: 6) {
                        ForEach(summary.tags.prefix(2), id: \.self) { tag in
                            Text("#\(tag)")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(Palette.textSecondary)
                                .lineLimit(1)
                        }
                        if summary.tags.count > 2 {
                            Text("+\(summary.tags.count - 2)")
                                .font(.system(.caption2, design: .rounded))
                                .foregroundStyle(Palette.textTertiary)
                        }
                        if row.connections > 0 {
                            HStack(spacing: 3) {
                                Image(systemName: "link")
                                Text("\(row.connections)")
                            }
                            .font(.system(.caption2, design: .rounded, weight: .medium))
                            .foregroundStyle(Palette.blue)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(row.connections == 1 ? "1 connection" : "\(row.connections) connections")
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var metaLine: String {
        var parts = [row.summary.typeLabel]
        if let date = row.summary.createdAt { parts.append(date.formatted(date: .abbreviated, time: .omitted)) }
        return parts.joined(separator: " \u{00B7} ")
    }
}

/// A page another person shared: its name, its kind, whose it is and when.
struct LibrarySharedRow: View {
    let item: SharedWithYouItem

    var body: some View {
        HStack(spacing: HV.Space.s + 2) {
            ArtifactGlyph(slug: item.slug, title: item.title, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.hvBody)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.hvFootnote)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        var parts = [item.typeLabel]
        if let owner = item.owner { parts.append("from \(owner)") }
        if let date = item.createdAt { parts.append(date.formatted(date: .abbreviated, time: .omitted)) }
        return parts.joined(separator: " \u{00B7} ")
    }
}
