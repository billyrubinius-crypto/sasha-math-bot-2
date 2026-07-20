// Dev-утилита B2-T02: печатает ВАЛИДНЫЙ Telegram initData для синтетического ученика.
// BOT_TOKEN читается из env и НИКОГДА не печатается. Использование:
//   BOT_TOKEN=<...> deno run --allow-env supabase/functions/tests/make_initdata.ts [telegram_id] [auth_date_offset_sec]
// Примеры offset: 0 (сейчас), -90000 (старше 24h), 600 (в будущем > 5m).

import { _internal } from "../_shared/telegram.ts";

const enc = new TextEncoder();
const botToken = Deno.env.get("BOT_TOKEN");
if (!botToken) {
  console.error("ERROR: set BOT_TOKEN env (значение не печатается)");
  Deno.exit(1);
}

const id = Number(Deno.args[0] ?? "995000001");
const authDate = Math.floor(Date.now() / 1000) + Number(Deno.args[1] ?? "0");
const fields: Record<string, string> = {
  user: JSON.stringify({ id, first_name: "T10test" }),
  auth_date: String(authDate),
};

const dcs = Object.entries(fields).map(([k, v]) => `${k}=${v}`).sort().join("\n");
const secret = await _internal.hmacSha256(enc.encode("WebAppData"), botToken);
const hash = _internal.toHex(await _internal.hmacSha256(secret, dcs));
const usp = new URLSearchParams(fields);
usp.set("hash", hash);

console.log(usp.toString());
