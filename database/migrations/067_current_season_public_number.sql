-- Keep the public calendar independent from immutable database ids and catalog codes:
-- archived sequence 1 has no number, August sequence 2 is Season №0.

begin;

alter table public.seasons drop constraint if exists seasons_display_number_check;
alter table public.seasons add constraint seasons_display_number_check
  check (display_number is null or display_number between 0 and 999);

update public.seasons
   set display_number = null,
       updated_at = now()
 where preset_code = 'ca26_01_summer_practice'
    or sequence_no = 1;

update public.seasons
   set display_number = 0,
       updated_at = now()
 where preset_code = 'ca26_02_before_start'
    or sequence_no = 2;

-- The student league read model now exposes the editable public number too. The
-- internal season_id remains present for compatibility, but the UI never labels
-- the current season with that id.
create or replace function public.get_student_league_snapshot_self()
 returns json
 language plpgsql
 stable
 security definer
 set search_path = public, pg_temp
as $function$
declare
  v_tid            bigint;
  v_snapshot       jsonb;
  v_display_number integer;
begin
  if private.current_app_role() is distinct from 'student' then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  v_tid := private.current_telegram_id();
  if v_tid is null or v_tid <= 0 then
    raise exception 'no student identity' using errcode = '42501';
  end if;

  v_snapshot := public.get_student_league_snapshot(v_tid)::jsonb;

  if v_snapshot ->> 'season_id' is not null then
    select s.display_number
      into v_display_number
      from public.seasons s
     where s.id = (v_snapshot ->> 'season_id')::bigint;
  end if;

  return (
    v_snapshot
    || jsonb_build_object('season_display_number', v_display_number)
  )::json;
end;
$function$;

revoke all on function public.get_student_league_snapshot_self() from public, anon;
grant execute on function public.get_student_league_snapshot_self() to authenticated;

commit;
