-- =============================================================================
-- 043_t10_game_rls.sql — T10-08B (Game RLS: магазин, недели, лиги, квесты)
-- (Bot 2.0, T10; SPEC_T10.md §5; карточка T10-08B; после T10-04B/06B/08A)
--
-- Покрывает RLS/grants ВСЕ оставшиеся business-таблицы (после T10-08A закрывает всю поверхность —
-- DoD: нет orphan public table). Строго, без anon-compat (боты не на dev). Экономика/UI не меняются.
--
-- Категории:
--   * student-own SELECT: inventory/equipment/showcase/achievements, season_results, week_results,
--     shields, league membership/movements/awards, student_daily_quests (life history — СТРОГО
--     student-own, teacher/parent НЕ получают доступ);
--   * student_daily_quest_options — own через parent (daily_quest_id → student_daily_quests);
--   * student_custom_titles — own + teacher (модерация);
--   * catalog (authenticated SELECT): shop_items, season_bundles, seasons; life_quest_templates —
--     active всем authenticated + всё teacher;
--   * teacher-only: weekly_plans, weekly_plan_items;
--   * deny-client (RLS on, без политик, revoke all): reward/points ledgers, economy_config,
--     league_tiers, league_cohorts, student_league_state, bot_notification_state.
-- Writes revoked у anon/authenticated везде (gateway'и — owner, обходят RLS; service_role — Apps
-- Script/боты позже). Policy-хелперы jwt_app_role/jwt_student_id — из T10-08A.
--
-- Cross-student/internal read (leaderboard/лига/звание) ломается под RLS у INVOKER-функций (нужен
-- полный когорт-рид). Решение: узкие SECURITY DEFINER _self-обёртки с claim-guard; inner-функции
-- revoked у anon/authenticated (достижимы только через обёртку). telegram_username/лишние student-
-- поля не раскрываются (preview_league_close отдаёт student_id+статы, snapshot — place/tier/counts).
-- economy_config — только через узкий get_economy_flags(); seasons bootstrap — только ensure_current_season().
-- auth_mode остаётся legacy (enforced — T10-11). Прямые client writes уже уведены в gateway'и;
-- последний (seasons.insert) закрывается ensure_current_season здесь.
-- =============================================================================

-- ============================== SECTION A: RPC ==============================

-- get_economy_flags — узкий read economy_config (клиент читал cutover_at напрямую; теперь только тут).
create or replace function public.get_economy_flags()
 returns json language plpgsql security definer set search_path = public, pg_temp
as $function$
begin
  if private.current_app_role() not in ('student','teacher') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  return (select json_build_object('cutover_at', cutover_at, 'stage4_started_at', stage4_started_at)
            from public.economy_config limit 1);
end;
$function$;

-- ensure_current_season — безопасная замена прямого seasons.insert (getCurrentSeasonId). Возвращает
-- открытый сезон, создаёт при отсутствии. Гонку двух созданий ловит partial-unique idx_seasons_one_active.
create or replace function public.ensure_current_season()
 returns bigint language plpgsql security definer set search_path = public, pg_temp
as $function$
declare v_id bigint;
begin
  if private.current_app_role() not in ('student','teacher') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select id into v_id from public.seasons where end_date is null order by id desc limit 1;
  if v_id is not null then return v_id; end if;
  begin
    insert into public.seasons (start_date) values ((now() at time zone 'Europe/Moscow')::date)
      returning id into v_id;
    return v_id;
  exception when unique_violation then
    select id into v_id from public.seasons where end_date is null order by id desc limit 1;
    return v_id;
  end;
end;
$function$;

-- get_student_league_snapshot_self — own snapshot (place/tier/counts). Definer: inner читает всю
-- когорту (rating соперников) — под RLS у INVOKER не сработало бы. Identity из claim, не из аргумента.
create or replace function public.get_student_league_snapshot_self()
 returns json language plpgsql security definer set search_path = public, pg_temp
as $function$
declare v_tid bigint;
begin
  if private.current_app_role() is distinct from 'student' then
    raise exception 'forbidden' using errcode = '42501'; end if;
  v_tid := private.current_telegram_id();
  if v_tid is null or v_tid <= 0 then
    raise exception 'no student identity' using errcode = '42501'; end if;
  return public.get_student_league_snapshot(v_tid);
end;
$function$;

-- get_student_rank_title_self — own звание/прогресс. Definer: inner читает student_league_state
-- (deny-client) + агрегаты по assignments. Identity из claim.
create or replace function public.get_student_rank_title_self()
 returns json language plpgsql security definer set search_path = public, pg_temp
as $function$
declare v_tid bigint;
begin
  if private.current_app_role() is distinct from 'student' then
    raise exception 'forbidden' using errcode = '42501'; end if;
  v_tid := private.current_telegram_id();
  if v_tid is null or v_tid <= 0 then
    raise exception 'no student identity' using errcode = '42501'; end if;
  return public.get_student_rank_title(v_tid);
