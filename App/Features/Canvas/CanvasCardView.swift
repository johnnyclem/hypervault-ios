import HyperVaultKit
import SwiftUI

/// A thing on the page: a memory, a page, a file, a group of files or a key. A key
/// card names who may use it and never anything it holds.
struct CanvasCardView: View {
    let card: CanvasCard
    let onOpen: () -> Void
    let onHide: () -> Void
    /// Opens the people-and-role share sheet. A card that has nothing to share (a memory, a key) shows no Share whatever this is.
    var onShare: (() -> Void)?

    @State private var showFiles = false
    @State private var copied = false
    @State private var sealed = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var isLarge: Bool { dynamicTypeSize.isAccessibilitySize }

    var body: some View {
        VStack(alignment: .leading, spacing: HV.Space.s + 2) {
            header
            if let kept = card.kept { keptSection(kept) }
            if card.kind == .group, let files = card.detail?.files, !files.isEmpty { groupFiles(files) }
            if card.kind == .key, let agents = card.detail?.agents { keyAgents(agents) }
            actions
        }
        .hvCard()
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: HV.Space.s + 2) {
            HVIconBadge(symbol: card.kind.symbol, tint: card.kind.tint, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(card.title)
                    .font(.hvHeadline)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(isLarge ? 4 : 2)
                // Side by side while the words have the room. At an accessibility size each half would get a
                // sliver of the card and be broken mid-word ("MEM-ORY", "Bud-get"), so the kind sits over the line.
                if isLarge {
                    VStack(alignment: .leading, spacing: 2) { kindLabel; subtitleLabel }
                } else {
                    HStack(spacing: HV.Space.xs) {
                        kindLabel
                        if hasSubtitle {
                            Text("·").foregroundStyle(Palette.textTertiary)
                            subtitleLabel
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var kindLabel: some View {
        Text(card.kind.singular.uppercased())
            .font(.system(.caption2, weight: .bold))
            .foregroundStyle(card.kind.tint)
            .tracking(0.6)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var hasSubtitle: Bool { !(card.subtitle ?? "").isEmpty }

    @ViewBuilder
    private var subtitleLabel: some View {
        if let subtitle = card.subtitle, !subtitle.isEmpty {
            Text(subtitle)
                .font(.hvFootnote)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(isLarge ? 6 : 2)
        }
    }

    private func keptSection(_ kept: KeptDetails) -> some View {
        VStack(alignment: .leading, spacing: HV.Space.xs) {
            HStack(spacing: HV.Space.xs) {
                HVIcon("checkmark.seal.fill")
                    .foregroundStyle(Palette.success)
                    .hvBounce(value: sealed)
                    .onAppear { sealed = true }
                Text(kept.line)
                    .font(.system(.subheadline, weight: .semibold))
            }
            if kept.isPrivate {
                Text(HVCopy.onlyYouLine)
                    .font(.hvFootnote)
                    .foregroundStyle(Palette.textSecondary)
            }
            Text(kept.link)
                .font(.hvMono)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, HV.Space.s)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: HV.Radius.s, style: .continuous))
        }
    }

    private func groupFiles(_ files: [GroupMember]) -> some View {
        VStack(alignment: .leading, spacing: HV.Space.xs) {
            Button(showFiles ? "Show less" : "Show files") {
                HV.Motion.animate(.snappy) { showFiles.toggle() }
            }
            .buttonStyle(.hvGhost)
            .padding(.leading, -HV.Space.s)
            if showFiles {
                ForEach(files, id: \.path) { file in
                    HStack {
                        Text(file.path).font(.hvMono).lineLimit(1)
                        Spacer()
                        Text(HVCopy.bytesLine(file.sizeBytes)).font(.hvCaption).foregroundStyle(Palette.textTertiary)
                    }
                }
            }
        }
    }

    private func keyAgents(_ agents: [CardAgent]) -> some View {
        VStack(alignment: .leading, spacing: HV.Space.xs) {
            Text(HVCopy.agentsAllowedHeading)
                .font(.system(.caption, weight: .semibold))
                .foregroundStyle(Palette.textSecondary)
            if agents.isEmpty {
                Text("No agents allowed").font(.hvFootnote).foregroundStyle(Palette.textTertiary)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(agents) { agent in
                        HVTag(text: agent.name, tint: Palette.amber)
                    }
                }
            }
        }
    }

    /// One row when it fits. At a larger text size Hide drops to a row of its own, and at the largest
    /// each action has one, so no label is ever broken across two lines.
    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                leadingActions
                Spacer(minLength: HV.Space.xs)
                hideButton
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) { leadingActions }
                hideButton
            }
            VStack(alignment: .leading, spacing: 0) {
                leadingActions
                hideButton
            }
        }
        .lineLimit(1)
        .padding(.leading, -HV.Space.s)
        // The buttons are 44 points tall with their words in the middle, which is already a dozen points of air under
        // the words; the card's own padding is not added on top of it, or the card has twice as much room under its last
        // line as over its first. (The buttons' tap areas still end inside the card.)
        .padding(.bottom, -HV.Space.s)
    }

    /// Open, and for a thing that was just kept, its link (copied, or handed on with the system's own share sheet). For any
    /// other page, file or group, Share: the sheet that has the link and the people who can open it. Every one is a ghost
    /// button, which already carries its own padding and a 44-point target, so the row adds no spacing of its own.
    @ViewBuilder
    private var leadingActions: some View {
        Button(HVCopy.cardOpenLabel, action: onOpen)
            .buttonStyle(.hvGhost)
            .accessibilityLabel("Open \(card.title)")
            // Open on a key shows its page over the canvas, where the agents that may use it are changed; "Open" alone does not say so.
            .accessibilityHint(card.kind == .key ? "Change which agents may use it, or rename it" : "")
        if let kept = card.kept, let url = URL(string: kept.link) {
            Button(copied ? "Copied" : "Copy link") {
                UIPasteboard.general.string = kept.link
                Haptics.tap()
                copied = true
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(HV.Motion.copiedHold * 1_000_000_000))
                    copied = false
                }
            }
            .buttonStyle(.hvGhost)
            ShareLink(item: url) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.hvGhost)
        } else if let onShare, let slug = card.slug {
            // (A card that was just kept has the system share beside Copy link: the quick way to hand the link on, and a fifth
            // button would not fit the row. Its people sheet is one tap away from the page.)
            Button(action: onShare) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.hvGhost)
            .accessibilityLabel("Share \(card.title)")
            .accessibilityHint("Share the link or add people")
            .accessibilityIdentifier("canvas.share.\(slug)")
        }
    }

    private var hideButton: some View {
        Button(HVCopy.cardHideLabel, action: onHide)
            .buttonStyle(.hvGhost)
            .foregroundStyle(Palette.textSecondary)
            .accessibilityLabel("Hide \(card.title)")
    }
}
