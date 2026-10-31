import HyperVaultKit
import SwiftUI

/// Digest: a memory that is really many (a pasted chat, a long import) is
/// proposed as a split into smaller memories, wired together in reading order.
/// Review it like a pull request: apply the split, or keep the memory whole.
struct DigestRootView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        DigestContent(env: env)
    }
}

private struct DigestContent: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var model: DigestModel
    @State private var applying: DigestRun?

    init(env: AppEnvironment) {
        _model = State(initialValue: DigestModel(env: env))
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: HV.Space.m) {
                settings
                switch model.phase {
                case .loading:
                    HVListSkeleton(rows: 3)
                case .failed(let message):
                    HVErrorState(message: message) { Task { await model.load() } }
                case .loaded:
                    if model.isStale { HVStaleBanner() }
                    if model.runs.isEmpty {
                        emptyState
                    } else {
                        ForEach(model.runs) { run in
                            DigestRunCard(
                                run: run,
                                isBusy: model.busy.contains(run.id),
                                onApply: { applying = run },
                                onKeepWhole: { decide(run, .reject) },
                                onOpenSource: { app.router.push(.memory(id: run.sourceMemoryId)) }
                            )
                        }
                    }
                }
            }
            .padding(HV.Space.m)
            .padding(.bottom, HV.Space.xl)
            .hvReadableWidth()
        }
        .hvScreenBackground()
        .navigationTitle("Digest")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.refresh(app: app) }
        .task { await model.load() }
        .confirmationDialog(
            "Apply this split?",
            isPresented: Binding(get: { applying != nil }, set: { if !$0 { applying = nil } }),
            titleVisibility: .visible,
            presenting: applying
        ) { run in
            Button("Apply split") { decide(run, .accept) }
        } message: { run in
            Text("\u{201C}\(run.displayTitle)\u{201D} is replaced by \(run.segments.count) smaller memories, linked in order. It is one commit, so you can undo it from History.")
        }
    }

    private var settingsTitle: some View {
        Text("Auto-digest on import")
            .font(.hvHeadline)
            .foregroundStyle(Palette.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var settingsDetail: some View {
        Text("A big import or a pasted chat can land as one memory when it is really many. Digest proposes how to split it, and nothing changes until you say so.")
            .font(.hvFootnote)
            .foregroundStyle(Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var digestSwitch: some View {
        Toggle("Auto-digest on import", isOn: Binding(get: { model.enabled }, set: { toggle($0) }))
            .labelsHidden()
            .disabled(model.isChangingSetting)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: HV.Space.s) {
            // The sentence has the card's whole width: between the badge and the switch it was left about half of it
            // and ran to six lines. The title shares the badge's row while it fits; at an accessibility size the title
            // would get a narrow column ("Auto-/digest"), so the switch goes up beside the badge and the title goes
            // below it.
            if dynamicTypeSize.isAccessibilitySize {
                HStack(spacing: HV.Space.s) {
                    HVIconBadge(symbol: "scissors", tint: Palette.cyan, size: 36)
                    Spacer(minLength: HV.Space.xs)
                    digestSwitch
                }
                VStack(alignment: .leading, spacing: HV.Space.xxs) {
                    settingsTitle
                    settingsDetail
                }
            } else {
                HStack(spacing: HV.Space.s) {
                    HVIconBadge(symbol: "scissors", tint: Palette.cyan, size: 36)
                    settingsTitle
                    Spacer(minLength: HV.Space.xs)
                    digestSwitch
                }
                settingsDetail
            }
            Text("You can always digest a memory yourself: open it and choose Digest this. The switch only controls the automatic proposals.")
                .font(.hvCaption)
                .foregroundStyle(Palette.textTertiary)
        }
        .hvCard()
    }

    private var emptyState: some View {
        Group {
            if model.appliedThisSitting > 0 {
                HVEmptyState(symbol: "sparkles", title: "All reviewed", message: "Your memory is a little tidier.")
            } else {
                HVEmptyState(
                    symbol: "scissors",
                    title: "Nothing to split",
                    message: "Open a long memory and choose Digest this to propose a split. With auto-digest on, long imports show up here by themselves."
                )
            }
        }
    }

    private func toggle(_ on: Bool) {
        Task {
            do {
                try await model.setEnabled(on)
                Haptics.select()
            } catch {
                app.toasts.show(error: error)
            }
        }
    }

    private func decide(_ run: DigestRun, _ verdict: DigestVerdict) {
        applying = nil
        Task {
            do {
                let message = try await model.decide(run, verdict)
                if verdict == .accept { Haptics.success() }
                if !message.isEmpty { app.toasts.success(message) }
            } catch {
                app.toasts.show(error: error)
            }
        }
    }
}

/// One proposed split: the source, the pieces as cards, and how they will be wired.
private struct DigestRunCard: View {
    let run: DigestRun
    let isBusy: Bool
    let onApply: () -> Void
    let onKeepWhole: () -> Void
    let onOpenSource: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: HV.Space.s) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Split \u{201C}\(run.displayTitle)\u{201D}")
                    .font(.hvTitle3)
                    .foregroundStyle(Palette.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle)
                    .font(.hvFootnote)
                    .foregroundStyle(Palette.textSecondary)
                Button("Read the original", action: onOpenSource)
                    .buttonStyle(.hvGhost)
            }

            VStack(spacing: HV.Space.xs) {
                ForEach(run.segments) { segment in
                    DigestSegmentCard(segment: segment, total: run.segments.count)
                }
            }

            Text(run.linksLine)
                .font(.hvCaption)
                .foregroundStyle(Palette.textTertiary)

            HStack(spacing: HV.Space.m) {
                Button(action: onApply) {
                    if isBusy { ProgressView() } else { Text("Apply split") }
                }
                .buttonStyle(DreamTintedButtonStyle())
                .accessibilityIdentifier("digest.apply.\(run.id)")
                Button("Keep whole", action: onKeepWhole)
                    .buttonStyle(.hvGhost)
                    .accessibilityIdentifier("digest.keep.\(run.id)")
                Spacer(minLength: 0)
            }
            .disabled(isBusy)
        }
        .hvCard()
    }

    private var subtitle: String {
        var parts = ["\(run.segments.count) pieces", "found as \(run.strategy.label)"]
        if let date = run.createdAt { parts.append(MemoryDates.quiet(date)) }
        return parts.joined(separator: " \u{00B7} ")
    }
}

private struct DigestSegmentCard: View {
    let segment: DigestSegment
    let total: Int

    var body: some View {
        HStack(alignment: .top, spacing: HV.Space.s) {
            Text("\(segment.ordinal + 1)")
                .font(.system(.footnote, weight: .bold))
                .foregroundStyle(Palette.cyan)
                .frame(width: 26, height: 26)
                .background(Palette.cyan.opacity(0.14), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(segment.title)
                    .font(.hvSubheadline.weight(.semibold))
                    .foregroundStyle(Palette.textPrimary)
                    .multilineTextAlignment(.leading)
                if !segment.summary.isEmpty {
                    Text(segment.summary)
                        .font(.hvFootnote)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
                if !segment.reason.isEmpty || !segment.tags.isEmpty {
                    MemoryFlowLayout(spacing: 6) {
                        if !segment.reason.isEmpty { HVTag(text: segment.reason, tint: Palette.cyan) }
                        ForEach(segment.tags.prefix(4), id: \.self) { HVTag(text: $0) }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(HV.Space.s)
        .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: HV.Radius.control, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Piece \(segment.ordinal + 1) of \(total): \(segment.title)")
    }
}
