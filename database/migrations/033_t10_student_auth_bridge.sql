-- =============================================================================
-- 033_t10_student_auth_bridge.sql — T10-02 (corrective)
-- (Bot 2.0, T10; SPEC_T10.md §§3.1-3.2, §4; карточка T10-02)
--
-- Зачем corrective migration: student-auth Edge Function должна идемпотентно найти/создать
-- student principal (в закрытой схеме `private`, T10-01) и строку `public.students`, а также вести
-- rate-limit в `private.security_rate_limits`. Схема `private` НЕ входит в exposed schemas Data API,
-- поэтому Edge не может писать в неё напрямую через PostgREST. Мост — две `public` SECURITY DEFINER
-- функции, доступные ТОЛЬКО роли `service_role` (Edge), revoked у anon/authenticated/public.
--
-- Доказанная необходимость (SPEC §4 «новые API-RPC»): без моста auth не может выпустить JWT с
-- `sub`=principal. Никаких политик на business-таблицах, никаких изменений экономики/бизнес-логики,
-- никаких revoke legacy-пути. auth_mode остаётся 'legacy'.
-- =============================================================================

-- --- 1. Идемпотентный upsert principal + students (concurrency-safe) -------------------------
-- Возвращает стабильный principal UUID и token_version. Гонка первого логина сериализуется
-- уникальными индексами (partial unique на principals; unique telegram_id на students):
-- конкурентные вызовы дают РОВНО один principal и одну students-строку.
create or replace function public.student_auth_upsert_principal(p_telegram_id bigint)
 returns json
 language plpgsql
 security definer
 set search_path = ''
as $function$
declare
  v_principal     uuid;
  v_token_version integer;
begin
  if p_telegram_id is null or p_telegram_id <= 0 then
    raise exception 'invalid telegram_id';
  end if;

  -- students-строка (идемпотентно; существующие не трогаются, дефолты применяются к новым)
  insert into public.students (telegram_id)
    values (p_telegram_id)
  on conflict (telegram_id) do nothing;

  -- principal (идемпотентно; partial unique index where app_role='student')
  insert into private.security_principals (app_role, telegram_id)
    values ('student', p_telegram_id)
  on conflict do nothing;

  select id, token_version
    into v_principal, v_token_version
    from private.security_principals
   where app_role = 'student' and telegram_id = p_telegram_id;

  return json_build_object('principal_id', v_principal, 'token_version', v_token_version);
end;
$function$;

-- --- 2. Fixed-window rate limit по (bucket, fingerprint) -------------------------------------
-- Возвращает true, если запрос в пределах лимита (attempts <= p_max в текущем окне), иначе false.
-- Хранилище — private.security_rate_limits (T10-01). Атомарный upsert-инкремент.
create or replace function public.security_rate_limit_hit(
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
  if p_bucket is null or p_fingerprint is null or coalesce(p_window_seconds,0) <= 0 then
    raise exception 'invalid rate limit args';
  end if;
  -- начало фиксированного окна (выравнивание по epoch)
  v_window := to_timestamp(floor(extract(epoch from clock_timestamp()) / p_window_seconds) * p_window_seconds);

  insert into private.security_rate_limits (bucket, fingerprint, window_start, attempts)
    values (p_bucket, p_fingerprint, v_window, 1)
  on conflict (bucket, fingerprint, window_start)
    do update set attempts = private.security_rate_limits.attempts + 1
  returning attempts into v_attempts;

  return v_attempts <= p_max;
end;
$function$;

-- --- 3. Явные grants: только service_role (Edge). Publishable key вызвать НЕ может ------------
revoke all on function public.student_auth_upsert_principal(bigint) from public, anon, authenticated;
revoke all on function public.security_rate_limit_hit(text, text, integer, integer) from public, anon, authenticated;
grant execute on function public.student_auth_upsert_principal(bigint) to service_role;
grant execute on function public.security_rate_limit_hit(text, text, integer, integer) to service_role;

-- =============================================================================
-- ROLLBACK:
--   drop function if exists public.student_auth_upsert_principal(bigint);
--   drop function if exists public.security_rate_limit_hit(text, text, integer, integer);
-- =============================================================================
