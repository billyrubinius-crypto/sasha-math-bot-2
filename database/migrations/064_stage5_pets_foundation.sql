-- =============================================================================
-- 064_stage5_pets_foundation.sql — Stage 5, блок «Питомцы»: каталог, сытость, кормление
-- (Bot 2.0; SPEC_STAGE5_PETS.md, ECONOMY_V4_PROPOSAL.md §4.11)
--
-- ЗАЧЕМ. Питомец — ежедневный ритуал заботы: кормление раз в календарный день MSK по 5
-- бубликов, запас сытости до 7 дней, настроение зависит только от заботы. Никакой смерти,
-- штрафов и связи с учебными результатами.
--
-- --- РЕШЕНИЕ ПО АРХИТЕКТУРЕ (важно, отличается от первоначальной спеки) -------------------
-- Спека предполагала новый `item_kind='pet'` и отдельную ветку в `buy_item`. Проверка кода
-- показала, что это лишнее и вдобавок ломающее: `equip_item` (миграция 053) отвергает всё,
-- у чего `item_kind not in ('cosmetic','service')`, то есть питомца с новым видом нельзя было
-- бы надеть без правки ещё одной функции.
--
-- Поэтому питомец — обычная косметика в НОВОМ СЛОТЕ: `item_kind='cosmetic'`, `slot='pet'`.
-- Тогда без единой правки работают: `buy_item` (ветка cosmetic — проверка «уже куплено»,
-- списание, запись в student_items и автоэкипировка), `equip_item`, `get_student_inventory_self`,
-- проверка `condition_achievement` (нужное нам условие `rhythm_4`) и `unique(student_id, slot)`,
-- который сам гарантирует ровно одного активного питомца. Ни одна существующая функция этой
-- миграцией не переопределяется.
--
-- Питомцы не попадают в альбом коллекций: тот собирается по `availability='rotation'`, а
-- питомцы — `always`. В рендерер сезонной косметики они тоже не попадают: у него явные
-- allowlist по слотам avatar/frame/title/background.
--
-- --- ЭКОНОМИКА (после ребаланса 062) -----------------------------------------------------
--   * питомец 1200 + условие `rhythm_4` (4 успешные недели подряд) — раньше двух периодов
--     его не купит никто, включая профиль 7/7;
--   * корм 5 за день сытости: 70 за период, 8-11% дохода целевого профиля;
--   * запас — до 7 оплаченных дней, считая сегодня (satiety_until <= today + 6).
--
-- ГРАНИЦЫ. Не входят: эволюция, редкие/мифические, Феникс, клички, сон (следующая карточка),
-- любая эмиссия бубликов из питомца, связь настроения с учёбой. Питомцы засеиваются
-- `active=false`: применение миграции не является запуском, firing — отдельный скрипт
-- `database/releases/stage5_pets_cutover.sql`.
--
-- ВАЖНО ПРО ДЕНЬГИ. `add_huikons` обрезает баланс снизу нулём и НЕ падает при нехватке —
-- поэтому `feed_pet` проверяет баланс явно до списания, как это делают `buy_item` и
-- `buy_streak_shield`.
-- =============================================================================

begin;

-- --- 0. PREFLIGHT --------------------------------------------------------------
do $preflight$
begin
  if to_regclass('public.student_pet_state') is not null
     or to_regclass('public.pet_feed_log') is not null then
    raise exception '064 ABORT: таблицы питомцев уже существуют';
  end if;
  if exists (select 1 from public.shop_items where slot = 'pet') then
    raise exception '064 ABORT: в каталоге уже есть предметы слота pet';
  end if;
  if to_regprocedure('public.buy_item(bigint, text, text)') is null
     or to_regprocedure('public.add_huikons(bigint, integer, text)') is null then
    raise exception '064 ABORT: базовые функции магазина не найдены';
  end if;
  -- Цена питомца рассчитана под ребаланс 062: без него 1200 недостижимы.
  if (select price from public.shop_items where item_code = 'crown') <> 1800 then
    raise exception '064 ABORT: ребаланс 062 не применён (корона не 1800) — цены питомца неверны';
  end if;
end
$preflight$;

-- --- 1. Новый слот экипировки --------------------------------------------------
-- Расширение того же check, что вводила миграция 057 для слота avatar.
alter table public.shop_items drop constraint if exists shop_items_slot_check;
alter table public.shop_items add constraint shop_items_slot_check
  check (slot in ('name_color', 'crown', 'status_emoji', 'title', 'frame', 'background',
                  'avatar', 'pet'));

