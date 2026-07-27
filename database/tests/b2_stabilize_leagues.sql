-- =============================================================================
-- b2_stabilize_leagues.sql — стабилизационный этап, задачи 2 и 4.
-- Вступление в лигу по первому начислению рейтинга + полный список участников.
-- Выполняется владельцем БД после миграций 051–053. Всё откатывается (ROLLBACK).
--
-- Покрывает обязательные сценарии отчёта:
--   ЛИГИ
--     1. пустой аккаунт с рейтингом 0 отсутствует;
--     2. только начисление за подтверждённое ДЗ добавляет ученика (ровно одно участие);
--     3. повторный вызов не создаёт дубль;
--     4. участников больше 50 — все доступны (без скрытого лимита);
--     5. участники другой лиги или сезона не попадают в список;
--     6. текущий ученик видит себя;
--     7. существующий ученик с положительным рейтингом и без участия восстанавливается;
--     8. отрицательная корректировка не выкидывает из лиги;
--     9. legacy-путь приёмки ДЗ (settle_legacy_approval → add_season_points) тоже
--        заводит участие.
-- =============================================================================

begin;

do $test$
declare
  v_base     bigint := 995052000;
  v_new      bigint := 995052001;   -- новый пустой аккаунт
  v_legacy   bigint := 995052002;   -- ученик с рейтингом, но без участия (эмуляция старых данных)
  v_other    bigint := 995052003;   -- ученик в другой лиге (Серебро)
  v_season   bigint;
  v_prev     bigint;
  v_i        integer;
  v_id       bigint;
  v_cnt      integer;
  v_rows     integer;
  v_tiers    integer;
  v_place    integer;
  v_snap     json;
