import HyperVaultKit
import SwiftUI
import UIKit

/// Truth: what you have asserted, what rests on it, and what waits on you. TB is
/// a signed ground truth; UV is an unverified assertion. Standing says what has
/// happened beneath an entry, in words.
struct TruthRootView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        TruthScreen(client: env.client, cache: env.cache, namespace: env.user.id)
    }
}

/// Where the ledger page goes next.
enum TruthDestination: Hashable {
    case entry(TruthEntryRef)
    case review
}

/// The screens behind the "more" menu.
enum TruthMore: Hashable, Identifiable {
    case drafts, notices, stale, signers, sidecar

    var id: Self { self }
}

struct TruthEntryRef: Hashable {
    let row: TruthEntryRow
    let ledger: String
    let isHosted: Bool
}

struct TruthScreen: View {
    @Environment(AppModel.self) private var app
    @State private var model: TruthModel
    @AppStorage("pref.truth.ledger") private var storedLedger = ""
    @State private var showAssert = false
    @State private var showImport = false
    @State private var showNewLedger = false
    @State private var historyOpen = false
    @State private var more: TruthMore?
    @State private var shared: TruthSharedFile?
    private let client: HVClient

    init(client: HVClient, cache: DiskCache, namespace: String) {
        self.client = client
        _model = State(initialValue: TruthModel(client: client, cache: cache, namespace: namespace))
    }

    var body: some View {
        content
            .hvScreenBackground()
            .navigationTitle("Truth")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .task { await model.start(preferring: storedLedger.isEmpty ? nil : storedLedger) }
            .onChange(of: model.activeSlug) { _, slug in if let slug { storedLedger = slug } }
            .navigationDestination(for: TruthDestination.self) { destination in
                destinationView(destination)
            }
            .navigationDestination(item: $more) { destination in
                moreView(destination)
            }
            .sheet(isPresented: $showAssert) {
                if let ledger = model.active {
                    TruthAssertView(client: client, ledger: ledger) {
                        Task { await model.changed() }
                    }
                }
            }
            .sheet(isPresented: $showImport) {
                if let ledger = model.active {
                    TruthImportView(ledger: ledger, onStream: { try await model.importStream($0) }, onPage: { try await model.importPage(slug: $0, jsonl: $1) })
                }
            }
            .sheet(isPresented: $showNewLedger) {
                TruthNewLedgerView { slug, name, kind in
                    try await model.createLedger(slug: slug, name: name, kind: kind)
                    Haptics.success()
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(item: $shared) { file in
                TruthActivitySheet(items: [file.url])
            }
    }

    // MARK: States

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            VStack {
                HVListSkeleton(rows: 5).padding(.top, HV.Space.m)
                Spacer()
            }
        case .failed(let message):
            HVErrorState(message: message) { Task { await model.refresh() } }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            list
        }
    }