-- --- 2. Конфигурация -----------------------------------------------------------
-- Спящий флаг по образцу stage4_generation_enabled: до firing питомцев нет ни у кого.
alter table public.economy_config
  add column if not exists stage5_pets_enabled  boolean not null default false;
alter table public.economy_config
  add column if not exists pet_feed_price       integer not null default 5;
alter table public.economy_config
  add column if not exists pet_max_prepaid_days integer not null default 7;

alter table public.economy_config drop constraint if exists economy_config_pet_price_check;
alter table public.economy_config add constraint economy_config_pet_price_check
  check (pet_feed_price > 0 and pet_max_prepaid_days between 1 and 30);

comment on column public.economy_config.pet_max_prepaid_days is
  'Сколько дней сытости может быть оплачено, считая сегодняшний: satiety_until <= today + n - 1.';

-- --- 3. Состояние заботы -------------------------------------------------------
-- Состояние на УЧЕНИКА, а не на строку питомца: иначе появляется эксплойт «покормил одного,
-- переключился на второго». Смена активного питомца не создаёт и не сбрасывает запас.
create table if not exists public.student_pet_state (
  student_id     bigint      primary key references public.students (telegram_id),
  satiety_until  date        not null,          -- «сыт до» включительно
  days_fed_total integer     not null default 0 check (days_fed_total >= 0),
  updated_at     timestamptz not null default now(),
  created_at     timestamptz not null default now()
);

-- pet_feed_log — pay-once по КАЛЕНДАРНОЙ ДАТЕ, а не по факту нажатия: один и тот же день
-- нельзя оплатить дважды ни повтором, ни двойным кликом, ни параллельным вызовом.
-- Тот же приём, что у daily_quest_reward_log (student_id, quest_date, reward_kind).
create table if not exists public.pet_feed_log (
  id           uuid        primary key default gen_random_uuid(),
  student_id   bigint      not null references public.students (telegram_id),
  covered_date date        not null,
  bubliks      integer     not null check (bubliks > 0),
  paid_at      timestamptz not null default now(),
  unique (student_id, covered_date)
);
create index if not exists idx_pet_feed_log_student
  on public.pet_feed_log (student_id, covered_date);

-- DENY-CLIENT по образцу миграции 043: ledger и состояние пишут только definer-функции.
alter table public.pet_feed_log enable row level security;
revoke all on public.pet_feed_log from anon, authenticated;

-- student_pet_state тоже DENY-CLIENT, а не select-own: клиент читает состояние исключительно
-- через get_pet_state_self (security definer), прямой select таблицы ему не нужен, а значит
-- и политики заводить незачем — меньше поверхности.
alter table public.student_pet_state enable row level security;
revoke all on public.student_pet_state from anon, authenticated;

-- --- 4. Каталог питомцев (спящий) ----------------------------------------------
-- item_kind='cosmetic' — сознательно, см. шапку. condition_achievement уже проверяется
-- существующим buy_item, кода для условия писать не нужно.
insert into public.shop_items
  (item_code, name, description, item_kind, slot, price, availability,
   condition_achievement, render_payload, visual_key, motion_policy, rarity, sort_order, active)
values
  ('pet_cat',      'Питомец: кот',      'Живёт в профиле, ест раз в день, грустит без корма.',
   'cosmetic', 'pet', 1200, 'always', 'rhythm_4', 'pet_v1_cat',      'pet_v1_cat',      'subtle', 'rare', 610, false),
  ('pet_owl',      'Питомец: сова',     'Живёт в профиле, ест раз в день, грустит без корма.',
   'cosmetic', 'pet', 1200, 'always', 'rhythm_4', 'pet_v1_owl',      'pet_v1_owl',      'subtle', 'rare', 611, false),
  ('pet_capybara', 'Питомец: капибара', 'Живёт в профиле, ест раз в день, грустит без корма.',
   'cosmetic', 'pet', 1200, 'always', 'rhythm_4', 'pet_v1_capybara', 'pet_v1_capybara', 'subtle', 'rare', 612, false)
on conflict (item_code) do nothing;

-- --- 5. feed_pet ---------------------------------------------------------------
-- Оплачивает конкретные КАЛЕНДАРНЫЕ ДАТЫ вперёд, начиная с первой неоплаченной.
-- p_days — сколько дней добавить; потолок запаса — pet_max_prepaid_days, считая сегодня.
create or replace function public.feed_pet(p_student_id bigint, p_days integer default 1)
 returns json
 language plpgsql
 set search_path = public, pg_temp
