-- =============================================================================
-- 039_t10_close_contour_b_server_side.sql — T10-06C (закрытие контура B server-side)
-- (Bot 2.0, T10; корректирующая карта перед T10-08A; SPEC_T10.md §4)
--
-- Зачем: legacy pre-cutover teacher streak-награда («контур B») до сих пор считалась в браузере
-- (teacher-review.js: processStreak/awardApprovalBonus/grantAchievement/checkPerfectMonth) и делала
-- ПРЯМЫЕ writes из-под роли authenticated: students.update, add_huikons, add_season_points,
-- student_achievements insert, consume_streak_shield. Это блокировало write-lockdown T10-08A на
-- students/balance_history. Карта переносит весь контур B на сервер БЕЗ изменения экономики: та же
-- цепочка стрика, тиры 5/10/15/20/25, bonus_return 20, season +12, достижения streak_*/rebirth/
-- perfect_month/first_step с теми же суммами, тот же щит-мост. Суммы/пороги/идемпотентность
-- достижений (grant_achievement_server) сохранены дословно.
--
-- Реализация: (1) внутренний settle_legacy_approval(assignment) — точный порт клиентской логики,
-- вызывает существующие примитивы; НЕ выдаётся клиенту (revoke от anon/authenticated/public), зовётся
-- только из review_assignment_self, которая SECURITY DEFINER (owner postgres) — потому settle_*
-- исполняется под owner и обходит RLS. (2) review_assignment_self (T10-06A) расширяется: в legacy-
-- ветке при СВЕЖЕЙ приёмке (not was_approved) вызывает settle_legacy_approval В ТОЙ ЖЕ транзакции
-- (статус + recalc + награда атомарны). reward_path/was_approved в ответе сохранены (контракт
-- T10-06A не ломается), но клиент теперь контур B не выполняет.
--
-- Экономику не переписываем; cutover/Stage 4 ветки не тронуты; auth_mode=legacy; RLS не включается.
-- =============================================================================

-- --- 1. settle_legacy_approval — серверный порт контура B (internal primitive) --------------
-- Не SECURITY DEFINER: исполняется в контексте owner'а через вызывающую review_assignment_self.
-- Порядок и суммы — дословно как в teacher-review.js (processStreak + awardApprovalBonus + first_step).
create or replace function public.settle_legacy_approval(p_assignment_id uuid)
 returns void
 language plpgsql
 set search_path = public, pg_temp
as $function$
declare
  v_a           public.assignments%rowtype;
  v_sid         bigint;
  v_sched       date;
  v_dates       date[];
  v_bridged     date[] := '{}';
  v_effective   date[];
  v_prevappr    date;
  v_missing     date;
  v_lastdate    date;
  v_d           date;
  v_prev        date;
  v_position    integer;
  v_max         integer;
  v_count30     integer;
  v_pos_this    integer;
  v_pos_last    integer;
  v_current     integer;
  v_reward      integer;
  v_idx         integer;
  v_month_start date;
  v_next_month  date;
