import XCTest

/// The Memory tab's graph and the controls over it: finding a memory by part of its name, leaving a kind of node off and
/// putting it back, leaving out what has no links, and the Drift tour.
///
/// In the canned world the seven memories come from four places (the person's own: "Trip to Lisbon..." and "Reading list for
/// the winter"; and one each from an agent, a chat, a coding agent, a file and a repository), two pages hang off two of
/// them, and every memory has a link. Leaving the person's own memories off the map takes "Reading list for the winter" with
/// them and leaves "Passport checklist", whose only links were to those two, with none: that is what Hide unlinked is for.
@MainActor
final class MemoryGraphControlsJourneyTests: HyperVaultUITestCase {
    private func openTheGraph() {
        openTab("Memory")
        tap(segment("Graph"), "the Graph mode", until: { button("Fit the whole graph").exists })
        require(button("Passport checklist"), "the graph's node for the Passport checklist memory")
    }

    /// The row of pills is wider than a phone and the Hide unlinked chip is its last: draws the row sideways until `target`
    /// can be tapped.
    private func scrollThePills(until target: XCUIElement, towardsEnd: Bool) {
        // The finger goes down on the row itself: every pill is on it, whether it is on the screen or not.
        let window = app.windows.firstMatch.frame
        let y = min(max(element("memory.graph.type.You").frame.midY / max(window.height, 1), 0.05), 0.95)
        for _ in 0..<4 where !(target.exists && target.isHittable) {
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: towardsEnd ? 0.9 : 0.1, dy: y))
            let to = app.coordinate(withNormalizedOffset: CGVector(dx: towardsEnd ? 0.1 : 0.9, dy: y))
            from.press(forDuration: 0.05, thenDragTo: to, withVelocity: XCUIGestureVelocity(rawValue: 500), thenHoldForDuration: 0.2)
        }
    }

    func testTheMemoryGraphFindsLeavesOutAndDrifts() {
        launch(.signedIn)

        step("The graph has its controls") {
            openTheGraph()
            require(element("memory.graph.search"), "the search field")
            require(element("memory.graph.type.You"), "the pill for the person's own memories")
            require(element("memory.graph.type.Agent"), "the pill for the agent's memories")
            require(element("memory.graph.type.Page"), "the pill for the pages the memories are bridged to")
            require(element("memory.graph.unlinked"), "the Hide unlinked chip")
            require(element("graph.drift"), "the Drift button")
            XCTAssertEqual(element("graph.drift").label, "Drift")
            XCTAssertTrue(element("memory.graph.type.You").isSelected, "every kind of node starts on the map")
            XCTAssertFalse(element("memory.graph.unlinked").isSelected, "and nothing starts left out for having no links")
        }

        step("A memory is found by part of its name") {
            enter("passport", into: textField("memory.graph.search"), "the search field")
            require(button("Passport checklist, Agent"), "the match whose name starts with it")
            require(button("Trip to Lisbon: ferry and passports, You"), "the match with it in the middle of its name")
            requireGone(button("Planning chat with Sam, Chat"), "a memory without it in its name")
        }

        step("A search with no match says so, and clearing it takes the results away") {
            tap(button("Clear the search"), "the clear button", until: { !self.button("Passport checklist, Agent").exists })
            requireGone(button("Passport checklist, Agent"), "the results, once the search is cleared")
            enter("zzzz", into: textField("memory.graph.search"), "the search field")
            require(text("Nothing on the map has that in its name."), "the words for a search with no match")
            tap(button("Clear the search"), "the clear button", until: { !self.text("Nothing on the map has that in its name.").exists })
            putTheKeyboardAway()
            require(button("Passport checklist"), "the map, with nothing laid over it")
        }

        step("A kind of node can be left off the map and put back") {
            let pill = element("memory.graph.type.You")
            tap(pill, "the pill for the person's own memories", until: { !self.button("Reading list for the winter").exists })
            requireGone(button("Reading list for the winter"), "a memory of the kind that was left off")
            requireGone(button("Trip to Lisbon: ferry and passports"), "the other memory of that kind")
            require(button("Passport checklist"), "a memory of another kind, which stays")
            XCTAssertFalse(pill.isSelected, "the pill says it is off")
        }

        step("Hide unlinked leaves out the memory the hidden ones left with no links, and shows it again") {
            // "Passport checklist" was linked to the two that are off the map, and still shows until the chip is on.
            require(button("Passport checklist"), "the memory with no links left, still on the map")
            let chip = element("memory.graph.unlinked")
            scrollThePills(until: chip, towardsEnd: true)
            tap(chip, "the Hide unlinked chip", until: { !self.button("Passport checklist").exists })
            requireGone(button("Passport checklist"), "the memory with no links")
            XCTAssertTrue(chip.isSelected, "the chip says it is on")
            require(button("Planning chat with Sam"), "a memory that still has links, which stays")

            tap(chip, "the Hide unlinked chip", until: { self.button("Passport checklist").exists })
            require(button("Passport checklist"), "the memory, back with the chip off")
            XCTAssertFalse(chip.isSelected, "the chip says it is off")
        }

        step("Putting the kind back brings its memories back") {
            let pill = element("memory.graph.type.You")
            scrollThePills(until: pill, towardsEnd: false)
            tap(pill, "the pill for the person's own memories", until: { self.button("Reading list for the winter").exists })
            require(button("Reading list for the winter"), "the memory that was left off, back")
            require(button("Trip to Lisbon: ferry and passports"), "the other one, back")
            XCTAssertTrue(pill.isSelected, "the pill says it is on")
        }

        step("Drift selects a node and shows what it is") {
            let drift = element("graph.drift")
            XCTAssertFalse(element("graph.open").exists, "nothing is selected before the tour starts")
            tap(drift, "the Drift button", until: { self.element("graph.open").exists })
            require(element("graph.open"), "the callout of the node the tour is on")
            require(text(containing: "connection"), "the callout's words about the node's links")
            waitUntil("the button to say it can stop the tour") { self.element("graph.drift").label == "Stop drifting" }
            XCTAssertTrue(element("graph.drift").isSelected, "and to look pressed in")
        }

        step("Tapping the button again ends the tour and leaves the node selected") {
            tap(element("graph.drift"), "the Stop drifting button", until: { self.element("graph.drift").label == "Drift" })
            waitUntil("the button to say Drift again") { self.element("graph.drift").label == "Drift" }
            XCTAssertFalse(element("graph.drift").isSelected, "and to look as it did")
            require(element("graph.open"), "the callout, still there")
        }
    }
}
