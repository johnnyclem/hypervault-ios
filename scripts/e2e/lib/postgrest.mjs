// A PostgREST-compatible HTTP layer over PostgreSQL, for the part of PostgREST
// that supabase-js and the HyperVault iOS Kit actually use. It follows
// PostgREST's documented behaviour (https://docs.postgrest.org/en/stable/):
//
//   - GET / HEAD / POST / PATCH / DELETE on tables and views, POST|GET /rpc/<fn>
//   - select with column lists, *, aliases, casts, JSON paths, embedded
//     resources through foreign keys (to-one, to-many, !inner, !hint)
//   - filters eq neq gt gte lt lte like ilike match imatch in is isdistinct fts plfts phfts wfts
//     cs cd ov sl sr nxl nxr adj, `not.`, (any)/(all), and/or trees
//   - order (asc/desc/nullsfirst/nullslast, JSON paths, to-one embeds), limit, offset, Range
//   - Prefer: count, return, resolution, missing; Accept: vnd.pgrst.object+json
//   - upsert with on_conflict, PostgREST-shaped errors
//
// Every request runs in one transaction with `set local role` to the caller's
// JWT role and request.jwt.claims set, so row-level security and auth.uid()
// behave as in a Supabase project.

import { verify } from "./jwt.mjs";

const ROLES = new Set(["anon", "authenticated", "service_role"]);
const RESERVED = new Set(["select", "order", "limit", "offset", "columns", "on_conflict", "apikey"]);
const OPS = {
  eq: "=", gt: ">", gte: ">=", lt: "<", lte: "<=", neq: "<>",
  like: "LIKE", ilike: "ILIKE", match: "~", imatch: "~*",
  cs: "@>", cd: "<@", ov: "&&", sl: "<<", sr: ">>", nxr: "&<", nxl: "&>", adj: "-|-",
};
const FTS = { fts: "to_tsquery", plfts: "plainto_tsquery", phfts: "phraseto_tsquery", wfts: "websearch_to_tsquery" };

export class RestError extends Error {
  constructor(status, code, message, details = null, hint = null, headers = {}) {
    super(message);
    this.status = status;
    this.code = code;
    this.details = details;
    this.hint = hint;
    this.headers = headers;
  }
  body() {
    return { code: this.code, details: this.details, hint: this.hint, message: this.message };
  }
}

const ident = (s) => `"${String(s).replace(/"/g, '""')}"`;
const lit = (s) => `'${String(s).replace(/'/g, "''")}'`;

/** Postgres SQLSTATE class to the HTTP status PostgREST uses. */
export function statusForPgError(err, role) {
  const code = err.code ?? "";
  if (/^PT\d{3}$/.test(code)) return Number(code.slice(2));
  if (code === "42501") return role === "anon" ? 401 : 403;
  if (code === "42883" || code === "42P01") return 404;
  if (code === "23503" || code === "23505") return 409;
  if (code === "25006") return 405;
  if (code === "P0001") return 400;
  if (code.startsWith("08") || code.startsWith("53")) return 503;
  if (code.startsWith("09") || code.startsWith("25") || code.startsWith("2D") || code.startsWith("38") ||
      code.startsWith("39") || code.startsWith("3B") || code.startsWith("40") || code.startsWith("54") ||
      code.startsWith("55") || code.startsWith("57") || code.startsWith("58") || code.startsWith("F0") ||
      code.startsWith("HV") || code === "42P17") return 500;
  if (code.startsWith("0L") || code.startsWith("0P") || code.startsWith("28")) return 403;
  return 400;
}

// ── small parsers ──────────────────────────────────────────────────────────

/** Splits on `sep` at parenthesis depth 0, outside double quotes. */
function splitTop(str, sep = ",") {
  const out = [];
  let depth = 0;
  let inQuote = false;
  let cur = "";
  for (let i = 0; i < str.length; i++) {
    const ch = str[i];
    if (inQuote) {
      cur += ch;
      if (ch === "\\" && i + 1 < str.length) cur += str[++i];
      else if (ch === '"') inQuote = false;
      continue;
    }
    if (ch === '"') { inQuote = true; cur += ch; continue; }
    if (ch === "(") depth++;
    if (ch === ")") depth--;
    if (ch === sep && depth === 0) { out.push(cur); cur = ""; continue; }
    cur += ch;
  }
  out.push(cur);
  return out;
}

function unquote(s) {
  s = s.trim();
  if (s.length >= 2 && s[0] === '"' && s[s.length - 1] === '"') return s.slice(1, -1).replace(/\\(.)/g, "$1");
  return s;
}

function parseError(what, text) {
  return new RestError(400, "PGRST100", `"failed to parse ${what} (${text})"`, null, null);
}

/** `a->b->>c` into { column, steps: [{op, key}] }. */
function parseColumnPath(text) {
  const tokens = text.split(/(->>|->)/);
  const column = unquote(tokens[0]);
  const steps = [];
  for (let i = 1; i < tokens.length; i += 2) steps.push({ op: tokens[i], key: unquote(tokens[i + 1] ?? "") });
  return { column, steps };
}

class Params {
  constructor() { this.values = []; }
  add(v) { this.values.push(v); return `$${this.values.length}`; }
}

/** SQL for a column reference, with an optional JSON path. */
function columnSql(text, alias) {
  const { column, steps } = parseColumnPath(text);
  let sql = alias ? `${ident(alias)}.${ident(column)}` : ident(column);
  for (const s of steps) {
    const key = /^-?\d+$/.test(s.key) ? s.key : lit(s.key);
    sql = `${sql}${s.op}${key}`;
  }
  return steps.length ? `(${sql})` : sql;
}

// ── select parsing ─────────────────────────────────────────────────────────

function parseSelect(text) {
  const nodes = [];
  for (const raw of splitTop(text)) {
    const item = raw.trim();
    if (!item) continue;
    if (item === "*") { nodes.push({ kind: "star" }); continue; }
    let spread = false;
    let rest = item;
    if (rest.startsWith("...")) { spread = true; rest = rest.slice(3); }
    let alias = null;
    const am = rest.match(/^([\w-]+):(?!:)(.*)$/s);
    if (am) { alias = am[1]; rest = am[2]; }
    const open = rest.indexOf("(");
    if (open > 0 && rest.endsWith(")")) {
      const head = rest.slice(0, open);
      const inner = rest.slice(open + 1, -1);
      const [name, ...mods] = head.split("!");
      let join = "left";
      let hint = null;
      for (const m of mods) {
        if (m === "inner") join = "inner";
        else if (m === "left") join = "left";
        else hint = m;
      }
      nodes.push({ kind: "embed", name, alias: alias ?? name, hint, join, spread, children: parseSelect(inner), params: {} });
      continue;
    }
    let cast = null;
    const cm = rest.match(/^(.*?)::([\w ]+(?:\(\d+(?:,\d+)?\))?(?:\[\])?)$/s);
    if (cm) { rest = cm[1]; cast = cm[2]; }
    nodes.push({ kind: "col", text: rest, alias, cast });
  }
  return nodes;
}

