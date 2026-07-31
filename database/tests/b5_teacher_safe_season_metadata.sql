-- Post-migration checks for 059_teacher_safe_season_metadata.sql.
begin;

do $test$
declare
  v_count integer;
begin
  select count(*) into v_count
    from public.seasons s
    join public.season_v2_presets p on p.preset_code = s.preset_code
   where p.season_type = 'regular'
     and s.display_number is not null;
  if v_count <> 21 then
    raise exception 'expected display numbers for 21 regular seasons, got %', v_count;
  end if;

  if exists (
    select 1
      from public.seasons s
      join public.season_v2_presets p on p.preset_code = s.preset_code
     where p.season_type = 'interseason'
       and s.display_number is not null
  ) then
    raise exception 'interseason periods must not have display numbers';
  end if;

  if exists (
    select display_number
      from public.seasons
     where preset_code is not null and display_number is not null
     group by display_number
    having count(*) > 1
  ) then
    raise exception 'regular season display numbers must be unique';
  end if;

  if to_regprocedure(
       'public.admin_update_scheduled_season_meta_self(text,integer,text)') is null then
    raise exception 'safe teacher metadata RPC is missing';
  end if;

  if has_function_privilege(
       'authenticated',
       'public.admin_save_season_v2_self(text,text,text,timestamptz,timestamptz,jsonb,boolean)',
       'EXECUTE') then
    raise exception 'authenticated must not execute full Season V2 mutation';
  end if;

  if has_function_privilege(
       'authenticated',
       'public.close_season_self()',
       'EXECUTE') then
    raise exception 'authenticated must not close a season manually';
  end if;

  if not has_function_privilege(
       'authenticated',
       'public.admin_update_scheduled_season_meta_self(text,integer,text)',
       'EXECUTE') then
    raise exception 'authenticated teacher gateway grant is missing';
  end if;
end;
$test$;

rollback;