    private var list: some View {
        List {
            if model.isShowingSavedCopy {
                HVStaleBanner()
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            headerRows
            let sections = model.sections
            if sections.isEmpty {
                emptyState
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            } else {
                entriesSection(title: "Standing", note: "Signed truth, with the UVs disputing it underneath.", rows: sections.standing, empty: "No signed truth yet.")
                entriesSection(title: "Unverified", note: "Believed, not yet checked. Never shown as proven.", rows: sections.unverified, empty: "Nothing unverified.")
                historySection(sections.history)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .refreshable { await model.refresh() }
    }

    // MARK: Header

    @ViewBuilder
    private var headerRows: some View {
        if let overview = model.overview {
            // Its own section: a bare row at the top of the card below would take the card's rounded corners
            // and leave the visible rows square.
            Section {
                VStack(alignment: .leading, spacing: HV.Space.s) {
                    HStack(alignment: .firstTextBaseline, spacing: HV.Space.xs) {
                        Text(model.active?.name ?? "Ledger").font(.hvTitle)
                        if let kind = model.active?.kind { HVTag(text: kind.title, tint: kind == .hosted ? Palette.blue : Palette.textSecondary) }
                    }
                    TruthSummaryStats(summary: overview.summary)
                    Text(model.active?.isHosted == true
                        ? "Written here: you and your agents assert into it, and the review decides it."
                        : "A mirror of a stenographer stream. Import to update it; decide its items there.")
                        .font(.hvFootnote)
                        .foregroundStyle(Palette.textSecondary)
                }
                .padding(.vertical, HV.Space.xxs)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }

            Section {
                NavigationLink(value: TruthDestination.review) {
                    docketRow(overview)
                }
                .hvListRow()

                Toggle(isOn: Binding(get: { overview.chatTruth }, set: { setCiting($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Cite in chat")
                        Text("Put the ledger at the head of every chat turn, so a signed TB outranks recalled memory.")
                            .font(.hvCaption)
                            .foregroundStyle(Palette.textSecondary)
                    }
                }
                .disabled(model.isCiteBusy)
                .hvListRow()
            }
        }
    }

    /// The row to the review. Its second line is the whole sentence about what waits, never cut short: the
    /// shared row stops at two lines, and "1 nominated by ag..." loses what it was there to say.
    private func docketRow(_ overview: TruthOverview) -> some View {
        HStack(spacing: HV.Space.s + 2) {
            HVIconBadge(symbol: "checklist", tint: Palette.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(overview.review?.due == true ? "A review is due" : "Review docket")
                    .font(.hvBody)
                    .foregroundStyle(Palette.textPrimary)
                Text(overview.docket?.sentence ?? "Open UVs, appeals and reviews, one card at a time.")
                    .font(.hvFootnote)
                    .foregroundStyle(Palette.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.active?.isHosted == true {
            HVEmptyState(
                symbol: "checkmark.seal",
                title: "Nothing asserted yet.",
                message: "Say something you are sure of (a TB) or something you believe (a UV). Your agents can add UVs too.",
                actionTitle: "Assert something"
            ) { showAssert = true }
        } else {
            HVEmptyState(
                symbol: "tray.and.arrow.down",
                title: "Nothing in this ledger yet.",
                message: "Import a stenographer export to fill it.",
                actionTitle: "Import"
            ) { showImport = true }
        }
    }

    // MARK: Entries

    @ViewBuilder
    private func entriesSection(title: String, note: String, rows: [TruthEntryRow], empty: String) -> some View {
        Section {
            if rows.isEmpty {
                Text(empty).font(.hvCallout).foregroundStyle(Palette.textSecondary).hvListRow()
            } else {
                ForEach(rows) { row in
                    NavigationLink(value: TruthDestination.entry(ref(row))) {
                        TruthEntryRowView(row: row)
                    }
                    .hvListRow()
                }
            }
        } header: {
            VStack(alignment: .leading, spacing: 2) {
                HVSectionHeader(title: title, detail: "\(rows.count)")
                Text(note).font(.hvCaption).foregroundStyle(Palette.textSecondary).textCase(nil)
            }
        }
    }

    @ViewBuilder
    private func historySection(_ rows: [TruthEntryRow]) -> some View {
        if !rows.isEmpty {
            Section {
                if historyOpen {
                    ForEach(rows) { row in
                        NavigationLink(value: TruthDestination.entry(ref(row))) {
                            TruthEntryRowView(row: row).opacity(0.8)
                        }
                        .hvListRow()
                    }
                }
            } header: {
                Button {
                    Haptics.select()
                    withAnimation(.easeOut(duration: 0.2)) { historyOpen.toggle() }
                } label: {
                    HStack {
                        HVSectionHeader(title: "History", detail: "\(rows.count)")
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .bold))
                            .rotationEffect(.degrees(historyOpen ? 0 : -90))
                            .foregroundStyle(Palette.textSecondary)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(historyOpen ? "Hides what was overturned, refuted or verified" : "Shows what was overturned, refuted or verified")
            } footer: {
                if historyOpen {
                    Text("Overridden, refuted and verified entries, and anything that no longer stands. Kept for the record, never cited.")
                        .font(.hvCaption)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
        }
    }

    private func ref(_ row: TruthEntryRow) -> TruthEntryRef {
        TruthEntryRef(row: row, ledger: model.active?.slug ?? "default", isHosted: model.active?.isHosted == true)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) { ledgerMenu }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if model.active?.isHosted == true {
                    Button { showAssert = true } label: { Label("Assert a TB or UV", systemImage: "plus.circle") }
                }
                Button { showImport = true } label: { Label("Import", systemImage: "square.and.arrow.down") }
                Button { exportStream() } label: { Label("Export this ledger", systemImage: "square.and.arrow.up") }
                Divider()
                Button { more = .drafts } label: { Label("Drafts", systemImage: "doc.text") }
                Button { more = .notices } label: { Label("Notices", systemImage: "bell") }
                Button { more = .stale } label: { Label("Out of date", systemImage: "clock.arrow.circlepath") }
                Button { more = .signers } label: { Label("Signers", systemImage: "signature") }
                if model.overview?.sidecar.configured == true {
                    Button { more = .sidecar } label: { Label("Sidecar inbox", systemImage: "tray") }
                }
            } label: {
                Image(systemName: "ellipsis.circle").frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("More")
        }
    }

    private var ledgerMenu: some View {
        Menu {
            ForEach(model.ledgers) { ledger in
                Button {
                    Haptics.select()
                    Task { await model.select(slug: ledger.slug) }
                } label: {
                    if ledger.slug == model.activeSlug {
                        Label("\(ledger.name) (\(ledger.kind.title.lowercased()))", systemImage: "checkmark")
                    } else {
                        Text("\(ledger.name) (\(ledger.kind.title.lowercased()))")
                    }
                }
            }
            Divider()
            Button { showNewLedger = true } label: { Label("New ledger", systemImage: "plus") }
        } label: {
            VStack(spacing: 0) {
                Text("Truth").font(.hvHeadline).foregroundStyle(Palette.textPrimary)
                HStack(spacing: 3) {
                    Text(model.active?.name ?? "Ledger").lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                }
                .font(.hvCaption)
                .foregroundStyle(Palette.textSecondary)
            }
            .frame(minHeight: 44)
        }
        .accessibilityLabel("Ledger: \(model.active?.name ?? "none")")
        .accessibilityHint("Choose another ledger")
    }

    @ViewBuilder
    private func destinationView(_ destination: TruthDestination) -> some View {
        switch destination {
        case .entry(let ref):
            TruthEntryScreen(client: client, ref: ref) { Task { await model.changed() } }
        case .review:
            TruthReviewScreen(client: client, preferring: model.activeSlug) { Task { await model.changed() } }
        }
    }

    @ViewBuilder
    private func moreView(_ destination: TruthMore) -> some View {
        switch destination {
        case .drafts:
            TruthDraftsScreen(client: client, ledger: model.activeSlug ?? "default") { Task { await model.changed() } }
        case .notices:
            TruthNoticesScreen(client: client, ledger: model.active)
        case .stale:
            TruthStaleScreen(client: client)
        case .signers:
            TruthSignersScreen(client: client)
        case .sidecar:
            TruthSidecarScreen(client: client)
        }
    }

    // MARK: Actions

    private func setCiting(_ on: Bool) {
        Task {
            do { try await model.setCiteInChat(on); Haptics.select() } catch { app.toasts.show(error: error) }
        }
    }

    private func exportStream() {
        Task {
            do { shared = TruthSharedFile(url: try await model.exportStream()) } catch { app.toasts.show(error: error) }
        }
    }
}

#if DEBUG
#Preview("Ledger") {
    PreviewHost(routes: TruthPreviewData.ledgerRoutes) { TruthRootView() }
}
#endif
