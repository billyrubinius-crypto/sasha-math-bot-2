-- =============================================================================
-- 051_lifetime_rating_and_scheduled_seasons.sql — стабилизация: накопительный рейтинг
-- за всё время + планирование сезонов на сайте учителя.
-- (Bot 2.0, стабилизационный этап после Cosmic Academy stage 9; правки к 005/006/019/038/043)
--
-- ПРОБЛЕМА 1 — общий топ показывал очки ОДНОГО сезона.
--   students.rating обнуляется в close_season (миграция 005/006), а клиент сортировал
--   лидерборд именно по нему (js/student-progress.js, loadGlobalTop) с limit(10). После
--   T10-08A (миграция 042) на students включён RLS «своя строка + учитель», поэтому у
--   ученика этот прямой select вообще возвращал одну строку — его самого.
--   РЕШЕНИЕ: исторический рейтинг НЕ вводится новой таблицей — он уже есть в
--   season_results (unique(season_id, student_id), пишется один раз при закрытии сезона).
--   Общий рейтинг = sum(season_results.points) за все закрытые сезоны + students.rating
--   за текущий. Он ВЫЧИСЛЯЕМЫЙ, не хранимый и не инкрементируемый — поэтому повторное
--   завершение сезона физически не может прибавить один и тот же результат дважды.
--   Выдачу отдаёт узкий definer-RPC get_global_top_self (RLS обойти иначе нельзя).
--
-- ПРОБЛЕМА 2 — сезоны нельзя было планировать: в seasons нет ни названия, ни времени
--   начала/окончания, ни статуса; сезон появлялся только «сейчас» (ensure_current_season)
--   или при закрытии предыдущего (close_season).
--   РЕШЕНИЕ: seasons получает title / starts_at / ends_at / status ('planned'|'active'|
--   'completed').
--
--   СОВМЕСТИМОСТЬ (важно): во всём проекте «текущий сезон» ищется как
--   `end_date is null order by id desc limit 1` — так делают close_season,
--   award_season_points, ensure_league_membership, ensure_season_rotation,
--   get_student_league_snapshot, preview_league_close, ensure_current_season и два
--   клиентских запроса. Чтобы НЕ переписывать десяток селекторов (и не получить окно,
--   где запланированный сезон с большим id подменяет текущий), у запланированного сезона
--   end_date ЗАПОЛНЕН плановой датой окончания. Инвариант закреплён check-ограничением:
--       (status = 'active') = (end_date is null)
--   То есть end_date is null по-прежнему означает ровно «этот сезон идёт», а planned и
--   completed отличаются только полем status. Единственное место, где раньше «end_date
--   не null» трактовалось как «сезон закрыт» — supabase/functions/_shared/db.ts
--   (fetchLatestClosedSeasonId для лиговых уведомлений main.py); там добавлен фильтр
--   status = 'completed'.
--
--   Номер сезона = seasons.id (так он и показывается в UI: «Сезон №N»). Отдельная колонка
--   не вводится: PK уже даёт обязательность и уникальность номера, а весь существующий
--   код (season_results.season_id, season_bundles.season_id, `order by id desc limit 1`)
--   продолжает работать без изменений. Учитель задаёт номер явно при создании; он обязан
--   быть больше последнего, иначе сломался бы хронологический порядок `order by id`.
--
-- МЕХАНИЗМ АКТИВАЦИИ. Cron в проекте нет (нет pg_cron, нет планировщика на стороне
--   Supabase; фоновые задачи main.py ходят через student-bot-api и занимаются рассылками).
--   Поэтому переход состояний — ленивый, на обращении, тем же паттерном, которым уже
--   создаётся сезон (ensure_current_season вызывается из Mini App). ensure_season_schedule()
--   под транзакционным advisory-lock: если у активного сезона истёк ends_at ИЛИ подошёл
--   starts_at запланированного — активный завершается (архив/призы/лиги) и активируется
--   следующий. Ровно один сезон активен всегда (partial unique index сохранён).
--
-- ИДЕМПОТЕНТНОСТЬ ЗАВЕРШЕНИЯ. finish_season блокирует строку сезона (for update) и
--   работает только если status = 'active'; статус переводится в 'completed' первым же
--   действием той же транзакции. Повторный/параллельный вызов дождётся блокировки, увидит
--   'completed' и выйдет без архива и без призов. Вставка в season_results дополнительно
--   защищена on conflict do nothing.
--
-- Ничего не удаляется, все ALTER — аддитивные, миграция идемпотентна (if not exists /
-- drop constraint if exists перед add).
-- =============================================================================

