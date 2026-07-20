// student-auth — параллельный Telegram student-auth Edge Function (T10-02, SPEC §§3.1-3.2).
//
// Принимает { initData } (сырой Telegram.WebApp.initData), проверяет HMAC-SHA256 по правилам
// Telegram (constant-time), возраст auth_date <= 24h и future skew <= 5m, строгий parse user.id,
// origin allowlist, ограниченный размер тела и rate limit по IP fingerprint. При успехе идемпотентно
// находит/создаёт principal + students-строку и выпускает 60-минутный ES256 JWT c текущим kid.
//
// Клиент этим ещё НЕ пользуется (переключение — T10-03); runtime mode остаётся 'legacy'.
// Секреты (BOT_TOKEN, private JWK, service role) наружу/в лог не попадают.

import { corsHeaders, originAllowed } from "../_shared/cors.ts";
import { AuthError, auditLine, json, safeError } from "../_shared/errors.ts";
import { validateInitData } from "../_shared/telegram.ts";
import { importSigningKey, type SigningKey, signJwtES256 } from "../_shared/jwt.ts";
import { rateLimitHit, upsertStudentPrincipal } from "../_shared/db.ts";

const BOT_TOKEN = Deno.env.get("BOT_TOKEN") ?? "";
const PRIVATE_JWK = Deno.env.get("T10_JWT_PRIVATE_JWK") ?? "";
const JWT_ISS = Deno.env.get("JWT_ISS") ?? `${Deno.env.get("SUPABASE_URL") ?? ""}/auth/v1`;

const MAX_BODY_BYTES = 16 * 1024; // 16 KB
const MAX_INITDATA_LEN = 8 * 1024; // 8 KB
const JWT_TTL_SEC = 60 * 60; // 60 минут (SPEC §3.2)
const INITDATA_MAX_AGE_SEC = 24 * 60 * 60; // 24 часа
const INITDATA_FUTURE_SKEW_SEC = 5 * 60; // 5 минут
const RL_BUCKET = "student_auth";
const RL_MAX = Number(Deno.env.get("STUDENT_AUTH_RL_MAX") ?? "60");
const RL_WINDOW_SEC = Number(Deno.env.get("STUDENT_AUTH_RL_WINDOW_SEC") ?? "300");

// Ленивая инициализация signing key (один импорт на инстанс).
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

  // Ограниченное тело
  const raw = new Uint8Array(await req.arrayBuffer());
  if (raw.byteLength > MAX_BODY_BYTES) return json({ error: "body_too_large" }, 413, cors);

  let initData: unknown;
  try {
    initData = JSON.parse(new TextDecoder().decode(raw))?.initData;
  } catch {
    return json({ error: "bad_request" }, 400, cors);
  }
  if (typeof initData !== "string" || initData.length === 0 || initData.length > MAX_INITDATA_LEN) {
    return json({ error: "bad_request" }, 400, cors);
  }

  // Rate limit по IP fingerprint (до крипто-работы)
  const fp = await ipFingerprint(req);
  let allowed = false;
  try {
    allowed = await rateLimitHit(RL_BUCKET, fp, RL_MAX, RL_WINDOW_SEC);
  } catch (_e) {
    return json({ error: "internal_error" }, 500, cors);
  }
  if (!allowed) return json({ error: "rate_limited" }, 429, cors);

  try {
    const { user } = await validateInitData(initData, BOT_TOKEN, {
      maxAgeSec: INITDATA_MAX_AGE_SEC,
      futureSkewSec: INITDATA_FUTURE_SKEW_SEC,
    });

    const { principal_id, token_version } = await upsertStudentPrincipal(user.id);
    const signing = await getSigningKey();

    const nowSec = Math.floor(Date.now() / 1000);
    const jwt = await signJwtES256(signing, {
      role: "authenticated",
      app_role: "student",
      sub: principal_id,
      telegram_id: String(user.id),
      token_version,
      iss: JWT_ISS,
      aud: "authenticated",
      iat: nowSec,
      exp: nowSec + JWT_TTL_SEC,
      jti: crypto.randomUUID(),
    });

    console.log(auditLine("issued", "ok", user.id));
    return json({ access_token: jwt, token_type: "bearer", expires_in: JWT_TTL_SEC }, 200, cors);
  } catch (e) {
    const { code, status } = safeError(e);
    console.log(auditLine("rejected", code)); // без initData/hash/токенов
    return json({ error: code }, status, cors);
  }
});
