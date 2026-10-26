import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HyperVaultKit

/// The picker's bundled list and the parser for GET /connect.md?client=<id>
/// (lib/agent-clients.ts, lib/agent-docs/connect.ts). The fixtures in ConnectFixtures.swift are the
/// pages the live server answered.
final class AgentClientsTests: XCTestCase {
    // MARK: The bundled list

    /// The index of the live /connect.md ("Find your client"), one line per client.
    static let liveIndex = """
    - [Claude.ai (web)](#claudeai-web) `claude-ai-web` - MCP, key in the URL
    - [Claude Desktop (connector)](#claude-desktop-connector) `claude-desktop-connector` - MCP, key in the URL
    - [Claude Desktop (local server)](#claude-desktop-local-server) `claude-desktop-stdio` - MCP, local program
    - [Claude mobile (iPhone, Android)](#claude-mobile-iphone-android) `claude-mobile` - MCP, key in the URL
    - [ChatGPT (web)](#chatgpt-web) `chatgpt` - MCP, key in the URL
    - [Grok (grok.com)](#grok-grokcom) `grok-com` - MCP, key in the URL (untested)
    - [Perplexity (app)](#perplexity-app) `perplexity-app` - MCP, key in the URL (untested)
    - [Mistral Le Chat](#mistral-le-chat) `mistral-le-chat` - MCP, key in the URL
    - [Microsoft 365 Copilot (declarative agent)](#microsoft-365-copilot-declarative-agent) `m365-copilot` - MCP, key in the URL
    - [Notion Custom Agents](#notion-custom-agents) `notion-custom-agents` - MCP, key in a header (untested)
    - [Claude Code (CLI)](#claude-code-cli) `claude-code-cli` - MCP, key in a header
    - [Claude Code (desktop app)](#claude-code-desktop-app) `claude-code-desktop` - MCP, key in a header
    - [Cursor](#cursor) `cursor` - MCP, key in a header
    - [Windsurf (Cascade and Devin)](#windsurf-cascade-and-devin) `windsurf` - MCP, key in a header
    - [VS Code with GitHub Copilot](#vs-code-with-github-copilot) `vscode-copilot` - MCP, key in a header
    - [Cline (VS Code and other editors)](#cline-vs-code-and-other-editors) `cline-vscode` - MCP, key in a header
    - [Cline CLI](#cline-cli) `cline-cli` - MCP, key in a header
    - [Continue (VS Code and JetBrains)](#continue-vs-code-and-jetbrains) `continue-dev` - MCP, key in a header
    - [Zed](#zed) `zed` - MCP, key in a header
    - [Codex CLI](#codex-cli) `codex-cli` - MCP, key as a bearer token
    - [Codex app (ChatGPT desktop)](#codex-app-chatgpt-desktop) `codex-app` - MCP, key in a header
    - [Gemini CLI](#gemini-cli) `gemini-cli` - MCP, key in a header
    - [Goose (desktop and CLI)](#goose-desktop-and-cli) `goose` - MCP, key in a header
    - [OpenCode](#opencode) `opencode` - MCP, key in a header
    - [Grok Build (CLI)](#grok-build-cli) `grok-build-cli` - MCP, key in a header
    - [Any agent that can make HTTP requests](#any-agent-that-can-make-http-requests) `generic-http-agent` - plain requests, key in a header
    - [n8n (MCP Client Tool node)](#n8n-mcp-client-tool-node) `n8n` - MCP, key in a header
    - [OpenAI Responses API (remote MCP tool)](#openai-responses-api-remote-mcp-tool) `openai-responses-api-remote-mcp` - MCP, key in a header
    - [Anthropic Messages API (MCP connector)](#anthropic-messages-api-mcp-connector) `anthropic-messages-api-mcp-connector` - MCP, key as a bearer token
    - [xAI API (remote MCP tool)](#xai-api-remote-mcp-tool) `grok-api` - MCP, key in a header
    - [Perplexity Agent API](#perplexity-agent-api) `perplexity-agent-api` - MCP, key in a header
    - [Mistral Studio API (connectors)](#mistral-studio-api-connectors) `mistral-studio-api` - MCP, key in a header
    - [Amazon Bedrock AgentCore Gateway](#amazon-bedrock-agentcore-gateway) `bedrock-agentcore-gateway` - MCP, key in a header
    """

