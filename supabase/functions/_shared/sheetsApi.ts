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
export function assertExamDate(value: unknown): string | undefined {
  if (value === null || value === undefined || value === "") return undefined;
  try {
    return assertIsoDate(value);
  } catch {
    throw new Error("bad_exam_date");
  }
}