begin;

-- --- 1. seasons: название, плановое окно, статус --------------------------------------------
alter table public.seasons add column if not exists title     text;
alter table public.seasons add column if not exists starts_at timestamptz;
alter table public.seasons add column if not exists ends_at   timestamptz;
alter table public.seasons add column if not exists status    text;

-- Backfill существующих сезонов: идущий → active, закрытый → completed. Плановое окно у
-- исторических сезонов неизвестно и НЕ выдумывается (starts_at/ends_at остаются null).
update public.seasons
   set status = case when end_date is null then 'active' else 'completed' end
 where status is null;

alter table public.seasons alter column status set default 'active';
alter table public.seasons alter column status set not null;

alter table public.seasons drop constraint if exists seasons_status_check;
alter table public.seasons add constraint seasons_status_check
  check (status in ('planned', 'active', 'completed'));

-- Ключевой инвариант совместимости: «идёт» ⇔ end_date is null (см. шапку).
alter table public.seasons drop constraint if exists seasons_active_end_date;
alter table public.seasons add constraint seasons_active_end_date
  check ((status = 'active') = (end_date is null));

-- Окно осмысленно: конец позже начала. Проверяется и на уровне RPC (понятный текст учителю).
alter table public.seasons drop constraint if exists seasons_window_order;
alter table public.seasons add constraint seasons_window_order
  check (starts_at is null or ends_at is null or ends_at > starts_at);

-- У запланированного сезона окно обязательно (иначе непонятно, когда его активировать).
alter table public.seasons drop constraint if exists seasons_planned_window_required;
alter table public.seasons add constraint seasons_planned_window_required
  check (status <> 'planned' or (starts_at is not null and ends_at is not null));

-- Название непустое, если задано (у исторических сезонов остаётся null — UI покажет «Сезон №N»).
alter table public.seasons drop constraint if exists seasons_title_shape;
alter table public.seasons add constraint seasons_title_shape
  check (title is null or (char_length(btrim(title)) between 1 and 60 and title = btrim(title)));

create index if not exists idx_seasons_status on public.seasons (status, starts_at);

comment on column public.seasons.status is
  'planned | active | completed. Ровно один active (idx_seasons_one_active). У planned и '
  'completed end_date НЕ null (инвариант seasons_active_end_date), поэтому все существующие '
  'селекторы "end_date is null" продолжают означать "текущий сезон".';
comment on column public.seasons.starts_at is 'Плановое начало (timestamptz; учитель вводит в МСК).';
comment on column public.seasons.ends_at   is 'Плановое окончание (timestamptz; учитель вводит в МСК).';
comment on column public.seasons.title     is 'Название сезона для UI; null у исторических сезонов.';

-- --- 2. current_season_id — канонический селектор для нового кода ---------------------------
-- Существующие функции продолжают искать сезон как end_date is null (это то же самое, см.
-- шапку); новый код пользуется этой функцией, чтобы намерение читалось однозначно.
create or replace function public.current_season_id()
 returns bigint
 language sql
 stable
as $function$
  select id from public.seasons where status = 'active' order by id desc limit 1
$function$;

revoke all on function public.current_season_id() from public, anon;
grant execute on function public.current_season_id() to authenticated;

-- --- 3. Пожизненный рейтинг ------------------------------------------------------------------
-- Источник истины: season_results (архив закрытых сезонов, unique(season_id, student_id)) +
-- students.rating (текущий сезон). Вычисляется, не хранится — см. шапку.
create or replace function public.student_lifetime_points(p_student_id bigint)
 returns integer
 language sql
 stable
