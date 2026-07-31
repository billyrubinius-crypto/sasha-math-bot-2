-- Post-migration checks for 061_public_season_numbering_from_zero.sql.
begin;

do $test$
declare
  v_number integer;
  v_mismatch_count integer;
  v_function text;
begin
  select s.display_number
    into v_number
    from public.seasons s
   where s.preset_code = 'ca26_02_before_start';
  if v_number is distinct from 0 then
    raise exception 'August season must be public Season №0, got %', v_number;
  end if;

  select count(*)
    into v_mismatch_count
    from public.seasons s
    join public.season_v2_presets p on p.preset_code = s.preset_code
   where p.season_type = 'regular'
     and s.display_number is distinct from p.competition_season_no;
  if v_mismatch_count <> 0 then
    raise exception '% academic season numbers do not match the approved calendar', v_mismatch_count;
  end if;

  select pg_get_functiondef(
           'public.admin_list_season_v2_self()'::regprocedure)
    into v_function;
  if lower(v_function) not like '%when p.catalog_only then null%' then
    raise exception 'catalog-only archive still exposes a public season number';
  end if;

  select pg_get_functiondef(
           'public.admin_update_scheduled_season_meta_self(text,integer,text)'::regprocedure)
    into v_function;
  if lower(v_function) not like '%between 0 and 999%' then
    raise exception 'teacher gateway does not accept Season №0';
  end if;
end;
$test$;

rollback;
