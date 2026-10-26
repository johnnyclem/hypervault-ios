#!/usr/bin/env node
// The local Supabase stand-in: one HTTP server that answers /auth/v1 (a fake
// GoTrue) and /rest/v1 (a PostgREST-compatible layer) over a local PostgreSQL,
// so NEXT_PUBLIC_SUPABASE_URL can point at it.
//
//   node stack.mjs --port 54321 --socket DIR --pgport 54329 --db hv --secret <jwt secret>
//
// Throwaway, local use only. It never talks to anything but the database it is
// given and the clients that call it.

import http from "node:http";
import { PgPool } from "./lib/pg.mjs";
import { createRestHandler } from "./lib/postgrest.mjs";
import { createAuthHandler } from "./lib/gotrue.mjs";
import { createStorageHandler } from "./lib/storage.mjs";

const args = Object.fromEntries(process.argv.slice(2).reduce((acc, a, i, all) => (a.startsWith("--") ? [...acc, [a.slice(2), all[i + 1]]] : acc), []));
const port = Number(args.port ?? process.env.HV_E2E_STACK_PORT ?? 54321);
const secret = args.secret ?? process.env.HV_E2E_JWT_SECRET;
if (!secret) throw new Error("a JWT secret is required (--secret or HV_E2E_JWT_SECRET)");
const verbose = process.env.HV_E2E_VERBOSE === "1";
const log = (m) => console.error(`[stack ${new Date().toISOString()}] ${m}`);

const pool = new PgPool(
  { socketPath: `${args.socket}/.s.PGSQL.${args.pgport ?? 54329}`, user: "postgres", database: args.db ?? "hv" },
  Number(process.env.HV_E2E_POOL ?? 10)
);

const rest = createRestHandler({ pool, jwtSecret: secret, log });
const auth = createAuthHandler({ pool, jwtSecret: secret, ttlSeconds: Number(process.env.HV_E2E_TOKEN_TTL ?? 3600), log });
const storage = createStorageHandler({ pool, jwtSecret: secret, dir: args.storage ?? process.env.HV_E2E_STORAGE_DIR, baseUrl: `http://127.0.0.1:${port}`, log });

async function readAll(req) {
  const chunks = [];
  for await (const c of req) chunks.push(c);
  return Buffer.concat(chunks);
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host ?? "localhost"}`);
  const started = Date.now();
  res.on("finish", () => {
    if (verbose) log(`${req.method} ${url.pathname}${url.search.slice(0, 160)} -> ${res.statusCode} (${Date.now() - started}ms)`);
  });
  try {
    if (url.pathname.startsWith("/auth/v1")) return await auth.handle(req, res, url);
    if (url.pathname.startsWith("/rest/v1")) return await rest.handle(req, res, url, await readAll(req));
    if (url.pathname.startsWith("/storage/v1")) return await storage.handle(req, res, url);
    if (url.pathname === "/health") {
      await pool.query("select 1");
      res.writeHead(200, { "content-type": "application/json" });
      return res.end(JSON.stringify({ ok: true }));
    }
    res.writeHead(404, { "content-type": "application/json" });
    res.end(JSON.stringify({ message: `stand-in: nothing at ${url.pathname}` }));
  } catch (e) {
    log(`unhandled: ${e?.stack ?? e}`);
    if (!res.headersSent) res.writeHead(500, { "content-type": "application/json" });
    res.end(JSON.stringify({ message: String(e?.message ?? e) }));
  }
});

server.keepAliveTimeout = 30_000;
server.listen(port, "127.0.0.1", () => log(`listening on http://127.0.0.1:${port} (auth, rest, storage)`));
for (const sig of ["SIGINT", "SIGTERM"]) process.on(sig, () => server.close(() => process.exit(0)));
