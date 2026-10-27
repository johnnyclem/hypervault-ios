import HyperVaultKit
import SwiftUI

/// The five tabs. Each has its own navigation stack, kept alive while another
/// tab shows, and every stack resolves the same `Route`s.
struct MainTabView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppEnvironment.self) private var env
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var router = model.router
        TabView(selection: $router.tab) {
            TabRoot(tab: .canvas) { CanvasRootView() }
                .tabItem { Label(AppTab.canvas.title, systemImage: AppTab.canvas.symbol) }
                .tag(AppTab.canvas)

            TabRoot(tab: .yours) { YoursRootView() }
                .tabItem { Label(AppTab.yours.title, systemImage: AppTab.yours.symbol) }
                .tag(AppTab.yours)

            TabRoot(tab: .memory) { MemoryRootView() }
                .tabItem { Label(AppTab.memory.title, systemImage: AppTab.memory.symbol) }
                .tag(AppTab.memory)

            TabRoot(tab: .chat) { ChatRootView() }
                .tabItem { Label(AppTab.chat.title, systemImage: AppTab.chat.symbol) }
                .tag(AppTab.chat)

            TabRoot(tab: .you) { YouRootView() }
                .tabItem { Label(AppTab.you.title, systemImage: AppTab.you.symbol) }
                .tag(AppTab.you)
        }
        .adaptiveTabStyle()
        // Whatever Siri or the share sheet left waiting is kept once the person is in, not while the lock is up.
        .task(id: model.lock.isLocked) {
            guard !model.lock.isLocked else { return }
            await env.flushOutbox(toasts: model.toasts)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                guard !model.lock.isLocked else { return }
                await env.flushOutbox(toasts: model.toasts)
            }
        }
        .sheet(item: $router.sheet) { sheet in
            switch sheet {
            case .pair(let code):
                PairingPageSheet(code: code)
            case .invite:
                InviteLinkSheet()
            case .connectAgent:
                ConnectAgentSheet()
            }
        }
    }
}

/// One tab's navigation stack.
struct TabRoot<Content: View>: View {
    let tab: AppTab
    @Environment(AppModel.self) private var model
    @ViewBuilder var content: () -> Content

    var body: some View {
        NavigationStack(path: model.router.path(for: tab)) {
            content()
                .navigationDestination(for: Route.self) { route in
                    RouteDestination(route: route)
                }
        }
    }
}

/// Maps a `Route` to the screen that shows it. Features own their screens;
/// this is only the table of contents.
struct RouteDestination: View {
    let route: Route

    var body: some View {
        switch route {
        case .artifact(let slug): ArtifactDetailView(slug: slug)
        case .memory(let id): MemoryDetailView(id: id)
        case .conversation(let id): ConversationScreen(conversationID: id)
        case .room(let id): RoomScreen(roomID: id)
        case .mailThread(let id): MailThreadView(id: id)
        case .library: LibraryRootView()
        case .agentsAndKeys: AgentsAndKeysView()
        case .vaultItems: VaultItemsView()
        case .mail: MailRootView()
        case .truth: TruthRootView()
        case .truthReview: TruthReviewView()
        case .tools: ToolsRootView()
        case .realms: RealmsRootView()
        case .importHistory: ImportRootView()
        case .dreams: DreamsRootView()
        case .digest: DigestRootView()
        case .taskBoards: TaskBoardsRootView()
        case .admin: AdminRootView()
        case .settings: SettingsRootView()
        }
    }
}

/// The sheet an invite link opens when the person is already inside: they have
/// no use for a code, so say so kindly.
struct InviteLinkSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: HV.Space.l) {
            BrandMark(size: 56)
            Text("You're already in").font(.hvTitle)
            Text("That invite is for someone who is still waiting. You can share it with them.")
                .font(.hvCallout)
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
            Button("Done") { dismiss() }.buttonStyle(.hvPrimary)
        }
        .padding(HV.Space.xl)
        .presentationDetents([.medium])
    }
}

extension View {
    /// Tabs along the bottom on a phone and a sidebar on iPad, where the system offers it.
    @ViewBuilder
    func adaptiveTabStyle() -> some View {
        if #available(iOS 18.0, *) {
            tabViewStyle(.sidebarAdaptable)
        } else {
            self
        }
    }
}
