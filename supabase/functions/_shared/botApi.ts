// _shared/botApi.ts — чистая валидация входных аргументов student-bot-api (T10-10A).
// Никакой сети/секретов здесь нет — только то, что можно юнит-тестировать без Deno-рантайма
// (тот же приём, что и в _shared/cloudinary.ts для sign-upload). Бросает bare Error с коротким
// кодом; index.ts сам решает, в какой AuthError/HTTP-статус это превратить.

// Три статичных ключа main.py (morning_digest/evening_reminder/league_result_check) — ровно то,
// что раньше писалось/читалось напрямую в bot_notification_state.
export const STATIC_NOTIFICATION_KEYS = [
  "morning_digest",
  "evening_reminder",
  "league_result_check",
] as const;
export type StaticNotificationKey = typeof STATIC_NOTIFICATION_KEYS[number];

const LEAGUE_KEY_RE = /^league_result:([1-9]\d*):([1-9]\d*)$/;
const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;

function isStaticKey(value: unknown): value is StaticNotificationKey {
  return typeof value === "string" && (STATIC_NOTIFICATION_KEYS as readonly string[]).includes(value);
}

export function assertPositiveInt(value: unknown): number {
  if (typeof value !== "number" || !Number.isInteger(value) || value <= 0) {
    throw new Error("bad_int");
  }
  return value;
}

// notification_last_sent читает только один из трёх фиксированных маркеров планировщика —
// league-per-student маркер здесь не допускается (для него отдельное действие с dedupe-списком).
export function assertLastSentKey(value: unknown): StaticNotificationKey {
  if (!isStaticKey(value)) throw new Error("bad_key");
  return value;
}

// notification_mark_sent пишет либо один из трёх статичных маркеров, либо ровно
// league_result:<season_id>:<student_id> — никакой другой ключ в bot_notification_state не уйдёт,
// даже если секрет утечёт.
export function assertMarkSentKey(value: unknown): string {
  if (isStaticKey(value)) return value;
  if (typeof value === "string" && LEAGUE_KEY_RE.test(value)) return value;
  throw new Error("bad_key");
}

// YYYY-MM-DD и реальная календарная дата (отсекает 2026-13-40 и т.п.).
export function assertIsoDate(value: unknown): string {
  if (typeof value !== "string" || !DATE_RE.test(value)) throw new Error("bad_date");
  const d = new Date(`${value}T00:00:00Z`);
  if (Number.isNaN(d.getTime()) || d.toISOString().slice(0, 10) !== value) throw new Error("bad_date");
  return value;
}

// Порт main.py fetch_already_notified_student_ids: из ключей вида league_result:<season_id>:<id>
// достаём только числовой student_id, сверяя, что season_id в ключе совпадает с запрошенным
// (PostgREST LIKE и так фильтрует по префиксу, здесь — второй, независимый рубеж).
export function parseAlreadyNotifiedIds(keys: string[], seasonId: number): number[] {
  const prefix = `league_result:${seasonId}:`;
  const ids: number[] = [];
  for (const key of keys) {
    if (!key.startsWith(prefix)) continue;
    const suffix = key.slice(prefix.length);
    if (/^[1-9]\d*$/.test(suffix)) ids.push(Number(suffix));
  }
  return ids;
}
