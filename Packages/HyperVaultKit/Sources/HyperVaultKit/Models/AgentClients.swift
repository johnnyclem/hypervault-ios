import Foundation

// Connecting an agent: which AI apps, editors, command lines and APIs can be
// given HyperVault, and how. The web app keeps one registry for this
// (lib/agent-clients.ts) and serves it to agents as /connect.md.
//
// The app bundles the *list* (id, name, family, how the key travels, whether
// the steps were checked) so the picker works offline and can be searched, and
// fetches each client's *steps and strings* from GET /connect.md?client=<id>,
// which is always the current registry. The key is filled in here, on the
// device, and is never sent anywhere: the document is fetched without one.

// MARK: Catalog

public enum AgentClientGroup: String, Sendable, CaseIterable, Identifiable, Hashable {
    case chatApps = "chat-apps"
    case codingAgents = "coding-agents"
    case automation

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .chatApps: return "Chat apps"
        case .codingAgents: return "Coding agents"
        case .automation: return "Automation and APIs"
        }
    }

    public var blurb: String {
        switch self {
        case .chatApps: return "Apps you talk to in a window, on the web or on your phone."
        case .codingAgents: return "Editors and terminal agents that run on your computer."
        case .automation: return "Workflows, gateways and API calls your own code makes."
        }
    }

    public var symbol: String {
        switch self {
        case .chatApps: return "bubble.left.and.bubble.right"
        case .codingAgents: return "terminal"
        case .automation: return "gearshape.2"
        }
    }
}

/// The lane a client's setup produces: plain requests, or MCP tools.
public enum AgentLane: String, Sendable, Hashable {
    case http, mcp

    public var label: String {
        switch self {
        case .http: return "HTTP: plain requests, nothing to install"
        case .mcp: return "MCP: native tools"
        }
    }

    public var shortLabel: String { self == .http ? "HTTP" : "MCP" }
}

/// How the key reaches HyperVault from a client.
public enum AgentAuth: String, Sendable, Hashable {
    case header
    case urlKey = "url-key"
    case bearerEnv = "bearer-env"
    case stdio

    public var label: String {
        switch self {
        case .header: return "Key sent as a request header"
        case .urlKey: return "Key inside the server URL (this client cannot send a header)"
        case .bearerEnv: return "Key sent as a bearer token, from an environment variable or a token field"
        case .stdio: return "Key in the environment of a local program"
        }
    }
}

/// Whether a client can show a tool's UI inside the chat, as its vendor documents it.
public enum AgentRenders: String, Sendable, Hashable {
    case inline
    case toolsOnly = "tools-only"
    case unknown

    public var label: String {
        switch self {
        case .inline: return "Can show a tool's UI inside the chat (documented)"
        case .toolsOnly: return "Shows tool calls and text results"
        case .unknown: return "Inline UI: the vendor's docs do not say"
        }
    }
}

/// One row of the picker. The steps and strings are not here: they come from the server.
public struct AgentClientInfo: Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let group: AgentClientGroup
    public let lane: AgentLane
    public let auth: AgentAuth
    public let renders: AgentRenders
    /// A paste-string puts the key inside a URL, so the URL is the credential.
    public let keyInUrl: Bool
    /// False is an "Untested" entry: its steps could not be checked against the vendor's own documentation.
    public let verified: Bool
    /// Extra words a person might search by ("curl", "openai").
    public let keywords: [String]

    public init(
        id: String, name: String, group: AgentClientGroup, lane: AgentLane = .mcp, auth: AgentAuth = .header,
        renders: AgentRenders = .unknown, keyInUrl: Bool = false, verified: Bool = true, keywords: [String] = []
    ) {
        self.id = id
        self.name = name
        self.group = group
        self.lane = lane
        self.auth = auth
        self.renders = renders
        self.keyInUrl = keyInUrl
        self.verified = verified
        self.keywords = keywords
    }

    /// The picker's option text: an untested client says so before it is opened (`connectOptionLabel`).
    public var optionLabel: String { verified ? name : "\(name) (untested)" }

    /// One line under the name: how it connects.
    public var detailLine: String {
        var parts = [lane == .http ? "Plain requests" : "MCP"]
        switch auth {
        case .urlKey: parts.append("key in the URL")
        case .header: parts.append("key in a header")
        case .bearerEnv: parts.append("key as a bearer token")
        case .stdio: parts.append("local program")
        }
        return parts.joined(separator: ", ")
    }
}

