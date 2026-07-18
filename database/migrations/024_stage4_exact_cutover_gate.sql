-- =============================================================================
-- 024_stage4_exact_cutover_gate.sql — Точный timestamp-гейт cutover для math settlement
-- (Bot 2.0, Stage 4, карточка U02D; SPEC_STAGE4.md §§2, 5, 8)
--
-- Зачем: U02C гейтил выплату по дате (quest_date >= (stage4_started_at MSK)::date), из-за чего
-- действие, совершённое в день старта, но РАНЬШЕ точного stage4_started_at, оплачивалось задним
-- числом (§8: «Действия до фактического времени cutover не получают награду задним числом»).
-- U02D переводит гейт на точный timestamptz: сравнивается момент исходного действия
-- coalesce(first_submitted_at, submitted_at) с неизменяемым stage4_started_at без приведения к
-- date. Если действие раньше старта хотя бы на миллисекунду — math (и, как следствие, combo) не
-- платятся и ledger не создаётся; повторная отправка после старта такую работу подходящей не
-- делает (first_submitted_at фиксирует первое действие).
--
-- Только функции. Eligibility U02C (принято + первая отправка в scheduled_date по МСК + возврат
-- в срок), суммы 3/3/2, таблицы, constraints, random/life claim, weekly settlement и миграция
-- 023 НЕ изменяются. Гейт по-прежнему НЕ зависит от stage4_generation_enabled: отключение
-- генерации после старта не блокирует settlement уже совершённых подходящих действий.
--
-- Второй пробел U02D (независимый запуск settlement из teacher approve при неактивном недельном
-- economy_config.cutover_at) закрывается в js/teacher-review.js после применения этой миграции.
-- =============================================================================

-- --- 1. Новый гейт: точное сравнение момента действия с неизменяемым stage4_started_at --------
create or replace function public.stage4_settlement_active(p_action_at timestamptz)
 returns boolean
 language sql
 stable
as $function$
  select ec.stage4_started_at is not null
     and p_action_at is not null
     and p_action_at >= ec.stage4_started_at
    from public.economy_config ec
   where ec.id;
$function$;

-- --- 2. settle_daily_math: гейт по моменту исходного действия, остальное без изменений --------
create or replace function public.settle_daily_math(p_assignment_id uuid)
 returns void
 language plpgsql
as $function$
declare
  a        public.assignments%rowtype;
  v_qdate  date;
  v_qid    uuid;
  v_target uuid;
  v_paid   integer;
begin
  select * into a from public.assignments where id = p_assignment_id;
  if not found or a.type <> 'daily' then
    return;
  end if;

  -- eligibility (U02C, без изменений): принято + первая отправка вовремя + исправление в срок
  if not (a.status = 'checked' and a.approval_status = 'approved'
          and public.is_first_submission_on_time(a.first_submitted_at, a.submitted_at, a.scheduled_date)
          and (coalesce(a.revision_count, 0) = 0
               or (a.revision_deadline_at is not null
                   and a.submitted_at is not null
                   and a.submitted_at <= a.revision_deadline_at))) then
    return;
  end if;

  v_qdate := a.scheduled_date;

  -- U02D: точный timestamp-гейт cutover по моменту ПЕРВОГО действия (не по календарной дате).
  if not public.stage4_settlement_active(coalesce(a.first_submitted_at, a.submitted_at)) then
    return;
  end if;

  perform public.ensure_daily_quest(a.student_id, v_qdate, false);

  select id, daily_assignment_id
    into v_qid, v_target
    from public.student_daily_quests
   where student_id = a.student_id and quest_date = v_qdate
   for update;

  if v_target is null then
    update public.student_daily_quests
       set daily_assignment_id = a.id, updated_at = now()
     where id = v_qid;
    v_target := a.id;
  end if;

  if v_target <> a.id then
    return;
  end if;

  insert into public.daily_quest_reward_log (student_id, quest_date, reward_kind, bubliks)
    values (a.student_id, v_qdate, 'math', 3)
    on conflict (student_id, quest_date, reward_kind) do nothing;
  get diagnostics v_paid = row_count;
  if v_paid = 1 then
    perform public.add_huikons(a.student_id, 3, 'daily_quest_math');
  end if;

  perform public.settle_daily_combo(a.student_id, v_qdate);
end;
$function$;

-- --- 3. Убрать устаревший date-гейт (заменён timestamptz-версией выше) ----------------------
drop function if exists public.stage4_settlement_active(date);

-- =============================================================================
-- ROLLBACK (только функции; балансы/ledger не отзываются):
--   -- восстановить date-версию гейта и её вызов из 023_stage4_math_combo_settlement.sql:
--   drop function if exists public.stage4_settlement_active(timestamptz);
--   -- затем воссоздать stage4_settlement_active(date) и settle_daily_math (версии U02C) из 023.
-- =============================================================================
