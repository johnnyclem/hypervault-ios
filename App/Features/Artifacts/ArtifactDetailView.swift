import HyperVaultKit
import SwiftUI

/// A kept page, file or group: the page itself, calm, with the four things people
/// do most under it: Share, who can open it, Source, and More. Reached from
/// Yours, the Library, a link, or a link inside another page.
struct ArtifactDetailView: View {
    let slug: String

    @Environment(AppEnvironment.self) private var env

    var body: some View {
        ArtifactDetailScreen(slug: slug, env: env)
    }
}

/// What a sheet over a page can be.
enum ArtifactSheet: Identifiable, Hashable {
    case share, source, history, details, connections, realmHome, files
    case repair(String?)
    case quickLook

    var id: String {
        switch self {
        case .share: return "share"
        case .source: return "source"
        case .history: return "history"
        case .details: return "details"
        case .connections: return "connections"
        case .realmHome: return "realmHome"
        case .files: return "files"
        case .repair(let error): return "repair-\(error ?? "")"
        case .quickLook: return "quickLook"
        }
    }
}

struct ArtifactDetailScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model: ArtifactDetailModel
    @State private var sheet: ArtifactSheet?
    @State private var askPublic = false
    @State private var askDelete = false
    @Environment(\.dismiss) private var dismiss

    init(slug: String, env: AppEnvironment, loader: ArtifactPageLoader? = nil) {
        _model = State(initialValue: ArtifactDetailModel(slug: slug, env: env, loader: loader))
    }

    /// A screen for a model that has already read its page (a snapshot test draws it that way, so what
    /// is checked is the page state and not how long the canned answers took).
    init(model: ArtifactDetailModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.background.ignoresSafeArea())
            .navigationTitle(model.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .tabBar)
            .toolbar { toolbar }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ArtifactActionBar(model: model, sheet: $sheet, askPublic: $askPublic, askDelete: $askDelete, onReload: reload, onOpenSafari: openSafari)
            }
            .sheet(item: $sheet) { sheet in sheetContent(sheet) }
            .confirmationDialog("Make this public?", isPresented: $askPublic, titleVisibility: .visible) {
                Button("Make public") { Task { await model.setVisibility(.public, toasts: app.toasts) } }
            } message: {
                Text("Anyone with the link can open it.")
            }
            .confirmationDialog("Delete \u{201C}\(model.title)\u{201D}?", isPresented: $askDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { delete() }
            } message: {
                Text("Its link stops working for good, and its connections go with it.")
            }
            .task { await model.load() }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch model.pageState {
        case .loading:
            ArtifactLoadingView()
        case .ready(let web):
            ZStack(alignment: .top) {
                ArtifactWebView(
                    content: web,
                    router: model.linkRouter,
                    onProgress: { model.progress = $0 },
                    onFinish: { model.progress = 1 },
                    onFailure: { model.webFailure = $0 },
                    onOpenInApp: openInApp,
                    onRepair: { sheet = .repair($0) }
                )
                if model.progress < 1 {
                    ProgressView(value: max(model.progress, 0.05))
                        .progressViewStyle(.linear)
                        .tint(Palette.blue)
                        .transition(.opacity)
                        .accessibilityHidden(true)
                }
                if let failure = model.webFailure {
                    ArtifactBlockedView(
                        title: "This didn't open", message: failure, symbol: "exclamationmark.triangle",
                        primary: ("Try again", { reload() }), secondary: ("Open in Safari", openSafari)
                    )
                    .background(Palette.background)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: model.progress < 1)
        case .blocked(let block):
            if block == .notAllowed {
                // Retrying will not change a no; the web, where the person can sign in, might.
                ArtifactBlockedView(
                    title: block.title, message: block.message, symbol: symbol(for: block),
                    primary: ("Open in Safari", openSafari), secondary: ("Try again", { reload() })
                )
            } else {
                ArtifactBlockedView(
                    title: block.title, message: block.message, symbol: symbol(for: block),
                    primary: ("Try again", { reload() }), secondary: ("Open in Safari", openSafari)
                )
            }
        }
    }

    private func symbol(for block: ArtifactBlock) -> String {
        switch block {
        case .notFound: return "questionmark.folder"
        case .notAllowed: return HVSymbol.vault
        case .unavailable: return "hourglass"
        case .offline: return "wifi.slash"
        case .failed: return "exclamationmark.triangle"
        }
    }

    // MARK: Toolbar and sheets

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button(action: reload) { Image(systemName: "arrow.clockwise") }
                .accessibilityLabel("Reload")
        }
    }

    @ViewBuilder
    private func sheetContent(_ sheet: ArtifactSheet) -> some View {
        switch sheet {
        case .share:
            ArtifactShareSheet(detail: model)
        case .source:
            ArtifactSourceSheet(detail: model, onSaved: reload)
        case .history:
            ArtifactHistorySheet(detail: model, onRestored: reload)
        case .details:
            ArtifactInfoSheet(detail: model)
        case .connections:
            ArtifactConnectionsSheet(detail: model)
        case .realmHome:
            ArtifactRealmHomeSheet(detail: model)
        case .files:
            GroupEditorView(env: model.env, slug: model.slug) { _ in
                self.sheet = nil
                reload()
            }
        case .repair(let error):
            ArtifactRepairSheet(detail: model, renderError: error, onRepaired: reload)
        case .quickLook:
            if let file = model.embeddedFile {
                ArtifactQuickLookScreen(file: file, title: model.title)
            }
        }
    }

    // MARK: Actions

    private func reload() {
        Task { await model.reload() }
    }

    private func openSafari() {
        openURL(model.safariURL)
    }

    /// A link inside the page to somewhere in HyperVault: the app opens it if it can, Safari if not.
    private func openInApp(_ url: URL) {
        if let link = DeepLink(url: url) {
            app.router.open(link)
        } else {
            openURL(url)
        }
    }

    private func delete() {
        Task {
            do {
                try await model.delete()
                app.toasts.show("Deleted. Its link is gone for good.", style: .success)
                dismiss()
            } catch {
                app.toasts.show(error: error)
            }
        }
    }
}

