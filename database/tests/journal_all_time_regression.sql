-- Synthetic fixtures only. Everything is rolled back, including student triggers.
begin;
insert into private.security_principals(id, app_role, teacher_id)
values ('00000000-0000-4000-8000-000000007501', 'teacher', 'journal-all-time-regression');
insert into public.students(telegram_id, name, group_name)
values (995075001, 'Journal all-time regression', 'Journal test');
delete from public.assignments where student_id = 995075001;

do $test$
declare
  v_today date := (now() at time zone 'Europe/Moscow')::date;
  v_id uuid; v_read jsonb; v_stats jsonb;
begin
  insert into public.assignments(student_id, type, title, scheduled_date, activation_status,
    status, approval_status, task_count, correct_task_count, submitted_at, first_submitted_at)
  select 995075001, 'daily', 'All-time fixture', day, 'archived', 'checked', 'approved', 8, 7,
    (day::timestamp + interval '12 hours') at time zone 'Europe/Moscow',
    (day::timestamp + interval '12 hours') at time zone 'Europe/Moscow'
  from (values (v_today - 400), (v_today - 100), (v_today - 1)) dates(day);
  select id into v_id from public.assignments where student_id = 995075001 order by scheduled_date limit 1;
  insert into public.teacher_journal_changes(assignment_id, teacher_principal, reason, before_state, after_state)
  values (v_id, '00000000-0000-4000-8000-000000007501', 'Historical fixture', '{}', '{}');
  insert into public.mock_exam_results(student_id, exam_name, score, exam_date)
  values (995075001, 'All-time historical mock', '70', v_today - 400);
end;
$test$;

-- Exercise the same authenticated role as PostgREST, using a synthetic teacher.
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000007501","app_role":"teacher","teacher_id":"journal-all-time-regression"}', true);
do $test$
declare
  v_today date := (now() at time zone 'Europe/Moscow')::date;
  v_read jsonb; v_stats jsonb;
begin
  v_read := public.get_teacher_journal_self(null, null);
  select s->'stats' into v_stats from jsonb_array_elements(v_read->'students') s
    where s->>'telegram_id' = '995075001';
  if (v_stats->>'total')::integer <> 3 or (v_stats->>'solved')::integer <> 21
     or (v_stats->>'task_total')::integer <> 24 then raise exception 'all-time roster lost old work'; end if;
  v_read := public.get_teacher_journal_self(null, null, 995075001);
  if jsonb_array_length(v_read->'students') <> 1 or jsonb_array_length(v_read->'assignments') <> 3
     or jsonb_array_length(v_read->'changes') <> 1 or jsonb_array_length(v_read->'exams') <> 1 then
    raise exception 'all-time detail differs from roster or omitted historical records';
  end if;
  if (v_read->'changes'->0) ? 'teacher_principal' then raise exception 'private principal leaked'; end if;
  v_read := public.get_teacher_journal_self(v_today - 29, v_today, 995075001);
  if jsonb_array_length(v_read->'assignments') <> 1 or jsonb_array_length(v_read->'exams') <> 0
     or jsonb_array_length(v_read->'changes') <> 0
     or (v_read->'students'->0->'stats'->>'total')::integer <> 1 then
    raise exception 'explicit range did not filter all sections';
  end if;
  begin
    perform public.get_teacher_journal_self(null, v_today);
    raise exception 'one-sided null accepted';
  exception when invalid_parameter_value then null; end;
  begin
    perform public.get_teacher_journal_self(v_today, null);
    raise exception 'one-sided null accepted';
  exception when invalid_parameter_value then null; end;
  begin
    perform public.get_teacher_journal_self(v_today - 93, v_today);
    raise exception 'oversized explicit range accepted';
  exception when invalid_parameter_value then null; end;
  begin
    perform public.get_teacher_journal_self(v_today, v_today - 1);
    raise exception 'reversed range accepted';
  exception when invalid_parameter_value then null; end;
end;
$test$;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000007501","app_role":"student","telegram_id":"995075001"}', true);
do $test$
begin
  begin
    perform public.get_teacher_journal_self(null, null);
    raise exception 'student accessed all-time journal';
  exception when insufficient_privilege then null; end;
end;
$test$;
reset role;
do $test$
begin
  if has_function_privilege('anon', 'public.get_teacher_journal_self(date,date,bigint)', 'execute') then
    raise exception 'anonymous journal access';
  end if;
end;
$test$;
select 'PASS journal all-time regression' as result;
rollback;
