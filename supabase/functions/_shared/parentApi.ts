// _shared/parentApi.ts — чистая логика parent-bot-api (T10-10B): валидация Telegram ID и
// приведение ответов к минимальному, утверждённому родительским UX набору полей.
// Сети/секретов здесь нет — юнит-тестируется без Deno-рантайма (как cloudinary.ts/botApi.ts).

// Одноразовый токен приглашения (migration 044). Формат проверяется до любых обращений к БД:
// Telegram start-payload допускает [A-Za-z0-9_-] длиной до 64. Сам токен никогда не логируется
// и не возвращается в ответах — из него сразу считается SHA-256 hash.
const INVITE_TOKEN_RE = /^[A-Za-z0-9_-]{20,64}$/;

export function assertInviteToken(value: unknown): string {
  if (typeof value !== "string" || !INVITE_TOKEN_RE.test(value)) throw new Error("bad_token");
  return value;
}

// Telegram ID — положительное целое в пределах безопасного диапазона JS/bigint.
export function assertTelegramId(value: unknown): number {
  if (
    typeof value !== "number" || !Number.isInteger(value) ||
    value <= 0 || value > Number.MAX_SAFE_INTEGER
  ) {
    throw new Error("bad_telegram_id");
  }
  return value;
}

// Прогресс по типам заданий: ровно те три поля, что печатает format_progress_message.
export interface ProgressRow {
  type: string;
  issued: number;
  completed: number;
}
export function pickProgressRows(rows: unknown): ProgressRow[] {
  if (!Array.isArray(rows)) return [];
  return rows.map((r) => ({
    type: String(r?.type ?? ""),
    issued: Number(r?.issued ?? 0),
    completed: Number(r?.completed ?? 0),
  }));
}

// Траектория пробников (U05A/U05B): count/points/delta/avg/min/max/trend — всё, что использует
// format_trajectory_summary и render_mock_chart, и ничего сверх.
export function pickTrajectory(t: unknown): Record<string, unknown> | null {
  if (!t || typeof t !== "object") return null;
  const src = t as Record<string, unknown>;
  const points = Array.isArray(src.points)
    ? src.points.map((p) => ({
      week_start: (p as Record<string, unknown>)?.week_start ?? null,
      score: (p as Record<string, unknown>)?.score ?? null,
    }))
    : [];
  return {
    count: src.count ?? 0,
    points,
    last_score: src.last_score ?? null,
    delta_last: src.delta_last ?? null,
    avg_last_3: src.avg_last_3 ?? null,
    min_last_3: src.min_last_3 ?? null,
    max_last_3: src.max_last_3 ?? null,
    trend: src.trend ?? null,
  };
}

// Недельный блок (W07). Пропускаем только то, что печатает format_week_block, и СОЗНАТЕЛЬНО
// отбрасываем reward_forecast: это сумма бубликов (денежное поле), родителю она не показывается
// и в родительский UX не входит. days отдаются с полями дня, включая щиты (weekly shields —
// утверждённая часть родительского UX), но без каких-либо Stage 4 life-quest данных: их нет и
// в самом get_student_current_week.
export function pickWeek(week: unknown): Record<string, unknown> | null {
  if (!week || typeof week !== "object") return null;
  const src = week as Record<string, unknown>;
  const days = Array.isArray(src.days)
    ? src.days.map((d) => {
      const day = d as Record<string, unknown>;
      return {
        day_index: day?.day_index ?? null,
        date: day?.date ?? null,
        title: day?.title ?? null,
        task_count: day?.task_count ?? null,
        status: day?.status ?? null,
        shield_status: day?.shield_status ?? null,
        revision_deadline_at: day?.revision_deadline_at ?? null,
      };
    })
    : [];
  const weekly = src.weekly && typeof src.weekly === "object"
    ? {
      title: (src.weekly as Record<string, unknown>)?.title ?? null,
      task_count: (src.weekly as Record<string, unknown>)?.task_count ?? null,
      status: (src.weekly as Record<string, unknown>)?.status ?? null,
    }
    : null;
  return {
    week_start: src.week_start ?? null,
    week_end: src.week_end ?? null,
    n: src.n ?? 0,
    a: src.a ?? 0,
    s: src.s ?? 0,
    e: src.e ?? 0,
    result_status: src.result_status ?? null,
    classification: src.classification ?? null,
    weekly,
    days,
  };
}

// Список подключённых учеников: student_id + имя. Ни группы, ни каких-либо иных полей ученика.
export interface LinkedStudent {
  student_id: number;
  name: string | null;
}
export function pickLinkedStudents(rows: unknown): LinkedStudent[] {
  if (!Array.isArray(rows)) return [];
  const out: LinkedStudent[] = [];
  for (const row of rows) {
    const r = row as Record<string, unknown>;
    const id = Number(r?.student_id);
    if (!Number.isInteger(id) || id <= 0) continue;
    const student = r?.students as Record<string, unknown> | null | undefined;
    out.push({ student_id: id, name: (student?.name as string) ?? null });
  }
  return out;
}
