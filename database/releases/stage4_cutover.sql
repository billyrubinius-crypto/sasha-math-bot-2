-- =============================================================================
-- database/releases/stage4_cutover.sql — РЕАЛЬНЫЙ firing Stage 4 (U08A)
-- (Bot 2.0, Stage 4; SPEC_STAGE4.md §8; ECONOMY_V2.md §8)
--
-- ЭТО НЕ МИГРАЦИЯ. Обычное применение миграций 021–031 оставляет dev/prod в DORMANT-состоянии
-- (migration 031 — bootstrap-neutralizer). Этот скрипт — ОТДЕЛЬНЫЙ, осознанный шаг запуска,
-- выполняемый вручную ПОСЛЕ T10 (см. database/releases/README.md), предпочтительно в понедельник.
--
-- Одна guarded транзакция: атомарно переводит каталог U07 с pre-cutover цен на approved цены
-- (ECONOMY_V2 §8), снимает frame_fire100 с продажи, ставит неизменяемый stage4_started_at=now()
-- (только из NULL) и включает генерацию. Весь блок — один DO (одна транзакция): любой preflight
-- raise откатывает всё, частичный firing невозможен.
--
-- Аварийная остановка (ничего не применяется) при:
--   * economy_config не содержит ровно одну singleton-строку (U08B: повреждённое окружение —
--     firing не пытается молча восстановить конфиг, только останавливается до любого UPDATE);
--   * stage4_started_at не NULL или generation уже true (уже запущено);
--   * наличии строк student_daily_quests / daily_quest_reward_log (частичный/реальный прогон);
--   * отсутствии любого ожидаемого item_code;
--   * любой текущей цене, не равной зафиксированной pre-cutover;
--   * frame_fire100 отсутствует или уже не active;
--   * финальный UPDATE economy_config затронул не ровно одну строку (U08B: singleton исчез между
--     preflight и APPLY — весь do-блок аварийно откатывается, включая уже применённые shop_items).
-- =============================================================================
do $$
declare
  v_missing    int;
  v_badprice   int;
  v_frame      boolean;
  v_config_cnt int;
  v_row_count  int;
begin
  -- preflight 0 (U08B): economy_config обязана содержать ровно одну singleton-строку id=true.
  -- Проверяется ДО любого UPDATE — отсутствие строки не чинится молча (нет fallback insert/upsert).
  select count(*) into v_config_cnt from public.economy_config where id;
  if v_config_cnt <> 1 then
    raise exception 'FIRING ABORT: economy_config singleton-строка отсутствует (count=%), окружение повреждено', v_config_cnt;
  end if;

  -- preflight 1: конфиг обязан быть чистым dormant
  if (select stage4_started_at from public.economy_config where id) is not null then
    raise exception 'FIRING ABORT: stage4_started_at не NULL — Stage 4 уже запущена';
  end if;
  if (select stage4_generation_enabled from public.economy_config where id) then
    raise exception 'FIRING ABORT: stage4_generation_enabled уже true';
  end if;

  -- preflight 2: нет частичного/реального Stage 4 состояния
  if exists (select 1 from public.student_daily_quests)
     or exists (select 1 from public.daily_quest_reward_log) then
    raise exception 'FIRING ABORT: уже есть данные квестов (student_daily_quests / daily_quest_reward_log)';
  end if;

  -- preflight 3: все целевые товары существуют и держат ровно pre-cutover цену
  with expected(item_code, old_price) as (values
    ('color_red',50),('color_orange',50),('color_green',50),('color_teal',50),
    ('color_blue',50),('color_indigo',50),('color_pink',50),('color_brown',50),
    ('status_emoji_change',30),('crown',600),('golden_nick',700),
    ('title_yaschenko',900),('title_custom',2000),
    ('title_groza',200),('title_elon',150),('title_sanchez',120),('title_derivative',150),
    ('frame_notebook',150),('frame_winter',150),
    ('bg_grid',200),('bg_space',200),('bg_aurora',200),('bg_draft',200),
    ('frame_pulsar',750),('frame_orbit',750),
    ('frame_legend_1',1500),('frame_legend_2',1500),('frame_legend_3',1500),('frame_legend_4',1500)
  )
  select count(*) filter (where s.item_code is null),
         count(*) filter (where s.item_code is not null and s.price is distinct from e.old_price)
    into v_missing, v_badprice
    from expected e left join public.shop_items s on s.item_code = e.item_code;
  if v_missing > 0 then
    raise exception 'FIRING ABORT: отсутствует % ожидаемых item_code', v_missing;
  end if;
  if v_badprice > 0 then
    raise exception 'FIRING ABORT: % товар(ов) с неожиданной текущей ценой (не pre-cutover)', v_badprice;
  end if;

  -- preflight 4: frame_fire100 существует и активен (чистый pre-cutover)
  select active into v_frame from public.shop_items where item_code = 'frame_fire100';
  if v_frame is null then
    raise exception 'FIRING ABORT: frame_fire100 отсутствует';
  end if;
  if v_frame is not true then
    raise exception 'FIRING ABORT: frame_fire100 не active — неожиданное pre-cutover состояние';
  end if;

  -- APPLY: approved цены (ECONOMY_V2 §8) + флаги в одном коммите (нет окна «старая цена/новый доход»)
  update public.shop_items set price = 80
   where item_code in ('color_red','color_orange','color_green','color_teal',
                       'color_blue','color_indigo','color_pink','color_brown');
  update public.shop_items set price = 40   where item_code = 'status_emoji_change';
  update public.shop_items set price = 900  where item_code = 'crown';
  update public.shop_items set price = 1100 where item_code = 'golden_nick';
  update public.shop_items set price = 1300 where item_code = 'title_yaschenko';
  update public.shop_items set price = 3000 where item_code = 'title_custom';
  update public.shop_items set active = false where item_code = 'frame_fire100';
  update public.shop_items set price = 250  where item_code in ('title_groza','title_elon','title_sanchez','title_derivative');
  update public.shop_items set price = 300  where item_code in ('frame_notebook','frame_winter');
  update public.shop_items set price = 380  where item_code in ('bg_grid','bg_space','bg_aurora','bg_draft');
  update public.shop_items set price = 1200 where item_code in ('frame_pulsar','frame_orbit');
  update public.shop_items set price = 2200 where item_code in ('frame_legend_1','frame_legend_2','frame_legend_3','frame_legend_4');

  update public.economy_config
     set stage4_started_at         = coalesce(stage4_started_at, now()),
         stage4_generation_enabled = true
   where id;
  get diagnostics v_row_count = row_count;
  if v_row_count <> 1 then
    raise exception 'FIRING ABORT: финальный UPDATE economy_config затронул % строк(и) вместо 1 — весь firing откатывается', v_row_count;
  end if;

  raise notice 'Stage 4 FIRED: approved prices applied, generation on, started_at=%',
    (select stage4_started_at from public.economy_config where id);
end $$;

-- =============================================================================
-- PRODUCT-ROLLBACK (только ПОСЛЕ реального запуска; НЕ bootstrap-neutralizer).
-- Возвращает цены и выключает генерацию, но СОХРАНЯЕТ stage4_started_at, дневные строки, ledger,
-- балансы и inventory: settlement уже созданных math/combo продолжается (гейт — по started_at,
-- а не по флагу; migration 030 §1 не даёт создавать новые дни при выключенной генерации).
-- Без clawback/drop. Раскомментировать и выполнить только при необходимости отката ПОСЛЕ firing.
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