begin
  select * into v_a from public.assignments where id = p_assignment_id;
  if not found then raise exception 'assignment % not found', p_assignment_id; end if;
  v_sid := v_a.student_id;

  if v_a.type = 'daily' then
    v_sched := v_a.scheduled_date;

    -- dates: 400 самых свежих различных принятых ежедневок, по возрастанию (как клиент).
    select array_agg(d order by d) into v_dates from (
      select distinct scheduled_date d
        from public.assignments
       where student_id = v_sid and type = 'daily' and status = 'checked'
         and approval_status = 'approved' and scheduled_date is not null
       order by d desc limit 400) t;
    if v_dates is null then v_dates := '{}'; end if;

    -- покрытые щитом дни.
    select coalesce(array_agg(distinct bridged_date), '{}') into v_bridged
      from public.streak_shield_uses where student_id = v_sid;

    -- Щит-мост: ровно 1 пропущенный день перед принятой ежедневкой, если ещё не покрыт и есть щит.
    select max(d) into v_prevappr from unnest(v_dates) d where d < v_sched;
    if v_prevappr is not null and (v_sched - v_prevappr) = 2 then
      v_missing := v_prevappr + 1;
      if not (v_missing = any(v_bridged)) then
        if public.consume_streak_shield(v_sid, v_missing) then
          v_bridged := array_append(v_bridged, v_missing);
        end if;
      end if;
    end if;

    -- Эффективная цепочка = принятые ∪ покрытые щитом, по возрастанию.
    select array_agg(d order by d) into v_effective
      from (select distinct unnest(v_dates || v_bridged) d) t;
    if v_effective is null then v_effective := '{}'; end if;

    -- Позиции подряд идущих дней.
    v_prev := null; v_position := 0; v_max := 0; v_count30 := 0; v_pos_this := 1; v_pos_last := 0;
    if array_length(v_dates, 1) is not null then v_lastdate := v_dates[array_length(v_dates, 1)]; end if;
    foreach v_d in array v_effective loop
      if v_prev is not null and v_d = v_prev + 1 then v_position := v_position + 1; else v_position := 1; end if;
      if v_d = v_sched then v_pos_this := v_position; end if;
      if v_lastdate is not null and v_d = v_lastdate then v_pos_last := v_position; end if;
      if v_position > v_max then v_max := v_position; end if;
      if v_position = 30 then v_count30 := v_count30 + 1; end if;
      v_prev := v_d;
    end loop;
    v_current := case when v_lastdate is not null then v_pos_last else 0 end;

    -- Тиры стрика 2.0: 1→5, 2→10, 3-6→15, 7-29→20, 30+→25.
    v_reward := case when v_pos_this >= 30 then 25 when v_pos_this >= 7 then 20
                     when v_pos_this >= 3 then 15 when v_pos_this = 2 then 10 else 5 end;

    update public.students
       set current_streak = v_current, last_submission_date_msk = v_lastdate
     where telegram_id = v_sid;

    perform public.add_huikons(v_sid, v_reward, 'streak_day_' || v_pos_this);
    perform public.add_season_points(v_sid, 12);

    -- Бонус возвращения: разрыв ≥7 дней перед этой ежедневкой в цепочке ВСЕХ принятых.
    v_idx := array_position(v_dates, v_sched);
    if v_idx is not null and v_idx > 1 and (v_sched - v_dates[v_idx - 1]) >= 7 then
      perform public.add_huikons(v_sid, 20, 'bonus_return');
    end if;

    -- Достижения дисциплины по maxStreak (те же суммы, что клиентский ACHIEVEMENT_REWARDS).
    if v_max >= 7   then perform public.grant_achievement_server(v_sid, 'streak_7',   25);   end if;
    if v_max >= 30  then perform public.grant_achievement_server(v_sid, 'streak_30',  100);  end if;
    if v_max >= 100 then perform public.grant_achievement_server(v_sid, 'streak_100', 300);  end if;
    if v_max >= 200 then perform public.grant_achievement_server(v_sid, 'streak_200', 500);  end if;
    if v_max >= 365 then perform public.grant_achievement_server(v_sid, 'streak_365', 1000); end if;
    if v_count30 >= 2 then perform public.grant_achievement_server(v_sid, 'rebirth', 200);   end if;

    -- Идеальный месяц: все ежедневки календарного месяца этой ежедневки приняты.
    v_month_start := date_trunc('month', v_sched)::date;
    v_next_month  := (v_month_start + interval '1 month')::date;
    if exists (select 1 from public.assignments
                where student_id = v_sid and type = 'daily'
                  and scheduled_date >= v_month_start and scheduled_date < v_next_month)
       and not exists (select 1 from public.assignments
                        where student_id = v_sid and type = 'daily'
                          and scheduled_date >= v_month_start and scheduled_date < v_next_month
                          and not (status = 'checked' and approval_status = 'approved'))
    then
      perform public.grant_achievement_server(v_sid, 'perfect_month', 150);
    end if;

  elsif v_a.type in ('weekly', 'individual') then
    -- Флат-бонус + season points (не связаны со стриком).
    perform public.add_huikons(v_sid,
      case v_a.type when 'weekly' then 20 else 15 end, v_a.type || '_approved');
    perform public.add_season_points(v_sid,
      case v_a.type when 'weekly' then 40 else 30 end);
  end if;

  -- «Первый шаг» — первая принятая работа любого типа (идемпотентно; для daily и non-daily).
  perform public.grant_achievement_server(v_sid, 'first_step', 10);
