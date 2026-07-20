# student-auth — Telegram student-auth Edge Function (T10-02)

Параллельный auth-endpoint: проверяет Telegram `initData` и выпускает 60-минутный **ES256 JWT**.
Клиент им ещё **не пользуется** (переключение — T10-03); `auth_mode` остаётся `legacy`.

## Файлы

- `index.ts` — HTTP-обработчик (origin allowlist, bounded body, rate limit, валидация, выпуск JWT).
- `../_shared/telegram.ts` — HMAC-SHA256 валидация initData (24h / 5m, constant-time, strict user.id).
- `../_shared/jwt.ts` — ES256 подпись из imported private JWK; `kid` берётся из JWK.
- `../_shared/db.ts` — вызов bridge-RPC (migration 033) под service_role.
- `../_shared/cors.ts`, `../_shared/errors.ts` — origin allowlist, безопасные ошибки (без секретов в логе).
- `../tests/*_test.ts` — unit-тесты; `../tests/make_initdata.ts` — генератор валидного initData для B2-T02.

## Требуются действия пользователя (dev)

### 1. Применить corrective migration 033
`033_t10_student_auth_bridge.sql` на dev (SQL editor или `supabase db push`). Создаёт
`public.student_auth_upsert_principal` и `public.security_rate_limit_hit` (SECURITY DEFINER,
`service_role` only). `auth_mode` не трогается.

### 2. Задать Edge secrets (значения не вставлять в чат/лог/git)
```
supabase secrets set BOT_TOKEN=<student bot token>
supabase secrets set ALLOWED_ORIGINS=<https://<mini-app-origin>[,<второй>]>
# private JWK уже задан в T10-01 как T10_JWT_PRIVATE_JWK
# На Windows передавать JWK как Base64 одной строкой: helper принимает raw JSON и Base64.
# (опционально) supabase secrets set JWT_ISS=<https://<ref>.supabase.co/auth/v1>
```
`SUPABASE_URL` и `SUPABASE_SERVICE_ROLE_KEY` инъектируются платформой автоматически.

### 3. Deploy (endpoint публичный — без JWT-гейта)
```
supabase functions deploy student-auth --no-verify-jwt
```

### 4. Unit-тесты (локально, без сети)
```
deno test supabase/functions/tests/
```
Ожидаемо: все PASS (валидный fixture, bad hash, changed user, missing/duplicate hash, old/future
auth_date, malformed user, retry; ES256 sign верифицируется публичным ключом, header c kid).

## B2-T02 — интеграционные проверки (dev, синтетические ID ≥ 995000000)

**Рекомендуется (Windows, без ручной работы с токеном):** PowerShell-harness
[`../tests/run_b2_t02.ps1`](../tests/run_b2_t02.ps1) — скрытый ввод BOT_TOKEN, все кейсы,
JWT-verify против JWKS, concurrency, итоговая таблица PASS/FAIL. Не печатает BOT_TOKEN/initData/
hash/полный JWT, не использует service-role, cleanup-SQL выводит отдельно. Запуск:
```
.\supabase\functions\tests\run_b2_t02.ps1 -FunctionUrl "https://<ref>.functions.supabase.co/student-auth" -Origin "https://<mini-app-origin>" -Kid "<current-kid>"
```

**Альтернатива (bash/curl, ручная):** генерация валидного initData (BOT_TOKEN только в env, не печатается):
```
export FN=https://<ref>.functions.supabase.co/student-auth
export ORIGIN=<один из ALLOWED_ORIGINS>
GOOD=$(BOT_TOKEN=<...> deno run --allow-env supabase/functions/tests/make_initdata.ts 995000001 0)
```

| # | Кейс | Команда (сокр.) | Ожидание |
|--:|---|---|---|
| 1 | valid fixture | `curl -H "Origin:$ORIGIN" -d "{\"initData\":\"$GOOD\"}" $FN` | 200 + `access_token` |
| 2 | retry same initData | тот же запрос повторно | 200; тот же principal/student (не дублируется) |
| 3 | bad hash | заменить hash на нули | 401 `bad_hash` |
| 4 | changed user | подменить `user=` после подписи | 401 `bad_hash` |
| 5 | missing hash | initData без `hash` | 401 `bad_hash` |
| 6 | duplicate hash | добавить второй `&hash=` | 401 `bad_hash` |
| 7 | old auth_date | `make_initdata.ts 995000002 -90000` | 401 `expired_auth_date` |
| 8 | future auth_date | `make_initdata.ts 995000002 600` | 401 `future_auth_date` |
| 9 | malformed user | вручную битый `user=` + пересчитанный hash | 401 `malformed_user` |
| 10 | oversized body | `initData` > 8 КБ | 400/413 |
| 11 | wrong origin | `Origin: https://evil.example` | 403 `origin_not_allowed` |
| 12 | JWT signature/JWKS | декодировать `access_token`; header.kid == current kid; verify против `/.well-known/jwks.json` | verify OK |
| 13 | claims/expiry | payload: `role=authenticated`, `app_role=student`, `sub`=UUID, `telegram_id="995000001"`, `aud=authenticated`, `exp-iat=3600` | как ожидается |
| 14 | concurrent first login | 5–10 параллельных запросов новым синтетическим ID | ровно один principal и одна students-строка |

Проверка «один principal» после (2)/(14) — под service_role:
```sql
select count(*) from private.security_principals where app_role='student' and telegram_id=995000001; -- 1
select count(*) from public.students where telegram_id=995000001;                                     -- 1
```

## Очистка dev после B2-T02 (обязательно)
```sql
delete from private.security_principals where telegram_id >= 995000000;
delete from public.students             where telegram_id >= 995000000;
delete from private.security_rate_limits where bucket='student_auth';
```

## Безопасность
- BOT_TOKEN, private JWK, service role key, сам JWT и initData/hash **не логируются** и не попадают в git.
- `auth_mode` остаётся `legacy`; браузерный клиент не менялся — legacy-путь работает как прежде.
- RPC моста доступны только `service_role`; publishable key их вызвать не может.
