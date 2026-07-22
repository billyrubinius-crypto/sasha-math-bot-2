// parent-bot-api — узкий server-to-server API для parent_bot.py (Railway), заменяет прямой
// Data API/publishable key (T10-10B, SPEC_T10 §§3.4-3.5).
//
// Три действия. Единственная запись — link; остальные read-only:
//   link             — поглощение ОДНОРАЗОВОГО приглашения (migration 044): принимает токен, НЕ
//                      student_id, поэтому знание telegram_id ребёнка доступа больше не даёт;
//   linked_students  — список подключённых детей этого родителя (student_id + имя);
//   progress         — прогресс/траектория/неделя ОДНОГО ребёнка, только после проверки parent_links.
// Действия «найти ученика по ID» нет: перечислять учеников через этот API нельзя в принципе.
//
// Приватность. parent_telegram_id всегда приходит из Telegram-update. Привязка возможна только по
// одноразовому токену (атомарное поглощение в SQL, hash вместо токена в БД), а КАЖДОЕ чтение
// прогресса проходит через parentLinkExists — раньше student_id из callback_data уходил в RPC без
// проверки связки, теперь это 403. Ответ ограничен утверждёнными родительскими полями
// (progress/mock trajectory/weekly), без баланса/инвентаря/бубликов и Stage 4 life-quest данных.
// Токен приглашения не логируется и не возвращается наружу ни в каком виде.
//
// Auth: статичный секрет в X-Parent-Bot-Secret (свой, НЕ общий со student-bot-api — компрометация
// одного бота не открывает другого, SPEC §3.4). Секрет не логируется и не возвращается.
// Развёртывать с --no-verify-jwt (проверка идёт через секрет, не через Supabase JWT).

import { AuthError, json, safeError, tagAuditLine } from "../_shared/errors.ts";
import { constantTimeSecretEqual } from "../_shared/secret.ts";
import { sha256Hex } from "../_shared/tokens.ts";
import {
  parentConsumeInvite,
  parentFetchCurrentWeek,
  parentFetchLinkedStudents,
  parentFetchProgress,
  parentFetchStudentName,
  parentFetchTrajectory,
  parentLinkExists,
  rateLimitHit,
  rateLimitPeek,
} from "../_shared/db.ts";
import {
  assertInviteToken,
  assertTelegramId,
  pickLinkedStudents,
  pickProgressRows,
  pickTrajectory,
  pickWeek,
} from "../_shared/parentApi.ts";

const BOT_SECRET = Deno.env.get("PARENT_BOT_API_SECRET") ?? "";
const MAX_BODY_BYTES = 2 * 1024; // 2 KB — тело только action + пара скалярных ID

const RL_FAIL_BUCKET = "parent_bot_api_fail";
const RL_FAIL_MAX = Number(Deno.env.get("PARENT_BOT_API_FAIL_MAX") ?? "5");
const RL_FAIL_WINDOW_SEC = Number(Deno.env.get("PARENT_BOT_API_FAIL_WINDOW_SEC") ?? "900");

const RL_CALL_BUCKET = "parent_bot_api_call";
const RL_CALL_MAX = Number(Deno.env.get("PARENT_BOT_API_CALL_MAX") ?? "300");
const RL_CALL_WINDOW_SEC = Number(Deno.env.get("PARENT_BOT_API_CALL_WINDOW_SEC") ?? "300");

async function ipFingerprint(req: Request): Promise<string> {
  const xff = req.headers.get("x-forwarded-for") ?? "";
  const ip = xff.split(",")[0].trim() || req.headers.get("cf-connecting-ip") || "unknown";
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(ip));
  const bytes = new Uint8Array(digest);
  let hex = "";
  for (const b of bytes) hex += b.toString(16).padStart(2, "0");
  return hex;
}

function badRequest(): AuthError {
  return new AuthError("bad_request", 400);
}