end;
$function$;

revoke all on function public.settle_legacy_approval(uuid) from public, anon, authenticated;

-- --- 2. review_assignment_self — legacy-ветка теперь платит серверно (в той же транзакции) ---
-- Отличие от 037: в legacy-ветке при свежей приёмке (not v_was_approved) вызывается
-- settle_legacy_approval. Остальное (cutover/stage4/reject, recalc, audit, ответ) без изменений.
create or replace function public.review_assignment_self(
  p_assignment_id uuid, p_status text, p_feedback text)
 returns json language plpgsql security definer set search_path = public, pg_temp
as $function$
declare
  v_princ uuid; v_a public.assignments%rowtype; v_cutover_at timestamptz; v_stage4_at timestamptz;
  v_was_approved boolean; v_cutover boolean; v_stage4 boolean; v_reward_path text; v_week_start date;
begin
  if private.current_app_role() is distinct from 'teacher' then
    raise exception 'forbidden' using errcode = '42501'; end if;
  if p_status not in ('approved', 'rejected') then
    raise exception 'invalid status' using errcode = '22023'; end if;
  if p_assignment_id is null then raise exception 'assignment required' using errcode = '22023'; end if;
  v_princ := private.current_principal();
  select * into v_a from public.assignments where id = p_assignment_id for update;
  if not found then raise exception 'not found' using errcode = 'P0002'; end if;
  v_was_approved := (v_a.status = 'checked' and v_a.approval_status = 'approved');
  select cutover_at, stage4_started_at into v_cutover_at, v_stage4_at from public.economy_config limit 1;
  v_cutover := v_cutover_at is not null and now() >= v_cutover_at;
  v_stage4  := v_stage4_at  is not null and now() >= v_stage4_at;
  update public.assignments
     set status = 'checked', approval_status = p_status, teacher_feedback = p_feedback, checked_at = now()
   where id = p_assignment_id;
  if v_a.type = 'daily' and v_a.scheduled_date is not null then
    v_week_start := public.week_start_of(v_a.scheduled_date);
    if v_week_start is not null then perform public.recalc_student_week(v_a.student_id, v_week_start); end if;
  end if;
  if p_status = 'approved' then
    if v_cutover then perform public.record_approved_assignment(p_assignment_id); v_reward_path := 'cutover';
    elsif v_stage4 then perform public.settle_daily_math(p_assignment_id); v_reward_path := 'stage4';
    else
      -- Контур B: свежая приёмка платит серверно (T10-06C). Повторная (was_approved) — не платит.
      if not v_was_approved then perform public.settle_legacy_approval(p_assignment_id); end if;
      v_reward_path := 'legacy';
    end if;
  else v_reward_path := 'reject'; end if;
  perform public.security_audit('teacher_review', 'teacher', v_princ, null,
    json_build_object('assignment_id', p_assignment_id, 'status', p_status, 'reward_path', v_reward_path)::jsonb);
  return json_build_object('ok', true, 'student_id', v_a.student_id, 'type', v_a.type,
    'scheduled_date', v_a.scheduled_date, 'was_approved', v_was_approved, 'reward_path', v_reward_path,
    'cutover_active', v_cutover, 'stage4_active', v_stage4);
end;
$function$;

-- grants review_assignment_self не меняются (authenticated; T10-06A/037). Пересоздание CREATE OR
-- REPLACE сохраняет существующие grants.

-- =============================================================================
-- ROLLBACK (вернуть review_assignment_self к версии 037 и удалить settle_legacy_approval):
--   -- восстановить review_assignment_self из 037 (legacy-ветка только выставляет reward_path,
--   -- без вызова settle_legacy_approval) — см. 037_t10_teacher_review_gateways.sql, функция 1;
--   drop function if exists public.settle_legacy_approval(uuid);
--   -- ВНИМАНИЕ: откат обязателен ДО отката клиента (client switch T10-06C) — иначе legacy-приёмка
--   -- перестанет платить (сервер не платит, клиент уже не считает). Порядок отката: клиент → эта миграция.
-- =============================================================================
