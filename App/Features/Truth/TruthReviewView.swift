import HyperVaultKit
import SwiftUI

/// The review session: the docket, one card at a time. Swipe right to approve
/// (which asks you to confirm), left to put it off for a week, or use the
/// buttons. Each action says what it does before it does it.
struct TruthReviewView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        TruthReviewScreen(client: env.client, preferring: nil)
    }
}

private struct DecisionRequest: Identifiable {
    let id = UUID()
    let action: TruthAction
    let item: TruthDocketItem
}

struct TruthReviewScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var model: TruthReviewModel
    @State private var drag: CGFloat = 0
    @State private var request: DecisionRequest?
    @State private var showAssert = false
    @State private var showNewLedger = false
    @State private var showExplanations = false
    private let client: HVClient
    private let preferring: String?
    private let onChange: () -> Void

    init(client: HVClient, preferring: String?, onChange: @escaping () -> Void = {}) {
        self.client = client
        self.preferring = preferring
        self.onChange = onChange
        _model = State(initialValue: TruthReviewModel(client: client))
    }

    var body: some View {
        content
            .hvScreenBackground()
            .navigationTitle("Review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .task { await model.start(preferring: preferring) }
            .safeAreaInset(edge: .bottom) { undoBar }
            .sheet(item: $request) { request in
                TruthDecisionSheet(model: model, action: request.action, item: request.item) { onChange() }
            }
            .sheet(isPresented: $showAssert) {
                if let ledger = model.ledger {
                    TruthAssertView(client: client, ledger: ledger) {
                        Task { await model.reload() }
                        onChange()
                    }
                }
            }
            .sheet(isPresented: $showNewLedger) {
                TruthNewLedgerView(hostedOnly: true) { slug, name, _ in
                    try await model.createHostedLedger(slug: slug, name: name)
                    Haptics.success()
                }
                .presentationDetents([.medium, .large])
            }
    }

    // MARK: States

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            VStack {
                HVListSkeleton(rows: 4).padding(.top, HV.Space.m)
                Spacer()
            }
        case .failed(let message):
            HVErrorState(message: message) { Task { await model.retry(preferring: preferring) } }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            ScrollView {
                VStack(spacing: HV.Space.m) {
                    header
                    if model.ledgers.allSatisfy({ !$0.isHosted }) { hostedPrompt }
                    if model.ledger?.isHosted == false { mirrorNote }
                    if let item = model.deck.current {
                        stack(item)
                        actions(item)
                    } else {
                        finished
                    }
                }
                .padding(.horizontal, HV.Space.m)
                .padding(.vertical, HV.Space.s)
                .hvReadableWidth()
            }
            .refreshable { await model.reload() }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: HV.Space.xxs) {
            // At a large text size the title takes the width, and the tag goes under it.
            let title = Text(model.deck.isFinished ? "Docket clear" : "Card \(model.deck.position) of \(model.deck.total)")
                .font(.hvTitle3)
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: HV.Space.xs) {
                    title
                    if model.schedule.due { HVTag(text: "A review is due", tint: Palette.blue) }
                }
            } else {
                HStack(alignment: .firstTextBaseline) {
                    title
                    Spacer()
                    if model.schedule.due { HVTag(text: "A review is due", tint: Palette.blue) }
                }
            }
            Text(headerLine)
                .font(.hvFootnote)
                .foregroundStyle(Palette.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var headerLine: String {
        guard let ledger = model.ledger else { return "" }
        var parts = [ledger.name]
        if model.deck.remaining.contains(where: \.nominated) { parts.append("agents nominated some") }
        if let cadence = model.schedule.cadence { parts.append("reminder \(cadence.title.lowercased())") }
        return parts.joined(separator: " · ")
    }

    private var mirrorNote: some View {
        Label(TruthDocketRules.mirrorReason, systemImage: "lock")
            .font(.hvFootnote)
            .foregroundStyle(Palette.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(HV.Space.s)
            .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: HV.Radius.m, style: .continuous))
    }

    private var hostedPrompt: some View {
        VStack(alignment: .leading, spacing: HV.Space.s) {
            Text("Your ledgers mirror stenographer. A hosted ledger is written here: you and your agents assert into it, and this session decides it.")
                .font(.hvCallout)
                .foregroundStyle(Palette.textSecondary)
            Button("Create a hosted ledger") { showNewLedger = true }
                .buttonStyle(.hvSecondary)
        }
        .hvCard()
    }

    // MARK: The stack

    private func stack(_ item: TruthDocketItem) -> some View {
        ZStack {
            if let next = model.deck.next {
                TruthCardView(item: next, replies: [])
                    .scaleEffect(0.95)
                    .offset(y: 10)
                    .opacity(0.55)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .frame(maxHeight: 220, alignment: .top)
                    .clipped()
            }
            TruthCardView(item: item, replies: model.answers[item.id] ?? [])
                .overlay(alignment: .top) { swipeHint }
                .offset(x: reduceMotion ? 0 : drag)
                .rotationEffect(.degrees(reduceMotion ? 0 : Double(drag) / 28), anchor: .bottom)
                .simultaneousGesture(swipe(item))
                .id(item.id)
                .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.97)), removal: .opacity))
                .accessibilityAction(named: "Approve") { open(.approve, item) }
                .accessibilityAction(named: "Defer for a week") { deferNow(item) }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.85), value: item.id)
    }

    @ViewBuilder
    private var swipeHint: some View {
        if drag > 40 {
            Label("Approve", systemImage: "checkmark.circle.fill")
                .font(.hvHeadline)
                .foregroundStyle(Palette.mint)
                .padding(HV.Space.s)
        } else if drag < -40 {
            Label("Defer", systemImage: "clock.fill")
                .font(.hvHeadline)
                .foregroundStyle(Palette.amber)
                .padding(HV.Space.s)
        }
    }

    private func swipe(_ item: TruthDocketItem) -> some Gesture {
        DragGesture(minimumDistance: 24)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                drag = value.translation.width
            }
            .onEnded { value in
                let width = value.translation.width
                let horizontal = abs(width) > abs(value.translation.height)
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { drag = 0 }
                guard horizontal else { return }
                if width > 110 {
                    open(.approve, item)
                } else if width < -110 {
                    deferNow(item)
                }
            }
    }

    // MARK: Actions

    private func actions(_ item: TruthDocketItem) -> some View {
        VStack(spacing: HV.Space.s) {
            LazyVGrid(columns: actionColumns, spacing: HV.Space.xs) {
                actionButton(.refute, item)
                actionButton(.deferral, item)
                actionButton(.strike, item)
                actionButton(.ask, item)
            }
            actionButton(.approve, item)
            ForEach(unavailableReasons(for: item), id: \.self) { reason in
                Text(reason)
                    .font(.hvCaption)
                    .foregroundStyle(Palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            DisclosureGroup(isExpanded: $showExplanations) {
                VStack(alignment: .leading, spacing: HV.Space.xs) {
                    ForEach(TruthAction.allCases) { action in
                        let state = model.state(of: action, for: item)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(state.label).font(.hvFootnote.weight(.semibold))
                            Text(state.explanation).font(.hvCaption).foregroundStyle(Palette.textSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.top, HV.Space.xs)
            } label: {
                Text("What do these do?").font(.hvFootnote).foregroundStyle(Palette.textSecondary)
            }
        }
    }

    /// Two buttons to a row, one at a large text size, where "Ask an agent" would not fit beside another.
    private var actionColumns: [GridItem] {
        let column = GridItem(.flexible(), spacing: HV.Space.xs)
        return dynamicTypeSize.isAccessibilitySize ? [column] : [column, column]
    }

    /// Why an action is not on offer, once each, so the person is not left guessing.
    private func unavailableReasons(for item: TruthDocketItem) -> [String] {
        let reasons: [String] = TruthAction.allCases.compactMap { action in
            let state = model.state(of: action, for: item)
            return state.isAvailable ? nil : state.unavailableReason
        }
        return reasons.uniqued()
    }

    @ViewBuilder
    private func actionButton(_ action: TruthAction, _ item: TruthDocketItem) -> some View {
        let state = model.state(of: action, for: item)
        let button = Button {
            if action == .deferral { deferNow(item) } else { open(action, item) }
        } label: {
            Label(state.label, systemImage: symbol(action))
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                .minimumScaleFactor(0.8)
        }
        .disabled(!state.isAvailable || model.isWorking)
        .accessibilityHint(state.explanation)
        if action == .approve {
            button.buttonStyle(.hvPrimary)
        } else {
            button.buttonStyle(.hvSecondary)
        }
    }

    private func symbol(_ action: TruthAction) -> String {
        switch action {
        case .approve: return "checkmark"
        case .refute: return "xmark"
        case .deferral: return "clock"
        case .strike: return "hammer"
        case .ask: return "bubble.left.and.bubble.right"
        }
    }

    private func open(_ action: TruthAction, _ item: TruthDocketItem) {
        guard model.state(of: action, for: item).isAvailable else {
            Haptics.warning()
            return
        }
        Haptics.tap()
        request = DecisionRequest(action: action, item: item)
    }

    /// Put it off for a week, at once, with a way to take it back.
    private func deferNow(_ item: TruthDocketItem) {
        guard model.state(of: .deferral, for: item).isAvailable, !model.isWorking else { return }
        Task {
            do {
                _ = try await model.decide(.deferral, item: item, draft: TruthDecisionDraft())
                Haptics.tap()
                onChange()
            } catch {
                if (error as? HVError)?.isTruthHandleRequired == true {
                    request = DecisionRequest(action: .deferral, item: item)
                } else {
                    app.toasts.show(error: error)
                }
            }
        }
    }

    // MARK: Done, and undo

    private var finished: some View {
        VStack(spacing: HV.Space.m) {
            HVEmptyState(
                symbol: "checkmark.seal",
                title: "Nothing waits on you.",
                message: model.deck.dealtWith > 0 ? "That was the last card. Deferred ones come back when their time does." : "The docket is clear.",
                actionTitle: model.isHosted ? "Assert something" : nil
            ) { showAssert = true }
        }
    }

    @ViewBuilder
    private var undoBar: some View {
        if let last = model.deferral {
            HStack(spacing: HV.Space.s) {
                Image(systemName: "clock.fill").foregroundStyle(Palette.amber)
                Text("Put off for a week.").font(.hvSubheadline)
                Spacer()
                Button("Undo") {
                    Haptics.tap()
                    Task {
                        do { try await model.undoDeferral() } catch { app.toasts.show(error: error) }
                    }
                }
                .buttonStyle(.hvGhost)
                Button {
                    model.dismissUndo()
                } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).frame(width: 44, height: 44)
                }
                .accessibilityLabel("Dismiss")
            }
            .padding(.horizontal, HV.Space.m)
            .padding(.vertical, HV.Space.xxs)
            .hvGlass(radius: 22)
            .padding(.horizontal, HV.Space.m)
            .padding(.bottom, HV.Space.xs)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .id(last.itemID)
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Menu {
                ForEach(model.ledgers) { ledger in
                    Button {
                        Haptics.select()
                        Task { await model.select(slug: ledger.slug) }
                    } label: {
                        if ledger.slug == model.ledger?.slug {
                            Label("\(ledger.name) (\(ledger.kind.title.lowercased()))", systemImage: "checkmark")
                        } else {
                            Text("\(ledger.name) (\(ledger.kind.title.lowercased()))")
                        }
                    }
                }
                Divider()
                Button { showNewLedger = true } label: { Label("New hosted ledger", systemImage: "plus") }
            } label: {
                VStack(spacing: 0) {
                    Text("Review").font(.hvHeadline).foregroundStyle(Palette.textPrimary)
                    HStack(spacing: 3) {
                        Text(model.ledger?.name ?? "Ledger").lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                    }
                    .font(.hvCaption)
                    .foregroundStyle(Palette.textSecondary)
                }
                .frame(minHeight: 44)
            }
            .accessibilityLabel("Ledger: \(model.ledger?.name ?? "none")")
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                Picker("Remind me", selection: Binding(
                    get: { model.schedule.cadence },
                    set: { setCadence($0) }
                )) {
                    Text("No reminder").tag(TruthCadence?.none)
                    ForEach(TruthCadence.allCases) { cadence in
                        Text(cadence.title).tag(TruthCadence?.some(cadence))
                    }
                }
                if model.isHosted {
                    Button { showAssert = true } label: { Label("Assert a TB or UV", systemImage: "plus.circle") }
                }
            } label: {
                Image(systemName: "ellipsis.circle").frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("More")
        }
    }

    private func setCadence(_ cadence: TruthCadence?) {
        Task {
            do { try await model.setCadence(cadence); Haptics.select() } catch { app.toasts.show(error: error) }
        }
    }
}

private extension Array where Element: Hashable {
    /// The elements once each, in order.
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

#if DEBUG
#Preview("Review") {
    PreviewHost(routes: TruthPreviewData.reviewRoutes) { TruthReviewView() }
}
#endif
