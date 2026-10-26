import HyperVaultKit
import SwiftUI
import XCTest
@testable import HyperVault

@MainActor
final class ChatSnapshotTests: XCTestCase {
    private let sectionKey = "pref.chat.section"

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: sectionKey)
        super.tearDown()
    }

    func testChatList() throws {
        UserDefaults.standard.set("Chats", forKey: sectionKey)
        try snapshot(PreviewHost(routes: ChatPreviewData.routes) { ChatRootView() }, named: "chat-list")
    }

    func testRoomsList() throws {
        UserDefaults.standard.set("Rooms", forKey: sectionKey)
        try snapshot(PreviewHost(routes: ChatPreviewData.routes) { ChatRootView() }, named: "chat-rooms")
    }

    func testConversation() throws {
        try snapshot(
            PreviewHost(routes: ChatPreviewData.routes) { ChatConversationContent(model: ChatPreviewData.conversationModel()) },
            named: "chat-conversation"
        )
    }

    func testConversationWithAFormattedReply() throws {
        try snapshot(
            PreviewHost(routes: ChatPreviewData.routes) { ChatConversationContent(model: ChatPreviewData.conversationModel(firstTurnOnly: true)) },
            named: "chat-formatted-reply"
        )
    }

    func testConversationWaitingForTheModel() throws {
        try snapshot(
            PreviewHost(routes: ChatPreviewData.routes) { ChatConversationContent(model: ChatPreviewData.conversationModel(working: true)) },
            named: "chat-thinking"
        )
    }

    func testConversationOnDevice() throws {
        try snapshot(
            PreviewHost(routes: ChatPreviewData.routes) { ChatConversationContent(model: ChatPreviewData.conversationModel(onDevice: true)) },
            named: "chat-on-device"
        )
    }

    func testConversationWithAModelOnYourNetwork() throws {
        try snapshot(
            PreviewHost(routes: ChatPreviewData.routes) { ChatConversationContent(model: ChatPreviewData.conversationModel(local: true)) },
            named: "chat-local-model"
        )
    }

    func testNewConversation() throws {
        try snapshot(
            PreviewHost(routes: ChatPreviewData.routes) { ChatConversationContent(model: ChatPreviewData.conversationModel(empty: true)) },
            named: "chat-new"
        )
    }

    func testConversationAtTheLargestTextSize() throws {
        try snapshot(
            PreviewHost(routes: ChatPreviewData.routes) { ChatConversationContent(model: ChatPreviewData.conversationModel()) }
                .dynamicTypeSize(.accessibility3),
            named: "chat-conversation-xxl"
        )
    }

    /// The whole thread on one tall page, so the top of it can be looked at too: the screen-sized renders
    /// above start at the newest message.
    func testConversationInFull() throws {
        try snapshot(
            PreviewHost(routes: ChatPreviewData.routes) { ChatConversationContent(model: ChatPreviewData.conversationModel()) },
            named: "chat-conversation-full",
            size: CGSize(width: 393, height: 1700)
        )
    }

    func testChatListAtTheLargestTextSize() throws {
        UserDefaults.standard.set("Chats", forKey: sectionKey)
        try snapshot(
            PreviewHost(routes: ChatPreviewData.routes) { ChatRootView() }.dynamicTypeSize(.accessibility3),
            named: "chat-list-xxl"
        )
    }

    func testRoomsListAtTheLargestTextSize() throws {
        UserDefaults.standard.set("Rooms", forKey: sectionKey)
        try snapshot(
            PreviewHost(routes: ChatPreviewData.routes) { ChatRootView() }.dynamicTypeSize(.accessibility3),
            named: "chat-rooms-xxl"
        )
    }

    func testOptionsSheet() throws {
        try snapshot(
            PreviewHost(routes: ChatPreviewData.routes, embedInNavigation: false) {
                ChatOptionsSheet(model: ChatPreviewData.conversationModel())
            },
            named: "chat-options"
        )
    }

    func testRoom() throws {
        try snapshot(PreviewHost(routes: ChatPreviewData.routes) { RoomScreen(roomID: "r1") }, named: "chat-room")
    }

    func testRoomInFull() throws {
        try snapshot(
            PreviewHost(routes: ChatPreviewData.routes) { RoomScreen(roomID: "r1") },
            named: "chat-room-full",
            size: CGSize(width: 393, height: 1500)
        )
    }

    func testNewRoom() throws {
        let env = AppEnvironment.preview(routes: ChatPreviewData.routes)
        try snapshot(
            PreviewHost(routes: ChatPreviewData.routes, embedInNavigation: false) {
                ChatNewRoomSheet(client: env.client, cache: env.cache, namespace: "preview") { _ in }
            },
            named: "chat-new-room"
        )
    }

    func testRoomMembers() async throws {
        let env = AppEnvironment.preview(routes: ChatPreviewData.routes)
        let model = ChatRoomModel(roomID: "r1", client: env.client)
        await model.load()
        try snapshot(
            PreviewHost(routes: ChatPreviewData.routes, embedInNavigation: false) {
                ChatRoomMembersSheet(model: model, env: env)
            },
            named: "chat-room-members"
        )
    }

    func testWhoCanReadAChat() throws {
        try snapshot(
            PreviewHost(routes: ChatPreviewData.routes, embedInNavigation: false) {
                ChatVisibilitySheet(model: ChatPreviewData.conversationModel())
            },
            named: "chat-visibility"
        )
    }

    func testModelsAtTheLargestTextSize() throws {
        try snapshot(
            PreviewHost(routes: ChatPreviewData.routes) { ChatModelsScreen(onDevice: ChatPreviewData.support(onDevice: true)) }
                .dynamicTypeSize(.accessibility3),
            named: "chat-models-xxl"
        )
    }

    func testModels() throws {
        try snapshot(
            PreviewHost(routes: ChatPreviewData.routes) { ChatModelsScreen(onDevice: ChatPreviewData.support(onDevice: true)) },
            named: "chat-models"
        )
    }

    func testAddAModelOnYourNetwork() throws {
        try snapshot(
            PreviewHost(embedInNavigation: false) { ChatLocalModelSheet(existing: ChatPreviewData.sampleLocal) { _ in } },
            named: "chat-local-form"
        )
    }

    func testConnectForm() throws {
        try snapshot(
            PreviewHost(routes: ChatPreviewData.routes, embedInNavigation: false) {
                ChatBackendFormSheet(
                    mode: .connect, registry: ChatProviders.builtIn, serverCanStoreKeys: true, connectedCount: 1, maxBackends: 20
                ) { _ in "Connected." }
            },
            named: "chat-connect-form"
        )
    }
}
