-- =============================================================================
-- 070_pet_room_items.sql — PET3: предметы комнаты
-- (Bot 2.0, Stage 5; SPEC_STAGE5_PET_ROOM.md §5, карточка tasks/PET3.md)
--
-- ЗАЧЕМ. Комната становится своей: лежанка под питомцем и игрушка рядом. Разовая косметика,
-- купленная навсегда, — коллекционность без второго регулярного стока.
--
-- --- ПОЧЕМУ ПРЕДМЕТЫ ПОСТОЯННЫЕ, А НЕ СЕЗОННЫЕ ------------------------------------------
-- Решение пользователя: предметы комнаты НЕ входят в бонус за закрытую коллекцию. Это
-- механически определяет и второй вопрос. `claim_collection_bonus_self` считает владение по
-- условию `availability = 'rotation' and rotation_bundle = <бандл сезона>` — без разбора
-- слотов. То есть ЛЮБОЙ сезонный предмет автоматически попадает в требование коллекции, и
-- исключить его можно было бы только правкой работающей функции выплаты.
--
-- Функцию не трогаем: коллекционный бонус только что стал достижимым после снижения цен
-- каталога (ECONOMY_V4 §4.7), и расширять требование с четырёх предметов до шести — значит
-- снова сделать его недостижимым. Поэтому предметы комнаты — `availability = 'always'`.
--
-- --- ДВА СЛОТА, А НЕ ОДИН И НЕ ТРИ -------------------------------------------------------
-- Один общий слот «декор» обесценил бы вторую покупку: новый предмет прятал бы старый.
-- Три и больше упираются в рисование — каждый предмет нужен в том же визуальном языке, что
-- и питомцы. Два независимых слота дают собранную комнату малой ценой.
--
-- Стена комнаты новым товаром НЕ становится: её рисует уже купленный сезонный фон
-- (SeasonCosmetics.createScene). Это добавляет ценность существующей покупке вместо второго
-- типа фонов, который путал бы: «почему мой фон не в комнате».
--
-- ГРАНИЦЫ. Предметы не влияют ни на одну ось заботы, не ускоряют эволюцию и ничего не дают,
-- кроме внешнего вида. Ни наборов со скидкой, ни случайной выдачи, ни отдельной валюты.
--
-- Товары засеиваются `active = false`: ученик не должен купить лежанку раньше, чем комната
-- научится её показывать. Включение — отдельный release-скрипт после деплоя клиента.
-- =============================================================================

begin;

-- --- 0. PREFLIGHT --------------------------------------------------------------
do $preflight$
begin
  if to_regprocedure('public.get_pet_room(bigint)') is null then
    raise exception '070 ABORT: комната (068/069) не применена';
  end if;
  if exists (select 1 from public.shop_items where slot in ('pet_bed', 'pet_toy')) then
    raise exception '070 ABORT: предметы комнаты уже засеяны';
  end if;
end
$preflight$;

-- --- 1. Новые слоты экипировки --------------------------------------------------
-- Расширение того же check, что вводило слоты avatar (057) и pet (064).
alter table public.shop_items drop constraint if exists shop_items_slot_check;
alter table public.shop_items add constraint shop_items_slot_check
  check (slot in ('name_color', 'crown', 'status_emoji', 'title', 'frame', 'background',
                  'avatar', 'pet', 'pet_bed', 'pet_toy'));

-- --- 2. Каталог предметов (спящий) ----------------------------------------------
-- item_kind='cosmetic' — сознательно, как и у питомца: тогда buy_item, equip_item и инвентарь
-- работают существующим кодом, а unique(student_id, slot) сам держит один предмет на слот.
insert into public.shop_items
  (item_code, name, description, item_kind, slot, price, availability,
   render_payload, visual_key, motion_policy, rarity, sort_order, active)