end;
$function$;

-- preview_league_close_self — leaderboard/лига (student и teacher). Definer: inner читает все
-- когорты. Аргумента нет; поведение сохраняется. Колонки inner — student_id+статы (без username/name).
create or replace function public.preview_league_close_self()
 returns table(student_id bigint, tier integer, tier_name text, cohort_index integer,
   points integer, place integer, active_in_cohort integer, projected_movement text, projected_tier integer)
 language plpgsql security definer set search_path = public, pg_temp
as $function$
begin
  if private.current_app_role() not in ('student','teacher') then
    raise exception 'forbidden' using errcode = '42501'; end if;
  return query select * from public.preview_league_close();
end;
$function$;

-- inner cross-student/internal read-RPC достижимы только через обёртки (revoke от anon/authenticated/public).
revoke all on function public.get_student_league_snapshot(bigint) from public, anon, authenticated;
revoke all on function public.get_student_rank_title(bigint)      from public, anon, authenticated;
revoke all on function public.preview_league_close()             from public, anon, authenticated;

-- grants новых объектов: только authenticated (app_role проверяется внутри); anon исключён.
revoke all on function public.get_economy_flags()                    from public, anon;
revoke all on function public.ensure_current_season()                from public, anon;
revoke all on function public.get_student_league_snapshot_self()     from public, anon;
revoke all on function public.get_student_rank_title_self()          from public, anon;
revoke all on function public.preview_league_close_self()            from public, anon;
grant execute on function public.get_economy_flags()                 to authenticated;
grant execute on function public.ensure_current_season()             to authenticated;
grant execute on function public.get_student_league_snapshot_self()  to authenticated;
grant execute on function public.get_student_rank_title_self()       to authenticated;
grant execute on function public.preview_league_close_self()         to authenticated;

-- ============================== SECTION B: RLS =============================
begin;

-- Preflight: хелперы + все 29 таблиц на месте до любого ENABLE.
do $$
declare v_missing text;
begin
  if to_regprocedure('public.jwt_student_id()') is null
     or to_regprocedure('public.jwt_app_role()') is null then
    raise exception 'preflight: policy helpers missing (T10-08A)';
  end if;
  select string_agg(t, ', ') into v_missing from unnest(array[
    'public.student_items','public.student_equipment','public.student_showcase',
    'public.student_custom_titles','public.student_achievements','public.season_results',
    'public.student_week_results','public.weekly_shield_uses','public.streak_shield_uses',
    'public.league_memberships','public.league_movements','public.league_season_awards',
    'public.student_daily_quests','public.student_daily_quest_options',
    'public.shop_items','public.season_bundles','public.seasons','public.life_quest_templates',
    'public.weekly_plans','public.weekly_plan_items',
    'public.assignment_reward_log','public.daily_quest_reward_log','public.weekly_reward_log',
    'public.season_points_log','public.economy_config','public.league_tiers','public.league_cohorts',
    'public.student_league_state','public.bot_notification_state']) t
  where to_regclass(t) is null;
  if v_missing is not null then raise exception 'preflight: missing tables: %', v_missing; end if;
end $$;

-- --- STUDENT-OWN SELECT (writes через gateway'и) ---------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['student_items','student_equipment','student_showcase',
    'student_achievements','season_results','student_week_results','weekly_shield_uses',
    'streak_shield_uses','league_memberships','league_movements','league_season_awards',
    'student_daily_quests']
  loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists %I on public.%I', t||'_select_own', t);
    execute format('create policy %I on public.%I for select to authenticated using (student_id = public.jwt_student_id())',
                   t||'_select_own', t);
    execute format('revoke insert, update, delete on public.%I from anon, authenticated', t);
  end loop;
end $$;

-- student_daily_quest_options — own через parent (нет student_id). teacher/parent denied.
alter table public.student_daily_quest_options enable row level security;
drop policy if exists student_daily_quest_options_select_own on public.student_daily_quest_options;
create policy student_daily_quest_options_select_own on public.student_daily_quest_options
  for select to authenticated
  using (daily_quest_id in (select id from public.student_daily_quests where student_id = public.jwt_student_id()));
revoke insert, update, delete on public.student_daily_quest_options from anon, authenticated;

-- student_custom_titles — own + teacher (модерация).
alter table public.student_custom_titles enable row level security;
drop policy if exists student_custom_titles_select_own     on public.student_custom_titles;
drop policy if exists student_custom_titles_select_teacher on public.student_custom_titles;
create policy student_custom_titles_select_own     on public.student_custom_titles for select to authenticated
  using (student_id = public.jwt_student_id());