public enum AgentClientCatalog {
    /// Every client the web registry lists, in the order it shows them (lib/agent-clients/*.ts).
    public static let all: [AgentClientInfo] = [
        AgentClientInfo(id: "claude-ai-web", name: "Claude.ai (web)", group: .chatApps, lane: .mcp, auth: .urlKey, renders: .inline, keyInUrl: true, verified: true, keywords: ["claude", "anthropic", "browser"]),
        AgentClientInfo(id: "claude-desktop-connector", name: "Claude Desktop (connector)", group: .chatApps, lane: .mcp, auth: .urlKey, renders: .inline, keyInUrl: true, verified: true, keywords: ["claude", "anthropic", "mac", "windows"]),
        AgentClientInfo(id: "claude-desktop-stdio", name: "Claude Desktop (local server)", group: .chatApps, lane: .mcp, auth: .stdio, renders: .inline, keyInUrl: false, verified: true, keywords: ["claude", "anthropic", "stdio"]),
        AgentClientInfo(id: "claude-mobile", name: "Claude mobile (iPhone, Android)", group: .chatApps, lane: .mcp, auth: .urlKey, renders: .inline, keyInUrl: true, verified: true, keywords: ["claude", "anthropic", "ios", "phone"]),
        AgentClientInfo(id: "chatgpt", name: "ChatGPT (web)", group: .chatApps, lane: .mcp, auth: .urlKey, renders: .inline, keyInUrl: true, verified: true, keywords: ["openai", "gpt"]),
        AgentClientInfo(id: "grok-com", name: "Grok (grok.com)", group: .chatApps, lane: .mcp, auth: .urlKey, renders: .unknown, keyInUrl: true, verified: false, keywords: ["xai"]),
        AgentClientInfo(id: "perplexity-app", name: "Perplexity (app)", group: .chatApps, lane: .mcp, auth: .urlKey, renders: .unknown, keyInUrl: true, verified: false),
        AgentClientInfo(id: "mistral-le-chat", name: "Mistral Le Chat", group: .chatApps, lane: .mcp, auth: .urlKey, renders: .unknown, keyInUrl: true, verified: true),
        AgentClientInfo(id: "m365-copilot", name: "Microsoft 365 Copilot (declarative agent)", group: .chatApps, lane: .mcp, auth: .urlKey, renders: .inline, keyInUrl: true, verified: true, keywords: ["microsoft", "office"]),
        AgentClientInfo(id: "notion-custom-agents", name: "Notion Custom Agents", group: .chatApps, lane: .mcp, auth: .header, renders: .unknown, keyInUrl: false, verified: false),
        AgentClientInfo(id: "claude-code-cli", name: "Claude Code (CLI)", group: .codingAgents, lane: .mcp, auth: .header, renders: .toolsOnly, keyInUrl: false, verified: true, keywords: ["claude", "anthropic", "terminal"]),
        AgentClientInfo(id: "claude-code-desktop", name: "Claude Code (desktop app)", group: .codingAgents, lane: .mcp, auth: .header, renders: .unknown, keyInUrl: false, verified: true, keywords: ["claude", "anthropic"]),
        AgentClientInfo(id: "cursor", name: "Cursor", group: .codingAgents, lane: .mcp, auth: .header, renders: .inline, keyInUrl: false, verified: true, keywords: ["editor", "ide"]),
        AgentClientInfo(id: "windsurf", name: "Windsurf (Cascade and Devin)", group: .codingAgents, lane: .mcp, auth: .header, renders: .unknown, keyInUrl: false, verified: true, keywords: ["codeium", "editor"]),
        AgentClientInfo(id: "vscode-copilot", name: "VS Code with GitHub Copilot", group: .codingAgents, lane: .mcp, auth: .header, renders: .inline, keyInUrl: false, verified: true, keywords: ["microsoft", "github", "editor"]),
        AgentClientInfo(id: "cline-vscode", name: "Cline (VS Code and other editors)", group: .codingAgents, lane: .mcp, auth: .header, renders: .unknown, keyInUrl: false, verified: true, keywords: ["editor"]),
        AgentClientInfo(id: "cline-cli", name: "Cline CLI", group: .codingAgents, lane: .mcp, auth: .header, renders: .toolsOnly, keyInUrl: false, verified: true, keywords: ["terminal"]),
        AgentClientInfo(id: "continue-dev", name: "Continue (VS Code and JetBrains)", group: .codingAgents, lane: .mcp, auth: .header, renders: .unknown, keyInUrl: false, verified: true, keywords: ["jetbrains", "editor"]),
        AgentClientInfo(id: "zed", name: "Zed", group: .codingAgents, lane: .mcp, auth: .header, renders: .toolsOnly, keyInUrl: false, verified: true, keywords: ["editor"]),
        AgentClientInfo(id: "codex-cli", name: "Codex CLI", group: .codingAgents, lane: .mcp, auth: .bearerEnv, renders: .toolsOnly, keyInUrl: false, verified: true, keywords: ["openai", "terminal"]),
        AgentClientInfo(id: "codex-app", name: "Codex app (ChatGPT desktop)", group: .codingAgents, lane: .mcp, auth: .header, renders: .unknown, keyInUrl: false, verified: true, keywords: ["openai", "chatgpt"]),
        AgentClientInfo(id: "gemini-cli", name: "Gemini CLI", group: .codingAgents, lane: .mcp, auth: .header, renders: .toolsOnly, keyInUrl: false, verified: true, keywords: ["google", "terminal"]),
        AgentClientInfo(id: "goose", name: "Goose (desktop and CLI)", group: .codingAgents, lane: .mcp, auth: .header, renders: .inline, keyInUrl: false, verified: true, keywords: ["block"]),
        AgentClientInfo(id: "opencode", name: "OpenCode", group: .codingAgents, lane: .mcp, auth: .header, renders: .toolsOnly, keyInUrl: false, verified: true, keywords: ["terminal"]),
        AgentClientInfo(id: "grok-build-cli", name: "Grok Build (CLI)", group: .codingAgents, lane: .mcp, auth: .header, renders: .toolsOnly, keyInUrl: false, verified: true, keywords: ["xai", "terminal"]),
        AgentClientInfo(id: "generic-http-agent", name: "Any agent that can make HTTP requests", group: .automation, lane: .http, auth: .header, renders: .toolsOnly, keyInUrl: false, verified: true, keywords: ["curl", "http", "rest", "api", "script", "python", "fetch", "other"]),
        AgentClientInfo(id: "n8n", name: "n8n (MCP Client Tool node)", group: .automation, lane: .mcp, auth: .header, renders: .toolsOnly, keyInUrl: false, verified: true, keywords: ["workflow", "zapier"]),
        AgentClientInfo(id: "openai-responses-api-remote-mcp", name: "OpenAI Responses API (remote MCP tool)", group: .automation, lane: .mcp, auth: .header, renders: .toolsOnly, keyInUrl: false, verified: true, keywords: ["openai", "api"]),
        AgentClientInfo(id: "anthropic-messages-api-mcp-connector", name: "Anthropic Messages API (MCP connector)", group: .automation, lane: .mcp, auth: .bearerEnv, renders: .toolsOnly, keyInUrl: true, verified: true, keywords: ["claude", "api"]),
        AgentClientInfo(id: "grok-api", name: "xAI API (remote MCP tool)", group: .automation, lane: .mcp, auth: .header, renders: .toolsOnly, keyInUrl: false, verified: true, keywords: ["grok", "api"]),
        AgentClientInfo(id: "perplexity-agent-api", name: "Perplexity Agent API", group: .automation, lane: .mcp, auth: .header, renders: .toolsOnly, keyInUrl: true, verified: true, keywords: ["api"]),
        AgentClientInfo(id: "mistral-studio-api", name: "Mistral Studio API (connectors)", group: .automation, lane: .mcp, auth: .header, renders: .toolsOnly, keyInUrl: false, verified: true, keywords: ["api"]),
        AgentClientInfo(id: "bedrock-agentcore-gateway", name: "Amazon Bedrock AgentCore Gateway", group: .automation, lane: .mcp, auth: .header, renders: .toolsOnly, keyInUrl: false, verified: true, keywords: ["aws", "amazon", "api"]),
    ]

