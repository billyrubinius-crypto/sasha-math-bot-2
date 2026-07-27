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
  v_season bigint;
  v_count integer;
begin
  select public.ensure_season_schedule() into v_season;
  if v_season is not null then
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
  end if;
end
$test$;

-- In an isolated dev database also exercise a pause and multiple missed planned windows:
-- create consecutive expired planned seasons plus one current window, call
-- ensure_season_schedule(), assert the expired rows are completed and only the current row is
-- active; then create a future-only plan and assert require_current_season_id() raises
-- no_active_season. This must be run after isolating existing seasonal data.

select 'PASS b3_fix_league_and_schedule; transaction will be rolled back' as summary;
rollback;
