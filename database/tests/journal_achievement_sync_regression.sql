-- Run as SQL owner after 074. All fixtures/config changes are rolled back.
begin;
insert into private.security_principals(id, app_role, teacher_id)
values ('00000000-0000-4000-8000-000000007401', 'teacher', 'journal-achievement-test');
insert into public.students(telegram_id, name, group_name, huikons, rating)
values (995074001, 'Weekly achievement test', 'Journal test', 0, 0),
       (995074002, 'Clean achievement test', 'Journal test', 0, 0),
       (995074003, 'Legacy achievement test', 'Journal test', 0, 0),
       (995074004, 'Open week achievement test', 'Journal test', 0, 0),
       (995074005, 'Revision breaks clean series test', 'Journal test', 0, 0),
       (995074006, 'Full legacy achievement test', 'Journal test', 0, 0);
delete from public.assignments where student_id between 995074001 and 995074006;

do $test$
declare
  v_today date := (now() at time zone 'Europe/Moscow')::date;
  v_week date; v_old date; v_target uuid; v_version text; v_response jsonb;
  v_balance integer; v_events integer; v_count integer;
begin
  perform set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000007401","app_role":"teacher","teacher_id":"journal-achievement-test"}', true);
  -- The test transaction temporarily enables the current homework achievement rules.
  update public.economy_config set cutover_at = (v_today - 80)::timestamp at time zone 'Europe/Moscow' where id;
  v_week := public.week_start_of(v_today) - 7;
  insert into public.student_week_results(student_id, week_start, available_daily_count, approved_daily_count,
    effective_daily_count, status, successful, reward_amount, finalized_at)
  select 995074001, v_week - 7 * i, 4, case when i = 0 then 3 else 4 end,
    case when i = 0 then 3 else 4 end, 'finalized', i <> 0, 0, now()
    from generate_series(0, 3) i;
  insert into public.assignments(student_id, type, title, scheduled_date, activation_status, status,
    approval_status, task_count, correct_task_count, first_submitted_at, submitted_at, checked_at)
  select 995074001, 'daily', 'Accepted closed week day', v_week + i, 'archived', 'checked',
    'approved', 8, 8, (v_week + i)::timestamp at time zone 'Europe/Moscow',
    (v_week + i)::timestamp at time zone 'Europe/Moscow', now() from generate_series(0, 2) i;
  insert into public.assignments(student_id, type, title, scheduled_date, activation_status, status, task_count)
    values (995074001, 'daily', 'Forgiven fourth day', v_week + 3, 'archived', 'assigned', 8)
    returning id into v_target;
  select md5(to_jsonb(a)::text) into v_version from public.assignments a where id = v_target;
  v_response := public.correct_journal_assignment_self(v_target, 'approved', 7, true, 'Restore fourth successful week', v_version);
  if (v_response->>'achievements_awarded')::integer <> 3 then
    raise exception 'expected first_step, first_good_week and rhythm_4 immediately: %', v_response;
  end if;
  if not exists (select 1 from public.student_achievements where student_id = 995074001 and achievement_code = 'rhythm_4') then
    raise exception 'historical weekly series achievement missing';
  end if;
  if (select huikons from public.students where telegram_id = 995074001) <> 45 then
    raise exception 'expected exactly 10+10+25 achievement reward';
  end if;
  if exists (select 1 from public.balance_history where student_id = 995074001 and reason not like 'achievement_%')
    or (select rating from public.students where telegram_id = 995074001) <> 0
    or (select reward_amount from public.student_week_results where student_id = 995074001 and week_start = v_week) <> 0 then
    raise exception 'correction replayed assignment/season/settled week payouts';
  end if;
  select huikons into v_balance from public.students where telegram_id = 995074001;
  select count(*) into v_events from public.balance_history where student_id = 995074001;

  -- Repeat, revoke and restore: badges remain permanent and rewards cannot repeat.
  select md5(to_jsonb(a)::text) into v_version from public.assignments a where id = v_target;
  v_response := public.correct_journal_assignment_self(v_target, 'approved', 7, true, 'Repeat accepted exception', v_version);
  if (v_response->>'achievements_awarded')::integer <> 0 then raise exception 'duplicate award reported'; end if;
  select md5(to_jsonb(a)::text) into v_version from public.assignments a where id = v_target;
  perform public.correct_journal_assignment_self(v_target, 'approved', 7, false, 'Remove exception', v_version);
  if (select successful from public.student_week_results where student_id = 995074001 and week_start = v_week) then
    raise exception 'revocation did not restore a weak week';
  end if;
  if not exists (select 1 from public.student_achievements where student_id = 995074001 and achievement_code = 'rhythm_4') then
    raise exception 'earned permanent achievement was revoked';
  end if;
  select md5(to_jsonb(a)::text) into v_version from public.assignments a where id = v_target;
  perform public.correct_journal_assignment_self(v_target, 'approved', 4, true, 'Restore exception with corrected score', v_version);
  if (select solved_tasks from public.get_student_task_totals(995074001)) <> 28 then
    raise exception 'task totals do not follow corrected score';
  end if;
  if (select huikons from public.students where telegram_id = 995074001) <> v_balance
    or (select count(*) from public.balance_history where student_id = 995074001) <> v_events then
    raise exception 'repeat/revocation/restoration paid rewards again';
  end if;

  -- The tenth clean work accepted manually must grant clean_10 immediately.
  insert into public.assignments(student_id, type, title, scheduled_date, activation_status, status,
    approval_status, task_count, correct_task_count, checked_at, revision_count)
  select 995074002, 'individual', 'Clean work', v_today - i, 'active', 'checked', 'approved', 8, 8,
    now() - i * interval '1 day', 0 from generate_series(1, 9) i;
  insert into public.assignments(student_id, type, title, scheduled_date, activation_status, status, task_count)
    values (995074002, 'individual', 'Tenth clean work', v_today, 'active', 'assigned', 8) returning id into v_target;
  select md5(to_jsonb(a)::text) into v_version from public.assignments a where id = v_target;
  v_response := public.correct_journal_assignment_self(v_target, 'approved', 8, false, 'Verified tenth work on lesson', v_version);
  if (v_response->>'achievements_awarded')::integer <> 2
    or not exists (select 1 from public.student_achievements where student_id = 995074002 and achievement_code = 'clean_10')
    or (select huikons from public.students where telegram_id = 995074002) <> 35 then
    raise exception 'first_step/clean_10 synchronization failed';
  end if;

  -- A returned work still breaks clean_10; a teacher exception does not erase revision history.
  insert into public.assignments(student_id, type, title, scheduled_date, activation_status, status,
    approval_status, task_count, correct_task_count, checked_at, revision_count)
  select 995074005, 'individual', 'Clean series with revision', v_today - i, 'active', 'checked', 'approved', 8, 8,
    now() - i * interval '1 day', case when i = 5 then 1 else 0 end from generate_series(1, 10) i;
  perform public.refresh_journal_homework_achievements(995074005);
  if exists (select 1 from public.student_achievements where student_id = 995074005 and achievement_code = 'clean_10') then
    raise exception 'revision was ignored in clean_10';
  end if;

  -- Repair of an old calendar streak, without a fabricated upload or consumed shield.
  v_old := date_trunc('month', v_today - 100)::date + 5;
  insert into public.assignments(student_id, type, title, scheduled_date, activation_status, status,
    approval_status, task_count, correct_task_count, first_submitted_at, submitted_at)
  select 995074003, 'daily', 'Legacy accepted day', v_old + i, 'archived', 'checked', 'approved', 8, 8,
    (v_old + i)::timestamp at time zone 'Europe/Moscow', (v_old + i)::timestamp at time zone 'Europe/Moscow'
    from generate_series(0, 6) i where i <> 3;
  insert into public.assignments(student_id, type, title, scheduled_date, activation_status, status, task_count)
    values (995074003, 'daily', 'Legacy gap', v_old + 3, 'archived', 'assigned', 8) returning id into v_target;
  select md5(to_jsonb(a)::text) into v_version from public.assignments a where id = v_target;
  perform public.correct_journal_assignment_self(v_target, 'approved', 8, true, 'Repair old seven-day streak', v_version);
  if (select current_streak from public.students where telegram_id = 995074003) <> 7
    or not exists (select 1 from public.student_achievements where student_id = 995074003 and achievement_code = 'streak_7')
    or not exists (select 1 from public.student_achievements where student_id = 995074003 and achievement_code = 'perfect_month') then
    raise exception 'legacy streak/month achievements not synchronized';
  end if;
  if exists (select 1 from public.assignments where id = v_target and (submitted_at is not null or first_submitted_at is not null))
    or exists (select 1 from public.streak_shield_uses where student_id = 995074003) then
    raise exception 'synchronization fabricated a submission or spent a shield';
  end if;
  select huikons into v_balance from public.students where telegram_id = 995074003;
  perform public.refresh_journal_homework_achievements(995074003);
  if (select huikons from public.students where telegram_id = 995074003) <> v_balance then
    raise exception 'legacy achievement reward repeated';
  end if;

  -- Open weeks cannot earn finalized-week badges early.
  insert into public.student_week_results(student_id, week_start, available_daily_count, approved_daily_count,
    effective_daily_count, status) values (995074004, public.week_start_of(v_today), 7, 7, 7, 'open');
  perform public.refresh_journal_homework_achievements(995074004);
  if exists (select 1 from public.student_achievements where student_id = 995074004) then
    raise exception 'open week was awarded before finalization';
  end if;
  -- All-history weekly evaluation must exclude dates before the new economy boundary.
  insert into public.student_week_results(student_id, week_start, available_daily_count, approved_daily_count,
    effective_daily_count, status, successful, finalized_at)
    values (995074004, public.week_start_of(v_today - 200), 7, 7, 7, 'finalized', true, now());
  perform public.grant_weekly_achievements(995074004, public.week_start_of(v_today));
  if exists (select 1 from public.student_achievements where student_id = 995074004) then
    raise exception 'pre-cutover weeks leaked into new weekly achievements';
  end if;

  -- Exercise every weekly badge using 36 successful closed weeks after a weak one.
  delete from public.student_week_results where student_id = 995074004 and status = 'finalized';
  update public.economy_config set cutover_at = (v_today - 600)::timestamp at time zone 'Europe/Moscow' where id;
  insert into public.student_week_results(student_id, week_start, available_daily_count, approved_daily_count,
    effective_daily_count, status, successful, finalized_at)
    values (995074004, v_week - 36 * 7, 7, 3, 3, 'finalized', false, now());
  insert into public.student_week_results(student_id, week_start, available_daily_count, approved_daily_count,
    effective_daily_count, status, successful, finalized_at)
    select 995074004, v_week - i * 7, 7, 7, 7, 'finalized', true, now() from generate_series(0, 35) i;
  perform public.refresh_journal_homework_achievements(995074004);
  select count(*) into v_count from public.student_achievements where student_id = 995074004
    and achievement_code in ('first_good_week', 'perfect_week', 'rhythm_4', 'rhythm_12', 'rhythm_24',
      'good_weeks_36', 'no_shields_8', 'perfect_month_weekly', 'rebirth_week');
  -- 10 + 15 + 25 + 50 + 100 + 150 + 40 + 50 + 30 = 470.
  if v_count <> 9 or (select huikons from public.students where telegram_id = 995074004) <> 470 then
    raise exception 'weekly synchronization mismatch: badges=%, balance=% (expected 9 and 470)',
      v_count, (select huikons from public.students where telegram_id = 995074004);
  end if;
  perform public.refresh_journal_homework_achievements(995074004);
  if (select huikons from public.students where telegram_id = 995074004) <> 470 then
    raise exception 'weekly achievement synchronization duplicated rewards';
  end if;

  -- Every legacy streak threshold and the two-run rebirth achievement are covered too.
  insert into public.assignments(student_id, type, title, scheduled_date, activation_status, status,
    approval_status, task_count, correct_task_count, first_submitted_at, submitted_at)
    select 995074006, 'daily', 'Legacy full run', v_today - 1100 + i, 'archived', 'checked', 'approved', 1, 1,
      (v_today - 1100 + i)::timestamp at time zone 'Europe/Moscow',
      (v_today - 1100 + i)::timestamp at time zone 'Europe/Moscow' from generate_series(0, 364) i;
  insert into public.assignments(student_id, type, title, scheduled_date, activation_status, status,
    approval_status, task_count, correct_task_count, first_submitted_at, submitted_at)
    select 995074006, 'daily', 'Earlier legacy run', v_today - 1150 + i, 'archived', 'checked', 'approved', 1, 1,
      (v_today - 1150 + i)::timestamp at time zone 'Europe/Moscow',
      (v_today - 1150 + i)::timestamp at time zone 'Europe/Moscow' from generate_series(0, 29) i;
  perform public.refresh_journal_homework_achievements(995074006);
  select count(*) into v_count from public.student_achievements where student_id = 995074006
    and achievement_code in ('streak_7', 'streak_30', 'streak_100', 'streak_200', 'streak_365', 'rebirth', 'perfect_month');
  if v_count <> 7 or (select current_streak from public.students where telegram_id = 995074006) <> 365 then
    raise exception 'not all legacy streak achievements were synchronized';
  end if;
  select huikons into v_balance from public.students where telegram_id = 995074006;
  perform public.refresh_journal_homework_achievements(995074006);
  if (select huikons from public.students where telegram_id = 995074006) <> v_balance then
    raise exception 'high-threshold legacy rewards duplicated';
  end if;
end;
$test$;

do $test$
begin
  if has_function_privilege('anon', 'public.refresh_journal_homework_achievements(bigint)', 'execute')
    or has_function_privilege('authenticated', 'public.refresh_journal_homework_achievements(bigint)', 'execute') then
    raise exception 'internal achievement helper exposed to browser';
  end if;
end;
$test$;
select 'PASS journal achievement synchronization' as result;
rollback;