// ── filters ────────────────────────────────────────────────────────────────

/** Parses `[not.]op[(q)].operand` into a leaf. */
function parseOperator(col, value) {
  let rest = value;
  let negate = false;
  if (rest.startsWith("not.")) { negate = true; rest = rest.slice(4); }
  const dot = rest.indexOf(".");
  if (dot < 0) throw parseError("filter", `${col}=${value}`);
  let opToken = rest.slice(0, dot);
  const operand = rest.slice(dot + 1);
  let quant = null;
  let config = null;
  const qm = opToken.match(/^(\w+)\((\w+)\)$/);
  if (qm) {
    opToken = qm[1];
    if (opToken in FTS) config = qm[2];
    else if (qm[2] === "any" || qm[2] === "all") quant = qm[2];
  }
  if (!(opToken in OPS) && !(opToken in FTS) && opToken !== "in" && opToken !== "is" && opToken !== "isdistinct") {
    throw parseError("filter", `${col}=${value}`);
  }
  return { type: "leaf", col, op: opToken, negate, quant, config, operand };
}

function parseLogic(kind, negate, text) {
  const t = text.trim();
  if (!t.startsWith("(") || !t.endsWith(")")) throw parseError("logic tree", text);
  const items = splitTop(t.slice(1, -1));
  const children = [];
  for (const item of items) {
    const s = item.trim();
    const lm = s.match(/^(not\.)?(and|or)(\(.*\))$/s);
    if (lm) { children.push(parseLogic(lm[2], Boolean(lm[1]), lm[3])); continue; }
    // col.op.value, where col may be a JSON path and the value may contain dots.
    const m = s.match(/^([^.]+)\.(.*)$/s);
    if (!m) throw parseError("logic tree", s);
    children.push(parseOperator(m[1], m[2]));
  }
  return { type: "logic", kind, negate, children };
}

function operandList(text) {
  const t = text.trim();
  if (!t.startsWith("(") || !t.endsWith(")")) throw parseError("filter", `in.${text}`);
  const inner = t.slice(1, -1);
  if (inner.trim() === "") return [];
  return splitTop(inner).map(unquote);
}

function filterSql(node, alias, P) {
  if (node.type === "logic") {
    const parts = node.children.map((c) => filterSql(c, alias, P));
    const sql = parts.length ? `(${parts.join(node.kind === "and" ? " AND " : " OR ")})` : "true";
    return node.negate ? `NOT ${sql}` : sql;
  }
  const col = columnSql(node.col, alias);
  const wrap = (sql) => (node.negate ? `NOT (${sql})` : sql);
  const { op, operand } = node;
  if (op === "is") {
    const v = operand.toLowerCase();
    const map = { null: "NULL", true: "TRUE", false: "FALSE", unknown: "UNKNOWN", not_null: "NOT NULL" };
    if (!(v in map)) throw parseError("filter", `${node.col}=is.${operand}`);
    return `(${col} IS ${node.negate ? "NOT " : ""}${map[v]})`;
  }
  if (op === "isdistinct") return wrap(`${col} IS DISTINCT FROM ${P.add(operand)}`);
  if (op === "in") {
    const items = operandList(operand);
    if (items.length === 0) return wrap("false");
    return wrap(`${col} IN (${items.map((i) => P.add(i)).join(", ")})`);
  }
  if (op in FTS) {
    const cfg = node.config ? `${lit(node.config.replace(/[^\w]/g, ""))}::regconfig, ` : "";
    return wrap(`${col} @@ ${FTS[op]}(${cfg}${P.add(operand)})`);
  }
  const sqlOp = OPS[op];
  let value = operand;
  if (op === "like" || op === "ilike") value = value.replace(/\*/g, "%");
  if (node.quant) {
    const items = operandList(operand.startsWith("{") ? `(${operand.slice(1, -1)})` : operand).map((v) => (op === "like" || op === "ilike" ? v.replace(/\*/g, "%") : v));
    return wrap(`${col} ${sqlOp} ${node.quant === "any" ? "ANY" : "ALL"} (${P.add(`{${items.map((i) => `"${i.replace(/(["\\])/g, "\\$1")}"`).join(",")}}`)})`);
  }
  return wrap(`${col} ${sqlOp} ${P.add(value)}`);
}

/** Splits query params into the root's and each embed's (by dotted prefix). */
function collectParams(searchParams, rootEmbeds) {
  const root = { filters: [], order: null, limit: null, offset: null };
  const embeds = new Map(); // path string -> same shape
  const bucket = (pathParts) => {
    if (pathParts.length === 0) return root;
    const key = pathParts.join(".");
    if (!embeds.has(key)) embeds.set(key, { filters: [], order: null, limit: null, offset: null });
    return embeds.get(key);
  };
  for (const [key, value] of searchParams.entries()) {
    if (key === "select" || key === "columns" || key === "on_conflict" || key === "apikey") continue;
    const parts = key.split(".");
    let negate = false;
    let last = parts[parts.length - 1];
    let prefix = parts.slice(0, -1);
    if (last === "and" || last === "or") {
      if (prefix[prefix.length - 1] === "not") { negate = true; prefix = prefix.slice(0, -1); }
      bucket(prefix).filters.push(parseLogic(last, negate, value));
      continue;
    }
    if (last === "order" || last === "limit" || last === "offset") {
      const b = bucket(prefix);
      if (last === "order") b.order = value;
      else b[last] = Number(value);
      if (last !== "order" && !Number.isInteger(b[last])) throw new RestError(400, "PGRST100", `"failed to parse ${last} (${value})"`);
      continue;
    }
    // A column of the embed at `prefix` (or the root).
    const b = bucket(prefix);
    b.filters.push(parseOperator(key.slice(prefix.join(".").length + (prefix.length ? 1 : 0)), value));
  }
  return { root, embeds };
}

