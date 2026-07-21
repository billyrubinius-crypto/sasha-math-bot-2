-- =============================================================================
-- 035_t10_student_game_gateways.sql — T10-04B (student game mutation gateways)
-- (Bot 2.0, T10; SPEC_T10.md §§4-5, 7; карточка T10-04B; продолжение T10-04A/034)
--
-- Переводит легитимные игровые действия ученика (покупка/щит, экипировка, витрина, персональный
-- титул, недельные щиты, ежедневные life-квесты get/replace/claim) на claim-based self RPC.
-- Каждый gateway:
--   * читает identity ТОЛЬКО из JWT-claims (private.current_app_role / private.current_telegram_id,
--     T10-01) — НЕ принимает p_student_id и не выводит его из аргумента;
--   * требует app_role='student';
--   * вызывает СУЩЕСТВУЮЩУЮ атомарную бизнес-логику (цены, лимиты, pay-once ledger, add_huikons,
--     for update, Stage 4 dormant-gate) — экономика НЕ переписывается;
--   * возвращает тот же тип, что базовая функция (json / void), клиент читает результат как раньше.
--
-- add_huikons, season points, achievements, settlement/finalize НЕ открываются ученику отдельным
-- gateway и остаются internal primitives (вызываются только изнутри базовых функций).
--
-- Legacy RPC (buy_item(p_student_id,...) и т.д.) НЕ трогаются и остаются рабочими параллельно —
-- их точечный REVOKE только на final anon-close T10-11. RLS не включается (T10-08A/B); auth_mode
-- не меняется. Новый gateway получает grant только authenticated; anon его не получает.
--
-- SECURITY DEFINER обязателен: у authenticated отозван USAGE на схему private (миграция 032),
-- поэтому обратиться к private.current_* может только definer-функция во владении postgres.
--
-- search_path: в отличие от 034 (там '' — прямой SQL с полной квалификацией public.*), эти gateway
-- ДЕЛЕГИРУЮТ в существующие функции, часть которых обращается к таблицам public по НЕполному имени
-- (student_items, students, add_huikons и т.п.); при search_path='' эти имена не разрешились бы.
-- Поэтому фиксируем search_path = public, pg_temp: путь фиксирован (не управляется вызывающим →
-- нет search-path-инъекции), pg_catalog ищется неявно первым, pg_temp явно последним (не может
-- перехватить public-объекты), а целевые объекты и так живут в public. Хардинг самих базовых
-- primitives (их собственный фиксированный search_path) — отдельная задача T10-08, здесь их не
-- переписываем (запрет карты на рефакторинг экономики).
-- =============================================================================

-- --- Общая заготовка identity-гейта повторяется в каждом gateway (без нового helper, чтобы не
-- --- плодить internal-функции и остаться в паттерне 034). ------------------------------------

-- 1. buy_item_self — покупка предмета витрины (делегирует в buy_item; щит внутри делегируется в
--    buy_streak_shield самой buy_item). Цена/бандл/pay-once/списание — без изменений.
create or replace function public.buy_item_self(
  p_item_code text,
  p_variant   text default null)
 returns json
 language plpgsql
 security definer
 set search_path = public, pg_temp
as $function$
declare
  v_tid bigint;
begin
  if private.current_app_role() is distinct from 'student' then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  v_tid := private.current_telegram_id();
  if v_tid is null or v_tid <= 0 then
    raise exception 'no student identity' using errcode = '42501';
  end if;
  return public.buy_item(v_tid, p_item_code, p_variant);
end;
$function$;

-- 2. buy_streak_shield_self — покупка недельного щита (лимит 7 / цена 90 внутри buy_streak_shield).
create or replace function public.buy_streak_shield_self()
 returns json
 language plpgsql
 security definer
 set search_path = public, pg_temp
as $function$
declare
  v_tid bigint;
begin
  if private.current_app_role() is distinct from 'student' then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  v_tid := private.current_telegram_id();
  if v_tid is null or v_tid <= 0 then
    raise exception 'no student identity' using errcode = '42501';
  end if;
  return public.buy_streak_shield(v_tid);
end;
$function$;

-- 3. equip_item_self — надеть/снять купленный предмет (проверка владения внутри equip_item).
create or replace function public.equip_item_self(
  p_slot      text,
  p_item_code text default null)
 returns void
 language plpgsql
 security definer
 set search_path = public, pg_temp
as $function$
declare
  v_tid bigint;
begin
  if private.current_app_role() is distinct from 'student' then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  v_tid := private.current_telegram_id();
  if v_tid is null or v_tid <= 0 then
    raise exception 'no student identity' using errcode = '42501';
  end if;
  perform public.equip_item(v_tid, p_slot, p_item_code);
end;
$function$;

-- 4. set_showcase_self — поставить/снять слот витрины (p_ref_code=null => снять; логика в set_showcase).
create or replace function public.set_showcase_self(
  p_position smallint,
  p_kind     text,
  p_ref_code text)
 returns void
 language plpgsql
 security definer
 set search_path = public, pg_temp
as $function$
declare
  v_tid bigint;
begin
  if private.current_app_role() is distinct from 'student' then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  v_tid := private.current_telegram_id();
  if v_tid is null or v_tid <= 0 then
    raise exception 'no student identity' using errcode = '42501';
  end if;
  perform public.set_showcase(v_tid, p_position, p_kind, p_ref_code);
end;
$function$;

-- 5. submit_custom_title_self — покупка права на персональный титул + отправка на модерацию
--    (валидация текста, цена 2000/бесплатная пересдача, pay-once — внутри submit_custom_title).
create or replace function public.submit_custom_title_self(
  p_title_text text)
 returns json
 language plpgsql
 security definer
 set search_path = public, pg_temp
