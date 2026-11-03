#if DEBUG
import HyperVaultKit
import SwiftUI

/// Canned answers for the overview of the Eurorack Choir Module project, for previews and snapshots: the board
/// (`TaskBoardPreviewData`), the pages the Library graph reads, the links, the memories and the chats.
///
/// What the vault holds, and why each thing is on the overview:
/// - "Power supply notes" is joined to the board page by hand (Linked), "Panel drawings" carries the project's tag (Tagged),
///   "Trip to Lisbon" was joined by the server's guess (Possibly related, behind "Show possibly related"), and "Garden
///   — Task Board" is another board the server joined by the same guess, which the overview leaves out.
/// - "Power budget" is a memory joined by hand (Linked), "Bench notes" is tagged, "Choir module wiring" has the project's
///   name in its title (Mentions it, although the server also joined it to the board page by its guess, which it does to
///   most memories that share words with a page), and "Planning chat with Sam" is a chat's own memory, which is never listed.
/// - "Eurorack choir front panel quotes" and "Choir module power budget" are chats whose titles are about the project.
enum ProjectPreviewData {
    static let project = "eurorack-choir"

    /// The Library graph's read of the `artifacts` table (`LibraryGraphRow.pages`): row ids, slugs, titles, tags.
    static let pagesJSON = #"""
    [{"id":"art-board-choir","slug":"taskboard-eurorack-choir","title":"Eurorack Choir Module \#u{2014} Task Board","type":"html","tags":["taskboard","eurorack-choir"],"is_jsx":false},
     {"id":"art-data-choir","slug":"tasks-eurorack-choir","title":"Tasks \#u{2014} Eurorack Choir Module","type":"html","tags":["tasklist","eurorack-choir"],"is_jsx":false},
     {"id":"art-psu","slug":"power-supply-notes-k3x9a2","title":"Power supply notes","type":"markdown","tags":[],"is_jsx":false},
     {"id":"art-panels","slug":"panel-drawings-x1","title":"Panel drawings","type":"html","tags":["eurorack-choir","cad"],"is_jsx":false},
     {"id":"art-lisbon","slug":"trip-to-lisbon-q7","title":"Trip to Lisbon","type":"html","tags":[],"is_jsx":false},
     {"id":"art-garden-board","slug":"taskboard-garden","title":"Spring garden \#u{2014} Task Board","type":"html","tags":["taskboard","garden"],"is_jsx":false}]
    """#

    /// `GET /api/connections`: the hand-made link to the power supply notes, the server's guesses at the Lisbon page and at
    /// the garden board, a memory joined to the board page by hand, and the server's guess at the memory that is also titled
    /// for the project (which the overview keeps for its name).
    static let connectionsJSON = #"""
    {"connections":[
       {"id":"e1","a_id":"art-board-choir","b_id":"art-psu","kind":"manual","created_at":"2026-10-21T09:00:00Z"},
       {"id":"e2","a_id":"art-board-choir","b_id":"art-lisbon","kind":"auto","created_at":"2026-10-21T09:00:00Z"},
       {"id":"e3","a_id":"art-board-choir","b_id":"art-garden-board","kind":"auto","created_at":"2026-10-21T09:00:00Z"},
       {"id":"e4","a_id":"art-board-choir","b_id":"art-data-choir","kind":"manual","created_at":"2026-10-20T09:00:00Z"}],
     "memory_links":[],
     "memory_artifact_links":[
       {"id":"b1","memory_id":"m-power","artifact_id":"art-board-choir","kind":"manual","created_at":"2026-10-22T09:00:00Z"},
       {"id":"b2","memory_id":"m-chat","artifact_id":"art-board-choir","kind":"auto","created_at":"2026-10-22T09:00:00Z"},
       {"id":"b3","memory_id":"m-wiring","artifact_id":"art-board-choir","kind":"auto","created_at":"2026-10-20T09:30:00Z"}]}
    """#

    static let memoriesJSON = #"""
    {"branch":"main","memories":[
      {"id":"m-power","title":"Power budget","summary":"Plus and minus twelve volts, 600 mA each.","tags":["power"],"source":"manual","created_at":"2026-10-24T08:15:00Z"},
      {"id":"m-bench","title":"Bench notes","summary":"Scope probes, the good iron.","tags":["eurorack-choir"],"source":"agent","created_at":"2026-10-23T14:02:00Z"},
      {"id":"m-wiring","title":"Choir module wiring","summary":"Ribbon pinout and the jumper at J3.","tags":[],"source":"coding","created_at":"2026-10-20T09:30:00Z"},
      {"id":"m-chat","title":"Chat: Choir module power budget","summary":"","tags":[],"source":"chat","created_at":"2026-10-19T10:00:00Z"},
      {"id":"m-dinner","title":"Dinner ideas","summary":"Soup.","tags":[],"source":"manual","created_at":"2026-10-12T10:00:00Z"}]}
    """#

    static var conversationsJSON: String {
        func row(_ id: String, _ title: String, _ seconds: Double) -> String {
            let now = Date()
            let made = HVDate.format(now.addingTimeInterval(-seconds - 3_600)), moved = HVDate.format(now.addingTimeInterval(-seconds))
            return #"{"id":"\#(id)","title":"\#(title)","source_platform":"hypervault","model":null,"created_at":"\#(made)","updated_at":"\#(moved)","visibility":"private","share_slug":null}"#
        }
        return """
        {"conversations":[
          \(row("c-quotes", "Eurorack choir front panel quotes", 7_200)),
          \(row("c-budget", "Choir module power budget", 90_000)),
          \(row("c-dinner", "Dinner ideas for Saturday", 100_000))]}
        """
    }

    /// Everything the overview reads, all of it answering.
    static var overviewRoutes: [MockRoute] {
        TaskBoardPreviewData.boardRoutes + relatedRoutes
    }

    private static var relatedRoutes: [MockRoute] {
        [
            .json(.get, "/rest/v1/artifacts", pagesJSON),
            .json(.get, "/api/connections", connectionsJSON),
            .json(.get, "/api/memories", memoriesJSON),
            .json(.get, "/api/conversations", conversationsJSON),
        ]
    }

    /// A project with nine pages tagged for it: a section shows six and "Show 3 more".
    static var longRoutes: [MockRoute] {
        let board = #"{"id":"art-board-choir","slug":"taskboard-eurorack-choir","title":"Eurorack Choir Module \#u{2014} Task Board","type":"html","tags":["taskboard","eurorack-choir"],"is_jsx":false}"#
        let tagged = (1...9).map { #"{"id":"art-t\#($0)","slug":"choir-notes-\#($0)","title":"Choir notes \#($0)","type":"markdown","tags":["eurorack-choir"],"is_jsx":false}"# }
        return [.json(.get, "/rest/v1/artifacts", "[" + ([board] + tagged).joined(separator: ",") + "]")] + overviewRoutes
    }

    /// A project with a board and nothing else in the vault.
    static var emptyRoutes: [MockRoute] {
        TaskBoardPreviewData.boardRoutes + [
            .json(.get, "/rest/v1/artifacts", "[]"),
            .json(.get, "/api/connections", #"{"connections":[],"memory_links":[],"memory_artifact_links":[]}"#),
            .json(.get, "/api/memories", #"{"branch":"main","memories":[]}"#),
            .json(.get, "/api/conversations", #"{"conversations":[]}"#),
        ]
    }

    /// The chat list will not load while the rest does: that section says so and the others still show.
    static var partialRoutes: [MockRoute] {
        [.failure(.get, "/api/conversations", status: 500, message: "The chat list is not available.")] + overviewRoutes
    }

    /// A link to a project that is not in this vault: the board is a 404, and nothing else is said.
    static var missingRoutes: [MockRoute] {
        [.failure(.get, "/api/tasklists/eurorack-choir", status: 404, message: "No task list named eurorack-choir.")] + relatedRoutes
    }
}
#endif
