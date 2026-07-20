// _shared/errors.ts — безопасные ошибки и JSON-ответы (T10).
// Никогда не логируем initData, hash, bot token, private JWK или сам JWT. Наружу отдаём только
// стабильный машинный код, без деталей крипто-проверки (не помогаем подбирать hash/подпись).

export class AuthError extends Error {
  constructor(public code: string, public status = 401) {
    super(code);
    this.name = "AuthError";
  }
}

export function json(
  body: unknown,
  status: number,
  headers: Record<string, string> = {},
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...headers },
  });
}

export function safeError(e: unknown): { code: string; status: number } {
  if (e instanceof AuthError) return { code: e.code, status: e.status };
  return { code: "internal_error", status: 500 };
}

// Разрешённый безопасный лог: тип события + код + (опц.) telegram_id. Без секретов и payload.
export function auditLine(event: string, code: string, telegramId?: number): string {
  const id = telegramId != null ? ` tg=${telegramId}` : "";
  return `[student-auth] ${event} code=${code}${id}`;
}
