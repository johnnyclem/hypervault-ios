import HyperVaultKit
import XCTest
@testable import HyperVault

/// What the canvas says aloud. Focus stays on the control that was used, and the result is added to the page elsewhere,
/// so a person using VoiceOver hears how a keep or a question went only from here.
@MainActor
final class CanvasAnnouncementTests: CanvasTestCase {
    private let keptAgain = #"{"slug":"here-you-go-1","url":"https://hypervault.store/a/here-you-go-1","kind":"page","form":"note","title":"Here you go.","visibility":"private","duplicate":true,"message":"Already kept."}"#

    private func speaking(_ routes: [MockRoute]) -> (model: CanvasModel, speech: CoreRecordingAnnouncer, transport: MockTransport) {
        let transport = MockTransport(routes: routes)
        let speech = CoreRecordingAnnouncer()
        return (CanvasModel(client: client(transport), origin: origin, announcer: speech), speech, transport)
    }

    private func offlineSpeaking() -> (model: CanvasModel, speech: CoreRecordingAnnouncer) {
        let speech = CoreRecordingAnnouncer()
        return (CanvasModel(client: client(OfflineTransport()), origin: origin, announcer: speech), speech)
    }

    // MARK: Keeping

    func testAKeepIsAnnouncedWithWhatWasKept() async {
        let (model, speech, _) = speaking([.json(.post, "/api/keep", kept)])
        model.keepExternal("Handoffs on Wednesday.")
        let done = await eventually { speech.spoken.contains("Kept. Here's the link. Here you go.") }
        XCTAssertTrue(done, "\(speech.spoken)")
    }

    func testAKeepOfSomethingAlreadyKeptSaysSo() async {
        let (model, speech, _) = speaking([.json(.post, "/api/keep", keptAgain)])
        model.keepExternal("Handoffs on Wednesday.")
        let done = await eventually { speech.spoken.contains("Already kept. Here's the link. Here you go.") }
        XCTAssertTrue(done, "\(speech.spoken)")
        XCTAssertFalse(speech.spoken.contains { $0.hasPrefix("Kept.") })
    }

    func testAKeepThatFailsSaysWhy() async {
        let (model, speech) = offlineSpeaking()
        model.keepExternal("Handoffs on Wednesday.")
        let done = await eventually { speech.spoken.contains(HVCopy.keepOfflineLine) }
        XCTAssertTrue(done, "\(speech.spoken)")
        XCTAssertEqual(model.notice?.text, HVCopy.keepOfflineLine)
    }

    func testAKeepTheServerRefusesIsSaidInTheServersWords() async {
        let (model, speech, _) = speaking([.failure(.post, "/api/keep", status: 413, message: "That is too large to keep.")])
        model.keepExternal("Handoffs on Wednesday.")
        let done = await eventually { speech.spoken.contains("That is too large to keep.") }
        XCTAssertTrue(done, "\(speech.spoken)")
    }

    func testKeepingWithNothingToKeepSaysSo() {
        let (model, speech, _) = speaking([])
        model.keepThis()
        XCTAssertEqual(speech.spoken, [HVCopy.nothingToKeepLine])
    }

    func testAPasteHeldAboveTheFieldIsAnnounced() {
        let (model, speech, _) = speaking([])
        model.stagePaste(aPaste)
        XCTAssertEqual(speech.spoken, [HVCopy.pastedLine(characters: aPaste.count)])
    }

    // MARK: Asking

    func testAReplyIsAnnounced() async {
        let (model, speech, _) = speaking([.json(.get, "/api/backends", oneModel), .json(.post, "/api/chat", reply)])
        await model.loadBackends()
        model.draft = "What did I decide?"
        await model.send()
        XCTAssertEqual(speech.spoken, ["Reply received"])
    }

    func testAQuestionThatDoesNotGetThroughSaysSo() async {
        let (model, speech) = offlineSpeaking()
        model.draft = "What did I decide?"
        await model.send()
        XCTAssertEqual(model.chatError, HVCopy.chatOfflineLine)
        XCTAssertEqual(speech.spoken, [HVCopy.chatOfflineLine])
    }

    func testATurnThatFailsAfterTheModelWasFoundSaysSo() async {
        let (model, speech, _) = speaking([
            .json(.get, "/api/backends", oneModel),
            .failure(.post, "/api/chat", status: 502, message: "The model did not answer."),
        ])
        await model.loadBackends()
        model.draft = "What did I decide?"
        await model.send()
        XCTAssertEqual(speech.spoken, ["The model did not answer."])
        XCTAssertEqual(model.draft, "What did I decide?", "the words go back to the field")
    }

    func testACancelledTurnSaysNothing() async {
        let transport = ServedOnce(first: oneModel)
        let speech = CoreRecordingAnnouncer()
        let model = CanvasModel(client: client(transport), origin: origin, announcer: speech)
        await model.loadBackends()
        model.draft = "What did I decide?"
        let sending = Task { await model.send() }
        let started = await eventually { await transport.waiting == 1 }
        XCTAssertTrue(started)
        sending.cancel()
        await sending.value
        XCTAssertNil(model.chatError)
        XCTAssertTrue(speech.spoken.isEmpty, "\(speech.spoken)")
    }

    func testATurnAbandonedForANewThreadSaysNothing() async {
        let transport = ServedOnce(first: oneModel)
        let speech = CoreRecordingAnnouncer()
        let model = CanvasModel(client: client(transport), origin: origin, announcer: speech)
        await model.loadBackends()
        model.draft = "What did I decide?"
        let sending = Task { await model.send() }
        _ = await eventually { await transport.waiting == 1 }
        model.startNewThread()
        sending.cancel()
        await sending.value
        XCTAssertTrue(speech.spoken.isEmpty, "\(speech.spoken)")
    }

    // MARK: The page's own lines

    func testThePagesOwnLinesAreSaid() {
        let (model, speech, _) = speaking([])
        model.help()
        model.ask()
        XCTAssertEqual(speech.spoken, [HVCopy.helpLine, HVCopy.newAskLine])
    }

    func testADictationThatDidNotStartSaysWhy() {
        let (model, speech, _) = speaking([])
        model.dictationFailed(.denied)
        XCTAssertEqual(speech.spoken, [DictationProblem.denied.line])
        XCTAssertEqual(model.notice?.opensSettings, true)
    }

    // MARK: Who spoke

    func testAThreadLineSaysWhoSpoke() {
        XCTAssertEqual(ThreadMessage(id: "1", role: .user, content: "Show my files").spokenLine, "You said: Show my files")
        XCTAssertEqual(ThreadMessage(id: "2", role: .assistant, content: "Here you go.").spokenLine, "Reply: Here you go.")
        XCTAssertEqual(ThreadMessage(id: "3", role: .assistant, content: "No files yet.", isLocal: true).spokenLine, "HyperVault: No files yet.")
    }

    func testAThreadLineIsReadWithoutTheMarksOfItsMarkdown() {
        let line = ThreadMessage(id: "1", role: .assistant, content: "Use **bold**, `code` and [the guide](https://hv.test/guide).")
        XCTAssertEqual(line.spokenLine, "Reply: Use bold, code and the guide.")
    }
}
