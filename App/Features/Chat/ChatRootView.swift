import HyperVaultKit
import SwiftUI

/// The fourth tab: your chats, and your rooms (group chats with several of
/// your models). Models, where you connect your own, is one tap away.
struct ChatRootView: View {
    enum Half: String, CaseIterable, Identifiable {
        case chats = "Chats"
        case rooms = "Rooms"
        var id: String { rawValue }
    }

    @Environment(AppEnvironment.self) private var env
    @AppStorage("pref.chat.section") private var section = Half.chats

    var body: some View {
        Group {
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
            ToolbarItem(placement: .principal) {
                Picker("Show", selection: $section) {
                    ForEach(Half.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)
                .accessibilityLabel("Chats or rooms")
            }
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink(value: ChatDestination.models) {
                    Image(systemName: "cpu").frame(width: 44, height: 44)
                }
                .accessibilityLabel("Models")
            }
        }
        .navigationDestination(for: ChatDestination.self) { destination in
            switch destination {
            case .newConversation: ConversationScreen(conversationID: nil)
            case .models: ChatModelsScreen()
            }
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