    public static func client(id: String) -> AgentClientInfo? {
        all.first { $0.id == id }
    }

    public static func clients(in group: AgentClientGroup) -> [AgentClientInfo] {
        all.filter { $0.group == group }
    }

    /// Clients matching what was typed: every word of the query has to start a word of the
    /// name, id or a keyword, so "code" finds Claude Code and Codex but "ode" does not.
    public static func search(_ query: String, in clients: [AgentClientInfo] = all) -> [AgentClientInfo] {
        let words = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard !words.isEmpty else { return clients }
        return clients.filter { client in
            let haystack = ([client.name, client.id] + client.keywords).joined(separator: " ").lowercased()
            let tokens = haystack.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            return words.allSatisfy { word in tokens.contains { $0.hasPrefix(word) } }
        }
    }

    /// The same clients, ordered by family and dropped into sections for a list.
    public static func sections(_ clients: [AgentClientInfo]) -> [(group: AgentClientGroup, clients: [AgentClientInfo])] {
        AgentClientGroup.allCases.compactMap { group in
            let inGroup = clients.filter { $0.group == group }
            return inGroup.isEmpty ? nil : (group, inGroup)
        }
    }
}

// MARK: Words

/// The words the web's picker uses (lib/copy.ts, CONNECT_*), and the two warnings every reader of
/// the registry prints (lib/agent-clients.ts).
public enum ConnectCopy {
    public static let pickerLabel = "Where does your agent live?"
    public static let stepsHeading = "Steps"
    public static let pasteHeading = "Paste exactly as shown"
    public static let checkHeading = "Check it worked"
    public static let notesHeading = "Things to know"
    public static let sourcesHeading = "Sources"
    public static let copyLabel = "Copy"
    public static let copiedLabel = "Copied"

