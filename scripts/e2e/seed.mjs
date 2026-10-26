#!/usr/bin/env node
// Creates the throwaway test people in the local database and mints their
// access tokens, plus the project's anon and service-role keys, all signed with
// the local JWT secret. Prints a shell-sourceable env file to --out.
//
//   node seed.mjs --socket DIR --pgport 54329 --db hv --secret S --url http://127.0.0.1:54321 --out tokens.env
//
// People (re-running reuses them and mints fresh tokens):
//   alice  a member            alice@e2e.test
//   bob    a second member     bob@e2e.test
//   admin  an administrator    admin@e2e.test   (HYPERVAULT_ADMIN_EMAILS names it)
//   carol  waitlisted          carol@e2e.test   (no account_access row: redeems an invite)

import fs from "node:fs";
import { PgConn } from "./lib/pg.mjs";
import { sign } from "./lib/jwt.mjs";

const args = Object.fromEntries(process.argv.slice(2).reduce((acc, a, i, all) => (a.startsWith("--") ? [...acc, [a.slice(2), all[i + 1]]] : acc), []));
const secret = args.secret ?? process.env.HV_E2E_JWT_SECRET;
if (!secret) throw new Error("--secret is required");

export const PEOPLE = [
  { key: "alice", email: "alice@e2e.test", name: "Alice Example", access: true },
  { key: "bob", email: "bob@e2e.test", name: "Bob Example", access: true },
  { key: "admin", email: "admin@e2e.test", name: "Ada Admin", access: true },
  { key: "carol", email: "carol@e2e.test", name: "Carol Waitlisted", access: false },
  // A pool of further members. The server meters each person at 120 calls a minute, so a long
  // suite spreads its areas over these rather than waiting on one person's budget.
  ...Array.from({ length: Number(process.env.HV_E2E_POOL_USERS ?? 12) }, (_, i) => {
    const n = String(i + 1).padStart(2, "0");
    return { key: `pool${n}`, email: `pool${n}@e2e.test`, name: `Pool ${n}`, access: true };
  }),
];

const conn = await new PgConn({ socketPath: `${args.socket}/.s.PGSQL.${args.pgport ?? 54329}`, user: "postgres", database: args.db ?? "hv" }).connect();
const now = Math.floor(Date.now() / 1000);
const out = {};

for (const person of PEOPLE) {
  const meta = JSON.stringify({ full_name: person.name });
  const r = await conn.query(
    `insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data, last_sign_in_at)
     values (gen_random_uuid(), $1, now(), $2::jsonb, now())
     on conflict (email) do update set raw_user_meta_data = excluded.raw_user_meta_data
     returning id::text`,
    [person.email, meta]
  );
  const id = r.rows[0][0];
  if (person.access) {
    await conn.query("insert into public.account_access (user_id, source) values ($1::uuid, 'admin') on conflict do nothing", [id]);
    await conn.query("delete from public.waitlist where user_id = $1::uuid", [id]);
  } else {
    await conn.query("delete from public.account_access where user_id = $1::uuid", [id]);
    await conn.query("insert into public.waitlist (user_id, email) values ($1::uuid, $2) on conflict do nothing", [id, person.email]);
  }
  const claims = (exp) => ({
    aud: "authenticated",
    exp,
    iat: now,
    sub: id,
    email: person.email,
    phone: "",
    app_metadata: { provider: "email", providers: ["email"] },
    user_metadata: { full_name: person.name },
    role: "authenticated",
    aal: "aal1",
    session_id: `e2e-${person.key}`,
    is_anonymous: false,
  });
  out[person.key] = { id, token: sign(claims(now + 24 * 3600), secret), expired: sign(claims(now - 60), secret) };
}

const pool = PEOPLE.filter((p) => p.key.startsWith("pool")).map((p) => out[p.key].token);
const anon = sign({ iss: "supabase-e2e", role: "anon", iat: now, exp: now + 10 * 365 * 24 * 3600 }, secret);
const service = sign({ iss: "supabase-e2e", role: "service_role", iat: now, exp: now + 10 * 365 * 24 * 3600 }, secret);

const url = args.url ?? "http://127.0.0.1:54321";
const lines = [
  `HV_E2E_SUPABASE_URL=${url}`,
  `HV_E2E_ANON_KEY=${anon}`,
  `HV_E2E_SERVICE_KEY=${service}`,
  `HV_E2E_LOCAL_TOKEN=${out.alice.token}`,
  `HV_E2E_LOCAL_TOKEN_2=${out.bob.token}`,
  `HV_E2E_LOCAL_ADMIN_TOKEN=${out.admin.token}`,
  `HV_E2E_LOCAL_WAITLIST_TOKEN=${out.carol.token}`,
  `HV_E2E_LOCAL_EXPIRED_TOKEN=${out.alice.expired}`,
  `HV_E2E_LOCAL_POOL_TOKENS=${pool.join(",")}`,
  `HV_E2E_USER_ID=${out.alice.id}`,
  `HV_E2E_USER_ID_2=${out.bob.id}`,
  `HV_E2E_ADMIN_ID=${out.admin.id}`,
  `HV_E2E_WAITLIST_ID=${out.carol.id}`,
];
if (args.out) fs.writeFileSync(args.out, lines.join("\n") + "\n", { mode: 0o600 });
else console.log(lines.join("\n"));
console.error(`seeded ${PEOPLE.length} people`);
conn.close();
