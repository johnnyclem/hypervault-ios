import XCTest

/// Dreams, Digest, Truth, Chat and Rooms, written to: one proposed connection accepted and another rejected, a split of a memory
/// applied, a belief asserted into the ledger, the memories and pages that are out of date decided one by one, and a chat
/// begun by its first message and deleted. Each journey checks what the screen shows afterwards and what
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

        step("Accept all takes the rest in one verdict, and the queue says what was woven in") {
            open(button("Accept all"), "Accept all")
            requireWrite("POST", "/api/dreams", equal: ["decision": "accept", "runId": "run1"])
            require(shows("2 connections woven into your graph"), "the line that says what was woven in")
            XCTAssertFalse(element("dream.accept.d2").exists, "Every connection of the dream had its verdict.")
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
            require(shows("Delete this chat?"), "the question that asks first")
            confirm("Delete chat")
            requireWrite("DELETE", "/api/conversations/n1")
        }

        step("The list no longer has it") {
            require(element("chat.row.c1"), "the list again")
            requireGone(element("chat.row.n1"), "the deleted chat")
        }
    }
    func testABeliefIsAssertedIntoTheLedger() {
        launch(.signedIn)
        openFromYou("truth", title: "Truth")
        let made = "truth.entry.01M2UITEST0000000000000001"

        step("The Team ledger is chosen, and Assert is in the menu") {
            // (The ledger the page opens on is the mirror, which nothing can be asserted into: the hosted one is chosen.)
            let ledgers = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Ledger:")).firstMatch
            tap(ledgers, "the ledger menu")
            tap(button("Team (hosted)"), "the Team ledger")
            require(element("truth.entry.01M1E6JK80P9Y3CMA9HBZEND9H"), "the LOG_BUDGET entry")
            XCTAssertFalse(element(made).exists, "The belief is not in the ledger yet.")
            tap(button("More"), "the More menu")
            tap(button("Assert a TB or UV"), "Assert a TB or UV")
            require(element("truth.assert.text"), "the field for what is believed")
        }

        step("A belief and why it is held are typed") {
            enter("Retries are bounded by the budget.", into: element("truth.assert.text"), "the belief field")
            enter("The retry design doc says so.", into: element("truth.assert.basis"), "the basis field")
        }

        step("Assert UV sends it and closes the sheet") {
            let assert = button("Assert UV")
            revealAboveTheKeyboard(assert, "the Assert UV button")
            // (A tap that lands while the form is still settling after the scroll is lost, and a person would tap again;
            // `until` taps again only while the sheet is still there.)
            tap(assert, "Assert UV", until: { !self.element("truth.assert.text").exists })
            requireGone(element("truth.assert.text"), "the Assert sheet")
            requireWrite(
                "POST", "/api/truth/entries",
                equal: ["type": "UV", "ledger": "team", "assertion": "Retries are bounded by the budget.", "basis": "The retry design doc says so."],
                contains: ["verifyBy": "inspect"]
            )
        }

        step("The ledger lists the belief as unverified") {
            reveal(element(made), "the belief in the ledger")
            XCTAssertTrue(element(made).label.contains("Retries are bounded by the budget."), "The row says \"\(element(made).label)\".")
        }
    }

    func testWhatIsOutOfDateIsDecidedOneByOne() {
        launch(.signedIn)
        openFromYou("truth", title: "Truth")

        step("Out of date lists the memories and the page whose facts moved") {
            tap(button("More"), "the More menu")
            tap(button("Out of date"), "Out of date")
            require(element("truth.stale.reaffirm.memory:mem1"), "the first memory's Still fine button")
            reveal(element("truth.stale.reaffirm.artifact:a-retry"), "the page's Still fine button")
        }

        step("Move to the new one points a memory at the entry that replaced the old") {
            open(element("truth.stale.relink.memory:mem1"), "Move to the new one")
            requireWrite(
                "POST", "/api/truth/stale",
                equal: ["kind": "memory", "id": "mem1", "action": "relink", "ledger": "team", "to": "[E9]", "entries": "[E1]"]
            )
            requireGone(element("truth.stale.relink.memory:mem1"), "the memory that was moved")
        }

        step("Still fine keeps a memory as it is") {
            open(element("truth.stale.reaffirm.memory:mem2"), "Still fine")
            requireWrite("POST", "/api/truth/stale", equal: ["kind": "memory", "id": "mem2", "action": "reaffirm", "entries": "[E2]"])
            requireGone(element("truth.stale.reaffirm.memory:mem2"), "the memory that was kept")
        }

        step("Stop tracking asks first, and then stops tracking the page") {
            let stop = element("truth.stale.unlink.artifact:a-retry")
            open(stop, "Stop tracking")
            confirm("Stop tracking", whileStill: stop)
            requireWrite("POST", "/api/truth/stale", equal: ["kind": "artifact", "id": "a-retry", "action": "unlink", "entries": "[E3]"])
        }

        step("Nothing is left, and the list says so") {
            require(shows("Nothing is out of date."), "the empty worklist")
        }
    }
    func testARoomIsMadeItsAgentsChangedItIsRenamedAndDeleted() {
        launch(.signedIn)
        openTab("Chat")
        tap(segment("Rooms"), "the Rooms half")

        step("New room offers the connected models and takes a name") {
            tap(button("New room"), "New room")
            require(element("room.new.title"), "the room name field")
            enter("Garden club", into: element("room.new.title"), "the room name field")
            putTheKeyboardAway()
        }

        step("Start room makes it and opens it") {
            open(button("Start room with 1 member"), "Start room")
            requireGone(element("room.new.title"), "the New room sheet")
            requireWrite("POST", "/api/rooms", equal: ["title": "Garden club"], contains: ["members": "handle=claude"])
            waitUntil("the new room's screen") { self.isShowingTitle("Garden club") }
            require(button("Room menu"), "the room's menu")
        }

        step("Members lists the agent in the room and adds another") {
            tap(button("Room menu"), "the room menu")
            tap(button("Members"), "Members")
            require(element("room.member.claude"), "the agent that was in the room from the start")
            tap(button("Add a member"), "Add a member")
            require(element("room.member.handle"), "the handle field")
            XCTAssertEqual(element("room.member.handle").value as? String, "claude2", "The handle that is taken is not offered again.")
            open(button("Add to the room"), "Add to the room")
            require(element("room.member.claude2"), "the agent that was added")
            requireWrite("POST", "/api/rooms/rn1/members", contains: ["members": "handle=claude2"])
        }

        step("Removing an agent asks first, and then takes it out") {
            let row = element("room.member.claude2")
            row.swipeLeft()
            tap(button("Remove"), "Remove")
            confirm("Remove @claude2")
            requireWrite("DELETE", "/api/rooms/rn1/members", equal: ["member_id": "rn1-m2"])
            requireGone(element("room.member.claude2"), "the agent that was removed")
            require(element("room.member.claude"), "the agent that stays")
            tap(button("Done"), "Done")
        }

        step("Rename takes a new name") {
            tap(button("Room menu"), "the room menu")
            tap(button("Rename"), "Rename")
            let field = app.alerts.textFields.firstMatch
            require(field, "the rename box")
            append(" 2026", to: field, "the rename box")
            tap(app.alerts.buttons["Save"], "Save")
            requireWrite("PATCH", "/api/rooms/rn1", equal: ["title": "Garden club 2026"])
            waitUntil("the room's title to change") { self.isShowingTitle("Garden club 2026") }
        }

        step("The list of rooms has the new name") {
            goBack(until: { self.element("chat.room.rn1").exists })
            let row = element("chat.room.rn1")
            XCTAssertTrue(row.label.contains("Garden club 2026"), "The row says \"\(row.label)\".")
            XCTAssertTrue(row.label.contains("@claude"), "The row says \"\(row.label)\".")
        }

        step("Delete room asks first, and then deletes it") {
            tap(element("chat.room.rn1"), "the new room", until: { self.button("Room menu").exists })
            tap(button("Room menu"), "the room menu")
            tap(button("Delete room"), "Delete room")
            require(shows("Delete this room?"), "the question that asks first")
            confirm("Delete room")
            requireWrite("DELETE", "/api/rooms/rn1")
            require(element("chat.room.r1"), "the rooms it had")
            requireGone(element("chat.room.rn1"), "the deleted room")
        }
    }
}
