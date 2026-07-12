-- Миграция 008 — ядро магазина «Бубличная» (задача S1, этап 2)
--
-- Что создаёт: каталог товаров (shop_items), привязку ротации к сезонам (season_bundles),
-- экипировку по слотам (student_equipment), RPC ensure_season_rotation / buy_item /
-- equip_item, сид каталога этапа 2 (SPEC_STAGE2.md раздел 1, решения 1–7 утверждены
-- пользователем 2026-07-12; S8 — персональный титул — отложен, в сиде отсутствует).
--
-- Владение НЕ дублируется: купленная косметика лежит в существующей student_items
-- (quantity=1), щит стрика продолжает жить своей механикой G9.
--
-- ---------------------------------------------------------------------------
-- РЕШЕНИЯ (требование карточки S1 — зафиксировать здесь):
--
-- 1. ЕДИНАЯ RPC buy_item(student, item_code, variant) вместо RPC-на-товар.
--    Для щита стрика buy_item ДЕЛЕГИРУЕТ в существующую buy_streak_shield (правило 2
--    BOT2_CONTEXT: не дублировать логику — лимит 2 и цена щита остаются в одном месте).
--    UI зовёт одну функцию для всей витрины.
--
-- 2. РОТАЦИЯ ЧЕРЕЗ БАНДЛЫ. Ротационные товары собраны в пронумерованные наборы-витрины
--    (shop_items.rotation_bundle, по 4 товара — «3–4 сезонных товара», §4 принцип 2).
--    season_bundles: одна строка на сезон = какой бандл на витрине. Назначение ленивое
--    (ensure_season_rotation): первый, кто открыл магазин в новом сезоне, забирает
--    МИНИМАЛЬНЫЙ ещё не использованный бандл. Гонка безопасна: PK(season_id) +
--    on conflict do nothing + перечитывание. unique(bundle) даёт «потом — никогда»
--    для легендарных рамок на уровне схемы: использованный бандл не вернётся.
--    Пул кончился → ensure возвращает null, витрина показывает только постоянные
--    товары (кейс из карточки S4). Пополнение пула — insert новых бандлов в Supabase.
--
-- 3. ЭКИПИРОВКА student_equipment(student_id, slot, item_code, variant):
--    unique(student_id, slot) — в слоте одна вещь; слоты: name_color / crown /
--    status_emoji / title / frame / background (проверка — check на shop_items.slot;
--    сама student_equipment.slot без check — S7 добавит showcase_1..3 без миграции).
--    variant — для эмодзи-статуса (решение 3: «30 за смену» — сервис-операция, одна
--    строка каталога, выбранный эмодзи хранится в variant, инвентаря нет).
--    Переключение купленного и снятие — бесплатно (equip_item); слот status_emoji
--    через equip_item менять нельзя (только оплатой), снять — можно.
--
-- 4. АВТОЭКИПИРОВКА: купленная косметика сразу надевается в свой слот (купил рамку —
--    носишь; UI может переодеть/снять). Золотой ник — обычный товар слота name_color
--    (решение 5: премиум-значение цвета, render_payload='gold', совместим с короной).
--
-- 5. БАЛАНС ПРОВЕРЯЕТСЯ ЯВНО под for update ДО add_huikons: add_huikons клампит баланс
--    нулём и НЕ отклоняет недостачу — покупка без явной проверки списала бы «сколько
--    есть». Паттерн тот же, что в buy_streak_shield.
--
-- 6. УСЛОВНЫЕ ТОВАРЫ: condition_achievement проверяется ВНУТРИ buy_item по
--    student_achievements (не только в UI — требование карточки S5).
--
-- 7. reason в balance_history: 'buy_' || item_code (продолжение паттерна
--    'buy_streak_shield' из G9).
--
-- RLS выключается на всех новых таблицах явно (урок G9: dev-Supabase включает RLS
-- на новых таблицах молча; принятый риск T10, как во всём проекте).
-- ---------------------------------------------------------------------------

-- --- Каталог -----------------------------------------------------------------

