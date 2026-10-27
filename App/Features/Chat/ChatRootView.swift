import HyperVaultKit
import SwiftUI

/// The second tab: your chats, and your group chats (rooms, with several of
/// your models). Models, where you connect your own, is one tap away, and
/// Tools and Import are under More.
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
                ChatRoomsListView(client: env.client, cache: env.cache, namespace: env.user.id)
            }
        }
        .hvScreenBackground()
        .navigationTitle("Chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink(value: ChatDestination.models) {
                    Image(systemName: "cpu").frame(width: 44, height: 44)
                }
                .accessibilityLabel("Models")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { app.router.push(.tools) } label: { Label(AccountMenu.tools, systemImage: "wrench.and.screwdriver") }
                    Button { app.router.push(.importHistory) } label: { Label("Import your AI history", systemImage: "square.and.arrow.down") }
                } label: {
                    Image(systemName: "ellipsis.circle").frame(width: 44, height: 44)
                }
                .accessibilityLabel("More")
                .accessibilityIdentifier("chat.more")
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
}

#Preview("Chat") {
    PreviewHost(routes: ChatPreviewData.routes) {
        ChatRootView()
    }
}
