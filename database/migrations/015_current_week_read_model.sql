-- =============================================================================
-- 015_current_week_read_model.sql
-- Read-only current-week model for student/parent consumers (W07 correction).
--
-- W07 duplicated the W04/014 weekly rules in parent_bot.py because the read-only RPC
-- required by SPEC_STAGE2_5 section 10 did not exist. This function restores one server
-- contract: it derives the current MSK week directly from assignments and shield reserves,
-- returns all seven calendar slots plus N/A/S/E and weekly status, and performs no writes.
-- It does not call recalc_student_week and does not create student_week_results.
-- =============================================================================

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
  select
    a.*,
    public.is_first_submission_on_time(
      a.first_submitted_at, a.submitted_at, a.scheduled_date
    )
    and (
      coalesce(a.revision_count, 0) = 0
      or (
        a.revision_deadline_at is not null
        and a.submitted_at is not null
        and a.submitted_at <= a.revision_deadline_at
      )
    ) as attempt_on_time
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
      'revision_deadline_at', d.revision_deadline_at
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
