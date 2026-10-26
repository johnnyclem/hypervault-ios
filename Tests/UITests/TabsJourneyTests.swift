import XCTest

/// The Yours, Memory and Chat tabs of someone signed in: what they list, how they narrow, and where a tap goes.
@MainActor
final class TabsJourneyTests: HyperVaultUITestCase {
    func testYoursListsFiltersSearchesAndOpensARow() {
        launch(.signedIn)
        openTab("Yours")

        step("Yours lists what is kept") {
            require(element("yours.row.a1"), "the Bakery landing page row")
            XCTAssertTrue(element("yours.row.a1").label.contains("Bakery landing page"))
            for id in ["m1", "k1", "g1"] { require(element("yours.row.\(id)"), "the row \(id)") }
        }

        step("The Memories filter keeps only memories") {
            tap(segment("Memories"), "the Memories filter")
            require(element("yours.row.m2"), "the Auth decision memory")
            requireGone(element("yours.row.a1"), "the page, which is not a memory")
            XCTAssertTrue(element("yours.row.m1").exists)
        }

        step("The Files filter keeps pages and groups") {
            tap(segment("Files"), "the Files filter")
            require(element("yours.row.g1"), "the Portfolio site group")
            requireGone(element("yours.row.m1"), "the memory, which is not a file")
            XCTAssertTrue(element("yours.row.a1").exists)
        }

        step("The Keys filter keeps only keys") {
            tap(segment("Keys"), "the Keys filter")
            require(element("yours.row.k1"), "the OPENAI_API_KEY row")
            requireGone(element("yours.row.a1"), "the page, which is not a key")
        }

        step("Searching by name narrows the list") {
            tap(segment("All"), "the All filter")
            require(element("yours.row.m1"), "the full list again")
            enter("bakery", into: field("Search by name"), "the search field")
            requireGone(element("yours.row.m1"), "rows that do not match the search")
            XCTAssertTrue(element("yours.row.a1").exists, "The match should stay.")
        }

        step("Tapping a row opens the page") {
            tap(element("yours.row.a1"), "the Bakery landing page row")
            waitUntil("the page's title in the navigation bar") { isShowingTitle("Bakery landing page") }
            require(app.webViews.firstMatch, "the page's web view")
            require(element("artifact.share"), "the Share action")
            require(element("artifact.source"), "the Source action")
            XCTAssertFalse(text("You're offline").exists, "The page should have loaded from the canned server.")
            XCTAssertFalse(text("Nothing here").exists, "The page should have been found.")
        }

        step("Source opens as a sheet over the page") {
            tap(element("artifact.source"), "Source")
            require(button("Copy source"), "the source sheet's Copy source button, which shows once the source has loaded")
            tap(button("Done"), "Done")
            requireGone(button("Copy source"), "the source sheet")
        }

        step("Back returns to Yours") {
            goBack()
            require(element("yours.row.a1"), "the list again")
        }
    }

    func testMemoryListsSwitchesToTheGraphAndBack() {
        launch(.signedIn)
        openTab("Memory")

        step("Memory lists its memories") {
            require(element("memory.row.m1"), "the Lisbon memory")
            XCTAssertTrue(element("memory.row.m1").label.contains("Trip to Lisbon: ferry and passports"))
            require(text("7 memories"), "the count line")
        }

        step("Graph draws the map") {
            tap(segment("Graph"), "the Graph mode")
            require(button("Fit the whole graph"), "the graph's controls")
            requireGone(element("memory.row.m1"), "the list, now that the graph shows")
        }

        step("Search brings the list back") {
            tap(segment("Search"), "the Search mode")
            require(element("memory.row.m1"), "the list again")
        }
    }

    func testChatListsConversationsAndSwitchesToRooms() {
        launch(.signedIn)
        openTab("Chat")

        step("Chat lists conversations") {
            require(element("chat.row.c1"), "the Lisbon conversation")
            XCTAssertTrue(element("chat.row.c1").label.contains("Three days in Lisbon"))
            XCTAssertTrue(element("chat.row.c2").exists, "The next conversation should be listed too.")
        }

        step("Rooms lists the group chats") {
            tap(segment("Rooms"), "the Rooms half")
            require(element("chat.room.r1"), "the Features X and Y room")
            XCTAssertTrue(element("chat.room.r1").label.contains("Features X and Y"))
            requireGone(element("chat.row.c1"), "the conversations, now that rooms show")
        }

        step("Chats brings the conversations back") {
            tap(segment("Chats"), "the Chats half")
            require(element("chat.row.c1"), "the conversations again")
        }
    }
}
