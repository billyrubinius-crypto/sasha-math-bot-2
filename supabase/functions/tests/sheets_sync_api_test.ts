// deno test supabase/functions/tests/sheets_sync_api_test.ts
// Unit-тесты чистой логики sheets-sync-api (T10-10C): нормализация username и границы того,
// что помощник может положить в организационные поля. Сеть/секреты не нужны.

import { assertEquals, assertThrows } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  assertExamDate,
  assertExamName,
  assertGroupName,
  assertPaymentDate,
  assertScore,
  assertTelegramId,
  normalizeUsername,
} from "../_shared/sheetsApi.ts";

Deno.test("normalizeUsername: тот же приём, что в Apps Script (trim, @, lowercase)", () => {
  assertEquals(normalizeUsername("  @IvanPetrov "), "ivanpetrov");
  assertEquals(normalizeUsername("ivan_petrov"), "ivan_petrov");
  assertEquals(normalizeUsername("Ivan123"), "ivan123");
  // Мусор из ячейки не должен доехать до запроса
  assertThrows(() => normalizeUsername("ivan petrov"), Error, "bad_username");
  assertThrows(() => normalizeUsername("ivan*"), Error, "bad_username");
  assertThrows(() => normalizeUsername("иван"), Error, "bad_username");
  assertThrows(() => normalizeUsername(""), Error, "bad_username");
  assertThrows(() => normalizeUsername(null), Error, "bad_username");
  assertThrows(() => normalizeUsername("a".repeat(65)), Error, "bad_username");
});

Deno.test("assertTelegramId: только положительное целое", () => {
  assertEquals(assertTelegramId(995000030), 995000030);
  assertThrows(() => assertTelegramId(0), Error, "bad_telegram_id");
  assertThrows(() => assertTelegramId(-5), Error, "bad_telegram_id");
  assertThrows(() => assertTelegramId("995000030"), Error, "bad_telegram_id");
});

Deno.test("assertGroupName: пустая ячейка => null, длинная строка => отказ", () => {
  assertEquals(assertGroupName("10А"), "10А");
  assertEquals(assertGroupName("  10Б  "), "10Б");
  assertEquals(assertGroupName(""), null);
  assertEquals(assertGroupName(null), null);
  assertEquals(assertGroupName(undefined), null);
  assertEquals(assertGroupName("   "), null);
  assertThrows(() => assertGroupName("Г".repeat(101)), Error, "bad_group");
  assertThrows(() => assertGroupName(42), Error, "bad_group");
});

Deno.test("assertPaymentDate: пусто допустимо, формат строгий", () => {
  assertEquals(assertPaymentDate("2026-07-22"), "2026-07-22");
  assertEquals(assertPaymentDate(""), null);
  assertEquals(assertPaymentDate(null), null);
  assertThrows(() => assertPaymentDate("22.07.2026"), Error, "bad_payment_date");
  assertThrows(() => assertPaymentDate("2026-02-30"), Error, "bad_payment_date");
  assertThrows(() => assertPaymentDate("скоро"), Error, "bad_payment_date");
});

Deno.test("assertExamName: непустой, ограниченной длины", () => {
  assertEquals(assertExamName(" Пробник №1 "), "Пробник №1");
  assertThrows(() => assertExamName(""), Error, "bad_exam_name");
  assertThrows(() => assertExamName("   "), Error, "bad_exam_name");
  assertThrows(() => assertExamName("П".repeat(101)), Error, "bad_exam_name");
  assertThrows(() => assertExamName(null), Error, "bad_exam_name");
});

Deno.test("assertScore: колонка text, но с границами", () => {
  assertEquals(assertScore(70), "70");
  assertEquals(assertScore(" 70.5 "), "70.5");
  assertEquals(assertScore("не писал"), "не писал");
  assertThrows(() => assertScore(""), Error, "bad_score");
  assertThrows(() => assertScore("x".repeat(51)), Error, "bad_score");
  assertThrows(() => assertScore(null), Error, "bad_score");
});

Deno.test("assertExamDate: пустая дата => undefined (не затирает сохранённую)", () => {
  assertEquals(assertExamDate("2026-07-22"), "2026-07-22");
  assertEquals(assertExamDate(""), undefined);
  assertEquals(assertExamDate(null), undefined);
  assertEquals(assertExamDate(undefined), undefined);
  assertThrows(() => assertExamDate("22.07.2026"), Error, "bad_exam_date");
  assertThrows(() => assertExamDate("2026-13-01"), Error, "bad_exam_date");
});