    func testTheBundledListMatchesTheServersIndex() throws {
        var expected: [(name: String, id: String, rest: String)] = []
        for line in Self.liveIndex.split(separator: "\n") {
            let text = String(line)
            let name = try XCTUnwrap(text.range(of: "- [").flatMap { start in text.range(of: "](", range: start.upperBound..<text.endIndex).map { String(text[start.upperBound..<$0.lowerBound]) } })
            let tick = try XCTUnwrap(text.range(of: "`"))
            let end = try XCTUnwrap(text.range(of: "`", range: tick.upperBound..<text.endIndex))
            expected.append((name, String(text[tick.upperBound..<end.lowerBound]), String(text[end.upperBound...])))
        }
        XCTAssertEqual(expected.count, 33)
        XCTAssertEqual(AgentClientCatalog.all.count, 33)
        XCTAssertEqual(AgentClientCatalog.all.map(\.id), expected.map(\.id), "same clients in the same order")
        XCTAssertEqual(AgentClientCatalog.all.map(\.name), expected.map(\.name))
        for (client, entry) in zip(AgentClientCatalog.all, expected) {
            XCTAssertEqual(client.verified, !entry.rest.hasSuffix("(untested)"), client.id)
            XCTAssertEqual(client.lane == .http, entry.rest.contains("plain requests"), client.id)
            switch client.auth {
            case .urlKey: XCTAssertTrue(entry.rest.contains("key in the URL"), client.id)
            case .header: XCTAssertTrue(entry.rest.contains("key in a header"), client.id)
            case .bearerEnv: XCTAssertTrue(entry.rest.contains("bearer token"), client.id)
            case .stdio: XCTAssertTrue(entry.rest.contains("local program"), client.id)
            }
        }
    }

    func testIdsAreUniqueAndEveryFamilyHasClients() {
        XCTAssertEqual(Set(AgentClientCatalog.all.map(\.id)).count, AgentClientCatalog.all.count)
        for group in AgentClientGroup.allCases { XCTAssertFalse(AgentClientCatalog.clients(in: group).isEmpty, group.title) }
        XCTAssertEqual(AgentClientCatalog.all.filter { !$0.verified }.map(\.id), ["grok-com", "perplexity-app", "notion-custom-agents"])
        XCTAssertEqual(AgentClientCatalog.client(id: "cursor")?.name, "Cursor")
        XCTAssertNil(AgentClientCatalog.client(id: "nope"))
        XCTAssertEqual(AgentClientCatalog.client(id: "grok-com")?.optionLabel, "Grok (grok.com) (untested)")
        XCTAssertEqual(AgentClientCatalog.client(id: "cursor")?.optionLabel, "Cursor")
    }

    func testSearch() {
        func ids(_ query: String) -> [String] { AgentClientCatalog.search(query).map(\.id) }
        XCTAssertEqual(ids("").count, 33)
        XCTAssertEqual(ids("   ").count, 33)
        XCTAssertEqual(ids("cursor"), ["cursor"])
        XCTAssertEqual(ids("CURSOR"), ["cursor"])
        XCTAssertTrue(ids("curl").contains("generic-http-agent"), "curl finds the plain-requests entry")
        XCTAssertTrue(ids("code").contains("claude-code-cli"))
        XCTAssertTrue(ids("code").contains("codex-cli"))
        XCTAssertTrue(ids("openai").contains("chatgpt"))
        XCTAssertTrue(ids("gemini").contains("gemini-cli"))
        XCTAssertEqual(ids("claude code"), ["claude-code-cli", "claude-code-desktop"])
        XCTAssertTrue(ids("n8n").contains("n8n"))
        XCTAssertEqual(ids("zzzz"), [])
        XCTAssertFalse(ids("ode").contains("codex-cli"), "a word has to start with what was typed")
    }

