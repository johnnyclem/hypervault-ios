import HyperVaultKit
import SwiftUI

/// Tools: the remote services (MCP servers) a person's chats can use. Connect
/// one, choose what it may do, then compile, which builds the index chats search
/// to find the right tool. This is a power-user screen, so it says "MCP" and
/// "compile" where they help.
struct ToolsRootView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        ToolsScreen(client: env.client, cache: env.cache, namespace: env.user.id, maxServers: env.limits.maxMcpServers)
    }
}

/// Where the Tools screen can go from its list.
enum ToolsRoute: Hashable {
    case server(String)
}

/// What the Tools screen can present over itself.
enum ToolsSheet: Identifiable {
    case add(ToolsCandidate?)
    case catalog
    case compile

    var id: String {
        switch self {
        case .add(let candidate): return "add-\(candidate?.url ?? "")"
        case .catalog: return "catalog"
        case .compile: return "compile"
        }
    }
}

struct ToolsScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var model: ToolsModel
    @State private var sheet: ToolsSheet?

    init(client: HVClient, cache: DiskCache, namespace: String, maxServers: Int) {
        _model = State(initialValue: ToolsModel(client: client, cache: cache, namespace: namespace, maxServers: maxServers))
    }

    var body: some View {
        content
            .hvScreenBackground()
            .navigationTitle("Tools")
            .toolbar {
                ToolbarItem(placement: .primaryAction) { addMenu }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // Pinned under the list while the words fit. At an accessibility size the bar would take nearly half the
                // screen and hide the list it is about, so there it is the last thing in the list instead.
                if !dynamicTypeSize.isAccessibilitySize, model.phase == .loaded, !model.servers.isEmpty {
                    ToolsCompileBar(model: model) { startCompile() }
                }
            }
            .navigationDestination(for: ToolsRoute.self) { route in
                switch route {
                case .server(let id): ToolsServerDetailView(model: model, serverID: id, client: env.client)
                }
            }
            .sheet(item: $sheet) { sheet in
                switch sheet {
                case .add(let candidate):
                    ToolsAddServerSheet(candidate: candidate, client: env.client, model: model)
                case .catalog:
                    ToolsCatalogSheet(model: model, client: env.client)
                case .compile:
                    ToolsCompileSheet(model: model)
                }
            }
            .task {
                model.reportError = { app.toasts.show(error: $0) }
                model.reportSuccess = { app.toasts.success($0) }
                await model.load()
            }
            .refreshable { await model.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ScrollView { HVListSkeleton() }
        case .failed(let message):
            HVErrorState(message: message) { Task { await model.load() } }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            if model.servers.isEmpty { emptyState } else { list }
        }
    }

    // MARK: Pieces

    private var addMenu: some View {
        Menu {
            Button { sheet = .catalog } label: { Label("Browse the catalog", systemImage: "square.grid.2x2") }
            Button { sheet = .add(nil) } label: { Label("Add by address", systemImage: "link") }
        } label: {
            Image(systemName: HVSymbol.add)
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel("Add a server")
    }

    private var list: some View {
        List {
            if model.isShowingSavedCopy {
                HVStaleBanner()
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            Section {
                ToolsToolkitCard(status: model.toolkit, needsCompile: model.needsCompile)
                    .listRowInsets(EdgeInsets(top: HV.Space.s, leading: HV.Space.m, bottom: HV.Space.s, trailing: HV.Space.m))
            }
            .hvListRow()

            Section(header: HVSectionHeader(title: "Connected", detail: "\(model.servers.count) of \(model.maxServers)")) {
                ForEach(model.servers) { server in
                    NavigationLink(value: ToolsRoute.server(server.id)) {
                        ToolsServerRow(server: server, needsSignIn: model.needsSignIn.contains(server.id))
                    }
                    .accessibilityIdentifier("tools.server.\(server.id)")
                }
            }
            .hvListRow()

            Section(footer: Text("Saved at once").hvSectionNote()) {
                Button { sheet = .catalog } label: { Label("Browse the catalog", systemImage: "square.grid.2x2").hvRowLabel() }
                Button { sheet = .add(nil) } label: { Label("Add by address", systemImage: "link").hvRowLabel() }
            }
            .hvListRow()

            if dynamicTypeSize.isAccessibilitySize {
                Section {
                    ToolsCompileBar(model: model) { startCompile() }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                }
            }
        }
        .scrollContentBackground(.hidden)
    }

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: HV.Space.l) {
                HVEmptyState(
                    symbol: "wrench.and.screwdriver",
                    title: "No tool servers yet",
                    message: "Tools are other services, like your calendar, GitHub or a notes app, that a chat can use for you"
                )
                VStack(alignment: .leading, spacing: HV.Space.m) {
                    ToolsStep(number: 1, title: "Connect a service", text: "Pick one from the catalog or paste its address. Some ask you to sign in first.")
                    ToolsStep(number: 2, title: "Choose what it may do", text: "Switch off any tool you do not want your chats to use.")
                    ToolsStep(number: 3, title: "Compile", text: "This builds the index your chats search to find the right tool. Do it again after a change.")
                }
                .hvCard()
                VStack(spacing: HV.Space.xs) {
                    Button("Browse the catalog") { sheet = .catalog }.buttonStyle(.hvPrimary)
                    Button("Add by address") { sheet = .add(nil) }.buttonStyle(.hvSecondary)
                }
            }
            .padding(HV.Space.m)
            .hvReadableWidth()
        }
    }

    private func startCompile() {
        model.startCompile()
        sheet = .compile
    }
}

