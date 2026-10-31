import HyperVaultKit
import SwiftUI

/// Yours, the panel Home opens from its corner icon: everything that has been kept, newest used first. Tapping a thing, or
/// choosing "Put on the page" on it, puts it on the page; "Open" opens it where it lives. The Library, the longer list,
/// is under More.
struct YoursSheet: View {
    let onPull: (KeptItem) -> Void
    let onNew: () -> Void
    let onLibrary: () -> Void

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        YoursSheetContent(
            client: env.client, cache: env.cache, namespace: env.user.id, baseURL: env.server.baseURL,
            onPull: onPull, onNew: onNew, onLibrary: onLibrary, onClose: { dismiss() }
        )
    }
}

private struct YoursSheetContent: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var model: YoursModel
    let baseURL: URL
    let onPull: (KeptItem) -> Void
    let onNew: () -> Void
    let onLibrary: () -> Void
    let onClose: () -> Void

    init(
        client: HVClient, cache: DiskCache, namespace: String, baseURL: URL,
        onPull: @escaping (KeptItem) -> Void, onNew: @escaping () -> Void, onLibrary: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        _model = State(initialValue: YoursModel(client: client, cache: cache, namespace: namespace))
        self.baseURL = baseURL
        self.onPull = onPull
        self.onNew = onNew
        self.onLibrary = onLibrary
        self.onClose = onClose
    }

    var body: some View {
        NavigationStack {
            YoursListView(model: model, baseURL: baseURL, onSelect: onPull, onPull: onPull, onOpen: open)
            .navigationTitle(HVCopy.panelTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("New", action: onNew)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Button(action: onLibrary) { Label("Library", systemImage: "folder") }
                            .accessibilityIdentifier("yours.library")
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("More")
                    .accessibilityIdentifier("yours.more")
                    Button("Done", action: onClose)
                }
            }
        }
        // Half height shows no row at accessibility text sizes, where the search and the filter fill it: open at full height.
        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
        .presentationDragIndicator(.visible)
    }

    /// Opens the thing where it lives, and closes the panel so what opens is not under it.
    private func open(_ item: KeptItem) {
        model.markOpened(item)
        onClose()
        switch item.kind {
        case .page, .file, .group:
            if let slug = item.slug { app.router.open(.route(.artifact(slug: slug))) }
        case .memory:
            app.router.open(.route(.memory(id: item.id)))
        case .key:
            app.router.open(.account(.vault))
        }
    }
}

/// The list itself: filters, search, Recent and the rest, with its loading, empty and error states.
struct YoursListView: View {
    @Bindable var model: YoursModel
    let baseURL: URL
    let onSelect: (KeptItem) -> Void
    let onPull: (KeptItem) -> Void
    /// Opens the thing where it lives, for the row's menu.
    let onOpen: (KeptItem) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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
                    message: model.isEmptyVault ? "Ask your AI to keep something, or paste it on the page." : nil
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
                    Text(HVCopy.libraryTruncatedLine).font(.hvCaption).hvSectionNote()
                }
            }
        }
    }

    private func row(_ item: KeptItem) -> some View {
        let ago = (item.lastOpenedAt ?? item.updatedAt).map { HVCopy.ago(since: $0) }
        // At an accessibility size the time beside the words would leave the name a sliver ("land-/ing", "30 / min ago"),
        // so it follows the line under the name instead, as the Library's rows do.
        let stacksTime = dynamicTypeSize.isAccessibilitySize
        return Button { onSelect(item) } label: {
            HVRow(
                symbol: item.kind.symbol, title: item.name,
                subtitle: stacksTime ? [subtitle(for: item), ago].compactMap { $0 }.joined(separator: " \u{00B7} ") : subtitle(for: item)
            ) {
                if !stacksTime, let ago {
                    Text(ago).font(.hvCaption).foregroundStyle(Palette.textTertiary)
                }
            }
        }
        .buttonStyle(.plain)
        .hvListRow()
        .contextMenu {
            Button("Put on the page", systemImage: "rectangle.on.rectangle") { onPull(item) }
            Button("Open", systemImage: "arrow.up.forward.square") { onOpen(item) }
            if let url = link(for: item) {
                ShareLink(item: url) { Label("Share link", systemImage: "square.and.arrow.up") }
                Button("Copy link", systemImage: HVSymbol.copy) { UIPasteboard.general.string = url.absoluteString }
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