    func testSectionsKeepTheFamilyOrder() {
        let sections = AgentClientCatalog.sections(AgentClientCatalog.all)
        XCTAssertEqual(sections.map(\.group), [.chatApps, .codingAgents, .automation])
        XCTAssertEqual(sections.map { $0.clients.count }, [10, 15, 8])
        XCTAssertEqual(AgentClientCatalog.sections(AgentClientCatalog.search("cursor")).count, 1)
        XCTAssertTrue(AgentClientCatalog.sections([]).isEmpty)
    }

    // MARK: The document

    func testParseAClientBlock() throws {
        let guide = ConnectGuide.parse(ConnectFixtures.cursor)
        XCTAssertEqual(guide.name, "Cursor")
        XCTAssertEqual(guide.clientID, "cursor")
        XCTAssertEqual(guide.family, "Coding agents")
        XCTAssertEqual(guide.lane, "MCP: native tools")
        XCTAssertEqual(guide.keyMethod, "Key sent as a request header")
        XCTAssertEqual(guide.renders, "Can show a tool's UI inside the chat (documented)")
        XCTAssertEqual(guide.status, "Checked against the vendor's documentation on 2026-10-08. Most steps were not run in the live app.")
        XCTAssertFalse(guide.isUntested)
        XCTAssertEqual(guide.steps.count, 4)
        XCTAssertTrue(guide.steps[0].hasPrefix("Choose where the config lives."))
        XCTAssertEqual(guide.pastes.map(\.label), [
            "~/.cursor/mcp.json (key inline)",
            ".cursor/mcp.json with the key read from your environment (safe to commit)",
            "Set the variable the second block reads",
            "First message in a new Agent chat",
        ])
        XCTAssertEqual(guide.pastes.map(\.language), ["json", "json", "bash", "text"])
        XCTAssertTrue(guide.pastes[0].text.contains(#""Authorization": "Bearer hv_YOUR_KEY_HERE""#))
        XCTAssertTrue(guide.pastes[0].text.hasPrefix("{\n  \"mcpServers\""))
        XCTAssertEqual(guide.pastes[2].text, "export HYPERVAULT_API_KEY=hv_YOUR_KEY_HERE")
        XCTAssertNil(guide.warning)
        XCTAssertTrue(try XCTUnwrap(guide.check).hasPrefix("In a new Agent chat send:"))
        XCTAssertEqual(guide.caveats.count, 5)
        XCTAssertTrue(guide.caveats[0].hasPrefix("Never put the literal key"))
        XCTAssertEqual(guide.sources, ["https://cursor.com/docs/context/mcp", "https://cursor.com/docs/context/mcp/install-links", "https://cursor.com/docs/integrations/deeplinks"])
        XCTAssertFalse(guide.isEmpty)
    }

    func testParseAnUrlKeyClientCarriesItsWarning() throws {
        let guide = ConnectGuide.parse(ConnectFixtures.claudeAI)
        XCTAssertEqual(guide.name, "Claude.ai (web)")
        XCTAssertEqual(guide.keyMethod, "Key inside the server URL (this client cannot send a header)")
        XCTAssertEqual(guide.steps.count, 7)
        XCTAssertEqual(guide.warning, ConnectCopy.urlKeyWarning, "the app's constant is the server's sentence, verbatim")
        XCTAssertEqual(guide.pastes.first?.text, "https://mcp.vault.cool/k/hv_YOUR_KEY_HERE/mcp")
        XCTAssertEqual(guide.pastes.count, 5)
        XCTAssertEqual(guide.sources.count, 3)
    }

    func testParseAnUntestedClient() throws {
        let guide = ConnectGuide.parse(ConnectFixtures.notion)
        XCTAssertTrue(guide.isUntested)
        XCTAssertEqual(guide.status, ConnectCopy.untestedNote, "the app's constant is the server's sentence, verbatim")
        XCTAssertEqual(guide.renders, "Inline UI: the vendor's docs do not say")
        XCTAssertEqual(guide.steps.count, 7)
        XCTAssertEqual(guide.pastes.count, 4)
    }

    func testParseTheHTTPClient() throws {
        let guide = ConnectGuide.parse(ConnectFixtures.http)
        XCTAssertEqual(guide.lane, "HTTP: plain requests, nothing to install")
        XCTAssertEqual(guide.pastes.count, 5)
        XCTAssertEqual(guide.pastes[0].language, "bash")
        XCTAssertTrue(guide.pastes[0].text.contains("curl \"https://hypervault.store/api/setup-challenge\" \\\n  -H \"X-HyperVault-Key: hv_YOUR_KEY_HERE\""))
        XCTAssertTrue(guide.check?.hasPrefix("Run the setup-challenge request.") ?? false)
        XCTAssertEqual(guide.sources.count, 2)
    }

    func testParseTheBearerEnvClient() {
        let guide = ConnectGuide.parse(ConnectFixtures.codexCLI)
        XCTAssertEqual(guide.name, "Codex CLI")
        XCTAssertFalse(guide.steps.isEmpty)
        XCTAssertTrue(guide.pastes.contains { $0.text.contains("hv_YOUR_KEY_HERE") })
    }

    func testPastesInTheCodeFencesAreKeptByteForByte() {
        // Fenced text is shown exactly as the page has it, backslashes, blank lines and all.
        let markdown = """
        ### Odd

        Steps:

        1. One.

        Paste exactly as shown (hv_YOUR_KEY_HERE stands for the key):

        **A script**

        ```bash
        echo "a"

          indented \\
          more
        ```

        Check: ok.
        """
        let guide = ConnectGuide.parse(markdown)
        XCTAssertEqual(guide.pastes.first?.text, "echo \"a\"\n\n  indented \\\n  more")
        XCTAssertEqual(guide.check, "ok.")
    }

    func testParseOfSomethingElseIsEmptyRatherThanAnError() {
        XCTAssertTrue(ConnectGuide.parse("").isEmpty)
        XCTAssertTrue(ConnectGuide.parse("No client has that id.").isEmpty)
        XCTAssertTrue(ConnectGuide.parse("### Lonely").isEmpty)
    }

    func testTheWholePagePicksTheLastClientBlock() {
        let page = ConnectFixtures.cursor + "\n\n### Another\n\nSteps:\n\n1. Do it.\n"
        XCTAssertEqual(ConnectGuide.parse(page).name, "Another")
    }

    // MARK: Filling in the key

    func testTheKeyIsFilledInEverywhereOnTheDevice() throws {
        let key = "hv_Zk3pQ9vL2mX8aRt5NwYb7CdEfGhJ1sUo"
        let guide = ConnectGuide.parse(ConnectFixtures.claudeAI).filled(with: key)
        XCTAssertEqual(guide.pastes.first?.text, "https://mcp.vault.cool/k/\(key)/mcp")
        XCTAssertEqual(guide.pastes[3].text, "Bearer \(key)")
        let everything = ([guide.pastes.map(\.text), guide.steps, guide.caveats, [guide.check ?? "", guide.warning ?? ""]]).flatMap { $0 }.joined()
        XCTAssertFalse(everything.contains(ConnectKey.placeholder))
        // A nil or empty key leaves the placeholder, which is what an existing key's guide shows.
        XCTAssertEqual(ConnectGuide.parse(ConnectFixtures.claudeAI).filled(with: nil).pastes.first?.text, "https://mcp.vault.cool/k/hv_YOUR_KEY_HERE/mcp")
        XCTAssertEqual(ConnectKey.fill("a hv_YOUR_KEY_HERE b", key: ""), "a hv_YOUR_KEY_HERE b")
    }

    func testAKeyWithDollarSignsIsNotReadAsAReplacementPattern() {
        XCTAssertEqual(ConnectKey.fill("Bearer hv_YOUR_KEY_HERE", key: "hv_a$1b$&c"), "Bearer hv_a$1b$&c")
    }

    func testTheChallengeSlugReplacesThePlainRequestsPlaceholder() {
        let guide = ConnectGuide.parse(ConnectFixtures.http).filled(with: "hv_k", challengeSlug: "agent-setup-ab12")
        XCTAssertTrue(guide.pastes[1].text.contains("/api/artifacts/agent-setup-ab12/content"))
        XCTAssertFalse(guide.pastes[1].text.contains("YOUR_ARTIFACT_SLUG"))
        let left = ConnectGuide.parse(ConnectFixtures.http).filled(with: "hv_k")
        XCTAssertTrue(left.pastes[1].text.contains("YOUR_ARTIFACT_SLUG"), "without a slug the placeholder stays")
    }

    func testThePromptCarriesTheKeyAndTheInstructions() {
        let key = "hv_Zk3pQ9vL2mX8aRt5NwYb7CdEfGhJ1sUo"
        let prompt = ConnectPrompt.make(clientName: "Cursor", document: ConnectFixtures.cursor, key: key)
        XCTAssertTrue(prompt.hasPrefix("Connect yourself to my HyperVault. I use Cursor."))
        XCTAssertTrue(prompt.contains("Bearer \(key)"))
        XCTAssertFalse(prompt.contains("hv_YOUR_KEY_HERE"))
        XCTAssertTrue(prompt.contains("### Cursor"))
        XCTAssertTrue(prompt.contains("do not repeat it in this chat"))

        let pointer = ConnectPrompt.pointer(clientName: "Cursor", clientID: "cursor", origin: "https://hypervault.store", key: key)
        XCTAssertTrue(pointer.contains("https://hypervault.store/connect.md?client=cursor"))
        XCTAssertTrue(pointer.contains(key))
    }

    func testTheSentencesAreTheWebs() {
        XCTAssertEqual(ConnectCopy.promptLine("Cursor"), "Paste it into Cursor. It connects, then rewrites a page of yours to prove the link works.")
        XCTAssertEqual(ConnectCopy.pickerLabel, "Where does your agent live?")
        XCTAssertEqual(AgentLane.http.label, "HTTP: plain requests, nothing to install")
        XCTAssertEqual(AgentAuth.urlKey.label, "Key inside the server URL (this client cannot send a header)")
    }

    // MARK: Wire

    func testTheDocumentIsFetchedWithoutAKey() async throws {
        let transport = MockTransport(routes: [
            MockRoute(.get, "/connect.md") { _ in HTTPResponse(status: 200, headers: ["content-type": "text/markdown"], data: Data(ConnectFixtures.cursor.utf8)) }
        ])
        let client = HVClient(baseURL: URL(string: "https://hypervault.store")!, transport: transport, tokens: StaticTokenProvider("secret-jwt"))
        let markdown = try await client.send(.connectDocument(clientID: "cursor"))
        XCTAssertTrue(markdown.contains("### Cursor"))

        let sentRequests = await transport.requests(matching: "/connect.md")
        let sent = try XCTUnwrap(sentRequests.first)
        XCTAssertEqual(sent.url?.query, "client=cursor")
        XCTAssertNil(sent.value(forHTTPHeaderField: "Authorization"), "the page is public: no token goes with it")
    }

    func testAnUnknownClientIsAGracefulNotFound() async {
        let transport = MockTransport(routes: [
            MockRoute(.get, "/connect.md") { _ in HTTPResponse(status: 404, headers: ["content-type": "text/markdown"], data: Data("No client has that id. The full page, with every client and its id, is https://hypervault.store/connect.md.\n".utf8)) }
        ])
        let client = HVClient(baseURL: URL(string: "https://hypervault.store")!, transport: transport, tokens: nil, retry: .none)
        do {
            _ = try await client.send(.connectDocument(clientID: "nope"))
            XCTFail("expected a 404")
        } catch let error as HVError {
            XCTAssertTrue(error.isNotFound)
        } catch {
            XCTFail("\(error)")
        }
    }
}