// Аргументы всегда парой (родитель из update + ребёнок), поэтому один общий разбор.
function parentAndStudent(body: Record<string, unknown>): { parentId: number; studentId: number } {
  try {
    return {
      parentId: assertTelegramId(body.parent_id),
      studentId: assertTelegramId(body.student_id),
    };
  } catch {
    throw badRequest();
  }
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const raw = new Uint8Array(await req.arrayBuffer());
  if (raw.byteLength > MAX_BODY_BYTES) return json({ error: "body_too_large" }, 413);

  const fp = await ipFingerprint(req);
  let action: unknown;

  try {
    if (!BOT_SECRET) throw new AuthError("server_misconfigured", 500);

    const failAllowed = await rateLimitPeek(RL_FAIL_BUCKET, fp, RL_FAIL_MAX, RL_FAIL_WINDOW_SEC);
    if (!failAllowed) throw new AuthError("rate_limited", 429);

    const provided = req.headers.get("x-parent-bot-secret") ?? "";
    if (!provided || !(await constantTimeSecretEqual(provided, BOT_SECRET))) {
      await rateLimitHit(RL_FAIL_BUCKET, fp, RL_FAIL_MAX, RL_FAIL_WINDOW_SEC).catch(() => {});
      throw new AuthError("unauthorized", 401);
    }

    const callAllowed = await rateLimitHit(RL_CALL_BUCKET, fp, RL_CALL_MAX, RL_CALL_WINDOW_SEC);
    if (!callAllowed) throw new AuthError("rate_limited", 429);

    let body: Record<string, unknown>;
    try {
      body = raw.byteLength ? JSON.parse(new TextDecoder().decode(raw)) : {};
    } catch {
      throw badRequest();
    }
    action = body.action;

    let data: unknown;
    switch (action) {
      // Единственная запись. Принимает ТОЛЬКО одноразовый токен + parent_id из Telegram-update.
      // Плейнтекст токена дальше этой функции не идёт: в SQL уходит его SHA-256 hash.
      // Битый формат, чужой, просроченный и уже поглощённый токен дают ОДИН ответ linked=false —
      // по нему нельзя отличить «такого приглашения нет» от «оно уже использовано».
      case "link": {
        let parentId: number, token: string;
        try {
          parentId = assertTelegramId(body.parent_id);
          token = assertInviteToken(body.token);
        } catch {
          data = { linked: false, name: null };
          break;
        }
        const result = await parentConsumeInvite(await sha256Hex(token), parentId);
        data = result?.status === "ok"
          ? { linked: true, name: result.name ?? null }
          : { linked: false, name: null };
        break;
      }

      case "linked_students": {
        let parentId: number;
        try {
          parentId = assertTelegramId(body.parent_id);
        } catch {
          throw badRequest();
        }
        data = { students: pickLinkedStudents(await parentFetchLinkedStudents(parentId)) };
        break;
      }

      // Единственная точка чтения прогресса. Связка проверяется ДО любых RPC; чужой/подделанный
      // student_id и неподключённый родитель дают одинаковый 403 (существование не раскрываем).
      case "progress": {
        const { parentId, studentId } = parentAndStudent(body);
        if (!(await parentLinkExists(parentId, studentId))) throw new AuthError("forbidden", 403);

        const [progress, trajectory] = await Promise.all([
          parentFetchProgress(studentId),
          parentFetchTrajectory(studentId),
        ]);

        // Недельный блок необязателен: его сбой не должен ломать /progress (W07-требование
        // «старый /progress работает»). Раньше это был отдельный try/except в Python — теперь
        // тот же контракт держит сервер, отдавая week: null.
        let week: unknown = null;
        try {
          week = pickWeek(await parentFetchCurrentWeek(studentId));
        } catch (_e) {
          console.log(tagAuditLine("parent-bot-api", "week_unavailable", "soft"));
        }

        data = {
          name: await parentFetchStudentName(studentId),
          progress: pickProgressRows(progress),
          trajectory: pickTrajectory(trajectory),
          week,
        };
        break;
      }

      default:
        throw badRequest();
    }

    console.log(tagAuditLine("parent-bot-api", "ok", typeof action === "string" ? action : "unknown"));
    return json({ data }, 200);
  } catch (e) {
    const { code, status } = safeError(e);
    console.log(tagAuditLine("parent-bot-api", "rejected", code));
    return json({ error: code }, status);
  }
});
