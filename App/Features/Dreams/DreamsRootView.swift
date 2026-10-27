import HyperVaultKit
import SwiftUI

/// Dreams: the connections HyperVault found overnight between things you kept,
/// waiting for a verdict like a pull request. Nothing touches your graph until
/// you accept it; a connection you reject is never proposed again.
struct DreamsRootView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        DreamsContent(env: env)
    }
}

private struct DreamsContent: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var model: DreamsModel
    @State private var rejecting: DreamRun?

    init(env: AppEnvironment) {
        _model = State(initialValue: DreamsModel(env: env))
    }

    var body: some View {
        List {
            Section {
                settings
                    .listRowStyle()
            }
            switch model.phase {
            case .loading:
                Section { HVListSkeleton(rows: 3).listRowStyle() }
            case .failed(let message):
                Section { HVErrorState(message: message) { Task { await model.load() } }.listRowStyle() }
            case .loaded:
                queue
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .hvScreenBackground()
        .navigationTitle("Dreams")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.refresh(app: app) }
        .task { await model.load() }
        .confirmationDialog(
            "Reject every connection in this dream?",
            isPresented: Binding(get: { rejecting != nil }, set: { if !$0 { rejecting = nil } }),
            titleVisibility: .visible,
            presenting: rejecting
        ) { run in
            Button("Reject \(run.connections.count)", role: .destructive) { decide(run: run, .reject) }
        } message: { _ in
            Text("They are filed away for good and never proposed again.")
        }
    }

    // MARK: Settings

    private var settingsWords: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Dream every night")
                .font(.hvHeadline)
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text("While you sleep, HyperVault looks for connections you never made by hand, between your memories and your pages, and stages them here for you to review.")
                .font(.hvFootnote)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var dreamSwitch: some View {
        Toggle("Dream every night", isOn: Binding(get: { model.enabled }, set: { toggle($0) }))
            .labelsHidden()
            .disabled(model.isChangingSetting)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: HV.Space.s) {
            // Badge, words and switch in a row while the words have the room. At an accessibility size they would get a
            // narrow column between the badge and the switch ("connec-/tions"), so the switch goes up beside the badge
            // and the words have the whole width below.
            if dynamicTypeSize.isAccessibilitySize {
                HStack(spacing: HV.Space.s) {
                    HVIconBadge(symbol: "moon.stars", tint: Palette.violet, size: 40)
                    Spacer(minLength: HV.Space.xs)
                    dreamSwitch
                }
                settingsWords
            } else {
                HStack(alignment: .top, spacing: HV.Space.s) {
                    HVIconBadge(symbol: "moon.stars", tint: Palette.violet, size: 40)
                    settingsWords
                    Spacer(minLength: HV.Space.xs)
                    dreamSwitch
                }
            }
            if model.enabled {
                Button {
                    dreamNow()
                } label: {
                    if model.isDreaming {
                        HStack(spacing: HV.Space.xs) {
                            ProgressView()
                            Text("Dreaming\u{2026}")
                        }
                    } else {
                        Text("Dream now")
                    }
                }
                .buttonStyle(.hvSecondary)
                .disabled(model.isDreaming)
            }
            if let note = model.dreamNote {
                Text(note)
                    .font(.hvFootnote)
                    .foregroundStyle(Color.accentColor)
                    .transition(.opacity)
            }
            if let last = model.lastRunAt {
                Text("Last dreamt \(MemoryDates.full(last))")
                    .font(.hvCaption)
                    .foregroundStyle(Palette.textTertiary)
            }
            if !model.enabled {
                Text("Turn dreaming on to let the nightly pass start proposing connections. You can dream on the spot once it is on.")
                    .font(.hvCaption)
                    .foregroundStyle(Palette.textTertiary)
            }
        }
        .hvCard()
    }

    // MARK: Queue

    @ViewBuilder
    private var queue: some View {
        if model.review.isEmpty {
            Section { emptyState.listRowStyle() }
        } else {
            ForEach(model.review.runs) { run in
                Section {
                    runHeader(run).listRowStyle()
                    ForEach(run.connections) { connection in
                        DreamConnectionCard(
                            connection: connection,
                            topScore: model.topScore,
                            isWoven: model.woven.contains(connection.id),
                            onAccept: { accept(connection) },
                            onReject: { reject(connection) },
                            onOpen: { open($0) }
                        )
                        .listRowStyle()
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button { accept(connection) } label: { Label("Accept", systemImage: "checkmark") }
                                .tint(Palette.mint)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button { reject(connection) } label: { Label("Reject", systemImage: "xmark") }
                                .tint(Palette.textSecondary)
                        }
                    }
                }
            }
        }
    }

    private static func title(for run: DreamRun) -> String {
        guard let date = run.createdAt else { return "A dream" }
        let when = MemoryDates.quiet(date)
        return when == "Today" || when == "Yesterday" ? "Last night\u{2019}s dream" : "Dream from \(when)"
    }

    private func runHeader(_ run: DreamRun) -> some View {
        let busy = run.connections.contains { model.woven.contains($0.id) }
        return VStack(alignment: .leading, spacing: HV.Space.xs) {
            Text(Self.title(for: run))
                .font(.hvTitle3)
                .foregroundStyle(Palette.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text("\(run.connections.count) proposed \(run.connections.count == 1 ? "connection" : "connections") to review")
                .font(.hvFootnote)
                .foregroundStyle(Palette.textSecondary)
            HStack(spacing: HV.Space.xs) {
                Button("Accept all") { decide(run: run, .accept) }
                    .buttonStyle(DreamTintedButtonStyle())
                Button("Reject all") { rejecting = run }
                    .buttonStyle(.hvGhost)
                Spacer(minLength: 0)
            }
            .disabled(busy)
        }
        .padding(.top, HV.Space.s)
    }

    private var emptyState: some View {
        Group {
            if model.review.acceptedThisSitting > 0 {
                HVEmptyState(
                    symbol: "sparkles",
                    title: "All caught up",
                    message: "\(model.review.acceptedThisSitting) \(model.review.acceptedThisSitting == 1 ? "connection" : "connections") woven into your graph. Your memory is a little more your own."
                )
            } else if model.enabled {
                HVEmptyState(
                    symbol: "moon.zzz",
                    title: "Nothing found overnight",
                    message: "No new connections yet. Check back after tonight\u{2019}s pass, or dream now."
                )
            } else {
                HVEmptyState(
                    symbol: "moon.stars",
                    title: "Dreaming is off",
                    message: "Turn it on and HyperVault will look for connections while you sleep, then ask you about them here."
                )
            }
        }
    }

    // MARK: Actions

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

    private func dreamNow() {
        Task {
            do {
                try await model.dreamNow()
                Haptics.success()
            } catch {
                app.toasts.show(error: error)
            }
        }
    }

    private func accept(_ connection: DreamConnection) {
        Task {
            do {
                try await model.accept(connection.id, calm: reduceMotion)
            } catch {
                app.toasts.show(error: error)
            }
        }
    }

    private func reject(_ connection: DreamConnection) {
        Task {
            do {
                try await model.reject(connection.id)
            } catch {
                app.toasts.show(error: error)
            }
        }
    }

    private func decide(run: DreamRun, _ verdict: DreamVerdict) {
        rejecting = nil
        Task {
            do {
                let message = try await model.decide(run: run.id, verdict, calm: reduceMotion)
                if !message.isEmpty { app.toasts.success(message) }
            } catch {
                app.toasts.show(error: error)
            }
        }
    }

    private func open(_ endpoint: DreamEndpoint) {
        switch endpoint.kind {
        case .memory:
            app.router.push(.memory(id: endpoint.id))
        case .artifact:
            if let slug = endpoint.slug { app.router.push(.artifact(slug: slug)) }
        }
    }
}

