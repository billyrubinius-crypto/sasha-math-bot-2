-- =============================================================================
-- 036_t10_teacher_auth_bridge.sql — T10-05 (teacher auth, refresh-session, audit)
-- (Bot 2.0, T10; SPEC_T10.md §3.3; карточка T10-05; foundation T10-01/032, паттерн T10-02/033)
--
-- Зачем migration (foundation недостаточен): teacher-auth / teacher-refresh Edge Functions должны
-- работать с закрытой схемой `private` (принципалы, refresh-сессии, rate limit, audit), которая НЕ
-- входит в exposed schemas Data API. Мост — public SECURITY DEFINER функции, доступные ТОЛЬКО роли
-- service_role (Edge); anon/authenticated/public их вызвать не могут. Плюс небольшая schema
-- correction private.teacher_sessions для reuse-detection (family) и kill-switch (token_version).
--
-- Ничего в поведении текущих клиентов не меняется: RLS на business-таблицах не включается, legacy
-- teacher UI (хардкод PASS) продолжает работать, auth_mode остаётся 'legacy'. Пароль/hash/refresh
-- token в SQL не хранятся и не печатаются: пароль проверяется в Edge против hash из Edge secret,
-- в БД лежит только SHA-256 hash refresh-токена.
-- =============================================================================

-- --- 0. Schema correction: private.teacher_sessions (reuse family + kill-switch version) ------
-- family_id — общий идентификатор цепочки ротаций одной сессии логина: reuse старого токена
-- отзывает всю семью. token_version — снимок глобального teacher_token_version на момент создания
-- семьи: при bump'е (kill-switch, §3.3) refresh перестаёт работать. Оба nullable-совместимы со
-- старыми (пустыми) строками foundation; новые строки всегда заполняются мостом.
alter table private.teacher_sessions add column if not exists family_id     uuid;
alter table private.teacher_sessions add column if not exists token_version integer;
create index if not exists idx_teacher_sessions_family on private.teacher_sessions (family_id);
create index if not exists idx_teacher_sessions_refresh_hash on private.teacher_sessions (refresh_token_hash);

-- --- 1. teacher_auth_upsert_principal — идемпотентный teacher principal ----------------------
-- Возвращает стабильный principal UUID и ТЕКУЩИЙ глобальный teacher_token_version (для claim и
-- для снимка в сессию). Пароль сюда НЕ передаётся: verify выполняется в Edge против hash из secret.
create or replace function public.teacher_auth_upsert_principal(p_teacher_id text)
 returns json
 language plpgsql
 security definer
 set search_path = ''
as $function$
declare
  v_principal uuid;
  v_version   integer;
begin
  if p_teacher_id is null or length(btrim(p_teacher_id)) = 0 then
    raise exception 'invalid teacher_id';
  end if;

  insert into private.security_principals (app_role, teacher_id)
    values ('teacher', p_teacher_id)
  on conflict do nothing;

  select id into v_principal
    from private.security_principals
   where app_role = 'teacher' and teacher_id = p_teacher_id;

  select teacher_token_version into v_version
    from private.security_runtime_config where id;

  return json_build_object('principal_id', v_principal, 'teacher_token_version', v_version);
end;
$function$;

-- --- 2. teacher_session_create — создать refresh-семью при логине ----------------------------
-- Edge генерирует случайный refresh token, сюда передаёт только его SHA-256 hash, свежий family_id,
-- жёсткий дедлайн семьи (login + 12h) и снимок token_version. Плейнтекст токена в БД не попадает.
create or replace function public.teacher_session_create(
  p_principal_id  uuid,
  p_family_id     uuid,
  p_refresh_hash  text,
  p_expires_at    timestamptz,
  p_token_version integer)
 returns void
 language plpgsql
 security definer
 set search_path = ''