as $function$
  select coalesce((select sum(points)::integer
                     from public.season_results
                    where student_id = p_student_id), 0)
       + coalesce((select rating from public.students
                    where telegram_id = p_student_id), 0)
$function$;

revoke all on function public.student_lifetime_points(bigint) from public, anon;
grant execute on function public.student_lifetime_points(bigint) to authenticated;

-- --- 4. Публичная косметика ученика ----------------------------------------------------------
-- Лидерборду и лиге нужны ник/рамка/титул ЧУЖИХ участников, а student_equipment закрыт
-- RLS «своя строка» (миграция 043). Отдельный select клиенту не вернёт ничего, поэтому
-- косметика приезжает готовой картой slot → {item_code, variant, payload, name} внутри тех
-- же definer-RPC. Формат совпадает с buildEquipMap() на клиенте, чтобы рендер (renderNick /
-- applyAvatarFrame / equippedTitleText) не переписывать.
-- Каталог берётся БЕЗ фильтра active: предмет снятого с продажи сезона надет и должен
-- отображаться (см. миграцию 053).
create or replace function public.student_public_cosmetics(p_student_id bigint)
 returns jsonb
 language sql
 stable
as $function$
  select coalesce(
           jsonb_object_agg(e.slot, jsonb_build_object(
             'item_code', e.item_code,
             'variant',   e.variant,
             'payload',   si.render_payload,
             'name',      si.name)),
           '{}'::jsonb)
    from public.student_equipment e
    join public.shop_items si on si.item_code = e.item_code
   where e.student_id = p_student_id
$function$;

revoke all on function public.student_public_cosmetics(bigint) from public, anon;
grant execute on function public.student_public_cosmetics(bigint) to authenticated;

-- --- 5. get_global_top_self — общий топ за всё время -----------------------------------------
-- Все зарегистрированные ученики (в схеме нет ни статуса удаления, ни блокировки — фильтровать
-- нечего и выдумывать статусы нельзя). Сортировка стабильная и полностью детерминированная:
--   1) общий рейтинг за все сезоны;
--   2) очки текущего сезона (существующий дополнительный критерий);
--   3) имя;
--   4) telegram_id.
-- Пагинация есть (p_limit/p_offset) + total в каждой строке, чтобы клиент мог догрузить всё.
-- Скрытого «первых 10» больше нет: клиент листает до total.
create or replace function public.get_global_top_self(
  p_limit  integer default 100,
  p_offset integer default 0)
 returns table(
   place           integer,
   student_id      bigint,
   name            text,
   lifetime_points integer,
   season_points   integer,
   equipment       jsonb,
   total_students  integer)
 language plpgsql
 security definer
 set search_path = public, pg_temp
as $function$
declare
  v_limit  integer;
  v_offset integer;
begin
  if private.current_app_role() not in ('student', 'teacher') then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  v_limit  := least(greatest(coalesce(p_limit, 100), 1), 500);
  v_offset := greatest(coalesce(p_offset, 0), 0);

  return query
  with totals as (
    select s.telegram_id            as student_id,
           coalesce(s.name, '')     as name,
           coalesce(s.rating, 0)    as season_points,
           coalesce(a.total, 0) + coalesce(s.rating, 0) as lifetime_points
      from public.students s
      left join (
        select student_id, sum(points)::integer as total
          from public.season_results
         group by student_id) a on a.student_id = s.telegram_id
  ),
  ranked as (
    select t.*,
           (row_number() over (
              order by t.lifetime_points desc,
                       t.season_points   desc,
                       t.name            asc,
                       t.student_id      asc))::integer as place,
           (count(*) over ())::integer as total_students
      from totals t
  )
  select r.place, r.student_id, r.name, r.lifetime_points, r.season_points,
         public.student_public_cosmetics(r.student_id),
         r.total_students
    from ranked r
   order by r.place
   limit v_limit offset v_offset;
end;
$function$;

revoke all on function public.get_global_top_self(integer, integer) from public, anon;
grant execute on function public.get_global_top_self(integer, integer) to authenticated;

-- --- 6. Жизненный цикл сезона: примитивы ------------------------------------------------------