create table if not exists public.shop_items (
  item_code             text         primary key,
  name                  text         not null,             -- отображаемое имя на витрине
  item_kind             text         not null check (item_kind in ('cosmetic','shield','service')),
  slot                  text         check (slot in ('name_color','crown','status_emoji','title','frame','background')),
  price                 integer      not null check (price > 0),
  availability          text         not null check (availability in ('always','rotation')),
  rotation_bundle       integer,                            -- null для постоянных товаров
  condition_achievement text,                               -- код из student_achievements или null
  render_payload        text,                               -- hex цвета / css-класс / 'gold' / пул эмодзи; null = использовать name (титулы)
  sort_order            integer      not null default 100,
  active                boolean      not null default true, -- мягкое снятие с продажи без удаления
  created_at            timestamptz  not null default now(),
  check ((availability = 'rotation') = (rotation_bundle is not null))
);

alter table public.shop_items disable row level security;

-- --- Ротация: какой бандл на витрине какого сезона ----------------------------

create table if not exists public.season_bundles (
  season_id  bigint       primary key references public.seasons (id),
  bundle     integer      not null unique,   -- unique = использованный набор не возвращается
  created_at timestamptz  not null default now()
);

alter table public.season_bundles disable row level security;

-- --- Экипировка ----------------------------------------------------------------

create table if not exists public.student_equipment (
  id          uuid         primary key default gen_random_uuid(),
  student_id  bigint       not null references public.students (telegram_id),
  slot        text         not null,
  item_code   text         not null references public.shop_items (item_code),
  variant     text,                          -- выбранный эмодзи для status_emoji, иначе null
  updated_at  timestamptz  not null default now(),
  created_at  timestamptz  not null default now(),
  unique (student_id, slot)
);

create index if not exists idx_student_equipment_student
  on public.student_equipment (student_id);

alter table public.student_equipment disable row level security;

-- --- ensure_season_rotation: ленивое назначение бандла открытому сезону ---------

create or replace function public.ensure_season_rotation()
 returns integer
 language plpgsql
as $function$
declare
  v_season bigint;
  v_bundle integer;
begin
  select id into v_season from seasons where end_date is null order by id desc limit 1;
  if v_season is null then
    return null;                             -- сезона ещё нет (создаст getCurrentSeasonId, G7)
  end if;

  select bundle into v_bundle from season_bundles where season_id = v_season;
  if v_bundle is not null then
    return v_bundle;
  end if;

  select min(rotation_bundle) into v_bundle
    from shop_items
    where rotation_bundle is not null
      and active
      and rotation_bundle not in (select bundle from season_bundles);
  if v_bundle is null then
    return null;                             -- пул витрин исчерпан — только постоянные товары
  end if;

  insert into season_bundles (season_id, bundle)
    values (v_season, v_bundle)
    on conflict (season_id) do nothing;      -- гонка: кто-то назначил первым — не страшно

  select bundle into v_bundle from season_bundles where season_id = v_season;
  return v_bundle;
end;
$function$;

-- --- buy_item: единая атомарная покупка ------------------------------------------

create or replace function public.buy_item(p_student_id bigint, p_item_code text, p_variant text default null)
 returns json
 language plpgsql
as $function$
declare
  v_item     shop_items%rowtype;
  v_bundle   integer;
  v_balance  integer;
  v_new_balance integer;
