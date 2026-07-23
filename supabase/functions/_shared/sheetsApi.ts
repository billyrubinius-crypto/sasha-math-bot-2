// _shared/sheetsApi.ts — чистая валидация аргументов sheets-sync-api (T10-10C).
// Сети/секретов здесь нет: юнит-тестируется без Deno-рантайма (как cloudinary/botApi/parentApi).
//
// Роль модуля — вторая половина allowlist'а. Первая половина (какие таблицы и колонки вообще
// достижимы) зафиксирована в _shared/db.ts; здесь фиксируется, что именно помощник может в них
// положить. Игровые поля (huikons/rating/season points/inventory/approvals) не проходят просто
// потому, что ни одна функция их не принимает и не формирует.

import { assertIsoDate } from "./botApi.ts"; // тот же строгий YYYY-MM-DD, не дублируем

// Telegram username из таблицы: нормализуется так же, как в Apps Script
// (trim, снять ведущий @, lowercase) — сервер не доверяет нормализации клиента и делает её сам.
export function normalizeUsername(raw: unknown): string {
  if (typeof raw !== "string" && typeof raw !== "number") throw new Error("bad_username");
  const value = String(raw).trim().replace(/^@/, "").toLowerCase();
  if (!/^[a-z0-9_]{1,64}$/.test(value)) throw new Error("bad_username");
  return value;
}

export function assertTelegramId(value: unknown): number {
  if (
    typeof value !== "number" || !Number.isInteger(value) ||
    value <= 0 || value > Number.MAX_SAFE_INTEGER
  ) {
    throw new Error("bad_telegram_id");
  }
  return value;
}

// Группа — организационное поле. Пустая ячейка = null (как сейчас в Code.gs: group_name ? ... : null).
export function assertGroupName(value: unknown): string | null {
  if (value === null || value === undefined || value === "") return null;
  if (typeof value !== "string") throw new Error("bad_group");
  const trimmed = value.trim();
  if (trimmed.length === 0) return null;
  if (trimmed.length > 100) throw new Error("bad_group");
  return trimmed;
}

// Дата оплаты: пустая ячейка допустима (null) — помощник мог её ещё не заполнить.
export function assertPaymentDate(value: unknown): string | null {
  if (value === null || value === undefined || value === "") return null;
  try {
    return assertIsoDate(value);
  } catch {
    throw new Error("bad_payment_date");
  }
}

export function assertExamName(value: unknown): string {
  if (typeof value !== "string") throw new Error("bad_exam_name");
  const trimmed = value.trim();
  if (trimmed.length === 0 || trimmed.length > 100) throw new Error("bad_exam_name");
  return trimmed;
}

// score в схеме — text (в таблице помощники пишут и числа, и пометки), поэтому здесь только
// приведение к строке и ограничение длины, без навязывания числового формата.
export function assertScore(value: unknown): string {
  if (typeof value !== "string" && typeof value !== "number") throw new Error("bad_score");
  const trimmed = String(value).trim();
  if (trimmed.length === 0 || trimmed.length > 50) throw new Error("bad_score");
  return trimmed;
}

// Дата пробника необязательна. undefined => поле вообще не уйдёт в upsert, поэтому ранее
// сохранённый exam_date НЕ затирается (требование GOOGLE_SHEETS_SPEC/README).
// ВАЖНО: пустая ячейка (undefined) — это не ошибка, а маршрут «только архив» (см. classifyMockExam);
// а вот заполненная, но нечитаемая дата — именно ошибка помощника, и она бросается.
export function assertExamDate(value: unknown): string | undefined {
  if (value === null || value === undefined || value === "") return undefined;
  try {
    return assertIsoDate(value);
  } catch {
    throw new Error("bad_exam_date");
  }
}

// --- Маршрутизация пробника (T10-10C2) --------------------------------------------------------
// Canonical-таблица weekly_mock_exams требует ЦЕЛЫЙ балл 0-100 и дату (из неё считается неделя).
// Всё, что этим требованиям не отвечает, не является ошибкой помощника: в таблице встречаются
// пометки вроде «не писал» и незаполненные даты. Такие значения сохраняются в архивной
// mock_exam_results, как и раньше, а помощник получает причину — молча ничего не теряется.
export type MockExamRoute =
  | { canonical: true; score: number; examDate: string }
  | { canonical: false; reason: "no_exam_date" | "score_not_number" | "score_out_of_range" };

export function classifyMockExam(score: string, examDate: string | undefined): MockExamRoute {
  if (!examDate) return { canonical: false, reason: "no_exam_date" };
  if (!/^-?\d{1,3}$/.test(score)) return { canonical: false, reason: "score_not_number" };
  const value = Number(score);
  if (value < 0 || value > 100) return { canonical: false, reason: "score_out_of_range" };
  return { canonical: true, score: value, examDate };
}
