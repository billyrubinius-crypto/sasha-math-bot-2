-- =============================================================================
-- 030_stage4_cutover_shop_reprice.sql — Атомарный cutover Stage 4 + переоценка магазина
-- (Bot 2.0, Stage 4, карточка U07; SPEC_STAGE4.md §8; ECONOMY_V2.md §§8, 12; W09/012 shield)
--
-- Зачем: одной транзакцией включить генерацию дневных наборов и утверждённую ценовую лестницу
-- ECONOMY_V2 §8, без окна «старые цены + новый доход». Плюс закрывается найденный rollback-
-- пробел в settle_daily_math (см. секцию 1).
--
-- Решения пользователя (2026-07-19):
--   * frame_fire100 («100 дней огня») — вариант A: снять с продажи (active=false), владельцы
--     предмет сохраняют (legacy, ECONOMY §12.6). Новый frame_rhythm24 в U07 НЕ добавляется.
--   * Сезонные ротационные титулы (title_groza/elon/sanchez/derivative) — единая цена 250.
--   * Щит недели (streak_shield, 90/лимит 7) уже переоценён в W09/012 — повторно НЕ трогаем.
--
-- T10 блокирует production; в dev cutover тестируется self-rollback (rollback-скрипт в конце).
-- =============================================================================

-- --- 1. Rollback-safety fix для settle_daily_math (постоянное изменение) ---------------------
-- Пробел: settle_daily_math звал ensure_daily_quest(...,false) БЕЗ учёта generation-флага.
-- После rollback (generation off, но stage4_started_at сохранён и settlement-гейт по timestamp
-- ещё проходит) НОВАЯ принятая daily создавала бы student_daily_quests и получала math — хотя
-- rollback обязан останавливать новые дни. Кроме того, без ensure строка не создаётся, а
-- composite-FK ledger'а упал бы с ошибкой. Фикс: создавать отсутствующую строку только при
-- активной генерации; если генерация выключена и строки нет — не создавать и не платить.
-- Всё остальное (eligibility U02C, timestamp-гейт U02D, combo, life-достижения U06) без изменений.
-- Фикс постоянный и остаётся после rollback — именно он делает rollback безопасным.
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

  -- U07: отсутствующую дневную строку создаём ТОЛЬКО при активной генерации.
  if public.stage4_generation_active() then
    perform public.ensure_daily_quest(a.student_id, v_qdate, false);
  end if;

  select id, daily_assignment_id
    into v_qid, v_target
    from public.student_daily_quests
   where student_id = a.student_id and quest_date = v_qdate
   for update;

  if not found then
    return;  -- U07: генерация выключена и дневной строки нет — не создаём и не платим
  end if;

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

  -- U06: pay-zero достижения жизненных привычек (идемпотентно; поздний math может закрыть streak).
  perform public.grant_life_achievements(a.student_id);
end;
$function$;

-- --- 2. АТОМАРНЫЙ CUTOVER (firing): переоценка + включение генерации в одной транзакции -------
-- Все цены и оба флага меняются вместе — нет окна «старая цена / новый доход». stage4_started_at
-- ставится через coalesce: только если сейчас NULL, поэтому повторный firing/ретрай не
-- перезаписывает неизменяемый timestamp. Действие раньше этого момента не платит (U02D-гейт).
begin;

  -- Постоянная витрина (ECONOMY §8.1). Щит (streak_shield) НЕ трогаем — переоценён в W09/012.
  update public.shop_items set price = 80
   where item_code in ('color_red','color_orange','color_green','color_teal',
                       'color_blue','color_indigo','color_pink','color_brown');
  update public.shop_items set price = 40   where item_code = 'status_emoji_change';
  update public.shop_items set price = 900  where item_code = 'crown';
  update public.shop_items set price = 1100 where item_code = 'golden_nick';
  update public.shop_items set price = 1300 where item_code = 'title_yaschenko';
  update public.shop_items set price = 3000 where item_code = 'title_custom';

  -- frame_fire100 (вариант A): снять с продажи, владельцы сохраняют (legacy, ECONOMY §12.6).
  update public.shop_items set active = false where item_code = 'frame_fire100';

  -- Ротационная витрина (ECONOMY §8.2).
  update public.shop_items set price = 250  -- сезонные титулы, единая цена (решение пользователя)
   where item_code in ('title_groza','title_elon','title_sanchez','title_derivative');
  update public.shop_items set price = 300  where item_code in ('frame_notebook','frame_winter');
  update public.shop_items set price = 380  where item_code in ('bg_grid','bg_space','bg_aurora','bg_draft');
  update public.shop_items set price = 1200 where item_code in ('frame_pulsar','frame_orbit');
  update public.shop_items set price = 2200 where item_code in ('frame_legend_1','frame_legend_2','frame_legend_3','frame_legend_4');

  -- Включение Stage 4: неизменяемый start time (coalesce) + генерация. Один и тот же commit.
  update public.economy_config
     set stage4_started_at = coalesce(stage4_started_at, now()),
         stage4_generation_enabled = true
   where id;

commit;

-- =============================================================================
-- ROLLBACK (self-rollback для dev; в проде — то же, если понадобится откат):
-- Возвращает ТОЛЬКО изменённые этой версией цены и выключает генерацию. stage4_started_at,
-- дневные строки, ledger, балансы и inventory СОХРАНЯЮТСЯ. Settlement уже созданных math/combo
-- продолжается (гейт settlement — по stage4_started_at, а НЕ по флагу; секция 1 не даёт создавать
-- новые дни при выключенной генерации). Функцию settle_daily_math НЕ откатывать — фикс постоянный.
-- Никакого clawback и drop.
--
--   begin;
--     update public.shop_items set price = 50
--      where item_code in ('color_red','color_orange','color_green','color_teal',
--                          'color_blue','color_indigo','color_pink','color_brown');
--     update public.shop_items set price = 30   where item_code = 'status_emoji_change';
--     update public.shop_items set price = 600  where item_code = 'crown';
--     update public.shop_items set price = 700  where item_code = 'golden_nick';
--     update public.shop_items set price = 900  where item_code = 'title_yaschenko';
--     update public.shop_items set price = 2000 where item_code = 'title_custom';
--     update public.shop_items set active = true where item_code = 'frame_fire100';
--     update public.shop_items set price = 200  where item_code = 'title_groza';
--     update public.shop_items set price = 150  where item_code in ('title_elon','title_derivative');
--     update public.shop_items set price = 120  where item_code = 'title_sanchez';
--     update public.shop_items set price = 150  where item_code in ('frame_notebook','frame_winter');
--     update public.shop_items set price = 200  where item_code in ('bg_grid','bg_space','bg_aurora','bg_draft');
--     update public.shop_items set price = 750  where item_code in ('frame_pulsar','frame_orbit');
--     update public.shop_items set price = 1500 where item_code in ('frame_legend_1','frame_legend_2','frame_legend_3','frame_legend_4');
--     update public.economy_config set stage4_generation_enabled = false where id;  -- stage4_started_at СОХРАНЯЕТСЯ
--   commit;
-- =============================================================================