-- start_next_season — активировать следующий сезон. Сначала подошедший по плану (starts_at <=
-- now(), самый ранний), иначе — ad-hoc «сегодня» (прежнее поведение close_season /
-- ensure_current_season, чтобы активный сезон существовал ВСЕГДА).
-- p_seed_cohorts: посев лиговых когорт. finish_season передаёт false, потому что посев с
-- правильным seed-сезоном делает close_league_season (шаг 10e миграции 019) — если посеять
-- раньше с null, snake-seeding по месту прошлого сезона потерялся бы.
create or replace function public.start_next_season(p_seed_cohorts boolean default true)
 returns bigint
 language plpgsql
as $function$
declare
  v_today date := (now() at time zone 'Europe/Moscow')::date;
  v_id    bigint;
begin
  select id into v_id
    from public.seasons
   where status = 'planned'
     and starts_at <= now()
   order by starts_at asc, id asc
   limit 1
   for update;

  if v_id is not null then
    -- end_date снимается (инвариант: active ⇔ end_date is null), start_date остаётся
    -- ПЛАНОВОЙ датой начала по МСК даже если активация случилась позже (ленивый переход).
    update public.seasons
       set status     = 'active',
           end_date   = null,
           start_date = (starts_at at time zone 'Europe/Moscow')::date
     where id = v_id;
    if p_seed_cohorts then
      perform public.build_season_cohorts(v_id, null);
    end if;
    return v_id;
  end if;

  insert into public.seasons (start_date, status) values (v_today, 'active')
  returning id into v_id;
  if p_seed_cohorts then
    perform public.build_season_cohorts(v_id, null);
  end if;
  return v_id;
end;
$function$;

revoke all on function public.start_next_season(boolean) from public, anon, authenticated;

-- finish_season — завершение сезона ОДИН РАЗ (см. «идемпотентность» в шапке).
-- Тело — прежний close_season (миграция 006, расширенный 019): архив итогов с тем же
-- детерминированным tie-break, призы топ-3 (фонд <= 190), лиговое закрытие, обнуление
-- rating. Новое: гейт по status + перевод в 'completed' первым действием, on conflict
-- do nothing на архиве и активация следующего сезона через start_next_season.
create or replace function public.finish_season(p_season_id bigint)
 returns json
 language plpgsql
as $function$
declare
  v_status       text;
  v_start_date   date;
  v_start_ts     timestamptz;
  v_today        date := (now() at time zone 'Europe/Moscow')::date;
  v_new_season_id bigint;
  v_archived     integer := 0;
  v_awarded      integer := 0;
  v_reward       integer;
  r record;
begin
  select status, start_date into v_status, v_start_date
    from public.seasons
   where id = p_season_id
   for update;

  if v_status is null then
    raise exception 'Сезон % не найден', p_season_id;
  end if;

  -- Уже завершён (повторный вызов, retry, параллельный клиент) — ничего не делаем.
  if v_status <> 'active' then
    return json_build_object(
      'season_id', p_season_id,
      'archived',  0,
      'awarded',   0,
      'next_season_id', public.current_season_id(),
      'already_completed', true);
  end if;

  v_start_ts := (v_start_date::timestamp) at time zone 'Europe/Moscow';

  -- Флип статуса ПЕРВЫМ действием: любой конкурент, ждавший for update, увидит 'completed'.
  update public.seasons
     set status = 'completed', end_date = v_today
   where id = p_season_id;

  -- Блокируем учеников до снимка очков (гонка с add_season_points, см. миграцию 006).
  perform 1 from public.students for update;

  insert into public.season_results (season_id, student_id, points, place)
  select p_season_id, s.telegram_id, s.rating,
         row_number() over (
           order by s.rating desc,
                    coalesce(pen.cnt, 0) asc,
                    pts.last_scored asc nulls last,
                    s.telegram_id asc)
    from public.students s
    left join (
      select student_id, count(*) as cnt
        from public.balance_history
       where reason like 'penalty:%' and created_at >= v_start_ts
       group by student_id) pen on pen.student_id = s.telegram_id
    left join (
      select student_id, max(created_at) as last_scored
        from public.season_points_log
       where season_id = p_season_id and amount <> 0
       group by student_id) pts on pts.student_id = s.telegram_id
  on conflict (season_id, student_id) do nothing;
  get diagnostics v_archived = row_count;

  for r in
    select student_id, place
      from public.season_results
     where season_id = p_season_id and place <= 3 and points > 0
     order by place
  loop
    v_reward := case r.place when 1 then 100 when 2 then 60 else 30 end;
    perform public.add_huikons(r.student_id, v_reward, 'season_place_' || r.place);
    v_awarded := v_awarded + 1;
  end loop;

  -- Следующий сезон открывается ДО лигового закрытия: короне и посеву когорт нужен его id.
  -- Посев когорт делает close_league_season с правильным seed-сезоном (см. start_next_season).
  v_new_season_id := public.start_next_season(false);

  perform public.close_league_season(p_season_id, v_new_season_id);

  update public.students set rating = 0 where rating <> 0;

  return json_build_object(
    'season_id', p_season_id,
    'archived',  v_archived,
    'awarded',   v_awarded,
    'next_season_id', v_new_season_id,
    'already_completed', false);
