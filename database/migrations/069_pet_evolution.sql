-- =============================================================================
-- 069_pet_evolution.sql — PET4: вторая ступень питомца
-- (Bot 2.0, Stage 5; SPEC_STAGE5_PET_ROOM.md §1, карточка tasks/PET4.md)
--
-- ЗАЧЕМ. Видимый результат долгой заботы, который нельзя купить сразу: эволюция требует
-- И денег, И времени — 1500 бубликов плюс 60 дней заботы по `bond`.
--
-- ПОЧЕМУ ИМЕННО bond. Он растёт от всех четырёх осей, а `days_fed_total` — только от платной.
-- Считать по кормлению значило бы сделать бесплатные оси декоративными, а эволюцию — чисто
-- денежной целью (решение пользователя 2026-08-01). И поскольку bond считает ДНИ, а не
-- нажатия (миграция 068), 60 дней нельзя ни нафармить тапами, ни купить оптом: оплата семи
-- дней корма вперёд остаётся заботой за один день.
--
-- Дни не обязаны идти подряд: цепочка «подряд» воссоздала бы демотивирующий календарный
-- стрик, от которого проект ушёл.
--
-- ГРАНИЦЫ. Эволюция необратима, происходит по явному действию ученика и НИЧЕГО не даёт, кроме
-- внешнего вида: ни бонусов, ни ускорений, ни влияния на учёбу, рейтинг и лигу. Не входят:
-- третья ступень, редкие и мифические питомцы, Феникс, продажа готовой эволюции и сокращение
-- условия за деньги.
--
-- ВАЖНО ПРО ДЕНЬГИ. `add_huikons` обрезает баланс снизу нулём и НЕ падает при нехватке —
-- поэтому evolve_pet проверяет баланс явно, как это делают buy_item, buy_streak_shield и
-- feed_pet.
-- =============================================================================

begin;

-- --- 0. PREFLIGHT --------------------------------------------------------------
do $preflight$
begin
  if to_regclass('public.student_pet_state') is null then
    raise exception '069 ABORT: питомцы (064) не применены';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'student_pet_state'
                    and column_name = 'bond') then
    raise exception '069 ABORT: связь (068) не применена — эволюции не на чем считаться';
  end if;
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'student_pet_state'
                and column_name = 'stage') then
    raise exception '069 ABORT: ступень уже добавлена';
  end if;
end
$preflight$;

-- --- 1. Условие эволюции в конфиге ----------------------------------------------
alter table public.economy_config
  add column if not exists pet_evolution_price integer not null default 1500;
alter table public.economy_config
  add column if not exists pet_evolution_bond  integer not null default 60;

alter table public.economy_config drop constraint if exists economy_config_pet_evolution_check;
alter table public.economy_config add constraint economy_config_pet_evolution_check
  check (pet_evolution_price > 0 and pet_evolution_bond between 1 and 3650);

-- --- 2. Ступень -----------------------------------------------------------------
-- Только вперёд: откат ступени не предусматривается, поэтому check ограничивает 1..2, а
-- понижение запрещено самой evolve_pet (стартовать можно лишь со ступени 1).
alter table public.student_pet_state
  add column if not exists stage smallint not null default 1 check (stage between 1 and 2);

comment on column public.student_pet_state.stage is
  'Ступень питомца: 1 — базовая, 2 — выросший. Необратима, меняется только evolve_pet.';

-- --- 3. Read-модели: ступень и прогресс эволюции ---------------------------------
-- Тела перенесены из миграций 066 и 068 и пропатчены по явным якорям: добавлены ступень и
-- блок эволюции, остальное дословно прежнее. get_pet_state продолжает звать задеплоенный
-- клиент, поэтому её контракт только расширяется, никогда не сужается.
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
  v_sleep_h integer;
  v_rest_h  integer;
  v_now     timestamptz := now();
  v_today   date := (v_now at time zone 'Europe/Moscow')::date;
  v_pet     text;
  v_payload text;
  v_name    text;
  v_satiety date;
  v_total   integer := 0;
  v_stage   smallint;
  v_start   timestamptz;
  v_rested  timestamptz;
  v_days    integer;
  v_mood    text;
  v_rest    text;
  v_ends    timestamptz;
  v_until   timestamptz;
  v_overall text;
