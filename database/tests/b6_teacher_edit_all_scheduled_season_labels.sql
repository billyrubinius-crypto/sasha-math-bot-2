-- Post-migration checks for 060_teacher_edit_all_scheduled_season_labels.sql.
begin;

do $test$
declare
  v_count integer;
begin
  select count(*) into v_count
    from public.seasons
   where preset_code is not null
     and display_number is not null;
  if v_count <> 22 then
    raise exception 'expected public display numbers for all 22 persisted scheduled seasons, got %', v_count;
  end if;

  if to_regclass('public.idx_seasons_v2_display_number') is not null then
    raise exception 'display number must not remain a unique identifier';
  end if;

  if pg_get_functiondef(
       'public.admin_update_scheduled_season_meta_self(text,integer,text)'::regprocedure)
       like '%interseason_has_no_number%' then
    raise exception 'scheduled interseason labels must be editable';
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
