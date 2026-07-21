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
