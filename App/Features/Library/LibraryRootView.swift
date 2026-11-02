import HyperVaultKit
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The Library: everything kept, behind the same four filters and the same
/// search by name as Yours, with Files as the file manager. Pushed from the
/// You tab and from Yours' "More".
struct LibraryRootView: View {
    @Environment(AppEnvironment.self) private var env
    /// What a link chose (the web's `?filter=` and `?q=`). The Library a person opens themselves shows All, nothing typed.
    var filter: YoursFilter = .all
    var query = ""

    var body: some View {
        LibraryScreen(env: env, filter: filter, query: query)
            .jobNotices()
    }
}

/// What the Library presents over itself.
enum LibrarySheet: Identifiable {
    case newPage
    case newGroup
    case share(ArtifactShareTarget)

    var id: String {
        switch self {
        case .newPage: return "newPage"
        case .newGroup: return "newGroup"
        case .share(let target): return "share-\(target.id)"
        }
    }
}

struct LibraryScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(AppEnvironment.self) private var env
    @AppStorage("pref.libraryGraph") private var showGraph = false
    @State private var model: LibraryModel
    @State private var filter: YoursFilter
    @State private var query: String
    /// Set when a link chose the filter or the search: the list shows them and the graph does not, so the list is what opens,
    /// whatever the person last left the Library on. Their saved choice is not changed; the view button hands the screen back.
    @State private var openedByLink: Bool
    @State private var sheet: LibrarySheet?
    @State private var pendingDelete: LibraryModel.FileRow?
    @State private var pendingPublic: LibraryModel.FileRow?
    @State private var leaving: SharedWithYouItem?
    @State private var importingFile = false
    @State private var showPhotos = false
    @State private var photo: PhotosPickerItem?

    init(env: AppEnvironment, filter: YoursFilter = .all, query: String = "") {
        self.init(model: LibraryModel(env: env), filter: filter, query: query)
    }

    init(model: LibraryModel, filter: YoursFilter = .all, query: String = "") {
        _model = State(initialValue: model)
        _filter = State(initialValue: filter)
        _query = State(initialValue: query)
        _openedByLink = State(initialValue: Self.linkNamesWhatToShow(filter: filter, query: query))
    }

    /// Whether a link that arrived with this filter and search named something the list has and the graph does not.
    static func linkNamesWhatToShow(filter: YoursFilter, query: String) -> Bool {
        filter != .all || !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The graph, unless the person chose it earlier and a link has since asked for the list.
    private var graphShown: Bool { showGraph && !openedByLink }

    /// What makes the list read again: a different filter, or a name (after a pause).
    private struct LoadKey: Hashable {
        let filter: YoursFilter
        let query: String
    }

    /// Files are searched where they are (every page is already here), so typing does not read them again.
    private var loadKey: LoadKey {
        LoadKey(filter: filter, query: filter == .file ? "" : query.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var body: some View {
        Group {
            if graphShown { graphView } else { listView }
        }
            .sheet(item: $sheet) { sheet in sheetContent(sheet) }
            .fileImporter(isPresented: $importingFile, allowedContentTypes: [.pdf, .image], allowsMultipleSelection: false) { result in
                importFile(result)
            }
            .photosPicker(isPresented: $showPhotos, selection: $photo, matching: .images)
            .onChange(of: photo) { _, item in
                guard let item else { return }
                photo = nil
                importPhoto(item)
            }
            .modifier(LibraryConfirmations(
                pendingDelete: $pendingDelete, pendingPublic: $pendingPublic, leaving: $leaving,
                onDelete: { delete($0) },
                onPublic: { setVisibility($0, .public) },
                onLeave: { item in Task { await model.leave(item, toasts: app.toasts) } }
            ))
            .overlay(alignment: .bottom) { busyBanner }
            // A job that changed something has been dismissed: read the list again, as pulling it down does.
            .onChange(of: env.jobNotices.changes) { _, _ in
                Task { await model.refresh(filter: filter, query: query) }
            }
    }

    private var listView: some View {
        List {
            filterSection
            if model.isStale {
                Section { HVStaleBanner().listRowBackground(Color.clear).listRowInsets(EdgeInsets()) }
            }
            content
        }
        // The same grouped cards, paper rows and segmented filter as Yours: one list language.
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .hvScreenBackground()
        .navigationTitle(LibraryCopy.title)
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: LibraryCopy.searchLabel)
        .toolbar { toolbar }
        .refreshable { await model.refresh(filter: filter, query: query) }
        .task(id: loadKey) {
            // A pause in typing, then the search; typing again cancels this one.
            if !loadKey.query.isEmpty {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
            }
            await model.load(filter: filter, query: loadKey.query)
        }
        .task { await model.loadExtras() }
        .onChange(of: filter) { _, _ in Haptics.select() }
    }

    // MARK: Chrome

    /// Every page beside every memory, and the links among them (the Memory tab draws the memories alone).
    private var graphView: some View {
        LibraryGraphScreen(env: env)
            .hvScreenBackground()
            .navigationTitle(LibraryCopy.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
    }

    private var filterSection: some View {
        Section {
            filterPicker
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: HV.Space.xs, leading: HV.Space.m, bottom: HV.Space.xs, trailing: HV.Space.m))
        }
    }

    /// Four words fit a segmented control until the type gets very large; there a menu takes over.
    private var filterPicker: some View {
        HVChoicePicker(title: LibraryCopy.filterGroupLabel, selection: $filter) {
            ForEach(YoursFilter.allCases) { option in Text(option.title).tag(option) }
        }
        .accessibilityIdentifier("library.filter")
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // Pins can be put in the order the person likes (the side menu keeps the same order).
        ToolbarItem(placement: .topBarLeading) {
            if !graphShown, model.pins.artifactSlugs.count > 1, filter == .all || filter == .file, query.isEmpty {
                EditButton()
            }
        }
        // Mail is its own place, not a fifth way to filter what is kept.
        ToolbarItem(placement: .primaryAction) {
            NavigationLink(value: Route.mail) {
                Image(systemName: "envelope")
            }
            .accessibilityLabel("Mail")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                Haptics.select()
                HV.Motion.animate {
                    let wasGraph = graphShown
                    openedByLink = false
                    showGraph = !wasGraph
                }
            } label: {
                Image(systemName: graphShown ? "list.bullet" : "point.3.connected.trianglepath.dotted")
            }
            .accessibilityLabel(graphShown ? "Show as a list" : "Show as a graph")
            .accessibilityIdentifier("library.view")
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button { sheet = .newPage } label: { Label("A page from text or a file", systemImage: "doc.badge.plus") }
                Button { sheet = .newGroup } label: { Label("A group of files", systemImage: "folder.badge.plus") }
                Button { importingFile = true } label: { Label("A PDF or an image", systemImage: "arrow.up.doc") }
                Button { showPhotos = true } label: { Label("A photo", systemImage: "photo") }
            } label: {
                Label(LibraryCopy.newLabel, systemImage: HVSymbol.add)
            }
            .accessibilityLabel(LibraryCopy.newLabel)
        }
    }

    @ViewBuilder
    private var busyBanner: some View {
        if let busy = model.busy {
            HStack(spacing: HV.Space.xs) {
                ProgressView()
                Text(busy).font(.hvFootnote)
            }
            .padding(.horizontal, HV.Space.m)
            .padding(.vertical, HV.Space.xs)
            .hvGlass(radius: HV.Radius.floating)
            .padding(.bottom, HV.Space.m)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: Content

    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Pinned pages and pages shared with the person sit above the list, for the two filters that hold pages.
    private var showsShortcuts: Bool {
        !isSearching && (filter == .all || filter == .file) && (!model.pinnedRows.isEmpty || !model.sharedWithYou.isEmpty)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            Section { HVListSkeleton(rows: 6).listRowInsets(EdgeInsets()).listRowBackground(Color.clear) }
        case .failed(let message):
            Section {
                // A lost connection gets the connection's glyph; anything the server answered gets a plain notice.
                HVErrorState(message: message, symbol: model.failureIsOffline ? "wifi.exclamationmark" : "exclamationmark.circle") {
                    Task { await model.load(filter: filter, query: query) }
                }
                .listRowBackground(Color.clear)
            }
        case .loaded:
            if showsShortcuts {
                pinnedSection
                sharedSection
            }
            if filter == .file { fileRows } else { itemRows }
        }
    }

    /// The list proper. Under pinned and shared pages it needs a heading of its own; alone it does not.
    @ViewBuilder
    private func listSection<Rows: View, Footer: View>(
        @ViewBuilder rows: () -> Rows, @ViewBuilder footer: () -> Footer
    ) -> some View {
        if showsShortcuts {
            Section { rows() } header: { HVSectionHeader(title: "Everything") } footer: { footer() }
        } else {
            Section { rows() } footer: { footer() }
        }
    }

    // MARK: Yours rows

    @ViewBuilder
    private var itemRows: some View {
        if model.items.isEmpty {
            emptyState
        } else {
            let visible = Array(model.items.prefix(model.shown))
            listSection {
                ForEach(visible) { item in
                    // A button that pushes, like the rows of Yours: a link with a tap gesture beside it to stamp the
                    // open did not open anything on iOS 26 (the UI tests tapped the row and nothing came of it).
                    Button {
                        model.stampOpen(item)
                        open(item)
                    } label: {
                        LibraryItemRow(item: item, showsChevron: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("library.row.\(item.id)")
                    .libraryRow()
                    .contextMenu { itemMenu(item) }
                }
            } footer: {
                truncationNote(count: model.items.count)
            }
            showMore(count: model.items.count)
        }
    }

    /// A key opens the Vault pane of the You tab; everything else is pushed on this screen's stack.
    private func open(_ item: KeptItem) {
        switch item.kind {
        case .memory: app.router.push(.memory(id: item.id))
        case .key: app.router.open(.account(.vault))
        case .page, .file, .group: app.router.push(item.slug.map { .artifact(slug: $0) } ?? .library)
        }
    }

    @ViewBuilder
    private func itemMenu(_ item: KeptItem) -> some View {
        if let slug = item.slug, item.kind != .memory, item.kind != .key {
            let url = ArtifactLinks.url(slug: slug, isGroup: item.kind == .group, appURL: model.env.server.baseURL)
            ShareLink(item: url) { Label("Share link", systemImage: "square.and.arrow.up") }
            Button {
                ArtifactPasteboard.copy(url.absoluteString)
                Haptics.tap()
                app.toasts.show(LibraryCopy.linkCopied, style: .info)
            } label: {
                Label(LibraryCopy.copyLink, systemImage: HVSymbol.copy)
            }
        }
    }

    // MARK: File manager rows

    @ViewBuilder
    private var fileRows: some View {
        let rows = model.rows(matching: query)
        if rows.isEmpty {
            emptyState
        } else {
            listSection {
                ForEach(rows.prefix(model.shown)) { row in
                    NavigationLink(value: Route.artifact(slug: row.summary.slug)) {
                        LibraryFileRow(row: row)
                    }
                    .libraryRow()
                    .swipeActions(edge: .leading, allowsFullSwipe: true) { visibilitySwipe(row) }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) { pendingDelete = row } label: { Label("Delete", systemImage: HVSymbol.delete) }
                        Button { share(row) } label: { Label("Share", systemImage: "square.and.arrow.up") }
                            .tint(Palette.blue)
                    }
                    .contextMenu { fileMenu(row) }
                }
            } footer: {
                truncationNote(count: rows.count, files: true)
            }
            showMore(count: rows.count)
        }
    }

    @ViewBuilder
    private func visibilitySwipe(_ row: LibraryModel.FileRow) -> some View {
        if row.summary.visibility == .public {
            Button { setVisibility(row, .private) } label: { Label("Make private", systemImage: ArtifactVisibility.private.symbol) }
                .tint(Palette.blue)
        } else {
            Button { pendingPublic = row } label: { Label("Make public", systemImage: "globe") }
                .tint(Palette.mint)
        }
    }

    @ViewBuilder
    private func fileMenu(_ row: LibraryModel.FileRow) -> some View {
        let url = link(for: row.summary)
        ShareLink(item: url) { Label("Share link", systemImage: "square.and.arrow.up") }
        Button {
            ArtifactPasteboard.copy(url.absoluteString)
            Haptics.tap()
            app.toasts.show(LibraryCopy.linkCopied, style: .info)
        } label: {
            Label(LibraryCopy.copyLink, systemImage: HVSymbol.copy)
        }
        Button {
            Task { await model.togglePin(slug: row.summary.slug, toasts: app.toasts) }
        } label: {
            Label(model.pins.contains(artifact: row.summary.slug) ? "Unpin" : "Pin", systemImage: model.pins.contains(artifact: row.summary.slug) ? "pin.slash" : "pin")
        }
        Menu {
            ForEach(ArtifactVisibility.allCases, id: \.self) { option in
                Button {
                    if option == .public { pendingPublic = row } else { setVisibility(row, option) }
                } label: {
                    Label(option.title, systemImage: option == row.summary.visibility ? "checkmark" : option.symbol)
                }
            }
        } label: {
            Label("Who can open it", systemImage: "lock")
        }
        Button(role: .destructive) { pendingDelete = row } label: { Label("Delete", systemImage: HVSymbol.delete) }
    }

    // MARK: Pinned and shared

    @ViewBuilder
    private var pinnedSection: some View {
        let pinned = model.pinnedRows
        if !pinned.isEmpty {
            Section {
                ForEach(pinned, id: \.slug) { pin in
                    NavigationLink(value: Route.artifact(slug: pin.slug)) {
                        LibraryPinnedRow(slug: pin.slug, title: pin.title, icon: pin.summary?.icon)
                    }
                    .libraryRow()
                    .swipeActions {
                        Button { Task { await model.togglePin(slug: pin.slug, toasts: app.toasts) } } label: { Label("Unpin", systemImage: "pin.slash") }
                    }
                }
                .onMove { source, destination in
                    Task { await model.movePin(from: source, to: destination, toasts: app.toasts) }
                }
            } header: {
                HVSectionHeader(title: "Pinned")
            }
        }
    }

    @ViewBuilder
    private var sharedSection: some View {
        if !model.sharedWithYou.isEmpty {
            Section {
                ForEach(model.sharedWithYou) { item in
                    NavigationLink(value: Route.artifact(slug: item.slug)) {
                        LibrarySharedRow(item: item)
                    }
                    .libraryRow()
                    .swipeActions {
                        Button(role: .destructive) { leaving = item } label: { Label("Leave", systemImage: "rectangle.portrait.and.arrow.right") }
                    }
                    .contextMenu {
                        Button(role: .destructive) { leaving = item } label: { Label("Leave", systemImage: "rectangle.portrait.and.arrow.right") }
                    }
                }
            } header: {
                HVSectionHeader(title: LibraryCopy.sharedWithYou)
            }
        }
    }

    // MARK: Empty, footer

    private var emptyState: some View {
        Section {
            HVEmptyState(
                symbol: filter == .file ? "doc.on.doc" : "tray",
                title: LibraryCopy.emptyLine(filter: filter, query: query),
                message: filter == .all && query.isEmpty ? "Ask your AI to keep something, or add a page with New." : nil
            )
            .listRowBackground(Color.clear)
        }
    }

    /// The line under a list that stopped before the end, so its end is not taken for the end of everything.
    @ViewBuilder
    private func truncationNote(count: Int, files: Bool = false) -> some View {
        if count <= model.shown, count >= LibraryModel.readLimit || (files && model.artifacts.count >= 200) {
            Text(LibraryCopy.truncated).font(.hvCaption).hvSectionNote()
        }
    }

    /// "Show more" while there are rows left.
    @ViewBuilder
    private func showMore(count: Int) -> some View {
        if count > model.shown {
            Section {
                Button(LibraryCopy.showMore) { model.shown += LibraryModel.pageSize }
                    .buttonStyle(.hvSecondary)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
        }
    }

    // MARK: Sheets

    @ViewBuilder
    private func sheetContent(_ sheet: LibrarySheet) -> some View {
        switch sheet {
        case .newPage:
            NewArtifactView(env: model.env) { result in
                self.sheet = nil
                Task { await model.load(filter: filter, query: query) }
                if let result { app.router.push(.artifact(slug: result.slug)) }
            }
        case .newGroup:
            GroupEditorView(env: model.env, slug: nil) { slug in
                self.sheet = nil
                Task { await model.load(filter: filter, query: query) }
                if let slug { app.router.push(.artifact(slug: slug)) }
            }
        case .share(let target):
            ArtifactActivitySheet(items: [target.url])
                .presentationDetents([.medium, .large])
        }
    }

    // MARK: Actions

    private func link(for summary: ArtifactSummary) -> URL {
        let host = summary.visibility == .public ? ArtifactLinks.primaryHost(model.realms) : nil
        return ArtifactLinks.url(slug: summary.slug, isGroup: summary.isGroup, host: host, appURL: model.env.server.baseURL)
    }

    private func share(_ row: LibraryModel.FileRow) {
        sheet = .share(ArtifactShareTarget(url: link(for: row.summary)))
    }

    private func setVisibility(_ row: LibraryModel.FileRow, _ visibility: ArtifactVisibility) {
        guard row.summary.visibility != visibility else { return }
        Task { await model.setVisibility(row, to: visibility, toasts: app.toasts) }
    }

    private func delete(_ row: LibraryModel.FileRow) {
        Task { _ = await model.delete(row, toasts: app.toasts) }
    }

    private func importFile(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            app.toasts.show(error: error)
        case .success(let urls):
            guard let url = urls.first else { return }
            Task {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else {
                    app.toasts.show("That file couldn't be read", style: .error)
                    return
                }
                await keep(data: data, filename: url.lastPathComponent)
            }
        }
    }

    private func importPhoto(_ item: PhotosPickerItem) {
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                app.toasts.show("That photo couldn't be read", style: .error)
                return
            }
            let prepared = LibraryPhoto.prepare(data, contentTypes: item.supportedContentTypes)
            await keep(data: prepared.data, filename: prepared.filename)
        }
    }

    private func keep(data: Data, filename: String) async {
        if let result = await model.upload(data: data, filename: filename, toasts: app.toasts) {
            await model.load(filter: filter, query: query)
            app.router.push(.artifact(slug: result.slug))
        }
    }
}

