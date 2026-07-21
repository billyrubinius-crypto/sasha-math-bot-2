-- =============================================================================
-- 037_t10_teacher_review_gateways.sql — T10-06A (teacher review gateways)
-- (Bot 2.0, T10; SPEC_T10.md §4; карточка T10-06A; foundation T10-01/05, паттерн T10-04B)
--
-- Claim-protected teacher gateways для проверки работ. Каждый требует app_role='teacher' (из JWT-
-- claims, T10-01), выводит assignment/student на сервере (клиентский ID прав не даёт) и выполняет
-- статус-переход + пересчёт недели + СУЩЕСТВУЮЩИЕ reward RPC ОДНОЙ серверной транзакцией. Экономика
-- не переписывается: record_approved_assignment/settle_daily_math/recalc_student_week/add_huikons
-- вызываются как есть (pay-once ledgers, late-review rules, идемпотентность сохранены).
--
-- SCOPE (решение пользователя, T10-06A): покрываются post-cutover/Stage 4 reward-путь + reject +
-- penalty + read-модель очереди. Legacy pre-cutover streak-контур (processStreak/achievements/
-- perfect-month в teacher-review.js) НЕ реимплементируется здесь: gateway возвращает reward_path=
-- 'legacy' и pre-update was_approved, чтобы клиент при switch (T10-07) сам решил судьбу контура.
--
-- SECURITY DEFINER обязателен (доступ к private.* claim-хелперам, у authenticated нет USAGE на
-- private). search_path = public, pg_temp (как T10-04B): делегируем в функции с неполными public-
-- именами; путь фиксирован, pg_temp последним. Grant только authenticated (teacher JWT — role=
-- authenticated + app_role=teacher); anon исключён. UI НЕ переключается (T10-07), auth_mode=legacy,
-- RLS не включается. Audit значимых действий (review/penalty): object id + result, без photo/feedback.
-- =============================================================================

-- --- 1. review_assignment_self — approve/reject + recalc + settlement одной транзакцией --------
create or replace function public.review_assignment_self(
  p_assignment_id uuid,
  p_status        text,
  p_feedback      text)
 returns json
 language plpgsql
 security definer
 set search_path = public, pg_temp
as $function$
declare
  v_princ        uuid;
  v_a            public.assignments%rowtype;
  v_cutover_at   timestamptz;
  v_stage4_at    timestamptz;
  v_was_approved boolean;
  v_cutover      boolean;
  v_stage4       boolean;
  v_reward_path  text;
  v_week_start   date;
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

  -- Владелец/тип/scheduled_date выводятся сервером; row lock сериализует конкурентный review.
  select * into v_a from public.assignments where id = p_assignment_id for update;
  if not found then
    raise exception 'not found' using errcode = 'P0002';
  end if;

  -- Pre-update состояние: повторное «Принять» уже принятой (из архива) не должно дать второй
  -- legacy-награды — клиент решает по was_approved на switch T10-07.
  v_was_approved := (v_a.status = 'checked' and v_a.approval_status = 'approved');

  -- cutover/Stage 4 гейты — как в teacher-review.js: cutover => record_approved_assignment,
  -- Stage 4 без cutover => settle_daily_math (точная eligibility внутри самих RPC).
  select cutover_at, stage4_started_at into v_cutover_at, v_stage4_at
    from public.economy_config limit 1;
  v_cutover := v_cutover_at is not null and now() >= v_cutover_at;
  v_stage4  := v_stage4_at  is not null and now() >= v_stage4_at;

  update public.assignments
     set status           = 'checked',
         approval_status  = p_status,
         teacher_feedback = p_feedback,
         checked_at       = now()
   where id = p_assignment_id;

  -- Недельный результат пересчитывается для daily (и на approve, и на reject) — как в клиенте.
  -- В отличие от клиента (где сбой recalc лишь логировался) здесь всё атомарно: сбой откатит review.
  if v_a.type = 'daily' and v_a.scheduled_date is not null then
    v_week_start := public.week_start_of(v_a.scheduled_date);
    if v_week_start is not null then
      perform public.recalc_student_week(v_a.student_id, v_week_start);
    end if;
  end if;

  if p_status = 'approved' then
    if v_cutover then
      -- Идемпотентно на любое approve (в т.ч. повторное): восстановление после сбоя. Хвост
      -- record_approved_assignment сам зовёт settle_daily_math — второй math RPC не нужен.
      perform public.record_approved_assignment(p_assignment_id);
      v_reward_path := 'cutover';
    elsif v_stage4 then
      perform public.settle_daily_math(p_assignment_id);
      v_reward_path := 'stage4';
    else
      -- Legacy pre-cutover контур B: сервер здесь не платит (scope T10-06A); клиент — T10-07.
      v_reward_path := 'legacy';
    end if;
  else
    v_reward_path := 'reject';
  end if;

  perform public.security_audit('teacher_review', 'teacher', v_princ, null,
    json_build_object('assignment_id', p_assignment_id, 'status', p_status,
                      'reward_path', v_reward_path)::jsonb);

  return json_build_object(
    'ok', true,
    'student_id', v_a.student_id,
    'type', v_a.type,
    'scheduled_date', v_a.scheduled_date,
    'was_approved', v_was_approved,
    'reward_path', v_reward_path,
    'cutover_active', v_cutover,
    'stage4_active', v_stage4);
