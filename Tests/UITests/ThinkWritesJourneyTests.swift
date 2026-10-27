import XCTest

/// Dreams, Digest and Chat, written to: one proposed connection accepted and another rejected, a split of a memory
/// applied, and a chat begun by its first message and deleted. Each journey checks what the screen shows afterwards and what
/// the app sent to the server.
///
/// (A chat cannot be renamed from the app: its title is made from the first message. A room can be, which no journey drives yet.)
@MainActor
final class ThinkWritesJourneyTests: HyperVaultUITestCase {
    func testOneConnectionIsAcceptedAnotherRejectedAndTheRestWait() {
        launch(.signedIn)
        openFromYou("dreams", title: "Dreams")

        step("The dream proposes four connections") {
            require(shows("4 proposed connections to review"), "the count of the dream")
            // (The list is long and draws only what is near the screen: the later cards are found by scrolling to them.)
            require(element("dream.accept.d1"), "the Accept button of the first connection")
            reveal(element("dream.reject.d4"), "the Reject button of the last connection")
        }

        step("Accepting a connection weaves it in and takes it off the queue") {
            open(element("dream.accept.d1"), "the Accept button of the first connection")
            requireGone(element("dream.accept.d1"), "the accepted connection")
            requireWrite("POST", "/api/dreams", equal: ["decision": "accept", "id": "d1"])
            require(shows("1 connection woven into your graph"), "the line that says what was woven in")
        }

        step("Rejecting another files it away for good") {
            open(element("dream.reject.d3"), "the Reject button of the third connection")
            requireGone(element("dream.reject.d3"), "the rejected connection")
            requireWrite("POST", "/api/dreams", equal: ["decision": "reject", "id": "d3"])
        }

        step("The two that were not decided are still waiting") {
            reveal(element("dream.accept.d2"), "the second connection")
            reveal(element("dream.accept.d4"), "the fourth connection")
            XCTAssertFalse(element("dream.accept.d1").exists, "The accepted connection should be gone.")
            XCTAssertFalse(element("dream.accept.d3").exists, "The rejected connection should be gone.")
        }

        step("Leaving and coming back finds the same queue") {
            goBack(until: { self.isShowingTitle("You") })
            openFromYou("dreams", title: "Dreams")
            require(shows("2 proposed connections to review"), "the new count of the dream")
            reveal(element("dream.accept.d2"), "the second connection again")
            XCTAssertFalse(element("dream.accept.d1").exists, "The accepted connection should not come back.")
            XCTAssertFalse(element("dream.accept.d3").exists, "The rejected connection should not come back.")
        }
    }

    func testASplitIsAppliedAndMemoryHasTheSmallerMemories() {
        launch(.signedIn)
        openFromYou("digest", title: "Digest")

        step("Digest proposes splitting the Planning chat into three") {
            require(shows("Planning chat with Sam"), "the memory that is proposed to be split")
            require(shows("Budget is set at 40k"), "the first part")
            reveal(element("digest.apply.dg1"), "the Apply split button")
        }

        step("Apply split asks first, and then splits") {
            let apply = element("digest.apply.dg1")
            open(apply, "the Apply split button")
            confirm("Apply split", whileStill: apply)
            requireWrite("POST", "/api/digest", equal: ["decision": "accept", "runId": "dg1"])
            requireGone(element("digest.apply.dg1"), "the proposal that was applied")
            require(shows("All reviewed"), "the empty queue, once the split is applied")
        }

        step("Memory has the three parts and no longer the original") {
            openTab("Memory")
            require(text("9 memories"), "the count, which now includes the three parts")
            require(element("memory.row.m3-part1"), "the first part of the split")
            XCTAssertTrue(element("memory.row.m3-part1").label.contains("Budget is set at 40k"))
            reveal(element("memory.row.m3-part3"), "the last part of the split")
            XCTAssertFalse(element("memory.row.m3").exists, "The memory that was split should be replaced.")
        }
    }
    func testANewChatIsBegunFromItsFirstMessageAndThenDeleted() {
        launch(.signedIn)
        openTab("Chat")

        step("New chat opens an empty conversation") {
            tap(button("New chat"), "New chat")
            require(textField("Message"), "the message field")
        }

        step("The first message begins the chat and gets its answer") {
            enter("Plan the balcony garden", into: textField("Message"), "the message field")
            tap(button("Send"), "Send")
            require(shows("Noted: Plan the balcony garden"), "the model's reply", timeout: 40)
            requireWrite("POST", "/api/chat", contains: ["message": "Plan the balcony garden"])
        }

        step("The list has the new chat, above the old ones") {
            goBack(until: { self.element("chat.row.n1").exists })
            let row = element("chat.row.n1")
            XCTAssertTrue(row.label.contains("Plan the balcony garden"), "The row says \"\(row.label)\".")
            require(element("chat.row.c1"), "the chats it already had")
        }

        step("Delete chat asks first, and then deletes") {
            tap(element("chat.row.n1"), "the new chat", until: { self.button("Chat menu").exists })
            tap(button("Chat menu"), "the chat menu")
            tap(button("Delete chat"), "Delete chat")
            requireGone(button("Model and options"), "the chat menu")
            confirm("Delete chat")
            requireWrite("DELETE", "/api/conversations/n1")
        }

        step("The list no longer has it") {
            require(element("chat.row.c1"), "the list again")
            requireGone(element("chat.row.n1"), "the deleted chat")
        }
    }
}