/// A numbered step of the how-it-works card.
struct ToolsStep: View {
    let number: Int
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: HV.Space.s) {
            Text("\(number)")
                .font(.system(.footnote, weight: .bold))
                .foregroundStyle(Palette.sky)
                .frame(width: 26, height: 26)
                .background(Palette.blue.opacity(HV.Tint.fill), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: HV.Space.xxs) {
                Text(title).font(.hvHeadline)
                Text(text).font(.hvFootnote).foregroundStyle(Palette.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number). \(title). \(text)")
    }
}

/// One connected server in the list.
struct ToolsServerRow: View {
    let server: McpServer
    var needsSignIn = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                // The tag and the key take the room the name needs, so at these sizes they sit under it,
                // lined up with the name.
                VStack(alignment: .leading, spacing: HV.Space.xs) {
                    HVRow(symbol: symbol, title: server.name, subtitle: subtitle, subtitleIsAddress: true)
                    HStack(spacing: HV.Space.xs) { markers }
                        .hvRowWordsInset()
                }
            } else {
                HVRow(symbol: symbol, title: server.name, subtitle: subtitle, subtitleIsAddress: true) {
                    HStack(spacing: HV.Space.xs) { markers }
                }
            }
        }
        .frame(minHeight: 44)
        .opacity(server.enabled ? 1 : 0.65)
    }

    @ViewBuilder
    private var markers: some View {
        if let tag { HVTag(text: tag.text, tint: tag.tint) }
        if server.hasAuth {
            // Outline, and the size of the footnote beside it, so it follows the type.
            Image(systemName: server.secretBacked ? "lock.shield" : HVSymbol.key)
                .font(.footnote)
                .foregroundStyle(Palette.textSecondary)
                .accessibilityLabel(server.secretBacked ? "Sign-in kept in the saved-secrets vault" : "Needs a sign-in")
        }
    }

    /// One glyph for a server. Whether it is on, off or has no tools is said in words, in the subtitle ("· off",
    /// "· no tools listed") and the tag ("All off"), and not by the tile.
    private var symbol: String { "server.rack" }

    private var subtitle: String {
        switch server.status {
        case .off: return "\(server.host) · off"
        case .noTools: return "\(server.host) · no tools listed"
        case .allToolsOff, .on: return server.host
        }
    }

    private var tag: (text: String, tint: Color)? {
        if needsSignIn { return ("Sign in again", Palette.amber) }
        switch server.status {
        case .allToolsOff: return ("All off", Palette.amber)
        case .on: return ("\(server.enabledToolCount) of \(server.tools.count) on", Palette.textSecondary)
        default: return nil
        }
    }
}

