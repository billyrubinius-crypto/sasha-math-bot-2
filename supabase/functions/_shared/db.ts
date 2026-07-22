// _shared/db.ts — вызов bridge-RPC через PostgREST под service_role (T10-02, migration 033).
// service_role доступен Edge как SUPABASE_SERVICE_ROLE_KEY (инъектируется платформой). Эти RPC
// revoked у anon/authenticated, поэтому publishable key их не вызовет. Ключ наружу не отдаётся.

import { AuthError } from "./errors.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

async function callRpc<T>(name: string, args: Record<string, unknown>): Promise<T> {
  if (!SUPABASE_URL || !SERVICE_ROLE_KEY) throw new AuthError("server_misconfigured", 500);
  const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "apikey": SERVICE_ROLE_KEY,
      "Authorization": `Bearer ${SERVICE_ROLE_KEY}`,
    },
    body: JSON.stringify(args),
  });
  if (!res.ok) throw new AuthError("db_error", 500);
  // void-возвращающие RPC (teacher_session_create/security_audit) отдают пустое тело (204) —
  // тогда возвращаем null, не пытаясь распарсить JSON. Скалярные/json RPC парсятся как раньше.
  const text = await res.text();
  return (text ? JSON.parse(text) : null) as T;
}

export interface PrincipalResult {
  principal_id: string;
  token_version: number;
}

export function upsertStudentPrincipal(telegramId: number): Promise<PrincipalResult> {
  return callRpc<PrincipalResult>("student_auth_upsert_principal", { p_telegram_id: telegramId });
}

// true = запрос в пределах лимита (инкрементит счётчик окна).
export function rateLimitHit(
  bucket: string,
  fingerprint: string,
  max: number,
  windowSeconds: number,
): Promise<boolean> {
  return callRpc<boolean>("security_rate_limit_hit", {
    p_bucket: bucket,
    p_fingerprint: fingerprint,
    p_max: max,
    p_window_seconds: windowSeconds,
  });
}

// true = ещё в пределах лимита (БЕЗ инкремента) — гейт по неудачным попыткам (T10-05).
export function rateLimitPeek(
  bucket: string,
  fingerprint: string,
  max: number,
  windowSeconds: number,
): Promise<boolean> {
  return callRpc<boolean>("security_rate_limit_peek", {
    p_bucket: bucket,
    p_fingerprint: fingerprint,
    p_max: max,
    p_window_seconds: windowSeconds,
  });
}

// --- Teacher auth bridge (T10-05, migration 036; service_role only) --------------------------
export interface TeacherPrincipalResult {
  principal_id: string;
  teacher_token_version: number;
}

export function teacherUpsertPrincipal(teacherId: string): Promise<TeacherPrincipalResult> {
  return callRpc<TeacherPrincipalResult>("teacher_auth_upsert_principal", { p_teacher_id: teacherId });
}

export function teacherSessionCreate(
  principalId: string,
  familyId: string,
  refreshHash: string,
  expiresAt: string,
  tokenVersion: number,
): Promise<null> {
  return callRpc<null>("teacher_session_create", {
    p_principal_id: principalId,
    p_family_id: familyId,
    p_refresh_hash: refreshHash,
    p_expires_at: expiresAt,
    p_token_version: tokenVersion,
  });
}

export interface TeacherRotateResult {
  status: "ok" | "invalid" | "race" | "reuse" | "expired" | "version";
  principal_id?: string;
  teacher_id?: string;
  token_version?: number;
}

export function teacherSessionRotate(
  oldHash: string,
  newHash: string,
  reuseGraceSeconds: number,
): Promise<TeacherRotateResult> {
  return callRpc<TeacherRotateResult>("teacher_session_rotate", {
    p_old_hash: oldHash,
    p_new_hash: newHash,
    p_reuse_grace_seconds: reuseGraceSeconds,
  });
}

// --- Upload authorization (T10-09) ------------------------------------------------------------
// assignments.student_id — это telegram_id (FK на students.telegram_id), поэтому владение
// проверяется одним точечным запросом. Чужая/несуществующая строка даёт одинаковый ответ false.
export async function assignmentOwnedBy(telegramId: number, assignmentId: string): Promise<boolean> {
  if (!SUPABASE_URL || !SERVICE_ROLE_KEY) throw new AuthError("server_misconfigured", 500);
  const url = `${SUPABASE_URL}/rest/v1/assignments` +
    `?id=eq.${encodeURIComponent(assignmentId)}` +
    `&student_id=eq.${encodeURIComponent(String(telegramId))}&select=id&limit=1`;
  const res = await fetch(url, {
    headers: { "apikey": SERVICE_ROLE_KEY, "Authorization": `Bearer ${SERVICE_ROLE_KEY}` },
  });
  if (!res.ok) throw new AuthError("db_error", 500);
  const rows = await res.json();
  return Array.isArray(rows) && rows.length === 1;
}

// --- Student bot API: narrow service-role reads/write (T10-10A) ------------------------------
// Generic PostgREST helpers under service_role, НЕ экспортируются — вызывающий код (student-bot-api)
// видит только именованные функции ниже с зафиксированным table/select/filter. Это и есть жёсткий
// allowlist операций: секрет бота не может открыть произвольную таблицу/колонку, только то, что
// main.py уже читал/писал напрямую до T10-10A.