    /// The connect sheet on the canvas (lib/copy.ts, CONNECT_AI_*).
    public static let title = "Connect your AI"
    public static let line = "Pick the AI you use. You get a key and a prompt to paste into it, and it sets itself up."
    public static let whichAI = "Which AI do you use?"
    public static let makingLine = "Making a key for it..."
    public static let failedLine = "That did not go through. Try again."
    public static let keyLine = "Its key. It is shown once, and the prompt below carries it."
    public static let promptLabel = "Copy the prompt"
    public static func promptLine(_ name: String) -> String {
        "Paste it into \(name). It connects, then rewrites a page of yours to prove the link works."
    }
    public static let privateLine = "The prompt holds your key: paste it into a private chat, not a shared one."
    public static let doneLine = "When it writes back, the key reads Agent connected on your account page."

    /// Shown wherever a client puts the key inside a URL. A header can be kept out of logs and a URL cannot.
    public static let urlKeyWarning =
        "The key is part of this URL, so the URL is the credential: anything that logs the address can read it. Make a key just for this connection, do not post the URL anywhere shared, and revoke the key from the Agent keys card if it leaks."

    /// Shown for every entry whose steps were not checked against the vendor's own documentation.
    public static let untestedNote =
        "Untested. These steps could not be checked against the vendor's own documentation, so treat every step and string as a best guess, not exact. Tell the person so, and expect the screen to differ."
}

// MARK: The document