end;
$function$;

-- --- 2. apply_penalty_self — штраф по assignment (student выводится сервером) ------------------
-- Кламп нулём и запись фактически списанной суммы — внутри add_huikons (без изменений). Audit
-- содержит assignment id + суммы, но НЕ текст причины (feedback content).
create or replace function public.apply_penalty_self(
  p_assignment_id uuid,
  p_amount        integer,
  p_reason        text)
 returns json
 language plpgsql
 security definer
 set search_path = public, pg_temp
as $function$
declare
  v_princ   uuid;
  v_student bigint;
  v_change  integer;
  v_balance integer;
begin
  if private.current_app_role() is distinct from 'teacher' then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_assignment_id is null then
    raise exception 'assignment required' using errcode = '22023';
  end if;
  if p_reason is null or length(btrim(p_reason)) = 0 then
    raise exception 'reason required' using errcode = '22023';
  end if;
  if p_amount is null then
    raise exception 'amount required' using errcode = '22023';
  end if;
  v_princ := private.current_principal();

  select student_id into v_student from public.assignments where id = p_assignment_id;
  if v_student is null then
    raise exception 'not found' using errcode = 'P0002';
  end if;

  select actual_change, new_balance into v_change, v_balance
    from public.add_huikons(v_student, p_amount, 'penalty: ' || p_reason);

  perform public.security_audit('teacher_penalty', 'teacher', v_princ, null,
    json_build_object('assignment_id', p_assignment_id, 'amount', p_amount,
                      'actual_change', v_change)::jsonb);

  return json_build_object('actual_change', v_change, 'new_balance', v_balance);
end;
$function$;

-- --- 3. get_review_queue_self — teacher read-модель очереди (pending/archive) -----------------
-- Возвращает pending_count + элементы с вложенным students{name,group_name} (форма, совместимая с
-- текущим PostgREST-embed teacher-review.js). Archive лимитирован 200 (как клиент, T7). Read-only.
create or replace function public.get_review_queue_self(p_view text default 'pending')
 returns json
 language plpgsql
 security definer
 set search_path = public, pg_temp
as $function$
declare
  v_items   json;
  v_pending integer;
begin
  if private.current_app_role() is distinct from 'teacher' then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  select count(*) into v_pending from public.assignments where status = 'submitted';

  if p_view = 'archive' then
    select coalesce(json_agg(row_to_json(t)), '[]'::json) into v_items from (
      select a.*, json_build_object('name', s.name, 'group_name', s.group_name) as students
        from public.assignments a
        left join public.students s on s.telegram_id = a.student_id
       where a.status = 'checked'
       order by a.submitted_at desc nulls last
       limit 200) t;
  else
    select coalesce(json_agg(row_to_json(t)), '[]'::json) into v_items from (
      select a.*, json_build_object('name', s.name, 'group_name', s.group_name) as students
        from public.assignments a
        left join public.students s on s.telegram_id = a.student_id
       where a.status = 'submitted'
       order by a.submitted_at desc nulls last) t;
  end if;

  return json_build_object('pending_count', v_pending, 'view', p_view, 'items', v_items);
end;
$function$;

-- --- 4. Явные grants: authenticated (teacher JWT; app_role проверяется внутри). anon исключён --
revoke all on function public.review_assignment_self(uuid, text, text) from public, anon;
revoke all on function public.apply_penalty_self(uuid, integer, text)  from public, anon;
revoke all on function public.get_review_queue_self(text)              from public, anon;
grant execute on function public.review_assignment_self(uuid, text, text) to authenticated;
grant execute on function public.apply_penalty_self(uuid, integer, text)  to authenticated;
grant execute on function public.get_review_queue_self(text)              to authenticated;

-- =============================================================================
-- ROLLBACK (UI не переключён — откат безопасен):
--   drop function if exists public.get_review_queue_self(text);
--   drop function if exists public.apply_penalty_self(uuid, integer, text);
--   drop function if exists public.review_assignment_self(uuid, text, text);
-- =============================================================================