async function serviceRestGet<T>(path: string, params: Record<string, string>): Promise<T> {
  if (!SUPABASE_URL || !SERVICE_ROLE_KEY) throw new AuthError("server_misconfigured", 500);
  const qs = new URLSearchParams(params).toString();
  const res = await fetch(`${SUPABASE_URL}/rest/v1/${path}?${qs}`, {
    headers: { "apikey": SERVICE_ROLE_KEY, "Authorization": `Bearer ${SERVICE_ROLE_KEY}` },
  });
  if (!res.ok) throw new AuthError("db_error", 500);
  return (await res.json()) as T;
}

async function serviceRestUpsert(
  path: string,
  onConflict: string,
  body: Record<string, unknown>,
): Promise<void> {
  if (!SUPABASE_URL || !SERVICE_ROLE_KEY) throw new AuthError("server_misconfigured", 500);
  const res = await fetch(`${SUPABASE_URL}/rest/v1/${path}?on_conflict=${encodeURIComponent(onConflict)}`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "apikey": SERVICE_ROLE_KEY,
      "Authorization": `Bearer ${SERVICE_ROLE_KEY}`,
      "Prefer": "resolution=merge-duplicates",
    },
    body: JSON.stringify(body),
  });
  if (!res.ok) throw new AuthError("db_error", 500);
}

// Ровно тот же select/filter, что раньше был в main.py fetch_active_assignments() напрямую.
export interface ActiveAssignmentRow {
  student_id: number;
  type: string;
  scheduled_date: string | null;
  week_label: string | null;
  status: string;
  approval_status: string | null;
  activation_status: string;
  revision_deadline_at: string | null;
}
export function fetchActiveAssignmentsForBot(): Promise<ActiveAssignmentRow[]> {
  return serviceRestGet<ActiveAssignmentRow[]>("assignments", {
    activation_status: "in.(active,scheduled)",
    select: "student_id,type,scheduled_date,week_label,status,approval_status," +
      "activation_status,revision_deadline_at",
  });
}

export async function fetchNotificationLastSent(key: string): Promise<string | null> {
  const rows = await serviceRestGet<{ last_sent_date: string | null }[]>("bot_notification_state", {
    notification_key: `eq.${key}`,
    select: "last_sent_date",
  });
  return rows[0]?.last_sent_date ?? null;
}

export function markNotificationSent(key: string, sentDate: string): Promise<void> {
  return serviceRestUpsert("bot_notification_state", "notification_key", {
    notification_key: key,
    last_sent_date: sentDate,
  });
}

// season_id проверен на положительное целое до вызова — идёт в LIKE-фильтр напрямую.
export async function fetchAlreadyNotifiedLeagueKeys(seasonId: number): Promise<string[]> {
  const rows = await serviceRestGet<{ notification_key: string }[]>("bot_notification_state", {
    notification_key: `like.league_result:${seasonId}:*`,
    select: "notification_key",
  });
  return rows.map((r) => r.notification_key);
}

export async function fetchLatestClosedSeasonId(): Promise<number | null> {
  const rows = await serviceRestGet<{ id: number }[]>("seasons", {
    end_date: "not.is.null",
    order: "id.desc",
    limit: "1",
    select: "id",
  });
  return rows[0]?.id ?? null;
}

export interface LeagueMembershipRow {
  student_id: number;
  tier: number;
  place: number | null;
  movement: string | null;
}
export function fetchLeagueMemberships(seasonId: number): Promise<LeagueMembershipRow[]> {
  return serviceRestGet<LeagueMembershipRow[]>("league_memberships", {
    season_id: `eq.${seasonId}`,
    select: "student_id,tier,place,movement",
  });
}

export interface LeagueTierRow {
  tier: number;
  name: string;
}
export function fetchLeagueTiers(): Promise<LeagueTierRow[]> {
  return serviceRestGet<LeagueTierRow[]>("league_tiers", { select: "tier,name" });
}

export interface LeagueMovementRow {
  student_id: number;
  from_tier: number;
  to_tier: number;
  kind: string;
}
export function fetchLeagueMovements(seasonId: number): Promise<LeagueMovementRow[]> {
  return serviceRestGet<LeagueMovementRow[]>("league_movements", {
    season_id: `eq.${seasonId}`,
    select: "student_id,from_tier,to_tier,kind",
  });
}

export async function fetchLeagueCrownStudentId(seasonId: number): Promise<number | null> {
  const rows = await serviceRestGet<{ student_id: number }[]>("league_season_awards", {
    award_code: "eq.legend_crown",
    earned_season_id: `eq.${seasonId}`,
    select: "student_id",
    limit: "1",
  });
  return rows[0]?.student_id ?? null;
}

export function securityAudit(
  eventType: string,
  appRole: string | null,
  principalId: string | null,
  ipFingerprint: string | null,
  detail: Record<string, unknown> | null,
): Promise<null> {
  return callRpc<null>("security_audit", {
    p_event_type: eventType,
    p_app_role: appRole,
    p_principal_id: principalId,
    p_ip_fingerprint: ipFingerprint,
    p_detail: detail,
  });
}
