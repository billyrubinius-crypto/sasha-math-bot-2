// deno test supabase/functions/tests/parent_bot_api_test.ts
// Unit-тесты чистой логики parent-bot-api (T10-10B): валидация Telegram ID и — главное —
// приватность формы ответа (никаких денег/инвентаря/Stage 4 life-quest полей). Сеть не нужна.

import { assert, assertEquals, assertThrows } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  assertInviteToken,
  assertTelegramId,
  pickLinkedStudents,
  pickProgressRows,
  pickTrajectory,
  pickWeek,
} from "../_shared/parentApi.ts";
import { sha256Hex } from "../_shared/tokens.ts";

Deno.test("assertInviteToken: формат Telegram start-payload, мусор отвергается", () => {
  const token = "a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718";
  assertEquals(assertInviteToken(token), token);
  assertThrows(() => assertInviteToken("short"), Error, "bad_token");
  assertThrows(() => assertInviteToken("995000020"), Error, "bad_token"); // старая ссылка по ID
  assertThrows(() => assertInviteToken("token with spaces!!"), Error, "bad_token");
  assertThrows(() => assertInviteToken("a".repeat(65)), Error, "bad_token");
  assertThrows(() => assertInviteToken(undefined), Error, "bad_token");
  assertThrows(() => assertInviteToken(12345678901234), Error, "bad_token");
});

Deno.test("sha256Hex: hash токена совпадает с тем, что считает SQL (encode(sha256(...),'hex'))", async () => {
  // Контрольный вектор: sha256("abc") — тот же результат даёт
  // encode(sha256(convert_to('abc','UTF8')),'hex') в migration 044.
  assertEquals(
    await sha256Hex("abc"),
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
  );
  // Формат hash'а — ровно то, что принимает consume_parent_invite: ^[0-9a-f]{64}$
  assert(/^[0-9a-f]{64}$/.test(await sha256Hex("любой токен")));
});

Deno.test("assertTelegramId: только положительное целое в безопасном диапазоне", () => {
  assertEquals(assertTelegramId(995000001), 995000001);
  assertThrows(() => assertTelegramId(0), Error, "bad_telegram_id");
  assertThrows(() => assertTelegramId(-1), Error, "bad_telegram_id");
  assertThrows(() => assertTelegramId(1.5), Error, "bad_telegram_id");
  assertThrows(() => assertTelegramId("995000001"), Error, "bad_telegram_id");
  assertThrows(() => assertTelegramId(undefined), Error, "bad_telegram_id");
  assertThrows(() => assertTelegramId(Number.MAX_SAFE_INTEGER + 2), Error, "bad_telegram_id");
});

Deno.test("pickProgressRows: ровно type/issued/completed", () => {
  const rows = pickProgressRows([
    { type: "daily", issued: 10, completed: 7, secret_field: "leak" },
  ]);
  assertEquals(rows, [{ type: "daily", issued: 10, completed: 7 }]);
  assertEquals(pickProgressRows(null), []);
  assertEquals(pickProgressRows("nonsense"), []);
});

Deno.test("pickTrajectory: только утверждённые поля пробников, лишнее отбрасывается", () => {
  const t = pickTrajectory({
    count: 2,
    points: [{ week_start: "2026-07-13", score: 70, huikons: 999 }],
    last_score: 70,
    delta_last: 5,
    avg_last_3: null,
    min_last_3: null,
    max_last_3: null,
    trend: null,
    balance: 12345, // денежное поле — не должно пройти
  })!;
  assertEquals(Object.keys(t).sort(), [
    "avg_last_3",
    "count",
    "delta_last",
    "last_score",
    "max_last_3",
    "min_last_3",
    "points",
    "trend",
  ]);
  assertEquals(t.points, [{ week_start: "2026-07-13", score: 70 }]);
  assert(!("balance" in t));
  assertEquals(pickTrajectory(null), null);
});

Deno.test("pickWeek: reward_forecast (бублики) НЕ проходит наружу", () => {
  const week = pickWeek({
    week_start: "2026-07-20",
    week_end: "2026-07-26",
    n: 5,
    a: 3,
    s: 1,
    e: 4,
    result_status: "pending",
    classification: "successful",
    reward_forecast: 40, // денежное поле — родителю не показывается
    weekly: { title: "Неделя 3", task_count: 12, status: "approved", extra: "leak" },
    days: [{
      day_index: 0,
      date: "2026-07-20",
      assignment_id: "uuid-here",
      title: "Задание",
      task_count: 4,
      status: "revision",
      shield_status: "consumed",
      revision_deadline_at: "2026-07-21T20:59:00Z",
      life_quest: "приватное", // Stage 4 privacy — не должно пройти
    }],
  })!;
  assert(!("reward_forecast" in week), "reward_forecast не отдаётся родителю");
  assertEquals(Object.keys(week).sort(), [
    "a",
    "classification",
    "days",
    "e",
    "n",
    "result_status",
    "s",
    "week_end",
    "week_start",
    "weekly",
  ]);
  const day = (week.days as Record<string, unknown>[])[0];
  assert(!("life_quest" in day), "life-quest данные не отдаются родителю");
  assert(!("assignment_id" in day), "внутренний assignment_id не отдаётся");
  assertEquals(day.shield_status, "consumed"); // weekly shields — утверждённая часть UX
  assertEquals(Object.keys(week.weekly as Record<string, unknown>).sort(), [
    "status",
    "task_count",
    "title",
  ]);
});

Deno.test("pickWeek: пустая/битая неделя не роняет форму ответа", () => {
  assertEquals(pickWeek(null), null);
  const empty = pickWeek({})!;
  assertEquals(empty.n, 0);
  assertEquals(empty.days, []);
  assertEquals(empty.weekly, null);
});

Deno.test("pickLinkedStudents: student_id + имя, без прочих полей ученика", () => {
  const rows = pickLinkedStudents([
    { student_id: 995000001, students: { name: "Аня", group_name: "10А", huikons: 500 } },
    { student_id: 995000002, students: null },
    { student_id: 0, students: { name: "битая строка" } },
    { nonsense: true },
  ]);
  assertEquals(rows, [
    { student_id: 995000001, name: "Аня" },
    { student_id: 995000002, name: null },
  ]);
  assertEquals(pickLinkedStudents(null), []);
});
