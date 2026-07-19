-- =============================================================================
-- 027_stage4_math_combo_status.sql — math_status/combo_status в серверной read-модели
-- (Bot 2.0, Stage 4, карточка U04; SPEC_STAGE4.md §§2, 9; решение пользователя 2026-07-19)
--
-- Зачем: U04 (student UI) обязана показывать серверные состояния math (unavailable/active/
-- waiting_review/completed) и combo (locked/waiting_review/completed), не выводя их из
-- assignments на клиенте. Действовавший daily_quest_state() отдавал только life_paid — этого
-- было недостаточно, и клиент был бы вынужден читать assignments.status/approval_status
-- напрямую, что карточка прямо запрещает. Расширяем ЕДИНСТВЕННУЮ функцию — daily_quest_state();
-- она уже используется get_daily_quests/replace_life_quest/claim_life_quest как последний шаг,
-- поэтому все клиентские вызовы автоматически получают новые поля без изменения этих функций.
--
-- Только read-only расширение существующей SQL-функции (language sql, returns json — не
-- RETURNS TABLE, поэтому баг 42702 из 026 здесь структурно невозможен). Никаких новых таблиц,
-- миграций данных, изменений бизнес-логики/сумм/eligibility settlement — эти правила остаются
-- ровно те же, что в 021-024; здесь только ВЫЧИСЛЕНИЕ статусов для отображения по уже
-- существующим полям assignments и daily_quest_reward_log, целиком на сервере.
--
-- Правила (решение пользователя):
--   math_status:
--     'unavailable'    — daily_assignment_id отсутствует (ежедневки на сегодня нет);
--     'completed'      — существует math ledger (приоритет над остальным: settle_daily_math
--                        мог оплатить и после того, как assignment уже в другом статусе);
--     'waiting_review' — работа отправлена (status='submitted') и ждёт решения учителя;
--     'active'         — назначена и не отправлена (status='assigned'), ИЛИ возвращена на
--                        исправление (status='checked' and approval_status='rejected') —
--                        студенту снова есть что сделать. Тот же fallback 'active' закрывает
--                        редкий пограничный случай checked+approved без math ledger (например,
--                        поздняя первичная отправка — settlement уже честно отказал и не
--                        заплатит задним числом, SPEC §2); отдельного статуса для него нет,
--                        математический ряд просто перестаёт требовать действия.
--   combo_status:
--     'completed'      — существует combo ledger;
--     'waiting_review' — life уже оплачен, а math ещё не оплачен (после оплаты обоих combo
--                        платится автоматически — settle_daily_combo, без действий студента);
--     'locked'          — все остальные неоплаченные случаи (life ещё не оплачен).
-- =============================================================================

create or replace function public.daily_quest_state(p_student_id bigint, p_quest_date date)
 returns json
 language sql
 stable
as $function$
  with q as (
    select * from public.student_daily_quests
     where student_id = p_student_id and quest_date = p_quest_date
  ),
  a as (
    select status, approval_status
      from public.assignments
     where id = (select daily_assignment_id from q)
  ),
  math_paid as (
    select 1 from public.daily_quest_reward_log
     where student_id = p_student_id and quest_date = p_quest_date and reward_kind = 'math'
  ),
  life_paid as (
    select 1 from public.daily_quest_reward_log
     where student_id = p_student_id and quest_date = p_quest_date and reward_kind = 'life'
  ),
  combo_paid as (
    select 1 from public.daily_quest_reward_log
     where student_id = p_student_id and quest_date = p_quest_date and reward_kind = 'combo'
  )
  select json_build_object(
    'quest_date',          p_quest_date,
    'exists',              exists (select 1 from q),
    'daily_assignment_id', (select daily_assignment_id from q),
    'replacements_used',   coalesce((select replacements_used from q), 0),
    'replacements_left',   greatest(2 - coalesce((select replacements_used from q), 0), 0),
    'life_paid',           exists (select 1 from life_paid),
    'math_paid',           exists (select 1 from math_paid),
    'combo_paid',          exists (select 1 from combo_paid),
    'generation_active',   public.stage4_generation_active(),
    'math_status',
      case
        when exists (select 1 from math_paid) then 'completed'
        when (select daily_assignment_id from q) is null then 'unavailable'
        when (select status from a) = 'submitted' then 'waiting_review'
        when (select status from a) = 'checked' and (select approval_status from a) = 'rejected' then 'active'
        else 'active'
      end,
    'combo_status',
      case
        when exists (select 1 from combo_paid) then 'completed'
        when exists (select 1 from life_paid) and not exists (select 1 from math_paid) then 'waiting_review'
        else 'locked'
      end,
    'life', (
      select json_build_object(
        'template_code', t.template_code,
        'name',          t.name,
        'description',   t.description,
        'category',      t.category
      )
      from q join public.life_quest_templates t on t.template_code = q.life_template_code
    ),
    'can_replace',
      coalesce((select replacements_used from q), 0) < 2
      and (select life_template_code from q) is not null
      and not exists (select 1 from life_paid)
      and public.stage4_generation_active(),
    'options', coalesce((
      select json_agg(
               json_build_object('ordinal', o.ordinal, 'template_code', o.template_code)
               order by o.ordinal)
        from public.student_daily_quest_options o
        join q on o.daily_quest_id = q.id
    ), '[]'::json)
  );
$function$;

-- =============================================================================
-- ROLLBACK (только функция; данные/ledger не затрагиваются):
--   восстановить тело daily_quest_state без math_paid/combo_paid/math_status/combo_status
--   из database/migrations/022_stage4_life_quest_rpc.sql (версия U02B).
-- =============================================================================
