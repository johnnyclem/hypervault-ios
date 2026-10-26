#if DEBUG
import HyperVaultKit
import SwiftUI

/// Canned answers for previews and snapshots.
enum TaskBoardPreviewData {
    static let listing = TaskBoardListing(
        slug: "tasks-eurorack-choir", project: "eurorack-choir", title: "Tasks — Eurorack Choir Module",
        url: "https://preview.hypervault.test/a/tasks-eurorack-choir"
    )

    static var boardJSON: String {
        let now = HVDate.format(Date())
        let later = HVDate.format(Date().addingTimeInterval(3000))
        let earlier = HVDate.format(Date().addingTimeInterval(-3600))
        return """
        {"$schema":"https://hypervault.store/schemas/tasklist-v1.json","schemaVersion":1,"id":"eurorack-choir",
         "title":"Eurorack Choir Module","version":42,"settings":{},"createdAt":"\(earlier)","updatedAt":"\(now)",
         "tasks":[
          {"id":"epic-hw","title":"Hardware","type":"epic","status":"in_progress","assignee":{"kind":"unassigned"},"parent":null,"children":["t-panels","t-psu"]},
          {"id":"t-panels","title":"Order the front panels","type":"task","status":"in_progress","priority":"high","activeForm":"Comparing three quotes",
           "assignee":{"kind":"agent","name":"Claude Code","agentType":"claude-code"},"progress":60,"parent":"epic-hw",
           "lock":{"by":"Claude Code","agentType":"claude-code","at":"\(now)","expiresAt":"\(later)"},
           "notes":[{"id":"n1","author":"johnny","authorKind":"human","body":"Keep it under $80","createdAt":"\(earlier)"},{"id":"n2","author":"Claude Code","authorKind":"agent","body":"Two quotes in, one to go.","createdAt":"\(now)"}]},
          {"id":"t-psu","title":"Pick a power supply","type":"task","status":"todo","assignee":{"kind":"unassigned"},"parent":"epic-hw"},
          {"id":"t-fw","title":"Wait for the firmware drop","type":"task","status":"blocked","assignee":{"kind":"unassigned"}},
          {"id":"t-review","title":"Review the schematic","type":"task","status":"review","assignee":{"kind":"human","name":"johnny"}},
          {"id":"t-doc","title":"Write the manual","type":"task","status":"done","assignee":{"kind":"human","name":"johnny"},"completedAt":"\(earlier)"},
          {"id":"t-logo","title":"Draw the logo","type":"task","status":"done","assignee":{"kind":"agent","name":"Gemini"}}
         ]}
        """
    }

    static var summaryJSON: String {
        #"{"slug":"tasks-eurorack-choir","summary":{"id":"eurorack-choir","title":"Eurorack Choir Module","version":42,"total":7,"byStatus":{"todo":1,"in_progress":2,"blocked":1,"review":1,"done":2,"cancelled":0},"progress":29,"epics":[{"id":"epic-hw","title":"Hardware","total":2,"done":0,"progress":0}],"claimed":[{"taskId":"t-panels","by":"Claude Code","agentType":"claude-code"}],"unassigned":2}}"#
    }

    static var indexRoutes: [MockRoute] {
        [
            .json(.get, "/api/taskboards", """
            {"boards":[
             {"slug":"tasks-eurorack-choir","project":"eurorack-choir","title":"Tasks — Eurorack Choir Module","url":"https://x/a/tasks-eurorack-choir","created_at":"2026-10-20T09:00:00.000Z","updated_at":null},
             {"slug":"tasks-garden","project":"garden","title":"Tasks — Spring garden","url":"https://x/a/tasks-garden","created_at":"2026-10-12T09:00:00.000Z","updated_at":null}],
             "schema":"x"}
            """),
            .json(.get, "/api/tasklists/eurorack-choir/summary", summaryJSON),
            .json(.get, "/api/tasklists/garden/summary", #"{"slug":"tasks-garden","summary":{"id":"garden","title":"Spring garden","version":3,"total":4,"byStatus":{"todo":3,"done":1},"progress":25,"epics":[],"claimed":[],"unassigned":3}}"#),
        ]
    }

    static var boardRoutes: [MockRoute] {
        [.json(.get, "/api/tasklists/eurorack-choir", #"{"slug":"tasks-eurorack-choir","tasklist":\#(boardJSON)}"#)]
    }
}
#endif
