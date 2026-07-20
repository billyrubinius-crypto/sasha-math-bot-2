// _shared/telegram.ts — валидация Telegram Mini Apps initData (T10, SPEC §3.2).
// Контракт: https://core.telegram.org/bots/webapps (Validating data received via the Mini App).
//
// Алгоритм:
//   data_check_string = отсортированные "key=value" (кроме hash), соединённые "\n";
//   secret_key        = HMAC_SHA256(key="WebAppData", message=bot_token);
//   calculated_hash   = HMAC_SHA256(key=secret_key,  message=data_check_string) в hex;
//   сравнение с полученным hash — constant-time.
// Плюс: ровно один hash, возраст auth_date <= 24h, future skew <= 5m, строгий parse user.id.

import { AuthError } from "./errors.ts";

export interface TelegramUser {
  id: number;
  first_name?: string;
  last_name?: string;
  username?: string;
}

export interface ValidatedInitData {
  user: TelegramUser;
  authDate: number;
}

const enc = new TextEncoder();

async function hmacSha256(keyBytes: Uint8Array, message: string): Promise<Uint8Array<ArrayBuffer>> {
  // Копия ключа в свежий ArrayBuffer-backed view: bare Uint8Array (Uint8Array<ArrayBufferLike>)
  // не удовлетворяет BufferSource в TS 5.7+/6.0; new Uint8Array(len) гарантированно <ArrayBuffer>.
  const rawKey = new Uint8Array(keyBytes.byteLength);
  rawKey.set(keyBytes);
  const key = await crypto.subtle.importKey(
    "raw",
    rawKey,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, enc.encode(message));
  return new Uint8Array(sig);
}

function toHex(u: Uint8Array): string {
  let s = "";
  for (const b of u) s += b.toString(16).padStart(2, "0");
  return s;
}

// Constant-time сравнение hex-строк равной длины.
function constantTimeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let r = 0;
  for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return r === 0;
}

export interface ValidateOpts {
  maxAgeSec: number; // 86400
  futureSkewSec: number; // 300
  now?: number; // для тестов; по умолчанию Date.now()/1000
}

export async function validateInitData(
  initData: string,
  botToken: string,
  opts: ValidateOpts,
): Promise<ValidatedInitData> {
  if (!botToken) throw new AuthError("server_misconfigured", 500);

  const params = new URLSearchParams(initData);

  // ровно один hash
  const hashes = params.getAll("hash");
  if (hashes.length !== 1) throw new AuthError("bad_hash");
  const providedHash = hashes[0];
  if (!/^[0-9a-f]{64}$/i.test(providedHash)) throw new AuthError("bad_hash");

  // data_check_string по всем параметрам кроме hash
  const pairs: string[] = [];
  for (const [k, v] of params) {
    if (k === "hash") continue;
    pairs.push(`${k}=${v}`);
  }
  pairs.sort();
  const dataCheckString = pairs.join("\n");

  const secretKey = await hmacSha256(enc.encode("WebAppData"), botToken);
  const calculated = toHex(await hmacSha256(secretKey, dataCheckString));

  if (!constantTimeEqual(calculated, providedHash.toLowerCase())) {
    throw new AuthError("bad_hash");
  }

  // auth_date
  const authDateRaw = params.get("auth_date");
  const authDate = Number(authDateRaw);
  if (!authDateRaw || !Number.isFinite(authDate) || !Number.isInteger(authDate) || authDate <= 0) {
    throw new AuthError("bad_auth_date");
  }
  const now = opts.now ?? Math.floor(Date.now() / 1000);
  if (now - authDate > opts.maxAgeSec) throw new AuthError("expired_auth_date");
  if (authDate - now > opts.futureSkewSec) throw new AuthError("future_auth_date");

  // user
  const userRaw = params.get("user");
  if (!userRaw) throw new AuthError("missing_user");
  let user: TelegramUser;
  try {
    user = JSON.parse(userRaw);
  } catch {
    throw new AuthError("malformed_user");
  }
  if (
    !user || typeof user.id !== "number" || !Number.isInteger(user.id) ||
    user.id <= 0 || user.id > Number.MAX_SAFE_INTEGER
  ) {
    throw new AuthError("malformed_user");
  }

  return { user, authDate };
}

// Экспортируем внутренние helpers для unit-тестов (создание valid fixture).
export const _internal = { hmacSha256, toHex, constantTimeEqual };
