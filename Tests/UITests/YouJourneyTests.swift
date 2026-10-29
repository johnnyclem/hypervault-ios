import XCTest

/// The Account menu behind the avatar and the You tab of someone signed in: the menu's rows and the Library it opens, the
/// seven panes of the You page in the web's order, a pane chosen from the list (and the same pane chosen again), General and
/// its switch, Agent keys with its keys, and the Appearance pane, which is the website's theme and says so.
@MainActor
final class YouJourneyTests: HyperVaultUITestCase {
    private let paneIds = ["general", "vault", "keys", "backends", "domain", "appearance", "import"]
    private let paneLabels = ["General", "Vault", "Agent keys", "Models", "Domain", "Appearance", "Import"]

    func testTheAvatarOpensTheAccountMenuAndLibraryTogglesBetweenListAndGraph() {
        launch(.signedIn)

        step("The avatar on Home opens the Account menu") {
            tap(button("Account"), "the Account button")
            require(element("account.close"), "the Account menu")
            XCTAssertTrue(isShowingTitle("Account"), "The menu is titled Account.")
        }

        step("The menu lists what the tab bar does not carry, in the web's words") {
            let rows: [(id: String, label: String)] = [
                ("library", "Library"), ("mail", "Mail"), ("taskBoards", "Task boards"), ("accountAndKeys", "Account & keys"),
                ("groupChats", "Group chats"), ("tools", "Tools"), ("import", "Import"), ("dreams", "Dreams"), ("truth", "Truth"),
            ]
            for row in rows {
                let item = element("account.\(row.id)")
                reveal(item, "the \(row.label) row")
                XCTAssertTrue(item.label.contains(row.label), "The \(row.id) row says \"\(item.label)\".")
            }
            require(shows("Beta"), "the heading over Dreams and Truth")
            XCTAssertFalse(element("account.admin").exists, "Admin is for an admin only.")
            reveal(element("account.signOut"), "Sign out")
            XCTAssertFalse(shows("Pricing").exists, "The menu has no Pricing.")
            XCTAssertFalse(shows("Sign in").exists, "The menu has no Sign in.")
        }

        step("Library opens with what is kept") {
            reveal(element("account.library"), "the Library row")
            tap(element("account.library"), "the Library row", until: { isShowingTitle("Library") })
            waitUntil("the Library title") { isShowingTitle("Library") }
            require(element("library.row.a1"), "the Bakery landing page row")
            XCTAssertTrue(element("library.view").label == "Show as a graph", "The view button says \"\(element("library.view").label)\".")
        }

        step("The graph view draws the map") {
            tap(element("library.view"), "the view button")
            require(button("Passport checklist"), "the graph's node for the Passport checklist memory")
            require(button("Fit the whole graph"), "the graph's Fit button")
            XCTAssertEqual(element("library.view").label, "Show as a list")
        }

        step("The list view comes back") {
            tap(element("library.view"), "the view button")
            require(element("library.row.a1"), "the list again")
            XCTAssertEqual(element("library.view").label, "Show as a graph")
        }
    }

    func testAccountAndKeysInTheMenuOpensTheVaultPaneOfTheYouTab() {
        launch(.signedIn)
        openAccountMenu()

        step("Account & keys lands on the vault, as /vault/account does") {
            tap(element("account.accountAndKeys"), "the Account & keys row", until: { element("vault.row.github.com").exists })
            require(element("vault.row.github.com"), "the github.com entry of the vault")
            XCTAssertFalse(element("canvas.account").exists, "The You tab has taken over from Home.")
            XCTAssertTrue(tab("You").isSelected, "The You tab is the one showing.")
        }
    }

    func testTheYouTabListsSevenPanesAndOpensOnTheVault() {
        launch(.signedIn)
        openTab("You")

        step("It opens on the vault, not on the list") {
            require(element("vault.row.github.com"), "the github.com entry of the vault")
            XCTAssertFalse(element("you.pane.vault").exists, "A phone shows the pane, with the list one step back.")
        }

        step("Going back shows the seven panes in the web's order") {
            goBack(until: { element("you.pane.general").exists })
            XCTAssertTrue(isShowingTitle("You"), "The list is titled You.")
            var previous: CGFloat = -1
            for (id, label) in zip(paneIds, paneLabels) {
                let row = element("you.pane.\(id)")
                require(row, "the \(label) pane")
                XCTAssertTrue(row.label.contains(label), "The \(id) pane says \"\(row.label)\".")
                XCTAssertGreaterThan(row.frame.minY, previous, "\(label) comes after the pane above it.")
                previous = row.frame.minY
            }
            XCTAssertFalse(shows("Pairing").exists, "There is no pairing approval.")
        }
    }

    func testChoosingAPaneShowsItAndTheSamePaneCanBeChosenAgainFromTheList() {
        launch(.signedIn)

        step("Models is a pane, with the web's line above it") {
            openPane("backends", title: "Models")
            require(shows("What answers when you ask something, on the canvas and in Chat."), "the pane's description")
            require(shows("Pick a provider, paste its API key, and press Connect. The canvas uses the newest one; Chat lets you pick one per conversation."), "the rest of the line")
        }

        step("Back shows the list, and Models can be chosen again though it is the one that was open") {
            goBack(until: { element("you.pane.general").exists })
            tap(element("you.pane.backends"), "the Models pane", until: { isShowingTitle("Models") })
            waitUntil("Models to open again") { isShowingTitle("Models") }
        }

        step("Another pane replaces it") {
            openPane("import", title: "Import")
            XCTAssertFalse(shows("What answers when you ask something").exists, "Models should be gone.")
            require(element("import.history"), "the history row of Import")
        }
    }

