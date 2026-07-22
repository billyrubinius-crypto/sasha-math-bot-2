// _shared/cors.ts — строгий origin/CORS allowlist (T10).
// ALLOWED_ORIGINS — запятая-разделённый список точных origin'ов Mini App (owner задаёт как Edge
// secret). Пустой список => все браузерные origin'ы отклоняются. Echo только разрешённого origin.

const RAW = Deno.env.get("ALLOWED_ORIGINS") ?? "";
export const ALLOWLIST: string[] = RAW.split(",").map((s) => s.trim()).filter(Boolean);

export function originAllowed(origin: string | null): boolean {
  return !!origin && ALLOWLIST.includes(origin);
}

export function corsHeaders(origin: string | null): Record<string, string> {
  return {
    "Access-Control-Allow-Origin": originAllowed(origin) ? origin! : "null",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    // authorization нужен функциям, которые принимают уже выпущенный JWT (sign-upload, T10-09).
    "Access-Control-Allow-Headers": "content-type, authorization",
    "Access-Control-Max-Age": "600",
    "Vary": "Origin",
  };
}