as $function$
declare
  v_enabled   boolean;
  v_price     integer;
  v_max       integer;
  v_today     date := (now() at time zone 'Europe/Moscow')::date;
  v_pet       text;
  v_satiety   date;
  v_total     integer;
  v_limit     date;
  v_start     date;
  v_end       date;
  v_count     integer;
  v_cost      integer;
  v_balance   integer;
  v_new_balance integer;
begin
  select stage5_pets_enabled, pet_feed_price, pet_max_prepaid_days
    into v_enabled, v_price, v_max
    from public.economy_config where id;
  if not coalesce(v_enabled, false) then
    raise exception 'Питомцы пока недоступны';
  end if;

  if p_days is null or p_days < 1 or p_days > v_max then
    raise exception 'Кормить можно от 1 до % дней за раз', v_max;
  end if;

  select item_code into v_pet
    from public.student_equipment
   where student_id = p_student_id and slot = 'pet';
  if v_pet is null then
    raise exception 'Сначала нужно завести питомца';
  end if;

  -- Блокировка ученика сериализует параллельные кормления (как в buy_item).
  select huikons into v_balance from public.students
   where telegram_id = p_student_id for update;
  if v_balance is null then
    raise exception 'Ученик % не найден', p_student_id;
  end if;

  select satiety_until, days_fed_total into v_satiety, v_total
    from public.student_pet_state where student_id = p_student_id for update;

  -- Первая неоплаченная дата: либо завтрашняя относительно запаса, либо сегодня, если голоден.
  v_start := greatest(coalesce(v_satiety, v_today - 1) + 1, v_today);
  v_limit := v_today + (v_max - 1);
  if v_start > v_limit then
    raise exception 'Питомец уже сыт на % дней вперёд', v_max;
  end if;
  v_end := least(v_start + (p_days - 1), v_limit);

  v_count := (v_end - v_start) + 1;
  v_cost  := v_count * v_price;
  if v_balance < v_cost then
    raise exception 'Недостаточно бубликов: нужно %, есть %', v_cost, v_balance;
  end if;

  -- Уникальный индекс — единственная защита от двойной оплаты дня; предварительная проверка
  -- на неё не заменяется. Реально оплачиваем ровно вставленные строки.
  with wanted as (
    select generate_series(v_start, v_end, interval '1 day')::date as covered_date
  ), inserted as (
    insert into public.pet_feed_log (student_id, covered_date, bubliks)
    select p_student_id, w.covered_date, v_price from wanted w
    on conflict (student_id, covered_date) do nothing
    returning covered_date
  )
  select count(*), max(covered_date) into v_count, v_end from inserted;

  if coalesce(v_count, 0) = 0 then
    raise exception 'Эти дни уже оплачены';
  end if;

  v_cost := v_count * v_price;
  select new_balance into v_new_balance
    from public.add_huikons(p_student_id, -v_cost, 'pet_feed');

  insert into public.student_pet_state (student_id, satiety_until, days_fed_total)
    values (p_student_id, v_end, v_count)
    on conflict (student_id) do update
      set satiety_until  = greatest(student_pet_state.satiety_until, excluded.satiety_until),
          days_fed_total = student_pet_state.days_fed_total + excluded.days_fed_total,
          updated_at     = now();

  return json_build_object(
    'days_paid',      v_count,
    'spent',          v_cost,
    'satiety_until',  v_end,
    'balance',        v_new_balance);
end;
$function$;

-- --- 6. Read-модель ------------------------------------------------------------
-- Настроение считает сервер: клиент не знает ни правил, ни таймзоны расчёта.
create or replace function public.get_pet_state(p_student_id bigint)
 returns json
 language plpgsql
 stable
 set search_path = public, pg_temp
as $function$
declare
  v_enabled boolean;
  v_price   integer;
  v_max     integer;
  v_today   date := (now() at time zone 'Europe/Moscow')::date;
  v_pet     text;
  v_payload text;
  v_name    text;
  v_satiety date;
  v_total   integer := 0;
  v_days    integer;
  v_mood    text;
begin
  select stage5_pets_enabled, pet_feed_price, pet_max_prepaid_days
    into v_enabled, v_price, v_max
    from public.economy_config where id;

  select e.item_code, s.render_payload, s.name into v_pet, v_payload, v_name
    from public.student_equipment e
    join public.shop_items s on s.item_code = e.item_code
   where e.student_id = p_student_id and e.slot = 'pet';

  select satiety_until, days_fed_total into v_satiety, v_total
    from public.student_pet_state where student_id = p_student_id;

  v_days := case when v_satiety is null or v_satiety < v_today
                 then 0 else (v_satiety - v_today) + 1 end;

  v_mood := case
    when v_satiety is null or v_satiety < v_today then 'hungry'
    when v_satiety = v_today                      then 'hungry_soon'
    when v_satiety = v_today + 1                  then 'fed'
    else 'happy'
  end;

  return json_build_object(
    'enabled',           coalesce(v_enabled, false),
    'item_code',         v_pet,
    'name',              v_name,
    'render_payload',    v_payload,
    'satiety_until',     v_satiety,
    'days_left',         v_days,
    'mood',              case when v_pet is null then null else v_mood end,
    'days_fed_total',    coalesce(v_total, 0),
    'feed_price',        v_price,
    'max_prepaid_days',  v_max);
