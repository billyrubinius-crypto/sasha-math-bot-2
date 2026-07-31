-- Post-migration checks for 067_current_season_public_number.sql.
begin;

do $test$
declare
  v_number   integer;
  v_function text;
begin
  select s.display_number
    into v_number
    from public.seasons s
   where s.preset_code = 'ca26_02_before_start';

  if v_number is distinct from 0 then
    raise exception 'Current August season must be public Season №0, got %', v_number;
  end if;

  if exists (
    select 1
      from public.seasons s
     where (s.preset_code = 'ca26_01_summer_practice' or s.sequence_no = 1)
       and s.display_number is not null
  ) then
    raise exception 'Catalog archive must not occupy a public season number';
  end if;

  select pg_get_functiondef(
           'public.get_student_league_snapshot_self()'::regprocedure)
    into v_function;

  if lower(v_function) not like '%season_display_number%' then
    raise exception 'League snapshot does not expose the public season number';
  end if;
end;
$test$;

rollback;