// MARK: Bottom bar

/// Share, who can open it, Source, More: the four things people do most, on a
/// floating bar under the page. The page is inset above it, never covered.
struct ArtifactActionBar: View {
    let model: ArtifactDetailModel
    @Binding var sheet: ArtifactSheet?
    @Binding var askPublic: Bool
    @Binding var askDelete: Bool
    var onReload: () -> Void
    var onOpenSafari: () -> Void

    @Environment(AppModel.self) private var app
    /// The glyph of a bar item follows the type with its label; the bar stops at `.xxxLarge` (below), so it stays in its box.
    @ScaledMetric(relativeTo: .title3) private var glyph: CGFloat = 19

    var body: some View {
        HStack(spacing: 0) {
            Button { sheet = .share } label: { item("Share", "square.and.arrow.up") }
                .accessibilityHint("Share the link or add people")
                .accessibilityIdentifier("artifact.share")
            visibilityMenu
            if model.isGroup {
                Button { sheet = .files } label: { item("Files", "folder") }
                    .accessibilityIdentifier("artifact.files")
            } else if !model.isStoredFile {
                Button { sheet = .source } label: { item("Source", "chevron.left.forwardslash.chevron.right") }
                    .accessibilityIdentifier("artifact.source")
            }
            moreMenu
        }
        .buttonStyle(.plain)
        .padding(.horizontal, HV.Space.xs)
        .padding(.vertical, 6)
        // 30, half the bar's 60pt: a capsule, which is the one shape of floating glass that is not `HV.Radius.floating`.
        .hvGlass(radius: 30)
        .padding(.horizontal, HV.Space.m)
        .padding(.bottom, HV.Space.xxs)
        .padding(.top, HV.Space.xxs)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
        // Four labelled buttons stop fitting past the large sizes; the page above keeps scaling.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private func item(_ title: String, _ symbol: String) -> some View {
        VStack(spacing: HV.Space.xxs) {
            HVIcon(symbol)
                .font(.system(size: glyph, weight: .medium))
                .frame(height: glyph + 5)
            Text(title).font(.system(.caption2, weight: .medium))
        }
        .foregroundStyle(Palette.textPrimary)
        .frame(maxWidth: .infinity, minHeight: 48)
        .contentShape(Rectangle())
    }

    // MARK: Who can open it

