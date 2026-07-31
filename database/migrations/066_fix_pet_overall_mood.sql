-- =============================================================================
-- 066_fix_pet_overall_mood.sql — общее настроение питомца: отдельный код усталости
-- (исправление к миграции 065)
--
-- ДЕФЕКТ. В 065 общее настроение считалось так:
--     when v_mood = 'hungry' or v_rest = 'tired' then 'hungry'
-- то есть сытому, но не выспавшемуся питомцу подставлялся код голода, и карточка сказала бы
-- «Проголодался и грустит» тому, кого только что покормили. Найдено регрессионным сценарием
-- database/tests/v2_pets_regression.sql (блок 4, проверка OVERALL_WORST) до запуска механики.
--
-- ИСПРАВЛЕНИЕ. У каждой оси свой код: голод остаётся голодом, усталость получает 'tired'.
-- Приоритет: спит → голоден → устал → скоро проголодается → накормлен → доволен.
-- Голод впереди усталости сознательно: он единственный, что стоит денег.
--
-- Меняется ровно одна CASE-ветка; остальное тело перенесено из 065 без изменений.
-- Клиент получает новый код и показывает «Не выспался» вместо ложного «Проголодался».
-- =============================================================================

begin;

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
    'sleep_hours',       v_sleep_h,
    'rest_hours',        v_rest_h);
end;
$function$;

revoke all on function public.get_pet_state(bigint) from public, anon, authenticated;

do $postflight$
begin
  if position('''tired''' in pg_get_functiondef('public.get_pet_state(bigint)'::regprocedure)) = 0 then
    raise exception '066 ABORT: код усталости не появился в get_pet_state';
  end if;
end
$postflight$;

commit;

-- =============================================================================
-- ROLLBACK: вернуть тело get_pet_state из миграции 065.
-- =============================================================================