function orderSql(text, alias, relation) {
  const terms = [];
  for (const raw of splitTop(text)) {
    const t = raw.trim();
    if (!t) continue;
    // col[.asc|.desc][.nullsfirst|.nullslast]; rel(col) for a to-one embed.
    const m = t.match(/^(.*?)((?:\.(?:asc|desc|nullsfirst|nullslast))*)$/s);
    const colText = m[1];
    const mods = m[2].split(".").filter(Boolean);
    const rel = colText.match(/^(\w+)\((.+)\)$/);
    let sql;
    if (rel) {
      const link = relation?.toOne?.get(rel[1]);
      if (!link) throw new RestError(400, "PGRST118", `Could not order with the embedded resource '${rel[1]}'`, null, null);
      sql = `(SELECT ${columnSql(rel[2], "_o")} FROM ${link.target} AS "_o" WHERE ${link.join("_o", alias)})`;
    } else {
      sql = columnSql(colText, alias);
    }
    const dir = mods.includes("desc") ? "DESC" : mods.includes("asc") ? "ASC" : "";
    const nulls = mods.includes("nullsfirst") ? "NULLS FIRST" : mods.includes("nullslast") ? "NULLS LAST" : "";
    terms.push([sql, dir, nulls].filter(Boolean).join(" "));
  }
  return terms.join(", ");
}

// ── the handler ────────────────────────────────────────────────────────────

