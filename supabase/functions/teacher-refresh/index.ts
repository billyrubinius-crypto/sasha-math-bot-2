// teacher-refresh — ротация refresh-сессии учителя (T10-05, SPEC §3.3).
//
// Принимает { refresh_token }, хеширует его (SHA-256) и через teacher_session_rotate атомарно:
// проверяет валидность/срок/kill-switch, ловит reuse (отзыв всей семьи) и ротирует токен (старый
// закрывается, новый создаётся в той же семье с тем же 12h-дедлайном). При успехе выпускает новый
// 60-минутный JWT и новый refresh-токен. Все отказы — generic 401; audit без токенов.
//
// Refresh-token и hash наружу/в лог не пишутся. Клиент этим ещё НЕ пользуется (переключение — T10-07).

import { corsHeaders, originAllowed } from "../_shared/cors.ts";
import { AuthError, json, safeError, tagAuditLine } from "../_shared/errors.ts";
import { importSigningKey, type SigningKey, signJwtES256 } from "../_shared/jwt.ts";
import { rateLimitHit, securityAudit, teacherSessionRotate } from "../_shared/db.ts";
import { generateRefreshToken, sha256Hex } from "../_shared/tokens.ts";

const PRIVATE_JWK = Deno.env.get("T10_JWT_PRIVATE_JWK") ?? "";
const JWT_ISS = Deno.env.get("JWT_ISS") ?? `${Deno.env.get("SUPABASE_URL") ?? ""}/auth/v1`;

const MAX_BODY_BYTES = 8 * 1024; // 8 KB
const MAX_TOKEN_LEN = 512;
const JWT_TTL_SEC = 60 * 60; // 60 минут
const REFRESH_TTL_SEC = 12 * 60 * 60; // жёсткий дедлайн семьи 12 часов (переносится ротацией)
const REUSE_GRACE_SEC = Number(Deno.env.get("TEACHER_REFRESH_REUSE_GRACE_SEC") ?? "10");
const RL_BUCKET = "teacher_refresh";
const RL_MAX = Number(Deno.env.get("TEACHER_REFRESH_RL_MAX") ?? "120");
const RL_WINDOW_SEC = Number(Deno.env.get("TEACHER_REFRESH_RL_WINDOW_SEC") ?? "300");

let signingKeyPromise: Promise<SigningKey> | null = null;
function getSigningKey(): Promise<SigningKey> {
  if (!PRIVATE_JWK) return Promise.reject(new AuthError("server_misconfigured", 500));
  signingKeyPromise ??= importSigningKey(PRIVATE_JWK);
  return signingKeyPromise;
}

async function ipFingerprint(req: Request): Promise<string> {
  const xff = req.headers.get("x-forwarded-for") ?? "";
  const ip = xff.split(",")[0].trim() || req.headers.get("cf-connecting-ip") || "unknown";
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(ip));
  const bytes = new Uint8Array(digest);
  let hex = "";
  for (const b of bytes) hex += b.toString(16).padStart(2, "0");
  return hex;
}

Deno.serve(async (req: Request): Promise<Response> => {
  const origin = req.headers.get("origin");
  const cors = corsHeaders(origin);

  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405, cors);
  if (!originAllowed(origin)) return json({ error: "origin_not_allowed" }, 403, cors);

  const raw = new Uint8Array(await req.arrayBuffer());
  if (raw.byteLength > MAX_BODY_BYTES) return json({ error: "body_too_large" }, 413, cors);

  let refreshToken: unknown;
  try {
    refreshToken = JSON.parse(new TextDecoder().decode(raw))?.refresh_token;
  } catch {
    return json({ error: "bad_request" }, 400, cors);
  }
  if (typeof refreshToken !== "string" || refreshToken.length === 0 || refreshToken.length > MAX_TOKEN_LEN) {
    return json({ error: "bad_request" }, 400, cors);
  }

  const fp = await ipFingerprint(req);

  // Базовый rate limit против перебора (инкремент на каждый вызов).
  try {
    const allowed = await rateLimitHit(RL_BUCKET, fp, RL_MAX, RL_WINDOW_SEC);
    if (!allowed) return json({ error: "rate_limited" }, 429, cors);
  } catch (_e) {
    return json({ error: "internal_error" }, 500, cors);
  }

  try {
    const oldHash = await sha256Hex(refreshToken);
    // Новый refresh-токен генерируем ДО ротации: в БД пишем только его hash.
    const newToken = generateRefreshToken();
    const newHash = await sha256Hex(newToken);

    const result = await teacherSessionRotate(oldHash, newHash, REUSE_GRACE_SEC);

    if (result.status !== "ok") {
      // reuse => семью уже отозвал rotate; фиксируем redacted-статус, клиенту — generic 401.
      await securityAudit("teacher_refresh_reject", "teacher", result.principal_id ?? null, fp, {
        status: result.status,
      }).catch(() => {});
      console.log(tagAuditLine("teacher-refresh", "rejected", result.status));
      return json({ error: "invalid_token" }, 401, cors);
    }

    const signing = await getSigningKey();
    const nowSec = Math.floor(Date.now() / 1000);
    const jwt = await signJwtES256(signing, {
      role: "authenticated",
      app_role: "teacher",
      sub: result.principal_id,
      teacher_id: result.teacher_id,
      token_version: result.token_version,
      iss: JWT_ISS,
      aud: "authenticated",
      iat: nowSec,
      exp: nowSec + JWT_TTL_SEC,
      jti: crypto.randomUUID(),
    });

    await securityAudit("teacher_refresh_success", "teacher", result.principal_id ?? null, fp, null).catch(() => {});
    console.log(tagAuditLine("teacher-refresh", "issued", "ok"));
    return json({
      access_token: jwt,
      token_type: "bearer",
      expires_in: JWT_TTL_SEC,
      refresh_token: newToken,
      refresh_expires_in: REFRESH_TTL_SEC,
    }, 200, cors);
  } catch (e) {
    const { code, status } = safeError(e);
    console.log(tagAuditLine("teacher-refresh", "error", code)); // без токенов
    return json({ error: code }, status, cors);
  }
});
