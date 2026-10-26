import HyperVaultKit
import SwiftUI

/// The second tab: everything that has been kept, newest used first.
struct YoursRootView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        YoursTab(client: env.client, cache: env.cache, namespace: env.user.id, baseURL: env.server.baseURL)
    }
}

private struct YoursTab: View {
    @Environment(AppModel.self) private var app
    @State private var model: YoursModel
    let baseURL: URL

    init(client: HVClient, cache: DiskCache, namespace: String, baseURL: URL) {
        _model = State(initialValue: YoursModel(client: client, cache: cache, namespace: namespace))
        self.baseURL = baseURL
    }

    var body: some View {
        YoursListView(model: model, baseURL: baseURL, onSelect: open, onPull: pull)
            .navigationTitle(HVCopy.panelTitle)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        app.router.canvasAsk = true
                        app.router.tab = .canvas
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New")
                    .accessibilityIdentifier("yours.new")
                }
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink(value: Route.library) {
                        Text("Library").font(.system(.subheadline, design: .rounded, weight: .semibold))
                    }
                    .accessibilityIdentifier("yours.library")
                }
            }
    }

    private func open(_ item: KeptItem) {
        model.markOpened(item)
        switch item.kind {
        case .page, .file, .group:
            if let slug = item.slug { app.router.push(.artifact(slug: slug), on: .yours) }
        case .memory:
            app.router.open(.route(.memory(id: item.id)))
        case .key:
            app.router.open(.route(.vaultItems))
        }
    }

    private func pull(_ item: KeptItem) {
        app.router.canvasPull = item
        app.router.tab = .canvas
    }
}

/// The panel the canvas opens from its corner icon. Tapping a thing, or choosing "Put on the canvas"
/// on it, puts it on the page; `onPull` is where that notes the open.
struct YoursSheet: View {
    let onPull: (KeptItem) -> Void
    let onNew: () -> Void

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        YoursSheetContent(client: env.client, cache: env.cache, namespace: env.user.id, baseURL: env.server.baseURL, onPull: onPull, onNew: onNew, onClose: { dismiss() })
    }
}

private struct YoursSheetContent: View {
    @State private var model: YoursModel
    let baseURL: URL
    let onPull: (KeptItem) -> Void
    let onNew: () -> Void
    let onClose: () -> Void

    init(client: HVClient, cache: DiskCache, namespace: String, baseURL: URL, onPull: @escaping (KeptItem) -> Void, onNew: @escaping () -> Void, onClose: @escaping () -> Void) {
        _model = State(initialValue: YoursModel(client: client, cache: cache, namespace: namespace))
        self.baseURL = baseURL
        self.onPull = onPull
        self.onNew = onNew
        self.onClose = onClose
    }

    var body: some View {
        NavigationStack {
            YoursListView(model: model, baseURL: baseURL, onSelect: onPull, onPull: onPull)
            .navigationTitle(HVCopy.panelTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("New", action: onNew)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: onClose)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

/// The list itself: filters, search, Recent and the rest, with its loading, empty and error states.
struct YoursListView: View {
    @Bindable var model: YoursModel
    let baseURL: URL
    let onSelect: (KeptItem) -> Void
    let onPull: (KeptItem) -> Void

    var body: some View {
        List {
            Section {
                HVChoicePicker(title: "Show", selection: $model.filter) {
                    ForEach(YoursFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .accessibilityIdentifier("yours.filter")
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: HV.Space.xs, leading: HV.Space.m, bottom: HV.Space.xs, trailing: HV.Space.m))
            }
            content
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .hvScreenBackground()
        .searchable(text: $model.query, placement: .navigationBarDrawer(displayMode: .always), prompt: HVCopy.yoursSearchLabel)
        .refreshable { await model.reload() }
        .task(id: reloadKey) { await model.reload() }
        .onChange(of: model.filter) { _, _ in Haptics.select() }
    }

    /// Changes whenever the list has to be read again.
    private var reloadKey: String { "\(model.filter.rawValue)|\(model.query)" }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            Section { HVListSkeleton(rows: 5).listRowInsets(EdgeInsets()).listRowBackground(Color.clear) }
        case .failed(let message):
            Section {
                HVErrorState(message: message, retryTitle: HVCopy.tryAgainLabel) { Task { await model.retry() } }
                    .listRowBackground(Color.clear)
            }
        case .loaded:
            loaded
        }
    }

    @ViewBuilder
    private var loaded: some View {
        if model.isStale {
            Section { HVStaleBanner().listRowBackground(Color.clear).listRowInsets(EdgeInsets()) }
        }
        if model.results.isEmpty {
            Section {
                HVEmptyState(
                    symbol: model.isEmptyVault ? "tray" : "magnifyingglass",
                    title: model.isEmptyVault ? HVCopy.emptyPanel : HVCopy.yoursNothingHereLine,
                    message: model.isEmptyVault ? "Ask your AI to keep something, or paste it on the canvas." : nil
                )
                .listRowBackground(Color.clear)
            }
        } else if !model.isSearching, model.filter == .all, !model.recent.isEmpty {
            Section(header: HVSectionHeader(title: HVCopy.recentHeading)) {
                ForEach(model.recent) { item in row(item) }
            }
            if !model.everythingElse.isEmpty {
                Section(header: HVSectionHeader(title: "Everything")) {
                    ForEach(model.everythingElse) { item in row(item) }
                }
            }
        } else {
            Section {
                ForEach(model.results) { item in row(item) }
            } footer: {
                if model.results.count >= YoursModel.pageLimit {
                    Text(HVCopy.libraryTruncatedLine).font(.hvCaption)
                }
            }
        }
    }

    private func row(_ item: KeptItem) -> some View {
        Button { onSelect(item) } label: {
            HVRow(symbol: item.kind.symbol, tint: item.kind.tint, title: item.name, subtitle: subtitle(for: item)) {
                if let when = item.lastOpenedAt ?? item.updatedAt {
                    Text(HVCopy.ago(since: when)).font(.hvCaption).foregroundStyle(Palette.textTertiary)
                }
            }
        }
        .buttonStyle(.plain)
        .hvListRow()
        .contextMenu {
            Button("Put on the canvas", systemImage: "rectangle.on.rectangle") { onPull(item) }
            if let url = link(for: item) {
                ShareLink(item: url) { Label("Share link", systemImage: "square.and.arrow.up") }
                Button("Copy link", systemImage: "link") { UIPasteboard.general.string = url.absoluteString }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("yours.row.\(item.id)")
    }

    private func subtitle(for item: KeptItem) -> String {
        item.summary.isEmpty ? item.kind.singular : item.summary
    }

    /// The permanent link for a page, file or group; a memory and a key have none to hand out.
    private func link(for item: KeptItem) -> URL? {
        guard item.kind == .page || item.kind == .file || item.kind == .group, !item.href.isEmpty else { return nil }
        return URL(string: baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + item.href)
    }
}