begin
  select * into v_item from shop_items where item_code = p_item_code and active;
  if v_item.item_code is null then
    raise exception 'Товар % не найден или снят с продажи', p_item_code;
  end if;

  -- Щит стрика: делегируем в проверенную RPC G9 (лимит 2, цена — там)
  if v_item.item_kind = 'shield' then
    return buy_streak_shield(p_student_id);
  end if;

  -- Ротация: товар должен быть на витрине ТЕКУЩЕГО сезона
  if v_item.availability = 'rotation' then
    v_bundle := ensure_season_rotation();
    if v_bundle is null or v_bundle <> v_item.rotation_bundle then
      raise exception 'Товар «%» сейчас не на витрине', v_item.name;
    end if;
  end if;

  -- Условие-достижение (проверка на стороне БД, не только в UI)
  if v_item.condition_achievement is not null then
    if not exists (select 1 from student_achievements
                     where student_id = p_student_id
                       and achievement_code = v_item.condition_achievement) then
      raise exception 'Для покупки «%» нужно достижение', v_item.name;
    end if;
  end if;

  -- Сервис (смена эмодзи-статуса): вариант обязателен и из пула
  if v_item.item_kind = 'service' then
    if p_variant is null or position(p_variant in coalesce(v_item.render_payload, '')) = 0 then
      raise exception 'Недопустимый вариант для «%»', v_item.name;
    end if;
  end if;

  -- Косметика: повторная покупка владения запрещена
  if v_item.item_kind = 'cosmetic' then
    if exists (select 1 from student_items
                 where student_id = p_student_id and item_code = p_item_code) then
      raise exception 'Уже куплено';
    end if;
  end if;

  -- Баланс: явная проверка под замком (add_huikons клампит нулём, а не отклоняет)
  select huikons into v_balance from students where telegram_id = p_student_id for update;
  if v_balance is null then
    raise exception 'Ученик % не найден', p_student_id;
  end if;
  if v_balance < v_item.price then
    raise exception 'Недостаточно бубликов: нужно %, есть %', v_item.price, v_balance;
  end if;

  select new_balance into v_new_balance
    from add_huikons(p_student_id, -v_item.price, 'buy_' || p_item_code);

  if v_item.item_kind = 'cosmetic' then
    insert into student_items (student_id, item_code, quantity)
      values (p_student_id, p_item_code, 1);          -- unique(student_id,item_code): гонка двух покупок откатит вторую целиком
    -- автоэкипировка в слот товара
    insert into student_equipment (student_id, slot, item_code)
      values (p_student_id, v_item.slot, p_item_code)
      on conflict (student_id, slot)
      do update set item_code = excluded.item_code, variant = null, updated_at = now();
  elsif v_item.item_kind = 'service' then
    -- владения нет — оплаченная операция сразу пишет эффект в экипировку
    insert into student_equipment (student_id, slot, item_code, variant)
      values (p_student_id, v_item.slot, p_item_code, p_variant)
      on conflict (student_id, slot)
      do update set item_code = excluded.item_code, variant = excluded.variant, updated_at = now();
  end if;

  return json_build_object('item_code', p_item_code, 'balance', v_new_balance);
end;
$function$;

-- --- equip_item: бесплатное переодевание купленного / снятие ---------------------

create or replace function public.equip_item(p_student_id bigint, p_slot text, p_item_code text default null)
 returns void
 language plpgsql
as $function$
declare
  v_slot text;
begin
  if p_item_code is null then
    delete from student_equipment where student_id = p_student_id and slot = p_slot;
    return;                                   -- снятие бесплатно для любого слота
  end if;

  if p_slot = 'status_emoji' then
    raise exception 'Эмодзи-статус меняется только покупкой смены';
  end if;

  select slot into v_slot from shop_items where item_code = p_item_code and active;
  if v_slot is null or v_slot <> p_slot then
    raise exception 'Товар % не подходит слоту %', p_item_code, p_slot;
  end if;

  if not exists (select 1 from student_items
                   where student_id = p_student_id and item_code = p_item_code) then
    raise exception 'Сначала нужно купить этот предмет';
  end if;

  insert into student_equipment (student_id, slot, item_code)
    values (p_student_id, p_slot, p_item_code)
    on conflict (student_id, slot)
    do update set item_code = excluded.item_code, variant = null, updated_at = now();
end;
$function$;

-- --- Сид каталога этапа 2 (решение 7; повторный прогон безопасен) -----------------

insert into public.shop_items
  (item_code, name, item_kind, slot, price, availability, rotation_bundle, condition_achievement, render_payload, sort_order)
