// Generated from the live https://hypervault.store/connect.md?client=<id> pages (client block, short preface).
// A raw string, so the fences and backslashes of the page are kept exactly.

enum ConnectFixtures {
    static let cursor = #"""
# Connect an agent to HyperVault

This page is for an AI agent. It gets you, or the app you run in, connected to the person's HyperVault.

- Web app and REST API: https://hypervault.store
- MCP endpoint: https://mcp.vault.cool/mcp
- In every string below, hv_YOUR_KEY_HERE stands for the person's key. This page never holds a real one.

## The key

1. Look before you ask.
5. Never print it. When you show the person a command, show it with hv_YOUR_KEY_HERE or $HYPERVAULT_API_KEY in place of the key.

```bash
umask 077
mkdir -p ~/.config/hypervault && chmod 700 ~/.config/hypervault
```

## Recovery cheat sheet

| Status | `recovery.kind` | What it means | What to do |
| --- | --- | --- | --- |
| 401, 422 | `pair` | No key came with the request. | Find a key you already have. |

## Coding agents

### Cursor

- Client id: `cursor`
- Family: Coding agents
- Lane: MCP: native tools
- Key: Key sent as a request header
- Can show a tool's UI inside the chat (documented)
- Status: Checked against the vendor's documentation on 2026-10-08. Most steps were not run in the live app.

Steps:

1. Choose where the config lives. ~/.cursor/mcp.json makes HyperVault available in every project. .cursor/mcp.json inside a repo limits it to that project and is normally committed, so use the environment-variable block there.
2. Create the file if it does not exist and paste the block. If it already has an mcpServers object, add only the hypervault entry. For the environment-variable block, also export HYPERVAULT_API_KEY in the shell or system environment that launches Cursor.
3. Open Customize in the sidebar, find HyperVault under MCP and make sure its toggle is on. If it is missing after saving, reload the window or restart Cursor.
4. Start a new Agent chat and send the message below. Cursor asks for approval before an MCP tool runs, so approve the call.

Paste exactly as shown (hv_YOUR_KEY_HERE stands for the key):

**~/.cursor/mcp.json (key inline)**

```json
{
  "mcpServers": {
    "hypervault": {
      "url": "https://mcp.vault.cool/mcp",
      "headers": {
        "Authorization": "Bearer hv_YOUR_KEY_HERE"
      }
    }
  }
}
```

**.cursor/mcp.json with the key read from your environment (safe to commit)**

```json
{
  "mcpServers": {
    "hypervault": {
      "url": "https://mcp.vault.cool/mcp",
      "headers": {
        "Authorization": "Bearer ${env:HYPERVAULT_API_KEY}"
      }
    }
  }
}
```

**Set the variable the second block reads**

```bash
export HYPERVAULT_API_KEY=hv_YOUR_KEY_HERE
```

**First message in a new Agent chat**

```text
Run the HyperVault setup_challenge tool and complete the challenge it returns.
```

Check: In a new Agent chat send: Run the HyperVault setup_challenge tool and complete the challenge it returns. Approve the tool call. An enabled toggle in Customize proves nothing about the key. If the call errors, open the Output panel and pick MCP Logs. Once the challenge is written, the key's row in the Agent keys card on the Account page reads Agent connected.

Things to know:

- Never put the literal key in a project-level .cursor/mcp.json. Use the ${env:HYPERVAULT_API_KEY} form there; Cursor documents ${env:NAME} for command, args, env, url and headers.
- The environment form only works if Cursor's own process can see the variable. Cursor started from the Dock or Start menu may not inherit a shell export, so launch it from a shell or set the variable system-wide.
- Team admins can restrict remote servers with the MCP Allowlist; the MCP URL has to be allowed on managed teams.
- Cursor's transport table lists OAuth for remote servers, but its own remote example sends static headers. With a valid key in the header no OAuth is attempted.
- Not run. Cursor also offers one-click install links, which are left out because their remote-server format could not be confirmed. The Cursor CLI reads the same mcp.json files, but its docs were not checked.

Sources: https://cursor.com/docs/context/mcp https://cursor.com/docs/context/mcp/install-links https://cursor.com/docs/integrations/deeplinks
"""#

    static let claudeAI = #"""
# Connect an agent to HyperVault

This page is for an AI agent. It gets you, or the app you run in, connected to the person's HyperVault.

- Web app and REST API: https://hypervault.store
- MCP endpoint: https://mcp.vault.cool/mcp
- In every string below, hv_YOUR_KEY_HERE stands for the person's key. This page never holds a real one.

## The key

1. Look before you ask.
5. Never print it. When you show the person a command, show it with hv_YOUR_KEY_HERE or $HYPERVAULT_API_KEY in place of the key.

```bash
umask 077
mkdir -p ~/.config/hypervault && chmod 700 ~/.config/hypervault
```

## Recovery cheat sheet

| Status | `recovery.kind` | What it means | What to do |
| --- | --- | --- | --- |
| 401, 422 | `pair` | No key came with the request. | Find a key you already have. |

## Coding agents

### Claude.ai (web)

- Client id: `claude-ai-web`
- Family: Chat apps
- Lane: MCP: native tools
- Key: Key inside the server URL (this client cannot send a header)
- Can show a tool's UI inside the chat (documented)
- Status: Checked against the vendor's documentation on 2026-10-08. Most steps were not run in the live app.

Steps:

1. Make a key just for this connector (Account, Agent keys, Generate a key) so you can revoke it on its own later.
2. On claude.ai open Customize, then Connectors. On Team and Enterprise an owner adds it under Organization settings, Connectors, Add, Custom, Web, and each member then clicks Connect.
3. Choose Add custom connector and name it HyperVault.
4. This works on every plan: paste the connector URL below as the server URL, set Authentication to No sign-in, and leave Request headers empty.
5. Only if your dialog shows a Request headers section: use the plain server URL instead, keep No sign-in, add a header named authorization whose value is the word Bearer, a space, then the key, and mark it Required.
6. Click Add. The URL and headers cannot be edited afterwards, so if something is wrong, remove the connector and add it again.
7. Open a new chat, choose + then Connectors, make sure HyperVault is switched on, and send the message below.

Paste exactly as shown (hv_YOUR_KEY_HERE stands for the key):

**Server URL (key in the URL; Authentication: No sign-in)**

```text
https://mcp.vault.cool/k/hv_YOUR_KEY_HERE/mcp
```

**Server URL (header route)**

```text
https://mcp.vault.cool/mcp
```

**Request header name (header route)**

```text
authorization
```

**Request header value (header route: the word Bearer, a space, then the key)**

```text
Bearer hv_YOUR_KEY_HERE
```

**First message in a new chat**

```text
Run the HyperVault setup_challenge tool and complete the challenge it returns.
```

Warning: The key is part of this URL, so the URL is the credential: anything that logs the address can read it. Make a key just for this connection, do not post the URL anywhere shared, and revoke the key from the Agent keys card if it leaks.

Check: In a new chat with HyperVault switched on (+ then Connectors), send: Run the HyperVault setup_challenge tool and complete the challenge it returns. Claude should call setup_challenge, then read and write the challenge page, and the key's row in the Agent keys card on the Account page reads Agent connected.

Things to know:

- Request headers are a beta for a limited set of organizations. If the section is not in your dialog, use the key-in-URL route.
- Only header names Anthropic has approved can be saved: authorization, x-api-key and x-auth-token work everywhere. X-HyperVault-Key is not on the list, so use authorization (HyperVault accepts Authorization: Bearer).
- Claude sends a header value exactly as typed and adds no scheme, so the value has to start with Bearer and a space.
- Claude connects from Anthropic's cloud, not from your device, so the MCP URL has to be publicly reachable. The hosted one is.
- Free accounts can add one custom connector. On Team and Enterprise only owners can add it and every member then reaches HyperVault with the same key, so there is no per-person identity.
- Anthropic's pages say Customize, Connectors; older text says Settings, Connectors. The dialog is one screen or two steps depending on the organization.
- A connector added here is account-wide: it also appears in Claude Desktop, on mobile and in Claude Code signed in with the same account.
- The docs describe No sign-in in general and say nothing about a key inside the URL path, so the key-in-URL route relies on that general behaviour. Not run in the live app.

Sources: https://claude.com/docs/connectors/custom/add-unlisted https://claude.com/docs/connectors/building/authentication https://support.claude.com/en/articles/11175166-get-started-with-custom-connectors-using-remote-mcp
"""#

    static let notion = #"""
# Connect an agent to HyperVault

This page is for an AI agent. It gets you, or the app you run in, connected to the person's HyperVault.

- Web app and REST API: https://hypervault.store
- MCP endpoint: https://mcp.vault.cool/mcp
- In every string below, hv_YOUR_KEY_HERE stands for the person's key. This page never holds a real one.

## The key

1. Look before you ask.
5. Never print it. When you show the person a command, show it with hv_YOUR_KEY_HERE or $HYPERVAULT_API_KEY in place of the key.

```bash
umask 077
mkdir -p ~/.config/hypervault && chmod 700 ~/.config/hypervault
```

## Recovery cheat sheet

| Status | `recovery.kind` | What it means | What to do |
| --- | --- | --- | --- |
| 401, 422 | `pair` | No key came with the request. | Find a key you already have. |

## Coding agents

### Notion Custom Agents

- Client id: `notion-custom-agents`
- Family: Chat apps
- Lane: MCP: native tools
- Key: Key sent as a request header
- Inline UI: the vendor's docs do not say
- Status: Untested. These steps could not be checked against the vendor's own documentation, so treat every step and string as a best guess, not exact. Tell the person so, and expect the screen to differ.

Steps:

1. Check the workspace is on a Business or Enterprise plan. MCP connections are not available on other plans.
2. A workspace admin opens Settings, Connections, the Manage tab, and turns on Enable custom MCP servers. If members are limited to approved connections, the admin also adds the server URL below as an approved custom server.
3. Open the Custom Agent's Settings, then Tools & Access, then Add connection, then Custom MCP server.
4. Enter the server URL below and HyperVault as the display name.
5. Notion lists header-based sign-in (for example API keys or bearer tokens) next to OAuth. Choose the header-based option and give it the key as a bearer credential. The help page does not show this form, so how it asks for the value is untested.
6. Choose Connect, then pick which tools the agent may use. Write tools ask for confirmation by default.
7. Send the message below in the agent's chat.

Paste exactly as shown (hv_YOUR_KEY_HERE stands for the key):

**Server URL**

```text
https://mcp.vault.cool/mcp
```

**Credential if the form takes a bearer value (best guess)**

```text
Bearer hv_YOUR_KEY_HERE
```

**Credential if the form adds the word Bearer itself (best guess)**

```text
hv_YOUR_KEY_HERE
```

**First message in the agent's chat**

```text
Use the HyperVault MCP connection to run setup_challenge and complete the challenge it returns.
```

Check: In a chat with the Custom Agent, send: Use the HyperVault MCP connection to run setup_challenge and complete the challenge it returns. Once it is written, the key's row in the Agent keys card on the Account page reads Agent connected.

Things to know:

- Not confirmed. Notion's help page supports the plan, admin and menu steps, and says header-based authentication exists, but it never shows the form: not the field names, whether a header name can be chosen, whether Bearer is added for you, or whether a server with no authentication is accepted. The two credential strings are guesses from that wording.
- There is no key-in-URL fallback here, because the page does not say a server with no authentication is accepted.
- Each connection belongs to one Custom Agent and uses the credentials of whoever set it up. Repeat the setup for every agent that needs HyperVault.
- HyperVault has no OAuth. Notion says a server with neither OAuth with dynamic client registration nor a key or bearer token cannot be used with Custom Agents.

Sources: https://www.notion.com/help/mcp-connections-for-custom-agents
"""#

    static let codexCLI = #"""
# Connect an agent to HyperVault

This page is for an AI agent. It gets you, or the app you run in, connected to the person's HyperVault.

- Web app and REST API: https://hypervault.store
- MCP endpoint: https://mcp.vault.cool/mcp
- In every string below, hv_YOUR_KEY_HERE stands for the person's key. This page never holds a real one.

## The key

1. Look before you ask.
5. Never print it. When you show the person a command, show it with hv_YOUR_KEY_HERE or $HYPERVAULT_API_KEY in place of the key.

```bash
umask 077
mkdir -p ~/.config/hypervault && chmod 700 ~/.config/hypervault
```

## Recovery cheat sheet

| Status | `recovery.kind` | What it means | What to do |
| --- | --- | --- | --- |
| 401, 422 | `pair` | No key came with the request. | Find a key you already have. |

## Coding agents

### Codex CLI

- Client id: `codex-cli`
- Family: Coding agents
- Lane: MCP: native tools
- Key: Key sent as a bearer token, from an environment variable or a token field
- Shows tool calls and text results
- Status: Checked against the vendor's documentation on 2026-10-08. Most steps were not run in the live app.

Steps:

1. Export your key as HYPERVAULT_API_KEY in the shell profile that launches codex (for example ~/.zshrc or ~/.bashrc), then open a new terminal so the variable is present. The key stays out of Codex's config file this way.
2. Register the hosted server with the one command below. It writes a [mcp_servers.hypervault] table to ~/.codex/config.toml; you can paste that table by hand instead.
3. Codex then sends Authorization: Bearer with the variable's value on every request, which HyperVault accepts. The bearer-token flag works because Codex's OAuth fallback only applies when no credential source resolves.
4. Start a fresh codex session (a running one will not see the new server). codex mcp list confirms the entry; /mcp shows it inside the TUI.
5. Send the message below.

Paste exactly as shown (hv_YOUR_KEY_HERE stands for the key):

**Export the key (shell profile)**

```bash
export HYPERVAULT_API_KEY=hv_YOUR_KEY_HERE
```

**One-line add (recommended)**

```bash
codex mcp add hypervault --url https://mcp.vault.cool/mcp --bearer-token-env-var HYPERVAULT_API_KEY
```

**The equivalent ~/.codex/config.toml table**

```toml
[mcp_servers.hypervault]
url = "https://mcp.vault.cool/mcp"
bearer_token_env_var = "HYPERVAULT_API_KEY"
```

**Alternative: the key stored in config.toml (the file now holds a secret)**

```toml
[mcp_servers.hypervault]
url = "https://mcp.vault.cool/mcp"
http_headers = { "Authorization" = "Bearer hv_YOUR_KEY_HERE" }
```

**First message in a new session**

```text
Run the HyperVault setup_challenge tool and complete the challenge it returns.
```

Check: In a new session run codex mcp list, which should show hypervault enabled with Auth Bearer token and the variable HYPERVAULT_API_KEY. Then send: Run the HyperVault setup_challenge tool and complete the challenge it returns. The server appearing in /mcp is not proof. Once the challenge is written, the key's row in the Agent keys card on the Account page reads Agent connected.

Things to know:

- A missing, empty or misnamed HYPERVAULT_API_KEY still shows the server as enabled, because listing tools needs no key. Only tool calls fail, with Authentication required.
- The variable has to exist in the environment of the process that starts codex. Exporting it after codex is running does nothing until you restart.
- Codex's default auth is OAuth. HyperVault has none, so never run codex mcp login hypervault.
- A project-scoped .codex/config.toml only applies in trusted projects and may be committed. Put a literal key only in ~/.codex/config.toml, never in a repo.
- Enterprise-managed Codex setups can restrict mcp_servers through requirements, so the add may be refused there.
- Tested with codex-cli 0.161.0 against a local fake server: the add command wrote the expected TOML and the header reached the server exactly. Not exercised: an authenticated HyperVault tool call.

Sources: https://developers.openai.com/codex/mcp https://developers.openai.com/codex/cli/reference https://developers.openai.com/codex/config-sample
"""#

    static let http = #"""
# Connect an agent to HyperVault

This page is for an AI agent. It gets you, or the app you run in, connected to the person's HyperVault.

- Web app and REST API: https://hypervault.store
- MCP endpoint: https://mcp.vault.cool/mcp
- In every string below, hv_YOUR_KEY_HERE stands for the person's key. This page never holds a real one.

## The key

1. Look before you ask.
5. Never print it. When you show the person a command, show it with hv_YOUR_KEY_HERE or $HYPERVAULT_API_KEY in place of the key.

```bash
umask 077
mkdir -p ~/.config/hypervault && chmod 700 ~/.config/hypervault
```

## Recovery cheat sheet

| Status | `recovery.kind` | What it means | What to do |
| --- | --- | --- | --- |
| 401, 422 | `pair` | No key came with the request. | Find a key you already have. |

## Coding agents

### Any agent that can make HTTP requests

- Client id: `generic-http-agent`
- Family: Automation and APIs
- Lane: HTTP: plain requests, nothing to install
- Key: Key sent as a request header
- Shows tool calls and text results
- Status: Checked against the vendor's documentation on 2026-10-08. Most steps were not run in the live app.

Steps:

1. Make a key (Account, Agent keys, Generate a key). It is shown once, so keep it in an environment variable or a secret store.
2. Send the key on every request as the header X-HyperVault-Key. Authorization: Bearer with the same key works too. The commands below carry this deployment's own address.
3. Call GET /api/setup-challenge first. It returns the key's challenge slug, its content_url, whether it is done, and the exact edits that finish it.
4. Read the challenge page with GET /api/artifacts/{slug}/content and note content and head_version_id.
5. Make the edits the challenge describes, then PUT the whole edited page back to the same URL with content, a message and base_version_id (the head_version_id you read).
6. The key's row in the Agent keys card now shows Agent connected. After that use /api/save, /api/memories and the rest; GET /api with the key returns the catalog of everything the key can call (add ?format=markdown for a paste-ready version).
7. The key-in-URL form belongs to the MCP endpoint only and does not work on these routes, so always send the header here.

Paste exactly as shown (hv_YOUR_KEY_HERE stands for the key):

**Find this key's setup challenge (do this first)**

```bash
curl "https://hypervault.store/api/setup-challenge" \
  -H "X-HyperVault-Key: hv_YOUR_KEY_HERE"
```

**Read the challenge page (replace YOUR_ARTIFACT_SLUG with the slug it returned)**

```bash
curl "https://hypervault.store/api/artifacts/YOUR_ARTIFACT_SLUG/content" \
  -H "X-HyperVault-Key: hv_YOUR_KEY_HERE"
```

**Write the edited page back (base_version_id is the head_version_id from the read)**

```bash
curl -X PUT "https://hypervault.store/api/artifacts/YOUR_ARTIFACT_SLUG/content" \
  -H "Content-Type: application/json" \
  -H "X-HyperVault-Key: hv_YOUR_KEY_HERE" \
  -d '{"content": "<h1>v2</h1>", "message": "iterate", "base_version_id": "<head_version_id from the GET>"}'
```

**Save a page and get a permanent link**

```bash
curl -X POST "https://hypervault.store/api/save" \
  -H "Content-Type: application/json" \
  -H "X-HyperVault-Key: hv_YOUR_KEY_HERE" \
  -d '{"title": "Hello from my agent", "content": "<h1>It works</h1>"}'
```

**Remember something in the private memory**

```bash
curl -X POST "https://hypervault.store/api/memories" \
  -H "Content-Type: application/json" \
  -H "X-HyperVault-Key: hv_YOUR_KEY_HERE" \
  -d '{"content": "The user prefers dark mode."}'
```

Check: Run the setup-challenge request. HTTP 200 with JSON holding slug, content_url and complete means the key authenticates; 401 means the header was not sent or the key is wrong. Completing the challenge with the content PUT is the REST form of asking an MCP agent to run setup_challenge, and the key's row in the Agent keys card on the Account page reads Agent connected.

Things to know:

- This is plain REST, not MCP: for scripts, cron jobs, serverless functions and custom bots, and for any agent with a shell that does not want to install anything.
- The limit is 60 requests per minute per key.
- A PUT to /content has to name what it was built on: send base_version_id (or an If-Match header). Without one the write is refused with 428. A stale base can be refused with 409 or 412, and the reply includes the current head so you can merge again.
- Only mutable artifacts accept writes. The setup challenge page is mutable.
- /api/setup-challenge works only with a key, not with a signed-in session or an app token.
- YOUR_ARTIFACT_SLUG and the head version id are values you get at run time, not secrets.
- The key is a bearer secret: keep it out of logs and shell history, and read it from an environment variable in real scripts.
- There are no vendor docs for this entry. It was checked against HyperVault's own routes and MCP README, and no authenticated call was made against a live server, so the success response shapes come from the code.

Sources: https://github.com/johnnyclem/hypervault https://github.com/johnnyclem/hypervault-mcp
"""#

}
