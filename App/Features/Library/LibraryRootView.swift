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

    var body: some View {
        LibraryScreen(env: env)
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
    @State private var model: LibraryModel
    @State private var filter: YoursFilter
    @State private var query = ""
    @State private var sheet: LibrarySheet?
    @State private var pendingDelete: LibraryModel.FileRow?
    @State private var pendingPublic: LibraryModel.FileRow?
    @State private var leaving: SharedWithYouItem?
    @State private var importingFile = false
    @State private var showPhotos = false
    @State private var photo: PhotosPickerItem?

    init(env: AppEnvironment, filter: YoursFilter = .all) {
        _model = State(initialValue: LibraryModel(env: env))
        _filter = State(initialValue: filter)
    }

    /// What makes the list read again: a different filter, or a name (after a pause).
    private struct LoadKey: Hashable {
        let filter: YoursFilter
        let query: String
    }

    var body: some View {
        listView
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
    }

    private var listView: some View {
        List {
            filterBar
            if model.isStale { staleBanner }
            content
        }
        .listStyle(.plain)
        .listRowSeparatorTint(Palette.hairline)
        .scrollContentBackground(.hidden)
        .hvScreenBackground()
        .navigationTitle(LibraryCopy.title)
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: LibraryCopy.searchLabel)
        .toolbar { toolbar }
        .refreshable { await model.refresh(filter: filter, query: query) }
        .task(id: LoadKey(filter: filter, query: query.trimmingCharacters(in: .whitespacesAndNewlines))) {
            // A pause in typing, then the search; typing again cancels this one.
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
            }
            await model.load(filter: filter, query: query)
        }
        .task { await model.loadExtras() }
    }

    // MARK: Chrome

    // GRAPH-TOGGLE: the Library has a List view only. The memory feature is building a reusable
    // force graph; when it lands, a List/Graph control belongs here (a segmented picker beside the
    // filters, with the graph replacing `content` below), as the web's `VaultView` has.
    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: HV.Space.xs) {
                ForEach(YoursFilter.allCases) { option in
                    Button {
                        guard filter != option else { return }
                        Haptics.select()
                        filter = option
                    } label: {
                        HVChip(title: option.title, isSelected: filter == option)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(filter == option ? .isSelected : [])
                }
                NavigationLink(value: Route.mail) {
                    HVChip(title: "Mail")
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, HV.Space.m)
        }
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(LibraryCopy.filterGroupLabel)
    }

    private var staleBanner: some View {
        HVStaleBanner()
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // Pins can be put in the order the person likes (the side menu keeps the same order).
        ToolbarItem(placement: .topBarLeading) {
            if model.pins.artifactSlugs.count > 1, filter == .all || filter == .file, query.isEmpty {
                EditButton()
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button { sheet = .newPage } label: { Label("A page from text or a file", systemImage: "doc.badge.plus") }
                Button { sheet = .newGroup } label: { Label("A group of files", systemImage: "folder.badge.plus") }
                Button { importingFile = true } label: { Label("A PDF or an image", systemImage: "arrow.up.doc") }
                Button { showPhotos = true } label: { Label("A photo", systemImage: "photo") }
            } label: {
                Label(LibraryCopy.newLabel, systemImage: "plus")
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
            .hvGlass(radius: 22)
            .padding(.bottom, HV.Space.m)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        let searching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        switch model.phase {
        case .loading:
            HVListSkeleton(rows: 6)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
        case .failed(let message):
            HVErrorState(message: message) { Task { await model.load(filter: filter, query: query) } }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        case .loaded:
            if !searching, filter == .all || filter == .file {
                pinnedSection
                sharedSection
            }
            if filter == .file { fileRows } else { itemRows }
        }
    }

    // MARK: Yours rows

    @ViewBuilder
    private var itemRows: some View {
        if model.items.isEmpty {
            emptyState
        } else {
            let visible = Array(model.items.prefix(model.shown))
            ForEach(visible) { item in
                NavigationLink(value: route(for: item)) {
                    LibraryItemRow(item: item)
                }
                .libraryRow()
                .simultaneousGesture(TapGesture().onEnded { model.stampOpen(item) })
                .contextMenu { itemMenu(item) }
            }
            footer(count: model.items.count)
        }
    }

    private func route(for item: KeptItem) -> Route {
        switch item.kind {
        case .memory: return .memory(id: item.id)
        case .key: return .vaultItems
        case .page, .file, .group: return item.slug.map { .artifact(slug: $0) } ?? .library
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
                Label(LibraryCopy.copyLink, systemImage: "doc.on.doc")
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
            ForEach(rows.prefix(model.shown)) { row in
                NavigationLink(value: Route.artifact(slug: row.summary.slug)) {
                    LibraryFileRow(row: row)
                }
                .libraryRow()
                .swipeActions(edge: .leading, allowsFullSwipe: true) { visibilitySwipe(row) }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) { pendingDelete = row } label: { Label("Delete", systemImage: "trash") }
                    Button { share(row) } label: { Label("Share", systemImage: "square.and.arrow.up") }
                        .tint(Palette.blue)
                }
                .contextMenu { fileMenu(row) }
            }
            footer(count: rows.count)
        }
    }

    @ViewBuilder
    private func visibilitySwipe(_ row: LibraryModel.FileRow) -> some View {
        if row.summary.visibility == .public {
            Button { setVisibility(row, .private) } label: { Label("Make private", systemImage: "lock.fill") }
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
            Label(LibraryCopy.copyLink, systemImage: "doc.on.doc")
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
        Button(role: .destructive) { pendingDelete = row } label: { Label("Delete", systemImage: "trash") }
    }

    // MARK: Pinned and shared

    @ViewBuilder
    private var pinnedSection: some View {
        let pinned = model.pinnedRows
        if !pinned.isEmpty {
            Section {
                ForEach(pinned, id: \.slug) { pin in
                    NavigationLink(value: Route.artifact(slug: pin.slug)) {
                        HStack(spacing: HV.Space.s + 2) {
                            ArtifactGlyph(slug: pin.slug, title: pin.title, icon: pin.summary?.icon, size: 36)
                            Text(pin.title).font(.hvBody).lineLimit(1)
                            Spacer(minLength: HV.Space.xs)
                            Image(systemName: "pin.fill").font(.system(size: 11)).foregroundStyle(Palette.textTertiary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(pin.title), pinned")
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
        HVEmptyState(
            symbol: filter == .file ? "doc.on.doc" : "tray",
            title: LibraryCopy.emptyLine(filter: filter, query: query),
            message: filter == .all && query.isEmpty ? "Ask your AI to keep something, or add a page with New." : nil
        )
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    /// "Show more" while there are rows left, and the truncation line when the server stopped before the end.
    @ViewBuilder
    private func footer(count: Int) -> some View {
        if count > model.shown {
            Button(LibraryCopy.showMore) { model.shown += LibraryModel.pageSize }
                .buttonStyle(.hvSecondary)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        } else if count >= LibraryModel.readLimit || (filter == .file && model.artifacts.count >= 200) {
            Text(LibraryCopy.truncated)
                .font(.hvFootnote)
                .foregroundStyle(Palette.textSecondary)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
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
                    app.toasts.show("That file couldn't be read.", style: .error)
                    return
                }
                await keep(data: data, filename: url.lastPathComponent)
            }
        }
    }

    private func importPhoto(_ item: PhotosPickerItem) {
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                app.toasts.show("That photo couldn't be read.", style: .error)
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
    /// A row on paper, not on the list's own white or black, with its separator in line with the text.
    fileprivate func libraryRow() -> some View {
        self
            .listRowBackground(Color.clear)
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] + 50 }
    }
}