values
  ('pet_bed_pillow', 'Лежанка: подушка',  'Мягкая подушка, на которой питомец спит.',
   'cosmetic', 'pet_bed', 600, 'always', 'bed_v1_pillow', 'bed_v1_pillow', 'static', 'rare', 620, false),
  ('pet_bed_basket', 'Лежанка: корзинка', 'Плетёная корзинка с бортиками.',
   'cosmetic', 'pet_bed', 600, 'always', 'bed_v1_basket', 'bed_v1_basket', 'static', 'rare', 621, false),
  ('pet_bed_mat',    'Лежанка: коврик',   'Полосатый коврик — просто и удобно.',
   'cosmetic', 'pet_bed', 600, 'always', 'bed_v1_mat',    'bed_v1_mat',    'static', 'rare', 622, false),
  ('pet_toy_ball',   'Игрушка: мячик',    'Мячик, который всегда лежит рядом.',
   'cosmetic', 'pet_toy', 300, 'always', 'toy_v1_ball',   'toy_v1_ball',   'static', 'common', 630, false),
  ('pet_toy_yarn',   'Игрушка: клубок',   'Клубок ниток — классика жанра.',
   'cosmetic', 'pet_toy', 300, 'always', 'toy_v1_yarn',   'toy_v1_yarn',   'static', 'common', 631, false),
  ('pet_toy_block',  'Игрушка: кубик',    'Кубик с буквой — для умных питомцев.',
   'cosmetic', 'pet_toy', 300, 'always', 'toy_v1_block',  'toy_v1_block',  'static', 'common', 632, false)
on conflict (item_code) do nothing;

-- --- 3. Read-модель комнаты отдаёт надетые предметы -------------------------------
-- Тело перенесено из миграции 069 и пропатчено по якорям: добавлены два поля, остальное
-- дословно прежнее.
create or replace function public.get_pet_room(p_student_id bigint)
 returns json
 language plpgsql
 stable
 set search_path = public, pg_temp
as $function$
declare
  v_state     json := public.get_pet_state(p_student_id);
  v_petting   integer;
  v_play      integer;
  v_now       timestamptz := now();
  v_pet_win   timestamptz;
  v_play_win  timestamptz;
  v_pet_done  boolean;
  v_play_done boolean;
  v_bond      integer;
  v_stage     smallint;
  v_ev_price  integer;
  v_ev_bond   integer;
  v_bed       text;
  v_toy       text;
  v_week      boolean;
  v_record    boolean;
  v_promote   boolean;
