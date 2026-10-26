#!/usr/bin/env node
// Rewrites a HyperVault migration so it runs on a stock PostgreSQL with no
// pgvector: the vector(N) column type becomes real[], `create extension vector`
// goes, and ivfflat / hnsw indexes are dropped. The `<=>` operator the
// migrations' functions call is defined over real[] in sql/bootstrap.sql.
//
//   node transform-migration.mjs <file.sql>   (prints the transformed SQL)
//
// Everything the migrations need that a plain Postgres lacks is fixed in the
// bootstrap or here, never in the migrations themselves.

import fs from "node:fs";

export function transform(sql) {
  let out = sql;
  // create extension [if not exists] vector [...];
  out = out.replace(/create\s+extension\s+(if\s+not\s+exists\s+)?"?vector"?[^;]*;/gi, "-- (stand-in) pgvector is real[] here;");
  // vector(1536) / extensions.vector(1536) / public.vector(1536)
  out = out.replace(/\b(?:(?:extensions|public)\.)?vector\s*\(\s*\d+\s*\)/gi, "real[]");
  // A bare `vector` type name in a declaration position.
  out = out.replace(/(:\s*:?\s*)(?:(?:extensions|public)\.)?vector\b(?!\s*[\w(])/gi, "$1real[]");
  // ivfflat / hnsw indexes, with or without a WITH (...) clause.
  out = out.replace(/create\s+(?:unique\s+)?index\s[^;]*?\b(?:ivfflat|hnsw)\b[^;]*;/gis, "-- (stand-in) approximate vector index dropped;");
  // Two of the early migrations overlap (the fourth is a catch-up for a database that missed the second
  // and third), and a `create policy` has no `if not exists`. Dropping the policy first makes each
  // of them safe to run in the order the files sort.
  out = out.replace(
    /create\s+policy\s+("[^"]+"|\w+)\s+on\s+((?:"?\w+"?\.)?"?\w+"?)/gi,
    (match, name, table) => `drop policy if exists ${name} on ${table};\n${match}`
  );
  return out;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  process.stdout.write(transform(fs.readFileSync(process.argv[2], "utf8")));
}
