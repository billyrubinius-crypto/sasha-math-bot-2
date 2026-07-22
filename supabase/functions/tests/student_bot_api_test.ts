// deno test supabase/functions/tests/student_bot_api_test.ts
// Unit-тесты чистой логики student-bot-api (T10-10A): валидация ключей/дат/season_id и константное
// сравнение секрета. Сеть/секреты не нужны.

import { assert, assertEquals, assertThrows } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  assertIsoDate,
  assertLastSentKey,
  assertMarkSentKey,
  assertPositiveInt,
  parseAlreadyNotifiedIds,
  STATIC_NOTIFICATION_KEYS,
} from "../_shared/botApi.ts";
import { constantTimeSecretEqual } from "../_shared/secret.ts";

Deno.test("STATIC_NOTIFICATION_KEYS: ровно три планировщик-маркера", () => {
  assertEquals([...STATIC_NOTIFICATION_KEYS].sort(), [
    "evening_reminder",
    "league_result_check",
    "morning_digest",
  ]);
});

Deno.test("assertLastSentKey: только статичные ключи, league-ключ отвергается", () => {
  assertEquals(assertLastSentKey("morning_digest"), "morning_digest");
  assertEquals(assertLastSentKey("evening_reminder"), "evening_reminder");
  assertEquals(assertLastSentKey("league_result_check"), "league_result_check");
  assertThrows(() => assertLastSentKey("league_result:1:2"), Error, "bad_key");
  assertThrows(() => assertLastSentKey("morning_digest; drop table x"), Error, "bad_key");
  assertThrows(() => assertLastSentKey(undefined), Error, "bad_key");
  assertThrows(() => assertLastSentKey(123), Error, "bad_key");
});

Deno.test("assertMarkSentKey: статичные ключи И league_result:<season>:<student>, ничего иного", () => {
  assertEquals(assertMarkSentKey("morning_digest"), "morning_digest");
  assertEquals(assertMarkSentKey("league_result:7:995000009"), "league_result:7:995000009");
  assertThrows(() => assertMarkSentKey("league_result:0:5"), Error, "bad_key");
  assertThrows(() => assertMarkSentKey("league_result:7:995000009:extra"), Error, "bad_key");
  assertThrows(() => assertMarkSentKey("league_result:7:-5"), Error, "bad_key");
  assertThrows(() => assertMarkSentKey("some_other_key"), Error, "bad_key");
  assertThrows(() => assertMarkSentKey("students"), Error, "bad_key");
});

Deno.test("assertIsoDate: строгий YYYY-MM-DD, календарно валидный", () => {
  assertEquals(assertIsoDate("2026-07-22"), "2026-07-22");
  assertThrows(() => assertIsoDate("2026-13-01"), Error, "bad_date");
  assertThrows(() => assertIsoDate("2026-02-30"), Error, "bad_date");
  assertThrows(() => assertIsoDate("22-07-2026"), Error, "bad_date");
  assertThrows(() => assertIsoDate("2026-07-22T00:00:00Z"), Error, "bad_date");
  assertThrows(() => assertIsoDate(20260722), Error, "bad_date");
});

Deno.test("assertPositiveInt: только положительное целое число", () => {
  assertEquals(assertPositiveInt(7), 7);
  assertThrows(() => assertPositiveInt(0), Error, "bad_int");
  assertThrows(() => assertPositiveInt(-3), Error, "bad_int");
  assertThrows(() => assertPositiveInt(1.5), Error, "bad_int");
  assertThrows(() => assertPositiveInt("7"), Error, "bad_int");
  assertThrows(() => assertPositiveInt(undefined), Error, "bad_int");
});

Deno.test("parseAlreadyNotifiedIds: только числовой суффикс, совпадающий season_id", () => {
  const keys = [
    "league_result:7:995000001",
    "league_result:7:995000002",
    "league_result:8:995000003", // другой сезон — не должен попасть в LIKE-выборку, но и тут отсеян
    "league_result:7:abc",       // не число — игнорируется
    "unrelated_key",
  ];
  assertEquals(parseAlreadyNotifiedIds(keys, 7).sort(), [995000001, 995000002]);
  assertEquals(parseAlreadyNotifiedIds(keys, 8), [995000003]);
  assertEquals(parseAlreadyNotifiedIds([], 7), []);
});

Deno.test("constantTimeSecretEqual: совпадающие и разные секреты, независимо от длины", () => {
  assert(await constantTimeSecretEqual("same-secret", "same-secret"));
  assert(!(await constantTimeSecretEqual("same-secret", "same-secre")));
  assert(!(await constantTimeSecretEqual("short", "a-much-much-longer-secret-value")));
  assert(!(await constantTimeSecretEqual("", "nonempty")));
  assert(await constantTimeSecretEqual("", ""));
});
