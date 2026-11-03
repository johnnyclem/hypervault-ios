import HyperVaultKit
import SwiftUI

/// The four tabs, in the order of the tab bar: Home, Projects, Memory, Mail. Each has its own navigation stack, kept alive
/// while another tab shows, and every stack resolves the same `Route`s. Settings is not a tab: it is the Account sheet
/// behind the avatar on each tab's first screen, with a stack of its own (`AccountMenuSheet`).
struct MainTabView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppEnvironment.self) private var env
    @Environment(\.scenePhase) private var scenePhase

    /// Unread mail, for the number on the Mail tab. The Mail screen reads it from the environment to say what it found.
    @State private var mailUnread = MailUnread()

    var body: some View {
        @Bindable var router = model.router
        TabView(selection: $router.tab) {
            TabRoot(tab: .home) { CanvasRootView() }
                .tabItem { Label(AppTab.home.title, systemImage: AppTab.home.symbol) }
                .tag(AppTab.home)

            TabRoot(tab: .projects) { TaskBoardsRootView() }
                .tabItem { Label(AppTab.projects.title, systemImage: AppTab.projects.symbol) }
                .tag(AppTab.projects)

            TabRoot(tab: .memory) { MemoryRootView() }
                .tabItem { Label(AppTab.memory.title, systemImage: AppTab.memory.symbol) }
                .tag(AppTab.memory)

            TabRoot(tab: .mail) { MailRootView() }
                .tabItem { Label(AppTab.mail.title, systemImage: AppTab.mail.symbol) }
                .badge(mailUnread.count > 0 ? Text(AccountMenu.badgeText(mailUnread.count)) : nil)
                .tag(AppTab.mail)
        }
        .tabBarWithoutSidebar()
        .background(TabGlyphQuietHost())
        .environment(mailUnread)
        // Whatever Siri or the share sheet left waiting is kept once the person is in, not while the lock is up.
        .task(id: model.lock.isLocked) {
            guard !model.lock.isLocked else { return }
            await env.flushOutbox(toasts: model.toasts)
        }
        // The Mail tab's number is read here and not when Mail first shows: a tab's first screen is built when it is first visited.
        .task(id: model.lock.isLocked) {
            guard !model.lock.isLocked else { return }
            await mailUnread.refresh(client: env.client)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                guard !model.lock.isLocked else { return }
                await env.flushOutbox(toasts: model.toasts)
            }
            Task {
                guard !model.lock.isLocked else { return }
                await mailUnread.refresh(client: env.client)
            }
        }
        // Mail read or filed over there is counted when the person leaves it.
        .onChange(of: router.tab) { old, _ in
            guard old == .mail else { return }
            Task { await mailUnread.refresh(client: env.client) }
        }
        .sheet(item: $router.sheet, onDismiss: { router.sheetDidDismiss() }) { sheet in
            switch sheet {
            case .invite:
                InviteLinkSheet()
            case .connectAgent:
                ConnectAgentSheet()
            case .account:
                // A phone's sheet is as tall as it can be; an iPad's form sheet is too small for Settings, so it is a page.
                AccountMenuSheet()
                    .presentationSizing(.page)
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
        // A second link to the same screen with other values starts it over, not on the values the first one gave it.
        case .libraryFiltered(let filter, let query): LibraryRootView(filter: filter, query: query).id(route)
        case .truth: TruthRootView()
        case .truthReview: TruthReviewView()
        case .truthReviewLedger(let slug): TruthReviewView(ledger: slug).id(route)
        case .tools: ToolsRootView()
        case .importHistory: ImportRootView()
        case .dreams: DreamsRootView()
        case .digest: DigestRootView()
        case .taskBoard(let slug, let project, let title):
            TaskBoardView(listing: TaskBoardListing(slug: slug, project: project, title: title))
        case .admin: AdminRootView()
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
    /// The tab bar alone, on a phone and on an iPad: no sidebar made of the tabs, and no tab strip across the top that iPadOS 18
    /// and later draws for a tab view unless it is told this.
    func tabBarWithoutSidebar() -> some View {
        tabViewStyle(.tabBarOnly)
    }
}