as $function$
begin
  if p_principal_id is null or p_family_id is null or p_refresh_hash is null
     or p_expires_at is null or p_token_version is null then
    raise exception 'invalid session args';
  end if;

  insert into private.teacher_sessions
    (principal_id, family_id, refresh_token_hash, expires_at, token_version)
  values
    (p_principal_id, p_family_id, p_refresh_hash, p_expires_at, p_token_version);
end;
$function$;

-- --- 3. teacher_session_rotate — ротация refresh + reuse-detection + kill-switch -------------
-- Принимает hash предъявленного (старого) токена и hash нового, сгенерированного Edge. При успехе:
-- помечает старую строку rotated+revoked и создаёт новую (та же family, тот же дедлайн и
-- token_version), возвращает identity для нового JWT. Статусы отказа (Edge отдаёт клиенту generic):
--   invalid — hash не найден;
--   race    — токен только что ротирован (в пределах grace) => доброкачественный конкурентный
--             повтор/ретрай: отклоняем БЕЗ отзыва семьи;
--   reuse   — токен уже ротирован/отозван ранее (за пределами grace) => кража/replay: отзываем
--             ВСЮ семью;
--   expired — жёсткий дедлайн семьи (12h) достигнут => отзыв семьи;
--   version — глобальный teacher_token_version изменился (kill-switch) => отзыв семьи.
-- Конкурентная ротация одним токеном сериализуется `for update`: первый транзакт ротирует, второй
-- после снятия блокировки видит уже ротированную строку и попадает в race/reuse.
create or replace function public.teacher_session_rotate(
  p_old_hash             text,
  p_new_hash             text,
  p_reuse_grace_seconds  integer default 10)
 returns json
 language plpgsql
 security definer
 set search_path = ''
as $function$
declare
  v_row     private.teacher_sessions%rowtype;
  v_cur_ver integer;
  v_teacher text;
begin
  if p_old_hash is null or p_new_hash is null then
    raise exception 'invalid rotate args';
  end if;

  select * into v_row
    from private.teacher_sessions
   where refresh_token_hash = p_old_hash
   for update;
  if not found then
    return json_build_object('status', 'invalid');
  end if;

  -- Уже ротирован/отозван: race (в пределах grace) либо reuse (отзыв семьи).
  if v_row.revoked or v_row.rotated_at is not null then
    if v_row.rotated_at is not null
       and v_row.rotated_at > (now() - make_interval(secs => greatest(coalesce(p_reuse_grace_seconds, 0), 0))) then
      return json_build_object('status', 'race');
    end if;
    update private.teacher_sessions set revoked = true where family_id = v_row.family_id;
    return json_build_object('status', 'reuse');
  end if;

  -- Жёсткий дедлайн семьи.
  if v_row.expires_at <= now() then
    update private.teacher_sessions set revoked = true where family_id = v_row.family_id;
    return json_build_object('status', 'expired');
  end if;

  -- Kill-switch: снимок версии семьи против текущей глобальной.
  select teacher_token_version into v_cur_ver
    from private.security_runtime_config where id;
  if v_row.token_version is distinct from v_cur_ver then
    update private.teacher_sessions set revoked = true where family_id = v_row.family_id;
    return json_build_object('status', 'version');
  end if;

  -- Ротация: старую строку закрываем, новую создаём в той же семье с тем же дедлайном/версией.
  update private.teacher_sessions
     set rotated_at = now(), revoked = true
   where id = v_row.id;
  insert into private.teacher_sessions
    (principal_id, family_id, refresh_token_hash, expires_at, token_version)
  values
    (v_row.principal_id, v_row.family_id, p_new_hash, v_row.expires_at, v_row.token_version);

  select teacher_id into v_teacher
    from private.security_principals where id = v_row.principal_id;

  return json_build_object(
    'status', 'ok',
    'principal_id', v_row.principal_id,
    'teacher_id', v_teacher,
    'token_version', v_row.token_version);
end;
$function$;