export function createRestHandler({ pool, jwtSecret, schemas = ["public"], log = () => {} }) {
  let cache = null;
  let cacheAt = 0;

  async function loadCache() {
    const sch = `{${schemas.join(",")}}`;
    const rels = await pool.query(
      `select n.nspname, c.relname, c.relkind::text, c.oid::bigint
         from pg_class c join pg_namespace n on n.oid = c.relnamespace
        where n.nspname = any($1::text[]) and c.relkind in ('r','v','m','p','f')`,
      [sch]
    );
    const cols = await pool.query(
      `select n.nspname, c.relname, a.attname, format_type(a.atttypid, a.atttypmod), a.attnotnull::text, a.atthasdef::text, a.attgenerated::text, a.attnum::text
         from pg_attribute a join pg_class c on c.oid = a.attrelid join pg_namespace n on n.oid = c.relnamespace
        where n.nspname = any($1::text[]) and c.relkind in ('r','v','m','p','f') and a.attnum > 0 and not a.attisdropped
        order by n.nspname, c.relname, a.attnum`,
      [sch]
    );
    const pks = await pool.query(
      `select n.nspname, c.relname, (select array_agg(a.attname order by k.ord) from unnest(i.indkey) with ordinality k(attnum, ord) join pg_attribute a on a.attrelid = c.oid and a.attnum = k.attnum)::text
         from pg_index i join pg_class c on c.oid = i.indrelid join pg_namespace n on n.oid = c.relnamespace
        where i.indisprimary and n.nspname = any($1::text[])`,
      [sch]
    );
    const uniques = await pool.query(
      `select n.nspname, c.relname, (select array_agg(a.attname order by k.ord) from unnest(i.indkey) with ordinality k(attnum, ord) join pg_attribute a on a.attrelid = c.oid and a.attnum = k.attnum)::text
         from pg_index i join pg_class c on c.oid = i.indrelid join pg_namespace n on n.oid = c.relnamespace
        where i.indisunique and i.indpred is null and n.nspname = any($1::text[])`,
      [sch]
    );
    const fks = await pool.query(
      `select con.conname, n.nspname, c.relname,
              (select array_agg(a.attname order by k.ord) from unnest(con.conkey) with ordinality k(attnum, ord) join pg_attribute a on a.attrelid = con.conrelid and a.attnum = k.attnum)::text,
              fn.nspname, fc.relname,
              (select array_agg(a.attname order by k.ord) from unnest(con.confkey) with ordinality k(attnum, ord) join pg_attribute a on a.attrelid = con.confrelid and a.attnum = k.attnum)::text
         from pg_constraint con
         join pg_class c on c.oid = con.conrelid join pg_namespace n on n.oid = c.relnamespace
         join pg_class fc on fc.oid = con.confrelid join pg_namespace fn on fn.oid = fc.relnamespace
        where con.contype = 'f' and n.nspname = any($1::text[])`,
      [sch]
    );
    const fns = await pool.query(
      `select n.nspname, p.proname, p.pronargs::text, p.pronargdefaults::text, p.proretset::text, rt.typname, rt.typtype::text, p.provolatile::text,
              (select coalesce(json_agg(json_build_object('name', coalesce(p.proargnames[u.ord], ''), 'type', format_type(u.t, null)) order by u.ord), '[]'::json)
                 from unnest(string_to_array(p.proargtypes::text, ' ')::oid[]) with ordinality as u(t, ord) where p.pronargs > 0)::text
         from pg_proc p join pg_namespace n on n.oid = p.pronamespace join pg_type rt on rt.oid = p.prorettype
        where n.nspname = any($1::text[]) and p.prokind = 'f'`,
      [sch]
    );
    const pgArray = (text) => (text ? text.replace(/^\{|\}$/g, "").split(",").map((s) => s.replace(/^"|"$/g, "")) : []);
    const relations = new Map();
    for (const [schema, name, kind] of rels.rows) {
      relations.set(`${schema}.${name}`, { schema, name, kind, columns: new Map(), pk: [], uniques: [], fks: [] });
    }
    for (const [schema, rel, name, type, notnull, hasdef, gen, num] of cols.rows) {
      relations.get(`${schema}.${rel}`)?.columns.set(name, { name, type, notnull: notnull === "true", hasDefault: hasdef === "true", generated: gen !== "", num: Number(num) });
    }
    for (const [schema, rel, arr] of pks.rows) {
      const r = relations.get(`${schema}.${rel}`);
      if (r) r.pk = pgArray(arr);
    }
    for (const [schema, rel, arr] of uniques.rows) relations.get(`${schema}.${rel}`)?.uniques.push(pgArray(arr));
    for (const [conname, schema, rel, cols1, fschema, frel, cols2] of fks.rows) {
      const fk = { name: conname, from: `${schema}.${rel}`, fromCols: pgArray(cols1), to: `${fschema}.${frel}`, toCols: pgArray(cols2) };
      relations.get(`${schema}.${rel}`)?.fks.push(fk);
    }
    const functions = new Map();
    for (const [schema, name, nargs, ndefaults, retset, rettype, typtype, volatility, args] of fns.rows) {
      const key = `${schema}.${name}`;
      if (!functions.has(key)) functions.set(key, []);
      functions.get(key).push({
        schema, name, nargs: Number(nargs), ndefaults: Number(ndefaults), retset: retset === "true", rettype, typtype, volatility,
        args: JSON.parse(args ?? "[]"),
      });
    }
    // Reverse foreign keys, so the "other side" can be found.
    const allFks = [...relations.values()].flatMap((r) => r.fks);
    cache = { relations, functions, fks: allFks };
    cacheAt = Date.now();
  }

  async function schemaCache(force = false) {
    if (!cache || force || Date.now() - cacheAt > 30_000) await loadCache();
    return cache;
  }

  // Resolves how embed `name` hangs off `parentKey`; returns { cardinality, join(childAlias, parentAlias), target, targetKey }.
  function resolveEmbed(sc, parentKey, node) {
    const parent = sc.relations.get(parentKey);
    const schema = parentKey.split(".")[0];
    const targetKey = `${schema}.${node.name}`;
    const candidates = [];
    const isUnique = (rel, cols) => rel.pk.length && rel.pk.length === cols.length && rel.pk.every((c) => cols.includes(c)) ||
      rel.uniques.some((u) => u.length === cols.length && u.every((c) => cols.includes(c)));
    const target = sc.relations.get(targetKey);
    if (target) {
      // many-to-one: parent holds the FK
      for (const fk of parent.fks.filter((f) => f.to === targetKey)) candidates.push({ fk, dir: "m2o" });
      // one-to-many (or one-to-one): the target holds an FK to the parent
      for (const fk of target.fks.filter((f) => f.to === parentKey)) {
        candidates.push({ fk, dir: isUnique(target, fk.fromCols) ? "o2o" : "o2m" });
      }
    }
    // A foreign-key column name or constraint name can stand for the target (`author_id`, `fk_name`).
    if (!target || node.hint) {
      for (const fk of parent.fks) {
        if (fk.name === node.name || fk.fromCols.includes(node.name)) candidates.push({ fk, dir: "m2o", viaColumn: true });
      }
    }
    let picked = candidates;
    if (node.hint) {
      const h = node.hint;
      picked = candidates.filter((c) => c.fk.name === h || c.fk.fromCols.includes(h) || c.fk.toCols.includes(h) || c.fk.to.endsWith(`.${h}`) || c.fk.from.endsWith(`.${h}`));
    }
    if (picked.length === 0) {
      throw new RestError(400, "PGRST200", `Could not find a relationship between '${parentKey.split(".")[1]}' and '${node.name}' in the schema cache`, `Searched for a foreign key relationship between '${parentKey.split(".")[1]}' and '${node.name}' in the schema 'public', but no matches were found.`, null);
    }
    if (picked.length > 1) {
      throw new RestError(300, "PGRST201", `Could not embed because more than one relationship was found for '${parentKey.split(".")[1]}' and '${node.name}'`, null, "Try changing '" + node.name + "' to one of the following: " + picked.map((p) => `'${node.name}!${p.fk.name}'`).join(", ") + ". Find the desired relationship in the 'details' key.");
    }
    const { fk, dir } = picked[0];
    const tkey = dir === "m2o" ? fk.to : fk.from;
    const tgt = sc.relations.get(tkey);
    const qualified = `${ident(tgt.schema)}.${ident(tgt.name)}`;
    const join = (childAlias, parentAlias) => {
      const pairs = fk.fromCols.map((c, i) => [c, fk.toCols[i]]);
      return pairs
        .map(([from, to]) => (dir === "m2o"
          ? `${ident(childAlias)}.${ident(to)} = ${ident(parentAlias)}.${ident(from)}`
          : `${ident(childAlias)}.${ident(from)} = ${ident(parentAlias)}.${ident(to)}`))
        .join(" AND ");
    };
    return { cardinality: dir === "o2m" ? "many" : "one", join, target: qualified, targetKey: tkey };
  }

  /** Builds the select list (and join-filter predicates for !inner) for a relation. */
  function buildSelect(sc, relKey, alias, nodes, ctx, path) {
    const rel = sc.relations.get(relKey);
    const items = [];
    const inner = [];
    const nodesOrStar = nodes.length ? nodes : [{ kind: "star" }];
    for (const n of nodesOrStar) {
      if (n.kind === "star") { items.push(`${ident(alias)}.*`); continue; }
      if (n.kind === "col") {
        const { column, steps } = parseColumnPath(n.text);
        let expr = columnSql(n.text, alias);
        if (n.cast) expr = `(${expr})::${n.cast}`;
        const outName = n.alias ?? (steps.length ? steps[steps.length - 1].key : column);
        items.push(n.cast || steps.length || n.alias ? `${expr} AS ${ident(outName)}` : expr);
        continue;
      }
      // embed
      const link = resolveEmbed(sc, relKey, n);
      const childAlias = `_r${++ctx.counter}`;
      const params = ctx.embedParams.get([...path, n.alias ?? n.name].join(".")) ?? ctx.embedParams.get([...path, n.name].join(".")) ?? { filters: [], order: null, limit: null, offset: null };
      const child = buildSelect(sc, link.targetKey, childAlias, n.children, ctx, [...path, n.alias ?? n.name]);
      const where = [link.join(childAlias, alias), ...params.filters.map((f) => filterSql(f, childAlias, ctx.P))];
      const order = params.order ? ` ORDER BY ${orderSql(params.order, childAlias, relationInfo(sc, link.targetKey))}` : "";
      const limit = `${params.limit != null ? ` LIMIT ${params.limit | 0}` : ""}${params.offset != null ? ` OFFSET ${params.offset | 0}` : ""}`;
      const inside = `SELECT ${child.items.join(", ")} FROM ${link.target} AS ${ident(childAlias)} WHERE ${where.join(" AND ")}${order}${limit}`;
      if (n.spread) throw new RestError(400, "PGRST100", "Spread (...) embeds are not supported by this stand-in", null, null);
      if (link.cardinality === "one") {
        items.push(`(SELECT row_to_json(${ident("_e" + childAlias)}) FROM (${inside}) AS ${ident("_e" + childAlias)}) AS ${ident(n.alias)}`);
      } else {
        items.push(`(SELECT coalesce(json_agg(${ident("_e" + childAlias)}), '[]'::json) FROM (${inside}) AS ${ident("_e" + childAlias)}) AS ${ident(n.alias)}`);
      }
      if (n.join === "inner") {
        const existsWhere = [link.join(childAlias + "x", alias), ...params.filters.map((f) => filterSql(f, childAlias + "x", ctx.P))];
        inner.push(`EXISTS (SELECT 1 FROM ${link.target} AS ${ident(childAlias + "x")} WHERE ${existsWhere.join(" AND ")})`);
      }
      for (const i of child.inner) inner.push(i); // nested !inner only constrains its own level in PostgREST; kept simple
    }
    void rel;
    return { items, inner };
  }

  function relationInfo(sc, relKey) {
    // Which embeds are to-one, for `order=rel(col)`.
    const rel = sc.relations.get(relKey);
    const toOne = new Map();
    for (const fk of rel.fks) {
      const tgt = sc.relations.get(fk.to);
      if (!tgt) continue;
      toOne.set(tgt.name, {
        target: `${ident(tgt.schema)}.${ident(tgt.name)}`,
        join: (childAlias, parentAlias) => fk.fromCols.map((c, i) => `${ident(childAlias)}.${ident(fk.toCols[i])} = ${ident(parentAlias)}.${ident(c)}`).join(" AND "),
      });
    }
    return { toOne };
  }

  // ── request → SQL ────────────────────────────────────────────────────────

  function parsePrefer(headerValue) {
    const out = {};
    for (const part of String(headerValue ?? "").split(",")) {
      const [k, v] = part.trim().split("=");
      if (k) out[k.trim()] = (v ?? "true").trim();
    }
    return out;
  }

  function parseBody(raw, contentType) {
    if (!raw || raw.length === 0) return null;
    const text = raw.toString("utf8");
    if (/json/i.test(contentType ?? "") || /^\s*[{[]/.test(text)) {
      try {
        return JSON.parse(text);
      } catch (e) {
        throw new RestError(400, "PGRST102", "Empty or invalid json", null, null);
      }
    }
    if (/x-www-form-urlencoded/i.test(contentType ?? "")) return Object.fromEntries(new URLSearchParams(text));
    throw new RestError(400, "PGRST102", "Empty or invalid json", null, null);
  }

  async function plan(ctx) {
    const { method, name, isRpc, url, headers, body: raw } = ctx;
    const sc = await schemaCache();
    const prefer = parsePrefer(headers["prefer"]);
    const accept = headers["accept"] ?? "application/json";
    const singular = /application\/vnd\.pgrst\.object\+json/.test(accept);
    const schemaName = (method === "GET" || method === "HEAD" ? headers["accept-profile"] : headers["content-profile"]) ?? schemas[0];
    if (!schemas.includes(schemaName)) {
      throw new RestError(406, "PGRST106", `The schema must be one of the following: ${schemas.join(", ")}`, null, null);
    }
    const sp = url.searchParams;
    const P = new Params();

    // The source relation (a table, or a function call used as a relation).
    let relKey;
    let fromSql;
    let fnInfo = null;
    let body = null;
    if (isRpc) {
      fnInfo = await resolveFunction(sc, schemaName, name, method, sp, parseBody(raw, headers["content-type"]), P);
      relKey = null;
    } else {
      relKey = `${schemaName}.${name}`;
      if (!sc.relations.has(relKey)) {
        const fresh = await schemaCache(true);
        if (!fresh.relations.has(relKey)) {
          throw new RestError(404, "PGRST205", `Could not find the table '${schemaName}.${name}' in the schema cache`, null, null);
        }
      }
      body = method === "POST" || method === "PATCH" || method === "PUT" ? parseBody(raw, headers["content-type"]) : null;
    }
    const sc2 = cache;
    const rel = relKey ? sc2.relations.get(relKey) : null;

    const selectText = sp.get("select");
    const selectNodes = selectText ? parseSelect(selectText) : [];
    // Embed params are keyed by their path (alias or name).
    const embedNames = new Set();
    const walk = (nodes, prefix) => nodes.forEach((n) => {
      if (n.kind === "embed") { embedNames.add([...prefix, n.alias].join(".")); embedNames.add([...prefix, n.name].join(".")); walk(n.children, [...prefix, n.alias]); }
    });
    walk(selectNodes, []);
    const { root, embeds } = collectParams(sp, embedNames);
    const baseAlias = isRpc ? name : rel.name;
    const ctx2 = { counter: 0, P, embedParams: embeds };

    const whereParts = root.filters.map((f) => filterSql(f, baseAlias, P));
    return { sc: sc2, rel, relKey, fnInfo, body, prefer, singular, P, root, selectNodes, ctx2, baseAlias, whereParts, name, schemaName, sp };
  }

  async function resolveFunction(sc, schemaName, name, method, sp, body, P) {
    const overloads = sc.functions.get(`${schemaName}.${name}`);
    const supplied = method === "GET" || method === "HEAD"
      ? Object.fromEntries([...sp.entries()].filter(([k]) => !RESERVED.has(k)))
      : (body && typeof body === "object" && !Array.isArray(body) ? body : {});
    if (!overloads) {
      const fresh = await schemaCache(true);
      if (!fresh.functions.has(`${schemaName}.${name}`)) {
        throw new RestError(404, "PGRST202", `Could not find the function ${schemaName}.${name}(${Object.keys(supplied).join(", ")}) in the schema cache`,
          `Searched for the function ${schemaName}.${name} with parameter names ${Object.keys(supplied).join(", ")}, or with a single unnamed json/jsonb parameter, but no matches were found in the schema cache.`, null);
      }
      return resolveFunction(fresh, schemaName, name, method, sp, body, P);
    }
    const keys = Object.keys(supplied);
    const candidates = overloads.filter((f) => {
      const names = f.args.map((a) => a.name);
      const required = names.slice(0, f.nargs - f.ndefaults);
      return keys.every((k) => names.includes(k) || (method === "GET" && RESERVED.has(k))) && required.every((r) => keys.includes(r));
    });
    // A function with one json/jsonb parameter takes the whole body when no key matches by name.
    let f = candidates[0];
    let whole = false;
    if (!f) {
      const single = overloads.find((o) => o.nargs === 1 && /^jsonb?$/.test(o.args[0].type) && (o.args[0].name === "" || !keys.includes(o.args[0].name)));
      if (single && (method === "POST")) { f = single; whole = true; }
    }
    if (!f) {
      throw new RestError(404, "PGRST202", `Could not find the function ${schemaName}.${name}(${keys.join(", ")}) in the schema cache`,
        `Searched for the function ${schemaName}.${name} with parameter names ${keys.join(", ")}, or with a single unnamed json/jsonb parameter, but no matches were found in the schema cache.`,
        overloads.length ? `Perhaps you meant to call the function ${schemaName}.${name}(${overloads[0].args.map((a) => a.name).join(", ")})` : null);
    }
    let argsJson;
    let defs;
    if (whole) {
      argsJson = JSON.stringify(body);
      defs = null;
    } else {
      const given = f.args.filter((a) => keys.includes(a.name));
      const out = {};
      for (const a of given) out[a.name] = supplied[a.name];
      // GET passes strings: json_to_record casts them to the declared type.
      argsJson = JSON.stringify(out);
      defs = given;
    }
    const qualified = `${ident(f.schema)}.${ident(f.name)}`;
    let call;
    let fromSql;
    if (whole) {
      call = `${qualified}(${P.add(argsJson)}::${f.args[0].type})`;
      fromSql = null;
    } else if (defs.length) {
      const record = `json_to_record(${P.add(argsJson)}::json) AS _args(${defs.map((a) => `${ident(a.name)} ${a.type}`).join(", ")})`;
      call = `${qualified}(${defs.map((a) => `${ident(a.name)} := _args.${ident(a.name)}`).join(", ")})`;
      fromSql = record;
    } else {
      call = `${qualified}()`;
      fromSql = null;
    }
    return { f, call, argsFrom: fromSql, readonly: f.volatility !== "v" };
  }

  async function execute(role, claims, req, p, method) {
    const ctx = p.ctx2;
    const P = p.P;
    const prefer = p.prefer;
    const countMode = prefer.count; // exact | planned | estimated
    const wantRep = prefer.return === "representation";
    const wantHeaders = prefer.return === "headers-only";
    let sql;
    let kind = "read";

    // Range header → offset / limit.
    let limit = p.root.limit;
    let offset = p.root.offset;
    const rangeHeader = req.headers["range"];
    if (rangeHeader && (method === "GET" || method === "HEAD")) {
      const m = String(rangeHeader).match(/^(\d+)-(\d*)$/);
      if (m) {
        offset = Number(m[1]);
        if (m[2] !== "") limit = Number(m[2]) - offset + 1;
      }
    }
    const orderBy = p.root.order ? orderSql(p.root.order, p.baseAlias, p.rel ? relationInfo(p.sc, p.relKey) : null) : "";
    const limitSql = `${limit != null ? ` LIMIT ${limit | 0}` : ""}${offset ? ` OFFSET ${offset | 0}` : ""}`;

    if (p.fnInfo) {
      // The function is a relation: SELECT over its result.
      const fi = p.fnInfo;
      const f = fi.f;
      const isTableLike = f.retset && (f.typtype === "c" || f.rettype === "record");
      const isVoid = f.rettype === "void";
      let source;
      if (fi.argsFrom) source = isTableLike ? `${fi.argsFrom}, LATERAL ${fi.call} AS ${ident(p.name)}` : `${fi.argsFrom}`;
      else source = isTableLike ? `${fi.call} AS ${ident(p.name)}` : null;
      const where = p.whereParts.length ? ` WHERE ${p.whereParts.join(" AND ")}` : "";
      const projection = isTableLike ? p.selectNodes : [];
      let cols = `${ident(p.name)}.*`;
      if (isTableLike) {
        // select list over the function's columns; embeds are not supported on functions
        const items = (projection.length ? projection : [{ kind: "star" }]).map((n) => {
          if (n.kind === "star") return `${ident(p.name)}.*`;
          if (n.kind === "col") {
            const expr = columnSql(n.text, p.name);
            return n.alias || n.cast ? `${n.cast ? `(${expr})::${n.cast}` : expr} AS ${ident(n.alias ?? parseColumnPath(n.text).column)}` : expr;
          }
          throw new RestError(400, "PGRST200", "Embedding is not supported on function results here");
        });
        cols = items.join(", ");
      }
      let rowsSql;
      let scalar = false;
      if (isVoid) {
        sql = `SELECT ${fi.call.replace(/^/, "")} AS _v${fi.argsFrom ? ` FROM ${fi.argsFrom}` : ""}`;
        // A void function: run it, answer 204.
        return { sql: `SELECT 0::bigint AS total, 0::bigint AS page, 'null'::text AS body, (SELECT 1 FROM (${sql}) _x) AS _run`, kind: "void", expectRows: false };
      }
      if (isTableLike) {
        rowsSql = `SELECT ${cols} FROM ${source}${where}${orderBy ? ` ORDER BY ${orderBy}` : ""}${limitSql}`;
        const countSql = countMode ? `(SELECT count(*) FROM (SELECT 1 FROM ${source}${where}) _c)` : "NULL::bigint";
        sql = `SELECT ${countSql} AS total, count(_t) AS page, coalesce(json_agg(_t), '[]'::json)::text AS body FROM (${rowsSql}) _t`;
      } else if (f.retset) {
        // setof scalar
        const from = fi.argsFrom ? `${fi.argsFrom}, LATERAL ${fi.call} AS _s(v)` : `${fi.call} AS _s(v)`;
        sql = `SELECT NULL::bigint AS total, count(v) AS page, coalesce(json_agg(v), '[]'::json)::text AS body FROM (SELECT v FROM ${from}${limitSql}) _t`;
      } else {
        scalar = true;
        const from = fi.argsFrom ? ` FROM ${fi.argsFrom}` : "";
        sql = `SELECT NULL::bigint AS total, 1::bigint AS page, coalesce(to_json(v), 'null'::json)::text AS body FROM (SELECT ${fi.call} AS v${from}) _t`;
        if (f.typtype === "c" || f.rettype === "record" || f.typtype === "p") {
          sql = `SELECT NULL::bigint AS total, 1::bigint AS page, coalesce(to_json(v), 'null'::json)::text AS body FROM (SELECT ${fi.call} AS v${from}) _t`;
        }
      }
      return { sql, kind: scalar ? "scalar" : "read", expectRows: true, fn: true };
    }

    const rel = p.rel;
    const qualified = `${ident(rel.schema)}.${ident(rel.name)}`;
    const baseAlias = p.baseAlias;

    if (method === "GET" || method === "HEAD") {
      const sel = buildSelect(p.sc, p.relKey, baseAlias, p.selectNodes, ctx, []);
      const where = [...p.whereParts, ...sel.inner];
      const whereSql = where.length ? ` WHERE ${where.join(" AND ")}` : "";
      const rowsSql = `SELECT ${sel.items.join(", ")} FROM ${qualified} AS ${ident(baseAlias)}${whereSql}${orderBy ? ` ORDER BY ${orderBy}` : ""}${limitSql}`;
      const countSql = countMode ? `(SELECT count(*) FROM ${qualified} AS ${ident(baseAlias)}${whereSql})` : "NULL::bigint";
      sql = `SELECT ${countSql} AS total, count(_t) AS page, coalesce(json_agg(_t), '[]'::json)::text AS body FROM (${rowsSql}) _t`;
      return { sql, kind: "read", expectRows: true };
    }

    // ── mutations ───────────────────────────────────────────────────────────
    if (method === "POST") {
      kind = "insert";
      let rows = p.body;
      if (rows === null || rows === undefined) throw new RestError(400, "PGRST102", "Empty or invalid json", null, null);
      if (!Array.isArray(rows)) rows = [rows];
      if (rows.some((r) => r === null || typeof r !== "object" || Array.isArray(r))) throw new RestError(400, "PGRST102", "All object keys must match", null, null);
      let keys = [];
      const columnsParam = p.sp.get("columns");
      if (columnsParam) keys = splitTop(columnsParam).map(unquote);
      else for (const r of rows) for (const k of Object.keys(r)) if (!keys.includes(k)) keys.push(k);
      for (const k of keys) {
        if (!rel.columns.has(k)) throw new RestError(400, "PGRST204", `Could not find the '${k}' column of '${rel.name}' in the schema cache`, null, null);
      }
      const resolution = prefer.resolution;
      let conflict = "";
      if (resolution === "merge-duplicates" || resolution === "ignore-duplicates") {
        const onConflict = p.sp.get("on_conflict");
        const target = onConflict ? splitTop(onConflict).map(unquote) : rel.pk;
        if (!target.length && resolution === "merge-duplicates") throw new RestError(400, "42P10", "there is no unique or exclusion constraint matching the ON CONFLICT specification", null, null);
        const targetSql = target.length ? ` (${target.map(ident).join(", ")})` : "";
        if (resolution === "ignore-duplicates") conflict = ` ON CONFLICT${targetSql} DO NOTHING`;
        else {
          const sets = keys.filter((k) => !target.includes(k) || true).map((k) => `${ident(k)} = EXCLUDED.${ident(k)}`);
          conflict = sets.length ? ` ON CONFLICT${targetSql} DO UPDATE SET ${sets.join(", ")}` : ` ON CONFLICT${targetSql} DO NOTHING`;
        }
      }
      let insertSql;
      const missingDefault = prefer.missing === "default" && rows.some((r) => keys.some((k) => !(k in r)));
      if (keys.length === 0) {
        insertSql = `INSERT INTO ${qualified} AS ${ident(baseAlias)} DEFAULT VALUES${conflict}`;
      } else if (missingDefault) {
        // Absent keys take their column default instead of null.
        const defaults = await columnDefaults(rel);
        const exprs = keys.map((k) => `CASE WHEN _j.obj::jsonb ? ${lit(k)} THEN _b.${ident(k)} ELSE ${defaults.get(k) ?? "NULL"} END`);
        const pj = P.add(JSON.stringify(rows));
        insertSql = `INSERT INTO ${qualified} AS ${ident(baseAlias)} (${keys.map(ident).join(", ")})
          SELECT ${exprs.join(", ")} FROM json_array_elements(${pj}::json) WITH ORDINALITY AS _j(obj, n)
          JOIN json_populate_recordset(null::${qualified}, ${pj}::json) WITH ORDINALITY AS _b ON _b.ordinality = _j.n${conflict}`;
      } else {
        insertSql = `INSERT INTO ${qualified} AS ${ident(baseAlias)} (${keys.map(ident).join(", ")})
          SELECT ${keys.map((k) => `_b.${ident(k)}`).join(", ")} FROM json_populate_recordset(null::${qualified}, ${P.add(JSON.stringify(rows))}::json) AS _b${conflict}`;
      }
      sql = mutationOuter(p, ctx, `${insertSql} RETURNING ${ident(baseAlias)}.*`);
      return { sql, kind, expectRows: true, rowsIn: rows.length };
    }

    if (method === "PATCH") {
      kind = "update";
      const obj = p.body;
      if (obj === null || typeof obj !== "object" || Array.isArray(obj)) throw new RestError(400, "PGRST102", "Empty or invalid json", null, null);
      const keys = Object.keys(obj);
      for (const k of keys) {
        if (!rel.columns.has(k)) throw new RestError(400, "PGRST204", `Could not find the '${k}' column of '${rel.name}' in the schema cache`, null, null);
      }
      const where = p.whereParts.length ? ` WHERE ${p.whereParts.join(" AND ")}` : "";
      let updateSql;
      if (keys.length === 0) {
        updateSql = `SELECT 1`; // nothing to change
        sql = `SELECT ${countMode ? "0::bigint" : "NULL::bigint"} AS total, 0::bigint AS page, '[]'::text AS body`;
        return { sql, kind, expectRows: true };
      }
      updateSql = `UPDATE ${qualified} AS ${ident(baseAlias)} SET ${keys.map((k) => `${ident(k)} = _b.${ident(k)}`).join(", ")}
        FROM (SELECT * FROM json_populate_record(null::${qualified}, ${P.add(JSON.stringify(obj))}::json)) AS _b${where} RETURNING ${ident(baseAlias)}.*`;
      sql = mutationOuter(p, ctx, updateSql);
      return { sql, kind, expectRows: true };
    }

    if (method === "DELETE") {
      kind = "delete";
      const where = p.whereParts.length ? ` WHERE ${p.whereParts.join(" AND ")}` : "";
      const del = `DELETE FROM ${qualified} AS ${ident(baseAlias)}${where} RETURNING ${ident(baseAlias)}.*`;
      sql = mutationOuter(p, ctx, del);
      return { sql, kind, expectRows: true };
    }

    throw new RestError(405, "PGRST117", `Unsupported HTTP method: ${method}`, null, null);
  }

  async function columnDefaults(rel) {
    const r = await pool.query(
      `select a.attname, pg_get_expr(d.adbin, d.adrelid) from pg_attrdef d join pg_attribute a on a.attrelid = d.adrelid and a.attnum = d.adnum where d.adrelid = $1::regclass`,
      [`${ident(rel.schema)}.${ident(rel.name)}`]
    );
    return new Map(r.rows.map(([n, e]) => [n, e]));
  }

  function mutationOuter(p, ctx, mutationSql) {
    const baseAlias = p.baseAlias;
    const sel = buildSelect(p.sc, p.relKey, baseAlias, p.selectNodes, ctx, []);
    return `WITH pgrst_source AS (${mutationSql})
      SELECT ${p.prefer.count ? "(SELECT count(*) FROM pgrst_source)" : "NULL::bigint"} AS total, count(_t) AS page, coalesce(json_agg(_t), '[]'::json)::text AS body
      FROM (SELECT ${sel.items.join(", ")} FROM pgrst_source AS ${ident(baseAlias)}) _t`;
  }

  async function handle(req, res, url, rawBody) {
    const send = (status, headers, body) => {
      res.writeHead(status, headers);
      res.end(req.method === "HEAD" ? undefined : body);
    };
    const cors = {
      "access-control-allow-origin": "*",
      "access-control-expose-headers": "Content-Range, Content-Location, Preference-Applied, Location",
    };
    if (req.method === "OPTIONS") {
      return send(200, { ...cors, "access-control-allow-methods": "GET, POST, PATCH, PUT, DELETE, OPTIONS, HEAD", "access-control-allow-headers": "*", allow: "OPTIONS,GET,HEAD,POST,PATCH,PUT,DELETE" }, "");
    }
    let role = "anon";
    try {
      // Authentication, in the order the gateway and PostgREST apply it.
      const apikey = req.headers["apikey"] ?? url.searchParams.get("apikey");
      const authz = req.headers["authorization"];
      const bearer = authz?.match(/^Bearer\s+(.+)$/i)?.[1]?.trim();
      if (!apikey && !bearer) {
        return send(401, { ...cors, "content-type": "application/json; charset=utf-8" }, JSON.stringify({ message: "No API key found in request", hint: "No `apikey` request header or url param was found." }));
      }
      if (apikey) {
        const chk = verify(apikey, jwtSecret);
        if (chk.error) return send(401, { ...cors, "content-type": "application/json; charset=utf-8" }, JSON.stringify({ message: "Invalid API key", hint: "Double check your Supabase `anon` or `service_role` API key." }));
      }
      const token = bearer ?? apikey;
      const v = verify(token, jwtSecret);
      if (v.error) {
        const message = v.error === "expired" ? "JWT expired" : v.error === "signature" ? "JWSError JWSInvalidSignature" : "Expected 3 parts in JWT; got 1";
        const code = v.error === "expired" ? "PGRST303" : "PGRST301";
        return send(401, { ...cors, "content-type": "application/json; charset=utf-8", "www-authenticate": `Bearer error="invalid_token", error_description="${message}"` }, JSON.stringify({ code, details: null, hint: null, message }));
      }
      const claims = v.claims;
      role = claims.role ?? "anon";
      if (!ROLES.has(role)) {
        return send(401, { ...cors, "content-type": "application/json; charset=utf-8" }, JSON.stringify({ code: "42704", details: null, hint: null, message: `role "${role}" does not exist` }));
      }

      const pathname = url.pathname.replace(/^\/rest\/v1\/?/, "");
      if (pathname === "") {
        return send(200, { ...cors, "content-type": "application/openapi+json; charset=utf-8" }, JSON.stringify({ swagger: "2.0", info: { title: "standard public schema", version: "stand-in" }, paths: {} }));
      }
      const isRpc = pathname.startsWith("rpc/");
      const name = decodeURIComponent(isRpc ? pathname.slice(4) : pathname);
      const method = req.method === "PUT" ? "PUT" : req.method;
      if (method === "PUT") throw new RestError(405, "PGRST105", "Filters must include all and only primary key columns with 'eq' operators", null, null);
      if (isRpc && method !== "POST" && method !== "GET" && method !== "HEAD") throw new RestError(405, "PGRST101", `Only GET and POST verbs are allowed for functions`, null, null);

      const p = await plan({ method, name, isRpc, url, headers: req.headers, body: rawBody });
      const built = await execute(role, claims, req, p, method);

      const exec = await pool.with(async (conn) => {
        await conn.simple("BEGIN");
        try {
          await conn.query("select set_config('role', $1, true), set_config('request.jwt.claims', $2, true), set_config('request.method', $3, true), set_config('request.path', $4, true), set_config('statement_timeout', '20s', true)",
            [role, JSON.stringify(claims), method, url.pathname]);
          const r = await conn.query(built.sql, p.P.values);
          const row = r.rows[0] ?? [];
          // Singular object response: exactly one row, or the transaction is undone.
          if (p.singular && built.kind !== "scalar") {
            const n = Number(row[1] ?? 0);
            if (n !== 1) {
              await conn.simple("ROLLBACK");
              throw new RestError(406, "PGRST116", "JSON object requested, multiple (or no) rows returned", `The result contains ${n} rows`, null);
            }
          }
          if (p.prefer.tx === "rollback") await conn.simple("ROLLBACK");
          else await conn.simple("COMMIT");
          return row;
        } catch (e) {
          if (conn.txStatus !== "I") await conn.simple("ROLLBACK").catch(() => {});
          throw e;
        }
      });

      const total = exec[0] != null ? Number(exec[0]) : null;
      const page = exec[1] != null ? Number(exec[1]) : 0;
      let bodyText = exec[2] ?? "[]";
      const headers = { ...cors, "content-type": `${p.singular ? "application/vnd.pgrst.object+json" : "application/json"}; charset=utf-8` };
      let status = 200;
      const offsetUsed = Number(url.searchParams.get("offset") ?? 0) || 0;
      const rangeText = (from, n) => (n > 0 ? `${from}-${from + n - 1}` : "*");

      if (built.kind === "void") {
        return send(204, headers, "");
      }
      if (built.kind === "scalar") {
        return send(200, headers, bodyText);
      }
      if (built.kind === "read") {
        headers["content-range"] = `${rangeText(offsetUsed, page)}/${total ?? "*"}`;
        if (total !== null && offsetUsed > total) throw new RestError(416, "PGRST103", "Requested range not satisfiable", `An offset of ${offsetUsed} was requested, but there are only ${total} rows.`, null);
        if (total !== null && page < total && !(offsetUsed === 0 && page === 0)) status = 206;
        if (total !== null && page === total) status = 200;
        if (p.singular) bodyText = JSON.stringify(JSON.parse(bodyText)[0]);
        return send(status, headers, bodyText);
      }
      // mutations
      const rep = p.prefer.return;
      if (p.prefer.count) headers["content-range"] = `${rep === "representation" ? rangeText(0, page) : "*"}/${total ?? "*"}`;
      else headers["content-range"] = `${rep === "representation" ? rangeText(0, page) : "*"}/*`;
      if (rep) headers["preference-applied"] = `return=${rep}`;
      if (built.kind === "insert") {
        status = 201;
        if (rep === "headers-only" || rep === "representation") {
          const pk = p.rel.pk;
          if (pk.length) {
            const rows = JSON.parse(bodyText);
            if (rows[0]) headers["location"] = `/${p.name}?${pk.map((c) => `${c}=eq.${rows[0][c]}`).join("&")}`;
          }
        }
        if (rep === "representation") {
          if (p.singular) bodyText = JSON.stringify(JSON.parse(bodyText)[0]);
          return send(201, headers, bodyText);
        }
        delete headers["content-type"];
        return send(201, headers, "");
      }
      if (rep === "representation") {
        if (p.singular) bodyText = JSON.stringify(JSON.parse(bodyText)[0]);
        return send(200, headers, bodyText);
      }
      delete headers["content-type"];
      return send(204, headers, "");
    } catch (e) {
      if (e instanceof RestError) {
        return send(e.status, { ...cors, "content-type": "application/json; charset=utf-8", ...e.headers }, JSON.stringify(e.body()));
      }
      if (e && typeof e.code === "string" && e.name === "PgError") {
        const status = statusForPgError(e, role);
        const headers = { ...cors, "content-type": "application/json; charset=utf-8" };
        if (status === 401) headers["www-authenticate"] = 'Bearer error="invalid_token"';
        log(`pg error ${e.code} ${e.message}`);
        return send(status, headers, JSON.stringify({ code: e.code, details: e.detail, hint: e.hint, message: e.message }));
      }
      log(`internal error: ${e?.stack ?? e}`);
      return send(500, { ...cors, "content-type": "application/json; charset=utf-8" }, JSON.stringify({ code: "PGRST000", details: String(e?.message ?? e), hint: null, message: "Internal stand-in error" }));
    }
  }

  return { handle, refresh: () => schemaCache(true) };
}
