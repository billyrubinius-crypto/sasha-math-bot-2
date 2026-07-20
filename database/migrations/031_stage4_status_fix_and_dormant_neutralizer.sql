-- =============================================================================
-- 031_stage4_status_fix_and_dormant_neutralizer.sql — U08A
-- (Bot 2.0, Stage 4, карточка U08A; SPEC_STAGE4.md §§2, 8, 9)
--
-- Два независимых release-фикса post-review U08, оформленные ОДНОЙ миграцией. Миграции 027 и
-- 030 уже применены на dev и НЕ редактируются — исправления идут только новой миграцией 031.
--
--   1. daily_quest_state: точные terminal/combo-статусы (§1 карточки). Клиент по-прежнему читает
--      ТОЛЬКО эту read-модель и не вычисляет eligibility из assignments. Суммы 3/3/2, settlement,
--      ledger, random/replace/claim, достижения и тексты UI НЕ меняются — правятся только
--      CASE-выражения math_status/combo_status:
--        * terminal checked+approved БЕЗ math ledger (например, поздняя первичная отправка,
--          которую settlement честно не оплатил) => math_status='unavailable' (а не 'active'):
--          повторного действия не предлагаем, math уже не заплатит;
--        * combo_status='waiting_review' только когда life оплачен И math реально submitted
--          (math_status='waiting_review'); все прочие неоплаченные (unavailable/active/terminal)
--          => 'locked', без ложного «бонус ждёт».
--
--   2. Bootstrap-neutralizer: миграция 030 исторически содержит ИСПОЛНЯЕМЫЙ firing (approved
--      цены + generation + started_at). Чтобы полная цепочка 021→031 заканчивалась в DORMANT-
--      состоянии до подключения реальных клиентов, 031 возвращает каталог U07 к pre-cutover
--      ценам, frame_fire100.active=true, generation=false, started_at=NULL — НО только если
--      Stage 4 ещё не запущена для реальных данных (нет строк student_daily_quests /
--      daily_quest_reward_log). Иначе raise exception и НИЧЕГО не менять. Это нейтрализатор
--      перед первым реальным запуском, а НЕ product-rollback после запуска (product-rollback
--      сохраняет start/ledger — см. U07/030). Реальный firing вынесен в
--      database/releases/stage4_cutover.sql и НЕ является обычным применением миграций.
--
-- Balances, inventory, weekly economy, streak_shield и прочие товары не трогаются.
-- =============================================================================

-- --- 1. daily_quest_state: исправленные math_status / combo_status ---------------------------
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
        when (select status from a) = 'checked' and (select approval_status from a) = 'approved' then 'unavailable'
        when (select status from a) = 'checked' and (select approval_status from a) = 'rejected' then 'active'
        else 'active'
      end,
    'combo_status',
      case
        when exists (select 1 from combo_paid) then 'completed'
        when exists (select 1 from life_paid)
             and not exists (select 1 from math_paid)
             and (select status from a) = 'submitted' then 'waiting_review'
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

-- --- 2. Bootstrap-neutralizer: цепочка 021→031 заканчивается dormant -------------------------
-- Guard: если Stage 4 уже имеет реальные данные квестов — reset запрещён (не затираем боевой
-- fired-стейт). На чистом dev (синтетика 0) — приводит каталог/флаги к pre-cutover dormant.
do $$
begin
  if exists (select 1 from public.student_daily_quests)
     or exists (select 1 from public.daily_quest_reward_log) then
    raise exception
      'U08A neutralizer: Stage 4 уже имеет данные квестов — bootstrap-reset запрещён (для отката запущенной Stage 4 используйте product-rollback U07, сохраняющий start и ledger)';
  end if;

  -- Каталог U07 -> pre-cutover цены (дословно совпадает с rollback-секцией 030).
  update public.shop_items set price = 50
   where item_code in ('color_red','color_orange','color_green','color_teal',
                       'color_blue','color_indigo','color_pink','color_brown');
  update public.shop_items set price = 30   where item_code = 'status_emoji_change';
  update public.shop_items set price = 600  where item_code = 'crown';
  update public.shop_items set price = 700  where item_code = 'golden_nick';
  update public.shop_items set price = 900  where item_code = 'title_yaschenko';
  update public.shop_items set price = 2000 where item_code = 'title_custom';
  update public.shop_items set active = true where item_code = 'frame_fire100';
  update public.shop_items set price = 200  where item_code = 'title_groza';
  update public.shop_items set price = 150  where item_code in ('title_elon','title_derivative');
  update public.shop_items set price = 120  where item_code = 'title_sanchez';
  update public.shop_items set price = 150  where item_code in ('frame_notebook','frame_winter');
  update public.shop_items set price = 200  where item_code in ('bg_grid','bg_space','bg_aurora','bg_draft');
  update public.shop_items set price = 750  where item_code in ('frame_pulsar','frame_orbit');
  update public.shop_items set price = 1500 where item_code in ('frame_legend_1','frame_legend_2','frame_legend_3','frame_legend_4');

  -- Dormant-флаги: генерация выключена, старт сброшен.
  update public.economy_config
     set stage4_generation_enabled = false,
         stage4_started_at         = null
   where id;
end $$;

-- =============================================================================
-- ROLLBACK (031):
--   * daily_quest_state — восстановить версию U04 из
--     database/migrations/027_stage4_math_combo_status.sql (старые CASE math/combo).
--   * Bootstrap-neutralizer — это данные (цены/флаги), не DDL; отдельного отката нет. Реальный
--     запуск Stage 4 выполняется release-скриптом database/releases/stage4_cutover.sql
--     (guarded firing), а НЕ повторным применением миграций.
-- =============================================================================
