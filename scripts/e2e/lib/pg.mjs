// A small PostgreSQL client over the wire protocol (v3), built on node:net only,
// so the local stack needs nothing installed. Trust / cleartext / md5 auth,
// simple and extended queries (text format), and a connection pool.
//
// Every value comes back as text (or null); callers ask Postgres to produce JSON
// for anything structured, exactly as PostgREST does.

import net from "node:net";
import crypto from "node:crypto";

export class PgError extends Error {
  constructor(fields) {
    super(fields.M ?? "postgres error");
    this.name = "PgError";
    this.severity = fields.S;
    this.code = fields.C ?? "XX000";
    this.detail = fields.D ?? null;
    this.hint = fields.H ?? null;
    this.position = fields.P ?? null;
    this.schema = fields.s ?? null;
    this.table = fields.t ?? null;
    this.column = fields.c ?? null;
    this.constraint = fields.n ?? null;
  }
}

function cstr(s) {
  return Buffer.concat([Buffer.from(String(s), "utf8"), Buffer.from([0])]);
}

function i32(n) {
  const b = Buffer.alloc(4);
  b.writeInt32BE(n);
  return b;
}

function i16(n) {
  const b = Buffer.alloc(2);
  b.writeInt16BE(n);
  return b;
}

function message(type, body) {
  return Buffer.concat([Buffer.from(type, "latin1"), i32(body.length + 4), body]);
}

export class PgConn {
  constructor(opts) {
    this.opts = opts;
    this.buf = Buffer.alloc(0);
    this.waiter = null;
    this.queue = [];
    this.closed = false;
    this.params = {};
    this.txStatus = "I";
  }

  async connect() {
    const { socketPath, host, port, user, database } = this.opts;
    this.sock = socketPath ? net.connect({ path: socketPath }) : net.connect({ host, port });
    this.sock.on("data", (d) => {
      this.buf = this.buf.length ? Buffer.concat([this.buf, d]) : d;
      this.pump();
    });
    this.sock.on("error", (e) => this.fail(e));
    this.sock.on("close", () => this.fail(new Error("connection closed")));
    await new Promise((resolve, reject) => {
      this.sock.once("connect", resolve);
      this.sock.once("error", reject);
    });
    const body = Buffer.concat([i32(196608), cstr("user"), cstr(user), cstr("database"), cstr(database), cstr("client_encoding"), cstr("UTF8"), Buffer.from([0])]);
    this.sock.write(Buffer.concat([i32(body.length + 4), body]));
    // Read until ReadyForQuery.
    for (;;) {
      const m = await this.next();
      if (m.type === "R") {
        const kind = m.body.readInt32BE(0);
        if (kind === 0) continue;
        if (kind === 3) {
          this.sock.write(message("p", cstr(this.opts.password ?? "")));
          continue;
        }
        if (kind === 5) {
          const salt = m.body.subarray(4, 8);
          const inner = crypto.createHash("md5").update((this.opts.password ?? "") + this.opts.user).digest("hex");
          const pw = "md5" + crypto.createHash("md5").update(Buffer.concat([Buffer.from(inner), salt])).digest("hex");
          this.sock.write(message("p", cstr(pw)));
          continue;
        }
        throw new Error(`unsupported auth method ${kind}`);
      } else if (m.type === "S") {
        const [k, v] = m.body.toString("utf8").split("\0");
        this.params[k] = v;
      } else if (m.type === "E") {
        throw new PgError(parseFields(m.body));
      } else if (m.type === "Z") {
        this.txStatus = String.fromCharCode(m.body[0]);
        return this;
      }
    }
  }

  fail(err) {
    if (this.closed) return;
    this.closed = true;
    this.error = err;
    if (this.waiter) {
      const w = this.waiter;
      this.waiter = null;
      w.reject(err);
    }
  }

  pump() {
    while (this.buf.length >= 5) {
      const len = this.buf.readInt32BE(1);
      if (this.buf.length < len + 1) return;
      const type = String.fromCharCode(this.buf[0]);
      const body = this.buf.subarray(5, len + 1);
      this.buf = this.buf.subarray(len + 1);
      this.queue.push({ type, body });
    }
    if (this.waiter && this.queue.length) {
      const w = this.waiter;
      this.waiter = null;
      w.resolve(this.queue.shift());
    }
  }

  next() {
    if (this.queue.length) return Promise.resolve(this.queue.shift());
    if (this.closed) return Promise.reject(this.error ?? new Error("connection closed"));
    return new Promise((resolve, reject) => {
      this.waiter = { resolve, reject };
    });
  }

