-- =============================================================================
-- 068_pet_room_care_axes.sql — PET1: оси внимания и игры, связь, read-модель комнаты
-- (Bot 2.0, Stage 5; SPEC_STAGE5_PET_ROOM.md, карточка tasks/PET1.md)
--
-- ЗАЧЕМ. Питомец превращается в тамагочи: к платной оси (корм) и бесплатной (сон) добавляются
-- ещё две бесплатные — погладить и поиграть, — а вместо «здоровья» вводится накопительная
-- СВЯЗЬ, которая только растёт. Пропуск ничего не отнимает: это и есть замена смерти.
--
-- --- РЕШЕНИЕ, УТОЧНЁННОЕ ПРИ РЕАЛИЗАЦИИ --------------------------------------------------
-- Карточка PET1 говорила «bond +1 за каждое засчитанное действие». Так считать нельзя: при
-- четырёх осях выходит 4-6 инкрементов в сутки, и «60 дней заботы» из условия эволюции
-- набирались бы за две недели тапами, а не заботой.
--
-- Поэтому bond считает ДНИ С ЗАБОТОЙ: +1 в тот календарный день MSK, когда ученик впервые
-- сделал любое действие любой оси; второе и последующие действия того же дня связь не двигают.
-- Тогда bond буквально означает то, что написано в условии эволюции, его нельзя нафармить
-- нажатиями и нельзя купить: оплата семи дней корма вперёд — это забота за один день.
--
-- ГРАНИЦЫ. Не входят: предметы комнаты (PET3), эволюция (PET4), клиент (PET2). Ни одно
-- действие не даёт бубликов, очков сезона, места в лиге и не пишет в учебные таблицы.
-- get_pet_state НЕ меняется: её зовёт уже задеплоенный клиент.
-- =============================================================================

begin;

-- --- 0. PREFLIGHT --------------------------------------------------------------
do $preflight$
begin
  if to_regclass('public.student_pet_state') is null then
    raise exception '068 ABORT: питомцы (064) не применены';
  end if;
  if to_regclass('public.pet_care_log') is not null then
    raise exception '068 ABORT: pet_care_log уже существует';
  end if;
  if to_regprocedure('public.put_pet_to_sleep(bigint)') is null then
    raise exception '068 ABORT: сон (065) не применён';
  end if;
end
$preflight$;

-- --- 1. Кулдауны бесплатных осей -----------------------------------------------
alter table public.economy_config
  add column if not exists pet_petting_hours integer not null default 6;
alter table public.economy_config
  add column if not exists pet_play_hours    integer not null default 12;

alter table public.economy_config drop constraint if exists economy_config_pet_care_check;
alter table public.economy_config add constraint economy_config_pet_care_check
  check (pet_petting_hours between 1 and 168 and pet_play_hours between 1 and 168);

-- --- 2. Журнал заботы ----------------------------------------------------------
-- window_start — начало текущего окна кулдауна от неподвижной опорной точки. Уникальный
-- индекс — единственная защита от повторного засчитывания: двойной клик, retry и параллельный
-- вызов дают ровно одну строку. Тот же приём, что в pet_feed_log (student_id, covered_date).
create table if not exists public.pet_care_log (
  id           uuid        primary key default gen_random_uuid(),
  student_id   bigint      not null references public.students (telegram_id),
  action       text        not null check (action in ('pet', 'play')),
  window_start timestamptz not null,
  created_at   timestamptz not null default now(),
  unique (student_id, action, window_start)
);
create index if not exists idx_pet_care_log_student
  on public.pet_care_log (student_id, created_at);

alter table public.pet_care_log enable row level security;   -- DENY-CLIENT (образец 043)
revoke all on public.pet_care_log from anon, authenticated;

-- --- 3. Связь ------------------------------------------------------------------
alter table public.student_pet_state
  add column if not exists bond integer not null default 0 check (bond >= 0);
alter table public.student_pet_state
  add column if not exists last_bond_date date;

comment on column public.student_pet_state.bond is
  'Дни с заботой: +1 в первый за календарный день MSK уход любой оси. Только растёт.';

-- pet_touch_bond — единственная точка роста связи, её зовут все четыре оси.
-- Идемпотентность внутри суток держится на last_bond_date, а не на подсчёте действий.
create or replace function public.pet_touch_bond(p_student_id bigint)
 returns integer
 language plpgsql
 set search_path = public, pg_temp
