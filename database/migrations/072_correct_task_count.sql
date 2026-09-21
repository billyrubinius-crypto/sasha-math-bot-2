-- =============================================================================
-- 072_correct_task_count.sql — фактически правильно решённые задачи
--
-- task_count остаётся исходным объёмом задания. correct_task_count фиксируется учителем
-- при приёмке и используется в solved_tasks. Старые уже принятые работы с известным
-- task_count считаются полностью решёнными; незакрытые и возвращённые работы не backfill-ятся.
-- =============================================================================

begin;

alter table public.assignments
  add column if not exists correct_task_count integer;

alter table public.assignments
  drop constraint if exists assignments_correct_task_count_valid;

alter table public.assignments
  add constraint assignments_correct_task_count_valid check (
    correct_task_count is null
    or (
      correct_task_count >= 0
      and (task_count is null or correct_task_count <= task_count)
    )
  );

-- Только действительно закрытые старые работы. Rejected остаются null: их можно пересдать.
update public.assignments
   set correct_task_count = task_count
 where status = 'checked'
   and approval_status = 'approved'
   and task_count is not null
   and correct_task_count is null;

-- Меняется сигнатура: старая трёхаргументная RPC удаляется, чтобы нельзя было принять работу
-- в обход обязательного фактического результата.
drop function if exists public.review_assignment_self(uuid, text, text);

create function public.review_assignment_self(
  p_assignment_id    uuid,
  p_status           text,
  p_feedback         text,
  p_correct_task_count integer)
 returns json
 language plpgsql
 security definer
 set search_path = public, pg_temp
as $function$
declare
  v_princ uuid;
  v_a public.assignments%rowtype;
  v_cutover_at timestamptz;
  v_stage4_at timestamptz;
  v_was_approved boolean;
  v_cutover boolean;
  v_stage4 boolean;
  v_reward_path text;
  v_week_start date;
begin
  if private.current_app_role() is distinct from 'teacher' then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_status not in ('approved', 'rejected') then
    raise exception 'invalid status' using errcode = '22023';
  end if;
  if p_assignment_id is null then
    raise exception 'assignment required' using errcode = '22023';
  end if;

  v_princ := private.current_principal();
  select * into v_a
    from public.assignments
   where id = p_assignment_id
   for update;
  if not found then
    raise exception 'not found' using errcode = 'P0002';
  end if;

  if p_status = 'approved' then
    if p_correct_task_count is null then
      raise exception 'correct_task_count required' using errcode = '22023';
    end if;
    if p_correct_task_count < 0 then
      raise exception 'invalid correct_task_count' using errcode = '22023';
    end if;
    if v_a.task_count is not null and p_correct_task_count > v_a.task_count then
      raise exception 'correct_task_count exceeds task_count' using errcode = '22023';
    end if;
    -- У legacy-незакрытых строк total может быть неизвестен; оставляем разумный верхний предел.
    if v_a.task_count is null and p_correct_task_count > 200 then
      raise exception 'invalid correct_task_count' using errcode = '22023';
    end if;
  end if;

  v_was_approved := (v_a.status = 'checked' and v_a.approval_status = 'approved');
  select cutover_at, stage4_started_at
    into v_cutover_at, v_stage4_at
    from public.economy_config
   limit 1;
  v_cutover := v_cutover_at is not null and now() >= v_cutover_at;
  v_stage4  := v_stage4_at is not null and now() >= v_stage4_at;

  update public.assignments
     set status = 'checked',
         approval_status = p_status,
         teacher_feedback = p_feedback,
         correct_task_count = case when p_status = 'approved' then p_correct_task_count else null end,
         checked_at = now()
   where id = p_assignment_id;

  if v_a.type = 'daily' and v_a.scheduled_date is not null then
    v_week_start := public.week_start_of(v_a.scheduled_date);
    if v_week_start is not null then
      perform public.recalc_student_week(v_a.student_id, v_week_start);
    end if;
  end if;

  if p_status = 'approved' then
    if v_cutover then
      perform public.record_approved_assignment(p_assignment_id);
      v_reward_path := 'cutover';
    elsif v_stage4 then
      perform public.settle_daily_math(p_assignment_id);
      v_reward_path := 'stage4';
    else
      if not v_was_approved then
        perform public.settle_legacy_approval(p_assignment_id);
      end if;
      v_reward_path := 'legacy';
    end if;
  else
    v_reward_path := 'reject';
  end if;

  perform public.security_audit(
    'teacher_review', 'teacher', v_princ, null,
    json_build_object(
      'assignment_id', p_assignment_id,
      'status', p_status,
      'correct_task_count', case when p_status = 'approved' then p_correct_task_count else null end,
      'reward_path', v_reward_path
    )::jsonb
  );

  return json_build_object(
    'ok', true,
    'student_id', v_a.student_id,
    'type', v_a.type,
    'scheduled_date', v_a.scheduled_date,
    'correct_task_count', case when p_status = 'approved' then p_correct_task_count else null end,
    'was_approved', v_was_approved,
    'reward_path', v_reward_path,
    'cutover_active', v_cutover,
    'stage4_active', v_stage4
  );
end;
$function$;

revoke all on function public.review_assignment_self(uuid, text, text, integer)
  from public, anon;
grant execute on function public.review_assignment_self(uuid, text, text, integer)
  to authenticated;

-- solved_tasks теперь означает именно правильные ответы. active_days сохраняет прежнюю семантику.
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
      (coalesce(a.first_submitted_at, a.submitted_at) at time zone 'Europe/Moscow')::date as date_msk
    from public.assignments a
    where a.student_id = p_student_id
      and a.status = 'checked'
      and a.approval_status = 'approved'
      and (p_from is null or (coalesce(a.first_submitted_at, a.submitted_at) at time zone 'Europe/Moscow')::date >= p_from)
      and (p_to   is null or (coalesce(a.first_submitted_at, a.submitted_at) at time zone 'Europe/Moscow')::date <= p_to)
  )
  select
    coalesce(sum(correct_task_count) filter (where correct_task_count >= 0), 0)::bigint as solved_tasks,
    count(distinct date_msk)::bigint                                                as active_days,
    count(*) filter (where correct_task_count is null)::bigint                      as unknown_approved_assignments
  from accepted;
$function$;

-- Миграция должна оставить без результата только исторические approved с неизвестным task_count.
do $verify$
begin
  if exists (
    select 1
      from public.assignments
     where status = 'checked'
       and approval_status = 'approved'
       and task_count is not null
       and correct_task_count is distinct from task_count
  ) then
    raise exception '072 verification failed: approved backfill mismatch';
  end if;
end;
$verify$;

commit;