begin
  select stage5_pets_enabled, pet_feed_price, pet_max_prepaid_days,
         pet_sleep_hours, pet_rest_hours
    into v_enabled, v_price, v_max, v_sleep_h, v_rest_h
    from public.economy_config where id;

  select e.item_code, s.render_payload, s.name into v_pet, v_payload, v_name
    from public.student_equipment e
    join public.shop_items s on s.item_code = e.item_code
   where e.student_id = p_student_id and e.slot = 'pet';

  select satiety_until, days_fed_total, sleep_started_at, last_rested_at, stage
    into v_satiety, v_total, v_start, v_rested, v_stage
    from public.student_pet_state where student_id = p_student_id;

  v_days := case when v_satiety is null or v_satiety < v_today
                 then 0 else (v_satiety - v_today) + 1 end;

  v_mood := case
    when v_satiety is null or v_satiety < v_today then 'hungry'
    when v_satiety = v_today                      then 'hungry_soon'
    when v_satiety = v_today + 1                  then 'fed'
    else 'happy'
  end;

  -- Ось отдыха. Сон, начатый ранее и уже закончившийся, засчитывается как отдых даже если
  -- ученик с тех пор не заходил: пробуждение автоматическое.
  v_ends := case when v_start is not null then v_start + make_interval(hours => v_sleep_h) end;
  if v_ends is not null and v_ends > v_now then
    v_rest := 'sleeping';
  else
    v_until := greatest(coalesce(v_rested, '-infinity'::timestamptz), coalesce(v_ends, '-infinity'::timestamptz))
               + make_interval(hours => v_rest_h);
    v_rest := case when v_until > v_now then 'rested' else 'tired' end;
  end if;

  -- Общее настроение: худшее из двух осей, но у каждой оси СВОЙ код. Код 'hungry' означает
  -- именно голод: подставлять его уставшему, но накормленному питомцу нельзя — интерфейс
  -- сказал бы «проголодался» тому, кого только что покормили.
  v_overall := case
    when v_rest = 'sleeping'      then 'sleeping'
    when v_mood = 'hungry'        then 'hungry'
    when v_rest = 'tired'         then 'tired'
    when v_mood = 'hungry_soon'   then 'hungry_soon'
    when v_mood = 'fed'           then 'fed'
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
    'max_prepaid_days',  v_max,
    'rest_state',        case when v_pet is null then null else v_rest end,
    'overall_mood',      case when v_pet is null then null else v_overall end,
    'sleep_ends_at',     case when v_rest = 'sleeping' then v_ends end,
    'rested_until',      case when v_rest = 'rested' then v_until end,
    'can_sleep',         v_pet is not null and v_rest <> 'sleeping',
    'stage',             coalesce(v_stage, 1),
    'sleep_hours',       v_sleep_h,
    'rest_hours',        v_rest_h);
end;
$function$;

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
  v_week      boolean;
  v_record    boolean;
  v_promote   boolean;
begin
  select pet_petting_hours, pet_play_hours, pet_evolution_price, pet_evolution_bond
    into v_petting, v_play, v_ev_price, v_ev_bond
    from public.economy_config where id;

  select bond, stage into v_bond, v_stage
    from public.student_pet_state where student_id = p_student_id;

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

-- --- 4. evolve_pet ----------------------------------------------------------------
-- Явное действие ученика, а не автоматика: питомец не «вырастает сам», когда сойдутся
-- условия. Так момент остаётся событием, которое человек совершает, а не замечает постфактум.
create or replace function public.evolve_pet(p_student_id bigint)
 returns json
 language plpgsql
 set search_path = public, pg_temp
as $function$
declare
  v_enabled boolean;
  v_price   integer;
  v_need    integer;
  v_pet     text;
  v_stage   smallint;
  v_bond    integer;
  v_balance integer;
  v_new_balance integer;