/// `GET /connect.md?client=<id>`: how one client is connected, in markdown, public and key-free
/// (every string holds `hv_YOUR_KEY_HERE` where the key goes). Fetched with no token.
extension Endpoint where Response == String {
    public static func connectDocument(clientID: String) -> Endpoint<String> {
        Endpoint(text: .get, "/connect.md", query: [URLQueryItem(name: "client", value: clientID)], auth: .none)
    }
}

public enum ConnectKey {
    /// What the web's docs put where the key goes.
    public static let placeholder = "hv_YOUR_KEY_HERE"

    /// Puts a key in place of every placeholder. Done here, on the device: the key is never sent anywhere to fill a string in.
    public static func fill(_ text: String, key: String?) -> String {
        guard let key, !key.isEmpty else { return text }
        return text.replacingOccurrences(of: placeholder, with: key)
    }
}

/// One client's page of /connect.md, taken apart so the app can lay it out: what it is, the steps, the
/// strings to paste (each with its label), the check, the notes and where it all came from.
public struct ConnectGuide: Sendable, Equatable {
    public struct Paste: Sendable, Equatable, Identifiable {
        public var label: String
        /// `bash`, `json`, `yaml`, `toml`, `python` or `text`.
        public var language: String
        public var text: String
        public var id: String { label + "\u{0}" + String(text.prefix(24)) }

        public init(label: String, language: String, text: String) {
            self.label = label
            self.language = language
            self.text = text
        }
    }

    public var name: String
    public var clientID: String?
    public var family: String?
    public var lane: String?
    public var keyMethod: String?
    public var renders: String?
    /// "Checked against the vendor's documentation on 2026-10-08..." or the Untested note.
    public var status: String?
    public var steps: [String]
    public var pastes: [Paste]
    public var warning: String?
    public var check: String?
    public var caveats: [String]
    public var sources: [String]

    public init(
        name: String = "", clientID: String? = nil, family: String? = nil, lane: String? = nil, keyMethod: String? = nil,
        renders: String? = nil, status: String? = nil, steps: [String] = [], pastes: [Paste] = [], warning: String? = nil,
        check: String? = nil, caveats: [String] = [], sources: [String] = []
    ) {
        self.name = name
        self.clientID = clientID
        self.family = family
        self.lane = lane
        self.keyMethod = keyMethod
        self.renders = renders
        self.status = status
        self.steps = steps
        self.pastes = pastes
        self.warning = warning
        self.check = check
        self.caveats = caveats
        self.sources = sources
    }

    public var isUntested: Bool { status?.hasPrefix("Untested") ?? false }

    /// Nothing usable was found in the document.
    public var isEmpty: Bool { steps.isEmpty && pastes.isEmpty }

    /// The same guide with a key in place of the placeholder in every string.
    public func filled(with key: String?) -> ConnectGuide {
        var copy = self
        func fill(_ text: String) -> String { ConnectKey.fill(text, key: key) }
        copy.steps = steps.map(fill)
        copy.pastes = pastes.map { Paste(label: fill($0.label), language: $0.language, text: fill($0.text)) }
        copy.warning = warning.map(fill)
        copy.check = check.map(fill)
        copy.caveats = caveats.map(fill)
        return copy
    }

    // MARK: Parsing

