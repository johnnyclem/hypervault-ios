import HyperVaultKit
import SwiftUI

/// Home, the first tab: your chats, and your group chats (rooms, with several of your models), under the switch between them.
/// With no chats at all, the Chats half is the starter page instead (`HomeStarterView`). The bar has the avatar (the Account
/// menu, where Settings is), Keep (the canvas, pushed on Home), New chat or New room, and More: Yours, Models, Tools and Import.
struct ChatRootView: View {
    enum Half: String, CaseIterable, Identifiable {
        case chats = "Chats"
        /// Stored as "Rooms", which is what a phone that chose it already holds; the web calls the page Group chats.
        case rooms = "Rooms"
        var id: String { rawValue }

        var title: String {
            switch self {
            case .chats: return "Chats"
            case .rooms: return AccountMenu.groupChats
            }
        }
    }

    @Environment(AppModel.self) private var app
    @Environment(AppEnvironment.self) private var env
    @AppStorage("pref.chat.section") private var section = Half.chats
    /// The New room sheet of the Group chats half: the bar's button asks for it, and the half presents it.
    @State private var showNewRoom = false

    var body: some View {
        // The switch sits under the title, not in the bar: a control in the bar is drawn inside its own
        // glass capsule, whose shadow shows as a box on a light page.
        VStack(spacing: 0) {
            HVChoicePicker(title: "Chats or group chats", selection: $section) {
                ForEach(Half.allCases) { Text($0.title).tag($0) }
            }
            .accessibilityIdentifier("chat.section")
            .padding(.horizontal, HV.Space.m)
            .padding(.vertical, HV.Space.xs)
            .hvReadableWidth()

            switch section {
            case .chats:
                ChatConversationListView(client: env.client, cache: env.cache, namespace: env.user.id)
            case .rooms:
                ChatRoomsListView(client: env.client, cache: env.cache, namespace: env.user.id, showNew: $showNewRoom)
            }
        }
        // Finished background jobs (a page repair) are told here too, as on the canvas pushed over this and on the Library.
        .jobNotices()
        .hvScreenBackground()
        .navigationTitle("Home")
        .navigationBarTitleDisplayMode(.inline)
        // One toolbar for the whole bar, so the order of its buttons is the one written here (two screens that each add
        // buttons to the same side have no promised order).
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { AccountAvatarButton() }
            ToolbarItemGroup(placement: .topBarTrailing) {
                keepButton
                newButton
                moreMenu
            }
        }
        .navigationDestination(for: ChatDestination.self) { destination in
            switch destination {
            case .newConversation: ConversationScreen(conversationID: nil)
            case .models: ChatModelsScreen()
            }
        }
        // The Account menu and a link to the web's /rooms ask for the group chats.
        .onChange(of: app.router.groupChats, initial: true) { _, wanted in
            guard wanted else { return }
            app.router.groupChats = false
            section = .rooms
        }
        .task {
            // Anything written on this phone while offline goes to the vault now.
            _ = await ChatOutboxes.outbox(for: env).flush(client: env.client)
        }
    }

    // MARK: The bar

    /// The canvas, where something is kept: pushed on this stack, so Back comes home.
    private var keepButton: some View {
        Button {
            app.router.push(.keep, on: .home)
        } label: {
            Image(systemName: HVSymbol.keep).frame(width: 44, height: 44)
        }
        .accessibilityLabel("Keep")
        .accessibilityIdentifier("home.keep")
    }

    /// The way to a new chat, or to a new room on the other half.
    @ViewBuilder private var newButton: some View {
        switch section {
        case .chats:
            NavigationLink(value: ChatDestination.newConversation) {
                Image(systemName: "square.and.pencil").frame(width: 44, height: 44)
            }
            .accessibilityLabel("New chat")
        case .rooms:
            Button { showNewRoom = true } label: {
                Image(systemName: HVSymbol.add).frame(width: 44, height: 44)
            }
            .accessibilityLabel("New room")
        }
    }

    /// What Home has no room for in the bar. Yours opens the canvas's panel; Models is a pane of Settings, which is the
    /// Account sheet over Home.
    private var moreMenu: some View {
        Menu {
            Button { app.router.open(.yours) } label: { Label("Yours", systemImage: "rectangle.stack") }
            Button { app.router.open(.account(.backends)) } label: { Label(AccountPane.backends.label, systemImage: HVSymbol.model) }
            Button { app.router.push(.tools) } label: { Label(AccountMenu.tools, systemImage: "wrench.and.screwdriver") }
            Button { app.router.push(.importHistory) } label: { Label("Import your AI history", systemImage: HVSymbol.importData) }
        } label: {
            Image(systemName: "ellipsis.circle").frame(width: 44, height: 44)
        }
        .accessibilityLabel("More")
        .accessibilityIdentifier("chat.more")
    }
}

#if DEBUG
#Preview("Chat") {
    PreviewHost(routes: ChatPreviewData.routes) {
        ChatRootView()
    }
}
#endif