end;
$function$;

revoke all on function public.finish_season(bigint) from public, anon, authenticated;

-- close_season — РУЧНОЕ закрытие учителем. Формат ответа сохранён (season_id/archived/
-- awarded); next_season_id/already_completed добавлены, старые вызовы их просто не читают.
-- Защита «сезон, открытый сегодня, закрыть нельзя» остаётся только здесь (плановое
-- завершение управляется ends_at и не должно упираться в календарный день).
create or replace function public.close_season()
 returns json
 language plpgsql
as $function$
declare
  v_season_id  bigint;
  v_start_date date;
  v_today      date := (now() at time zone 'Europe/Moscow')::date;
begin
  select id, start_date into v_season_id, v_start_date
    from public.seasons
   where status = 'active'
   order by id desc
   limit 1
   for update;

  if v_season_id is null then
    raise exception 'Нет открытого сезона';
  end if;

  if v_start_date >= v_today then
    raise exception 'Сезон №% открыт сегодня — закрывать можно не раньше следующего дня', v_season_id;
  end if;

  return public.finish_season(v_season_id);
end;
$function$;

-- --- 7. ensure_season_schedule — ленивый плановый переход -------------------------------------
-- Единственный механизм активации/завершения по расписанию (cron в проекте нет, см. шапку).
-- Вызывается из ensure_current_season, то есть на любом обращении Mini App/учителя.
-- Транзакционный advisory-lock сериализует одновременные вызовы: второй ждёт и застаёт уже
-- выполненный переход, поэтому двойного завершения не происходит даже без гонки на строке.
create or replace function public.ensure_season_schedule()
 returns bigint
 language plpgsql
as $function$
declare
  v_active     bigint;
  v_active_end timestamptz;
  v_due_planned bigint;
begin
  perform pg_advisory_xact_lock(hashtext('sasha_math_season_schedule'));

  select id, ends_at into v_active, v_active_end
    from public.seasons
   where status = 'active'
   order by id desc
   limit 1;

  select id into v_due_planned
    from public.seasons
   where status = 'planned' and starts_at <= now()
   order by starts_at asc, id asc
   limit 1;

  if v_active is not null then
    -- Активный сезон перестаёт быть активным, если истекло плановое окончание ИЛИ подошёл
    -- старт следующего запланированного (перекрытие окон запрещено при создании, поэтому
    -- второй случай — это legacy-сезон без ends_at, которому нашёлся плановый преемник).
    if (v_active_end is not null and v_active_end <= now()) or v_due_planned is not null then
      perform public.finish_season(v_active);
    end if;
  elsif v_due_planned is not null then
    perform public.start_next_season(true);
  end if;

  return public.current_season_id();
end;
$function$;

revoke all on function public.ensure_season_schedule() from public, anon, authenticated;

-- ensure_current_season — прежний контракт (returns bigint, создаёт сезон при отсутствии),
-- теперь сначала выполняет плановый переход. Ad-hoc создание сохранено внутри
-- start_next_season, поэтому «сезон появится, когда кто-то откроет лидерборд» работает как было.
create or replace function public.ensure_current_season()
 returns bigint
 language plpgsql
 security definer
 set search_path = public, pg_temp
