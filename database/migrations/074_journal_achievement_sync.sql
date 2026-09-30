-- Apply after 073. Journal corrections immediately check all homework achievements.
-- Permanent achievements remain earned; new achievement rewards are paid exactly once.
-- Assignment/season/weekly payouts and life quests are not replayed.
begin;

create or replace function public.refresh_journal_homework_achievements(p_student_id bigint)
returns integer language plpgsql set search_path = public, pg_temp as $fn$
declare
  v_cutover timestamptz; v_legacy_until date; v_before integer; v_after integer;
  v_last date; v_current integer; v_max integer; v_thirty integer; v_run integer := 0;
  r record;
begin
  -- Serializes award checks with journal correction and other student reward operations.
  perform 1 from public.students where telegram_id = p_student_id for update;
  if not found then raise exception 'student_not_found' using errcode = 'P0002'; end if;
  select count(*) into v_before from public.student_achievements where student_id = p_student_id;
  select cutover_at into v_cutover from public.economy_config where id;
  v_legacy_until := coalesce((v_cutover at time zone 'Europe/Moscow')::date,
    (now() at time zone 'Europe/Moscow')::date + 1);

  if exists (select 1 from public.assignments where student_id = p_student_id
      and status = 'checked' and approval_status = 'approved') then
    perform public.grant_achievement_server(p_student_id, 'first_step', 10);
  end if;

  -- Same clean_10 rule and reward as record_approved_assignment, without its other payouts.
  if v_cutover is not null and now() >= v_cutover then
    for r in select coalesce(revision_count, 0) = 0 as clean
      from public.assignments where student_id = p_student_id
        and status = 'checked' and approval_status = 'approved'
      order by checked_at, id
    loop
      if r.clean then v_run := v_run + 1; else v_run := 0; end if;
      if v_run >= 10 then
        perform public.grant_achievement_server(p_student_id, 'clean_10', 25);
        exit;
      end if;
    end loop;
  end if;

  -- Recompute the visible daily series from on-time or explicitly excused accepted days.
  -- An ordinary late approval cannot bridge a gap. Existing shield bridges still count.
  select max(a.scheduled_date) into v_last from public.assignments a
    where a.student_id = p_student_id and a.type = 'daily' and a.scheduled_date is not null
      and a.status = 'checked' and a.approval_status = 'approved'
      and public.journal_assignment_on_time(a);
  with days as (
    select a.scheduled_date as day from public.assignments a
      where a.student_id = p_student_id and a.type = 'daily' and a.scheduled_date is not null
        and a.status = 'checked' and a.approval_status = 'approved'
        and public.journal_assignment_on_time(a)
    union select bridged_date from public.streak_shield_uses where student_id = p_student_id
  ), grouped as (
    select day, day - (row_number() over (order by day))::integer as grp from days
  ) select count(*)::integer into v_current from grouped
      where day <= v_last and grp = (select grp from grouped where day = v_last);
  update public.students set current_streak = v_current, last_submission_date_msk = v_last
    where telegram_id = p_student_id;

  -- Legacy discipline achievements apply only to the old daily economy dates.
  with days as (
    select a.scheduled_date as day from public.assignments a
      where a.student_id = p_student_id and a.type = 'daily' and a.scheduled_date < v_legacy_until
        and a.status = 'checked' and a.approval_status = 'approved'
        and public.journal_assignment_on_time(a)
    union select bridged_date from public.streak_shield_uses
      where student_id = p_student_id and bridged_date < v_legacy_until
  ), grouped as (
    select day - (row_number() over (order by day))::integer as grp from days
  ), runs as (select count(*)::integer as length from grouped group by grp)
  select coalesce(max(length), 0), count(*) filter (where length >= 30)::integer
    into v_max, v_thirty from runs;
  if v_max >= 7   then perform public.grant_achievement_server(p_student_id, 'streak_7', 25); end if;
  if v_max >= 30  then perform public.grant_achievement_server(p_student_id, 'streak_30', 100); end if;
  if v_max >= 100 then perform public.grant_achievement_server(p_student_id, 'streak_100', 300); end if;
  if v_max >= 200 then perform public.grant_achievement_server(p_student_id, 'streak_200', 500); end if;
  if v_max >= 365 then perform public.grant_achievement_server(p_student_id, 'streak_365', 1000); end if;
  if v_thirty >= 2 then perform public.grant_achievement_server(p_student_id, 'rebirth', 200); end if;

  if exists (
    select 1 from public.assignments a
      where a.student_id = p_student_id and a.type = 'daily'
        and a.scheduled_date < v_legacy_until
      group by date_trunc('month', a.scheduled_date)
      having bool_and(coalesce(a.status = 'checked' and a.approval_status = 'approved'
        and public.journal_assignment_on_time(a), false))
  ) then perform public.grant_achievement_server(p_student_id, 'perfect_month', 150); end if;

  -- Closed weeks are assessed immediately. Open weeks retain the normal finalization gate.
  if exists (select 1 from public.student_week_results where student_id = p_student_id
      and status = 'finalized' and public.weekly_economy_active(week_start)) then
    perform public.grant_weekly_achievements(p_student_id,
      public.week_start_of((now() at time zone 'Europe/Moscow')::date));
  end if;
  select count(*) into v_after from public.student_achievements where student_id = p_student_id;
  return v_after - v_before;