begin
  select stage5_pets_enabled, pet_evolution_price, pet_evolution_bond
    into v_enabled, v_price, v_need
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

  -- Блокировка ученика сериализует параллельные вызовы (как в feed_pet и pet_care).
  select huikons into v_balance from public.students
   where telegram_id = p_student_id for update;
  if v_balance is null then
    raise exception 'Ученик % не найден', p_student_id;
  end if;

  select stage, bond into v_stage, v_bond
    from public.student_pet_state where student_id = p_student_id for update;

  if coalesce(v_stage, 1) >= 2 then
    raise exception 'Питомец уже вырос';
  end if;

  -- Тексты отказов называют, чего не хватает, и ничего не ставят в вину.
  if coalesce(v_bond, 0) < v_need then
    raise exception 'Нужно % дней заботы, сейчас %', v_need, coalesce(v_bond, 0);
  end if;
  if v_balance < v_price then
    raise exception 'Недостаточно бубликов: нужно %, есть %', v_price, v_balance;
  end if;

  select new_balance into v_new_balance
    from public.add_huikons(p_student_id, -v_price, 'pet_evolution');

  update public.student_pet_state
     set stage = 2, updated_at = now()
   where student_id = p_student_id;

  return json_build_object(
    'stage',   2,
    'spent',   v_price,
    'balance', v_new_balance);
end;
$function$;

-- --- 5. Гейтвей --------------------------------------------------------------------
create or replace function public.evolve_pet_self()
 returns json language plpgsql security definer set search_path = public, pg_temp
as $function$
declare v_tid bigint;
begin
  if private.current_app_role() is distinct from 'student' then
    raise exception 'forbidden' using errcode = '42501'; end if;
  v_tid := private.current_telegram_id();
  if v_tid is null or v_tid <= 0 then
    raise exception 'no student identity' using errcode = '42501'; end if;
  return public.evolve_pet(v_tid);
end;
$function$;

revoke all on function public.evolve_pet(bigint)   from public, anon, authenticated;
revoke all on function public.evolve_pet_self()    from public, anon;
grant execute on function public.evolve_pet_self() to authenticated;

-- --- 6. POSTFLIGHT ------------------------------------------------------------------
do $postflight$
begin
  if to_regprocedure('public.evolve_pet_self()') is null then
    raise exception '069 ABORT: гейтвей эволюции не создан';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'student_pet_state'
                    and column_name = 'stage') then
    raise exception '069 ABORT: ступень не добавлена';
  end if;
  -- Контракт read-моделей обязан быть расширен, а не сломан: обе на месте и обе знают ступень.
  if to_regprocedure('public.get_pet_state(bigint)') is null
     or to_regprocedure('public.get_pet_room(bigint)') is null then
    raise exception '069 ABORT: read-модель исчезла — её зовёт задеплоенный клиент';
  end if;
  if position('''stage''' in pg_get_functiondef('public.get_pet_state(bigint)'::regprocedure)) = 0 then
    raise exception '069 ABORT: get_pet_state не отдаёт ступень';
  end if;
  if position('''evolution''' in pg_get_functiondef('public.get_pet_room(bigint)'::regprocedure)) = 0 then
    raise exception '069 ABORT: get_pet_room не отдаёт блок эволюции';
  end if;
end
$postflight$;

commit;

-- =============================================================================
-- ROLLBACK (до того, как кто-то вырос; после — ступень 2 придётся вернуть вручную,
-- потраченные бублики не возвращаются: clawback не предусмотрен):
--   begin;
--     drop function if exists public.evolve_pet_self();
--     drop function if exists public.evolve_pet(bigint);
--     -- get_pet_state вернуть телом из миграции 066, get_pet_room — из 068;
--     alter table public.student_pet_state drop column if exists stage;
--     alter table public.economy_config drop constraint if exists economy_config_pet_evolution_check;
--     alter table public.economy_config drop column if exists pet_evolution_price;
--     alter table public.economy_config drop column if exists pet_evolution_bond;
--   commit;
-- =============================================================================
