-- Electronic journal. Late submissions remain late; only an explicit teacher exception
-- makes an accepted daily assignment count as an on-time day. Actual upload times are kept.
-- Apply after 072. Corrections do not replay rewards or consume streak shields.
begin;

alter table public.assignments add column if not exists teacher_excused_at timestamptz;

create table public.teacher_journal_changes (
  id bigint generated always as identity primary key,
  assignment_id uuid not null references public.assignments(id) on delete cascade,
  teacher_principal uuid not null,
  reason text not null check (char_length(btrim(reason)) between 3 and 1000),
  before_state jsonb not null,
  after_state jsonb not null,
  created_at timestamptz not null default now()
);
create index teacher_journal_changes_assignment_idx
  on public.teacher_journal_changes(assignment_id, created_at desc);
alter table public.teacher_journal_changes enable row level security;
revoke all on public.teacher_journal_changes from public, anon, authenticated;
revoke all on sequence public.teacher_journal_changes_id_seq from public, anon, authenticated;

create or replace function public.journal_assignment_on_time(p_a public.assignments)
returns boolean language sql stable set search_path = public, pg_temp as $fn$
  select case when p_a.teacher_excused_at is not null
                    and p_a.status = 'checked' and p_a.approval_status = 'approved'
    then true
    else public.is_first_submission_on_time(p_a.first_submitted_at, p_a.submitted_at, p_a.scheduled_date)
      and (coalesce(p_a.revision_count, 0) = 0
        or (p_a.revision_deadline_at is not null and p_a.submitted_at is not null
            and p_a.submitted_at <= p_a.revision_deadline_at)) end;
$fn$;

create or replace function public.journal_assignment_date(p_a public.assignments)
returns date language sql stable set search_path = public, pg_temp as $fn$
  select coalesce(p_a.scheduled_date,
    case when p_a.week_label ~ '^\d{4}-\d{2}-\d{2}$' then p_a.week_label::date end,
    (p_a.created_at at time zone 'Europe/Moscow')::date);
$fn$;

create or replace function public.journal_assignment_status(p_a public.assignments)
returns text language sql stable set search_path = public, pg_temp as $fn$
  select case
    when p_a.status = 'checked' and p_a.approval_status = 'approved' then
      case when p_a.type = 'daily' and p_a.scheduled_date is not null
                 and not public.journal_assignment_on_time(p_a) then 'approved_late' else 'approved' end
    when p_a.status = 'checked' and p_a.approval_status = 'rejected' then 'revision'
    when p_a.status = 'submitted' then 'submitted'
    when public.journal_assignment_date(p_a) > (now() at time zone 'Europe/Moscow')::date
         or p_a.activation_status = 'draft' then 'planned'
    when p_a.type = 'daily' and p_a.scheduled_date < (now() at time zone 'Europe/Moscow')::date then 'missed'
    else 'assigned' end;
$fn$;