end;
$function$;

-- --- 7. Гейтвеи T10 ------------------------------------------------------------
-- Тонкие claim-based обёртки по образцу buy_item_self (миграция 035): identity из JWT,
-- p_student_id наружу не принимается.
create or replace function public.feed_pet_self(p_days integer default 1)
 returns json language plpgsql security definer set search_path = public, pg_temp
as $function$
declare v_tid bigint;
begin
  if private.current_app_role() is distinct from 'student' then
    raise exception 'forbidden' using errcode = '42501'; end if;
  v_tid := private.current_telegram_id();
  if v_tid is null or v_tid <= 0 then
    raise exception 'no student identity' using errcode = '42501'; end if;
  return public.feed_pet(v_tid, p_days);
end;
$function$;

create or replace function public.get_pet_state_self()
 returns json language plpgsql security definer set search_path = public, pg_temp
as $function$
declare v_tid bigint;
begin
  if private.current_app_role() is distinct from 'student' then
    raise exception 'forbidden' using errcode = '42501'; end if;
  v_tid := private.current_telegram_id();
  if v_tid is null or v_tid <= 0 then
    raise exception 'no student identity' using errcode = '42501'; end if;
  return public.get_pet_state(v_tid);
end;
$function$;

revoke all on function public.feed_pet(bigint, integer)      from public, anon, authenticated;
revoke all on function public.get_pet_state(bigint)          from public, anon, authenticated;
revoke all on function public.feed_pet_self(integer)         from public, anon;
revoke all on function public.get_pet_state_self()           from public, anon;
grant execute on function public.feed_pet_self(integer)      to authenticated;
grant execute on function public.get_pet_state_self()        to authenticated;

-- --- 8. POSTFLIGHT: dev обязан остаться спящим ---------------------------------
do $postflight$
declare v_cnt integer;
begin
  select count(*) into v_cnt from public.shop_items where slot = 'pet';
  if v_cnt <> 3 then
    raise exception '064 ABORT: ожидалось 3 питомца, найдено %', v_cnt;
  end if;
  if exists (select 1 from public.shop_items where slot = 'pet' and active) then
    raise exception '064 ABORT: питомец активен — миграция не должна включать продажу';
  end if;
  if exists (select 1 from public.shop_items where slot = 'pet'
              and (price <> 1200 or condition_achievement is distinct from 'rhythm_4')) then
    raise exception '064 ABORT: цена или условие покупки питомца отличаются от утверждённых';
  end if;
  if (select stage5_pets_enabled from public.economy_config where id) then
    raise exception '064 ABORT: stage5_pets_enabled включён — это делает release-скрипт';
  end if;
end
$postflight$;

commit;

-- =============================================================================
-- ROLLBACK (до firing безопасен полностью; после firing удалит купленных питомцев вместе с
-- инвентарём — тогда сначала снять их с продажи и решать отдельно):
--   begin;
--     drop function if exists public.feed_pet_self(integer);
--     drop function if exists public.get_pet_state_self();
--     drop function if exists public.feed_pet(bigint, integer);
--     drop function if exists public.get_pet_state(bigint);
--     delete from public.student_equipment where slot = 'pet';
--     delete from public.student_items where item_code in ('pet_cat','pet_owl','pet_capybara');
--     delete from public.shop_items where slot = 'pet';
--     drop table if exists public.pet_feed_log;
--     drop table if exists public.student_pet_state;
--     alter table public.economy_config drop constraint if exists economy_config_pet_price_check;
--     alter table public.economy_config drop column if exists stage5_pets_enabled;
--     alter table public.economy_config drop column if exists pet_feed_price;
--     alter table public.economy_config drop column if exists pet_max_prepaid_days;
--     alter table public.shop_items drop constraint if exists shop_items_slot_check;
--     alter table public.shop_items add constraint shop_items_slot_check
--       check (slot in ('name_color','crown','status_emoji','title','frame','background','avatar'));
--   commit;
-- =============================================================================
