// A stand-in for the parts of Supabase Auth (GoTrue) the HyperVault server and
// the iOS Kit use. Users live in the auth.users table of the local database.
//
//   GET    /auth/v1/settings
//   GET    /auth/v1/user                      (Bearer = an access token)
//   POST   /auth/v1/token?grant_type=refresh_token | password
//   POST   /auth/v1/otp                       (email code; always the fixed code below)
//   POST   /auth/v1/verify                    (type=email + the code → a session)
//   POST   /auth/v1/logout
//   DELETE /auth/v1/admin/users/:id           (service role)
//   GET    /auth/v1/admin/users/:id           (service role)
//
// Error bodies follow GoTrue's: { code, error_code, msg }.

import crypto from "node:crypto";
import { sign, verify } from "./jwt.mjs";

export const FIXED_OTP = "424242";

export function createAuthHandler({ pool, jwtSecret, ttlSeconds = 3600, log = () => {} }) {
  const refreshTokens = new Map(); // token -> { userId, used }
  let sessionCounter = 0;

  const json = (res, status, body, headers = {}) => {
    res.writeHead(status, { "content-type": "application/json", "access-control-allow-origin": "*", ...headers });
    res.end(JSON.stringify(body));
  };
  const fail = (res, status, errorCode, msg) => json(res, status, { code: status, error_code: errorCode, msg });

  async function userRow(where, value) {
    const r = await pool.query(
      `select id, email, coalesce(raw_app_meta_data, '{}'::jsonb)::text, coalesce(raw_user_meta_data, '{}'::jsonb)::text,
              email_confirmed_at::text, created_at::text, updated_at::text, last_sign_in_at::text, banned_until::text, deleted_at::text
         from auth.users where ${where} limit 1`,
      [value]
    );
    const row = r.rows[0];
    if (!row) return null;
    const [id, email, app, meta, confirmed, created, updated, lastSignIn, banned, deleted] = row;
    if (deleted) return null;
    return {
      id,
      aud: "authenticated",
      role: "authenticated",
      email,
      email_confirmed_at: confirmed,
      phone: "",
      confirmed_at: confirmed,
      last_sign_in_at: lastSignIn,
      app_metadata: JSON.parse(app),
      user_metadata: JSON.parse(meta),
      identities: [],
      created_at: created,
      updated_at: updated,
      is_anonymous: false,
      _banned: Boolean(banned && new Date(banned) > new Date()),
    };
  }

  function publicUser(u) {
    const { _banned, ...rest } = u;
    return rest;
  }

  function mintAccessToken(user, sessionId, now = Math.floor(Date.now() / 1000)) {
    return sign(
      {
        aud: "authenticated",
        exp: now + ttlSeconds,
        iat: now,
        sub: user.id,
        email: user.email,
        phone: "",
        app_metadata: user.app_metadata,
        user_metadata: user.user_metadata,
        role: "authenticated",
        aal: "aal1",
        amr: [{ method: "otp", timestamp: now }],
        session_id: sessionId,
        is_anonymous: false,
      },
      jwtSecret
    );
  }

  async function newSession(user) {
    const now = Math.floor(Date.now() / 1000);
    const sessionId = crypto.randomUUID();
    const refresh = crypto.randomBytes(9).toString("base64url");
    refreshTokens.set(refresh, { userId: user.id, used: false, sessionId });
    sessionCounter++;
    await pool.query("update auth.users set last_sign_in_at = now() where id = $1", [user.id]);
    return {
      access_token: mintAccessToken(user, sessionId, now),
      token_type: "bearer",
      expires_in: ttlSeconds,
      expires_at: now + ttlSeconds,
      refresh_token: refresh,
      user: publicUser(user),
    };
  }

  async function readBody(req) {
    const chunks = [];
    for await (const c of req) chunks.push(c);
    const text = Buffer.concat(chunks).toString("utf8");
    if (!text) return {};
    try {
      return JSON.parse(text);
    } catch {
      return {};
    }
  }

  function bearer(req) {
    return req.headers["authorization"]?.match(/^Bearer\s+(.+)$/i)?.[1]?.trim() ?? null;
  }

  function badJwt(res, why) {
    const msg = why === "expired" ? "invalid JWT: unable to parse or verify signature, token has invalid claims: token is expired"
      : "invalid JWT: unable to parse or verify signature, signature is invalid";
    return json(res, 401, { code: 401, error_code: "bad_jwt", msg });
  }

  async function handle(req, res, url) {
    const path = url.pathname.replace(/^\/auth\/v1/, "");
    try {
      if (req.method === "OPTIONS") {
        res.writeHead(204, { "access-control-allow-origin": "*", "access-control-allow-headers": "*", "access-control-allow-methods": "GET, POST, PUT, DELETE, OPTIONS" });
        return res.end();
      }
      if (path === "/settings" && req.method === "GET") {
        return json(res, 200, {
          external: { email: true, phone: false, google: true, apple: true, github: false },
          disable_signup: false,
          mailer_autoconfirm: true,
          phone_autoconfirm: false,
          sms_provider: "",
          saml_enabled: false,
        });
      }
      if (path === "/health") return json(res, 200, { name: "GoTrue", description: "stand-in" });

      if (path === "/user" && req.method === "GET") {
        const token = bearer(req);
        if (!token) return json(res, 401, { code: 401, error_code: "no_authorization", msg: "This endpoint requires a Bearer token" });
        const v = verify(token, jwtSecret);
        if (v.error) return badJwt(res, v.error);
        if (!v.claims.sub) return json(res, 401, { code: 401, error_code: "bad_jwt", msg: "invalid claim: missing sub claim" });
        if (v.claims.role === "service_role" || v.claims.role === "anon") {
          // The service key is not a person's token.
          return json(res, 403, { code: 403, error_code: "bad_jwt", msg: "invalid claim: sub claim must be a UUID" });
        }
        const user = await userRow("id = $1::uuid", v.claims.sub).catch(() => null);
        if (!user) return json(res, 403, { code: 403, error_code: "user_not_found", msg: "User from sub claim in JWT does not exist" });
        if (user._banned) return json(res, 403, { code: 403, error_code: "user_banned", msg: "User is banned" });
        return json(res, 200, publicUser(user));
      }

      if (path === "/token" && req.method === "POST") {
        const grant = url.searchParams.get("grant_type");
        const body = await readBody(req);
        if (grant === "refresh_token") {
          const entry = refreshTokens.get(body.refresh_token);
          if (!entry) return fail(res, 400, "refresh_token_not_found", "Invalid Refresh Token: Refresh Token Not Found");
          if (entry.used) return fail(res, 400, "refresh_token_already_used", "Invalid Refresh Token: Already Used");
          entry.used = true;
          const user = await userRow("id = $1::uuid", entry.userId);
          if (!user) return fail(res, 400, "user_not_found", "User from sub claim in JWT does not exist");
          if (user._banned) return fail(res, 400, "user_banned", "User is banned");
          return json(res, 200, await newSession(user));
        }
        if (grant === "password") {
          // Throwaway test users have no password: only the fixed code signs in.
          return fail(res, 400, "invalid_credentials", "Invalid login credentials");
        }
        return fail(res, 400, "unsupported_grant_type", `unsupported grant_type ${grant}`);
      }

      if (path === "/otp" && req.method === "POST") {
        const body = await readBody(req);
        const email = String(body.email ?? "").trim().toLowerCase();
        if (!email.includes("@")) return fail(res, 422, "validation_failed", "Unable to validate email address: invalid format");
        if (body.create_user !== false) {
          await pool.query(
            `insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values (gen_random_uuid(), $1, now(), '{}'::jsonb) on conflict (email) do nothing`,
            [email]
          );
        }
        return json(res, 200, {});
      }

      if (path === "/verify" && req.method === "POST") {
        const body = await readBody(req);
        const email = String(body.email ?? "").trim().toLowerCase();
        if (String(body.token ?? "") !== FIXED_OTP) return fail(res, 403, "otp_expired", "Token has expired or is invalid");
        const user = await userRow("lower(email) = $1", email);
        if (!user) return fail(res, 403, "otp_expired", "Token has expired or is invalid");
        return json(res, 200, await newSession(user));
      }

      if (path === "/logout" && req.method === "POST") {
        const token = bearer(req);
        const v = token ? verify(token, jwtSecret) : { error: "malformed" };
        if (v.error && v.error !== "expired") return badJwt(res, v.error);
        for (const [t, e] of refreshTokens) if (e.sessionId === v.claims.session_id) refreshTokens.delete(t);
        res.writeHead(204, { "access-control-allow-origin": "*" });
        return res.end();
      }

      const admin = path.match(/^\/admin\/users\/([0-9a-f-]{36})$/i);
      if (admin) {
        const token = bearer(req);
        const v = token ? verify(token, jwtSecret) : { error: "malformed" };
        if (v.error || v.claims.role !== "service_role") {
          return json(res, 403, { code: 403, error_code: "not_admin", msg: "User not allowed" });
        }
        if (req.method === "GET") {
          const user = await userRow("id = $1::uuid", admin[1]);
          return user ? json(res, 200, publicUser(user)) : fail(res, 404, "user_not_found", "User not found");
        }
        if (req.method === "DELETE") {
          const r = await pool.query("delete from auth.users where id = $1::uuid returning id", [admin[1]]);
          return r.rows.length ? json(res, 200, {}) : fail(res, 404, "user_not_found", "User not found");
        }
      }

      return json(res, 404, { code: 404, error_code: "not_found", msg: `stand-in: no route ${req.method} ${path}` });
    } catch (e) {
      log(`auth error: ${e?.stack ?? e}`);
      return json(res, 500, { code: 500, error_code: "unexpected_failure", msg: String(e?.message ?? e) });
    }
  }

  return { handle, mintAccessToken, newSession, sessions: () => sessionCounter };
}