create policy student_custom_titles_select_teacher on public.student_custom_titles for select to authenticated
  using (public.jwt_app_role() = 'teacher');
revoke insert, update, delete on public.student_custom_titles from anon, authenticated;

-- --- CATALOG (authenticated SELECT) ---------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['shop_items','season_bundles','seasons']
  loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists %I on public.%I', t||'_select_auth', t);
    execute format('create policy %I on public.%I for select to authenticated using (true)', t||'_select_auth', t);
    execute format('revoke insert, update, delete on public.%I from anon, authenticated', t);
  end loop;
end $$;

-- life_quest_templates — active всем authenticated (каталог ученика), всё — teacher (admin UI).
alter table public.life_quest_templates enable row level security;
drop policy if exists life_quest_templates_select on public.life_quest_templates;
create policy life_quest_templates_select on public.life_quest_templates for select to authenticated
  using (active or public.jwt_app_role() = 'teacher');
revoke insert, update, delete on public.life_quest_templates from anon, authenticated;

-- --- TEACHER-ONLY (планирование) ------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['weekly_plans','weekly_plan_items']
  loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists %I on public.%I', t||'_select_teacher', t);
    execute format('create policy %I on public.%I for select to authenticated using (public.jwt_app_role() = ''teacher'')',
                   t||'_select_teacher', t);
    execute format('revoke insert, update, delete on public.%I from anon, authenticated', t);
  end loop;
end $$;

-- --- DENY-CLIENT (RLS on, без политик, revoke all) ------------------------------------------
-- Ledgers/points, config, league internal/catalog-via-RPC, bot state. Доступ только definer-
-- gateway'ям (owner) и service_role.
do $$
declare t text;
begin
  foreach t in array array['assignment_reward_log','daily_quest_reward_log','weekly_reward_log',
    'season_points_log','economy_config','league_tiers','league_cohorts','student_league_state',
    'bot_notification_state']
  loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
  end loop;
end $$;

commit;

-- =============================================================================
-- ROLLBACK (возвращает pre-card grants/policies; RLS off на всех 29 таблицах этой карты):
--   begin;
--   -- снять политики
--   do $$ declare t text; begin
--     foreach t in array array['student_items','student_equipment','student_showcase',
--       'student_achievements','season_results','student_week_results','weekly_shield_uses',
--       'streak_shield_uses','league_memberships','league_movements','league_season_awards',
--       'student_daily_quests'] loop
--       execute format('drop policy if exists %I on public.%I', t||'_select_own', t); end loop;
--   end $$;
--   drop policy if exists student_daily_quest_options_select_own on public.student_daily_quest_options;
--   drop policy if exists student_custom_titles_select_own on public.student_custom_titles;
--   drop policy if exists student_custom_titles_select_teacher on public.student_custom_titles;
--   drop policy if exists shop_items_select_auth on public.shop_items;
--   drop policy if exists season_bundles_select_auth on public.season_bundles;
--   drop policy if exists seasons_select_auth on public.seasons;
--   drop policy if exists life_quest_templates_select on public.life_quest_templates;
--   drop policy if exists weekly_plans_select_teacher on public.weekly_plans;
--   drop policy if exists weekly_plan_items_select_teacher on public.weekly_plan_items;
--   -- RLS off + вернуть default-гранты anon/authenticated (все 29)
--   do $$ declare t text; begin
--     foreach t in array array['student_items','student_equipment','student_showcase',
--       'student_custom_titles','student_achievements','season_results','student_week_results',
--       'weekly_shield_uses','streak_shield_uses','league_memberships','league_movements',
--       'league_season_awards','student_daily_quests','student_daily_quest_options','shop_items',
--       'season_bundles','seasons','life_quest_templates','weekly_plans','weekly_plan_items',
--       'assignment_reward_log','daily_quest_reward_log','weekly_reward_log','season_points_log',
--       'economy_config','league_tiers','league_cohorts','student_league_state','bot_notification_state'] loop
--       execute format('alter table public.%I disable row level security', t);
--       execute format('grant select, insert, update, delete on public.%I to anon, authenticated', t);
--     end loop;
--   end $$;
--   commit;
--   -- вернуть inner read-RPC и снять новые
--   grant execute on function public.get_student_league_snapshot(bigint) to anon, authenticated;
--   grant execute on function public.get_student_rank_title(bigint) to anon, authenticated;
--   grant execute on function public.preview_league_close() to anon, authenticated;
--   drop function if exists public.preview_league_close_self();
--   drop function if exists public.get_student_rank_title_self();
--   drop function if exists public.get_student_league_snapshot_self();
--   drop function if exists public.ensure_current_season();
--   drop function if exists public.get_economy_flags();
-- ВНИМАНИЕ: откат клиента (client switch T10-08B) — ДО отката миграции.
-- =============================================================================
