// student-bot-api — узкий server-to-server API для main.py (Railway student bot), заменяет
// прямой Data API/publishable key (T10-10A, SPEC_T10 §3.4).
//
// Фиксированный allowlist действий: получить активные assignments для рассылок, прочитать/записать
// idempotency-маркер (bot_notification_state), получить данные закрытого сезона для итогов лиги.
// Ни одно действие не меняет balance/assignment/reward/season — единственная запись сюда это
// notification_mark_sent, и она ограничена форматом ключа (см. _shared/botApi.ts).
//
// Auth: статичный высокоэнтропийный секрет в заголовке X-Bot-Secret, сравнивается константным по
// времени способом с STUDENT_BOT_API_SECRET (Edge secret). Это не браузерная функция — Origin/CORS
// не проверяются и не нужны (main.py — server-to-server клиент, не Mini App).
//
// Секрет не логируется и не возвращается. Развёртывать как student-auth/sign-upload:
// --no-verify-jwt (проверка идёт через X-Bot-Secret, не через Supabase JWT).

import { AuthError, json, safeError, tagAuditLine } from "../_shared/errors.ts";
import { constantTimeSecretEqual } from "../_shared/secret.ts";
import {
  fetchActiveAssignmentsForBot,
  fetchAlreadyNotifiedLeagueKeys,
  fetchLatestClosedSeasonId,
  fetchLeagueCrownStudentId,
  fetchLeagueMemberships,
  fetchLeagueMovements,
  fetchLeagueTiers,
  fetchNotificationLastSent,
  markNotificationSent,
  rateLimitHit,
  rateLimitPeek,
} from "../_shared/db.ts";
import {
  assertIsoDate,
  assertLastSentKey,
  assertMarkSentKey,
  assertPositiveInt,
  parseAlreadyNotifiedIds,
} from "../_shared/botApi.ts";

const BOT_SECRET = Deno.env.get("STUDENT_BOT_API_SECRET") ?? "";
const MAX_BODY_BYTES = 2 * 1024; // 2 KB — тело только action + пара скалярных аргументов

// Gate по неудачным попыткам (перебор секрета) — отдельно от общего лимита успешных вызовов.
const RL_FAIL_BUCKET = "student_bot_api_fail";
const RL_FAIL_MAX = Number(Deno.env.get("STUDENT_BOT_API_FAIL_MAX") ?? "5");
const RL_FAIL_WINDOW_SEC = Number(Deno.env.get("STUDENT_BOT_API_FAIL_WINDOW_SEC") ?? "900");

// Общий лимит успешных вызовов — защита на случай, если секрет всё же утёк.
const RL_CALL_BUCKET = "student_bot_api_call";
const RL_CALL_MAX = Number(Deno.env.get("STUDENT_BOT_API_CALL_MAX") ?? "300");
const RL_CALL_WINDOW_SEC = Number(Deno.env.get("STUDENT_BOT_API_CALL_WINDOW_SEC") ?? "300");

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

    const provided = req.headers.get("x-bot-secret") ?? "";
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
      case "active_assignments":
        data = await fetchActiveAssignmentsForBot();
        break;

      case "notification_last_sent": {
        let key: string;
        try {
          key = assertLastSentKey(body.key);
        } catch {
          throw badRequest();
        }
        data = { last_sent_date: await fetchNotificationLastSent(key) };
        break;
      }

      case "notification_mark_sent": {
        let key: string, sentDate: string;
        try {
          key = assertMarkSentKey(body.key);
          sentDate = assertIsoDate(body.sent_date);
        } catch {
          throw badRequest();
        }
        await markNotificationSent(key, sentDate);
        data = { ok: true };
        break;
      }

      case "notification_already_sent_ids": {
        let seasonId: number;
        try {
          seasonId = assertPositiveInt(body.season_id);
        } catch {
          throw badRequest();
        }
        const keys = await fetchAlreadyNotifiedLeagueKeys(seasonId);
        data = { student_ids: parseAlreadyNotifiedIds(keys, seasonId) };
        break;
      }

      case "latest_closed_season":
        data = { season_id: await fetchLatestClosedSeasonId() };
        break;

      case "league_memberships": {
        let seasonId: number;
        try {
          seasonId = assertPositiveInt(body.season_id);
        } catch {
          throw badRequest();
        }
        data = { memberships: await fetchLeagueMemberships(seasonId) };
        break;
      }

      case "league_tiers":
        data = { tiers: await fetchLeagueTiers() };
        break;

      case "league_movements": {
        let seasonId: number;
        try {
          seasonId = assertPositiveInt(body.season_id);
        } catch {
          throw badRequest();
        }
        data = { movements: await fetchLeagueMovements(seasonId) };
        break;
      }

      case "league_crown_student": {
        let seasonId: number;
        try {
          seasonId = assertPositiveInt(body.season_id);
        } catch {
          throw badRequest();
        }
        data = { student_id: await fetchLeagueCrownStudentId(seasonId) };
        break;
      }

      default:
        throw badRequest();
    }

    console.log(tagAuditLine("student-bot-api", "ok", typeof action === "string" ? action : "unknown"));
    return json({ data }, 200);
  } catch (e) {
    const { code, status } = safeError(e);
    console.log(tagAuditLine("student-bot-api", "rejected", code));
    return json({ error: code }, status);
  }
});
