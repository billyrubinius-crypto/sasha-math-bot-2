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
  return await res.json() as T;
}

export interface PrincipalResult {
  principal_id: string;
  token_version: number;
}

export function upsertStudentPrincipal(telegramId: number): Promise<PrincipalResult> {
  return callRpc<PrincipalResult>("student_auth_upsert_principal", { p_telegram_id: telegramId });
}

// true = запрос в пределах лимита.
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
