// _shared/password.ts — серверная проверка пароля учителя (T10-05, SPEC §3.3).
// В Edge secret лежит СТРОКА-hash (не пароль): pbkdf2$sha256$<iterations>$<saltB64url>$<hashB64url>.
// PBKDF2-HMAC-SHA256 доступен в WebCrypto без внешних зависимостей. Verify — константное по времени
// сравнение выведенного ключа с сохранённым. Пароль/hash наружу и в лог не попадают.

function b64urlToBytes(s: string): Uint8Array {
  const b64 = s.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((s.length + 3) % 4);
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

function bytesToB64url(bytes: Uint8Array): string {
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

// Константное по времени сравнение (равная длина => XOR-аккумулятор).
function timingSafeEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

async function pbkdf2(
  password: string,
  salt: Uint8Array,
  iterations: number,
  dkLenBytes: number,
): Promise<Uint8Array> {
  const keyMaterial = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(password),
    { name: "PBKDF2" },
    false,
    ["deriveBits"],
  );
  const bits = await crypto.subtle.deriveBits(
    { name: "PBKDF2", hash: "SHA-256", salt: new Uint8Array(salt), iterations },
    keyMaterial,
    dkLenBytes * 8,
  );
  return new Uint8Array(bits);
}

// Проверяет пароль против phc-строки. Любая ошибка формата => false (без раскрытия причины).
export async function verifyPassword(password: string, stored: string): Promise<boolean> {
  try {
    if (typeof password !== "string" || password.length === 0) return false;
    const parts = stored.split("$");
    if (parts.length !== 5) return false;
    const [scheme, hashName, iterStr, saltB64, hashB64] = parts;
    if (scheme !== "pbkdf2" || hashName !== "sha256") return false;
    const iterations = Number(iterStr);
    if (!Number.isInteger(iterations) || iterations < 1) return false;
    const salt = b64urlToBytes(saltB64);
    const expected = b64urlToBytes(hashB64);
    if (salt.length === 0 || expected.length === 0) return false;
    const derived = await pbkdf2(password, salt, iterations, expected.length);
    return timingSafeEqual(derived, expected);
  } catch {
    return false;
  }
}

// Утилита для owner/тестов: собрать phc-строку из пароля (генерируется ОФЛАЙН, не в проде).
// Не содержит секретов; используется владельцем для получения TEACHER_PASSWORD_HASH.
export async function hashPassword(
  password: string,
  iterations = 210000,
  saltBytes = 16,
  dkLenBytes = 32,
): Promise<string> {
  const salt = crypto.getRandomValues(new Uint8Array(saltBytes));
  const derived = await pbkdf2(password, salt, iterations, dkLenBytes);
  return `pbkdf2$sha256$${iterations}$${bytesToB64url(salt)}$${bytesToB64url(derived)}`;
}