as $function$
declare
  v_today date := (now() at time zone 'Europe/Moscow')::date;
  v_bond  integer;
begin
  insert into public.student_pet_state (student_id, bond, last_bond_date)
    values (p_student_id, 1, v_today)
    on conflict (student_id) do update
      set bond           = student_pet_state.bond
                           + case when student_pet_state.last_bond_date is distinct from excluded.last_bond_date
                                  then 1 else 0 end,
          last_bond_date = excluded.last_bond_date,
          updated_at     = now()
    returning bond into v_bond;
  return v_bond;
end;
$function$;

-- --- 4. Существующие оси теперь двигают связь -----------------------------------
-- Тела перенесены из миграций 064 и 065 без изменений; добавлена ровно одна строка вызова
-- pet_touch_bond. Суммы, идемпотентность, тексты ошибок и контракт возврата прежние.
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

  perform public.pet_touch_bond(p_student_id);   -- PET1: день заботы засчитан

  return json_build_object(
    'days_paid',      v_count,
    'spent',          v_cost,
    'satiety_until',  v_end,
    'balance',        v_new_balance);
end;
$function$;

create or replace function public.put_pet_to_sleep(p_student_id bigint)
 returns json
 language plpgsql
 set search_path = public, pg_temp
as $function$
declare
  v_enabled boolean;
  v_sleep   integer;
  v_pet     text;
  v_start   timestamptz;
  v_now     timestamptz := now();
begin
  select stage5_pets_enabled, pet_sleep_hours into v_enabled, v_sleep
    from public.economy_config where id;
  if not coalesce(v_enabled, false) then
    raise exception 'Питомцы пока недоступны';
  end if;

  select item_code into v_pet
    from public.student_equipment
   where student_id = p_student_id and slot = 'pet';
  if v_pet is null then
    raise exception 'Сначала нужно завести питомца';
  end if;

  -- Блокировка строки ученика сериализует параллельные вызовы (как в feed_pet).
  perform 1 from public.students where telegram_id = p_student_id for update;

  select sleep_started_at into v_start
    from public.student_pet_state where student_id = p_student_id for update;

  if v_start is not null and v_start + make_interval(hours => v_sleep) > v_now then
    raise exception 'Питомец уже спит';
  end if;

  -- Предыдущий сон, если он был, засчитывается как состоявшийся отдых: он закончился сам.
  insert into public.student_pet_state (student_id, sleep_started_at, last_rested_at)
    values (p_student_id, v_now,
            case when v_start is not null then v_start + make_interval(hours => v_sleep) end)
    on conflict (student_id) do update
      set sleep_started_at = excluded.sleep_started_at,
          last_rested_at   = greatest(student_pet_state.last_rested_at, excluded.last_rested_at),
          updated_at       = now();

  perform public.pet_touch_bond(p_student_id);   -- PET1: день заботы засчитан

  return json_build_object(
    'sleep_started_at', v_now,
    'sleep_ends_at',    v_now + make_interval(hours => v_sleep));
end;
$function$;

-- --- 5. pet_care: погладить и поиграть ------------------------------------------
create or replace function public.pet_care(p_student_id bigint, p_action text)
 returns json
 language plpgsql
 set search_path = public, pg_temp
as $function$
declare
  v_enabled boolean;
  v_hours   integer;
  v_pet     text;
  v_now     timestamptz := now();
  v_window  timestamptz;
  v_rows    integer;
  v_bond    integer;
begin
  if p_action is null or p_action not in ('pet', 'play') then
    raise exception 'Неизвестное действие';
  end if;

  select stage5_pets_enabled,
         case when p_action = 'pet' then pet_petting_hours else pet_play_hours end
    into v_enabled, v_hours
    from public.economy_config where id;
  if not coalesce(v_enabled, false) then
    raise exception 'Питомцы пока недоступны';
  end if;

  select item_code into v_pet
    from public.student_equipment
   where student_id = p_student_id and slot = 'pet';
  if v_pet is null then
    raise exception 'Сначала нужно завести питомца';
  end if;

  -- Окно кулдауна отсчитывается от неподвижной опорной точки: оно одинаково для всех учеников
  -- и не зависит от того, когда именно было сделано первое действие.
  v_window := date_bin(make_interval(hours => v_hours), v_now, timestamptz '2026-01-01 00:00:00+03');

  insert into public.pet_care_log (student_id, action, window_start)
    values (p_student_id, p_action, v_window)
    on conflict (student_id, action, window_start) do nothing;
  get diagnostics v_rows = row_count;
  if v_rows = 0 then
    raise exception 'Это уже сделано, можно будет повторить позже';
  end if;

  v_bond := public.pet_touch_bond(p_student_id);

  return json_build_object(
    'action',  p_action,
    'next_at', v_window + make_interval(hours => v_hours),
    'bond',    v_bond);
