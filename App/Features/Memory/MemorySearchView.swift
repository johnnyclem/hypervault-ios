import HyperVaultKit
import SwiftUI

/// Browse memory, or recall from it. The list shows at once from the saved
/// copy; while someone types it narrows on the device and then upgrades to the
/// server's recall (meaning and keywords) with scores, links and receipts.
struct MemorySearchView: View {
    let list: MemoryListModel
    @Binding var query: String
    var onMemorize: () -> Void

    @Environment(AppModel.self) private var app

    var body: some View {
        ScrollView {
            LazyVStack(spacing: HV.Space.s) {
                MemorySearchField(text: $query, prompt: "Recall anything", isBusy: list.isRecalling)
                if list.isStale { HVStaleBanner() }
                content
            }
            .padding(.horizontal, HV.Space.m)
            .padding(.top, HV.Space.xs)
            .padding(.bottom, HV.Space.xl)
            .hvReadableWidth()
        }
        .scrollDismissesKeyboard(.interactively)
        .refreshable { await list.refresh(app: app) }
    }

    @ViewBuilder
    private var content: some View {
        if list.isSearching {
            searchContent
        } else {
            switch list.phase {
            case .loading where list.items.isEmpty:
                HVListSkeleton(rows: 6)
            case .failed(let message) where list.items.isEmpty:
                HVErrorState(message: message) { Task { await list.load() } }
            default:
                if list.items.isEmpty {
                    HVEmptyState(
                        symbol: "brain.head.profile",
                        title: "Nothing in memory yet",
                        message: "Ask your AI to keep something, or write a note here.",
                        actionTitle: "Memorize something",
                        action: onMemorize
                    )
                } else {
                    header(Text(countLine))
                    ForEach(list.items) { item in
                        NavigationLink(value: Route.memory(id: item.id)) {
                            MemoryCard(item: item)
                        }
                        .buttonStyle(.plain)
                        .id("list-\(item.id)")
                        .accessibilityIdentifier("memory.row.\(item.id)")
                    }
                }
            }
        }
    }

    private var countLine: String {
        let noun = list.items.count == 1 ? "memory" : "memories"
        let branch = list.branch == MindBranchName.defaultName ? "" : " \u{00B7} on \(list.branch)"
        let capped = list.items.count >= 200 ? " \u{00B7} newest 200, search finds the rest" : ""
        return "\(list.items.count) \(noun)\(branch)\(capped)"
    }

    @ViewBuilder
    private var searchContent: some View {
        if let recall = list.currentRecall {
            if recall.results.isEmpty {
                HVEmptyState(
                    symbol: "magnifyingglass",
                    title: recall.message.isEmpty ? "Nothing in memory matches that yet. Keep something first." : recall.message,
                    actionTitle: "Memorize something",
                    action: onMemorize
                )
            } else {
                header(Text("\(recall.results.count) \(recall.results.count == 1 ? "match" : "matches") \u{00B7} \(recall.recallMode.label)"))
                let top = recall.results.map(\.score).max() ?? 0
                ForEach(recall.results) { hit in
                    NavigationLink(value: Route.memory(id: hit.id)) {
                        MemoryHitCard(hit: hit, topScore: top)
                    }
                    .buttonStyle(.plain)
                    .id("hit-\(hit.id)")
                }
            }
        } else {
            let local = list.localMatches
            if let failure = list.recallFailure {
                Text(failure)
                    .font(.hvFootnote)
                    .foregroundStyle(Palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if local.isEmpty {
                if list.isRecalling {
                    HVLoadingState(message: "Recalling from memory\u{2026}")
                } else if list.trimmedQuery.count < 2 {
                    header(Text("Keep typing\u{2026}"))
                } else {
                    HVEmptyState(
                        symbol: "magnifyingglass",
                        title: "Nothing in memory matches that yet. Keep something first.",
                        actionTitle: "Memorize something",
                        action: onMemorize
                    )
                }
            } else {
                header(Text(list.isRecalling ? "\(local.count) so far \u{00B7} recalling\u{2026}" : "\(local.count) on this phone"))
                ForEach(local) { item in
                    NavigationLink(value: Route.memory(id: item.id)) {
                        MemoryCard(item: item)
                    }
                    .buttonStyle(.plain)
                    .id("local-\(item.id)")
                }
            }
        }
    }

    private func header(_ text: Text) -> some View {
        text
            .font(.hvCaption)
            .foregroundStyle(Palette.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, HV.Space.xxs)
            .padding(.top, HV.Space.xxs)
            .accessibilityAddTraits(.isHeader)
    }
}

struct MemorySearchField: View {
    @Binding var text: String
    var prompt: String
    var isBusy = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: HV.Space.xs) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Palette.textTertiary)
                .accessibilityHidden(true)
            TextField(prompt, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($focused)
                .accessibilityIdentifier("memory.search")
            if isBusy {
                ProgressView().controlSize(.small)
            }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Palette.textTertiary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .hvFieldChrome(isFocused: focused)
    }
}