    /// Reads a client's block from the markdown of `/connect.md?client=<id>` (or the whole page: the
    /// last `### ` heading starts the client). Tolerant: a line it does not recognize is skipped.
    public static func parse(_ markdown: String) -> ConnectGuide {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard let start = lines.lastIndex(where: { $0.hasPrefix("### ") }) else { return ConnectGuide() }

        enum Section { case facts, steps, pastes, caveats, idle }
        var guide = ConnectGuide(name: String(lines[start].dropFirst(4)).trimmingCharacters(in: .whitespaces))
        var section = Section.facts
        var pendingLabel: String?
        var fenceLanguage: String?
        var fenceLines: [String] = []

        for line in lines[(start + 1)...] {
            if let language = fenceLanguage {
                if line.hasPrefix("```") {
                    guide.pastes.append(Paste(label: pendingLabel ?? "Paste", language: language, text: fenceLines.joined(separator: "\n")))
                    pendingLabel = nil
                    fenceLanguage = nil
                    fenceLines = []
                } else {
                    fenceLines.append(line)
                }
                continue
            }
            if line.hasPrefix("```") {
                let language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                fenceLanguage = language.isEmpty ? "text" : language
                fenceLines = []
                continue
            }
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.isEmpty { continue }

            if text == "Steps:" { section = .steps; continue }
            if text.hasPrefix("Paste exactly as shown") { section = .pastes; continue }
            if text == "Things to know:" { section = .caveats; continue }
            if text.hasPrefix("Warning: ") { guide.warning = String(text.dropFirst(9)); section = .idle; continue }
            if text.hasPrefix("Check: ") { guide.check = String(text.dropFirst(7)); section = .idle; continue }
            if text.hasPrefix("Sources: ") {
                guide.sources = text.dropFirst(9).split(whereSeparator: { $0 == " " }).map(String.init)
                section = .idle
                continue
            }

            switch section {
            case .facts:
                guard text.hasPrefix("- ") else { continue }
                guide.assignFact(String(text.dropFirst(2)))
            case .steps:
                if let step = numberedItem(text) {
                    guide.steps.append(step)
                } else if !guide.steps.isEmpty {
                    guide.steps[guide.steps.count - 1] += " " + text
                }
            case .pastes:
                if text.hasPrefix("**"), text.hasSuffix("**"), text.count > 4 {
                    pendingLabel = String(text.dropFirst(2).dropLast(2))
                }
            case .caveats:
                if text.hasPrefix("- ") { guide.caveats.append(String(text.dropFirst(2))) }
            case .idle:
                break
            }
        }
        return guide
    }

    private mutating func assignFact(_ fact: String) {
        func value(after prefix: String) -> String? {
            fact.hasPrefix(prefix) ? String(fact.dropFirst(prefix.count)) : nil
        }
        if let id = value(after: "Client id: ") {
            clientID = id.trimmingCharacters(in: CharacterSet(charactersIn: "`"))
        } else if let value = value(after: "Family: ") {
            family = value
        } else if let value = value(after: "Lane: ") {
            lane = value
        } else if let value = value(after: "Key: ") {
            keyMethod = value
        } else if let value = value(after: "Status: ") {
            status = value
        } else {
            renders = fact
        }
    }

    /// "3. Open Customize..." is "Open Customize..."; any other line is nil.
    private static func numberedItem(_ text: String) -> String? {
        guard let dot = text.firstIndex(of: "."), dot != text.startIndex,
              text[..<dot].allSatisfy({ $0.isASCII && $0.isNumber }),
              text[text.index(after: dot)...].hasPrefix(" ")
        else { return nil }
        return String(text[text.index(dot, offsetBy: 2)...])
    }
}

// MARK: The prompt

/// The text a person pastes into the AI they use: the client's page of /connect.md, with the key filled in
/// and a first line that says what to do with it. Built on the device; the key is not sent anywhere.
public enum ConnectPrompt {
    public static func make(clientName: String, document: String, key: String) -> String {
        let filled = ConnectKey.fill(document, key: key).trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        Connect yourself to my HyperVault. I use \(clientName). The instructions for it are below, and my key is already filled in where it goes. \
        The key is private: do not repeat it in this chat or write it anywhere it could be read by others. \
        When you are done, run the check at the end and tell me what it said.

        ---

        \(filled)
        """
    }

    /// The prompt when the page could not be fetched: a pointer to the page and the key, enough for an agent that can read a URL.
    public static func pointer(clientName: String, clientID: String, origin: String, key: String) -> String {
        """
        Connect yourself to my HyperVault. I use \(clientName). Read \(origin)/connect.md?client=\(clientID) and follow it. \
        My key is \(key) (private: do not repeat it in this chat). When you are done, run the check at the end of that page and tell me what it said.
        """
    }
}
