import HyperVaultKit
import XCTest
@testable import HyperVault

/// The list of models the canvas asks with, and the opening page that gives way to what it has to say.
@MainActor
final class CanvasModelListTests: CanvasTestCase {
    func testAReadThatIsCancelledKeepsTheListOfModels() async {
        let transport = ServedOnce(first: oneModel)
        let model = CanvasModel(client: client(transport), origin: origin)
        await model.loadBackends()
        XCTAssertTrue(model.hasModel)

        let again = Task { await model.loadBackends() }
        let started = await eventually { await transport.waiting == 1 }
        XCTAssertTrue(started)
        again.cancel()
        await again.value

        XCTAssertTrue(model.hasModel, "a cancelled read says nothing about what is connected")
        XCTAssertFalse(model.needsModel)
        XCTAssertEqual(model.backends.map(\.id), ["b1"])
    }

    func testAReadThatFailsIsNotTakenForNoModel() async {
        let model = CanvasModel(client: client(OfflineTransport()), origin: origin)
        await model.loadBackends()
        XCTAssertFalse(model.backendsLoaded, "a failed read has not found out anything")
        XCTAssertFalse(model.needsModel)
    }

    func testAFailedReloadDoesNotTurnAModelIntoNone() async {
        let flaky = Flaky(inner: MockTransport(routes: [.json(.get, "/api/backends", oneModel)]))
        let model = CanvasModel(client: client(flaky), origin: origin)
        await model.loadBackends()
        await flaky.setOnline(false)
        await model.loadBackends()
        XCTAssertEqual(model.backends.map(\.id), ["b1"])
        XCTAssertTrue(model.backendsLoaded)
    }

    func testTheOpeningPageIsQuietUntilThereIsSomethingToShow() {
        let (model, _) = make([])
        XCTAssertTrue(model.isQuiet)
        model.say("A line")
        XCTAssertFalse(model.isQuiet)
        model.startNewThread()
        XCTAssertTrue(model.isQuiet)
    }

    func testAQuestionWithNoModelShowsTheNoModelLineAndStaysInTheField() async {
        let (model, transport) = make([.json(.get, "/api/backends", noModel)])
        await model.loadBackends()
        XCTAssertTrue(model.isQuiet)

        model.draft = "What did I decide about the trip?"
        await model.send()

        XCTAssertTrue(model.needsModel)
        XCTAssertFalse(model.isQuiet, "the empty page makes way for the line that nothing is connected")
        XCTAssertTrue(model.messages.isEmpty)
        XCTAssertEqual(model.draft, "What did I decide about the trip?")
        let chats = await transport.requests(matching: "/api/chat")
        XCTAssertTrue(chats.isEmpty, "nothing is sent")
    }

    func testAFirstTurnThatFailsShowsItsErrorAndGivesTheQuestionBack() async {
        let (model, _) = make([
            .json(.get, "/api/backends", oneModel),
            .failure(.post, "/api/chat", status: 502, message: "The model did not answer."),
        ])
        await model.loadBackends()
        model.draft = "Plan my week"
        await model.send()

        XCTAssertEqual(model.chatError, "The model did not answer.")
        XCTAssertFalse(model.isQuiet, "the error has somewhere to be drawn")
        XCTAssertTrue(model.messages.isEmpty)
        XCTAssertEqual(model.draft, "Plan my week")
        XCTAssertFalse(model.isBusy)
    }

    func testStartingOverEndsAnErrorAndTheNoModelLine() async {
        let (model, _) = make([.json(.get, "/api/backends", noModel)])
        await model.loadBackends()
        model.draft = "hello"
        await model.send()
        XCTAssertFalse(model.isQuiet)
        model.startNewThread()
        XCTAssertTrue(model.isQuiet)
    }

    func testAQuestionWhenTheListCouldNotBeReadSaysSoInsteadOfNoModel() async {
        let model = CanvasModel(client: client(OfflineTransport()), origin: origin)
        await model.loadBackends()
        model.draft = "Plan my week"
        await model.send()

        XCTAssertEqual(model.chatError, HVCopy.chatOfflineLine)
        XCTAssertFalse(model.needsModel, "it is not known that nothing is connected")
        XCTAssertFalse(model.isQuiet)
        XCTAssertEqual(model.draft, "Plan my week")
    }

    func testAModelConnectedSinceTheListWasReadIsFoundWhenAQuestionIsSent() async {
        let (model, transport) = make([.json(.get, "/api/backends", noModel), .json(.post, "/api/chat", reply)])
        await model.loadBackends()
        model.draft = "hello"
        await model.send()
        XCTAssertTrue(model.needsModel)

        // The person connects one in the sheet and comes back.
        await transport.add(.json(.get, "/api/backends", oneModel))
        await model.send()

        XCTAssertFalse(model.needsModel)
        XCTAssertEqual(model.messages.map(\.content), ["hello", "Here you go."])
        XCTAssertEqual(model.draft, "")
    }

    func testAListThatFailedToLoadIsReadAgainWhenTheQuestionIsSent() async {
        let flaky = Flaky(inner: MockTransport(routes: [.json(.get, "/api/backends", oneModel), .json(.post, "/api/chat", reply)]))
        await flaky.setOnline(false)
        let model = CanvasModel(client: client(flaky), origin: origin)
        await model.loadBackends()
        model.draft = "hello"
        await model.send()
        XCTAssertEqual(model.chatError, HVCopy.chatOfflineLine)

        await flaky.setOnline(true)
        await model.send()
        XCTAssertNil(model.chatError)
        XCTAssertEqual(model.messages.map(\.content), ["hello", "Here you go."])
    }
}
