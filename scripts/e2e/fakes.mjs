#!/usr/bin/env node
// Three small stand-ins the web app can be pointed at, so the routes that call out can be run without any
// outside service. All on one local port, no dependencies, nothing leaves the machine.
//
//   /llm/v1/chat/completions   an OpenAI-compatible model that answers with an echo of what it was asked
//   /llm/v1/messages           the same for the Anthropic protocol
//   /llm/v1/embeddings         deterministic 1536-dimension vectors (words hashed into the dimensions)
//   /llm/v1/models
//   /mcp                       a Streamable-HTTP MCP server with two tools: echo and add
//   /mcp-auth                  the same behind "Authorization: Bearer mcp-secret" (401 with a challenge otherwise)
//   /hook/<anything>           a webhook receiver; /hook/fail answers 500
//   /__log, /__received        what the stand-ins were asked, for the tests to read
//
//   node fakes.mjs --port 54340

import http from "node:http";
import crypto from "node:crypto";

const args = Object.fromEntries(process.argv.slice(2).reduce((acc, a, i, all) => (a.startsWith("--") ? [...acc, [a.slice(2), all[i + 1]]] : acc), []));
const port = Number(args.port ?? process.env.HV_E2E_FAKES_PORT ?? 54340);

const llmLog = [];
const received = [];
const mcpSessions = new Set();

const json = (res, status, body, headers = {}) => {
  res.writeHead(status, { "content-type": "application/json", ...headers });
  res.end(JSON.stringify(body));
};

async function readText(req) {
  const chunks = [];
  for await (const c of req) chunks.push(c);
  return Buffer.concat(chunks).toString("utf8");
}

// ── the model ──────────────────────────────────────────────────────────────

function replyFor(messages, system) {
  const last = [...messages].reverse().find((m) => m.role === "user");
  const text = typeof last?.content === "string" ? last.content : (last?.content ?? []).map((p) => p.text ?? "").join(" ");
  if (/Reply with the single word: ok/i.test(text)) return "ok";
  // An "@handle" in a reply would hand the floor to that member of a room; the echo says it without the @.
  const trimmed = text.replace(/\s+/g, " ").trim().slice(0, 300).replace(/@/g, "(at)");
  const hasSystem = Boolean(system && system.trim());
  return `Echo (${messages.length} messages, system ${hasSystem ? "yes" : "no"}): ${trimmed}`;
}

function textOf(content) {
  return typeof content === "string" ? content : (content ?? []).map((p) => p.text ?? "").join("");
}

const dims = 1536;
function embed(text) {
  const v = new Array(dims).fill(0);
  for (const word of String(text).toLowerCase().match(/[a-z0-9]+/g) ?? []) {
    const h = crypto.createHash("sha1").update(word).digest();
    v[h.readUInt16BE(0) % dims] += 1;
    v[h.readUInt16BE(2) % dims] += 0.5;
  }
  const norm = Math.sqrt(v.reduce((s, x) => s + x * x, 0)) || 1;
  return v.map((x) => x / norm);
}

async function handleLlm(req, res, path) {
  const body = JSON.parse((await readText(req)) || "{}");
  llmLog.push({ at: new Date().toISOString(), path, authorization: req.headers["authorization"] ?? req.headers["x-api-key"] ?? null, body });
  if (llmLog.length > 500) llmLog.shift();
  const model = body.model ?? "fake-model";
  if (model === "always-fails") return json(res, 500, { error: { message: "the model is down" } });
  if (model === "bad-key" || (req.headers["authorization"] ?? "").includes("sk-wrong")) return json(res, 401, { error: { message: "Incorrect API key provided" } });

  if (path === "/llm/v1/chat/completions") {
    const system = body.messages.filter((m) => m.role === "system").map((m) => textOf(m.content)).join("\n");
    const content = replyFor(body.messages.filter((m) => m.role !== "system").map((m) => ({ ...m, content: textOf(m.content) })), system);
    return json(res, 200, {
      id: `chatcmpl-${crypto.randomUUID()}`, object: "chat.completion", created: Math.floor(Date.now() / 1000), model,
      choices: [{ index: 0, message: { role: "assistant", content }, finish_reason: "stop" }],
      usage: { prompt_tokens: 10, completion_tokens: 10, total_tokens: 20 },
    });
  }
  if (path === "/llm/v1/messages") {
    const content = replyFor(body.messages, typeof body.system === "string" ? body.system : "");
    return json(res, 200, {
      id: `msg_${crypto.randomUUID()}`, type: "message", role: "assistant", model,
      content: [{ type: "text", text: content }], stop_reason: "end_turn", usage: { input_tokens: 10, output_tokens: 10 },
    });
  }
  if (path === "/llm/v1/embeddings") {
    const inputs = Array.isArray(body.input) ? body.input : [body.input];
    return json(res, 200, {
      object: "list", model,
      data: inputs.map((text, index) => ({ object: "embedding", index, embedding: embed(text) })),
      usage: { prompt_tokens: 5, total_tokens: 5 },
    });
  }
  return json(res, 404, { error: { message: `no ${path}` } });
}

