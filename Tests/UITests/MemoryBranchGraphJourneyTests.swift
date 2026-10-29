import XCTest

/// The Memory graph on a branch other than main: its links are the branch's own (read from the branch's state), not the
/// links of main that `/api/connections` carries.
///
/// In the canned world main has six links between memories and two memories bridged to pages (eight lines on the map);
/// the state it answers for any branch holds three memories and the one link between two of them. The page bridges are
/// the same on every branch, so a branch's map has that one link and the two bridges: three.
@MainActor
final class MemoryBranchGraphJourneyTests: HyperVaultUITestCase {
    private let dot = "\u{00B7}"

    func testAnotherBranchsGraphCountsItsOwnLinksNotMains() {
        launch(.signedIn)
        openTab("Memory")

        step("Main's graph counts main's links") {
            tap(segment("Graph"), "the Graph mode", until: { button("Fit the whole graph").exists })
            require(text("7 memories \(dot) 8 links"), "the caption with main's eight links")
            requireGone(text(containing: "could not be read"), "a note about links that could not be read")
        }

        step("Switching to a branch redraws the graph with that branch's links") {
            tap(button("Branch: main"), "the branch menu", until: { button("ideas").exists })
            tap(button("ideas"), "the ideas branch", until: { button("Branch: ideas").exists })
            require(text("7 memories \(dot) 3 links"), "the caption with the branch's own three lines")
            requireGone(text("7 memories \(dot) 8 links"), "main's count, now that another branch is showing")
        }

        step("The caption no longer says the links are main's") {
            requireGone(text(containing: "links are from main"), "the old note that the links were main's")
            requireGone(text(containing: "could not be read"), "a note about links that could not be read")
            require(button("Fit the whole graph"), "the graph, drawn")
        }

        step("Going back to main brings main's links back") {
            tap(button("Branch: ideas"), "the branch menu", until: { button("main").exists })
            tap(button("main"), "the main branch", until: { button("Branch: main").exists })
            require(text("7 memories \(dot) 8 links"), "the caption with main's eight links again")
        }
    }
}