/// A photo, in a form the server takes: PNG, JPEG, GIF and WebP stay as they are; anything else (HEIC) becomes a JPEG.
enum LibraryPhoto {
    static func prepare(_ data: Data, contentTypes: [UTType], now: Date = Date()) -> (data: Data, filename: String) {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd HH.mm"
        let name = "Photo \(format.string(from: now))"
        let kept: [UTType: String] = [.png: "png", .jpeg: "jpg", .gif: "gif", .webP: "webp"]
        for type in contentTypes {
            if let ext = kept[type] { return (data, "\(name).\(ext)") }
        }
        if let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.9) {
            return (jpeg, "\(name).jpg")
        }
        return (data, "\(name).jpg")
    }
}

/// The questions a swipe or a menu asks before it does something that cannot be undone.
private struct LibraryConfirmations: ViewModifier {
    @Binding var pendingDelete: LibraryModel.FileRow?
    @Binding var pendingPublic: LibraryModel.FileRow?
    @Binding var leaving: SharedWithYouItem?
    var onDelete: (LibraryModel.FileRow) -> Void
    var onPublic: (LibraryModel.FileRow) -> Void
    var onLeave: (SharedWithYouItem) -> Void

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                pendingDelete.map { "Delete \u{201C}\($0.summary.title)\u{201D}?" } ?? "",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible, presenting: pendingDelete
            ) { row in
                Button("Delete", role: .destructive) { onDelete(row) }
            } message: { row in
                Text(row.summary.isGroup
                    ? "The group and all its files are removed, and its link stops working for good."
                    : "Its link stops working for good, and its connections go with it.")
            }
            .confirmationDialog(
                "Make this public?",
                isPresented: Binding(get: { pendingPublic != nil }, set: { if !$0 { pendingPublic = nil } }),
                titleVisibility: .visible, presenting: pendingPublic
            ) { row in
                Button("Make public") { onPublic(row) }
            } message: { _ in
                Text("Anyone with the link can open it.")
            }
            .confirmationDialog(
                leaving.map { "Leave \u{201C}\($0.title)\u{201D}?" } ?? "",
                isPresented: Binding(get: { leaving != nil }, set: { if !$0 { leaving = nil } }),
                titleVisibility: .visible, presenting: leaving
            ) { item in
                Button("Leave", role: .destructive) { onLeave(item) }
            } message: { _ in
                Text("It stays with its owner. You can no longer open it unless they add you again.")
            }
    }
}

extension View {
    /// A row on paper with its separator in line with the text, as the rows of Yours sit.
    fileprivate func libraryRow() -> some View {
        modifier(LibraryRowStyle())
    }
}