    func testGeneralShowsTheAccountAndTheSwitchesOfThisPhone() {
        launch(.signedIn)
        openPane("general", title: "General")

        step("General is the account you are signed in with") {
            require(shows("The account you are signed in with."), "the pane's description")
            let email = element("general.email")
            require(email, "the Email row")
            XCTAssertTrue(email.label.contains("sam@example.com"), "The Email row says \"\(email.label)\".")
            let profile = element("you.profile")
            require(profile, "the name")
            XCTAssertTrue(profile.label.contains("Sam Rivers"), "The profile card says \"\(profile.label)\".")
            let plan = element("general.plan")
            require(plan, "the Plan row")
            waitUntil("the plan to be read") { self.element("general.plan").label.contains("Pro") }
            XCTAssertFalse(shows("Upgrade").exists, "There is nothing to buy in the app.")
            XCTAssertFalse(shows("$").exists, "There is no price in the app.")
            require(element("you.signOut"), "Sign out")
        }

        step("What belongs to this phone is under its own heading") {
            reveal(text("On this phone"), "the heading")
            require(text("These belong to this phone, not to your account."), "what the heading means")
        }

        step("A toggle flips") {
            let haptics = toggle("Haptics")
            reveal(haptics, "the Haptics switch")
            XCTAssertEqual(haptics.value as? String, "1", "Haptics start on.")
            flip(haptics, from: "1", "the Haptics switch")
            XCTAssertEqual(haptics.value as? String, "0", "Haptics should be off.")
        }
    }

    func testAgentKeysOpensWithItsKeys() {
        launch(.signedIn)
        openPane("keys")

        step("Agent keys opens with the keys") {
            require(element("keys.row.k1"), "the Claude Code key")
            XCTAssertTrue(element("keys.row.k1").label.contains("Claude Code"), "The key row says \"\(element("keys.row.k1").label)\".")
            require(element("keys.connect"), "Connect an agent")
        }
    }

    func testAppearanceIsTheWebsitesThemeAndSaysSo() {
        launch(.signedIn)
        openPane("appearance", title: "Appearance")

        step("The pane says it is about the website, and that the app keeps its own look") {
            require(shows("How your dashboard and chat look on the website."), "the pane's description")
            require(shows("On the website"), "the heading over the picker")
            require(shows("This app keeps the HyperVault default look, whatever you pick here."), "the line about the app")
            XCTAssertFalse(shows("Gsap").exists, "The stock look is not called Gsap.")
            XCTAssertFalse(segment("Dark").exists, "The app has no light and dark choice.")
        }

        step("The picker holds the theme the profile holds") {
            let picker = element("appearance.theme")
            require(picker, "the theme picker")
            waitUntil("the picker to show the profile's theme") { picker.label.contains("Glassmorphism") || (picker.value as? String)?.contains("Glassmorphism") == true }
        }

        step("Choosing another sends it to the server, and the confirmation is about the website") {
            tap(element("appearance.theme"), "the theme picker")
            tap(button("Newsprint (light)"), "Newsprint")
            requireWrite("PATCH", "/api/dashboard-theme", equal: ["theme": "newsprint"])
            let confirmation = element("appearance.confirmation")
            require(confirmation, "the confirmation")
            XCTAssertEqual(confirmation.label, "Your website now wears Newsprint.")
            XCTAssertFalse(shows("Saved").exists, "Nothing says the app was restyled or saved with a tick.")
        }

        step("The stock look is the HyperVault default") {
            tap(element("appearance.theme"), "the theme picker")
            tap(button("HyperVault default"), "the HyperVault default")
            requireWrite("PATCH", "/api/dashboard-theme", equal: ["theme": "null"])
            require(element("appearance.confirmation"), "the confirmation")
            XCTAssertEqual(element("appearance.confirmation").label, "Your website is back on the HyperVault default look.")
        }
    }

    func testImportHasItsTwoRows() {
        launch(.signedIn)
        openPane("import", title: "Import")

        step("Import offers the history and one file") {
            require(shows("Bring what you made elsewhere into your vault."), "the pane's description")
            require(element("import.history"), "the history button")
            XCTAssertEqual(element("import.history").label, "Import your AI history")
            require(shows("Bring your ChatGPT, Claude, Gemini, and Grok history home"), "the history row's line")
            require(element("import.file"), "the file button")
            XCTAssertEqual(element("import.file").label, "Import a file")
            require(shows("Pick a file and it goes where it belongs."), "the file row's line")
            require(shows("a .txt, .md or .docx file becomes a memory"), "what happens to a document")
        }

        step("The history row goes on to the importer, inside the pane") {
            tap(element("import.history"), "Import your AI history", until: { element("import.source.chatgpt").exists })
            require(element("import.source.chatgpt"), "the ChatGPT card")
            goBack(until: { element("import.file").exists })
            require(element("import.file"), "the Import pane again")
        }
    }
}
