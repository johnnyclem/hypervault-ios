import XCTest

/// Every screen the You tab opens, against canned answers that give it real things to show (not an error and not an empty
/// state): each journey opens the screen, checks one or two pieces of what it was given, goes one level further where
/// the screen has one, and keeps a screenshot of how it looked.
@MainActor
final class YouScreensJourneyTests: HyperVaultUITestCase {
    func testVaultItemsListMaskedEntriesFilterThemAndOpenOne() {
        launch(.signedIn)
        openFromYou("vaultItems", title: "Logins, cards & keys")

        step("The vault lists what is saved, with a masked line and never a value") {
            let github = element("vault.row.github.com")
            require(github, "the github.com entry")
            XCTAssertTrue(github.label.contains("jane@appleseed.dev"), "The github.com row says \"\(github.label)\".")
            let visa = element("vault.row.visa-4242")
            require(visa, "the visa-4242 entry")
            XCTAssertTrue(visa.label.contains("4242"), "The card row says \"\(visa.label)\".")
            require(element("vault.row.stripe-restricted-key"), "the stripe key entry")
        }

        step("A filter keeps one kind") {
            tap(button("Cards, 2"), "the Cards filter")
            require(element("vault.row.amex-0005"), "the amex card")
            requireGone(element("vault.row.github.com"), "the login, which is not a card")
            tap(button("All, 6"), "the All filter")
            require(element("vault.row.github.com"), "the login again")
        }

        step("An entry opens to the agents that may read it") {
            tap(element("vault.row.github.com"), "the github.com entry")
            waitUntil("the entry's title") { isShowingTitle("github.com") }
            require(shows("Work account"), "the entry's note")
            let claude = app.switches.matching(NSPredicate(format: "label CONTAINS %@", "Claude Code")).firstMatch
            require(claude, "the switch for the Claude Code key")
            waitUntil("Claude Code to be allowed to read it") { (claude.value as? String) == "1" }
            let cursor = app.switches.matching(NSPredicate(format: "label CONTAINS %@", "Paired: Cursor")).firstMatch
            require(cursor, "the switch for the paired Cursor key")
            XCTAssertEqual(cursor.value as? String, "0", "The paired key has not been allowed to read it.")
            require(shows("How an agent reads it"), "the section that says how an agent reads it")
        }
    }

    func testMailListsTheInboxAndOpensAThread() {
        launch(.signedIn)
        openFromYou("mail", title: "Mail")

        let thread = "mail.thread.11111111-1111-4111-8111-111111111111"
        step("The inbox lists the mail from agents") {
            require(shows("ana@vault.cool"), "the mailbox address")
            let weekly = element(thread)
            require(weekly, "the Weekly plan thread")
            XCTAssertTrue(weekly.label.contains("Weekly plan"), "The thread row says \"\(weekly.label)\".")
            require(shows("Found three broken links in the garden notes"), "the garden notes thread")
            require(shows("Receipts for October"), "the receipts thread")
        }

        step("A thread opens to its messages, newest last") {
            tap(element(thread), "the Weekly plan thread")
            require(shows("Done. Friday it is, and I updated the page."), "the newest message")
            require(shows("Looks good. Move the demo to Friday?"), "the owner's own message")
            require(shows("I drafted the plan for next week"), "the first message")
            require(textField("Write a reply"), "the reply field")
        }

        step("Back returns to the inbox") {
            goBack()
            require(element(thread), "the inbox again")
        }
    }

    func testTruthShowsTheLedgerAnEntryAndItsReview() {
        launch(.signedIn)
        openFromYou("truth", title: "Truth")

        let retryCap = "truth.entry.01M1E6JK8SQAJ8K0JBRHTD10YG"
        step("The ledger lists what stands and what is unverified") {
            require(element("truth.entry.01M1E6JK80P9Y3CMA9HBZEND9H"), "the LOG_BUDGET entry")
            XCTAssertTrue(element("truth.entry.01M1E6JK80P9Y3CMA9HBZEND9H").label.contains("LOG_BUDGET is 100"))
            require(element(retryCap), "the retry cap entry")
            require(shows("A review is due"), "the review row")
            reveal(shows("Unverified"), "the Unverified section")
        }

        step("An entry shows what it rests on and what rests on it") {
            tap(element(retryCap), "the retry cap entry")
            waitUntil("the entry's title") { isShowingTitle("Signed truth") }
            require(shows("johnnyclem"), "who signed it")
            require(shows("The retry budget is 100."), "the premise beneath it")
            require(shows("The per-tenant cap is 5 too."), "the entry that rests on it")
        }

        step("The review docket lists what waits on a decision") {
            goBack()
            tap(element("truth.review"), "the review row")
            waitUntil("the Review title") { isShowingTitle("Review") }
            require(shows("Retries are idempotent across regions."), "the nominated claim on the docket")
        }
    }

