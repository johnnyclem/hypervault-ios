import XCTest
@testable import HyperVaultKit

/// `AddressText.breakable`: where an address may break when it is drawn over lines, and that it only ever adds the
/// zero width space, so the real string is what is left when they are taken out.
final class AddressTextTests: XCTestCase {
    private let space = "\u{200B}"

    private func stripped(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { $0.value != 0x200B }))
    }

    func testAHostBreaksAfterItsDots() {
        XCTAssertEqual(AddressText.breakable("hooks.example.org"), "hooks.\(space)example.\(space)org")
        XCTAssertEqual(AddressText.breakable("notes.example.com"), "notes.\(space)example.\(space)com")
    }

    func testAnEmailBreaksAfterTheAtSignAndTheDots() {
        XCTAssertEqual(AddressText.breakable("sam@example.com"), "sam@\(space)example.\(space)com")
    }

    func testAUrlBreaksAfterTheSlashesThatHaveSomethingAfterThem() {
        XCTAssertEqual(
            AddressText.breakable("https://hooks.example.org/in/v1"),
            "https://\(space)hooks.\(space)example.\(space)org/\(space)in/\(space)v1"
        )
    }

    func testARunOfSeparatorsIsNotBrokenInTheMiddle() {
        XCTAssertEqual(AddressText.breakable("a//b"), "a//\(space)b")
        XCTAssertEqual(AddressText.breakable("a..b"), "a..\(space)b")
        XCTAssertEqual(AddressText.breakable("a./b"), "a./\(space)b")
    }

    func testNothingIsAddedAtTheEndOrBeforeWhiteSpace() {
        XCTAssertEqual(AddressText.breakable("nova.vault.cool."), "nova.\(space)vault.\(space)cool.")
        XCTAssertEqual(AddressText.breakable("example.com/"), "example.\(space)com/")
        XCTAssertEqual(AddressText.breakable("Mail me. Or call."), "Mail me. Or call.")
        XCTAssertEqual(AddressText.breakable("host.example.com \u{00B7} off"), "host.\(space)example.\(space)com \u{00B7} off")
        XCTAssertEqual(AddressText.breakable(".").count, 1)
        XCTAssertEqual(AddressText.breakable("@"), "@")
    }

    func testTextWithNothingToBreakAtIsUntouched() {
        for text in ["", "grok", "Team notes", "localhost", "192", "a-b_c:d"] {
            XCTAssertEqual(AddressText.breakable(text), text, text)
        }
    }

    func testTheRealStringIsWhatRemainsWhenTheBreaksAreTakenOut() {
        let addresses = [
            "hooks.example.org", "sam@example.com", "https://hooks.example.org/in?x=1&y=2#top", "a//b..c@@d", "a.", ".a", "/",
            "https://", "192.168.1.20:11434", "b\u{00FC}cher.example", "xn--bcher-kva.example", "caf\u{00E9}@example.com",
            "a.\u{0301}b", "x\u{1F600}.y", "line one.\nline two", "tab.\tstop", "  lead.trail  ", "a.b.c.d.e.f.g.h",
        ]
        for address in addresses {
            XCTAssertEqual(stripped(AddressText.breakable(address)), address, address)
        }
    }

    func testGivingItToItselfChangesNothing() {
        for address in ["hooks.example.org", "sam@example.com", "https://a.b/c//d", "end.", "no breaks"] {
            let once = AddressText.breakable(address)
            XCTAssertEqual(AddressText.breakable(once), once, address)
        }
    }

    func testOnlyTheZeroWidthSpaceIsAdded() {
        let address = "https://hooks.example.org/in"
        let drawn = AddressText.breakable(address)
        let added = drawn.unicodeScalars.filter { $0.value == 0x200B }.count
        XCTAssertEqual(drawn.unicodeScalars.count, address.unicodeScalars.count + added)
        XCTAssertEqual(added, 4)
    }

    func testADotThatCarriesAnAccentIsNotSplitFromIt() {
        // "." followed by a combining acute is one character, not a dot, so there is no break after it and the accent
        // stays on its dot.
        let text = "a.\u{0301}b.c"
        XCTAssertEqual(AddressText.breakable(text), "a.\u{0301}b.\(space)c")
    }
}
