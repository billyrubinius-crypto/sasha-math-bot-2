// sheets-sync-api — узкий server-to-server API для Google Apps Script (T10-10C, SPEC_T10 §3.4).
//
// Зачем. Боевой Apps Script держит в Script Properties SERVICE-ROLE ключ и ходит прямым Data API:
// компрометация таблицы помощников = полный доступ к БД. Здесь Apps Script получает отдельный
// секрет и ровно три действия своей спецификации, service-role ключа у него больше нет.
//
// Действия (жёсткий allowlist):
//   student_lookup    — найти ученика по telegram_username (НИКОГДА не создаёт: нет ученика => null,
//                       это и есть статус «🟡 Ожидает первого входа» в таблице);
//   student_sync      — организационная группа + upsert даты оплаты в student_payments;
//   mock_exam_upsert  — результат пробника: пригодный (целый балл 0-100 + дата) уходит в canonical
//                       weekly_mock_exams через ту же серверную логику, что панель учителя
//                       (T10-10C2); непригодный — в архивную mock_exam_results с причиной.
//
// Чего сделать НЕЛЬЗЯ ни при каких аргументах: менять huikons/rating/season points/inventory,
// approvals заданий, security config, создавать учеников, читать что-либо кроме telegram_id по
// username. Payload для БД собирается здесь (см. _shared/db.ts), поля из тела запроса в него не
// подставляются — лишние ключи вроде huikons просто игнорируются.
//
// Развёртывать с --no-verify-jwt (проверка идёт по X-Sheets-Secret, не по Supabase JWT).

import { AuthError, json, safeError, tagAuditLine } from "../_shared/errors.ts";
import { constantTimeSecretEqual } from "../_shared/secret.ts";
import {
  rateLimitHit,
  rateLimitPeek,
  sheetsFindStudentByUsername,
  sheetsRecordWeeklyMockExam,
  sheetsUpdateStudentGroup,
  sheetsUpsertMockExam,
  sheetsUpsertPayment,
} from "../_shared/db.ts";
import {
  assertExamDate,
  assertExamName,
  assertGroupName,
  assertPaymentDate,
  assertScore,
  assertTelegramId,
  classifyMockExam,
  normalizeUsername,
} from "../_shared/sheetsApi.ts";

const SHEETS_SECRET = Deno.env.get("SHEETS_SYNC_API_SECRET") ?? "";
const MAX_BODY_BYTES = 2 * 1024; // 2 KB — одна строка таблицы, не пакет

const RL_FAIL_BUCKET = "sheets_sync_api_fail";
const RL_FAIL_MAX = Number(Deno.env.get("SHEETS_SYNC_API_FAIL_MAX") ?? "5");
const RL_FAIL_WINDOW_SEC = Number(Deno.env.get("SHEETS_SYNC_API_FAIL_WINDOW_SEC") ?? "900");

// Синхронизация идёт по строкам: ~2 вызова на ученика + 1 на оценку пробника, каждые 10 минут.
// Лимит заведомо выше типичного прогона, но отсекает бесконтрольный перебор при утечке секрета.
const RL_CALL_BUCKET = "sheets_sync_api_call";
const RL_CALL_MAX = Number(Deno.env.get("SHEETS_SYNC_API_CALL_MAX") ?? "1500");
const RL_CALL_WINDOW_SEC = Number(Deno.env.get("SHEETS_SYNC_API_CALL_WINDOW_SEC") ?? "300");

async function ipFingerprint(req: Request): Promise<string> {
  const xff = req.headers.get("x-forwarded-for") ?? "";
  const ip = xff.split(",")[0].trim() || req.headers.get("cf-connecting-ip") || "unknown";
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(ip));
  const bytes = new Uint8Array(digest);
  let hex = "";
  for (const b of bytes) hex += b.toString(16).padStart(2, "0");
  return hex;
}