values
  -- Постоянная витрина
  ('streak_shield',      'Щит стрика',                'shield',   null,          40,  'always', null, null, null,        10),
  ('color_red',          'Цвет ника: алый',           'cosmetic', 'name_color',  50,  'always', null, null, '#e53935',   20),
  ('color_orange',       'Цвет ника: апельсин',       'cosmetic', 'name_color',  50,  'always', null, null, '#f57c00',   21),
  ('color_green',        'Цвет ника: изумруд',        'cosmetic', 'name_color',  50,  'always', null, null, '#43a047',   22),
  ('color_teal',         'Цвет ника: морской',        'cosmetic', 'name_color',  50,  'always', null, null, '#00897b',   23),
  ('color_blue',         'Цвет ника: небесный',       'cosmetic', 'name_color',  50,  'always', null, null, '#1e88e5',   24),
  ('color_indigo',       'Цвет ника: индиго',         'cosmetic', 'name_color',  50,  'always', null, null, '#5e35b1',   25),
  ('color_pink',         'Цвет ника: малиновый',      'cosmetic', 'name_color',  50,  'always', null, null, '#d81b60',   26),
  ('color_brown',        'Цвет ника: шоколад',        'cosmetic', 'name_color',  50,  'always', null, null, '#6d4c41',   27),
  ('status_emoji_change','Смена эмодзи-статуса',      'service',  'status_emoji',30,  'always', null, null, '🎯 🚀 🧠 📈 🔥 😤 🐢 ☕ 🌙 🏆', 30),
  ('crown',              'Корона у ника 👑',          'cosmetic', 'crown',       600, 'always', null, null, '👑',        40),
  ('golden_nick',        'Золотой ник',               'cosmetic', 'name_color',  700, 'always', null, null, 'gold',      41),
  ('title_yaschenko',    'Титул «Ященко»',            'cosmetic', 'title',       900, 'always', null, null, null,        42),
  ('frame_fire100',      'Рамка «100 дней огня» 🔥',  'cosmetic', 'frame',       2500,'always', null, 'streak_100', 'frame-fire100', 50),

  -- Бандл 1 (витрина первого сезона магазина)
  ('frame_notebook',     'Рамка «Тетрадная клетка»',  'cosmetic', 'frame',       150, 'rotation', 1, null, 'frame-notebook', 110),
  ('bg_grid',            'Фон «Миллиметровка»',       'cosmetic', 'background',  200, 'rotation', 1, null, 'bg-grid',    111),
  ('title_groza',        'Титул «Гроза параметров»',  'cosmetic', 'title',       200, 'rotation', 1, null, null,         112),
  ('frame_legend_1',     'Легендарная рамка «Сезон первый»','cosmetic','frame',  1500,'rotation', 1, null, 'frame-legend-1', 113),

  -- Бандл 2
  ('frame_pulsar',       'Анимированная рамка «Пульсар»','cosmetic','frame',     750, 'rotation', 2, null, 'frame-pulsar', 120),
  ('bg_space',           'Фон «Космос»',              'cosmetic', 'background',  200, 'rotation', 2, null, 'bg-space',   121),
  ('title_elon',         'Титул «Илон Маск»',         'cosmetic', 'title',       150, 'rotation', 2, null, null,         122),
  ('frame_legend_2',     'Легендарная рамка «Золотая осень»','cosmetic','frame', 1500,'rotation', 2, null, 'frame-legend-2', 123),

  -- Бандл 3
  ('frame_winter',       'Рамка «Зимняя»',            'cosmetic', 'frame',       150, 'rotation', 3, null, 'frame-winter', 130),
  ('bg_aurora',          'Фон «Северное сияние»',     'cosmetic', 'background',  200, 'rotation', 3, null, 'bg-aurora',  131),
  ('title_sanchez',      'Титул «Санчез»',            'cosmetic', 'title',       120, 'rotation', 3, null, null,         132),
  ('frame_legend_3',     'Легендарная рамка «Зимний апекс»','cosmetic','frame',  1500,'rotation', 3, null, 'frame-legend-3', 133),

  -- Бандл 4
  ('frame_orbit',        'Анимированная рамка «Орбита»','cosmetic','frame',      750, 'rotation', 4, null, 'frame-orbit', 140),
  ('bg_draft',           'Фон «Черновик гения»',      'cosmetic', 'background',  200, 'rotation', 4, null, 'bg-draft',   141),
  ('title_derivative',   'Титул «Держу производную»', 'cosmetic', 'title',       150, 'rotation', 4, null, null,         142),
  ('frame_legend_4',     'Легендарная рамка «Предэкзаменационная»','cosmetic','frame',1500,'rotation',4, null, 'frame-legend-4', 143)
on conflict (item_code) do nothing;
