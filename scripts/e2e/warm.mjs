#!/usr/bin/env node
// `next dev` compiles a route the first time it is requested, which takes
// seconds and would make the first test to touch each route time out. This asks
// every API route once, with the first test person's token, so the tests run
// against compiled code. GET on a made-up id is harmless: nothing is written.
//
//   node warm.mjs /path/to/web      (reads HV_E2E_ENV=<env.sh> for the server and token)

import fs from "node:fs";
import path from "node:path";

const web = process.argv[2];
const envFile = process.env.HV_E2E_ENV;
const env = {};
for (const line of fs.readFileSync(envFile, "utf8").split("\n")) {
  const m = line.match(/^export ([A-Z0-9_]+)=(.*)$/);
  if (m) env[m[1]] = m[2];
}
const base = env.HV_E2E_LOCAL_SERVER;
const token = env.HV_E2E_LOCAL_TOKEN;
const FAKE = "00000000-0000-4000-8000-000000000000";

function routes(dir, rel = "") {
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (entry.name === "__tests__" || entry.name.startsWith("_")) continue;
    if (entry.isDirectory()) out.push(...routes(path.join(dir, entry.name), `${rel}/${entry.name}`));
    else if (entry.name === "route.ts") out.push(rel || "/");
  }
  return out;
}

const paths = routes(path.join(web, "app/api"))
  .filter((p) => !p.startsWith("/cron"))
  .map((p) => "/api" + p.replace(/\[\.\.\.[^\]]+\]/g, "x").replace(/\[[^\]]+\]/g, FAKE));
paths.push("/", "/login", "/vault", "/explain.md", "/connect.md", "/start.md");

let done = 0;
const queue = [...paths];
async function worker() {
  while (queue.length) {
    const p = queue.shift();
    try {
      await fetch(base + p, { headers: { authorization: `Bearer ${token}`, accept: "application/json" }, signal: AbortSignal.timeout(180_000), redirect: "manual" });
    } catch (e) {
      console.error(`warm ${p}: ${e.message}`);
    }
    done++;
  }
}
const started = Date.now();
await Promise.all([worker(), worker(), worker()]);
console.error(`warmed ${done} routes in ${Math.round((Date.now() - started) / 1000)}s`);