end;
$fn$;
revoke all on function public.refresh_journal_homework_achievements(bigint) from public, anon, authenticated;

-- Existing weekly achievement and journal gateway definitions follow below.

create or replace function public.grant_weekly_achievements(p_student_id bigint, p_week_start date)
 returns void
 language plpgsql
as $function$
declare
  r                  record;
  v_total_succ       integer := 0;
  v_run_succ         integer := 0;   -- подряд успешных (щиты разрешены)
  v_max_run_succ     integer := 0;
  v_run_succ_ns      integer := 0;   -- подряд успешных без щитов
  v_max_run_succ_ns  integer := 0;
  v_run_77ns         integer := 0;   -- подряд 7/7 без щитов
  v_max_run_77ns     integer := 0;
  v_any_good         boolean := false;
  v_any_perfect_week boolean := false;
  v_rebirth          boolean := false;
  v_prev_weak        boolean := false;
  v_is_succ          boolean;
  v_is_77            boolean;
begin
  for r in
    select approved_daily_count, shields_used, successful
      from public.student_week_results
     where student_id = p_student_id and status = 'finalized'
       and public.weekly_economy_active(week_start)
     order by week_start
  loop
    v_is_succ := coalesce(r.successful, false);
    v_is_77   := (r.approved_daily_count = 7 and r.shields_used = 0);

    if v_is_succ then
      v_total_succ := v_total_succ + 1;
      v_any_good := true;

      v_run_succ := v_run_succ + 1;
      if v_run_succ > v_max_run_succ then v_max_run_succ := v_run_succ; end if;

      if r.shields_used = 0 then
        v_run_succ_ns := v_run_succ_ns + 1;
      else
        v_run_succ_ns := 0;
      end if;
      if v_run_succ_ns > v_max_run_succ_ns then v_max_run_succ_ns := v_run_succ_ns; end if;

      -- «Возвращение»: после слабой недели — A>=5 без щитов (ECONOMY §10.1).
      if v_prev_weak and r.approved_daily_count >= 5 and r.shields_used = 0 then
        v_rebirth := true;
      end if;
    else
      v_run_succ := 0;
      v_run_succ_ns := 0;
    end if;

    if v_is_77 then
      v_any_perfect_week := true;
      v_run_77ns := v_run_77ns + 1;
      if v_run_77ns > v_max_run_77ns then v_max_run_77ns := v_run_77ns; end if;
    else
      v_run_77ns := 0;
    end if;

    v_prev_weak := not v_is_succ;   -- слабая неделя (не нейтральная, successful=false)
  end loop;

  if v_any_good              then perform public.grant_achievement_server(p_student_id, 'first_good_week', 10); end if;
  if v_any_perfect_week      then perform public.grant_achievement_server(p_student_id, 'perfect_week', 15); end if;
  if v_max_run_succ >= 4     then perform public.grant_achievement_server(p_student_id, 'rhythm_4', 25); end if;
  if v_max_run_succ >= 12    then perform public.grant_achievement_server(p_student_id, 'rhythm_12', 50); end if;
  if v_max_run_succ >= 24    then perform public.grant_achievement_server(p_student_id, 'rhythm_24', 100); end if;
  if v_total_succ >= 36      then perform public.grant_achievement_server(p_student_id, 'good_weeks_36', 150); end if;
  if v_max_run_succ_ns >= 8  then perform public.grant_achievement_server(p_student_id, 'no_shields_8', 40); end if;
  if v_max_run_77ns >= 4     then perform public.grant_achievement_server(p_student_id, 'perfect_month_weekly', 50); end if;
  if v_rebirth               then perform public.grant_achievement_server(p_student_id, 'rebirth_week', 30); end if;
end;
$function$;