    func testToolsListsTheConnectedServersAndOpensOne() {
        launch(.signedIn)
        openFromYou("tools", title: "Tools")

        step("The servers are listed with what they offer") {
            let linear = element("tools.server.s1")
            require(linear, "the Linear server")
            XCTAssertTrue(linear.label.contains("Linear"), "The server row says \"\(linear.label)\".")
            require(element("tools.server.s2"), "the Team notes server")
            require(element("tools.server.s3"), "the Weather server")
        }

        step("A server opens to its tools") {
            tap(element("tools.server.s1"), "the Linear server")
            waitUntil("the server's title") { isShowingTitle("Linear") }
            require(shows("list_issues"), "the list_issues tool")
            require(shows("create_issue"), "the create_issue tool")
        }
    }

    func testYourAddressListsTheClaimedAddressesAndOpensOne() {
        launch(.signedIn)
        openFromYou("realms", title: "Your address")

        step("The claimed addresses are listed with the plan") {
            let first = element("realms.row.c1")
            require(first, "the nova.vault.cool address")
            XCTAssertTrue(first.label.contains("nova.vault.cool"), "The address row says \"\(first.label)\".")
            require(element("realms.row.c2"), "the nova.cleon.wiki address")
            require(shows("Pro"), "the plan tag")
        }

        step("An address opens to its look and its home page") {
            tap(element("realms.row.c1"), "the nova.vault.cool address")
            waitUntil("the Address title") { isShowingTitle("Address") }
            require(shows("nova.vault.cool"), "the address")
            require(shows("Glassmorphism"), "the look it has")
            require(shows("Bakery landing page"), "the page it opens to")
        }
    }

    func testImportReadsAPastedConversationAndSendsIt() {
        launch(.signedIn)
        openFromYou("importHistory", title: "Import")

        step("Import offers the services a history comes from") {
            require(shows("Import your AI history"), "the introduction")
            for source in ["chatgpt", "claude", "gemini", "grok", "other"] {
                require(element("import.source.\(source)"), "the \(source) card")
            }
        }

        step("Pasted text is read as a conversation") {
            tap(element("import.source.other"), "the Something else card")
            let editor = app.textViews["Pasted conversation"]
            tap(editor, "the paste box")
            editor.typeText("User: What time is the ferry?\nAssistant: It leaves at seven.")
            tap(button("Check what I pasted"), "Check what I pasted")
            require(shows("A pasted conversation"), "the review of what was pasted")
            require(shows("2 messages"), "the message count")
            require(button("Import 1 conversation"), "the import button")
        }

        step("The import runs and says what it brought in") {
            tap(button("Import 1 conversation"), "the import button")
            require(shows("All in"), "the finish line")
            require(shows("Imported 1 conversation (2 messages)"), "the sentence about what came in")
            require(button("Open Chat"), "the way on to Chat")
        }
    }

    func testDreamsAndDigestShowWhatWasFoundOvernight() {
        launch(.signedIn)
        openFromYou("dreams", title: "Dreams")

        step("Dreams lists the connections found, each with its reason") {
            require(shows("Dream every night"), "the nightly switch")
            require(shows("Passport checklist"), "a memory on a connection")
            require(shows("shared tag: passports"), "the reason for the connection")
        }

        step("Digest lists the memory it would split") {
            goBack()
            reveal(element("you.digest"), "the Digest row")
            tap(element("you.digest"), "the Digest row")
            waitUntil("the Digest title") { isShowingTitle("Digest") }
            require(shows("Planning chat with Sam"), "the memory to split")
            require(shows("Budget is set at 40k"), "the first piece it would make")
        }
    }

    func testTaskBoardsListBoardsAndOpenOneWithItsTasks() {
        launch(.signedIn)
        openFromYou("taskBoards", title: "Task boards")

        step("The boards are listed with how far along they are") {
            let choir = element("taskboards.row.eurorack-choir")
            require(choir, "the Eurorack Choir board")
            XCTAssertTrue(choir.label.contains("Eurorack Choir Module"), "The board row says \"\(choir.label)\".")
            require(element("taskboards.row.garden"), "the garden board")
        }

        step("A board lists its tasks by where they stand") {
            tap(element("taskboards.row.eurorack-choir"), "the Eurorack Choir board")
            waitUntil("the board's title") { isShowingTitle("Eurorack Choir Module") }
            require(element("taskboard.task.t-panels"), "the front panels task")
            require(shows("Order the front panels"), "the task's title")
            reveal(shows("Pick a power supply"), "another task")
        }

        step("A task opens to its notes") {
            tap(element("taskboard.task.t-panels"), "the front panels task")
            require(shows("Two quotes in, one to go."), "the agent's note on the task")
            require(shows("Keep it under $80"), "the person's note on the task")
        }
    }
}
