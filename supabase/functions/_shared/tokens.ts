// _shared/tokens.ts — opaque refresh-токены учителя (T10-05, SPEC §3.3).
// Токен — высокоэнтропийная случайная строка; в БД хранится только его SHA-256 hash (hex).
// Плейнтекст живёт только в ответе клиенту и в памяти Edge, наружу/в лог не пишется.

export function generateRefreshToken(bytes = 32): string {
  const raw = crypto.getRandomValues(new Uint8Array(bytes));
  let bin = "";
  for (const b of raw) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  const bytes = new Uint8Array(digest);
  let hex = "";
  for (const b of bytes) hex += b.toString(16).padStart(2, "0");
  return hex;
}