/// The toolkit at a glance: whether one has been built, how big, how old, and
/// whether it is out of step with the servers.
struct ToolsToolkitCard: View {
    let status: McpToolkitStatus
    let needsCompile: Bool
    @ScaledMetric(relativeTo: .body) private var tile: CGFloat = HV.rowTile

    var body: some View {
        HStack(alignment: .top, spacing: HV.Space.s) {
            // The neutral tile, as a row's is. Whether the toolkit is built is the glyph (hammer or seal) and the
            // title; whether it is out of date is the "Out of date" tag, so no hue carries either.
            HVTile(symbol: status.toolkit == nil ? "hammer" : "checkmark.seal", size: HV.glyphBox(scaled: tile, base: HV.rowTile))
            VStack(alignment: .leading, spacing: 4) {
                headline
                if let detail { Text(detail).font(.hvFootnote).foregroundStyle(Palette.textSecondary) }
                if let toolkit = status.toolkit, toolkit.isLexical {
                    Text("Matches by wording only, so a request has to sound like the tool's name.")
                        .font(.hvCaption)
                        .foregroundStyle(Palette.warning)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    /// The headline, with "Out of date" beside it when it fits on one line and under it when it does not,
    /// so the headline itself is never the thing that wraps.
    @ViewBuilder
    private var headline: some View {
        if needsCompile, status.toolkit != nil {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: HV.Space.xs) {
                    Text(title).font(.hvHeadline)
                    HVTag(text: "Out of date", tint: Palette.amber)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.hvHeadline)
                    HVTag(text: "Out of date", tint: Palette.amber)
                }
            }
        } else {
            Text(title).font(.hvHeadline)
        }
    }

    private var title: String {
        guard let toolkit = status.toolkit else { return "No toolkit yet" }
        return "\(toolkit.stats.toolCount) tool\(toolkit.stats.toolCount == 1 ? "" : "s") ready for chats"
    }

    /// Nothing under the title while there is no toolkit: the bar under the list already says to compile.
    private var detail: String? {
        guard let toolkit = status.toolkit else { return nil }
        guard let date = toolkit.compiledAt else { return "Built by HyperVault" }
        return "Built \(HVCopy.ago(since: date).lowercased()) from \(toolkit.stats.providerCount) server\(toolkit.stats.providerCount == 1 ? "" : "s")"
    }
}

/// The bar at the bottom of the list: what compiling would do, and the button.
struct ToolsCompileBar: View {
    let model: ToolsModel
    var onCompile: () -> Void

    var body: some View {
        VStack(spacing: HV.Space.xs) {
            Text(message)
                .font(.hvFootnote)
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
            if model.needsCompile {
                Button("Compile tools", action: onCompile).buttonStyle(.hvPrimary).disabled(model.compile.isRunning)
            } else {
                Button("Compile again", action: onCompile).buttonStyle(.hvSecondary).disabled(model.enabledToolCount == 0 || model.compile.isRunning)
            }
        }
        .hvActionBar()
    }

    private var message: String {
        if model.enabledToolCount == 0 { return "Switch on at least one tool, then compile." }
        if model.toolkit.toolkit == nil { return "\(model.enabledToolCount) tools are on. Compile once so your chats can use them." }
        if model.needsCompile { return "You changed something. Compile so new chats use it." }
        return "Up to date. New chats use your \(model.toolkit.toolkit?.stats.toolCount ?? 0) tools."
    }
}

#if DEBUG
#Preview("Connected") {
    PreviewHost(routes: ToolsFixtures.routes) { ToolsRootView() }
}

#Preview("Empty") {
    PreviewHost(routes: ToolsFixtures.emptyRoutes) { ToolsRootView() }
}
#endif
