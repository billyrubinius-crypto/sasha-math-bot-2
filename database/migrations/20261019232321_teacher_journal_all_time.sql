-- NULL/NULL means the complete journal history; explicit ranges retain the 93-day limit.
-- Preserve the teacher role guard, existing counters, and authenticated-only ACL.
begin;

create or replace function public.get_teacher_journal_self(p_from date, p_to date, p_student_id bigint default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $fn$
declare v_students jsonb; v_assignments jsonb; v_changes jsonb; v_exams jsonb;
begin
  if private.current_app_role() is distinct from 'teacher' then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if (p_from is null) <> (p_to is null)
     or (p_from is not null and (p_to < p_from or p_to - p_from > 92)) then
    raise exception 'invalid_period' using errcode = '22023';
  end if;
  if p_student_id is not null and not exists (select 1 from public.students where telegram_id = p_student_id) then
    raise exception 'student_not_found' using errcode = 'P0002';
  end if;

  with tasks as (
    select a.*, public.journal_assignment_status(a) as journal_status
      from public.assignments a
     where (p_from is null or public.journal_assignment_date(a) between p_from and p_to)
       and (p_student_id is null or a.student_id = p_student_id)
  ), stats as (
    select student_id, count(*) as total,
      count(*) filter (where journal_status in ('approved', 'approved_late')) as approved,
      count(*) filter (where journal_status = 'approved_late') as late,
      count(*) filter (where journal_status = 'submitted') as submitted,
      count(*) filter (where journal_status = 'missed') as missed,
      count(*) filter (where journal_status = 'revision') as revision,
      count(*) filter (where journal_status = 'planned') as planned,
      count(*) filter (where teacher_excused_at is not null and journal_status = 'approved') as excused,
      coalesce(sum(correct_task_count) filter (where journal_status in ('approved', 'approved_late')), 0) as solved,
      coalesce(sum(task_count), 0) as task_total,
      max(submitted_at) as last_upload
    from tasks group by student_id
  ) select coalesce(jsonb_agg(jsonb_build_object(
      'telegram_id', s.telegram_id::text, 'name', s.name, 'group_name', s.group_name,
      'telegram_username', s.telegram_username, 'current_streak', s.current_streak,
      'stats', coalesce(to_jsonb(t) - 'student_id', '{}'::jsonb))
      order by s.group_name nulls last, s.name, s.telegram_id), '[]'::jsonb)
    into v_students from public.students s left join stats t on t.student_id = s.telegram_id
    where p_student_id is null or s.telegram_id = p_student_id;

  if p_student_id is not null then
    select coalesce(jsonb_agg(to_jsonb(t) order by t.journal_date desc, t.created_at desc, t.id), '[]'::jsonb)
      into v_assignments from (
        select a.*, public.journal_assignment_date(a) as journal_date,
          public.journal_assignment_status(a) as journal_status,
          md5(to_jsonb(a)::text) as journal_version
        from public.assignments a where a.student_id = p_student_id
          and (p_from is null or public.journal_assignment_date(a) between p_from and p_to)
      ) t;
    select coalesce(jsonb_agg(to_jsonb(c) - 'teacher_principal' order by c.created_at desc, c.id desc), '[]'::jsonb)
      into v_changes from public.teacher_journal_changes c join public.assignments a on a.id = c.assignment_id
      where a.student_id = p_student_id and (p_from is null or public.journal_assignment_date(a) between p_from and p_to);
    select coalesce(jsonb_agg(to_jsonb(e) order by e.exam_date desc nulls last, e.created_at desc), '[]'::jsonb)
      into v_exams from public.mock_exam_results e where e.student_id = p_student_id
      and (p_from is null or coalesce(e.exam_date, (e.created_at at time zone 'Europe/Moscow')::date) between p_from and p_to);
  end if;
  return jsonb_build_object('students', v_students, 'assignments', coalesce(v_assignments, '[]'::jsonb),
    'changes', coalesce(v_changes, '[]'::jsonb), 'exams', coalesce(v_exams, '[]'::jsonb));
end;
$fn$;

revoke all on function public.get_teacher_journal_self(date,date,bigint) from public, anon;
grant execute on function public.get_teacher_journal_self(date,date,bigint) to authenticated;

commit;