end;
$function$;

-- --- 6. Read-модель комнаты ------------------------------------------------------
-- Отдаёт состояние комнаты одним объектом. Реакции читают уже существующие факты и ничего не
-- пишут; плохих событий в контракте НЕТ вовсе — клиент физически не может их показать.
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
  v_week      boolean;
  v_record    boolean;
  v_promote   boolean;
begin
  select pet_petting_hours, pet_play_hours into v_petting, v_play
    from public.economy_config where id;

  select bond into v_bond from public.student_pet_state where student_id = p_student_id;

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
    'cheers', json_build_object(
      'good_week',   coalesce(v_week, false),
      'mock_record', coalesce(v_record, false),
      'promoted',    coalesce(v_promote, false)));
end;
$function$;

-- --- 7. Гейтвеи ------------------------------------------------------------------
create or replace function public.pet_care_self(p_action text)
 returns json language plpgsql security definer set search_path = public, pg_temp
as $function$
declare v_tid bigint;
begin
  if private.current_app_role() is distinct from 'student' then
    raise exception 'forbidden' using errcode = '42501'; end if;
  v_tid := private.current_telegram_id();
  if v_tid is null or v_tid <= 0 then
    raise exception 'no student identity' using errcode = '42501'; end if;
  return public.pet_care(v_tid, p_action);
end;
$function$;

create or replace function public.get_pet_room_self()
 returns json language plpgsql security definer set search_path = public, pg_temp
as $function$
declare v_tid bigint;
begin
  if private.current_app_role() is distinct from 'student' then
    raise exception 'forbidden' using errcode = '42501'; end if;
  v_tid := private.current_telegram_id();
  if v_tid is null or v_tid <= 0 then
    raise exception 'no student identity' using errcode = '42501'; end if;
  return public.get_pet_room(v_tid);
end;
$function$;

revoke all on function public.pet_touch_bond(bigint) from public, anon, authenticated;
revoke all on function public.pet_care(bigint, text)  from public, anon, authenticated;
revoke all on function public.get_pet_room(bigint)    from public, anon, authenticated;
revoke all on function public.pet_care_self(text)     from public, anon;
revoke all on function public.get_pet_room_self()     from public, anon;
grant execute on function public.pet_care_self(text)  to authenticated;
grant execute on function public.get_pet_room_self()  to authenticated;

-- --- 8. POSTFLIGHT ---------------------------------------------------------------
do $postflight$
begin
  if to_regprocedure('public.pet_care_self(text)') is null
     or to_regprocedure('public.get_pet_room_self()') is null then
    raise exception '068 ABORT: гейтвеи не созданы';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'student_pet_state'
                    and column_name = 'bond') then
    raise exception '068 ABORT: связь не добавлена';
  end if;
  if to_regprocedure('public.get_pet_state(bigint)') is null then
    raise exception '068 ABORT: get_pet_state исчезла — её зовёт задеплоенный клиент';
  end if;
end
$postflight$;

commit;

-- =============================================================================
-- ROLLBACK:
--   begin;
--     drop function if exists public.pet_care_self(text);
--     drop function if exists public.get_pet_room_self();
--     drop function if exists public.pet_care(bigint, text);
--     drop function if exists public.get_pet_room(bigint);
--     -- feed_pet вернуть телом из миграции 064, put_pet_to_sleep — из 065 (без pet_touch_bond),
--     -- и только после этого:
--     drop function if exists public.pet_touch_bond(bigint);
--     drop table if exists public.pet_care_log;
--     alter table public.student_pet_state drop column if exists bond;
--     alter table public.student_pet_state drop column if exists last_bond_date;
--     alter table public.economy_config drop constraint if exists economy_config_pet_care_check;
--     alter table public.economy_config drop column if exists pet_petting_hours;
--     alter table public.economy_config drop column if exists pet_play_hours;
--   commit;
-- =============================================================================