create or replace function public.correct_journal_assignment_self(
  p_assignment_id uuid, p_status text, p_correct_task_count integer,
  p_excuse boolean, p_reason text, p_expected_version text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $fn$
declare
  v_a public.assignments%rowtype; v_after public.assignments%rowtype;
  v_principal uuid; v_student bigint; v_week date; v_n integer; v_approved integer; v_shields integer;
  v_achievements_awarded integer;
begin
  if private.current_app_role() is distinct from 'teacher' then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_status is null or p_status not in ('approved', 'rejected', 'assigned') or p_excuse is null then
    raise exception 'invalid_status' using errcode = '22023';
  end if;
  if p_reason is null or char_length(btrim(p_reason)) not between 3 and 1000 then
    raise exception 'reason_required' using errcode = '22023';
  end if;
  v_principal := private.current_principal();
  -- Same lock order as student submission/weekly settlement: student, then assignment.
  select student_id into v_student from public.assignments where id = p_assignment_id;
  if not found then raise exception 'assignment_not_found' using errcode = 'P0002'; end if;
  perform 1 from public.students where telegram_id = v_student for update;
  select * into v_a from public.assignments where id = p_assignment_id for update;
  if not found then raise exception 'assignment_not_found' using errcode = 'P0002'; end if;
  if p_expected_version is null or md5(to_jsonb(v_a)::text) <> p_expected_version then
    raise exception 'journal_conflict' using errcode = '40001';
  end if;
  if v_a.activation_status = 'draft' or public.journal_assignment_date(v_a) > (now() at time zone 'Europe/Moscow')::date then
    raise exception 'future_assignment' using errcode = '22023';
  end if;
  if p_excuse and (p_status <> 'approved' or v_a.type <> 'daily' or v_a.scheduled_date is null) then
    raise exception 'exception_requires_approved_daily' using errcode = '22023';
  end if;
  if p_status = 'approved' and (p_correct_task_count is null or p_correct_task_count < 0
      or p_correct_task_count > coalesce(v_a.task_count, 200)) then
    raise exception 'invalid_correct_task_count' using errcode = '22023';
  end if;

  update public.assignments set
    status = case when p_status = 'assigned' then 'assigned' else 'checked' end,
    approval_status = case when p_status = 'assigned' then null else p_status end,
    correct_task_count = case when p_status = 'approved' then p_correct_task_count end,
    teacher_feedback = btrim(p_reason), checked_at = case when p_status <> 'assigned' then now() end,
    teacher_excused_at = case when p_excuse then coalesce(v_a.teacher_excused_at, now()) end
    where id = p_assignment_id returning * into v_after;

  insert into public.teacher_journal_changes(assignment_id, teacher_principal, reason, before_state, after_state)
    values (p_assignment_id, v_principal, btrim(p_reason),
      jsonb_build_object('status', v_a.status, 'approval_status', v_a.approval_status,
        'correct_task_count', v_a.correct_task_count, 'teacher_excused_at', v_a.teacher_excused_at),
      jsonb_build_object('status', v_after.status, 'approval_status', v_after.approval_status,
        'correct_task_count', v_after.correct_task_count, 'teacher_excused_at', v_after.teacher_excused_at));

  if v_a.type = 'daily' and v_a.scheduled_date is not null then
    v_week := public.week_start_of(v_a.scheduled_date);
    perform public.recalc_student_week(v_a.student_id, v_week);
    -- Closed reports can be corrected too. Paid amounts/ledgers/finalized_at stay untouched.
    select count(*), count(*) filter (where a.status = 'checked' and a.approval_status = 'approved'
      and public.journal_assignment_on_time(a)) into v_n, v_approved
      from public.assignments a where a.student_id = v_a.student_id and a.type = 'daily'
      and a.scheduled_date between v_week and v_week + 6;
    select count(*) into v_shields from public.weekly_shield_uses
      where student_id = v_a.student_id and week_start = v_week and status in ('requested', 'consumed')
        and not exists (select 1 from public.assignments a where a.id = assignment_id
          and a.teacher_excused_at is not null and a.status = 'checked' and a.approval_status = 'approved');
    update public.student_week_results set available_daily_count = v_n, approved_daily_count = v_approved,
      effective_daily_count = least(v_n, v_approved + v_shields, 7),
      successful = case when status = 'finalized' then least(v_n, v_approved + v_shields, 7) >= 4 else successful end,
      updated_at = now()
      where student_id = v_a.student_id and week_start = v_week and status in ('finalized', 'neutral');


  end if;
  v_achievements_awarded := public.refresh_journal_homework_achievements(v_a.student_id);
  perform public.security_audit('teacher_journal_correction', 'teacher', v_principal, null,
    jsonb_build_object('assignment_id', p_assignment_id, 'status', p_status, 'excused', p_excuse, 'achievements_awarded', v_achievements_awarded));
  return jsonb_build_object('ok', true, 'achievements_awarded', v_achievements_awarded);
end;
$fn$;

-- Repair existing journal corrections using their present state, not historical approvals.
-- grant_achievement_server keeps both the badge and its reward idempotent.
do $backfill$
declare v_student bigint;
begin
  for v_student in
    select distinct a.student_id from public.teacher_journal_changes c
      join public.assignments a on a.id = c.assignment_id
      where a.student_id is not null order by a.student_id
  loop
    perform public.refresh_journal_homework_achievements(v_student);
  end loop;
end;
$backfill$;

commit;
