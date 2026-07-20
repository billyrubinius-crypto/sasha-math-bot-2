// deno test supabase/functions/tests/jwt_test.ts
// Unit-тесты ES256-подписи JWT (T10-02). Проверяем, что подпись верифицируется публичным ключом
// (как это сделает Supabase Data API через JWKS), а header несёт alg=ES256 и kid.

import { assert, assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { importSigningKey, signJwtES256 } from "../_shared/jwt.ts";

function b64urlDecode(s: string): Uint8Array<ArrayBuffer> {
  s = s.replace(/-/g, "+").replace(/_/g, "/");
  while (s.length % 4) s += "=";
  const bin = atob(s);
  const out = new Uint8Array(bin.length); // <ArrayBuffer>-backed => валидный BufferSource
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}
function b64urlDecodeJson(s: string): Record<string, unknown> {
  return JSON.parse(new TextDecoder().decode(b64urlDecode(s)));
}

Deno.test("ES256 sign is verifiable by the public key (JWKS path) and carries kid", async () => {
  const kp = await crypto.subtle.generateKey(
    { name: "ECDSA", namedCurve: "P-256" },
    true,
    ["sign", "verify"],
  );
  const privJwk = await crypto.subtle.exportKey("jwk", kp.privateKey) as JsonWebKey & { kid?: string };
  privJwk.kid = "test-kid-123";

  const signing = await importSigningKey(JSON.stringify(privJwk));
  assertEquals(signing.kid, "test-kid-123");

  const now = Math.floor(Date.now() / 1000);
  const jwt = await signJwtES256(signing, {
    role: "authenticated",
    app_role: "student",
    sub: "11111111-1111-1111-1111-111111111111",
    telegram_id: "995000001",
    aud: "authenticated",
    iat: now,
    exp: now + 3600,
  });

  const [h, p, s] = jwt.split(".");
  const header = b64urlDecodeJson(h);
  assertEquals(header.alg, "ES256");
  assertEquals(header.typ, "JWT");
  assertEquals(header.kid, "test-kid-123");

  const payload = b64urlDecodeJson(p);
  assertEquals(payload.role, "authenticated");
  assertEquals(payload.app_role, "student");
  assertEquals(payload.telegram_id, "995000001");

  const pub = await crypto.subtle.importKey(
    "jwk",
    await crypto.subtle.exportKey("jwk", kp.publicKey),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["verify"],
  );
  const ok = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    pub,
    b64urlDecode(s),
    new TextEncoder().encode(`${h}.${p}`),
  );
  assert(ok, "signature must verify with public key");
});

Deno.test("non-ES256 JWK rejected", async () => {
  let threw = false;
  try {
    await importSigningKey(JSON.stringify({ kty: "RSA", kid: "x" }));
  } catch {
    threw = true;
  }
  assert(threw);
});

Deno.test("base64-encoded private JWK imports without command-line JSON quoting", async () => {
  const kp = await crypto.subtle.generateKey(
    { name: "ECDSA", namedCurve: "P-256" },
    true,
    ["sign", "verify"],
  );
  const privateJwk = await crypto.subtle.exportKey("jwk", kp.privateKey) as JsonWebKey & { kid?: string };
  privateJwk.kid = "base64-secret-kid";

  const json = JSON.stringify(privateJwk);
  const base64 = btoa(String.fromCharCode(...new TextEncoder().encode(json)));
  const signing = await importSigningKey(base64);

  assertEquals(signing.kid, "base64-secret-kid");
});

Deno.test("Supabase CLI private JWK with sign+verify key_ops imports for signing", async () => {
  const kp = await crypto.subtle.generateKey(
    { name: "ECDSA", namedCurve: "P-256" },
    true,
    ["sign", "verify"],
  );
  const privateJwk = await crypto.subtle.exportKey("jwk", kp.privateKey) as JsonWebKey & { kid?: string };
  privateJwk.kid = "supabase-cli-kid";
  privateJwk.key_ops = ["sign", "verify"];

  const signing = await importSigningKey(JSON.stringify(privateJwk));

  assertEquals(signing.kid, "supabase-cli-kid");
  assertEquals(signing.key.usages, ["sign"]);
});