// Ошибка валидации -> 400 с КОДОМ ПОЛЯ. Помощник видит не «bad request», а конкретную причину
// (Apps Script переводит код в русский текст), при этом наружу не уходят детали БД.
function fieldError(e: unknown): AuthError {
  const code = (e as Error)?.message ?? "bad_request";
  const known = [
    "bad_username",
    "bad_telegram_id",
    "bad_group",
    "bad_payment_date",
    "bad_exam_name",
    "bad_score",
    "bad_exam_date",
  ];
  return new AuthError(known.includes(code) ? code : "bad_request", 400);
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const raw = new Uint8Array(await req.arrayBuffer());
  if (raw.byteLength > MAX_BODY_BYTES) return json({ error: "body_too_large" }, 413);

  const fp = await ipFingerprint(req);
  let action: unknown;

  try {
    if (!SHEETS_SECRET) throw new AuthError("server_misconfigured", 500);

    const failAllowed = await rateLimitPeek(RL_FAIL_BUCKET, fp, RL_FAIL_MAX, RL_FAIL_WINDOW_SEC);
    if (!failAllowed) throw new AuthError("rate_limited", 429);

    const provided = req.headers.get("x-sheets-secret") ?? "";
    if (!provided || !(await constantTimeSecretEqual(provided, SHEETS_SECRET))) {
      await rateLimitHit(RL_FAIL_BUCKET, fp, RL_FAIL_MAX, RL_FAIL_WINDOW_SEC).catch(() => {});
      throw new AuthError("unauthorized", 401);
    }

    const callAllowed = await rateLimitHit(RL_CALL_BUCKET, fp, RL_CALL_MAX, RL_CALL_WINDOW_SEC);
    if (!callAllowed) throw new AuthError("rate_limited", 429);

    let body: Record<string, unknown>;
    try {
      body = raw.byteLength ? JSON.parse(new TextDecoder().decode(raw)) : {};
    } catch {
      throw new AuthError("bad_request", 400);
    }
    action = body.action;

    let data: unknown;
    switch (action) {
      // Только поиск. Ученика не создаём: null => помощник увидит «Ожидает первого входа».
      case "student_lookup": {
        let username: string;
        try {
          username = normalizeUsername(body.username);
        } catch (e) {
          throw fieldError(e);
        }
        data = { telegram_id: await sheetsFindStudentByUsername(username) };
        break;
      }

      // Группа + дата оплаты одной операцией (в Code.gs это были updateStudent + upsertPaymentDate).
      // Порядок и семантика прежние: сперва группа, затем платёж.
      case "student_sync": {
        let telegramId: number, groupName: string | null, paymentDate: string | null;
        try {
          telegramId = assertTelegramId(body.telegram_id);
          groupName = assertGroupName(body.group_name);
          paymentDate = assertPaymentDate(body.payment_date);
        } catch (e) {
          throw fieldError(e);
        }
        await sheetsUpdateStudentGroup(telegramId, groupName);
        await sheetsUpsertPayment(telegramId, paymentDate);
        data = { ok: true };
        break;
      }

      // T10-10C2: маршрут выбирает СЕРВЕР. Пригодное значение (целый балл 0-100 + дата) идёт в
      // canonical weekly_mock_exams через ту же логику, что панель учителя (награды pay-once,
      // season points дельтой, зеркало в архив делает сама RPC). Непригодное — только в архив,
      // с причиной для помощника. Клиент week_start не передаёт и маршрут не выбирает.
      case "mock_exam_upsert": {
        let telegramId: number, examName: string, score: string, examDate: string | undefined;
        try {
          telegramId = assertTelegramId(body.telegram_id);
          examName = assertExamName(body.exam_name);
          score = assertScore(body.score);
          examDate = assertExamDate(body.exam_date);
        } catch (e) {
          throw fieldError(e);
        }

        const route = classifyMockExam(score, examDate);
        if (route.canonical) {
          const res = await sheetsRecordWeeklyMockExam(telegramId, route.examDate, route.score);
          data = { ok: true, route: "canonical", week_start: res?.week_start ?? null };
        } else {
          await sheetsUpsertMockExam(telegramId, examName, score, examDate);
          data = { ok: true, route: "archive", reason: route.reason };
        }
        break;
      }

      default:
        throw new AuthError("bad_request", 400);
    }

    console.log(tagAuditLine("sheets-sync-api", "ok", typeof action === "string" ? action : "unknown"));
    return json({ data }, 200);
  } catch (e) {
    const { code, status } = safeError(e);
    console.log(tagAuditLine("sheets-sync-api", "rejected", code)); // без секрета и данных строки
    return json({ error: code }, status);
  }
});
