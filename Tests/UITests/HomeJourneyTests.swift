import XCTest

/// Home, the first tab: the chats of someone who has some, and the starter page of someone who has none. Its bar has the
/// avatar, Keep (the canvas, pushed on Home), New chat and More; More holds Yours, Models, Tools and Import; and Back from
/// the screens it opens comes home.
@MainActor
final class HomeJourneyTests: HyperVaultUITestCase {
    func testHomeListsTheChatsAndItsBarOpensTheCanvasAndTheMoreMenu() {
        launch(.signedIn)

        step("Home is the list of chats, with no starter page") {
            require(element("chat.row.c1"), "the Lisbon conversation")
            requireGone(element("home.landing"), "the starter page, which is for someone with no chats")
            require(element("chat.section"), "the switch between chats and group chats")
            require(element("account.avatar"), "the avatar, which opens the Account menu")
            require(button("Keep"), "the Keep button")
            require(button("New chat"), "the New chat button")
            require(element("chat.more"), "the More menu")
        }

        step("Keep opens the canvas, and Back comes home to the chats") {
            openCanvas()
            require(element("canvas.yours"), "the canvas's panel button")
            goBack(until: { self.element("chat.row.c1").exists })
            require(element("chat.row.c1"), "the chats, which Back returns to")
        }

        step("The More menu holds Yours, Models, Tools and Import") {
            tap(element("chat.more"), "the More menu", until: { self.button("Yours").exists })
            for item in ["Yours", "Models", "Tools", "Import your AI history"] {
                require(button(item), "\(item) in the More menu")
            }
        }

        step("Yours opens the canvas with its panel over it, and Back from the canvas comes home") {
            tap(button("Yours"), "Yours", until: { self.element("yours.filter").exists })
            require(element("yours.filter"), "the Yours panel")
            tap(button("Done"), "Done", until: { !self.element("yours.filter").exists })
            require(element("canvas.field"), "the canvas under the panel")
            goBack(until: { self.element("chat.row.c1").exists })
        }
    }

    func testModelsInTheMoreMenuIsThePaneOfSettings() {
        launch(.signedIn)

        step("Models opens the Models pane of Settings over Home") {
            tap(element("chat.more"), "the More menu", until: { self.button("Models").exists })
            tap(button("Models"), "Models", until: { self.isShowingTitle("Models") })
            waitUntil("the Models pane") { isShowingTitle("Models") }
        }
    }

    func testSomeoneWithNoChatsGetsTheStarterPageAndTheirRoomsAreStillOnTheOtherHalf() {
        launch(.signedIn, arguments: withoutChats)

        step("Home is the starter page") {
            require(element("home.landing"), "the one line the starter page says")
            require(element("home.startChat"), "the Start a chat button")
            require(element("home.keepSomething"), "the Keep something button")
            require(element("home.starter"), "the Copy a starter prompt button")
            requireGone(element("chat.row.c1"), "the chats, of which there are none")
            requireGone(element("canvas.connectCard"), "the connect card, since this person already has keys")
        }

        step("Keep something opens the canvas, which has what the vault holds") {
            tap(element("home.keepSomething"), "Keep something", until: { self.element("canvas.field").exists })
            require(element("canvas.hint"), "the canvas's line about pasting")
            goBack(until: { self.element("home.landing").exists })
        }

        step("Start a chat opens an empty conversation") {
            tap(element("home.startChat"), "Start a chat", until: { self.textField("Message").exists })
            require(textField("Message"), "the message field")
            goBack(until: { self.element("home.landing").exists })
        }

        step("The group chats half still lists the rooms, and Chats brings the starter page back") {
            choose("Group chats", from: "chat.section")
            require(element("chat.room.r1"), "the Features X and Y room")
            requireGone(element("home.landing"), "the starter page, which is for the chats")
            choose("Chats", from: "chat.section")
            require(element("home.landing"), "the starter page again")
        }
    }
}