/// A match from recall: the memory, how well it fits, the exact chunk for the
/// best ones, what it links to, and who last touched it.
struct MemoryHitCard: View {
    let hit: MemoryRecallHit
    let topScore: Double

    var body: some View {
        VStack(alignment: .leading, spacing: HV.Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: HV.Space.s) {
                Text(hit.title)
                    .font(.hvHeadline)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: HV.Space.xs)
                MemoryRelevance(score: hit.score, topScore: topScore)
            }
            if let excerpt = hit.excerpt() {
                Text(excerpt)
                    .font(.hvSubheadline)
                    .foregroundStyle(Palette.textPrimary.opacity(0.85))
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
                    .padding(HV.Space.s)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: HV.Radius.s, style: .continuous))
            } else if !hit.summary.isEmpty {
                Text(hit.summary)
                    .font(.hvSubheadline)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            if !hit.related.isEmpty {
                MemoryMetaLine(symbol: "link", text: "Linked to " + hit.related.prefix(3).joined(separator: ", "))
            }
            MemoryTagList(tags: hit.tags, source: hit.source, limit: 3)
            if let receipt = hit.provenance {
                MemoryMetaLine(symbol: receipt.authorKind.symbol, text: MemoryReceiptText.line(receipt))
            }
        }
        .hvCard()
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens this memory")
    }
}

/// How well a match fits: a small bar against the best match, and the score itself.
struct MemoryRelevance: View {
    let score: Double
    let topScore: Double

    var body: some View {
        HStack(spacing: 6) {
            Capsule()
                .fill(Palette.surfaceRaised)
                .frame(width: 36, height: 5)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(Palette.softGradient)
                        .frame(width: 36 * fraction, height: 5)
                }
            Text(scoreText)
                .font(.system(.caption2, design: .rounded, weight: .semibold))
                .foregroundStyle(Palette.textTertiary)
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Relevance \(scoreText)")
    }

    private var fraction: CGFloat {
        guard topScore > 0 else { return 0.1 }
        return CGFloat(min(max(score / topScore, 0.08), 1))
    }

    private var scoreText: String {
        score >= 10 || score == score.rounded() ? String(format: "%.0f", score) : String(format: "%.2f", score)
    }
}

enum MemoryReceiptText {
    /// "You \u{00B7} memorize: Trip notes \u{00B7} 2 days ago"
    static func line(_ receipt: MemoryProvenance) -> String {
        var parts = [receipt.author]
        if !receipt.message.isEmpty { parts.append(receipt.message) }
        let when = MemoryDates.relative(receipt.committedAt)
        if !when.isEmpty { parts.append(when) }
        // The dot stays with the part before it, so a long line never starts with one.
        return parts.joined(separator: "\u{00A0}\u{00B7} ")
    }
}
