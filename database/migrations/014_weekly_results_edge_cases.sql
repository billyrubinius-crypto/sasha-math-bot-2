-- =============================================================================
-- 014_weekly_results_edge_cases.sql
-- Corrective migration for W04 after review of migration 012.
--
-- Fixes three server-side edge cases without rewriting applied migration 012:
--   1. A daily first submitted before its scheduled_date is not on time.
--   2. An approved resubmission counts in A only when the current attempt was submitted
--      inside the active revision_deadline_at.
--   3. Batch finalization discovers due materialized Bot 2.0 daily assignments even when
--      no client/RPC has created student_week_results yet.
--
-- Legacy rows are not backfilled. Headless discovery is limited to rows with plan_item_id,
-- so calling the batch function cannot turn the historical legacy archive into weekly
-- results. Existing explicitly created student_week_results remain eligible as before.
-- Rewards and Cron are still disabled until W09.
-- =============================================================================

-- "In its scheduled_date" is strict equality in MSK. Future daily assignments are already
-- materialized by W01, so <= would let an early direct submission count as on time.
CREATE OR REPLACE FUNCTION public.is_first_submission_on_time(
  p_first_submitted_at timestamptz,
  p_submitted_at       timestamptz,
  p_scheduled_date     date
)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select coalesce(p_first_submitted_at, p_submitted_at) is not null
     and p_scheduled_date is not null
     and (coalesce(p_first_submitted_at, p_submitted_at) at time zone 'Europe/Moscow')::date
         = p_scheduled_date;
$function$;

-- Recalculate one week. For an approved daily, the first submission must be on its own day.
-- If at least one revision was requested, the currently approved attempt must additionally
-- have been submitted no later than the latest server-issued revision deadline.
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
      where a.status = 'checked'
        and a.approval_status = 'approved'
        and public.is_first_submission_on_time(
              a.first_submitted_at, a.submitted_at, a.scheduled_date)
        and (
          coalesce(a.revision_count, 0) = 0
          or (
            a.revision_deadline_at is not null
            and a.submitted_at is not null
            and a.submitted_at <= a.revision_deadline_at
          )
        )),
    bool_or(a.status = 'submitted'
            and public.is_first_submission_on_time(
                  a.first_submitted_at, a.submitted_at, a.scheduled_date)
            and (
              coalesce(a.revision_count, 0) = 0
              or (
                a.revision_deadline_at is not null
                and a.submitted_at is not null
                and a.submitted_at <= a.revision_deadline_at
              )
            )),
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

  select count(*) filter (where status = 'requested'),
         count(*) filter (where status = 'consumed')
    into v_requested, v_consumed
    from public.weekly_shield_uses
   where student_id = p_student_id and week_start = p_week_start;

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

-- Discover both existing open result rows and due materialized Bot 2.0 daily assignments.
-- The latter path makes settlement independent of opening Mini App. plan_item_id excludes
-- legacy history from automatic result creation; an explicit legacy result row is still
-- processed through the first branch.
CREATE OR REPLACE FUNCTION public.finalize_due_student_weeks()
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
declare
  v_count integer := 0;
  v_row   public.student_week_results%rowtype;
  r       record;
begin
  for r in
    with due_candidates as (
      select swr.student_id, swr.week_start
        from public.student_week_results swr
       where swr.status not in ('finalized', 'neutral')
         and now() >= public.next_monday_msk(swr.week_start)

      union

      select a.student_id, public.week_start_of(a.scheduled_date) as week_start
        from public.assignments a
       where a.type = 'daily'
         and a.plan_item_id is not null
         and a.scheduled_date is not null
         and now() >= public.next_monday_msk(a.scheduled_date)
         and not exists (
           select 1
             from public.student_week_results closed
            where closed.student_id = a.student_id
              and closed.week_start = public.week_start_of(a.scheduled_date)
              and closed.status in ('finalized', 'neutral')
         )
       group by a.student_id, public.week_start_of(a.scheduled_date)
    )
    select student_id, week_start
      from due_candidates
     order by week_start, student_id
  loop
    v_row := public.finalize_student_week(r.student_id, r.week_start);
    if v_row.status in ('finalized', 'neutral') then
      v_count := v_count + 1;
    end if;
  end loop;

  return v_count;
end;
$function$;