begin
  select pet_petting_hours, pet_play_hours, pet_evolution_price, pet_evolution_bond
    into v_petting, v_play, v_ev_price, v_ev_bond
    from public.economy_config where id;

  select bond, stage into v_bond, v_stage
    from public.student_pet_state where student_id = p_student_id;

  -- Предметы комнаты — обычная косметика в своих слотах, поэтому берутся тем же способом,
  -- что и питомец: из student_equipment с render_payload из каталога.
  select s.render_payload into v_bed
    from public.student_equipment e
    join public.shop_items s on s.item_code = e.item_code
   where e.student_id = p_student_id and e.slot = 'pet_bed';
  select s.render_payload into v_toy
    from public.student_equipment e
    join public.shop_items s on s.item_code = e.item_code
   where e.student_id = p_student_id and e.slot = 'pet_toy';

  v_pet_win  := date_bin(make_interval(hours => v_petting), v_now, timestamptz '2026-01-01 00:00:00+03');
  v_play_win := date_bin(make_interval(hours => v_play),    v_now, timestamptz '2026-01-01 00:00:00+03');

  v_pet_done := exists (select 1 from public.pet_care_log
                         where student_id = p_student_id and action = 'pet'
                           and window_start = v_pet_win);
  v_play_done := exists (select 1 from public.pet_care_log
                          where student_id = p_student_id and action = 'play'
                            and window_start = v_play_win);

  -- Реакции: только хорошее и только свежее.
  v_week := exists (select 1 from public.student_week_results
                     where student_id = p_student_id and successful
                       and finalized_at >= v_now - interval '7 days');
  v_record := exists (select 1 from public.mock_exam_reward_log
                       where student_id = p_student_id and reward_kind = 'record'
                         and awarded_at >= v_now - interval '7 days');
  v_promote := exists (select 1 from public.league_movements
                        where student_id = p_student_id and kind = 'promote'
                          and created_at >= v_now - interval '30 days');

  return json_build_object(
    'pet',  v_state,
    'bond', coalesce(v_bond, 0),
    'care', json_build_object(
      'petting', json_build_object(
        'available', not v_pet_done,
        'next_at',   case when v_pet_done then v_pet_win + make_interval(hours => v_petting) end,
        'hours',     v_petting),
      'play', json_build_object(
        'available', not v_play_done,
        'next_at',   case when v_play_done then v_play_win + make_interval(hours => v_play) end,
        'hours',     v_play)),
    'room_items', json_build_object(
      'bed', v_bed,
      'toy', v_toy),
    -- Эволюция: сервер отдаёт и прогресс, и чего именно не хватает. Клиент ничего не
    -- досчитывает и не решает, доступна ли кнопка.
    'evolution', json_build_object(
      'stage',          coalesce(v_stage, 1),
      'price',          v_ev_price,
      'bond_required',  v_ev_bond,
      'bond_current',   least(coalesce(v_bond, 0), v_ev_bond),
      'bond_missing',   greatest(v_ev_bond - coalesce(v_bond, 0), 0),
      'available',      coalesce(v_stage, 1) = 1 and coalesce(v_bond, 0) >= v_ev_bond),
    'cheers', json_build_object(
      'good_week',   coalesce(v_week, false),
      'mock_record', coalesce(v_record, false),
      'promoted',    coalesce(v_promote, false)));
end;
$function$;

-- --- 4. POSTFLIGHT ---------------------------------------------------------------
do $postflight$
declare v_cnt integer;
begin
  select count(*) into v_cnt from public.shop_items where slot in ('pet_bed', 'pet_toy');
  if v_cnt <> 6 then
    raise exception '070 ABORT: ожидалось 6 предметов комнаты, найдено %', v_cnt;
  end if;
  if exists (select 1 from public.shop_items where slot in ('pet_bed', 'pet_toy') and active) then
    raise exception '070 ABORT: предмет активен — продажу включает release-скрипт';
  end if;
  -- Главная гарантия решения: предметы комнаты не могут попасть в бонус за коллекцию,
  -- потому что тот считает только availability='rotation'.
  if exists (select 1 from public.shop_items
              where slot in ('pet_bed', 'pet_toy') and availability <> 'always') then
    raise exception '070 ABORT: предмет комнаты попал в ротацию — он окажется в коллекции';
  end if;
  if position('''room_items''' in pg_get_functiondef('public.get_pet_room(bigint)'::regprocedure)) = 0 then
    raise exception '070 ABORT: get_pet_room не отдаёт предметы комнаты';
  end if;
end
$postflight$;

commit;

-- =============================================================================
-- ROLLBACK (до включения продажи безопасен полностью; после — удалит купленные предметы
-- вместе с инвентарём, поэтому сначала снять их с продажи и решать отдельно):
--   begin;
--     -- get_pet_room вернуть телом из миграции 069;
--     delete from public.student_equipment where slot in ('pet_bed', 'pet_toy');
--     delete from public.student_items
--      where item_code in ('pet_bed_pillow','pet_bed_basket','pet_bed_mat',
--                          'pet_toy_ball','pet_toy_yarn','pet_toy_block');
--     delete from public.shop_items where slot in ('pet_bed', 'pet_toy');
--     alter table public.shop_items drop constraint if exists shop_items_slot_check;
--     alter table public.shop_items add constraint shop_items_slot_check
--       check (slot in ('name_color','crown','status_emoji','title','frame','background',
--                       'avatar','pet'));
--   commit;
-- =============================================================================
