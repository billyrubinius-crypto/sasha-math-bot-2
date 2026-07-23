-- =============================================================================
-- 047_t10_direct_rpc_hardening.sql — T10-11 prerelease hardening
-- (Bot 2.0, T10; карточка T10-11; после 045/046, до release anon-closure)
--
-- Зачем. После T10-08/10 почти весь клиент уже переведён на узкие authenticated/service
-- gateway'и. Но перед финальным T10-11 revoke остаются два прямых вызова, которые нельзя
-- оставить как есть:
--   1) ensure_season_rotation() до сих пор ПИШЕТ в season_bundles из student-shop.js;
--      если просто отозвать default DML/EXECUTE в T10-11, магазин начнёт падать на загрузке.
--      Открывать insert на season_bundles обратно нельзя — значит, сама функция становится
--      узким authenticated gateway с server-side identity check и фиксированным search_path.
--   2) admin_list_life_quest_templates() используется только teacher UI, но до T10-11 живёт как
--      обычная invoker SQL-функция. После массового revoke EXECUTE мы хотим вернуть доступ ровно
--      утверждённой поверхности, а не полагаться на старый PUBLIC default. Поэтому фиксируем и её:
--      SECURITY DEFINER + teacher-role guard + explicit authenticated grant.
--
-- Что НЕ меняется. auth_mode остаётся legacy; RLS/grants таблиц не меняются; реальный anon
-- closure и default privileges — отдельные release/rollback scripts T10-11.
-- =============================================================================

-- --- 1. Student shop helper: season rotation only through authenticated student identity -------
create or replace function public.ensure_season_rotation()
 returns integer
 language plpgsql
 security definer
 set search_path = public, pg_temp
as $function$
declare
  v_season bigint;
  v_bundle integer;
begin
  if private.current_app_role() is distinct from 'student' then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  select id into v_season from public.seasons where end_date is null order by id desc limit 1;
  if v_season is null then
    return null;
  end if;

  select bundle into v_bundle from public.season_bundles where season_id = v_season;
  if v_bundle is not null then
    return v_bundle;
  end if;

  select min(rotation_bundle) into v_bundle
    from public.shop_items
   where rotation_bundle is not null
     and active
     and rotation_bundle not in (select bundle from public.season_bundles);
  if v_bundle is null then
    return null;
  end if;

  insert into public.season_bundles (season_id, bundle)
  values (v_season, v_bundle)
  on conflict (season_id) do nothing;

  select bundle into v_bundle from public.season_bundles where season_id = v_season;
  return v_bundle;
end;
$function$;

revoke all on function public.ensure_season_rotation() from public, anon;
grant execute on function public.ensure_season_rotation() to authenticated;

-- --- 2. Teacher-only challenge catalog list ---------------------------------------------------
create or replace function public.admin_list_life_quest_templates()
 returns table (
   template_code text,
   name          text,
   description   text,
   category      text,
   active        boolean,
   weight        integer,
   created_at    timestamptz,
   updated_at    timestamptz
 )
 language plpgsql
 stable
 security definer
 set search_path = public, pg_temp
as $function$
begin
  if private.current_app_role() is distinct from 'teacher' then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  return query
  select lqt.template_code,
         lqt.name,
         lqt.description,
         lqt.category,
         lqt.active,
         lqt.weight,
         lqt.created_at,
         lqt.updated_at
    from public.life_quest_templates lqt
   order by lqt.category, lqt.name;
end;
$function$;

revoke all on function public.admin_list_life_quest_templates() from public, anon;
grant execute on function public.admin_list_life_quest_templates() to authenticated;

-- =============================================================================
-- ROLLBACK:
--   create or replace function public.ensure_season_rotation()
--    returns integer
--    language plpgsql
--   as $function$
--   declare
--     v_season bigint;
--     v_bundle integer;
--   begin
--     select id into v_season from seasons where end_date is null order by id desc limit 1;
--     if v_season is null then
--       return null;
--     end if;
--
--     select bundle into v_bundle from season_bundles where season_id = v_season;
--     if v_bundle is not null then
--       return v_bundle;
--     end if;
--
--     select min(rotation_bundle) into v_bundle
--       from shop_items
--      where rotation_bundle is not null
--        and active
--        and rotation_bundle not in (select bundle from season_bundles);
--     if v_bundle is null then
--       return null;
--     end if;
--
--     insert into season_bundles (season_id, bundle)
--       values (v_season, v_bundle)
--       on conflict (season_id) do nothing;
--
--     select bundle into v_bundle from season_bundles where season_id = v_season;
--     return v_bundle;
--   end;
--   $function$;
--
--   create or replace function public.admin_list_life_quest_templates()
--    returns table (
--      template_code text,
--      name          text,
--      description   text,
--      category      text,
--      active        boolean,
--      weight        integer,
--      created_at    timestamptz,
--      updated_at    timestamptz
--    )
--    language sql
--    stable
--   as $function$
--     select template_code, name, description, category, active, weight, created_at, updated_at
--       from public.life_quest_templates
--      order by category, name;
--   $function$;
--
--   revoke all on function public.ensure_season_rotation() from authenticated;
--   revoke all on function public.admin_list_life_quest_templates() from authenticated;
--   grant execute on function public.ensure_season_rotation() to public;
--   grant execute on function public.admin_list_life_quest_templates() to public;
-- =============================================================================
