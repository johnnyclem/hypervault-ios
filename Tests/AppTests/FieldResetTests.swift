import SwiftUI
import XCTest
@testable import HyperVault

/// What a field that `hvFieldReset` has replaced may still write, when its words live in the view (Ask, a task's note).
@MainActor
final class FieldResetTests: XCTestCase {
    /// What such a view holds: the words in the field and the count that gives the field its identity.
    private final class Words {
        var text = ""
        var epoch = 0
    }

    /// The binding the view hands the text field, as it is when the body runs.
    private func binding(_ words: Words) -> Binding<String> {
        Binding<String>(get: { words.text }, set: { words.text = $0 })
            .hvDroppingStaleWrites(epoch: words.epoch, current: { words.epoch })
    }

    func testTypingInTheCurrentFieldIsKept() {
        let words = Words()
        let field = binding(words)
        field.wrappedValue = "hello"
        field.wrappedValue = "hello there"
        XCTAssertEqual(words.text, "hello there")
        XCTAssertEqual(field.wrappedValue, "hello there")
    }

    func testAWriteFromAFieldThatHasBeenReplacedIsDropped() {
        let words = Words()
        let old = binding(words)
        old.wrappedValue = "Plan the balcony garden"

        // Send: the view empties the field and gives it a new identity.
        words.text = ""
        words.epoch += 1

        // The old field hands its words back, and they are not typing.
        old.wrappedValue = "Plan the balcony garden"
        XCTAssertEqual(words.text, "")

        // The new field starts from the empty string and is heard.
        let new = binding(words)
        XCTAssertEqual(new.wrappedValue, "")
        new.wrappedValue = "Next"
        XCTAssertEqual(words.text, "Next")
    }
}
