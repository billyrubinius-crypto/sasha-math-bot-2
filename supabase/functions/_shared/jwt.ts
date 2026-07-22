// _shared/jwt.ts — ES256 (P-256) подпись externally minted JWT (T10, SPEC §3.1).
// Приватный ключ — из Edge secret (imported ES256 signing JWK). kid берётся из самого JWK,
// чтобы заголовок всегда совпадал с текущим ключом в JWKS. Приватный ключ наружу не отдаётся.

function b64url(bytes: Uint8Array): string {
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function b64urlJson(obj: unknown): string {
  return b64url(new TextEncoder().encode(JSON.stringify(obj)));
}

export interface SigningKey {
  key: CryptoKey;
  kid: string;
}

function decodeJwkSecret(value: string): string {
  const trimmed = value.trim();
  if (trimmed.startsWith("{")) return trimmed;

  const bytes = Uint8Array.from(atob(trimmed), (char) => char.charCodeAt(0));
  return new TextDecoder().decode(bytes);
}

export async function importSigningKey(jwkSecret: string): Promise<SigningKey> {
  let jwk: JsonWebKey & { kid?: string };
  try {
    jwk = JSON.parse(decodeJwkSecret(jwkSecret));
  } catch {
    throw new Error("invalid_jwk_json");
  }
  if (!jwk.kid) throw new Error("jwk_missing_kid");
  if (jwk.kty !== "EC" || jwk.crv !== "P-256") throw new Error("jwk_not_es256");
  // Supabase CLI exports a combined EC JWK with sign+verify operations. WebCrypto
  // imports the private half for signing only and rejects verify on a private key.
  const privateJwk: JsonWebKey = { ...jwk, key_ops: ["sign"] };
  const key = await crypto.subtle.importKey(
    "jwk",
    privateJwk,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  return { key, kid: jwk.kid };
}

// WebCrypto ECDSA sign отдаёт raw r||s (IEEE P1363, 64 байта) — ровно формат подписи JWS ES256.
export async function signJwtES256(
  signing: SigningKey,
  payload: Record<string, unknown>,
): Promise<string> {
  const header = { alg: "ES256", typ: "JWT", kid: signing.kid };
  const signingInput = `${b64urlJson(header)}.${b64urlJson(payload)}`;
  const sig = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    signing.key,
    new TextEncoder().encode(signingInput),
  );
  return `${signingInput}.${b64url(new Uint8Array(sig))}`;
}

// --- Проверка входящего JWT (T10-09) -----------------------------------------------------------
// Функции, принимающие уже выпущенный нами токен (sign-upload и далее), обязаны проверить подпись
// сами: приватный ключ им не нужен, публичная половина берётся из JWKS проекта по kid заголовка.

const JWKS_URL = Deno.env.get("JWKS_URL") ??
  `${Deno.env.get("SUPABASE_URL") ?? ""}/auth/v1/.well-known/jwks.json`;
const JWKS_TTL_MS = 10 * 60 * 1000; // публичные ключи меняются редко; 10 минут кэша на инстанс

let jwksCache: { at: number; keys: Record<string, CryptoKey> } | null = null;

function b64urlDecode(part: string): Uint8Array {
  const b64 = part.replace(/-/g, "+").replace(/_/g, "/");
  const padded = b64 + "=".repeat((4 - (b64.length % 4)) % 4);
  return Uint8Array.from(atob(padded), (ch) => ch.charCodeAt(0));
}

async function loadJwks(force = false): Promise<Record<string, CryptoKey>> {
  if (!force && jwksCache && Date.now() - jwksCache.at < JWKS_TTL_MS) return jwksCache.keys;
  const res = await fetch(JWKS_URL);
  if (!res.ok) throw new Error("jwks_unavailable");
  const body = await res.json();
  const keys: Record<string, CryptoKey> = {};
  for (const jwk of body?.keys ?? []) {
    if (jwk.kty !== "EC" || jwk.crv !== "P-256" || !jwk.kid) continue;
    const publicJwk: JsonWebKey = { kty: jwk.kty, crv: jwk.crv, x: jwk.x, y: jwk.y, key_ops: ["verify"] };
    keys[jwk.kid] = await crypto.subtle.importKey(
      "jwk",
      publicJwk,
      { name: "ECDSA", namedCurve: "P-256" },
      false,
      ["verify"],
    );
  }
  jwksCache = { at: Date.now(), keys };
  return keys;
}

export interface VerifiedClaims {
  sub: string;
  app_role: "student" | "teacher";
  telegram_id?: string;
  teacher_id?: string;
  token_version?: number;
  exp: number;
  [k: string]: unknown;
}

export interface VerifyOptions {
  issuer?: string;
  audience?: string;
  clockSkewSec?: number;
  now?: number; // секунды; только для тестов
}

// Бросает Error с машинным кодом при любом расхождении. Токен наружу/в лог не попадает.
export async function verifyJwtES256(token: string, opts: VerifyOptions = {}): Promise<VerifiedClaims> {
  const parts = token.split(".");
  if (parts.length !== 3) throw new Error("bad_token");

  let header: { alg?: string; kid?: string };
  let claims: VerifiedClaims;
  try {
    header = JSON.parse(new TextDecoder().decode(b64urlDecode(parts[0])));
    claims = JSON.parse(new TextDecoder().decode(b64urlDecode(parts[1])));
  } catch {
    throw new Error("bad_token");
  }
  if (header.alg !== "ES256" || !header.kid) throw new Error("bad_token");

  let keys = await loadJwks();
  if (!keys[header.kid]) keys = await loadJwks(true); // ротация ключа — один повторный забор JWKS
  const key = keys[header.kid];
  if (!key) throw new Error("unknown_kid");

  const ok = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    b64urlDecode(parts[2]),
    new TextEncoder().encode(`${parts[0]}.${parts[1]}`),
  );
  if (!ok) throw new Error("bad_signature");

  assertClaims(claims, opts);
  return claims;
}

// Проверка payload отдельно от криптографии — тестируется без ключей.
export function assertClaims(claims: VerifiedClaims, opts: VerifyOptions = {}): void {
  const skew = opts.clockSkewSec ?? 60;
  const now = opts.now ?? Math.floor(Date.now() / 1000);

  if (typeof claims.exp !== "number" || claims.exp + skew <= now) throw new Error("token_expired");
  if (typeof claims.iat === "number" && claims.iat - skew > now) throw new Error("bad_token");
  if (claims.role !== "authenticated") throw new Error("bad_token");
  if (opts.audience && claims.aud !== opts.audience) throw new Error("bad_token");
  if (opts.issuer && claims.iss !== opts.issuer) throw new Error("bad_token");
  if (claims.app_role !== "student" && claims.app_role !== "teacher") throw new Error("bad_token");
  if (typeof claims.sub !== "string" || claims.sub.length === 0) throw new Error("bad_token");
  if (claims.app_role === "student" && !/^\d+$/.test(String(claims.telegram_id ?? ""))) {
    throw new Error("bad_token");
  }
}

export const _internal = { b64url, b64urlJson, b64urlDecode };
