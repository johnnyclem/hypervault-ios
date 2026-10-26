import HyperVaultKit
import XCTest
@testable import HyperVault

/// The canvas field: what counts as a paste, where a paste can go, and what Return does.
@MainActor
final class CanvasFieldTests: CanvasTestCase {
    func testAskInsteadPutsThePasteInTheFieldAndTheFieldKeepsIt() {
        let (model, _) = make([])
        model.draft = aPaste
        model.draftChanged(from: "", to: aPaste)
        XCTAssertEqual(model.staged, aPaste)
        XCTAssertEqual(model.draft, "", "the paste waits above the field, not in it")

        model.askInstead()
        XCTAssertEqual(model.draft, aPaste)
        XCTAssertNil(model.staged)

        // The field reports the change the page just made; it is not the person pasting again.
        model.draftChanged(from: "", to: aPaste)
        XCTAssertEqual(model.draft, aPaste)
        XCTAssertNil(model.staged)
    }

    func testAskInsteadAfterWhatWasTypedJoinsThemWithABlankLine() {
        let (model, _) = make([])
        model.draft = "Summarise this"
        model.draftChanged(from: "", to: "Summarise this")
        model.draft = "Summarise this" + aPaste
        model.draftChanged(from: "Summarise this", to: "Summarise this" + aPaste)
        XCTAssertEqual(model.draft, "Summarise this")

        model.askInstead()
        XCTAssertEqual(model.draft, "Summarise this\n\n" + aPaste)
        model.draftChanged(from: "Summarise this", to: model.draft)
        XCTAssertNil(model.staged)
        XCTAssertEqual(model.draft, "Summarise this\n\n" + aPaste)
    }

    func testAPasteIsStillHeldBackAfterThePageHasWrittenTheField() {
        let (model, _) = make([])
        model.setDraft("one thought")
        model.draftChanged(from: "", to: "one thought")
        XCTAssertNil(model.staged)

        model.draft = "one thought" + aPaste
        model.draftChanged(from: "one thought", to: "one thought" + aPaste)
        XCTAssertEqual(model.staged, aPaste)
        XCTAssertEqual(model.draft, "one thought")
    }

    func testAWriteThatChangesNothingDoesNotLeaveAMarkThatSwallowsTheNextPaste() {
        let (model, _) = make([])
        model.draft = "same"
        model.setDraft("same")
        model.draft = "same" + aPaste
        model.draftChanged(from: "same", to: "same" + aPaste)
        XCTAssertEqual(model.staged, aPaste)
    }

    func testAShortInsertionAndATypedLetterAreNotPastes() {
        let (model, _) = make([])
        model.draft = "hello there"
        model.draftChanged(from: "hello ther", to: "hello there")
        model.draftChanged(from: "", to: "a sentence that is well under the length of a thing")
        XCTAssertNil(model.staged)
    }

    func testALongQuestionThatCouldNotBeSentComesBackToTheFieldAndIsNotAPaste() async {
        let (model, _) = make([
            .json(.get, "/api/backends", oneModel),
            .failure(.post, "/api/chat", status: 502, message: "The model did not answer."),
        ])
        await model.loadBackends()
        // Typed a letter at a time, so the field never saw it arrive whole.
        model.draft = aPaste
        await model.send()

        XCTAssertEqual(model.draft, aPaste, "what was asked is given back")
        model.draftChanged(from: "", to: aPaste)
        XCTAssertEqual(model.draft, aPaste)
        XCTAssertNil(model.staged, "a question is not a thing to keep")
    }

    func testAnAnswerThatCouldNotBeKeptComesBackToTheFieldAndIsNotAPaste() async {
        let (model, _) = make([.failure(.post, "/api/keep", status: 500, message: "Could not keep that.")])
        model.ask()
        model.draft = aPaste
        await model.send()
        let back = await eventually { model.draft == self.aPaste }
        XCTAssertTrue(back)
        model.draftChanged(from: "", to: aPaste)
        XCTAssertEqual(model.draft, aPaste)
        XCTAssertNil(model.staged)
    }

    func testAPasteWithoutAModelCannotBeAskedAbout() async {
        let (model, _) = make([.json(.get, "/api/backends", noModel)])
        XCTAssertTrue(model.canAsk, "before the list is read there is no telling")
        await model.loadBackends()
        XCTAssertFalse(model.canAsk)
    }

    func testReturnSendsWhatIsInTheField() async {
        let (model, transport) = make([.json(.get, "/api/backends", oneModel), .json(.post, "/api/chat", reply)])
        await model.loadBackends()
        model.draft = "Plan my week"
        await model.submit()
        XCTAssertEqual(model.messages.map(\.content), ["Plan my week", "Here you go."])
        let sent = await transport.requests(matching: "/api/chat")
        XCTAssertEqual(sent.count, 1)
    }

    func testReturnWithNothingTypedKeepsAWaitingPaste() async throws {
        let (model, transport) = make([.json(.get, "/api/backends", oneModel), .json(.post, "/api/keep", kept)])
        await model.loadBackends()
        model.stagePaste(aPaste)
        await model.submit()

        let sent = await eventually { await transport.requests(matching: "/api/keep").count == 1 }
        XCTAssertTrue(sent)
        XCTAssertNil(model.staged)
        let keep = await transport.requests(matching: "/api/keep")
        XCTAssertEqual(try body(of: keep.first)["content"] as? String, aPaste)
        let chats = await transport.requests(matching: "/api/chat")
        XCTAssertTrue(chats.isEmpty)
    }

    func testReturnWithSomethingTypedSendsItAndLeavesTheWaitingPasteAlone() async {
        let (model, _) = make([.json(.get, "/api/backends", oneModel), .json(.post, "/api/chat", reply)])
        await model.loadBackends()
        model.stagePaste(aPaste)
        model.draft = "What is this?"
        await model.submit()
        XCTAssertEqual(model.messages.first?.content, "What is this?")
        XCTAssertEqual(model.staged, aPaste)
    }

    func testReturnWithAnEmptyFieldDoesNothing() async {
        let (model, transport) = make([.json(.get, "/api/backends", oneModel)])
        await model.loadBackends()
        await model.submit()
        let requests = await transport.requests(matching: "/api/chat")
        XCTAssertTrue(requests.isEmpty)
        XCTAssertTrue(model.messages.isEmpty)
    }
}