-- --- 4. security_rate_limit_peek — прочитать счётчик окна БЕЗ инкремента ---------------------
-- Гейт по НЕУДАЧНЫМ попыткам (§3.3: не более 5 failures/15m): Edge peek'ает перед проверкой пароля
-- (успех не должен тратить лимит) и инкрементит существующим security_rate_limit_hit только при
-- неудаче. Окно выравнивается тем же способом, что и в hit (033). true = ещё в пределах лимита.
create or replace function public.security_rate_limit_peek(
  p_bucket          text,
  p_fingerprint     text,
  p_max             integer,
  p_window_seconds  integer)
 returns boolean
 language plpgsql
 security definer
 set search_path = ''
as $function$
declare
  v_window   timestamptz;
  v_attempts integer;
begin
  if p_bucket is null or p_fingerprint is null or coalesce(p_window_seconds, 0) <= 0 then
    raise exception 'invalid rate limit args';
  end if;
  v_window := to_timestamp(floor(extract(epoch from clock_timestamp()) / p_window_seconds) * p_window_seconds);

  select attempts into v_attempts
    from private.security_rate_limits
   where bucket = p_bucket and fingerprint = p_fingerprint and window_start = v_window;

  return coalesce(v_attempts, 0) < p_max;
end;
$function$;

-- --- 5. security_audit — запись события входа/отказа без секретов ----------------------------
-- Пишет в private.security_audit_log. Edge передаёт только тип события/роль/fingerprint/redacted
-- detail — НИКОГДА пароль, hash или refresh token.
create or replace function public.security_audit(
  p_event_type    text,
  p_app_role      text,
  p_principal_id  uuid,
  p_ip_fingerprint text,
  p_detail        jsonb default null)
 returns void
 language plpgsql
 security definer
 set search_path = ''
as $function$
begin
  if p_event_type is null then
    raise exception 'invalid audit event';
  end if;
  insert into private.security_audit_log
    (event_type, app_role, principal_id, ip_fingerprint, detail)
  values
    (p_event_type, p_app_role, p_principal_id, p_ip_fingerprint, p_detail);
end;
$function$;

-- --- 6. Явные grants: только service_role (Edge). Publishable key вызвать НЕ может ------------
revoke all on function public.teacher_auth_upsert_principal(text) from public, anon, authenticated;
revoke all on function public.teacher_session_create(uuid, uuid, text, timestamptz, integer) from public, anon, authenticated;
revoke all on function public.teacher_session_rotate(text, text, integer) from public, anon, authenticated;
revoke all on function public.security_rate_limit_peek(text, text, integer, integer) from public, anon, authenticated;
revoke all on function public.security_audit(text, text, uuid, text, jsonb) from public, anon, authenticated;
grant execute on function public.teacher_auth_upsert_principal(text) to service_role;
grant execute on function public.teacher_session_create(uuid, uuid, text, timestamptz, integer) to service_role;
grant execute on function public.teacher_session_rotate(text, text, integer) to service_role;
grant execute on function public.security_rate_limit_peek(text, text, integer, integer) to service_role;
grant execute on function public.security_audit(text, text, uuid, text, jsonb) to service_role;

-- =============================================================================
-- ROLLBACK (auth_mode legacy; клиент не переключён — откат безопасен):
--   drop function if exists public.security_audit(text, text, uuid, text, jsonb);
--   drop function if exists public.security_rate_limit_peek(text, text, integer, integer);
--   drop function if exists public.teacher_session_rotate(text, text, integer);
--   drop function if exists public.teacher_session_create(uuid, uuid, text, timestamptz, integer);
--   drop function if exists public.teacher_auth_upsert_principal(text);
--   drop index if exists private.idx_teacher_sessions_refresh_hash;
--   drop index if exists private.idx_teacher_sessions_family;
--   alter table private.teacher_sessions drop column if exists token_version;
--   alter table private.teacher_sessions drop column if exists family_id;
-- =============================================================================
