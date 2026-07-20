// deno test supabase/functions/tests/telegram_test.ts
// Unit-тесты валидации Telegram initData (T10-02, B2-T02 negative cases, без сети/БД).

import { assertEquals, assertRejects } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { _internal, validateInitData } from "../_shared/telegram.ts";
import { AuthError } from "../_shared/errors.ts";

const enc = new TextEncoder();
const BOT = "123456:TEST_ONLY_not_a_real_token";
const NOW = 1_700_000_000;
const OPTS = { maxAgeSec: 86400, futureSkewSec: 300, now: NOW };

// Собирает валидный initData: считает корректный hash тем же алгоритмом Telegram.
async function buildInitData(
  fields: Record<string, string>,
  botToken = BOT,
): Promise<string> {
  const dcs = Object.entries(fields).map(([k, v]) => `${k}=${v}`).sort().join("\n");
  const secret = await _internal.hmacSha256(enc.encode("WebAppData"), botToken);
  const hash = _internal.toHex(await _internal.hmacSha256(secret, dcs));
  const usp = new URLSearchParams(fields);
  usp.set("hash", hash);
  return usp.toString();
}

const validUser = JSON.stringify({ id: 995000001, first_name: "T" });

Deno.test("valid fixture accepted", async () => {
  const initData = await buildInitData({ user: validUser, auth_date: String(NOW) });
  const r = await validateInitData(initData, BOT, OPTS);
  assertEquals(r.user.id, 995000001);
  assertEquals(r.authDate, NOW);
});

Deno.test("retry same valid initData accepted again", async () => {
  const initData = await buildInitData({ user: validUser, auth_date: String(NOW) });
  await validateInitData(initData, BOT, OPTS);
  const r2 = await validateInitData(initData, BOT, OPTS);
  assertEquals(r2.user.id, 995000001);
});

Deno.test("bad hash rejected", async () => {
  const initData = await buildInitData({ user: validUser, auth_date: String(NOW) });
  const tampered = initData.replace(/hash=[0-9a-f]+/i, "hash=" + "0".repeat(64));
  await assertRejects(() => validateInitData(tampered, BOT, OPTS), AuthError, "bad_hash");
});

Deno.test("changed user after hash rejected (bad_hash)", async () => {
  const initData = await buildInitData({ user: validUser, auth_date: String(NOW) });
  const other = encodeURIComponent(JSON.stringify({ id: 995000999, first_name: "X" }));
  const tampered = initData.replace(/user=[^&]+/, "user=" + other);
  await assertRejects(() => validateInitData(tampered, BOT, OPTS), AuthError, "bad_hash");
});

Deno.test("wrong bot token rejected", async () => {
  const initData = await buildInitData({ user: validUser, auth_date: String(NOW) });
  await assertRejects(
    () => validateInitData(initData, "999:OTHER_TOKEN", OPTS),
    AuthError,
    "bad_hash",
  );
});

Deno.test("missing hash rejected", async () => {
  const initData = `user=${encodeURIComponent(validUser)}&auth_date=${NOW}`;
  await assertRejects(() => validateInitData(initData, BOT, OPTS), AuthError, "bad_hash");
});

Deno.test("duplicate hash rejected", async () => {
  const initData = await buildInitData({ user: validUser, auth_date: String(NOW) });
  await assertRejects(
    () => validateInitData(initData + "&hash=" + "a".repeat(64), BOT, OPTS),
    AuthError,
    "bad_hash",
  );
});

Deno.test("old auth_date rejected", async () => {
  const old = NOW - 86400 - 10;
  const initData = await buildInitData({ user: validUser, auth_date: String(old) });
  await assertRejects(() => validateInitData(initData, BOT, OPTS), AuthError, "expired_auth_date");
});

Deno.test("future auth_date rejected", async () => {
  const future = NOW + 301;
  const initData = await buildInitData({ user: validUser, auth_date: String(future) });
  await assertRejects(() => validateInitData(initData, BOT, OPTS), AuthError, "future_auth_date");
});

Deno.test("malformed user json rejected", async () => {
  const initData = await buildInitData({ user: "{not json", auth_date: String(NOW) });
  await assertRejects(() => validateInitData(initData, BOT, OPTS), AuthError, "malformed_user");
});

Deno.test("non-integer user id rejected", async () => {
  const initData = await buildInitData({
    user: JSON.stringify({ id: "995000001", first_name: "T" }),
    auth_date: String(NOW),
  });
  await assertRejects(() => validateInitData(initData, BOT, OPTS), AuthError, "malformed_user");
});
