-- Run as SQL owner after migrations 072 and 073; synthetic data is rolled back.
begin;

insert into private.security_principals(id, app_role, teacher_id)
values ('00000000-0000-4000-8000-000000007301', 'teacher', 'journal-regression');
insert into public.students(telegram_id, name, group_name, huikons, rating, current_streak)
values (995073001, 'Journal regression', 'Journal test', 123, 456, 1);
-- The student-insert trigger may materialize existing plans for the synthetic pupil.
-- Clear only this pupil's generated tasks so they cannot outrank the test fixtures.
delete from public.assignments where student_id = 995073001;

do $test$
declare
  v_today date := (now() at time zone 'Europe/Moscow')::date;
  v_id uuid; v_late uuid; v_old uuid; v_version text; v_week date;
  v_a public.assignments%rowtype; v_read jsonb; v_before integer; v_count integer;
begin
  perform set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000007301","app_role":"teacher","teacher_id":"journal-regression"}', true);
  insert into public.assignments(student_id, type, title, scheduled_date, activation_status,
    status, approval_status, task_count, correct_task_count, first_submitted_at, submitted_at)
  select 995073001, 'daily', 'Accepted neighbour', day, 'active', 'checked', 'approved', 8, 8,
    (day::timestamp + interval '12 hours') at time zone 'Europe/Moscow',
    (day::timestamp + interval '12 hours') at time zone 'Europe/Moscow'
  from (values (v_today - 2), (v_today)) dates(day);

  insert into public.assignments(student_id, type, title, scheduled_date, activation_status, status, task_count)
    values (995073001, 'daily', 'Past day without upload', v_today - 1, 'archived', 'assigned', 8)
    returning id into v_id;
  select * into v_a from public.assignments where id = v_id;
  v_version := md5(to_jsonb(v_a)::text);
  if public.journal_assignment_status(v_a) <> 'missed' then raise exception 'past day must start missed'; end if;

  -- Approving a late upload normally must still leave its cross in the daily report.
  insert into public.assignments(student_id, type, title, scheduled_date, activation_status,
    status, approval_status, task_count, correct_task_count, first_submitted_at, submitted_at)
    values (995073001, 'daily', 'Ordinary late approval', v_today - 5, 'archived',
      'checked', 'approved', 8, 6, now(), now()) returning id into v_late;
  select * into v_a from public.assignments where id = v_late;
  if public.journal_assignment_on_time(v_a) or public.journal_assignment_status(v_a) <> 'approved_late' then
    raise exception 'ordinary late approval was implicitly forgiven';
  end if;

  select count(*) into v_before from public.balance_history where student_id = 995073001
    and reason not like 'achievement_%';
  perform public.correct_journal_assignment_self(v_id, 'approved', 7, true, 'Checked on lesson; teacher exception', v_version);
  select * into v_a from public.assignments where id = v_id;
  if v_a.photo_url is not null or v_a.submitted_at is not null or v_a.first_submitted_at is not null then
    raise exception 'exception fabricated an upload or upload time';
  end if;
  if v_a.teacher_excused_at is null or not public.journal_assignment_on_time(v_a)
      or public.journal_assignment_status(v_a) <> 'approved' then raise exception 'exception did not replace the cross'; end if;
  if (select current_streak from public.students where telegram_id = 995073001) <> 3 then
    raise exception 'exception failed to restore the three-day series';
  end if;
  if (select count(*) from public.balance_history where student_id = 995073001
        and reason not like 'achievement_%') <> v_before
      or (select huikons from public.students where telegram_id = 995073001) <> 123 +
        (select coalesce(sum(change_amount), 0) from public.balance_history where student_id = 995073001
          and reason like 'achievement_%')
      or (select rating from public.students where telegram_id = 995073001) <> 456 then
    raise exception 'correction unexpectedly replayed rewards';
  end if;
  if (select count(*) from public.teacher_journal_changes where assignment_id = v_id) <> 1 then
    raise exception 'missing correction history';
  end if;
  v_read := public.get_teacher_journal_self(v_today - 10, v_today, 995073001);
  if not exists (select 1 from jsonb_array_elements(v_read->'assignments') a where a->>'id' = v_id::text) then
    raise exception 'historical assignment disappeared from journal';
  end if;
  if extract(isodow from v_today) > 1 then
    v_read := public.get_student_current_week(995073001);
    if not exists (select 1 from jsonb_array_elements(v_read->'days') d where d->>'assignment_id' = v_id::text
        and d->>'status' = 'approved' and d->>'teacher_excused_at' is not null) then
      raise exception 'student week still displays a cross';
    end if;
  end if;
  if (select solved_tasks from public.get_student_task_totals(995073001, v_today - 1, v_today - 1)) <> 7 then
    raise exception 'teacher-accepted work missing from task totals';
  end if;

  begin
    perform public.correct_journal_assignment_self(v_id, 'approved', 7, true, 'Stale retry', v_version);
    raise exception 'stale version accepted';
  exception when serialization_failure then null; end;
  v_version := md5(to_jsonb(v_a)::text);
  begin
    perform public.correct_journal_assignment_self(v_id, 'approved', 9, true, 'Invalid count', v_version);
    raise exception 'excess task count accepted';
  exception when invalid_parameter_value then null; end;
  begin
    perform public.correct_journal_assignment_self(v_id, 'approved', 7, true, '', v_version);
    raise exception 'empty reason accepted';
  exception when invalid_parameter_value then null; end;

  -- Removing the exception restores the normal deadline result, without deleting history.
  perform public.correct_journal_assignment_self(v_id, 'approved', 7, false, 'Revoke teacher exception', v_version);
  select * into v_a from public.assignments where id = v_id;
  if public.journal_assignment_on_time(v_a) or public.journal_assignment_status(v_a) <> 'approved_late' then
    raise exception 'revoking exception did not restore default rule';
  end if;
  v_version := md5(to_jsonb(v_a)::text);
  perform public.correct_journal_assignment_self(v_id, 'approved', 7, true, 'Restore exception', v_version);
  -- Ordinary review rejection clears the exception so it cannot return on a later approval.
  update public.assignments set status = 'checked', approval_status = 'rejected' where id = v_id;
  if (select teacher_excused_at from public.assignments where id = v_id) is not null then
    raise exception 'rejected work retained an active exception';
  end if;

  -- A closed weekly report changes academically but keeps its settled reward.
  v_week := public.week_start_of(v_today) - 14;
  insert into public.assignments(student_id, type, title, scheduled_date, activation_status, status, task_count)
    values (995073001, 'daily', 'Closed week exception', v_week, 'archived', 'assigned', 8)
    returning id into v_old;
  insert into public.student_week_results(student_id, week_start, available_daily_count, status, successful, reward_amount, finalized_at)
    values (995073001, v_week, 1, 'finalized', false, 25, now());
  select md5(to_jsonb(a)::text) into v_version from public.assignments a where id = v_old;
  perform public.correct_journal_assignment_self(v_old, 'approved', 8, true, 'Historical exception', v_version);
  if not exists (select 1 from public.student_week_results where student_id = 995073001 and week_start = v_week
    and approved_daily_count = 1 and effective_daily_count = 1 and status = 'finalized' and reward_amount = 25) then
    raise exception 'closed report or settled reward was lost';
  end if;
  begin
    perform public.get_teacher_journal_self(v_today - 93, v_today);
    raise exception 'unbounded period accepted';
  exception when invalid_parameter_value then null; end;
end;
$test$;

-- Check the real authenticated ACL and role guard, not only owner execution.
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000007301","app_role":"student","telegram_id":"995073001"}', true);
do $test$
begin
  begin
    perform public.get_teacher_journal_self(current_date - 1, current_date);
    raise exception 'student accessed teacher journal';
  exception when insufficient_privilege then null; end;
  begin
    perform public.correct_journal_assignment_self(gen_random_uuid(), 'approved', 1, true, 'Student attempted override', 'invalid');
    raise exception 'student forged an exception';
  exception when insufficient_privilege then null; end;
  begin
    perform 1 from public.teacher_journal_changes;
    raise exception 'student read private correction history';
  exception when insufficient_privilege then null; end;
  perform public.get_student_current_week(995073001);
end;
$test$;
reset role;

do $test$
begin
  if has_function_privilege('anon', 'public.get_teacher_journal_self(date,date,bigint)', 'execute')
     or has_function_privilege('anon', 'public.correct_journal_assignment_self(uuid,text,integer,boolean,text,text)', 'execute') then
    raise exception 'anonymous journal access';
  end if;
end;
$test$;
select 'PASS teacher journal regression' as result;
rollback;
