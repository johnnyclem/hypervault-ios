import XCTest

/// The things people open from the tabs and talk to: a memory in full, Memory's Ask mode, a conversation, a room, and a
/// page from the Library with what can be done to it.
@MainActor
final class ContentJourneyTests: HyperVaultUITestCase {
    func testAMemoryOpensInFullAndAskModeAnswersFromMemory() {
        launch(.signedIn)
        openTab("Memory")

        step("A memory opens to its text, what it rests on and what it links to") {
            tap(element("memory.row.m1"), "the Lisbon memory")
            waitUntil("the memory's title") { isShowingTitle("Memory") }
            require(shows("Lisbon, first weekend"), "the heading inside the memory's text")
            require(shows("One of these has changed since this memory was written."), "the warning about the truth it rests on")
            require(shows("Passport checklist"), "the memory it is linked to")
            require(shows("Lisbon trip plan"), "the page it is linked to")
            require(shows("3 revisions"), "the history row")
        }

        step("Back returns to the list and Ask takes a question") {
            goBack()
            require(element("memory.row.m1"), "the list again")
            tap(segment("Ask"), "the Ask mode")
            require(shows("Ask your memory"), "the introduction to Ask")
        }

        step("The answer is written from the memories it drew on") {
            enter("What did I plan for the ferry?", into: textField("Ask your memory"), "the question field")
            tap(button("Ask"), "Ask")
            require(text("What did I plan for the ferry?"), "the question, kept above its answer")
            require(shows("Your Lisbon notes say to book the Friday ferry"), "the answer", timeout: 40)
            require(shows("Drew from"), "the list of sources")
            require(shows("Trip to Lisbon: ferry and passports"), "the memory the answer drew from")
        }
    }

    func testAConversationOpensAndTakesAMessage() {
        launch(.signedIn)
        openTab("Chat")

        step("A conversation opens to what was said in it") {
            tap(element("chat.row.c1"), "the Lisbon conversation")
            waitUntil("the conversation's title") { isShowingTitle("Three days in Lisbon") }
            require(shows("Can you plan a three-day trip to Lisbon in March?"), "the first question")
            require(shows("Day one: Alfama and the river"), "a heading in the model's plan")
        }

        step("A message gets a reply") {
            enter("Add a fado night", into: textField("Message"), "the message field")
            tap(button("Send"), "Send")
            require(shows("Noted: Add a fado night"), "the model's reply", timeout: 40)
        }
    }

    func testARoomOpensAndTakesAMessage() {
        launch(.signedIn)
        openTab("Chat")
        tap(segment("Rooms"), "the Rooms half")

        step("A room opens to what its members said") {
            tap(element("chat.room.r1"), "the Features X and Y room")
            waitUntil("the room's title") { isShowingTitle("Features X and Y") }
            require(shows("Schema is up."), "claude's message")
            require(shows("Contract committed as v3"), "grok's message")
        }

        step("What is said to the room is answered by a member") {
            enter("claude, summarise the plan", into: textField("Message"), "the message field")
            require(shows("Goes to @claude."), "the line that says who the message goes to")
            tap(button("Send"), "Send")
            require(shows("Noted: claude, summarise the plan"), "claude's answer", timeout: 40)
        }
    }

    func testAPageFromTheLibraryShowsWhoCanOpenItAndItsHistory() {
        launch(.signedIn)
        openFromYou("library", title: "Library")

        step("The page opens from the Library") {
            tap(element("library.row.a1"), "the Bakery landing page row")
            waitUntil("the page's title") { isShowingTitle("Bakery landing page") }
            require(named("Fresh bread daily", in: app.webViews.staticTexts), "the page's heading in its web view", timeout: 40)
        }

        step("Share lists the people who have it") {
            tap(element("artifact.share"), "Share")
            require(shows("maya@example.com"), "the person it is shared with")
            attachScreenshot("The Share sheet over the page")
            tap(button("Done"), "Done")
        }

        step("History lists the changes, newest first") {
            tap(button("More"), "the More menu")
            tap(button("History"), "History")
            require(shows("Open at seven on weekdays"), "the latest change")
            require(shows("Add the opening hours"), "the change before it")
            require(shows("Latest"), "the tag on the latest change")
            tap(button("Done"), "Done")
        }

        step("Details says who can open the page") {
            tap(button("More"), "the More menu")
            tap(button("Details"), "Details")
            require(shows("Who can open it"), "the access section")
            tap(button("Done"), "Done")
        }
    }
}