as $function$
declare
  v_tid bigint;
begin
  if private.current_app_role() is distinct from 'student' then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  v_tid := private.current_telegram_id();
  if v_tid is null or v_tid <= 0 then
    raise exception 'no student identity' using errcode = '42501';
  end if;
  return public.submit_custom_title(v_tid, p_title_text);
end;
$function$;

-- 6. request_weekly_shield_self — попросить недельный щит на задание (owner/окно/лимит — внутри).
create or replace function public.request_weekly_shield_self(
  p_assignment_id uuid)
 returns json
 language plpgsql
 security definer
 set search_path = public, pg_temp
as $function$
declare
  v_tid bigint;
begin
  if private.current_app_role() is distinct from 'student' then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  v_tid := private.current_telegram_id();
  if v_tid is null or v_tid <= 0 then
    raise exception 'no student identity' using errcode = '42501';
  end if;
  return public.request_weekly_shield(v_tid, p_assignment_id);
end;
$function$;

-- 7. cancel_weekly_shield_self — отменить ранее запрошенный недельный щит.
create or replace function public.cancel_weekly_shield_self(
  p_assignment_id uuid)
 returns json
 language plpgsql
 security definer
 set search_path = public, pg_temp
as $function$
declare
  v_tid bigint;
begin
  if private.current_app_role() is distinct from 'student' then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  v_tid := private.current_telegram_id();
  if v_tid is null or v_tid <= 0 then
    raise exception 'no student identity' using errcode = '42501';
  end if;
  return public.cancel_weekly_shield(v_tid, p_assignment_id);
end;
$function$;

-- 8. get_daily_quests_self — прочитать/сгенерировать сегодняшний набор (dormant-gate внутри;
--    при выключенной генерации ничего не пишет). Возвращает daily_quest_state.
create or replace function public.get_daily_quests_self()
 returns json
 language plpgsql
 security definer
 set search_path = public, pg_temp
as $function$
declare
  v_tid bigint;
begin
  if private.current_app_role() is distinct from 'student' then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  v_tid := private.current_telegram_id();
  if v_tid is null or v_tid <= 0 then
    raise exception 'no student identity' using errcode = '42501';
  end if;
  return public.get_daily_quests(v_tid);
end;
$function$;

-- 9. replace_life_quest_self — заменить life-квест (сегодня, до self-report, максимум два раза).
create or replace function public.replace_life_quest_self()
 returns json
 language plpgsql
 security definer
 set search_path = public, pg_temp
as $function$
declare
  v_tid bigint;
begin
  if private.current_app_role() is distinct from 'student' then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  v_tid := private.current_telegram_id();
  if v_tid is null or v_tid <= 0 then
    raise exception 'no student identity' using errcode = '42501';
  end if;
  return public.replace_life_quest(v_tid);
end;
$function$;

-- 10. claim_life_quest_self — self-report выполнения life-квеста (pay-once life=3 + combo внутри).
create or replace function public.claim_life_quest_self()
 returns json
 language plpgsql
 security definer
 set search_path = public, pg_temp
as $function$
declare
  v_tid bigint;
begin
  if private.current_app_role() is distinct from 'student' then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  v_tid := private.current_telegram_id();
  if v_tid is null or v_tid <= 0 then
    raise exception 'no student identity' using errcode = '42501';
  end if;
  return public.claim_life_quest(v_tid);
end;
$function$;

-- --- Явные grants: только authenticated (student JWT). anon/public новый gateway НЕ получают. ---
revoke all on function public.buy_item_self(text, text)            from public, anon;
revoke all on function public.buy_streak_shield_self()             from public, anon;
revoke all on function public.equip_item_self(text, text)          from public, anon;
revoke all on function public.set_showcase_self(smallint, text, text) from public, anon;
revoke all on function public.submit_custom_title_self(text)       from public, anon;
revoke all on function public.request_weekly_shield_self(uuid)     from public, anon;
revoke all on function public.cancel_weekly_shield_self(uuid)      from public, anon;
revoke all on function public.get_daily_quests_self()              from public, anon;
revoke all on function public.replace_life_quest_self()            from public, anon;
revoke all on function public.claim_life_quest_self()              from public, anon;

grant execute on function public.buy_item_self(text, text)            to authenticated;
grant execute on function public.buy_streak_shield_self()             to authenticated;
grant execute on function public.equip_item_self(text, text)          to authenticated;
grant execute on function public.set_showcase_self(smallint, text, text) to authenticated;
grant execute on function public.submit_custom_title_self(text)       to authenticated;
grant execute on function public.request_weekly_shield_self(uuid)     to authenticated;
grant execute on function public.cancel_weekly_shield_self(uuid)      to authenticated;
grant execute on function public.get_daily_quests_self()              to authenticated;
grant execute on function public.replace_life_quest_self()            to authenticated;
grant execute on function public.claim_life_quest_self()              to authenticated;

-- =============================================================================
-- ROLLBACK (до переключения клиента откат безопасен — клиент ещё зовёт legacy RPC):
--   drop function if exists public.buy_item_self(text, text);
--   drop function if exists public.buy_streak_shield_self();
--   drop function if exists public.equip_item_self(text, text);
--   drop function if exists public.set_showcase_self(smallint, text, text);
--   drop function if exists public.submit_custom_title_self(text);
--   drop function if exists public.request_weekly_shield_self(uuid);
--   drop function if exists public.cancel_weekly_shield_self(uuid);
--   drop function if exists public.get_daily_quests_self();
--   drop function if exists public.replace_life_quest_self();
--   drop function if exists public.claim_life_quest_self();
-- =============================================================================
