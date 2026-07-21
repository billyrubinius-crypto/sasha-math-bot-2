-- =============================================================================
-- 040_t10_collection_bonus_gateway.sql — T10-06D (claim collection bonus gateway)
-- (Bot 2.0, T10; корректирующая мини-карта перед T10-08A; SPEC_T10.md §4; паттерн T10-04B)
--
-- Зачем: student-shop.js grantCollectionBonus (бонус за собранную коллекцию сезона) делает ПРЯМЫЕ
-- writes из клиента — insert student_achievements + add_huikons (пишет students/balance_history).
-- Это последний прямой client-write в core-таблицы (после T10-06C), блокирующий write-lockdown
-- T10-08A. Карта уводит его в claim-based student self-gateway с СЕРВЕРНОЙ проверкой полноты
-- коллекции (иначе ученик мог бы затребовать бонус по любому сезону и фармить бубл ики).
--
-- Гейт: app_role='student', identity из JWT-claim (не из аргумента), p_season_id — бизнес-аргумент
-- (какой сезон), НЕ доказательство владельца. Сервер сам проверяет, что ученик владеет ВСЕМИ
-- rotation-предметами бандла сезона, и только тогда идемпотентно выдаёт достижение + 50 бубликов
-- через существующий grant_achievement_server (та же семантика pay-once, что и в клиенте).
-- Экономика не переписана. RLS не включается; auth_mode=legacy. Grant только authenticated.
-- =============================================================================

create or replace function public.claim_collection_bonus_self(p_season_id bigint)
 returns json
 language plpgsql
 security definer
 set search_path = public, pg_temp
as $function$
declare
  v_tid     bigint;
  v_bundle  integer;
  v_total   integer;
  v_owned   integer;
  v_granted boolean := false;
begin
  if private.current_app_role() is distinct from 'student' then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  v_tid := private.current_telegram_id();
  if v_tid is null or v_tid <= 0 then
    raise exception 'no student identity' using errcode = '42501';
  end if;
  if p_season_id is null then
    raise exception 'season required' using errcode = '22023';
  end if;

  select bundle into v_bundle from public.season_bundles where season_id = p_season_id;
  if v_bundle is null then
    return json_build_object('granted', false, 'eligible', false);
  end if;

  -- Полнота коллекции: владеет ли ученик всеми rotation-предметами бандла (наличие строки
  -- student_items = владение, как считает клиент). v_total>=1 отсекает пустой бандл.
  select count(*), count(si.item_code)
    into v_total, v_owned
    from public.shop_items s
    left join public.student_items si
      on si.item_code = s.item_code and si.student_id = v_tid
   where s.availability = 'rotation' and s.rotation_bundle = v_bundle;

  if v_total >= 1 and v_owned = v_total then
    -- Идемпотентно: grant_achievement_server вернёт false, если достижение уже выдано (без второй
    -- награды). Та же выдача, что делал клиент напрямую (achievement + add_huikons 50).
    v_granted := public.grant_achievement_server(v_tid, 'collection_season_' || p_season_id, 50);
    return json_build_object('granted', v_granted, 'eligible', true);
  end if;

  return json_build_object('granted', false, 'eligible', false);
end;
$function$;

revoke all on function public.claim_collection_bonus_self(bigint) from public, anon;
grant execute on function public.claim_collection_bonus_self(bigint) to authenticated;

-- =============================================================================
-- ROLLBACK (до переключения клиента — безопасно):
--   drop function if exists public.claim_collection_bonus_self(bigint);
-- =============================================================================