create or replace function public.get_teacher_journal_self(p_from date, p_to date, p_student_id bigint default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $fn$
declare v_students jsonb; v_assignments jsonb; v_changes jsonb; v_exams jsonb;
begin
  if private.current_app_role() is distinct from 'teacher' then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 92 then
    raise exception 'invalid_period' using errcode = '22023';
  end if;
  if p_student_id is not null and not exists (select 1 from public.students where telegram_id = p_student_id) then
    raise exception 'student_not_found' using errcode = 'P0002';
  end if;

  with tasks as (
    select a.*, public.journal_assignment_status(a) as journal_status
      from public.assignments a
     where public.journal_assignment_date(a) between p_from and p_to
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
          and public.journal_assignment_date(a) between p_from and p_to
      ) t;
    select coalesce(jsonb_agg(to_jsonb(c) - 'teacher_principal' order by c.created_at desc, c.id desc), '[]'::jsonb)
      into v_changes from public.teacher_journal_changes c join public.assignments a on a.id = c.assignment_id
      where a.student_id = p_student_id and public.journal_assignment_date(a) between p_from and p_to;
    select coalesce(jsonb_agg(to_jsonb(e) order by e.exam_date desc nulls last, e.created_at desc), '[]'::jsonb)
      into v_exams from public.mock_exam_results e where e.student_id = p_student_id
      and coalesce(e.exam_date, (e.created_at at time zone 'Europe/Moscow')::date) between p_from and p_to;
  end if;
  return jsonb_build_object('students', v_students, 'assignments', coalesce(v_assignments, '[]'::jsonb),
    'changes', coalesce(v_changes, '[]'::jsonb), 'exams', coalesce(v_exams, '[]'::jsonb));
end;
$fn$;

create or replace function public.correct_journal_assignment_self(
  p_assignment_id uuid, p_status text, p_correct_task_count integer,
  p_excuse boolean, p_reason text, p_expected_version text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $fn$
declare
  v_a public.assignments%rowtype; v_after public.assignments%rowtype;
  v_principal uuid; v_student bigint; v_week date; v_n integer; v_approved integer; v_shields integer;
  v_dates date[]; v_last date; v_streak integer;
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

    -- Restore the legacy visible series without spending shields or paying daily rewards.
    select array_agg(d order by d) into v_dates from (
      select distinct scheduled_date as d from public.assignments
        where student_id = v_a.student_id and type = 'daily' and status = 'checked'
          and approval_status = 'approved' and scheduled_date is not null
      union select bridged_date from public.streak_shield_uses where student_id = v_a.student_id
    ) days;
    select max(scheduled_date) into v_last from public.assignments
      where student_id = v_a.student_id and type = 'daily' and status = 'checked' and approval_status = 'approved';
    v_streak := 0;
    while v_last is not null and (v_last - v_streak) = any(coalesce(v_dates, '{}'::date[])) loop
      v_streak := v_streak + 1;
    end loop;
    update public.students set current_streak = v_streak, last_submission_date_msk = v_last
      where telegram_id = v_a.student_id;
  end if;
  perform public.security_audit('teacher_journal_correction', 'teacher', v_principal, null,
    jsonb_build_object('assignment_id', p_assignment_id, 'status', p_status, 'excused', p_excuse));
  return jsonb_build_object('ok', true);
end;
$fn$;

-- Internal helpers are not browser entry points.
revoke all on function public.journal_assignment_on_time(public.assignments) from public, anon, authenticated;
-- get_student_current_week is an invoker RPC under the existing student/teacher RLS.
-- This pure helper only evaluates its argument; it reads and writes no tables.
grant execute on function public.journal_assignment_on_time(public.assignments) to authenticated, service_role;
revoke all on function public.journal_assignment_date(public.assignments) from public, anon, authenticated;
revoke all on function public.journal_assignment_status(public.assignments) from public, anon, authenticated;
revoke all on function public.get_teacher_journal_self(date,date,bigint) from public, anon;
revoke all on function public.correct_journal_assignment_self(uuid,text,integer,boolean,text,text) from public, anon;
grant execute on function public.get_teacher_journal_self(date,date,bigint) to authenticated;
grant execute on function public.correct_journal_assignment_self(uuid,text,integer,boolean,text,text) to authenticated;

create or replace function public.trg_journal_exception_lifecycle()
returns trigger language plpgsql set search_path = public, pg_temp as $fn$
begin
  if new.status is distinct from 'checked' or new.approval_status is distinct from 'approved' then
    new.teacher_excused_at := null;
  end if;
  return new;
end;
$fn$;
revoke all on function public.trg_journal_exception_lifecycle() from public, anon, authenticated;
create trigger trg_journal_exception_lifecycle before update on public.assignments
  for each row execute function public.trg_journal_exception_lifecycle();

-- Shared report functions follow below; their existing ACLs are preserved.

CREATE OR REPLACE FUNCTION public.recalc_student_week(p_student_id bigint, p_week_start date)
 RETURNS public.student_week_results
 LANGUAGE plpgsql
AS $function$
declare
  v_row       public.student_week_results%rowtype;
  v_n         integer;
  v_a         integer;
  v_requested integer;
  v_consumed  integer;
  v_shields   integer;
  v_e         integer;
  v_pending   boolean;
  v_awaiting  boolean;
  v_status    text;
begin
  if p_week_start is null or extract(isodow from p_week_start) <> 1 then
    raise exception 'week_start % is not Monday', p_week_start;
  end if;

  select * into v_row from public.student_week_results
    where student_id = p_student_id and week_start = p_week_start for update;

  if found and v_row.status in ('finalized', 'neutral') then
    return v_row;
  end if;

  select
    count(*),
    count(*) filter (
      where a.status = 'checked' and a.approval_status = 'approved'
        and public.journal_assignment_on_time(a)),
    bool_or(a.status = 'submitted'
            and public.journal_assignment_on_time(a)),
    bool_or(a.status = 'checked' and a.approval_status = 'rejected'
            and a.revision_deadline_at is not null and a.revision_deadline_at > now())
  into v_n, v_a, v_pending, v_awaiting
  from public.assignments a
  where a.student_id = p_student_id
    and a.type = 'daily'
    and a.scheduled_date between p_week_start and p_week_start + 6;

  v_n := coalesce(v_n, 0);
  v_a := coalesce(v_a, 0);
  v_pending := coalesce(v_pending, false);
  v_awaiting := coalesce(v_awaiting, false);

  select count(*) filter (where status = 'requested'), count(*) filter (where status = 'consumed')
    into v_requested, v_consumed
    from public.weekly_shield_uses
   where student_id = p_student_id and week_start = p_week_start
     and not exists (select 1 from public.assignments a where a.id = assignment_id
       and a.teacher_excused_at is not null and a.status = 'checked' and a.approval_status = 'approved');

  v_requested := coalesce(v_requested, 0);
  v_consumed := coalesce(v_consumed, 0);
  v_shields := v_requested + v_consumed;
  v_e := least(v_n, v_a + v_shields, 7);

  if v_pending then
    v_status := 'pending_review';
  elsif v_awaiting then
    v_status := 'awaiting_student';
  else
    v_status := 'open';
  end if;

  insert into public.student_week_results as r
    (student_id, week_start, available_daily_count, approved_daily_count,
     requested_shields, shields_used, effective_daily_count, status)
  values
    (p_student_id, p_week_start, v_n, v_a, v_requested, v_consumed, v_e, v_status)
  on conflict (student_id, week_start) do update
    set available_daily_count = excluded.available_daily_count,
        approved_daily_count  = excluded.approved_daily_count,
        requested_shields     = excluded.requested_shields,
        shields_used          = excluded.shields_used,
        effective_daily_count = excluded.effective_daily_count,
        status                = excluded.status,
        updated_at            = now()
  returning * into v_row;

  return v_row;
end;
$function$;

CREATE OR REPLACE FUNCTION public.get_student_current_week(p_student_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
AS $function$
with params as (
  select
    (now() at time zone 'Europe/Moscow')::date as today,
    public.week_start_of((now() at time zone 'Europe/Moscow')::date) as week_start,
    now() as now_ts
),
slots as (
  select p.week_start + gs.day_index as slot_date, gs.day_index
    from params p
    cross join generate_series(0, 6) as gs(day_index)
),
daily_ranked as (
  select
    a.*,
    -- Evaluate against the actual assignments row, before adding CTE-only columns.
    public.journal_assignment_on_time(a) as attempt_on_time,
    row_number() over (
      partition by a.scheduled_date
      order by (a.plan_item_id is not null) desc, a.created_at desc, a.id desc
    ) as rn
  from public.assignments a
  cross join params p
  where a.student_id = p_student_id
    and a.type = 'daily'
    and a.scheduled_date between p.week_start and p.week_start + 6
),
daily as (
  select a.*
  from daily_ranked a
  where a.rn = 1
),
active_shields as (
  select distinct on (u.assignment_id)
    u.assignment_id,
    u.status
  from public.weekly_shield_uses u
  cross join params p
  where u.student_id = p_student_id
    and u.week_start = p.week_start
    and u.status in ('requested', 'consumed')
    and not exists (select 1 from public.assignments a where a.id = u.assignment_id
      and a.teacher_excused_at is not null and a.status = 'checked' and a.approval_status = 'approved')
  order by u.assignment_id,
           case when u.status = 'consumed' then 0 else 1 end,
           u.created_at desc
),
day_rows as (
  select
    s.day_index,
    s.slot_date,
    d.id as assignment_id,
    d.title,
    d.task_count,
    d.revision_deadline_at,
    d.teacher_excused_at,
    sh.status as shield_status,
    case
      when d.id is null then 'not_assigned'
      when sh.status is not null then 'shielded'
      when d.status = 'checked' and d.approval_status = 'approved' and d.attempt_on_time
        then 'approved'
      when d.status = 'checked' and d.approval_status = 'rejected'
           and d.revision_deadline_at is not null
           and d.revision_deadline_at > p.now_ts
        then 'revision'
      when d.status = 'submitted' then 'submitted'
      when d.status = 'assigned' and d.scheduled_date < p.today then 'missed'
      when d.status = 'assigned' then 'assigned'
      else 'missed'
    end as day_status
  from slots s
  cross join params p
  left join daily d on d.scheduled_date = s.slot_date
  left join active_shields sh on sh.assignment_id = d.id
),
daily_stats as (
  select
    count(*)::int as n,
    count(*) filter (
      where d.status = 'checked'
        and d.approval_status = 'approved'
        and d.attempt_on_time
    )::int as a,
    coalesce(bool_or(d.status = 'submitted' and d.attempt_on_time), false) as pending_review,
    coalesce(bool_or(
      d.status = 'checked'
      and d.approval_status = 'rejected'
      and d.revision_deadline_at is not null
      and d.revision_deadline_at > p.now_ts
    ), false) as awaiting_student
  from daily d
  cross join params p
),
shield_stats as (
  select count(*)::int as s from active_shields
),
totals as (
  select
    ds.n,
    ds.a,
    ss.s,
    least(ds.n, ds.a + ss.s, 7)::int as e,
    ds.pending_review,
    ds.awaiting_student
  from daily_stats ds
  cross join shield_stats ss
),
classified as (
  select
    t.*,
    case
      when t.pending_review then 'pending_review'
      when t.awaiting_student then 'awaiting_student'
      else 'open'
    end as result_status,
    case
      when t.pending_review or t.awaiting_student then 'pending'
      when t.n < 4 then 'neutral'
      when t.e >= 4 then 'successful'
      else 'weak'
    end as classification
  from totals t
),
weekly_ranked as (
  select
    a.*,
    row_number() over (
      order by (a.plan_item_id is not null) desc, a.created_at desc, a.id desc
    ) as rn
  from public.assignments a
  cross join params p
  where a.student_id = p_student_id
    and a.type = 'weekly'
    and a.week_label = p.week_start::text
),
weekly_payload as (
  select jsonb_build_object(
    'assignment_id', w.id,
    'title', w.title,
    'task_count', w.task_count,
    'status', case
      when w.status = 'assigned' then 'assigned'
      when w.status = 'submitted' then 'submitted'
      when w.status = 'checked' and w.approval_status = 'approved' then 'approved'
      when w.status = 'checked' and w.approval_status = 'rejected' then 'rejected'
      else 'unknown'
    end
  ) as payload
  from weekly_ranked w
  where w.rn = 1
),
days_payload as (
  select jsonb_agg(
    jsonb_build_object(
      'day_index', d.day_index,
      'date', d.slot_date,
      'assignment_id', d.assignment_id,
      'title', d.title,
      'task_count', d.task_count,
      'status', d.day_status,
      'shield_status', d.shield_status,
      'revision_deadline_at', d.revision_deadline_at,
      'teacher_excused_at', d.teacher_excused_at
    ) order by d.day_index
  ) as payload
  from day_rows d
)
select jsonb_build_object(
  'week_start', p.week_start,
  'week_end', p.week_start + 6,
  'n', c.n,
  'a', c.a,
  's', c.s,
  'e', c.e,
  'result_status', c.result_status,
  'classification', c.classification,
  'reward_forecast', public.weekly_reward_amount(c.e),
  'days', coalesce(dp.payload, '[]'::jsonb),
  'weekly', (select wp.payload from weekly_payload wp limit 1)
)
from params p
cross join classified c
cross join days_payload dp;
$function$;

create or replace function public.get_student_task_totals(
  p_student_id bigint,
  p_from       date default null,
  p_to         date default null)
 returns table(
   solved_tasks                 bigint,
   active_days                  bigint,
   unknown_approved_assignments bigint)
 language sql
 stable
as $function$
  with accepted as (
    select
      a.correct_task_count,
      coalesce(case when a.teacher_excused_at is not null then a.scheduled_date end, (coalesce(a.first_submitted_at, a.submitted_at) at time zone 'Europe/Moscow')::date) as date_msk
    from public.assignments a
    where a.student_id = p_student_id
      and a.status = 'checked'
      and a.approval_status = 'approved'
      and (p_from is null or coalesce(case when a.teacher_excused_at is not null then a.scheduled_date end, (coalesce(a.first_submitted_at, a.submitted_at) at time zone 'Europe/Moscow')::date) >= p_from)
      and (p_to   is null or coalesce(case when a.teacher_excused_at is not null then a.scheduled_date end, (coalesce(a.first_submitted_at, a.submitted_at) at time zone 'Europe/Moscow')::date) <= p_to)
  )
  select
    coalesce(sum(correct_task_count) filter (where correct_task_count >= 0), 0)::bigint as solved_tasks,
    count(distinct date_msk)::bigint                                                as active_days,
    count(*) filter (where correct_task_count is null)::bigint                      as unknown_approved_assignments
  from accepted;
$function$;

commit;