    @ViewBuilder
    private var visibilityMenu: some View {
        if model.canManage {
            let current = model.visibility
            Menu {
                ForEach(ArtifactVisibility.allCases, id: \.self) { option in
                    Button {
                        choose(option)
                    } label: {
                        if option == current {
                            Label("\(option.title): \(option.detail)", systemImage: "checkmark")
                        } else {
                            Label("\(option.title): \(option.detail)", systemImage: option.symbol)
                        }
                    }
                }
            } label: {
                item(current?.title ?? "Access", current?.symbol ?? HVSymbol.vault)
            }
            .accessibilityLabel("Who can open it: \(current?.title ?? "unknown")")
            .accessibilityIdentifier("artifact.access")
            .disabled(model.summary == nil || model.summaryIsPlaceholder)
        }
    }

    private func choose(_ option: ArtifactVisibility) {
        guard option != model.visibility else { return }
        if option == .public { askPublic = true } else { Task { await model.setVisibility(option, toasts: app.toasts) } }
    }

    // MARK: More

    private var moreMenu: some View {
        Menu {
            Section {
                Button(action: onReload) { Label("Reload", systemImage: "arrow.clockwise") }
                Button(action: onOpenSafari) { Label("Open in Safari", systemImage: "safari") }
                if model.isStoredFile, model.embeddedFile != nil {
                    Button { sheet = .quickLook } label: { Label("Quick Look", systemImage: "eye") }
                }
            }
            if model.canManage {
                Section {
                    Button { sheet = .details } label: { Label("Details", systemImage: "info.circle") }
                    Button { sheet = .connections } label: { Label("Connections", systemImage: "link") }
                    if !model.isGroup, !model.isStoredFile {
                        Button { sheet = .history } label: { Label("History", systemImage: "clock.arrow.circlepath") }
                    }
                    Button {
                        Task { await model.togglePin(toasts: app.toasts) }
                    } label: {
                        Label(model.isPinned ? "Unpin from Library" : "Pin to Library", systemImage: model.isPinned ? "pin.slash" : "pin")
                    }
                }
                Section {
                    Button { Task { await model.rate(.up, toasts: app.toasts) } } label: {
                        Label("Thumbs up", systemImage: model.feedback == .up ? "hand.thumbsup.fill" : "hand.thumbsup")
                    }
                    Button { Task { await model.rate(.down, toasts: app.toasts) } } label: {
                        Label("Thumbs down", systemImage: model.feedback == .down ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                    }
                }
                Section {
                    if !model.isGroup, !model.isStoredFile {
                        Button { sheet = .repair(nil) } label: { Label("Fix it", systemImage: "wrench.and.screwdriver") }
                    }
                    if !model.isGroup, !model.isStoredFile, model.env.features.realmHomePage, !model.realms.isEmpty {
                        Button { sheet = .realmHome } label: { Label("Use as a home page", systemImage: "house") }
                    }
                }
                Section {
                    Button(role: .destructive) { askDelete = true } label: { Label("Delete", systemImage: HVSymbol.delete) }
                }
            }
        } label: {
            item("More", "ellipsis.circle")
        }
        .accessibilityLabel("More")
    }
}

// MARK: States

/// While the page is on its way.
struct ArtifactLoadingView: View {
    var body: some View {
        VStack(spacing: HV.Space.m) {
            HVSkeleton(height: 22, width: 220)
            HVSkeleton(height: 14, width: 280)
            HVSkeleton(height: 14, width: 240)
            HVSkeleton(height: 160)
                .padding(.horizontal, HV.Space.l)
        }
        .padding(HV.Space.l)
        .frame(maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading the page")
    }
}

/// A page that cannot be shown here: what happened, and the two ways on.
struct ArtifactBlockedView: View {
    let title: String
    let message: String
    let symbol: String
    var primary: (String, () -> Void)?
    var secondary: (String, () -> Void)?

    var body: some View {
        // The glyph, title and message are the app's one empty state; the two ways on go under it (it carries only one
        // quiet action of its own, and here the first of the two is the filled button).
        VStack(spacing: 0) {
            HVEmptyState(symbol: symbol, title: title, message: message)
            VStack(spacing: HV.Space.xs) {
                if let primary { Button(primary.0, action: primary.1).buttonStyle(.hvPrimary) }
                if let secondary { Button(secondary.0, action: secondary.1).buttonStyle(.hvGhost) }
            }
            .frame(maxWidth: 280)
            .padding(.horizontal, HV.Space.xl)
            .padding(.bottom, HV.Space.xl)
        }
        .frame(maxWidth: 460)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
