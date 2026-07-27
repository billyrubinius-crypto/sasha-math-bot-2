-- Focused dev-DB regression checks for migrations 054-055. Uses real RPC primitives.
-- The transaction is rolled back; PostgreSQL is required and this file is intentionally not run
-- by the lightweight CI checks.
begin;

do $test$
declare
  v_old bigint;
  v_cohort bigint;
  v_empty bigint := 995054001;
  v_active bigint := 995054002;
  v_late bigint := 995054003;
  v_state_before integer;
begin
  select coalesce(max(id), 0) + 1000 into v_old from public.seasons;
  insert into public.seasons (id, start_date, end_date, status)
  values (v_old, current_date - 10, current_date - 1, 'completed');
  insert into public.league_cohorts (season_id, tier, cohort_index, is_late_entry)
  values (v_old, 1, 1, false) returning id into v_cohort;
  insert into public.students (telegram_id, name, huikons, rating, lives, current_streak)
  values (v_empty, 'B3 empty', 0, 0, 3, 0),
         (v_active, 'B3 active', 0, 0, 3, 0),
         (v_late, 'B3 late', 0, 0, 3, 0);
  insert into public.student_league_state (student_id) values (v_empty), (v_active), (v_late);
  select inactive_seasons into v_state_before from public.student_league_state where student_id = v_empty;
  insert into public.league_memberships
    (season_id, cohort_id, student_id, tier, is_late_entry, activated_at)
  values (v_old, v_cohort, v_empty, 1, false, null),
         (v_old, v_cohort, v_active, 1, false, now()),
         (v_old, v_cohort, v_late, 1, true, now());
  insert into public.season_results (season_id, student_id, points, place)
  values (v_old, v_active, 10, 1), (v_old, v_late, 5, 2);

  perform public.close_league_season(v_old, null);
  if exists (select 1 from public.league_memberships where season_id = v_old and student_id = v_empty and (place is not null or movement is not null)) then
    raise exception 'FAIL: unactivated membership received settlement data';
  end if;
  if (select inactive_seasons from public.student_league_state where student_id = v_empty) is distinct from v_state_before then
    raise exception 'FAIL: unactivated membership changed inactive_seasons';
  end if;
  if not exists (select 1 from public.league_memberships where season_id = v_old and student_id = v_active and place = 1) then
    raise exception 'FAIL: activated participant did not receive a place';
  end if;
  if not exists (select 1 from public.league_memberships where season_id = v_old and student_id = v_late and place is not null) then
    raise exception 'FAIL: activated late entry was excluded from settlement';
  end if;
end
$test$;

do $test$
declare
  v_student bigint := 995055001;
  v_base bigint;
  v_missed_1 bigint;
  v_missed_2 bigint;
  v_current bigint;
  v_future bigint;
  v_season bigint;
  v_count integer;
  v_before integer;
begin
  -- Isolate the scheduler inside this rollback-only transaction.
  update public.seasons set status = 'completed', end_date = coalesce(end_date, current_date)
   where status = 'active';
  select coalesce(max(id), 0) + 1000 into v_base from public.seasons;
  v_missed_1 := v_base;
  v_missed_2 := v_base + 1;
  v_current := v_base + 2;
  v_future := v_base + 3;
  insert into public.seasons (id, title, status, start_date, end_date, starts_at, ends_at)
  values
    (v_missed_1, 'B3 missed 1', 'planned', current_date - 5, current_date - 4, now() - interval '5 days', now() - interval '4 days'),
    (v_missed_2, 'B3 missed 2', 'planned', current_date - 3, current_date - 2, now() - interval '3 days', now() - interval '2 days'),
    (v_current, 'B3 current', 'planned', current_date, current_date + 1, now() - interval '1 hour', now() + interval '1 hour'),
    (v_future, 'B3 future', 'planned', current_date + 2, current_date + 3, now() + interval '1 day', now() + interval '2 days');
  select count(*) into v_before from public.seasons;
  select public.ensure_season_schedule() into v_season;
  if v_season <> v_current then raise exception 'FAIL: scheduler returned an expired planned season'; end if;
  if (select status from public.seasons where id = v_missed_1) <> 'completed'
     or (select status from public.seasons where id = v_missed_2) <> 'completed' then
    raise exception 'FAIL: missed planned seasons were not completed in one call';
  end if;
  if (select count(*) from public.seasons) <> v_before then
    raise exception 'FAIL: scheduler created an ad-hoc season';
  end if;
  insert into public.students (telegram_id, name, huikons, rating, lives, current_streak)
  values (v_student, 'B3 enrollment', 0, 0, 3, 0);
  perform public.award_season_points(v_student, 11, 'mock_exam_season', 'b3-mock');
  select count(*) into v_count from public.league_memberships
   where season_id = v_season and student_id = v_student and activated_at is not null;
  if v_count <> 0 then raise exception 'FAIL: non-homework award activated membership'; end if;
  perform public.add_homework_season_points(v_student, 10);
  select count(*) into v_count from public.league_memberships
   where season_id = v_season and student_id = v_student and activated_at is not null;
  if v_count <> 1 then raise exception 'FAIL: homework award did not activate exactly once'; end if;
  perform public.add_homework_season_points(v_student, 10);
  if (select count(*) from public.league_memberships where season_id = v_season and student_id = v_student) <> 1 then
    raise exception 'FAIL: repeated homework created a duplicate membership';
  end if;
  update public.seasons set status = 'completed', end_date = current_date where id = v_current;
  if public.ensure_season_schedule() is not null then raise exception 'FAIL: future planned season activated early'; end if;
  begin
    perform public.add_season_points(v_student, 1);
    raise exception 'FAIL: rating was accepted during a planned pause';
  exception when sqlstate 'P0001' then null;
  end;
  if (select count(*) from public.seasons) <> v_before then raise exception 'FAIL: pause created an ad-hoc season'; end if;
end
$test$;

select 'PASS b3_fix_league_and_schedule; transaction will be rolled back' as summary;
rollback;