private extension View {
    /// A card's place in the list: no separators, no backdrop, the screen's margins.
    func listRowStyle() -> some View {
        self
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 6, leading: HV.Space.m, bottom: 6, trailing: HV.Space.m))
    }
}

/// A quiet filled button for the many small yeses on a review screen. The label takes the person's
/// accent; the fill is raised paper, because a tint of the accent under the accent itself falls
/// short of 4.5:1 for some of the accents a person can choose.
struct DreamTintedButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.subheadline, design: .rounded, weight: .semibold))
            .foregroundStyle(isEnabled ? AnyShapeStyle(TintShapeStyle()) : AnyShapeStyle(Palette.textTertiary))
            .padding(.horizontal, HV.Space.m)
            .frame(minHeight: 44)
            .background(Palette.surfaceRaised, in: Capsule())
            .overlay(Capsule().strokeBorder(Palette.border, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// One proposed connection: the two things, why, and a verdict.
private struct DreamConnectionCard: View {
    let connection: DreamConnection
    let topScore: Double
    let isWoven: Bool
    let onAccept: () -> Void
    let onReject: () -> Void
    let onOpen: (DreamEndpoint) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: HV.Space.s) {
            endpoint(connection.a)
            HStack(spacing: HV.Space.xs) {
                Capsule()
                    .fill(isWoven ? AnyShapeStyle(Palette.brandGradient) : AnyShapeStyle(Palette.border))
                    .frame(width: 3, height: 18)
                    .padding(.leading, 18)
                Text(connection.edgeType.label)
                    .font(.system(.caption2, design: .rounded, weight: .semibold))
                    .foregroundStyle(Palette.textTertiary)
                    .textCase(.uppercase)
                Spacer(minLength: 0)
                MemoryRelevance(score: connection.score, topScore: topScore)
            }
            endpoint(connection.b)
            if !connection.reason.isEmpty {
                Text(String(connection.reason.prefix(1)).uppercased() + String(connection.reason.dropFirst()))
                    .font(.hvFootnote)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if isWoven {
                HStack(spacing: HV.Space.xs) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Palette.success)
                    Text("Woven into your graph")
                        .font(.hvSubheadline.weight(.semibold))
                        .foregroundStyle(Palette.textPrimary)
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .transition(.scale(scale: 0.9).combined(with: .opacity))
                .accessibilityElement(children: .combine)
            } else {
                HStack(spacing: HV.Space.xs) {
                    Button("Accept", action: onAccept)
                        .buttonStyle(DreamTintedButtonStyle())
                        .accessibilityIdentifier("dream.accept.\(connection.id)")
                    Button("Reject", action: onReject)
                        .buttonStyle(.hvGhost)
                        .accessibilityIdentifier("dream.reject.\(connection.id)")
                    Spacer(minLength: 0)
                }
            }
        }
        .hvCard()
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isWoven)
    }

    @ViewBuilder
    private func endpoint(_ end: DreamEndpoint) -> some View {
        let openable = !end.isGone && (end.kind == .memory || end.slug != nil)
        Button {
            onOpen(end)
        } label: {
            HStack(spacing: HV.Space.s) {
                HVIconBadge(
                    symbol: end.kind == .memory ? KeptKind.memory.symbol : KeptKind.page.symbol,
                    tint: end.kind == .memory ? KeptKind.memory.tint : KeptKind.page.tint,
                    size: 36
                )
                Text(end.label)
                    .font(.hvBody)
                    .foregroundStyle(end.isGone ? Palette.textTertiary : Palette.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if openable {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.textTertiary)
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!openable)
        .accessibilityLabel("\(end.kind == .memory ? "Memory" : "Page"): \(end.label)")
        .accessibilityHint(openable ? "Opens it" : "")
    }
}
