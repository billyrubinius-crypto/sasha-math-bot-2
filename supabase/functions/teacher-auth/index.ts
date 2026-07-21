// teacher-auth — серверный вход учителя (T10-05, SPEC §3.3), параллельно старому PASS.
//
// Принимает { password }, проверяет его в Edge против hash из secret (PBKDF2, константное время),
// origin allowlist, ограниченный размер тела и gate по НЕУДАЧНЫМ попыткам (5/15m на IP fingerprint).
// При успехе идемпотентно находит/создаёт teacher principal, выпускает 60-минутный ES256 JWT и
// opaque refresh-токен (в БД — только его SHA-256 hash; семья с жёстким дедлайном 12h). Успех/отказ
// пишутся в audit без пароля/hash/токена. Клиент этим ещё НЕ пользуется (переключение — T10-07).
//
// Секреты (TEACHER_PASSWORD_HASH, private JWK, service role) наружу/в лог не попадают.

import { corsHeaders, originAllowed } from "../_shared/cors.ts";
import { AuthError, json, safeError, tagAuditLine } from "../_shared/errors.ts";
import { importSigningKey, type SigningKey, signJwtES256 } from "../_shared/jwt.ts";
import { rateLimitHit, rateLimitPeek, securityAudit, teacherSessionCreate, teacherUpsertPrincipal } from "../_shared/db.ts";
import { verifyPassword } from "../_shared/password.ts";
import { generateRefreshToken, sha256Hex } from "../_shared/tokens.ts";

const PASSWORD_HASH = Deno.env.get("TEACHER_PASSWORD_HASH") ?? "";
const PRIVATE_JWK = Deno.env.get("T10_JWT_PRIVATE_JWK") ?? "";
const JWT_ISS = Deno.env.get("JWT_ISS") ?? `${Deno.env.get("SUPABASE_URL") ?? ""}/auth/v1`;
const TEACHER_ID = Deno.env.get("TEACHER_ID") ?? "primary";

const MAX_BODY_BYTES = 8 * 1024; // 8 KB
const MAX_PASSWORD_LEN = 256;
const JWT_TTL_SEC = 60 * 60; // 60 минут (SPEC §3.3)
const REFRESH_TTL_SEC = 12 * 60 * 60; // жёсткий дедлайн семьи 12 часов (SPEC §3.3)
const RL_BUCKET = "teacher_login";
const RL_MAX = Number(Deno.env.get("TEACHER_LOGIN_RL_MAX") ?? "5"); // 5 неудач
const RL_WINDOW_SEC = Number(Deno.env.get("TEACHER_LOGIN_RL_WINDOW_SEC") ?? "900"); // 15 минут

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

  let password: unknown;
  try {
    password = JSON.parse(new TextDecoder().decode(raw))?.password;
  } catch {
    return json({ error: "bad_request" }, 400, cors);
  }
  if (typeof password !== "string" || password.length === 0 || password.length > MAX_PASSWORD_LEN) {
    return json({ error: "bad_request" }, 400, cors);
  }

  const fp = await ipFingerprint(req);

  // Gate по НЕУДАЧНЫМ попыткам: peek без инкремента; успех лимит не тратит.
  try {
    const allowed = await rateLimitPeek(RL_BUCKET, fp, RL_MAX, RL_WINDOW_SEC);
    if (!allowed) {
      await securityAudit("teacher_login_blocked", "teacher", null, fp, null).catch(() => {});
      return json({ error: "rate_limited" }, 429, cors);
    }
  } catch (_e) {
    return json({ error: "internal_error" }, 500, cors);
  }

  try {
    if (!PASSWORD_HASH) throw new AuthError("server_misconfigured", 500);

    const ok = await verifyPassword(password, PASSWORD_HASH);
    if (!ok) {
      // Инкремент счётчика неудач + audit; клиенту generic-ошибка (не помогаем подбирать).
      await rateLimitHit(RL_BUCKET, fp, RL_MAX, RL_WINDOW_SEC).catch(() => {});
      await securityAudit("teacher_login_failure", "teacher", null, fp, null).catch(() => {});
      console.log(tagAuditLine("teacher-auth", "rejected", "bad_password"));
      return json({ error: "invalid_credentials" }, 401, cors);
    }

    const { principal_id, teacher_token_version } = await teacherUpsertPrincipal(TEACHER_ID);

    // Refresh-семья: opaque токен (в БД только hash), жёсткий дедлайн 12h, снимок kill-switch версии.
    const refreshToken = generateRefreshToken();
    const refreshHash = await sha256Hex(refreshToken);
    const familyId = crypto.randomUUID();
    const nowMs = Date.now();
    const expiresAt = new Date(nowMs + REFRESH_TTL_SEC * 1000).toISOString();
    await teacherSessionCreate(principal_id, familyId, refreshHash, expiresAt, teacher_token_version);

    const signing = await getSigningKey();
    const nowSec = Math.floor(nowMs / 1000);
    const jwt = await signJwtES256(signing, {
      role: "authenticated",
      app_role: "teacher",
      sub: principal_id,
      teacher_id: TEACHER_ID,
      token_version: teacher_token_version,
      iss: JWT_ISS,
      aud: "authenticated",
      iat: nowSec,
      exp: nowSec + JWT_TTL_SEC,
      jti: crypto.randomUUID(),
    });

    await securityAudit("teacher_login_success", "teacher", principal_id, fp, null).catch(() => {});
    console.log(tagAuditLine("teacher-auth", "issued", "ok"));
    return json({
      access_token: jwt,
      token_type: "bearer",
      expires_in: JWT_TTL_SEC,
      refresh_token: refreshToken,
      refresh_expires_in: REFRESH_TTL_SEC,
    }, 200, cors);
  } catch (e) {
    const { code, status } = safeError(e);
    console.log(tagAuditLine("teacher-auth", "error", code)); // без пароля/hash/токенов
    return json({ error: code }, status, cors);
  }
});
