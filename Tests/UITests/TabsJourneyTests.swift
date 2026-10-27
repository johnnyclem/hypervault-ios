import XCTest

/// The Yours panel over Home, and the Memory and Chat tabs, of someone signed in: what they list, how they narrow, where a
/// tap goes, and what their More menus hold.
@MainActor
final class TabsJourneyTests: HyperVaultUITestCase {
    func testTheTabBarIsHomeChatMemoryYouAndNothingElse() {
        launch(.signedIn)

        step("Four tabs, in the order of the web's dock") {
            // (Each tab is asked for by its title, left to right: the tab bar's own tree has more in it than its four buttons.)
            var previous: CGFloat = -1
            for title in ["Home", "Chat", "Memory", "You"] {
                let item = tab(title)
                require(item, "the \(title) tab")
                XCTAssertGreaterThan(item.frame.minX, previous, "\(title) comes after the tab before it.")
                previous = item.frame.minX
            }
            XCTAssertFalse(tab("Yours").exists, "Yours is the panel on Home, not a tab.")
            XCTAssertFalse(tab("Canvas").exists, "The first tab is called Home.")
            XCTAssertFalse(tab("Library").exists, "The Library is behind the avatar, not a tab.")
        }
    }

    func testYoursListsFiltersSearchesAndPutsARowOnThePage() {
        launch(.signedIn)
        openYours()

        step("Yours lists what is kept") {
            require(element("yours.row.a1"), "the Bakery landing page row")
            XCTAssertTrue(element("yours.row.a1").label.contains("Bakery landing page"))
            // (The panel opens at half the height of the screen, so it is taken to the whole of it to see the rows below its fold.)
            expandThePanel()
            for id in ["m1", "k1", "g1"] { reveal(element("yours.row.\(id)"), "the row \(id)") }
        }

        step("The Memories filter keeps only memories") {
            reveal(segment("Memories"), "the Memories filter")
            tap(segment("Memories"), "the Memories filter")
            require(element("yours.row.m2"), "the Auth decision memory")
            requireGone(element("yours.row.a1"), "the page, which is not a memory")
            require(element("yours.row.m1"), "the other memory")
        }

        step("The Files filter keeps pages and groups") {
            tap(segment("Files"), "the Files filter")
            require(element("yours.row.g1"), "the Portfolio site group")
            requireGone(element("yours.row.m1"), "the memory, which is not a file")
            require(element("yours.row.a1"), "the page")
        }

        step("The Keys filter keeps only keys") {
            tap(segment("Keys"), "the Keys filter")
            require(element("yours.row.k1"), "the OPENAI_API_KEY row")
            requireGone(element("yours.row.a1"), "the page, which is not a key")
        }

        step("Searching by name narrows the list") {
            tap(segment("All"), "the All filter")
            require(element("yours.row.m1"), "the full list again")
            enter("bakery", into: searchField("Search by name"), "the search field")
            requireGone(element("yours.row.m1"), "rows that do not match the search")
            require(element("yours.row.a1"), "the match, which should stay")
        }

        step("Tapping a row puts it on the page and closes the panel") {
            tap(element("yours.row.a1"), "the Bakery landing page row")
            requireGone(element("yours.filter"), "the panel")
            require(button("Hide Bakery landing page"), "the card of the page, put on the page")
            require(button("Open Bakery landing page"), "the card's Open button")
        }

        step("The card opens the page") {
            tap(button("Open Bakery landing page"), "Open on the card")
            waitUntil("the page's title in the navigation bar") { isShowingTitle("Bakery landing page") }
            require(app.webViews.firstMatch, "the page's web view")
            // The page came through the app's own loader from the canned server, and the web view drew it.
            require(named("Fresh bread daily", in: app.webViews.staticTexts), "the page's heading in its web view", timeout: 40)
            require(element("artifact.share"), "the Share action")
            require(element("artifact.source"), "the Source action")
            XCTAssertFalse(text("You're offline").exists, "The page should have loaded from the canned server.")
            XCTAssertFalse(text("Nothing here").exists, "The page should have been found.")
        }

        step("Source opens as a sheet over the page") {
            tap(element("artifact.source"), "Source")
            require(button("Copy source"), "the source sheet's Copy source button, which shows once the source has loaded")
            attachScreenshot("The source sheet over the page")
            tap(button("Done"), "Done")
            requireGone(button("Copy source"), "the source sheet")
        }

        step("Back returns to Home") {
            goBack(until: { element("canvas.account").exists })
            require(element("canvas.yours"), "the panel button again")
        }
    }

    func testARowOfYoursOpensWhereItLivesFromItsMenuAndTheLibraryIsUnderMore() {
        launch(.signedIn)
        openYours()

        step("Library is under More") {
            tap(button("More"), "the More menu")
            XCTAssertTrue(button("Library").exists, "More holds Library.")
            tap(button("Library"), "Library", until: { isShowingTitle("Library") })
            waitUntil("the Library title") { isShowingTitle("Library") }
            requireGone(element("yours.filter"), "the panel, which closes as the Library opens")
            require(element("library.row.a1"), "the Bakery landing page row")
        }

        step("Back is Home") {
            goBack(until: { element("canvas.account").exists })
        }

        step("Open on a row opens the page where it lives") {
            openYours()
            let row = element("yours.row.a1")
            require(row, "the Bakery landing page row")
            row.press(forDuration: 1.0)
            tap(button("Open"), "Open", until: { isShowingTitle("Bakery landing page") })
            waitUntil("the page's title") { isShowingTitle("Bakery landing page") }
            requireGone(element("yours.filter"), "the panel")
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
            // The map is read as its nodes, each a button that opens its memory, and its zoom controls stay reachable.
            require(button("Passport checklist"), "the graph's node for the Passport checklist memory")
            require(button("Fit the whole graph"), "the graph's Fit button")
            requireGone(element("memory.row.m1"), "the list, now that the graph shows")
        }

        step("Search brings the list back") {
            tap(segment("Search"), "the Search mode")
            require(element("memory.row.m1"), "the list again")
        }
    }

    func testChatListsConversationsAndSwitchesToGroupChats() {
        launch(.signedIn)
        openTab("Chat")

        step("Chat lists conversations") {
            require(element("chat.row.c1"), "the Lisbon conversation")
            XCTAssertTrue(element("chat.row.c1").label.contains("Three days in Lisbon"))
            require(element("chat.row.c2"), "the next conversation")
        }

        step("Group chats lists the rooms") {
            tap(segment("Group chats"), "the Group chats half")
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
