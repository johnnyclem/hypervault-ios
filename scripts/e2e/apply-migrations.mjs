#!/usr/bin/env node
// Applies sql/bootstrap.sql and then every migration in the web repo, in
// filename order, through transform-migration.mjs. Records what ran in a
// hv_e2e.applied table, so a second run only applies new files.
//
//   node apply-migrations.mjs --web /path/to/web --socket DIR --port 54329 --db hv

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { PgConn } from "./lib/pg.mjs";
import { transform } from "./transform-migration.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const args = Object.fromEntries(process.argv.slice(2).reduce((acc, a, i, all) => (a.startsWith("--") ? [...acc, [a.slice(2), all[i + 1]]] : acc), []));
const web = args.web ?? process.env.HYPERVAULT_WEB;
if (!web) throw new Error("--web (the web repo) is required");

const conn = await new PgConn({
  socketPath: `${args.socket}/.s.PGSQL.${args.port}`,
  user: "postgres",
  database: args.db ?? "hv",
}).connect();

await conn.simple("create schema if not exists hv_e2e; create table if not exists hv_e2e.applied (name text primary key, applied_at timestamptz default now())");
const done = new Set((await conn.query("select name from hv_e2e.applied")).rows.map((r) => r[0]));

async function run(name, sql) {
  if (done.has(name)) return;
  try {
    await conn.simple("begin");
    await conn.simple(sql);
    await conn.query("insert into hv_e2e.applied(name) values ($1)", [name]);
    await conn.simple("commit");
    console.log(`applied ${name}`);
  } catch (e) {
    await conn.simple("rollback").catch(() => {});
    console.error(`FAILED ${name}: ${e.message}${e.detail ? ` (${e.detail})` : ""}${e.position ? ` at ${e.position}` : ""}`);
    process.exit(1);
  }
}

await run("bootstrap.sql", fs.readFileSync(path.join(here, "sql/bootstrap.sql"), "utf8"));
const dir = path.join(web, "supabase/migrations");
for (const file of fs.readdirSync(dir).filter((f) => f.endsWith(".sql")).sort()) {
  await run(file, transform(fs.readFileSync(path.join(dir, file), "utf8")));
}
// Grants for objects the migrations created after the default privileges.
await conn.simple("grant usage on schema public to anon, authenticated, service_role");
console.log("migrations done");
conn.close();
