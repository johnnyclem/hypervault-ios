import XCTest

/// Task boards and Mail, written to: a board made, a task added, ticked along and marked done; a note composed and sent,
/// and a reply written in its thread. Each journey checks what the screen shows afterwards and what the app sent.
///
/// (A task or a board cannot be deleted from the app: neither the app nor the server's task-list routes have a delete, so
/// there is nothing to drive. A task can be cancelled, which is what the journey stops short of.)
@MainActor
final class BoardsAndMailWritesJourneyTests: HyperVaultUITestCase {
    func testABoardIsMadeATaskAddedTickedAlongAndMarkedDone() {
        launch(.signedIn)
        openFromAccount("taskBoards", title: "Task boards")

        step("The list has the boards the vault starts with") {
            require(element("taskboards.row.eurorack-choir"), "the Eurorack Choir board")
            require(element("taskboards.row.garden"), "the Spring garden board")
        }

        step("New board asks for a name, and makes the board") {
            tap(button("New board"), "New board")
            require(element("taskboards.new.title"), "the name field")
            enter("Balcony garden", into: element("taskboards.new.title"), "the name field")
            putTheKeyboardAway()
            tap(button("Create board"), "Create board")
            requireGone(element("taskboards.new.title"), "the New board sheet")
            requireWrite("POST", "/api/taskboards", equal: ["title": "Balcony garden"])
        }

        step("The new board opens, empty") {
            waitUntil("the new board's screen") { self.isShowingTitle("Balcony garden") }
            require(element("taskboard.add"), "the Add a task field")
            require(shows("Nothing here yet."), "the empty board")
        }

        step("Two tasks are added, one line each") {
            enter("Paint the railing\n", into: element("taskboard.add"), "the Add a task field")
            require(element("taskboard.task.t-new1"), "the first task, once the server has kept it")
            enter("Buy pots\n", into: element("taskboard.add"), "the Add a task field")
            require(element("taskboard.task.t-new2"), "the second task, once the server has kept it")
            XCTAssertTrue(element("taskboard.task.t-new1").label.contains("Paint the railing"))
            requireWrite("POST", "/api/tasklists/balcony-garden/tasks", equal: ["task": "{title=Paint the railing}"])
            requireWrite("POST", "/api/tasklists/balcony-garden/tasks", equal: ["task": "{title=Buy pots}"])
            putTheKeyboardAway()
        }

        step("Ticking a task starts it, ticking again finishes it") {
            let check = element("taskboard.check.t-new1")
            tap(check, "the first task's check")
            waitUntil("the task to be in progress") { check.label == "In progress" }
            requireWrite("PATCH", "/api/tasklists/balcony-garden/tasks/t-new1", equal: ["patch": "{status=in_progress}"])
            tap(check, "the first task's check")
            requireWrite("PATCH", "/api/tasklists/balcony-garden/tasks/t-new1", equal: ["patch": "{status=done}"])
            // Done tasks sit in a group that starts folded.
            requireGone(element("taskboard.task.t-new1"), "the finished task, which moves to the folded Done group")
            require(shows("1 of 2 done"), "the board's progress")
        }

        step("Mark done in a task's own screen finishes it") {
            tap(element("taskboard.task.t-new2"), "the second task", until: { self.isShowingTitle("Task") })
            open(button("Mark done"), "Mark done")
            requireWrite("POST", "/api/tasklists/balcony-garden/tasks/t-new2/complete")
            waitUntil("the board's screen again") { self.element("taskboard.add").exists }
            require(shows("2 of 2 done"), "the board's progress")
            require(shows("100%"), "the board's percentage")
        }

        step("The list of boards has the new board, finished") {
            goBack(until: { self.element("taskboards.row.balcony-garden").exists })
            let row = element("taskboards.row.balcony-garden")
            require(row, "the new board in the list")
            XCTAssertTrue(row.label.contains("Balcony garden"), "The row says \"\(row.label)\".")
            waitUntil("the row to say the board is finished") { row.label.contains("2 of 2 done") }
        }
    }

    func testANoteIsSentAndAReplyAppearsInItsThread() {
        launch(.signedIn)
        openFromAccount("mail", title: "Mail")
        let thread = "mail.thread.5e000001-0000-4000-8000-000000000001"

        step("The inbox has the agents' mail") {
            require(button("New note"), "the New note button")
        }

        step("A note is composed and sent") {
            tap(button("New note"), "New note")
            require(element("mail.compose.body"), "the note field")
            enter("Garden plan", into: element("mail.compose.subject"), "the subject field")
            enter("Please order the pots before Friday.", into: element("mail.compose.body"), "the note field")
            tap(button("Send"), "Send")
            requireGone(element("mail.compose.body"), "the compose sheet")
            requireWrite(
                "POST", "/api/mail/messages",
                equal: ["subject": "Garden plan", "text": "Please order the pots before Friday."]
            )
        }

        step("Sent lists the note, in its own thread") {
            require(element(thread), "the sent note's thread in the list")
            XCTAssertTrue(element(thread).label.contains("Garden plan"), "The row says \"\(element(thread).label)\".")
        }

        step("The thread opens, and a reply is written in it") {
            tap(element(thread), "the sent note", until: { self.element("mail.reply").exists })
            require(text("Please order the pots before Friday."), "the note in its thread")
            enter("Thanks, and add the soil.", into: element("mail.reply"), "the reply field")
            tap(button("Send reply"), "Send reply")
            requireWrite("POST", "/api/mail/messages/s-1/reply", equal: ["text": "Thanks, and add the soil."])
        }

        step("The reply appears in the thread, under the note") {
            require(text("Thanks, and add the soil."), "the reply in the thread")
            require(text("Please order the pots before Friday."), "the note, still above it")
            waitUntil("the reply field to be empty again") { (self.element("mail.reply").value as? String) != "Thanks, and add the soil." }
        }

        step("Back in the list the thread is still there") {
            goBack(until: { self.element(thread).exists })
            require(element(thread), "the thread in the list")
        }
    }
}
