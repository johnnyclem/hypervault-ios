#if DEBUG
import HyperVaultKit
import SwiftUI

/// Canned answers for previews and snapshot tests, in the shapes the routes
/// really send (app/api/memories, app/api/mind, app/api/dreams, app/api/digest).
enum MemoryPreviewData {
    static let memories = #"""
    {"branch":"main","memories":[
      {"id":"m1","title":"Trip to Lisbon: ferry and passports","summary":"Book the Friday ferry across the Tagus. Bring both passports and the printed tickets, the app is flaky on the pier.","tags":["trip","ferry","passports"],"source":"manual","created_at":"2026-10-22T08:15:00Z"},
      {"id":"m2","title":"Auth decision: passkeys first","summary":"We chose passkeys with email codes as the fallback. No passwords, no SMS. Revisit after the beta.","tags":["auth","decision","passkeys"],"source":"coding","created_at":"2026-10-20T14:02:00Z"},
      {"id":"m3","title":"Planning chat with Sam","summary":"Budget is set at 40k, ship in March, hire one more engineer in January if the beta holds.","tags":["planning","budget"],"source":"chat","created_at":"2026-10-18T09:30:00Z"},
      {"id":"m4","title":"Quarterly report","summary":"Revenue up 12 percent, churn flat, support load down after the onboarding rewrite.","tags":["report","pdf","notes"],"source":"file","created_at":"2026-10-12T10:00:00Z"},
      {"id":"m5","title":"owner/hypervault-ios","summary":"A native SwiftUI client for HyperVault: Kit models, endpoints and tests, a design system, and one folder per feature.","tags":["swift","ios","github"],"source":"github","created_at":"2026-10-08T16:40:00Z"},
      {"id":"m6","title":"Passport checklist","summary":"Where they are, when they expire, and what the consulate needs for a renewal.","tags":["passports","admin"],"source":"agent","created_at":"2026-09-30T11:11:00Z"},
      {"id":"m7","title":"Reading list for the winter","summary":"Four books and two papers on local-first software and memory systems.","tags":["reading"],"source":"manual","created_at":"2025-12-02T19:20:00Z"}
    ]}
    """#

    static let recall = #"""
    {"query":"ferry","branch":"main","recall_mode":"hybrid","results":[
      {"id":"m1","title":"Trip to Lisbon: ferry and passports","summary":"Book the Friday ferry across the Tagus.","tags":["trip","ferry","passports"],"source":"manual","created_at":"2026-10-22T08:15:00Z","score":0.84,
       "content":"Book the Friday ferry across the Tagus. Bring both passports and the printed tickets, the app is flaky on the pier. Leave by seven so we make the early crossing before the queue builds up at the terminal.",
       "related":["Passport checklist"],
       "provenance":{"commit_id":"a47d1e60-3c58-4b19-92f7-d8e05b6a1c07","message":"memorize: Trip to Lisbon","author_kind":"user","committed_at":"2026-10-22T08:15:01Z"}},
      {"id":"m6","title":"Passport checklist","summary":"Where they are, when they expire, and what the consulate needs for a renewal.","tags":["passports","admin"],"source":"agent","created_at":"2026-09-30T11:11:00Z","score":0.41,
       "content":"Both passports are in the grey folder. Sam's expires in March, so renew before booking anything past spring.",
       "related":["Trip to Lisbon: ferry and passports"],
       "provenance":{"commit_id":"8b41d07a-2c93-4f55-a6e0-1d7c93b4e802","message":"memorize: Passport checklist","author_kind":"agent","author_key_prefix":"hv_ab12cdef","committed_at":"2026-09-30T11:11:02Z"}}
    ],"message":"Recalled 2 matching memories."}
    """#

    static let page = #"""
    {"branch":"main",
     "memory":{"id":"m1","title":"Trip to Lisbon: ferry and passports","content":"# Lisbon, first weekend\n\nBook the **Friday ferry** across the Tagus. Bring both passports and the printed tickets, the app is flaky on the pier.\n\n## Packing\n\n- Passports (grey folder)\n- Printed tickets\n- Layers: it is windy on the water\n\n> Leave by seven so we make the early crossing before the queue builds up at the terminal.\n\nSee also the passport checklist.","summary":"Book the Friday ferry across the Tagus. Bring both passports and the printed tickets.","tags":["trip","ferry","passports"],"source":"manual","created_at":"2026-10-22T08:15:00Z"},
     "related":[{"id":"m6","title":"Passport checklist","summary":"Where they are, when they expire, and what the consulate needs for a renewal.","tags":["passports","admin"]}],
     "artifacts":[{"id":"a1","slug":"trip-plan","title":"Lisbon trip plan","type":"note"}],
     "provenance":{"commit_id":"c92e5f13-aa6d-4b08-8f3c-62d0b1e7a903","message":"edit: Trip to Lisbon","author_kind":"user","committed_at":"2026-10-23T09:00:00Z"},
     "revision_count":3,
     "truth":{"stale":1,"rests_on":[{"ledger":"default","entry":{"id":"TB-12","type":"TB","status":"held","standing":"upheld","reasons":[],"text":"The Friday ferry leaves at 07:10.","signedBy":null,"answerableBy":null},"relation":"rests_on","seen_status":"held","seen_standing":"upheld","stale_since":"2026-10-24T10:00:00Z","stale_kind":"struck","stale_by":"sam","stale_summary":"TB-12 was restated: the ferry now leaves at 07:40.","successor":null}]}}
    """#

    static let history = #"""
    {"memory_id":"m1","revisions":[
      {"revision_id":"r3","op":"update","title":"Trip to Lisbon: ferry and passports","summary":"s","tags":["trip","ferry"],"source":"manual","commit":{"id":"c3","message":"edit: Trip to Lisbon","author_kind":"user","branch":"main","created_at":"2026-10-23T09:00:00Z"}},
      {"revision_id":"r2","op":"update","title":"Trip to Lisbon","summary":"s","tags":["trip"],"source":"manual","commit":{"id":"c2","message":"Add the packing list","author_kind":"agent","author_key_prefix":"hv_ab12cdef","branch":"main","created_at":"2026-10-22T18:30:00Z"}},
      {"revision_id":"r1","op":"create","title":"Trip to Lisbon","summary":"s","tags":["trip"],"source":"manual","commit":{"id":"c1","message":"memorize: Trip to Lisbon","author_kind":"user","branch":"main","created_at":"2026-10-22T08:15:00Z"}}
    ]}
    """#

    static let memoryDiff = #"""
    {"from":{"ref":"c2","commit_id":"c2"},"to":{"ref":"c3","commit_id":"c3"},"memory_id":"m1","title_from":"Trip to Lisbon","title_to":"Trip to Lisbon: ferry and passports","tags_added":["ferry","passports"],"tags_removed":[],"status":"changed",
     "diff":{"hunks":[{"oldStart":2,"oldLines":5,"newStart":2,"newLines":6,"lines":[{"kind":"ctx","text":""},{"kind":"ctx","text":"Book the **Friday ferry** across the Tagus."},{"kind":"del","text":"Bring the passports."},{"kind":"add","text":"Bring both passports and the printed tickets, the app is flaky on the pier."},{"kind":"add","text":"Leave by seven."},{"kind":"ctx","text":""},{"kind":"ctx","text":"## Packing"}]}],"oversize":false}}
    """#

    static let branches = #"""
    {"branches":[
      {"id":"b1","name":"main","is_default":true,"head_commit_id":"c9","created_at":"2026-09-01T00:00:00Z","memory_count":184},
      {"id":"b2","name":"research/quantum","is_default":false,"head_commit_id":"c12","created_at":"2026-10-10T00:00:00Z","memory_count":52},
      {"id":"b3","name":"ideas","is_default":false,"head_commit_id":"c13","created_at":"2026-10-11T00:00:00Z","memory_count":7}
    ]}
    """#

    static let commits = #"""
    {"branch":"main","commits":[
      {"id":"3f2a9c1e-7b40-4d0a-9c11-5e8a0d2f6b01","message":"merge ideas into main","author_kind":"user","parent_commit_id":"c8","merge_parent_commit_id":"c13","created_at":"2026-10-25T10:00:00Z","change_counts":{"created":2,"updated":1,"deleted":0,"links":3}},
      {"id":"8b41d07a-2c93-4f55-a6e0-1d7c93b4e802","message":"memorize: Passport checklist","author_kind":"agent","author_key_prefix":"hv_ab12cdef","parent_commit_id":"c7","created_at":"2026-10-24T10:00:00Z","change_counts":{"created":1,"updated":0,"deleted":0,"links":2}},
      {"id":"c92e5f13-aa6d-4b08-8f3c-62d0b1e7a903","message":"edit: Trip to Lisbon","author_kind":"user","parent_commit_id":"c6","created_at":"2026-10-23T09:00:00Z","change_counts":{"created":0,"updated":1,"deleted":0,"links":0}},
      {"id":"5d07b6e4-91fc-4e2a-b3d8-0a4f7c61d504","message":"forget: Old reading list","author_kind":"user","parent_commit_id":"c5","created_at":"2026-10-21T11:00:00Z","change_counts":{"created":0,"updated":0,"deleted":1,"links":0}},
      {"id":"e1a8c7f2-04b5-43d9-87ae-9c3b25f0d605","message":"import (file): Quarterly report","author_kind":"user","parent_commit_id":"c4","created_at":"2026-10-12T10:00:00Z","change_counts":{"created":1,"updated":0,"deleted":0,"links":1}},
      {"id":"0f6d3a98-bd12-4c77-a1e4-73e8b9c2f006","message":"genesis","author_kind":"system","created_at":"2026-09-01T00:00:00Z","change_counts":{"created":40,"updated":0,"deleted":0,"links":12}}
    ]}
    """#

    static let stateDiff = #"""
    {"from":{"ref":"main","commit_id":"c9"},"to":{"ref":"ideas","commit_id":"c13"},
     "memories":{
       "added":[{"id":"m20","title":"A second brain, but opinionated","tags":["ideas"]},{"id":"m21","title":"What if the graph dreamed?","tags":["ideas","dreams"]}],
       "removed":[{"id":"m7","title":"Reading list for the winter","tags":["reading"]}],
       "changed":[{"id":"m2","title_from":"Auth decision: passkeys first","title_to":"Auth decision: passkeys first","tags_added":["beta"],"tags_removed":[],"content_changed":true,
         "diff":{"hunks":[{"oldStart":1,"oldLines":3,"newStart":1,"newLines":4,"lines":[{"kind":"ctx","text":"We chose passkeys with email codes as the fallback."},{"kind":"del","text":"No passwords, no SMS."},{"kind":"add","text":"No passwords."},{"kind":"add","text":"SMS only for recovery, and only in the beta."},{"kind":"ctx","text":"Revisit after the beta."}]}],"oversize":false}}]},
     "links":{"added":[{"a_id":"m20","b_id":"m21","kind":"manual"}],"removed":[]}}
    """#

    static let state = #"""
    {"at":"2026-10-15T09:00:00.000Z","commit_id":"c5","memories":[
      {"id":"m4","title":"Quarterly report","summary":"Revenue up 12 percent, churn flat.","tags":["report"],"source":"file","committed_at":"2026-10-12T10:00:00Z"},
      {"id":"m7","title":"Reading list for the winter","summary":"Four books and two papers.","tags":["reading"],"source":"manual","committed_at":"2026-10-01T10:00:00Z"},
      {"id":"m2","title":"Auth decision: passkeys first","summary":"We chose passkeys with email codes as the fallback.","tags":["auth"],"source":"coding","committed_at":"2026-10-14T10:00:00Z"}],
     "links":[{"a_id":"m2","b_id":"m4","kind":"auto"}],
     "message":"Your mind held 3 memories and 1 link at that point."}
    """#

    static let connections = #"""
    {"connections":[],
     "memory_links":[
       {"id":"l1","a_id":"m1","b_id":"m6","kind":"manual","created_at":"2026-10-01T00:00:00Z"},
       {"id":"l2","a_id":"m2","b_id":"m3","kind":"auto","created_at":"2026-10-01T00:00:00Z"},
       {"id":"l3","a_id":"m3","b_id":"m4","kind":"auto","created_at":"2026-10-01T00:00:00Z"},
       {"id":"l4","a_id":"m2","b_id":"m5","kind":"auto","created_at":"2026-10-01T00:00:00Z"},
       {"id":"l5","a_id":"m6","b_id":"m7","kind":"auto","created_at":"2026-10-01T00:00:00Z"},
       {"id":"l6","a_id":"m4","b_id":"m5","kind":"auto","created_at":"2026-10-01T00:00:00Z"}],
     "memory_artifact_links":[{"id":"b1","memory_id":"m1","artifact_id":"a1","kind":"auto","created_at":"2026-10-01T00:00:00Z"},{"id":"b2","memory_id":"m5","artifact_id":"a2","kind":"auto","created_at":"2026-10-01T00:00:00Z"}]}
    """#

    static let yours = #"""
    {"recent":[],"results":[
      {"id":"a1","kind":"page","name":"Lisbon trip plan","summary":"","href":"/a/trip-plan"},
      {"id":"a2","kind":"page","name":"iOS client roadmap","summary":"","href":"/a/ios-roadmap"}]}
    """#

    static let dreams = #"""
    {"dreaming_enabled":true,"last_run_at":"2026-10-25T03:00:00.000Z","pending_count":4,"runs":[
      {"id":"run1","created_at":"2026-10-25T03:00:00Z","connections":[
        {"id":"d1","edge_type":"memory_memory","score":7,"reason":"shared tag: passports · common theme: ferry","a":{"kind":"memory","id":"m1","label":"Trip to Lisbon: ferry and passports"},"b":{"kind":"memory","id":"m6","label":"Passport checklist"}},
        {"id":"d2","edge_type":"memory_artifact","score":5,"reason":"common themes: auth, passkeys","a":{"kind":"memory","id":"m2","label":"Auth decision: passkeys first"},"b":{"kind":"artifact","id":"a2","label":"iOS client roadmap","slug":"ios-roadmap"}},
        {"id":"d3","edge_type":"memory_memory","score":3,"reason":"common theme: budget","a":{"kind":"memory","id":"m3","label":"Planning chat with Sam"},"b":{"kind":"memory","id":"m4","label":"Quarterly report"}},
        {"id":"d4","edge_type":"artifact_artifact","score":2,"reason":"shared tag: trip","a":{"kind":"artifact","id":"a1","label":"Lisbon trip plan","slug":"trip-plan"},"b":{"kind":"artifact","id":"a9","label":"(deleted artifact)"}}]}]}
    """#

    static let dreamsEmpty = #"{"dreaming_enabled":true,"last_run_at":"2026-10-25T03:00:00.000Z","pending_count":0,"runs":[]}"#

    static let digest = #"""
    {"digestion_enabled":true,"pending_count":1,"runs":[
      {"id":"dg1","source_memory_id":"m3","source_title":"Planning chat with Sam","strategy":"chat","created_at":"2026-10-25T09:00:00Z",
       "segments":[
         {"ordinal":0,"title":"Budget is set at 40k","summary":"We agreed the budget and what it covers.","tags":["budget","planning"],"reason":"Speaker turn"},
         {"ordinal":1,"title":"Ship in March","summary":"The beta has to hold through January before we commit to a date.","tags":["planning"],"reason":"Speaker turn"},
         {"ordinal":2,"title":"Hire one more engineer","summary":"Only if the beta holds; revisit the budget then.","tags":["budget","hiring"],"reason":"Speaker turn"}],
       "links":[{"a":0,"b":1,"kind":"sequence"},{"a":1,"b":2,"kind":"sequence"},{"a":0,"b":2,"kind":"theme"}]}]}
    """#

    static let digestEmpty = #"{"digestion_enabled":false,"pending_count":0,"runs":[]}"#

    static let conflicts = #"""
    {"error":"Merge has 2 conflicts — resolve and resubmit.","conflicts":[
      {"memory_id":"m2","base":{"memory_id":"m2","title":"Auth decision","content":"We chose passkeys.\nNo SMS.","summary":"s","tags":["auth"],"source":"coding"},
       "ours":{"memory_id":"m2","title":"Auth decision: passkeys first","content":"We chose passkeys with email codes.\nNo SMS.","summary":"s","tags":["auth"],"source":"coding"},
       "theirs":{"memory_id":"m2","title":"Auth decision","content":"We chose passkeys.\nSMS only for recovery.","summary":"s","tags":["auth","beta"],"source":"coding"},
       "hunks_ours":{"hunks":[{"oldStart":1,"oldLines":2,"newStart":1,"newLines":2,"lines":[{"kind":"del","text":"We chose passkeys."},{"kind":"add","text":"We chose passkeys with email codes."},{"kind":"ctx","text":"No SMS."}]}],"oversize":false},
       "hunks_theirs":{"hunks":[{"oldStart":1,"oldLines":2,"newStart":1,"newLines":2,"lines":[{"kind":"ctx","text":"We chose passkeys."},{"kind":"del","text":"No SMS."},{"kind":"add","text":"SMS only for recovery."}]}],"oversize":false}},
      {"memory_id":"m7","base":{"memory_id":"m7","title":"Reading list","content":"Four books.","summary":"s","tags":[],"source":"manual"},"ours":null,
       "theirs":{"memory_id":"m7","title":"Reading list","content":"Four books and two papers.","summary":"s","tags":[],"source":"manual"},
       "hunks_ours":{"hunks":[],"oversize":false},"hunks_theirs":{"hunks":[],"oversize":false}}]}
    """#

    /// The routes most screens need, answered the way the server would.
    static var routes: [MockRoute] {
        [
            MockRoute(.get, "/api/memories") { request in
                let isRecall = (request.url?.query ?? "").contains("q=")
                return HTTPResponse(status: 200, headers: ["content-type": "application/json"], data: Data((isRecall ? recall : memories).utf8))
            },
            .json(.get, "/api/memories/m1/history", history),
            .json(.get, "/api/memories/m1", page),
            .json(.get, "/api/memories/*", page),
            .json(.get, "/api/mind/branches", branches),
            .json(.get, "/api/mind/commits", commits),
            MockRoute(.get, "/api/mind/diff") { request in
                let isMemory = (request.url?.query ?? "").contains("memory_id=")
                return HTTPResponse(status: 200, headers: ["content-type": "application/json"], data: Data((isMemory ? memoryDiff : stateDiff).utf8))
            },
            .json(.get, "/api/mind/state", state),
            .json(.post, "/api/mind/merge", conflicts, status: 409),
            .json(.get, "/api/connections", connections),
            .json(.get, "/api/yours", yours),
            .json(.get, "/api/backends", #"{"backends":[{"id":"b1","name":"My Claude","provider":"anthropic","default_model":"claude"}],"providers":[]}"#),
            .json(.get, "/api/dreams", dreams),
            .json(.get, "/api/dreams/settings", #"{"enabled":true,"last_run_at":"2026-10-25T03:00:00.000Z"}"#),
            .json(.get, "/api/digest", digest),
            .json(.get, "/api/digest/settings", #"{"enabled":true}"#),
        ]
    }
}

/// Builds the Memory list model a screen needs, for previews and snapshots.
struct MemoryScreenHost<Content: View>: View {
    @Environment(AppEnvironment.self) private var env
    let content: (MemoryListModel) -> Content

    init(@ViewBuilder content: @escaping (MemoryListModel) -> Content) {
        self.content = content
    }

    var body: some View {
        Inner(env: env, content: content)
    }

    private struct Inner: View {
        @State private var list: MemoryListModel
        let content: (MemoryListModel) -> Content

        init(env: AppEnvironment, content: @escaping (MemoryListModel) -> Content) {
            _list = State(initialValue: MemoryListModel(env: env))
            self.content = content
        }

        var body: some View {
            content(list)
                .task {
                    await list.load()
                    await list.loadBranches()
                }
        }
    }
}

/// The tab, started in a given mode (and with a search typed), for snapshots.
struct MemoryTabPreview: View {
    @Environment(AppEnvironment.self) private var env
    var mode: MemoryMode = .search
    var query = ""

    var body: some View {
        MemoryTabScreen(env: env, mode: mode, query: query)
    }
}

#Preview("Memory") {
    PreviewHost(routes: MemoryPreviewData.routes) { MemoryRootView() }
}

#Preview("Recall") {
    PreviewHost(routes: MemoryPreviewData.routes) { MemoryTabPreview(query: "ferry") }
}

#Preview("Graph") {
    PreviewHost(routes: MemoryPreviewData.routes) { MemoryTabPreview(mode: .graph) }
}

#Preview("Ask") {
    PreviewHost(routes: MemoryPreviewData.routes) { MemoryTabPreview(mode: .ask) }
}

#Preview("Memory detail") {
    PreviewHost(routes: MemoryPreviewData.routes) { MemoryDetailView(id: "m1") }
}

#Preview("History") {
    PreviewHost(routes: MemoryPreviewData.routes) {
        MemoryScreenHost { list in MemoryHistoryView(memoryID: "m1", title: "Trip to Lisbon", branch: list.branch, env: list.env) }
    }
}

#Preview("Memorize") {
    PreviewHost(routes: MemoryPreviewData.routes) {
        MemoryScreenHost { list in MemorizeSheet(list: list) }
    }
}

#Preview("Branches") {
    PreviewHost(routes: MemoryPreviewData.routes) {
        MemoryScreenHost { list in MindBranchesView(list: list) }
    }
}

#Preview("Commits") {
    PreviewHost(routes: MemoryPreviewData.routes) {
        MemoryScreenHost { list in MindCommitLogView(list: list) }
    }
}

#Preview("Merge") {
    PreviewHost(routes: MemoryPreviewData.routes) {
        MemoryScreenHost { list in MindMergeView(source: "ideas", list: list) }
    }
}

#Preview("Dreams") {
    PreviewHost(routes: MemoryPreviewData.routes) { DreamsRootView() }
}

#Preview("Digest") {
    PreviewHost(routes: MemoryPreviewData.routes) { DigestRootView() }
}
#endif