  /** Reads messages up to and including ReadyForQuery; returns the result sets. */
  async collect() {
    const results = [];
    let current = { fields: [], rows: [], command: null };
    let error = null;
    for (;;) {
      const m = await this.next();
      switch (m.type) {
        case "T": {
          const n = m.body.readInt16BE(0);
          let o = 2;
          const fields = [];
          for (let i = 0; i < n; i++) {
            const end = m.body.indexOf(0, o);
            const name = m.body.toString("utf8", o, end);
            o = end + 1;
            const oid = m.body.readUInt32BE(o + 6);
            o += 18;
            fields.push({ name, oid });
          }
          current.fields = fields;
          break;
        }
        case "D": {
          const n = m.body.readInt16BE(0);
          let o = 2;
          const row = [];
          for (let i = 0; i < n; i++) {
            const l = m.body.readInt32BE(o);
            o += 4;
            if (l < 0) row.push(null);
            else {
              row.push(m.body.toString("utf8", o, o + l));
              o += l;
            }
          }
          current.rows.push(row);
          break;
        }
        case "C": {
          current.command = m.body.toString("utf8", 0, m.body.length - 1);
          results.push(current);
          current = { fields: [], rows: [], command: null };
          break;
        }
        case "E":
          error = new PgError(parseFields(m.body));
          break;
        case "Z":
          this.txStatus = String.fromCharCode(m.body[0]);
          if (error) throw error;
          return results;
        default:
          break; // ParseComplete, BindComplete, NoData, NoticeResponse, ParameterStatus, EmptyQueryResponse
      }
    }
  }

  /** Simple protocol: may hold several statements; returns one result per statement. */
  async simple(sql) {
    this.sock.write(message("Q", cstr(sql)));
    return this.collect();
  }

  /** Extended protocol with text parameters ($1, $2, ...). Returns one result. */
  async query(sql, params = []) {
    const parts = [];
    parts.push(message("P", Buffer.concat([cstr(""), cstr(sql), i16(0)])));
    const bind = [cstr(""), cstr(""), i16(0), i16(params.length)];
    for (const p of params) {
      if (p === null || p === undefined) bind.push(i32(-1));
      else {
        const b = Buffer.from(String(p), "utf8");
        bind.push(i32(b.length), b);
      }
    }
    bind.push(i16(0)); // result formats: text
    parts.push(message("B", Buffer.concat(bind)));
    parts.push(message("D", Buffer.concat([Buffer.from("P"), cstr("")])));
    parts.push(message("E", Buffer.concat([cstr(""), i32(0)])));
    parts.push(message("S", Buffer.alloc(0)));
    this.sock.write(Buffer.concat(parts));
    const results = await this.collect();
    return results[0] ?? { fields: [], rows: [], command: "" };
  }

  close() {
    if (this.closed) return;
    this.closed = true;
    try {
      this.sock.write(message("X", Buffer.alloc(0)));
      this.sock.end();
    } catch {
      /* already gone */
    }
  }
}

function parseFields(body) {
  const out = {};
  let o = 0;
  while (o < body.length && body[o] !== 0) {
    const code = String.fromCharCode(body[o]);
    const end = body.indexOf(0, o + 1);
    out[code] = body.toString("utf8", o + 1, end);
    o = end + 1;
  }
  return out;
}

export class PgPool {
  constructor(opts, max = 8) {
    this.opts = opts;
    this.max = max;
    this.idle = [];
    this.count = 0;
    this.waiting = [];
  }

  async acquire() {
    while (this.idle.length) {
      const c = this.idle.pop();
      if (!c.closed) return c;
      this.count--;
    }
    if (this.count < this.max) {
      this.count++;
      try {
        return await new PgConn(this.opts).connect();
      } catch (e) {
        this.count--;
        throw e;
      }
    }
    return new Promise((resolve) => this.waiting.push(resolve));
  }

  release(conn) {
    if (conn.closed || conn.txStatus !== "I") {
      // A connection left in a transaction is discarded rather than reused.
      conn.close();
      this.count--;
      const w = this.waiting.shift();
      if (w) this.acquire().then(w);
      return;
    }
    const w = this.waiting.shift();
    if (w) w(conn);
    else this.idle.push(conn);
  }

  async with(fn) {
    const conn = await this.acquire();
    try {
      return await fn(conn);
    } finally {
      this.release(conn);
    }
  }

  async query(sql, params) {
    return this.with((c) => c.query(sql, params));
  }

  async end() {
    for (const c of this.idle) c.close();
    this.idle = [];
  }
}