as $function$
declare v_id bigint;
begin
  if private.current_app_role() not in ('student', 'teacher') then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  v_id := public.ensure_season_schedule();
  if v_id is not null then
    return v_id;
  end if;

  -- Активного сезона нет и планового перехода не случилось — открываем ad-hoc, как до 051.
  begin
    v_id := public.start_next_season(true);
  exception when unique_violation then
    v_id := public.current_season_id();
  end;
  return v_id;
end;
$function$;

revoke all on function public.ensure_current_season() from public, anon;
grant execute on function public.ensure_current_season() to authenticated;

-- --- 8. Административные RPC планирования сезонов ---------------------------------------------
-- Только app_role='teacher' из JWT (прямой insert/update/delete в seasons у anon/authenticated
-- отозван миграцией 043 — ученик не может ни создать сезон, ни изменить чужой итог).

-- admin_list_seasons_self — текущий + запланированные + завершённые, с однозначным статусом.
create or replace function public.admin_list_seasons_self()
 returns table(
   season_id    bigint,
   title        text,
   status       text,
   starts_at    timestamptz,
   ends_at      timestamptz,
   start_date   date,
   end_date     date,
   is_overdue   boolean,
   participants integer,
   archived     integer)
 language plpgsql
 security definer
 set search_path = public, pg_temp
as $function$
begin
  if private.current_app_role() is distinct from 'teacher' then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  return query
  select s.id,
         s.title,
         s.status,
         s.starts_at,
         s.ends_at,
         s.start_date,
         s.end_date,
         (s.status = 'active' and s.ends_at is not null and s.ends_at <= now()) as is_overdue,
         -- Участники лиг сезона. Миграция 052 переопределяет эту функцию так, чтобы
         -- считались только реально вступившие (activated_at is not null) — здесь колонки
         -- ещё нет, поэтому считаем все memberships.
         (select count(*)::integer from public.league_memberships m
           where m.season_id = s.id) as participants,
         (select count(*)::integer from public.season_results r where r.season_id = s.id) as archived
    from public.seasons s
   order by s.id desc;
end;
$function$;

-- admin_create_season_self — запланировать сезон.
-- Валидация (сообщения короткими кодами, текст показывает учительский UI):
--   season_number_required / season_number_taken / season_number_too_small
--   title_required / window_required / window_order / start_in_past / season_overlap
create or replace function public.admin_create_season_self(
  p_season_number bigint,
  p_title         text,
  p_starts_at     timestamptz,
  p_ends_at       timestamptz)
 returns json
 language plpgsql
 security definer
 set search_path = public, pg_temp
as $function$
declare
  v_princ    uuid;
  v_title    text;
  v_max_id   bigint;
  v_boundary timestamptz;
