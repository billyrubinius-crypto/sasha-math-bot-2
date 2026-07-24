-- =============================================================================
-- 050_capture_username_at_student_registration.sql
--
-- student-auth already validates the complete signed Telegram user object, but
-- migration 033 passed only telegram_id to the auth bridge. The bridge therefore
-- created students before ensure_student_self could capture name/username.
--
-- This overload records Telegram identity metadata at registration. Existing
-- non-empty values are intentionally immutable: a later Telegram username
-- change must not silently break the username maintained in Google Sheets.
-- Rows created by the broken auth path are repaired once on their next login.
--
-- The original bigint-only overload stays temporarily for rollout compatibility
-- with an already deployed student-auth version.
-- =============================================================================

create or replace function public.student_auth_upsert_principal(
  p_telegram_id bigint,
  p_name text,
  p_telegram_username text
)
returns json
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_principal uuid;
  v_token_version integer;
begin
  if p_telegram_id is null or p_telegram_id <= 0 then
    raise exception 'invalid telegram_id';
  end if;

  insert into public.students (
    telegram_id,
    name,
    telegram_username
  )
  values (
    p_telegram_id,
    nullif(btrim(p_name), ''),
    nullif(btrim(p_telegram_username), '')
  )
  on conflict (telegram_id) do update
  set
    name = case
      when public.students.name is null or btrim(public.students.name) = ''
        then excluded.name
      else public.students.name
    end,
    telegram_username = case
      when public.students.telegram_username is null
        or btrim(public.students.telegram_username) = ''
        then excluded.telegram_username
      else public.students.telegram_username
    end;

  insert into private.security_principals (app_role, telegram_id)
  values ('student', p_telegram_id)
  on conflict do nothing;

  select id, token_version
    into v_principal, v_token_version
    from private.security_principals
   where app_role = 'student'
     and telegram_id = p_telegram_id;

  return json_build_object(
    'principal_id', v_principal,
    'token_version', v_token_version
  );
end;
$function$;

revoke all on function public.student_auth_upsert_principal(bigint, text, text)
  from public, anon, authenticated;

grant execute on function public.student_auth_upsert_principal(bigint, text, text)
  to service_role;
