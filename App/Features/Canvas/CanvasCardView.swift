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
        VStack(alignment: .leading, spacing: HV.Space.s) {
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
        HStack(alignment: .top, spacing: HV.Space.s) {
            // The kind's own colour lives here, on the Home card; every list draws the neutral tile.
            HVIconBadge(symbol: card.kind.symbol, tint: card.kind.tint, size: 36)
            VStack(alignment: .leading, spacing: HV.Space.xxs) {
                Text(card.title)
                    .font(.hvHeadline)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(isLarge ? 4 : 2)
                // Side by side while the words have the room. At an accessibility size each half would get a
                // sliver of the card and be broken mid-word ("Mem-ory", "Bud-get"), so the kind sits over the line.
                if isLarge {
                    VStack(alignment: .leading, spacing: HV.Space.xxs) { kindLabel; subtitleLabel }
                } else {
                    // On the first line of the subtitle, so a subtitle that wraps does not leave the kind between its lines.
                    HStack(alignment: .firstTextBaseline, spacing: HV.Space.xs) {
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
        // The kind's own word ("Memory", "Page"), in sentence case; the tile beside the title carries the kind's colour.
        Text(card.kind.singular)
            .font(.hvMeta)
            .foregroundStyle(Palette.textSecondary)
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
                .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: HV.Radius.control, style: .continuous))
        }
    }

    private func groupFiles(_ files: [GroupMember]) -> some View {
        VStack(alignment: .leading, spacing: HV.Space.xs) {
            Button(showFiles ? "Show less" : "Show files") {
                HV.Motion.animate(.snappy) { showFiles.toggle() }
            }
            .buttonStyle(.hvGhost)
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
                FlowLayout(spacing: HV.Space.hair) {
                    ForEach(agents) { agent in
                        // A name states no warning, so the tag is the neutral grey one.
                        HVTag(text: agent.name)
                    }
                }
            }
        }
    }

    /// One row when it fits. At a larger text size Hide drops to a row of its own, and at the largest
    /// each action has one, so no label is ever broken across two lines.
    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: HV.Space.m) {
                leadingActions
                Spacer(minLength: HV.Space.xs)
                hideButton
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: HV.Space.m) { leadingActions }
                hideButton
            }
            VStack(alignment: .leading, spacing: 0) {
                leadingActions
                hideButton
            }
        }
        .lineLimit(1)
        // The buttons are 44 points tall with their words in the middle, which is already a dozen points of air under
        // the words; the card's own padding is not added on top of it, or the card has twice as much room under its last
        // line as over its first. (The buttons' tap areas still end inside the card.)
        .padding(.bottom, -HV.Space.s)
    }

    /// Open, and for a thing that was just kept, its link (copied, or handed on with the system's own share sheet). For any
    /// other page, file or group, Share: the sheet that has the link and the people who can open it. Every one is a ghost
    /// button, which has a 44-point target and no padding of its own: the first word sits on the card's edge, and the
    /// row puts the space between the words.
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
                Text("Share")
            }
            .buttonStyle(.hvGhost)
        } else if let onShare, let slug = card.slug {
            // (A card that was just kept has the system share beside Copy link: the quick way to hand the link on, and a fifth
            // button would not fit the row. Its people sheet is one tap away from the page.)
            Button("Share", action: onShare)
                .buttonStyle(.hvGhost)
                .accessibilityLabel("Share \(card.title)")
                .accessibilityHint("Share the link or add people")
                .accessibilityIdentifier("canvas.share.\(slug)")
        }
    }

    private var hideButton: some View {
        // The ghost style draws its ink from the tint, so a `foregroundStyle` here would be ignored: Hide, which only
        // removes the card, is quiet through `.tint`, and Open, Copy link and Share keep the accent.
        Button(HVCopy.cardHideLabel, action: onHide)
            .buttonStyle(.hvGhost)
            .tint(Palette.textSecondary)
            .accessibilityLabel("Hide \(card.title)")
    }
}
