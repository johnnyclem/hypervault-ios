// HS256 JSON Web Tokens with node:crypto, enough for a local Supabase stand-in.

import crypto from "node:crypto";

const b64u = (buf) => Buffer.from(buf).toString("base64url");

export function sign(claims, secret) {
  const header = b64u(JSON.stringify({ alg: "HS256", typ: "JWT" }));
  const payload = b64u(JSON.stringify(claims));
  const sig = crypto.createHmac("sha256", secret).update(`${header}.${payload}`).digest("base64url");
  return `${header}.${payload}.${sig}`;
}

/**
 * Returns { claims } for a good token, or { error: "malformed" | "signature" | "expired" | "alg" }.
 * `now` is in seconds.
 */
export function verify(token, secret, now = Math.floor(Date.now() / 1000)) {
  const parts = String(token ?? "").split(".");
  if (parts.length !== 3) return { error: "malformed" };
  let header;
  let claims;
  try {
    header = JSON.parse(Buffer.from(parts[0], "base64url").toString("utf8"));
    claims = JSON.parse(Buffer.from(parts[1], "base64url").toString("utf8"));
  } catch {
    return { error: "malformed" };
  }
  if (header.alg !== "HS256") return { error: "alg" };
  const expected = crypto.createHmac("sha256", secret).update(`${parts[0]}.${parts[1]}`).digest();
  const given = Buffer.from(parts[2], "base64url");
  if (given.length !== expected.length || !crypto.timingSafeEqual(given, expected)) return { error: "signature" };
  if (typeof claims.exp === "number" && claims.exp <= now) return { error: "expired", claims };
  return { claims };
}
