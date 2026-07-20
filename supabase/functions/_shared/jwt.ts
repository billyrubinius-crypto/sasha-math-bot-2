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

export const _internal = { b64url, b64urlJson };
