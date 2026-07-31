-- =============================================================================
-- 065_stage5_pet_sleep.sql — Stage 5, вторая ось заботы: сон питомца
-- (Bot 2.0; SPEC_STAGE5_PETS.md §2.3, ECONOMY_V3.md §7)
--
-- ЗАЧЕМ. Питомец развивается в сторону тамагочи: несколько независимых осей заботы. Первая —
-- корм (деньги), вторая — сон (время и внимание). Денежная ось остаётся ровно одна: сон
-- БЕСПЛАТЕН и не трогает баланс. Платный сон стал бы вторым обязательным стоком и вышел бы за
-- потолок бюджета заботы (70 за период).
--
-- --- МЕХАНИКА -----------------------------------------------------------------------------
--   * «Уложить спать» доступно, когда питомец не спит;
--   * сон длится pet_sleep_hours (8) и заканчивается САМ — будить руками не нужно. Ручное
--     пробуждение сделало бы механику наказывающей: не открыл приложение в нужный час —
--     потерял результат;
--   * после пробуждения питомец «отдохнувший» ещё pet_rest_hours (48), потом «уставший»;
--   * усталость — только внешний вид. Она не влияет на сытость, деньги, учёбу, рейтинг, лигу,
--     достижения и не образует цепочку «подряд».
--
-- Привычка возникает сама: чтобы питомец был бодрым, надо заходить хотя бы раз в двое суток.
--
-- ГРАНИЦЫ. Не входят: эволюция, редкие/мифические, клички, любые награды за сон, любая
-- эмиссия бубликов. Кормление во время сна разрешено — блокировать его незачем.
--
-- ИДЕМПОТЕНТНОСТЬ. Повторный вызов во время сна отвергается явной проверкой; повторный прогон
-- миграции безопасен (add column if not exists / or replace).
-- =============================================================================

begin;

-- --- 0. PREFLIGHT --------------------------------------------------------------
do $preflight$
begin
  if to_regclass('public.student_pet_state') is null then
    raise exception '065 ABORT: миграция 064 (питомцы) не применена';
  end if;
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'student_pet_state'
                and column_name = 'sleep_started_at') then
    raise exception '065 ABORT: сон уже добавлен';
  end if;
end
$preflight$;

-- --- 1. Конфигурация -----------------------------------------------------------
alter table public.economy_config
  add column if not exists pet_sleep_hours integer not null default 8;
alter table public.economy_config
  add column if not exists pet_rest_hours  integer not null default 48;

alter table public.economy_config drop constraint if exists economy_config_pet_sleep_check;
alter table public.economy_config add constraint economy_config_pet_sleep_check
  check (pet_sleep_hours between 1 and 24 and pet_rest_hours between 2 and 168);

-- --- 2. Состояние --------------------------------------------------------------
alter table public.student_pet_state
  add column if not exists sleep_started_at timestamptz;
alter table public.student_pet_state
  add column if not exists last_rested_at   timestamptz;

-- Строка состояния теперь может появиться из-за сна, а не только из-за кормления: у ученика,
-- который сразу уложил питомца спать, сытости ещё нет. Поэтому «сыт до» становится nullable,
-- а null уже трактуется существующим кодом как «не кормлен» (feed_pet: coalesce(...),
-- get_pet_state: mood = hungry).
alter table public.student_pet_state alter column satiety_until drop not null;

comment on column public.student_pet_state.sleep_started_at is
  'Начало текущего сна; сон заканчивается сам через economy_config.pet_sleep_hours.';
comment on column public.student_pet_state.last_rested_at is
  'Когда питомец в последний раз выспался; отдых держится economy_config.pet_rest_hours.';

-- --- 3. put_pet_to_sleep -------------------------------------------------------
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

  return json_build_object(
    'sleep_started_at', v_now,
    'sleep_ends_at',    v_now + make_interval(hours => v_sleep));
end;
$function$;

-- --- 4. Read-модель: две оси заботы --------------------------------------------
-- Питание и отдых считаются независимо, общее настроение — худшее из двух: питомец не может
-- быть «доволен», если голоден или не спал. Всё вычисляет сервер, клиент только показывает.
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

  select satiety_until, days_fed_total, sleep_started_at, last_rested_at
    into v_satiety, v_total, v_start, v_rested
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

  -- Общее настроение: худшее из двух осей. Спящий питомец показывается как спящий.
  v_overall := case
    when v_rest = 'sleeping'                        then 'sleeping'
    when v_mood = 'hungry' or v_rest = 'tired'      then 'hungry'
    when v_mood = 'hungry_soon'                     then 'hungry_soon'
    when v_mood = 'fed'                             then 'fed'
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
    'sleep_hours',       v_sleep_h,
    'rest_hours',        v_rest_h);
end;
$function$;

-- --- 5. Гейтвей ----------------------------------------------------------------
create or replace function public.put_pet_to_sleep_self()
 returns json language plpgsql security definer set search_path = public, pg_temp
as $function$
declare v_tid bigint;
begin
  if private.current_app_role() is distinct from 'student' then
    raise exception 'forbidden' using errcode = '42501'; end if;
  v_tid := private.current_telegram_id();
  if v_tid is null or v_tid <= 0 then
    raise exception 'no student identity' using errcode = '42501'; end if;
  return public.put_pet_to_sleep(v_tid);
end;
$function$;

revoke all on function public.put_pet_to_sleep(bigint)  from public, anon, authenticated;
revoke all on function public.put_pet_to_sleep_self()   from public, anon;
grant execute on function public.put_pet_to_sleep_self() to authenticated;

-- --- 6. POSTFLIGHT -------------------------------------------------------------
do $postflight$
begin
  if to_regprocedure('public.put_pet_to_sleep_self()') is null then
    raise exception '065 ABORT: гейтвей сна не создан';
  end if;
  if (select stage5_pets_enabled from public.economy_config where id) then
    raise exception '065 ABORT: питомцы включены — миграция ожидала спящее состояние';
  end if;
end
$postflight$;

commit;

-- =============================================================================
-- ROLLBACK:
--   begin;
--     drop function if exists public.put_pet_to_sleep_self();
--     drop function if exists public.put_pet_to_sleep(bigint);
--     -- get_pet_state вернуть телом из миграции 064 (без осей отдыха);
--     alter table public.student_pet_state drop column if exists sleep_started_at;
--     alter table public.student_pet_state drop column if exists last_rested_at;
--     alter table public.economy_config drop constraint if exists economy_config_pet_sleep_check;
--     alter table public.economy_config drop column if exists pet_sleep_hours;
--     alter table public.economy_config drop column if exists pet_rest_hours;
--     -- satiety_until обратно not null только после проверки, что null-строк нет.
--   commit;
-- =============================================================================
