#if DEBUG
import HyperVaultKit
import SwiftUI

/// Canned answers for previews and snapshot tests, in the shapes the routes
/// really send (app/api/mcp-servers, app/api/toolkits, app/api/registry).
enum ToolsFixtures {
    private static func stamp(daysAgo: Double) -> String {
        HVDate.format(Date().addingTimeInterval(-daysAgo * 86_400))
    }

    static var serversJSON: String {
        """
        {"servers":[
          {"id":"s1","name":"Linear","url":"https://mcp.linear.app/mcp","enabled":true,"disabled_tools":["delete_issue"],
           "tools_cache":[
             {"name":"list_issues","description":"List the issues in a team, newest first.","input_schema":{"type":"object","properties":{"team_id":{"type":"string","description":"Which team"},"limit":{"type":"integer"}},"required":["team_id"]}},
             {"name":"create_issue","description":"Create an issue with a title and a description.","input_schema":{"type":"object","properties":{"title":{"type":"string"}},"required":["title"]}},
             {"name":"delete_issue","description":"Delete an issue for good.","input_schema":{"type":"object"}}],
           "introspected_at":"\(stamp(daysAgo: 3))","registry_id":"app.linear/mcp","created_at":"\(stamp(daysAgo: 30))",
           "has_auth":true,"secret_backed":true,"auth_type":"oauth"},
          {"id":"s2","name":"Team notes","url":"https://notes.example.com/mcp","enabled":true,"disabled_tools":[],
           "tools_cache":[
             {"name":"search_notes","description":"Search every note by words.","input_schema":{"type":"object"}},
             {"name":"read_note","description":"Read one note.","input_schema":{"type":"object"}}],
           "introspected_at":"\(stamp(daysAgo: 1))","registry_id":null,"created_at":"\(stamp(daysAgo: 12))",
           "has_auth":true,"secret_backed":false,"auth_type":"headers"},
          {"id":"s3","name":"Weather","url":"https://weather.example.com/mcp","enabled":false,"disabled_tools":[],
           "tools_cache":[{"name":"forecast","description":"Forecast for a place.","input_schema":{"type":"object"}}],
           "introspected_at":"\(stamp(daysAgo: 9))","registry_id":null,"created_at":"\(stamp(daysAgo: 20))",
           "has_auth":false,"secret_backed":false,"auth_type":"none"}
        ]}
        """
    }

    static var toolkitJSON: String {
        """
        {"toolkit":{"id":"k1","stats":{"toolCount":5,"uniqueSelectorCount":5,"providerCount":2,"collisionCount":0},
          "embedder":{"kind":"local"},"embedder_label":"semantic (MiniLM-L6-v2, 384d local)","compiled_at":"\(stamp(daysAgo: 2))"},"stale":true}
        """
    }

    static let registryJSON = """
    {"servers":[
      {"registryId":"app.linear/mcp","name":"mcp","description":"Find, create and update issues and projects in Linear.","url":"https://mcp.linear.app/mcp","transport":"streamable-http"},
      {"registryId":"com.github/mcp","name":"github","description":"Read repositories, issues and pull requests, and open new ones.","url":"https://api.githubcopilot.com/mcp","transport":"streamable-http"},
      {"registryId":"io.example/old","name":"old-calendar","description":"A calendar server that has moved.","url":"https://old.example.com/mcp","transport":"sse","dead":true}],
     "suggested":[{"registryId":"hypervault","name":"HyperVault","description":"This vault's own tools: keep pages, claim an address, and manage memories.","url":"https://hypervault.store/api/mcp","transport":"streamable-http"}]}
    """

    static let previewJSON = """
    {"url":"https://notes.example.com/mcp","name":"Team notes","serverName":"notes","tools":[
      {"name":"search_notes","description":"Search every note by words.","input_schema":{"type":"object","properties":{"query":{"type":"string","description":"What to look for"},"limit":{"type":"integer"}},"required":["query"]}},
      {"name":"read_note","description":"Read one note.","input_schema":{"type":"object","properties":{"id":{"type":"string"}},"required":["id"]}}]}
    """

    static let compileJSON = """
    {"toolkitId":"k2","stats":{"toolCount":5,"uniqueSelectorCount":5,"providerCount":2,"collisionCount":1},
     "collisions":[{"selectorA":"search_notes","selectorB":"list_issues","similarity":0.91,"hint":"Both read like a lookup."}],
     "embedder":{"kind":"local"},"embedderLabel":"semantic (MiniLM-L6-v2, 384d local)","embedderDegradeReason":null,"skippedServers":[]}
    """

    static var routes: [MockRoute] {
        [
            .json(.get, "/api/mcp-servers", serversJSON),
            .json(.get, "/api/toolkits", toolkitJSON),
            .json(.get, "/api/registry/search", registryJSON),
            .json(.post, "/api/registry/liveness", #"{"results":[{"url":"https://old.example.com/mcp","state":"dead","status":404},{"url":"https://mcp.linear.app/mcp","state":"alive"}]}"#),
            .json(.post, "/api/mcp-servers/preview", previewJSON),
            .json(.post, "/api/toolkits/compile", compileJSON),
        ]
    }

    static var emptyRoutes: [MockRoute] {
        [
            .json(.get, "/api/mcp-servers", #"{"servers":[]}"#),
            .json(.get, "/api/toolkits", #"{"toolkit":null,"stale":false}"#),
            .json(.get, "/api/registry/search", registryJSON),
        ]
    }

    static func servers() -> [McpServer] {
        (try? HVCoding.decoder(.verbatim).decode(McpServerList.self, from: Data(serversJSON.utf8)))?.servers ?? []
    }
}

/// Builds a loaded Tools model from the preview environment and hands it to
/// `content`, for previews and snapshot tests of the screens that take one.
struct ToolsModelHost<Content: View>: View {
    @Environment(AppEnvironment.self) private var env
    @State private var model: ToolsModel?
    var prepare: (ToolsModel) -> Void = { _ in }
    @ViewBuilder var content: (ToolsModel, HVClient) -> Content

    var body: some View {
        Group {
            if let model {
                content(model, env.client)
            } else {
                HVLoadingState()
            }
        }
        .task {
            let loaded = ToolsModel(client: env.client, cache: env.cache, namespace: env.user.id, maxServers: 20)
            await loaded.load()
            prepare(loaded)
            model = loaded
        }
    }
}
#endif