begin
  if private.current_app_role() is distinct from 'teacher' then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  if p_season_number is null or p_season_number <= 0 then
    raise exception 'season_number_required' using errcode = '22023';
  end if;

  v_title := btrim(coalesce(p_title, ''));
  if char_length(v_title) = 0 or char_length(v_title) > 60 then
    raise exception 'title_required' using errcode = '22023';
  end if;

  if p_starts_at is null or p_ends_at is null then
    raise exception 'window_required' using errcode = '22023';
  end if;
  if p_ends_at <= p_starts_at then
    raise exception 'window_order' using errcode = '22023';
  end if;
  if p_starts_at <= now() then
    raise exception 'start_in_past' using errcode = '22023';
  end if;

  -- Номер обязан быть свободным и больше последнего: весь проект считает `order by id`
  -- хронологией сезонов (см. шапку).
  if exists (select 1 from public.seasons where id = p_season_number) then
    raise exception 'season_number_taken' using errcode = '23505';
  end if;
  select max(id) into v_max_id from public.seasons;
  if v_max_id is not null and p_season_number <= v_max_id then
    raise exception 'season_number_too_small' using errcode = '22023';
  end if;

  -- Перекрытие временных рамок запрещено: сезоны в этом проекте строго последовательны
  -- (одновременно активен ровно один). Сверяем и с объявленными окнами, и с границей
  -- текущего/запланированных сезонов (у legacy-сезона окна нет — берём день после старта).
  if exists (
    select 1 from public.seasons s
     where s.starts_at is not null and s.ends_at is not null
       and tstzrange(s.starts_at, s.ends_at) && tstzrange(p_starts_at, p_ends_at)) then
    raise exception 'season_overlap' using errcode = '22023';
  end if;

  select max(coalesce(s.ends_at, ((s.start_date + 1)::timestamp at time zone 'Europe/Moscow')))
    into v_boundary
    from public.seasons s
   where s.status in ('active', 'planned');
  if v_boundary is not null and p_starts_at < v_boundary then
    raise exception 'season_overlap' using errcode = '22023';
  end if;

  v_princ := private.current_principal();

  insert into public.seasons (id, title, status, start_date, end_date, starts_at, ends_at)
  values (p_season_number,
          v_title,
          'planned',
          (p_starts_at at time zone 'Europe/Moscow')::date,
          (p_ends_at   at time zone 'Europe/Moscow')::date,
          p_starts_at,
          p_ends_at);

  -- id вставлен явно (колонка identity BY DEFAULT) — подтягиваем последовательность, иначе
  -- следующий ad-hoc сезон попробует занять уже использованный номер.
  perform setval(pg_get_serial_sequence('public.seasons', 'id'),
                 (select max(id) from public.seasons));

  perform public.security_audit('teacher_create_season', 'teacher', v_princ, null,
    json_build_object('season_id', p_season_number,
                      'starts_at', p_starts_at, 'ends_at', p_ends_at)::jsonb);

  return json_build_object('season_id', p_season_number, 'status', 'planned');
end;
$function$;

-- admin_update_season_self — изменить ТОЛЬКО запланированный сезон (у идущего и завершённого
-- окно менять нельзя: у первого от start_date зависят начисления и витрина, у второго — архив).
create or replace function public.admin_update_season_self(
  p_season_id bigint,
  p_title     text,
  p_starts_at timestamptz,
  p_ends_at   timestamptz)
 returns json
 language plpgsql
 security definer
 set search_path = public, pg_temp
as $function$
declare
  v_princ  uuid;
  v_status text;
  v_title  text;
begin
  if private.current_app_role() is distinct from 'teacher' then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_season_id is null then
    raise exception 'season_required' using errcode = '22023';
  end if;

  select status into v_status from public.seasons where id = p_season_id for update;
  if v_status is null then
    raise exception 'season_not_found' using errcode = 'P0002';
  end if;
  if v_status <> 'planned' then
    raise exception 'season_not_planned' using errcode = '22023';
  end if;

  v_title := btrim(coalesce(p_title, ''));
  if char_length(v_title) = 0 or char_length(v_title) > 60 then
    raise exception 'title_required' using errcode = '22023';
  end if;
  if p_starts_at is null or p_ends_at is null then
    raise exception 'window_required' using errcode = '22023';
  end if;
  if p_ends_at <= p_starts_at then
    raise exception 'window_order' using errcode = '22023';
  end if;
  if p_starts_at <= now() then
    raise exception 'start_in_past' using errcode = '22023';
  end if;
  if exists (
    select 1 from public.seasons s
     where s.id <> p_season_id
       and s.starts_at is not null and s.ends_at is not null
       and tstzrange(s.starts_at, s.ends_at) && tstzrange(p_starts_at, p_ends_at)) then
    raise exception 'season_overlap' using errcode = '22023';
  end if;

  v_princ := private.current_principal();

  update public.seasons
     set title      = v_title,
         starts_at  = p_starts_at,
         ends_at    = p_ends_at,
         start_date = (p_starts_at at time zone 'Europe/Moscow')::date,
         end_date   = (p_ends_at   at time zone 'Europe/Moscow')::date
   where id = p_season_id;

  perform public.security_audit('teacher_update_season', 'teacher', v_princ, null,
    json_build_object('season_id', p_season_id,
                      'starts_at', p_starts_at, 'ends_at', p_ends_at)::jsonb);

  return json_build_object('season_id', p_season_id, 'status', 'planned');
