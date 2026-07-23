-- =============================================================================
-- DEV ONLY: полный сброс тестовой игровой экономики перед T10-12B.
--
-- НИКОГДА не выполнять в production.
-- Перед запуском вручную убедиться, что в Supabase Dashboard открыт DEV-проект.
--
-- Что очищается:
--   * балансы, очки сезона, старый streak и история баланса;
--   * инвентарь, экипировка, витрина, custom titles и достижения;
--   * недельные результаты/щиты/награды;
--   * лиговые состояния и история тестовых сезонов;
--   * сгенерированные дневные квесты и их reward ledger;
--   * reward ledgers заданий и пробников.
--
-- Что сохраняется:
--   * students, assignments, планы, авторизация и родительские связи;
--   * weekly_mock_exams и mock_exam_results (траектория пробников);
--   * life_quest_templates (учительский каталог, из которого пойдёт генерация);
--   * shop_items, seasons и остальные справочники.
--
-- После успешного выполнения ОБЯЗАТЕЛЬНО отдельно выполнить целиком:
--   database/releases/stage4_cutover.sql
-- Он проверит чистое dormant-состояние, применит утверждённые цены и включит квесты.
-- =============================================================================

begin;

set local lock_timeout = '5s';
set local statement_timeout = '60s';

do $reset$
declare
  v_student_count integer;
  v_config_count  integer;
  v_config_rows   integer;
  v_job           record;
begin
  select count(*) into v_student_count from public.students;
  if v_student_count > 50 then
    raise exception
      'DEV RESET ABORT: найдено % учеников (>50). Проверьте, что открыт DEV-проект',
      v_student_count;
  end if;

  select count(*) into v_config_count
    from public.economy_config
   where id;
  if v_config_count <> 1 then
    raise exception
      'DEV RESET ABORT: economy_config должен содержать ровно одну строку id=true (count=%)',
      v_config_count;
  end if;

  -- Дочерние строки квестов удаляются раньше дневного набора.
  delete from public.daily_quest_reward_log;
  delete from public.student_daily_quest_options;
  delete from public.student_daily_quests;

  -- Недельная экономика и все её тестовые pay-once ledgers.
  delete from public.weekly_shield_uses;
  delete from public.weekly_reward_log;
  delete from public.student_week_results;
  delete from public.assignment_reward_log;
  delete from public.mock_exam_reward_log;

  -- Профильная игровая экономика.
  delete from public.student_showcase;
  delete from public.student_equipment;
  delete from public.student_custom_titles;
  delete from public.streak_shield_uses;
  delete from public.student_items;
  delete from public.student_achievements;

  -- Сезонные очки и тестовые лиги. Справочник league_tiers сохраняется.
  delete from public.league_season_awards;
  delete from public.league_movements;
  delete from public.league_memberships;
  delete from public.league_cohorts;
  delete from public.student_league_state;
  delete from public.season_results;
  delete from public.season_points_log;

  -- Сохранённые пробники остаются видимыми, но их экономическая дельта начинается заново.
  update public.weekly_mock_exams
     set season_points_awarded = 0,
         updated_at = now()
   where season_points_awarded <> 0;

  delete from public.balance_history;

  update public.students
     set huikons                  = 0,
         rating                   = 0,
         lives                    = 3,
         current_streak           = 0,
         last_submission_date_msk = null;

  -- Возвращаем только Stage 4-цены в ожидаемое pre-cutover состояние.
  -- Следующий stage4_cutover.sql снова проверит полный каталог перед запуском.
  update public.shop_items set price = 50
   where item_code in (
     'color_red','color_orange','color_green','color_teal',
     'color_blue','color_indigo','color_pink','color_brown'
   );
  update public.shop_items set price = 30   where item_code = 'status_emoji_change';
  update public.shop_items set price = 600  where item_code = 'crown';
  update public.shop_items set price = 700  where item_code = 'golden_nick';
  update public.shop_items set price = 900  where item_code = 'title_yaschenko';
  update public.shop_items set price = 2000 where item_code = 'title_custom';
  update public.shop_items set active = true where item_code = 'frame_fire100';
  update public.shop_items set price = 200  where item_code = 'title_groza';
  update public.shop_items set price = 150
   where item_code in ('title_elon','title_derivative');
  update public.shop_items set price = 120  where item_code = 'title_sanchez';
  update public.shop_items set price = 150
   where item_code in ('frame_notebook','frame_winter');
  update public.shop_items set price = 200
   where item_code in ('bg_grid','bg_space','bg_aurora','bg_draft');
  update public.shop_items set price = 750
   where item_code in ('frame_pulsar','frame_orbit');
  update public.shop_items set price = 1500
   where item_code in (
     'frame_legend_1','frame_legend_2','frame_legend_3','frame_legend_4'
   );

  -- На dev включаем недельную модель немедленно, с начала текущей недели по Москве.
  -- Stage 4 пока возвращается в чистый dormant: её включит штатный guarded cutover.
  update public.economy_config
     set cutover_at = (
           date_trunc('week', timezone('Europe/Moscow', now()))
           at time zone 'Europe/Moscow'
         ),
         stage4_started_at         = null,
         stage4_generation_enabled = false,
         updated_at                = now()
   where id;
  get diagnostics v_config_rows = row_count;
  if v_config_rows <> 1 then
    raise exception
      'DEV RESET ABORT: economy_config update затронул % строк вместо 1',
      v_config_rows;
  end if;

  -- Полностью заменяем только наш именованный job, не трогая другие cron-задачи.
  for v_job in
    select jobid
      from cron.job
     where jobname = 'finalize-weeks'
  loop
    perform cron.unschedule(v_job.jobid);
  end loop;

  perform cron.schedule(
    'finalize-weeks',
    '*/45 * * * *',
    $job$select public.finalize_due_student_weeks()$job$
  );

  raise notice
    'DEV GAME RESET OK: students=%, weekly cutover active from current MSK week; Stage 4 remains dormant until stage4_cutover.sql',
    v_student_count;
end
$reset$;

commit;

-- Итоговая проверка reset. Все SELECT должны вернуть согласованное состояние.
select
  count(*)                                      as students,
  coalesce(sum(huikons), 0)                    as total_huikons,
  coalesce(sum(rating), 0)                     as total_rating,
  coalesce(max(current_streak), 0)             as max_streak,
  coalesce(min(lives), 3)                      as min_lives,
  coalesce(max(lives), 3)                      as max_lives
from public.students;

select
  cutover_at,
  stage4_started_at,
  stage4_generation_enabled
from public.economy_config
where id;

select
  (select count(*) from public.student_daily_quests)       as daily_quests,
  (select count(*) from public.daily_quest_reward_log)     as quest_rewards,
  (select count(*) from public.student_items)              as inventory,
  (select count(*) from public.student_achievements)       as achievements,
  (select count(*) from public.student_week_results)       as week_results,
  (select count(*) from public.balance_history)            as balance_events,
  (select count(*) from public.season_points_log)          as season_events,
  (select count(*) from public.life_quest_templates)       as quest_templates;

select jobname, schedule, command, active
from cron.job
where jobname = 'finalize-weeks';
