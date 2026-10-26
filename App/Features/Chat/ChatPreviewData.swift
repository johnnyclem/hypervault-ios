#if DEBUG
import HyperVaultKit
import SwiftUI

/// Canned answers for previews and snapshot tests: what the server says, in the
/// shapes its routes really use.
enum ChatPreviewData {
    private static func ago(_ seconds: Double) -> String {
        HVDate.format(Date().addingTimeInterval(-seconds))
    }

    // MARK: Routes

    static var routes: [MockRoute] {
        [
            .json(.get, "/api/conversations", conversationsJSON),
            .json(.get, "/api/conversations/c1", detailJSON),
            .json(.get, "/api/backends", backendsJSON),
            .json(.get, "/api/chat-settings", #"{"smart_context":true,"deep_memory":false,"polytician":true,"truth":true}"#),
            .json(.get, "/api/toolkits", #"{"toolkit":null,"stale":false}"#),
            .json(.get, "/api/rooms", roomsJSON),
            .json(.get, "/api/rooms/r1", roomJSON),
            .json(.post, "/api/chat", turnJSON),
        ]
    }

    static var conversationsJSON: String {
        func row(_ id: String, _ title: String, _ platform: String, _ seconds: Double, visibility: String = "private", slug: String? = nil) -> String {
            let slugValue = slug.map { "\"\($0)\"" } ?? "null"
            return #"{"id":"\#(id)","title":"\#(title)","source_platform":"\#(platform)","model":null,"created_at":"\#(ago(seconds + 3_600))","updated_at":"\#(ago(seconds))","visibility":"\#(visibility)","share_slug":\#(slugValue)}"#
        }
        return """
        {"conversations":[
          \(row("c1", "Three days in Lisbon", "hypervault", 1_200, visibility: "shared", slug: "three-days-in-lisbon-a1b2")),
          \(row("c2", "Refactor the sync engine", "hypervault", 10_800)),
          \(row("c3", "Dinner ideas for Saturday", "hypervault", 100_000)),
          \(row("c4", "Quarterly planning notes", "chatgpt", 259_200)),
          \(row("c5", "Reading list for the autumn", "claude", 1_209_600)),
          \(row("c6", "Invoice template", "gemini", 3_500_000)),
          \(row("c7", "Shell one-liners I keep forgetting", "grok", 7_800_000))
        ]}
        """
    }

    static var detailJSON: String {
        func message(_ id: String, _ role: String, _ content: JSONValue, _ position: Int, _ seconds: Double, feedback: JSONValue = .null) -> JSONValue {
            ["id": .string(id), "role": .string(role), "content": content, "attachments": [], "model": role == "user" ? .null : "claude-opus-4-8",
             "position": .int(position), "created_at": .string(ago(seconds)), "feedback": feedback]
        }
        let toolRequest = "Let me check your calendar first.\n\n```tool\n{\"intent\":\"list events in March\",\"args\":{}}\n```"
        let toolResult = "```tool-result\n{\"intent\":\"list events in March\",\"tool\":\"calendar.list\",\"ok\":true,\"confidence\":0.93,\"tier\":\"high\",\"content\":\"No events 12 to 15 March.\"}\n```"
        let body: JSONValue = [
            "conversation": ["id": "c1", "title": "Three days in Lisbon", "source_platform": "hypervault", "model": "claude-opus-4-8",
                             "created_at": .string(ago(4_800)), "updated_at": .string(ago(1_200)), "visibility": "shared", "share_slug": "three-days-in-lisbon-a1b2"],
            "messages": [
                message("m0", "user", "Can you plan a three-day trip to Lisbon in March? We like walking, food and not queueing.", 0, 4_800),
                message("m1", "assistant", .string(toolRequest), 1, 4_790),
                message("m2", "tool", .string(toolResult), 2, 4_789),
                message("m3", "assistant", .string(plan), 3, 4_780, feedback: 1),
                message("m4", "user", "Lovely. Put the tram route in a script I can paste into my notes.", 4, 1_300),
                message("m5", "assistant", .string(script), 5, 1_290),
            ],
        ]
        return body.jsonString()
    }

    static let plan = """
    Here is a relaxed plan that keeps the queues short.

    ## Day one: Alfama and the river
    - Morning: walk up through **Alfama** before the tour groups arrive
    - Lunch at a tasca near the market (book the 12:30 table)
    - Evening: *miradouro* at sunset, then dinner in Baixa

    ## Day two: Belem
    1. Take the 15 tram at opening time
    2. Pasteis first, monastery second
    3. Walk the river back

    > Tip: buy the 24-hour transit pass on day one.

    Want me to turn this into a checklist?
    """

    static let script = """
    Here you go. It prints the stops in order:

    ```bash
    #!/usr/bin/env bash
    stops=("Praca do Comercio" "Alfama" "Belem")
    for stop in "${stops[@]}"; do
      echo "Tram 15 -> $stop"
    done
    ```

    Save it as `tram.sh` and run `bash tram.sh`.
    """

    static var backendsJSON: String {
        """
        {"backends":[
          {"id":"b1","name":"Claude","provider":"anthropic","base_url":null,"default_model":"claude-opus-4-8","embedding_model":null,"key_hint":"sk-ant-\u{2026}","created_at":"\(ago(900_000))","last_used_at":"\(ago(1_200))"},
          {"id":"b2","name":"GPT","provider":"openai","base_url":null,"default_model":"gpt-4o","embedding_model":"text-embedding-3-small","key_hint":"sk-proj\u{2026}","created_at":"\(ago(800_000))","last_used_at":"\(ago(300_000))"},
          {"id":"b3","name":"Studio Llama","provider":"ollama","base_url":"https://studio.example.ts.net/v1","default_model":"llama3.3","embedding_model":null,"key_hint":null,"created_at":"\(ago(100_000))","last_used_at":null}
        ],"providers":[]}
        """
    }

    static let turnJSON = """
    {"conversation_id":"c9","reply":{"id":"m12","role":"assistant","content":"Done.","model":"claude-opus-4-8","truncated":false},
     "backend":{"id":"b1","name":"Claude","provider":"anthropic"},"recalled":[],"recalled_memories":[],"pulled":[],
     "recall_branch":"main","smart_context":false,"deep_memory":null,"truth":null,
     "tools":{"status":"off","toolkit_id":null,"turns":[],"embedder":null},"tool_selection":null}
    """

    static var roomsJSON: String {
        """
        {"rooms":[
          {"id":"r1","title":"Features X and Y","pending":[{"handle":"gemini","reason":"The user spoke to the room."}],"created_at":"\(ago(90_000))","updated_at":"\(ago(600))",
           "members":[\(memberJSON("m1", "grok", "Grok", "xai", "grok-4", 0)),\(memberJSON("m2", "gemini", "Gemini", "gemini", "gemini-2.5-pro", 1)),\(memberJSON("m3", "claude", "Claude", "anthropic", "claude-opus-4-8", 2))]},
          {"id":"r2","title":"Weekly review","pending":[],"created_at":"\(ago(900_000))","updated_at":"\(ago(400_000))",
           "members":[\(memberJSON("m4", "claude", "Claude", "anthropic", "claude-opus-4-8", 0)),\(memberJSON("m5", "gpt", "GPT", "openai", "gpt-4o", 1))]}
        ]}
        """
    }

    private static func memberJSON(_ id: String, _ handle: String, _ name: String, _ provider: String, _ model: String, _ position: Int) -> String {
        #"{"id":"\#(id)","room_id":"r1","backend_id":"b-\#(handle)","handle":"\#(handle)","role_brief":"","position":\#(position),"backend":{"name":"\#(name)","provider":"\#(provider)","default_model":"\#(model)"}}"#
    }

    static var roomJSON: String {
        func message(_ id: String, _ position: Int, _ kind: String, _ handle: String?, _ content: String, mentions: [String] = [], tools: String = "[]", status: String = "complete", seconds: Double) -> String {
            let handleValue = handle.map { "\"\($0)\"" } ?? "null"
            let escaped = JSONValue.string(content).jsonString()
            let mentionList = mentions.map { "\"\($0)\"" }.joined(separator: ",")
            return #"{"id":"\#(id)","room_id":"r1","position":\#(position),"sender_kind":"\#(kind)","sender_handle":\#(handleValue),"member_id":null,"content":\#(escaped),"mentions":[\#(mentionList)],"tool_turns":\#(tools),"model":null,"status":"\#(status)","created_at":"\#(ago(seconds))"}"#
        }
        return """
        {"room":{"id":"r1","title":"Features X and Y","pending":[{"handle":"gemini","reason":"@grok handed you the turn"}],"budget":9,"running":false,"truth_ledgers":null,"created_at":"\(ago(90_000))","updated_at":"\(ago(600))"},
         "members":[\(memberJSON("m1", "grok", "Grok", "xai", "grok-4", 0)),\(memberJSON("m2", "gemini", "Gemini", "gemini", "gemini-2.5-pro", 1)),\(memberJSON("m3", "claude", "Claude", "anthropic", "claude-opus-4-8", 2))],
         "messages":[
          \(message("x1", 0, "human", nil, "grok - you take the importer; gemini - you take the UI; claude - architecture first, then review both.", mentions: ["grok", "gemini", "claude"], seconds: 900)),
          \(message("x2", 1, "agent", "claude", "Schema is up. The importer reads one file at a time and the UI only needs the **summary** table.\n\n@grok the API contract is yours now.", mentions: ["grok"], tools: #"[{"tool":"create_artifact","ok":true,"summary":"Created plan-x7k2","url":"https://hv.test/a/plan-x7k2","slug":"plan-x7k2"}]"#, seconds: 800)),
          \(message("x3", 2, "agent", "grok", "On it. Contract committed as v3; the importer streams rows in batches of 500. @gemini the endpoint is ready.", mentions: ["gemini"], seconds: 700)),
          \(message("x4", 3, "agent", "gemini", "(@gemini couldn't reply: The endpoint timed out.)", status: "error", seconds: 650)),
          \(message("x5", 4, "system", nil, "Paused: this round used its 12-turn budget before @claude could speak. Send another message to start a new round.", seconds: 600))
         ]}
        """
    }

    // MARK: Models

    static let sampleLocal = ChatLocalModel(
        id: "l1", name: "Studio Llama", baseURL: "http://192.168.1.20:11434/v1", model: "llama3.3"
    )

    static func support(onDevice: Bool = false) -> ChatOnDeviceSupport {
        .fixed(onDevice ? .ready : .unavailable("This iPhone can't run Apple Intelligence, so it can't write replies itself."), localModels: [sampleLocal])
    }

    @MainActor
    static func client() -> HVClient {
        HVClient(
            baseURL: URL(string: "https://preview.hypervault.test")!,
            transport: MockTransport(routes: routes),
            tokens: StaticTokenProvider()
        )
    }

    /// A conversation with a live turn in it: sources, a tool step, a reply with code.
    @MainActor
    static func conversationModel(working: Bool = false, onDevice: Bool = false, empty: Bool = false, firstTurnOnly: Bool = false, local: Bool = false) -> ChatConversationModel {
        let env = AppEnvironment.preview(routes: routes)
        let model = ChatConversationModel(
            conversationID: nil, client: env.client, cache: env.cache, namespace: "preview",
            limits: env.limits, features: env.features, onDevice: support(onDevice: onDevice),
            outbox: ChatTurnOutbox(cache: env.cache, namespace: "preview")
        )
        let grounding = ChatGrounding(
            pages: [ChatRecalledPage(title: "Lisbon trip notes", slug: "lisbon-trip-ab12")],
            memories: ["Walking preferences", "Passport and visas"],
            deepMemory: [],
            truth: ChatTruthSummary(cited: 2, contested: 1, flags: 0, drafted: 0, ledgers: ["default"]),
            pulled: [ChatPulledUse(kind: .memory, id: "mem1", title: "Lisbon trip notes")]
        )
        let detail = try? HVCoding.decoder().decode(ChatConversationDetail.self, from: Data(detailJSON.utf8))
        var rows = ChatThreadRow.hydrate(detail?.messages ?? [])
        if let index = rows.lastIndex(where: { $0.kind == .assistant }) {
            rows[index].grounding = grounding
        }
        if working {
            rows.append(ChatThreadRow(kind: .user, text: "Now turn the plan into a packing list, grouped by day.", state: .sending))
        }
        let backends = (try? HVCoding.decoder().decode(PreviewBackends.self, from: Data(backendsJSON.utf8)))?.backends ?? []
        if firstTurnOnly {
            rows = rows.filter { $0.id == "m0" || $0.id == "m3" }
        }
        if empty {
            model.seed(rows: [], backends: backends, choice: .server("b1"))
            return model
        }
        model.seed(
            rows: rows, backends: backends,
            conversation: ChatConversation(id: "c1", title: "Three days in Lisbon", visibility: .shared, shareSlug: "three-days-in-lisbon-a1b2"),
            choice: local ? .local(sampleLocal.id) : (onDevice ? .onDevice : .server("b1")),
            working: working ? Date().addingTimeInterval(-14) : nil,
            keptNotes: rows.lastIndex(where: { $0.kind == .assistant }).map { [rows[$0].id: ChatKeptNote(slug: "tram-script-x1", url: nil, duplicate: false, isPrivate: true)] } ?? [:]
        )
        return model
    }

    private struct PreviewBackends: Decodable { let backends: [ChatBackend] }
}
#endif