// ── the MCP server ─────────────────────────────────────────────────────────

const tools = [
  { name: "echo", description: "Echo a message back", inputSchema: { type: "object", properties: { message: { type: "string" } }, required: ["message"] } },
  { name: "add", description: "Add two numbers", inputSchema: { type: "object", properties: { a: { type: "number" }, b: { type: "number" } }, required: ["a", "b"] } },
];

async function handleMcp(req, res, path) {
  if (req.method !== "POST") {
    res.writeHead(405, { allow: "POST" });
    return res.end();
  }
  if (path === "/mcp-auth" && req.headers["authorization"] !== "Bearer mcp-secret") {
    return json(res, 401, { error: "unauthorized" }, { "www-authenticate": 'Bearer resource_metadata="http://127.0.0.1/.well-known/oauth-protected-resource"' });
  }
  const text = await readText(req);
  const message = JSON.parse(text || "{}");
  llmLog.push({ at: new Date().toISOString(), path, mcp: message.method });
  if (message.method === "notifications/initialized") {
    res.writeHead(202);
    return res.end();
  }
  const reply = (result) => json(res, 200, { jsonrpc: "2.0", id: message.id, result });
  if (message.method === "initialize") {
    const session = crypto.randomUUID();
    mcpSessions.add(session);
    return json(res, 200, { jsonrpc: "2.0", id: message.id, result: { protocolVersion: message.params?.protocolVersion ?? "2025-03-26", capabilities: { tools: {} }, serverInfo: { name: path === "/mcp-auth" ? "Fake Private MCP" : "Fake MCP", version: "1.0" } } }, { "mcp-session-id": session });
  }
  if (message.method === "tools/list") return reply({ tools });
  if (message.method === "tools/call") {
    const { name, arguments: a = {} } = message.params ?? {};
    if (name === "echo") return reply({ content: [{ type: "text", text: `echo: ${a.message}` }], isError: false });
    if (name === "add") return reply({ content: [{ type: "text", text: String(Number(a.a) + Number(a.b)) }], isError: false });
    return reply({ content: [{ type: "text", text: `no tool ${name}` }], isError: true });
  }
  return json(res, 200, { jsonrpc: "2.0", id: message.id, error: { code: -32601, message: `Method not found: ${message.method}` } });
}

// ── the webhook receiver ───────────────────────────────────────────────────

async function handleHook(req, res, path) {
  const body = await readText(req);
  received.push({ at: new Date().toISOString(), method: req.method, path, headers: req.headers, body });
  if (received.length > 500) received.shift();
  if (path === "/hook/fail") return json(res, 500, { ok: false });
  return json(res, 200, { ok: true });
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  const path = url.pathname;
  try {
    if (path === "/health") return json(res, 200, { ok: true });
    if (path === "/__log") return json(res, 200, llmLog);
    if (path === "/__received") {
      if (req.method === "DELETE") {
        received.length = 0;
        llmLog.length = 0;
        return json(res, 200, { cleared: true });
      }
      const want = url.searchParams.get("path");
      return json(res, 200, received.filter((r) => !want || r.path === want));
    }
    if (path.startsWith("/llm/v1/")) {
      if (req.method === "GET" && path === "/llm/v1/models") return json(res, 200, { object: "list", data: [{ id: "fake-model", object: "model" }] });
      return await handleLlm(req, res, path);
    }
    if (path === "/mcp" || path === "/mcp-auth") return await handleMcp(req, res, path);
    if (path.startsWith("/hook/")) return await handleHook(req, res, path);
    json(res, 404, { error: `nothing at ${path}` });
  } catch (e) {
    json(res, 500, { error: String(e?.message ?? e) });
  }
});

server.listen(port, "127.0.0.1", () => console.error(`[fakes] listening on http://127.0.0.1:${port} (llm, mcp, hooks)`));
for (const sig of ["SIGINT", "SIGTERM"]) process.on(sig, () => server.close(() => process.exit(0)));