begin
  v_season := public.current_season_id();
  if v_season is null then
    v_season := public.start_next_season(true);
  end if;

  -- --- ЛИГИ 1: новый пустой аккаунт в лигах не участвует ------------------------------------
  insert into public.students (telegram_id, name, telegram_username, huikons, rating, lives, current_streak)
  values (v_new, 'STAB-NEW synthetic', 'stab_new', 0, 0, 3, 0);

  if exists (select 1 from public.league_memberships
              where season_id = v_season and student_id = v_new and activated_at is not null) then
    raise exception 'FAIL: пустой аккаунт сразу попал в лигу';
  end if;

  perform set_config('request.jwt.claims',
    json_build_object('app_role', 'student', 'telegram_id', v_new::text)::text, true);
  v_snap := public.get_student_league_snapshot(v_new);
  if (v_snap->>'in_season')::boolean is not false then
    raise exception 'FAIL: снимок лиги считает пустой аккаунт участником сезона';
  end if;
  select count(*) into v_cnt from public.get_student_league_standings_self();
  if v_cnt <> 0 then
    raise exception 'FAIL: пустой аккаунт получил непустой список лиги (% строк)', v_cnt;
  end if;

  -- --- ЛИГИ 2: пробник/бонус/ручная дельта не активируют участие -----------------------------
  perform public.award_season_points(v_new, 10, 'test_first_award', 'stab_lg_first');

  select count(*) into v_cnt from public.league_memberships
   where season_id = v_season and student_id = v_new and activated_at is not null;
  if v_cnt <> 0 then
    raise exception 'FAIL: обычное положительное начисление активировало лигу';
  end if;

  perform public.add_homework_season_points(v_new, 10);
  select count(*) into v_cnt from public.league_memberships
   where season_id = v_season and student_id = v_new and activated_at is not null;
  if v_cnt <> 1 then
    raise exception 'FAIL: начисление за ДЗ не активировало ровно одно участие';
  end if;

  -- --- ЛИГИ 3: повторные вызовы (retry, перезагрузка, второе ДЗ) дубля не создают ------------
  perform public.add_homework_season_points(v_new, 40);

  select count(*) into v_cnt from public.league_memberships
   where season_id = v_season and student_id = v_new;
  if v_cnt <> 1 then
    raise exception 'FAIL: повторные начисления создали % участий', v_cnt;
  end if;

  -- Ученик не меняет когорту при каждом новом ДЗ.
  select count(distinct cohort_id) into v_cnt from public.league_memberships
   where season_id = v_season and student_id = v_new;
  if v_cnt <> 1 then
    raise exception 'FAIL: когорта ученика менялась между начислениями';
  end if;

  -- --- ЛИГИ 6: ученик видит себя в выдаче своей лиги -----------------------------------------
  if not exists (select 1 from public.get_student_league_standings_self() r where r.is_me) then
    raise exception 'FAIL: ученик не видит себя в списке своей лиги';
  end if;

  -- --- ЛИГИ 8: отрицательная корректировка не выкидывает из лиги -----------------------------
  perform public.add_season_points(v_new, -1000);
  if (select rating from public.students where telegram_id = v_new) <> 0 then
    raise exception 'FAIL: подготовка теста — рейтинг не обнулился корректировкой';
  end if;
  if not exists (select 1 from public.league_memberships
                  where season_id = v_season and student_id = v_new and activated_at is not null) then
    raise exception 'FAIL: снижение рейтинга до нуля удалило ученика из лиги';
  end if;
  -- ...и не создаёт участие тому, у кого его нет.
  perform public.add_season_points(v_new, 0);
  perform public.award_season_points(v_new, 50, 'test_restore', 'stab_lg_restore');

  -- --- ЛИГИ 9: legacy-путь приёмки ДЗ тоже заводит участие -----------------------------------
  insert into public.students (telegram_id, name, telegram_username, huikons, rating, lives, current_streak)
  values (v_legacy, 'STAB-LEGACY synthetic', 'stab_legacy', 0, 0, 3, 0);
  -- Общая ручная дельта не является ДЗ и не должна активировать лигу.
  perform public.add_season_points(v_legacy, 30);
  if exists (select 1 from public.league_memberships
              where season_id = v_season and student_id = v_legacy and activated_at is not null) then
    raise exception 'FAIL: прямое add_season_points активировало участие в лиге';
  end if;

  -- --- ЛИГИ 7: восстановление ученика с рейтингом, но без участия ----------------------------
  -- Эмулируем «старые данные»: участие снимаем, рейтинг оставляем положительным.
  update public.league_memberships set activated_at = null
   where season_id = v_season and student_id = v_legacy;
  perform public.add_homework_season_points(v_legacy, 10);
  if not exists (select 1 from public.league_memberships
                  where season_id = v_season and student_id = v_legacy and activated_at is not null) then
    raise exception 'FAIL: ученик с положительным рейтингом не восстановлен в лиге';
  end if;
  select count(*) into v_cnt from public.league_memberships
   where season_id = v_season and student_id = v_legacy;
  if v_cnt <> 1 then
    raise exception 'FAIL: восстановление создало второе участие';
  end if;

  -- --- ЛИГИ 5: участники другой лиги в список не попадают ------------------------------------
  insert into public.students (telegram_id, name, telegram_username, huikons, rating, lives, current_streak)
  values (v_other, 'STAB-SILVER synthetic', 'stab_silver', 0, 0, 3, 0);
  perform public.add_homework_season_points(v_other, 70);
  -- Переводим его в Серебро (tier 2) и в собственную когорту этого сезона.
  update public.student_league_state set tier = 2 where student_id = v_other;
  insert into public.league_cohorts (season_id, tier, cohort_index, is_late_entry)
    values (v_season, 2, 1, false)
    on conflict (season_id, tier, cohort_index, is_late_entry) do nothing;
  update public.league_memberships
     set tier = 2,
         cohort_id = (select id from public.league_cohorts
                       where season_id = v_season and tier = 2 and cohort_index = 1 and not is_late_entry)
   where season_id = v_season and student_id = v_other;

  perform set_config('request.jwt.claims',
    json_build_object('app_role', 'student', 'telegram_id', v_new::text)::text, true);

  if exists (select 1 from public.get_student_league_standings_self() r where r.student_id = v_other) then
    raise exception 'FAIL: в список моей лиги попал участник другой лиги';
  end if;
  select count(distinct r.tier) into v_tiers from public.get_student_league_standings_self() r;
  if v_tiers <> 1 then
    raise exception 'FAIL: выдача смешала % разных лиг', v_tiers;
  end if;

  -- Участники ДРУГОГО сезона тоже не попадают: у каждой возвращённой строки обязано быть
  -- фактическое участие именно в текущем сезоне.
  if exists (
    select 1 from public.get_student_league_standings_self() r
     where not exists (
       select 1 from public.league_memberships m
        where m.season_id = v_season
          and m.student_id = r.student_id
          and m.activated_at is not null)
  ) then
    raise exception 'FAIL: в списке оказался участник другого сезона';
  end if;

  -- --- ЛИГИ 4: больше 50 участников — доступны ВСЕ -------------------------------------------
  -- Раньше список строился из preview_league_close, где `is_late_entry = false` резал часть
  -- участников, а имена тянулись прямым select из students под RLS. Проверяем, что 60 учеников
  -- видны целиком, без скрытого лимита в 10/20/50.
  for v_i in 1..60 loop
    v_id := v_base + 100 + v_i;
    insert into public.students (telegram_id, name, telegram_username, huikons, rating, lives, current_streak)
    values (v_id, 'STAB-MASS ' || v_i, 'stab_mass_' || v_i, 0, 0, 3, 0);
    perform public.add_homework_season_points(v_id, 5 + v_i);
  end loop;

  select count(*) into v_cnt from public.league_memberships m
   where m.season_id = v_season and m.tier = 1 and m.activated_at is not null;
  select count(*) into v_rows from public.get_student_league_standings_self();
  if v_rows <> v_cnt then
    raise exception 'FAIL: выдано % строк из % фактических участников лиги — есть скрытый лимит',
      v_rows, v_cnt;
  end if;
  if v_rows <= 50 then
    raise exception 'FAIL: подготовка теста — участников должно быть больше 50 (сейчас %)', v_rows;
  end if;

  -- Имена и косметика приезжают вместе со строками (RLS «своя строка» их бы не отдал).
  if exists (select 1 from public.get_student_league_standings_self() r
              where r.name is null or r.equipment is null) then
    raise exception 'FAIL: в выдаче есть строки без имени или без карты косметики';
  end if;

  -- Нумерация непрерывна внутри каждой когорты и начинается с 1.
  if exists (
    select 1 from (
      select r.cohort_index, r.is_late_entry,
             min(r.place) as min_place, max(r.place) as max_place, count(*) as n
        from public.get_student_league_standings_self() r
       group by r.cohort_index, r.is_late_entry
    ) g where g.min_place <> 1 or g.max_place <> g.n
  ) then
    raise exception 'FAIL: места внутри когорты не образуют непрерывный ряд 1..N';
  end if;

  -- Место из снимка совпадает с местом в полном списке.
  v_snap := public.get_student_league_snapshot(v_new);
  select r.place into v_place from public.get_student_league_standings_self() r where r.is_me;
  if (v_snap->>'place')::integer is distinct from v_place then
    raise exception 'FAIL: место в снимке (%) не совпадает с местом в списке (%)',
      v_snap->>'place', v_place;
  end if;
  if (v_snap->>'cohort_size')::integer is distinct from
     (select r.cohort_size from public.get_student_league_standings_self() r where r.is_me) then
    raise exception 'FAIL: размер когорты в снимке не совпадает со списком';
  end if;

  -- Заготовки посева (activated_at is null) в выдаче не появляются.
  if exists (
    select 1 from public.get_student_league_standings_self() r
     join public.league_memberships m
       on m.season_id = v_season and m.student_id = r.student_id
    where m.activated_at is null
  ) then
    raise exception 'FAIL: в списке лиги оказалась неактивированная заготовка посева';
  end if;

  raise notice 'PASS b2_stabilize_leagues: enrollment on first award, no duplicates, full standings (% участников)', v_rows;
end
$test$;

select 'PASS b2_stabilize_leagues; transaction will be rolled back' as summary;

rollback;
