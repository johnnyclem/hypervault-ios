// A small stand-in for Supabase Storage: buckets, signed uploads, signed reads,
// listing, info and removal, with the bytes on local disk. Only what the
// HyperVault server's file artifacts (PDFs and images) call.

import fs from "node:fs";
import path from "node:path";
import { sign, verify } from "./jwt.mjs";

export function createStorageHandler({ pool, jwtSecret, dir, baseUrl, log = () => {} }) {
  const root = dir ?? "/tmp/hv-e2e/storage";
  fs.mkdirSync(root, { recursive: true });
  const buckets = new Map();

  const json = (res, status, body) => {
    res.writeHead(status, { "content-type": "application/json", "access-control-allow-origin": "*" });
    res.end(JSON.stringify(body));
  };
  const err = (res, status, error, message) => json(res, status, { statusCode: String(status), error, message });

  const read = async (req) => {
    const chunks = [];
    for await (const c of req) chunks.push(c);
    return Buffer.concat(chunks);
  };

  const fileOf = (bucket, name) => {
    const full = path.join(root, bucket, name);
    if (!full.startsWith(path.join(root, bucket) + path.sep)) throw new Error("bad path");
    return full;
  };

  function requireService(req, res) {
    const token = req.headers["authorization"]?.match(/^Bearer\s+(.+)$/i)?.[1];
    const v = token ? verify(token, jwtSecret) : { error: "malformed" };
    if (v.error || v.claims.role !== "service_role") {
      err(res, 403, "Unauthorized", "new row violates row-level security policy");
      return false;
    }
    return true;
  }

  async function handle(req, res, url) {
    const p = url.pathname.replace(/^\/storage\/v1/, "");
    try {
      if (req.method === "OPTIONS") {
        res.writeHead(204, { "access-control-allow-origin": "*", "access-control-allow-headers": "*", "access-control-allow-methods": "GET, POST, PUT, DELETE, OPTIONS" });
        return res.end();
      }
      // Signed reads and uploads authorise with the token in the URL.
      let m = p.match(/^\/object\/upload\/sign\/([^/]+)\/(.+)$/);
      if (m && req.method === "PUT") {
        const [, bucket, name] = m;
        const v = verify(url.searchParams.get("token"), jwtSecret);
        if (v.error || v.claims.url !== `${bucket}/${decodeURIComponent(name)}` || v.claims.kind !== "upload") return err(res, 403, "Unauthorized", "Invalid token");
        const info = buckets.get(bucket) ?? {};
        const body = await read(req);
        const contentType = req.headers["content-type"] ?? "application/octet-stream";
        if (info.file_size_limit && body.length > info.file_size_limit) return err(res, 413, "Payload too large", "The object exceeded the maximum allowed size");
        if (info.allowed_mime_types?.length && !info.allowed_mime_types.includes(contentType.split(";")[0])) return err(res, 415, "invalid_mime_type", `mime type ${contentType} is not supported`);
        const file = fileOf(bucket, decodeURIComponent(name));
        fs.mkdirSync(path.dirname(file), { recursive: true });
        fs.writeFileSync(file, body);
        fs.writeFileSync(`${file}.meta`, JSON.stringify({ mimetype: contentType.split(";")[0], size: body.length, created: new Date().toISOString() }));
        return json(res, 200, { Key: `${bucket}/${decodeURIComponent(name)}` });
      }
      m = p.match(/^\/object\/sign\/([^/]+)\/(.+)$/);
      if (m && req.method === "GET") {
        const [, bucket, name] = m;
        const v = verify(url.searchParams.get("token"), jwtSecret);
        if (v.error || v.claims.url !== `${bucket}/${decodeURIComponent(name)}`) return err(res, 400, "InvalidJWT", "jwt malformed");
        const file = fileOf(bucket, decodeURIComponent(name));
        if (!fs.existsSync(file)) return err(res, 404, "not_found", "Object not found");
        const meta = JSON.parse(fs.readFileSync(`${file}.meta`, "utf8"));
        res.writeHead(200, { "content-type": meta.mimetype, "content-length": meta.size, "access-control-allow-origin": "*" });
        return res.end(fs.readFileSync(file));
      }

      // Everything else needs the service role.
      if (!requireService(req, res)) return;

      if (p === "/bucket" && req.method === "POST") {
        const b = JSON.parse((await read(req)).toString("utf8"));
        if (buckets.has(b.name ?? b.id)) return err(res, 400, "Duplicate", "The resource already exists");
        buckets.set(b.name ?? b.id, b);
        await pool.query("insert into storage.buckets (id, name, public) values ($1, $1, $2) on conflict do nothing", [b.name ?? b.id, Boolean(b.public)]);
        return json(res, 200, { name: b.name ?? b.id });
      }
      m = p.match(/^\/bucket\/([^/]+)$/);
      if (m && req.method === "PUT") {
        const b = JSON.parse((await read(req)).toString("utf8"));
        buckets.set(m[1], { ...(buckets.get(m[1]) ?? {}), ...b });
        return json(res, 200, { message: "Successfully updated" });
      }
      m = p.match(/^\/object\/upload\/sign\/([^/]+)\/(.+)$/);
      if (m && req.method === "POST") {
        const [, bucket, name] = m;
        const token = sign({ url: `${bucket}/${decodeURIComponent(name)}`, kind: "upload", exp: Math.floor(Date.now() / 1000) + 7200 }, jwtSecret);
        return json(res, 200, { url: `/object/upload/sign/${bucket}/${name}?token=${token}` });
      }
      m = p.match(/^\/object\/sign\/([^/]+)\/(.+)$/);
      if (m && req.method === "POST") {
        const [, bucket, name] = m;
        const body = JSON.parse((await read(req)).toString("utf8") || "{}");
        const token = sign({ url: `${bucket}/${decodeURIComponent(name)}`, kind: "read", exp: Math.floor(Date.now() / 1000) + (body.expiresIn ?? 300) }, jwtSecret);
        return json(res, 200, { signedURL: `/object/sign/${bucket}/${name}?token=${token}` });
      }
      m = p.match(/^\/object\/info\/([^/]+)\/(.+)$/);
      if (m && req.method === "GET") {
        const file = fileOf(m[1], decodeURIComponent(m[2]));
        if (!fs.existsSync(file)) return err(res, 404, "not_found", "Object not found");
        const meta = JSON.parse(fs.readFileSync(`${file}.meta`, "utf8"));
        return json(res, 200, { name: decodeURIComponent(m[2]), size: meta.size, contentType: meta.mimetype, createdAt: meta.created, bucketId: m[1] });
      }
      m = p.match(/^\/object\/list\/([^/]+)$/);
      if (m && req.method === "POST") {
        const body = JSON.parse((await read(req)).toString("utf8") || "{}");
        const prefix = body.prefix ?? "";
        const folder = fileOf(m[1], prefix || "x").replace(/\/x$/, "");
        let names = [];
        try {
          names = fs.readdirSync(folder).filter((n) => !n.endsWith(".meta"));
        } catch { /* empty */ }
        const rows = names.slice(body.offset ?? 0, (body.offset ?? 0) + (body.limit ?? 100)).map((n) => {
          const meta = JSON.parse(fs.readFileSync(path.join(folder, `${n}.meta`), "utf8"));
          return { name: n, id: n, metadata: { size: meta.size, mimetype: meta.mimetype } };
        });
        return json(res, 200, rows);
      }
      m = p.match(/^\/object\/([^/]+)$/);
      if (m && req.method === "DELETE") {
        const body = JSON.parse((await read(req)).toString("utf8") || "{}");
        const removed = [];
        for (const name of body.prefixes ?? []) {
          const file = fileOf(m[1], name);
          for (const f of [file, `${file}.meta`]) fs.rmSync(f, { force: true });
          removed.push({ name, bucket_id: m[1] });
        }
        return json(res, 200, removed);
      }
      return err(res, 404, "not_found", `stand-in storage: no route ${req.method} ${p}`);
    } catch (e) {
      log(`storage error: ${e?.stack ?? e}`);
      return err(res, 500, "internal", String(e?.message ?? e));
    }
  }

  void baseUrl;
  return { handle };
}