end;
$function$;

-- admin_delete_season_self — снять запланированный сезон. Только 'planned' и только пока к
-- нему ничего не привязано: исторические данные не удаляются никогда.
create or replace function public.admin_delete_season_self(p_season_id bigint)
 returns json
 language plpgsql
 security definer
 set search_path = public, pg_temp
as $function$
declare
  v_princ  uuid;
  v_status text;
begin
  if private.current_app_role() is distinct from 'teacher' then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_season_id is null then
    raise exception 'season_required' using errcode = '22023';
  end if;

  select status into v_status from public.seasons where id = p_season_id for update;
  if v_status is null then
    raise exception 'season_not_found' using errcode = 'P0002';
  end if;
  if v_status <> 'planned' then
    raise exception 'season_not_planned' using errcode = '22023';
  end if;
  if exists (select 1 from public.season_results   where season_id = p_season_id)
     or exists (select 1 from public.league_cohorts   where season_id = p_season_id)
     or exists (select 1 from public.season_bundles   where season_id = p_season_id)
     or exists (select 1 from public.season_points_log where season_id = p_season_id) then
    raise exception 'season_has_data' using errcode = '22023';
  end if;

  v_princ := private.current_principal();
  delete from public.seasons where id = p_season_id;

  perform public.security_audit('teacher_delete_season', 'teacher', v_princ, null,
    json_build_object('season_id', p_season_id)::jsonb);

  return json_build_object('season_id', p_season_id, 'deleted', true);
end;
$function$;

revoke all on function public.admin_list_seasons_self() from public, anon;
revoke all on function public.admin_create_season_self(bigint, text, timestamptz, timestamptz) from public, anon;
revoke all on function public.admin_update_season_self(bigint, text, timestamptz, timestamptz) from public, anon;
revoke all on function public.admin_delete_season_self(bigint) from public, anon;
grant execute on function public.admin_list_seasons_self() to authenticated;
grant execute on function public.admin_create_season_self(bigint, text, timestamptz, timestamptz) to authenticated;
grant execute on function public.admin_update_season_self(bigint, text, timestamptz, timestamptz) to authenticated;
grant execute on function public.admin_delete_season_self(bigint) to authenticated;

commit;

-- =============================================================================
-- ROLLBACK (dev-форк; исторические данные не затрагиваются):
--   begin;
--   -- вернуть close_season/ensure_current_season к версиям 006/043:
--   --   переприменить их тела из database/migrations/006_close_season.sql (раздел 1) и
--   --   043_t10_game_rls.sql (ensure_current_season). ensure_season_rotation этой
--   --   миграцией НЕ менялась. Остальное новое и просто удаляется.
--   drop function if exists public.admin_delete_season_self(bigint);
--   drop function if exists public.admin_update_season_self(bigint, text, timestamptz, timestamptz);
--   drop function if exists public.admin_create_season_self(bigint, text, timestamptz, timestamptz);
--   drop function if exists public.admin_list_seasons_self();
--   drop function if exists public.ensure_season_schedule();
--   drop function if exists public.finish_season(bigint);
--   drop function if exists public.start_next_season(boolean);
--   drop function if exists public.get_global_top_self(integer, integer);
--   drop function if exists public.student_public_cosmetics(bigint);
--   drop function if exists public.student_lifetime_points(bigint);
--   drop function if exists public.current_season_id();
--   delete from public.seasons where status = 'planned';
--   alter table public.seasons drop constraint if exists seasons_title_shape;
--   alter table public.seasons drop constraint if exists seasons_planned_window_required;
--   alter table public.seasons drop constraint if exists seasons_window_order;
--   alter table public.seasons drop constraint if exists seasons_active_end_date;
--   alter table public.seasons drop constraint if exists seasons_status_check;
--   drop index if exists public.idx_seasons_status;
--   alter table public.seasons drop column if exists status;
--   alter table public.seasons drop column if exists ends_at;
--   alter table public.seasons drop column if exists starts_at;
--   alter table public.seasons drop column if exists title;
--   commit;
-- =============================================================================
