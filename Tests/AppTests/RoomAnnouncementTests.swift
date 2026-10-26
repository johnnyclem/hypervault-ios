import HyperVaultKit
import XCTest
@testable import HyperVault

/// What a room says out loud: the members' answers arrive in a transcript VoiceOver is not reading, and the
/// notices and the Continue card appear below it.
@MainActor
final class RoomAnnouncementTests: XCTestCase {
    private func message(_ id: String, _ position: Int, _ kind: String, _ handle: String?, status: String = "complete") -> String {
        let handleValue = handle.map { "\"\($0)\"" } ?? "null"
        return #"{"id":"\#(id)","room_id":"r1","position":\#(position),"sender_kind":"\#(kind)","sender_handle":\#(handleValue),"member_id":null,"content":"Words.","mentions":[],"tool_turns":[],"model":null,"status":"\#(status)","created_at":"2026-10-25T10:00:00Z"}"#
    }

    private func run(_ messages: [String], pending: String = "[]", budget: Int = 12) -> String {
        #"{"messages":[\#(messages.joined(separator: ","))],"pending":\#(pending),"budget":\#(budget),"busy":false}"#
    }

    /// The preview room has a turn waiting; this one has nothing queued, as a finished round leaves it.
    private var calmRoom: String {
        ChatPreviewData.roomJSON.replacingOccurrences(of: #""pending":[{"handle":"gemini","reason":"@grok handed you the turn"}]"#, with: #""pending":[]"#)
    }

    private func make(_ extra: [MockRoute] = [], room: String? = nil) -> (model: ChatRoomModel, speech: FeaturesRecordingAnnouncer) {
        let speech = FeaturesRecordingAnnouncer()
        let routes = extra + (room.map { [MockRoute.json(.get, "/api/rooms/r1", $0)] } ?? []) + ChatPreviewData.routes
        let env = AppEnvironment.preview(routes: routes)
        return (ChatRoomModel(roomID: "r1", client: env.client, announcer: speech), speech)
    }

    private func finishDriving(_ model: ChatRoomModel) async {
        for _ in 0..<500 where model.isDriving { try? await Task.sleep(nanoseconds: 10_000_000) }
        // The refresh that follows a round.
        try? await Task.sleep(nanoseconds: 100_000_000)
    }

    func testAnswersAreSaidOncePerRequestAndNotThePersonsOwnMessage() async {
        let reply = run([message("n1", 5, "human", nil), message("n2", 6, "agent", "claude"), message("n3", 7, "agent", "grok")])
        let (model, speech) = make([.json(.post, "/api/rooms/r1/messages", reply)], room: calmRoom)
        await model.load()
        speech.clear()
        model.draft = "claude, grok - go"
        model.send()
        await finishDriving(model)
        XCTAssertEqual(speech.spoken, ["@claude and @grok replied."])
    }

    func testAMemberThatCouldNotAnswerIsSaidSo() async {
        let reply = run([message("n1", 5, "human", nil), message("n2", 6, "agent", "claude"), message("n3", 7, "agent", "gemini", status: "error")])
        let (model, speech) = make([.json(.post, "/api/rooms/r1/messages", reply)], room: calmRoom)
        await model.load()
        speech.clear()
        model.draft = "go"
        model.send()
        await finishDriving(model)
        XCTAssertEqual(speech.spoken, ["@claude replied. @gemini could not answer."])
    }

    func testTheRoomsOwnNotesAreNotAnswers() {
        let note = ChatRoomMessage(id: "s1", position: 9, senderKind: .system, content: "Paused: this round used its 12-turn budget.")
        XCTAssertNil(ChatRoomModel.spokenAnswers(in: [note]))
    }

    func testManyAnswersAreCountedNotListed() {
        let many = ["a", "b", "c", "d"].enumerated().map { index, handle in
            ChatRoomMessage(id: handle, position: index, senderKind: .agent, senderHandle: handle, content: "Words.")
        }
        XCTAssertEqual(ChatRoomModel.spokenAnswers(in: many), "4 members replied.")
    }

    func testARoundThatStalledIsSaidOnceAndTheCardItBringsIsNotSaidAgain() async {
        let waiting = #"[{"handle":"gemini","reason":"@grok handed you the turn"}]"#
        let stuck = run([], pending: waiting, budget: 9)
        let (model, speech) = make([
            .json(.post, "/api/rooms/r1/messages", stuck),
            .json(.post, "/api/rooms/r1/run", stuck),
        ])
        await model.load()
        speech.clear()
        model.draft = "go"
        model.send()
        await finishDriving(model)
        XCTAssertEqual(speech.spoken, ["The room stopped answering. Continue to try again."])
        XCTAssertTrue(model.canContinue)
    }

    func testAFailedRequestIsSaidInTheServersWordsAsWellAsShown() async {
        let (model, speech) = make([.failure(.post, "/api/rooms/r1/messages", status: 503, message: "The database is missing agent-room support.")], room: calmRoom)
        await model.load()
        speech.clear()
        model.draft = "go"
        model.send()
        await finishDriving(model)
        XCTAssertEqual(model.notice, "The database is missing agent-room support.")
        XCTAssertEqual(speech.spoken, ["The database is missing agent-room support."])
    }

    func testARoundLeftHalfDoneIsSaidWhenTheRoomOpensAndNotEveryTimeItIsLookedAt() async {
        let (model, speech) = make()
        await model.load()
        XCTAssertEqual(speech.spoken, ["1 turn still waiting. Nobody is running this round. Continue is under the messages."])
        await model.refresh()
        XCTAssertEqual(speech.spoken.count, 1, "the card is still the same card")
    }
}
