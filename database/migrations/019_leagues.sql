-- =============================================================================
-- 019_leagues.sql — адаптивные лиги, звания и атомарное закрытие сезона с лигами
-- (Bot 2.0, Stage 3, карточка L01; SPEC_STAGE3.md, ECONOMY_V2.md §11)
--
-- Зачем: добавить семь лиг с адаптивными когортами для малого состава, производное
-- трудовое звание и расширить существующий атомарный close_season одной серверной
-- операцией, которая считает места/переходы/временную Корону внутри той же транзакции.
-- Клиент (L02-L05) ничего не пересчитывает — только читает серверные RPC.
--
-- ГРАНИЦЫ (EXECUTION_CONTEXT, SPEC_STAGE3 §7):
--   * global top-3 (100/60/30, фонд ровно 190) остаётся в close_season без изменений —
--     лиговые места НЕ создают дополнительную эмиссию бубликов;
--   * очки сезона по-прежнему идут через ledger-aware award_season_points; add_season_points
--     остаётся низкоуровневой внутренней функцией и напрямую здесь не вызывается;
--   * students.rating, seasons, season_results сохраняются; вычислимое текущее место в
--     students НЕ хранится; отдельная валюта лиг НЕ вводится;
--   * временная Корona живёт в league_season_awards — НЕ в shop_items/student_items/
--     student_equipment, поэтому FK магазина не ослабляются и корона не продаётся;
--   * старые season_results без когорт читаются как legacy (close-функция их пропускает).
--
-- ИДЕМПОТЕНТНОСТЬ И АТОМАРНОСТЬ:
--   close_league_season вызывается ВНУТРИ close_season, под теми же блокировками
--   (единственный открытый сезон for update + все students for update). Повторный/
--   конкурентный close защищён инвариантом «один открытый сезон» и guard'ом
--   «сезон, открытый сегодня, закрыть нельзя»; вдобавок league_memberships/league_movements
--   уникальны по (season_id, student_id), а league_season_awards — по
--   (award_code, earned_season_id, student_id). Второй проход не создаёт второй переход,
--   результат или корону.
--
-- РЕШЕНИЯ ИНТЕРПРЕТАЦИИ (зафиксированы здесь, мотивация — в карточке L01/SPEC_STAGE3):
--   1. Внутрикогортное место берётся как ранг по глобальному season_results.place — он уже
--      кодирует полный детерминированный tie-break сезона (rating desc → меньше штрафов →
--      раньше набрал очки → telegram_id). Отдельно tie-break не переприменяется.
--   2. Движение (promote/demote) считается ТОЛЬКО среди активных (points > 0); ученик с
--      нулём очков конкурентного места не занимает и движется лишь по правилу неактивности.
--   3. Неактивность: активный сезон обнуляет счётчик; первый полностью неактивный сезон —
--      neutral (лига сохраняется, счётчик = 1); второй и каждый следующий понижает на одну
--      ступень до Бронзы (счётчик продолжает расти, понижение только при tier > 1).
--   4. late_entry: membership без движения и без изменения tier/счётчика неактивности в свой
--      первый неполный сезон; в global top-3 он всё равно попадает через season_results.
--   5. Bootstrap-сезон (текущий открытый на момент миграции) — первый лиговый: ВСЕ
--      существующие ученики становятся обычными участниками Бронзы; seeding когорт при
--      bootstrap только по telegram_id (никакой скрытой калибровки по историческому rating).
--   6. Разовые достижения за повышения (§6 «могут») в L01 НЕ реализуются: их бублик-суммы не
--      заданы точной картой, а конституция запрещает вводить экономические суммы вне карточки.
--      Корона реализована (она без бубликов). Достижения — отдельным решением позже.
--
-- Повторный прогон миграции безопасен (create ... if not exists / or replace). RLS у новых
-- таблиц выключен, как у всех таблиц проекта (T10). Bootstrap-блок в конце идемпотентен.
-- =============================================================================

-- --- 1. Справочник семи лиг ----------------------------------------------------
create table if not exists public.league_tiers (
  tier  integer primary key check (tier between 1 and 7),
  code  text    not null unique,
  name  text    not null
);
alter table public.league_tiers disable row level security;

insert into public.league_tiers (tier, code, name) values
  (1, 'bronze',   'Бронза'),
  (2, 'silver',   'Серебро'),
  (3, 'gold',     'Золото'),
  (4, 'platinum', 'Платина'),
  (5, 'diamond',  'Алмаз'),
  (6, 'master',   'Мастер'),
  (7, 'legend',   'Легенда')
on conflict (tier) do nothing;

-- --- 2. Постоянное лиговое состояние ученика -----------------------------------
-- tier — текущая лига; inactive_seasons — число подряд полностью неактивных сезонов.
create table if not exists public.student_league_state (
  student_id       bigint      primary key references public.students (telegram_id),
  tier             integer     not null default 1 references public.league_tiers (tier),
  inactive_seasons integer     not null default 0,
  updated_at       timestamptz not null default now(),
  created_at       timestamptz not null default now()
);
alter table public.student_league_state disable row level security;

-- --- 3. Когорта конкретного сезона и лиги --------------------------------------
-- is_late_entry = отдельная когорта поздних новичков (до 30), не участвует в движении.
create table if not exists public.league_cohorts (
  id            bigint      generated by default as identity primary key,
  season_id     bigint      not null references public.seasons (id),
  tier          integer     not null references public.league_tiers (tier),
  cohort_index  integer     not null,
  is_late_entry boolean     not null default false,
  created_at    timestamptz not null default now(),
  unique (season_id, tier, cohort_index, is_late_entry)
);
create index if not exists idx_league_cohorts_season
  on public.league_cohorts (season_id);
alter table public.league_cohorts disable row level security;

-- --- 4. Membership ученика в когорте сезона ------------------------------------
-- seed — позиция посева при создании когорты; points/place/movement заполняются при закрытии.
create table if not exists public.league_memberships (
  id            bigint      generated by default as identity primary key,
  season_id     bigint      not null references public.seasons (id),
  cohort_id     bigint      not null references public.league_cohorts (id),
  student_id    bigint      not null references public.students (telegram_id),
  tier          integer     not null references public.league_tiers (tier),
  is_late_entry boolean     not null default false,
  seed          integer,
  points        integer,
  place         integer,
  movement      text        check (movement in ('promote','demote','inactive_demote','stayed')),
  created_at    timestamptz not null default now(),
  unique (season_id, student_id)
);
create index if not exists idx_league_memberships_cohort
  on public.league_memberships (cohort_id);
create index if not exists idx_league_memberships_student
  on public.league_memberships (student_id);
alter table public.league_memberships disable row level security;

-- --- 5. Журнал переходов -------------------------------------------------------
create table if not exists public.league_movements (
  id          bigint      generated by default as identity primary key,
  season_id   bigint      not null references public.seasons (id),  -- закрытый сезон, породивший переход
  student_id  bigint      not null references public.students (telegram_id),
  from_tier   integer     not null references public.league_tiers (tier),
  to_tier     integer     not null references public.league_tiers (tier),
  kind        text        not null check (kind in ('promote','demote','inactive_demote')),
  created_at  timestamptz not null default now(),
  unique (season_id, student_id)
);
alter table public.league_movements disable row level security;

-- --- 6. Временные сезонные награды (Корона Легенды) ----------------------------
-- Непокупаемая, невечная: активна ровно один следующий сезон (active_season_id).
-- НЕ пишется в shop_items/student_items/student_equipment.
create table if not exists public.league_season_awards (
  id               bigint      generated by default as identity primary key,
  award_code       text        not null,                              -- 'legend_crown'
  student_id       bigint      not null references public.students (telegram_id),
  earned_season_id bigint      not null references public.seasons (id),
  active_season_id bigint      not null references public.seasons (id),
  created_at       timestamptz not null default now(),
  unique (award_code, earned_season_id, student_id)
);
create index if not exists idx_league_awards_active
  on public.league_season_awards (award_code, active_season_id);
alter table public.league_season_awards disable row level security;

-- --- 7. build_season_cohorts — посев когорт стартующего сезона ------------------
-- Для каждой лиги с участниками: 1 когорта при N<=30, иначе ceil(N/30) сбалансированных
-- когорт 15–30 (размеры отличаются максимум на 1), распределение snake-seeding по месту
-- сезона p_seed_season_id (season_results.place). p_seed_season_id = null (bootstrap) →
-- посев по telegram_id. Создаёт только обычные (не late_entry) когорты и memberships с
-- пустыми points/place/movement. Идемпотентна: при существующих memberships сезона выходит.
create or replace function public.build_season_cohorts(
  p_new_season_id  bigint,
  p_seed_season_id bigint default null)
 returns void
 language plpgsql
as $function$
declare
  v_tier   integer;
  v_n      integer;
  v_k      integer;
  v_cohort bigint;
  v_idx    integer;
begin
  -- Уже посеян — не пересобираем (защита от повторного вызова).
  if exists (select 1 from public.league_memberships where season_id = p_new_season_id) then
    return;
  end if;

  for v_tier in 1..7 loop
    select count(*) into v_n
      from public.student_league_state
      where tier = v_tier;

    if v_n = 0 then
      continue;
    end if;

    v_k := case when v_n <= 30 then 1 else ceil(v_n / 30.0)::integer end;

    -- Создаём K когорт и запоминаем их id по индексу.
    for v_idx in 1..v_k loop
      insert into public.league_cohorts (season_id, tier, cohort_index, is_late_entry)
        values (p_new_season_id, v_tier, v_idx, false);
    end loop;

    -- Snake-распределение по посеву; cohort_index в 1..K по змейке, затем подставляем cohort.id.
    insert into public.league_memberships
      (season_id, cohort_id, student_id, tier, is_late_entry, seed)
    select p_new_season_id,
           c.id,
           o.student_id,
           v_tier,
           false,
           o.rn
      from (
        select st.student_id,
               row_number() over (
                 order by sr.place asc nulls last, st.student_id asc) as rn,
               ( (row_number() over (
                    order by sr.place asc nulls last, st.student_id asc) - 1) % (2 * v_k) ) as pos
          from public.student_league_state st
          left join public.season_results sr
            on p_seed_season_id is not null
           and sr.season_id = p_seed_season_id
           and sr.student_id = st.student_id
         where st.tier = v_tier
      ) o
      join public.league_cohorts c
        on c.season_id = p_new_season_id
       and c.tier = v_tier
       and c.is_late_entry = false
       and c.cohort_index = case when o.pos < v_k then o.pos + 1 else 2 * v_k - o.pos end;
  end loop;
end;
$function$;

-- --- 8. ensure_league_membership — ленивое membership для позднего новичка ------
-- Вызывается из award_season_points при первом реальном ненулевом начислении очков.
-- Создаёт state (Бронза) и, если на текущий открытый сезон membership нет, кладёт ученика
-- в late_entry-когорту Бронзы (до 30, при переполнении — новая late_entry-когорта). Не
-- трогает обычные когорты и не двигает уже соревнующихся. Идемпотентна.
create or replace function public.ensure_league_membership(p_student_id bigint)
 returns void
 language plpgsql
as $function$
declare
  v_season   bigint;
  v_cohort   bigint;
  v_count    integer;
  v_next_idx integer;
begin
  select id into v_season
    from public.seasons where end_date is null order by id desc limit 1;
  if v_season is null then
    return;                                  -- нет открытого сезона — нечего наполнять
  end if;

  -- Постоянное состояние (Бронза по умолчанию).
  insert into public.student_league_state (student_id)
    values (p_student_id)
    on conflict (student_id) do nothing;

  -- Уже участвует в текущем сезоне (обычный или late_entry) — выходим.
  if exists (
    select 1 from public.league_memberships
     where season_id = v_season and student_id = p_student_id) then
    return;
  end if;

  -- Ищем незаполненную late_entry-когорту Бронзы (tier 1) этого сезона.
  select c.id, count(m.id) into v_cohort, v_count
    from public.league_cohorts c
    left join public.league_memberships m on m.cohort_id = c.id
   where c.season_id = v_season and c.tier = 1 and c.is_late_entry = true
   group by c.id
   having count(m.id) < 30
   order by c.id
   limit 1;

  if v_cohort is null then
    select coalesce(max(cohort_index), 0) + 1 into v_next_idx
      from public.league_cohorts
     where season_id = v_season and tier = 1 and is_late_entry = true;
    insert into public.league_cohorts (season_id, tier, cohort_index, is_late_entry)
      values (v_season, 1, v_next_idx, true)
      returning id into v_cohort;
  end if;

  insert into public.league_memberships
    (season_id, cohort_id, student_id, tier, is_late_entry)
    values (v_season, v_cohort, p_student_id, 1, true)
    on conflict (season_id, student_id) do nothing;
end;
$function$;

-- --- 9. award_season_points — + наполнение лиги при реальном начислении ---------
-- Единственное добавление относительно 018 — вызов ensure_league_membership после
-- фактического ненулевого начисления. Zero-delta no-op, идемпотентность по event_key,
-- ledger и подсчёт rating сохранены дословно.
create or replace function public.award_season_points(
  p_student_id bigint, p_amount integer, p_reason text, p_event_key text default null)
 returns integer
 language plpgsql
as $function$
declare
  v_season   bigint;
  v_inserted integer;
  v_rating   integer;
begin
  -- Нулевая дельта: ничего не пишем и не начисляем (W11, исправление 1).
  if p_amount = 0 then
    select rating into v_rating from public.students where telegram_id = p_student_id;
    return v_rating;
  end if;

  select id into v_season from public.seasons where end_date is null order by id desc limit 1;

  insert into public.season_points_log (season_id, student_id, amount, reason, event_key)
    values (v_season, p_student_id, p_amount, p_reason, p_event_key)
    on conflict (event_key) where event_key is not null do nothing;
  get diagnostics v_inserted = row_count;

  if v_inserted = 0 and p_event_key is not null then
    select rating into v_rating from public.students where telegram_id = p_student_id;
    return v_rating;
  end if;

  -- Лига: гарантируем membership новичка на текущий сезон (L01). Идемпотентно, обычные
  -- когорты не пересобираются. Не влияет на возвращаемый rating.
  perform public.ensure_league_membership(p_student_id);

  return public.add_season_points(p_student_id, p_amount);
end;
$function$;

-- --- 10. close_league_season — места/переходы/корона закрываемого сезона --------
-- Вызывается из close_season ПОСЛЕ вставки season_results и ДО обнуления rating. Работает
-- только если у закрываемого сезона есть когорты (иначе legacy-сезон — тихо выходит).
-- p_new_season_id — уже открытый следующий сезон (для активации короны и посева когорт).
create or replace function public.close_league_season(
  p_old_season_id bigint,
  p_new_season_id bigint)
 returns void
 language plpgsql
as $function$
declare
  r          record;
  v_active   integer;
  v_promote  integer;
  v_demote   integer;
  v_to       integer;
  v_kind     text;
  v_move     text;
  v_new_inactive  integer;
  v_legend_active integer;
  v_crown    bigint;
begin
  -- Legacy-сезон без когорт (создан до лиг) — лиговое закрытие пропускаем.
  if not exists (select 1 from public.league_cohorts where season_id = p_old_season_id) then
    return;
  end if;

  -- 10a. Внутрикогортное место и points по глобальному season_results.place закрытого сезона.
  --      place считаем по всем участникам когорты; движение ниже — только среди активных.
  for r in
    select m.id           as membership_id,
           m.student_id,
           m.cohort_id,
           m.tier,
           m.is_late_entry,
           coalesce(sr.points, 0) as points,
           row_number() over (
             partition by m.cohort_id
             order by sr.place asc nulls last, m.student_id asc) as place
      from public.league_memberships m
      left join public.season_results sr
        on sr.season_id = p_old_season_id and sr.student_id = m.student_id
     where m.season_id = p_old_season_id
  loop
    update public.league_memberships
       set points = r.points, place = r.place
     where id = r.membership_id;
  end loop;

  -- 10b. Движение по каждому обычному участнику. Активные (points>0) — по адаптивной таблице
  --      среди активных когорты; неактивные — по правилу неактивных сезонов.
  for r in
    select m.id           as membership_id,
           m.student_id,
           m.cohort_id,
           m.tier,
           m.points,
           -- ранг среди активных когорты (1 = лучший), null для неактивных
           case when m.points > 0 then
             row_number() over (
               partition by m.cohort_id, (m.points > 0)
               order by m.place asc)
           end as active_rank
      from public.league_memberships m
     where m.season_id = p_old_season_id
       and m.is_late_entry = false
  loop
    -- Число активных в когорте.
    select count(*) into v_active
      from public.league_memberships
     where cohort_id = r.cohort_id and is_late_entry = false and points > 0;

    -- Адаптивная таблица (SPEC_STAGE3 §4).
    if v_active between 5 and 9 then
      v_promote := 1; v_demote := 1;
    elsif v_active between 10 and 19 then
      v_promote := 3; v_demote := 3;
    elsif v_active between 20 and 30 then
      v_promote := 5; v_demote := 5;
    else
      v_promote := 0; v_demote := 0;              -- 0–4 активных: движения нет
    end if;

    v_to := r.tier;
    v_kind := null;
    v_move := 'stayed';

    if r.points > 0 then
      -- Активный сезон обнуляет счётчик неактивности.
      update public.student_league_state
         set inactive_seasons = 0, updated_at = now()
       where student_id = r.student_id;

      if r.active_rank <= v_promote and r.tier < 7 then
        v_to := r.tier + 1; v_kind := 'promote'; v_move := 'promote';
      elsif r.active_rank > v_active - v_demote and r.tier > 1 then
        v_to := r.tier - 1; v_kind := 'demote'; v_move := 'demote';
      end if;
    else
      -- Полностью неактивный сезон: инкремент счётчика, со 2-го — понижение до Бронзы.
      update public.student_league_state
         set inactive_seasons = inactive_seasons + 1, updated_at = now()
       where student_id = r.student_id
       returning inactive_seasons into v_new_inactive;

      if v_new_inactive >= 2 and r.tier > 1 then
        v_to := r.tier - 1; v_kind := 'inactive_demote'; v_move := 'inactive_demote';
      end if;
    end if;

    -- Фиксируем движение в membership и, при реальном переходе, в журнал + новое состояние.
    update public.league_memberships set movement = v_move where id = r.membership_id;

    if v_kind is not null then
      insert into public.league_movements
        (season_id, student_id, from_tier, to_tier, kind)
        values (p_old_season_id, r.student_id, r.tier, v_to, v_kind)
        on conflict (season_id, student_id) do nothing;
      update public.student_league_state
         set tier = v_to, updated_at = now()
       where student_id = r.student_id;
    end if;
  end loop;

  -- 10c. late_entry: без движения, tier и счётчик неактивности не трогаем (они были активны).
  update public.league_memberships
     set movement = 'stayed'
   where season_id = p_old_season_id and is_late_entry = true;

  -- 10d. Корона Легенды: топ-1 активный Легенды при >=5 активных участниках Легенды.
  select count(*) into v_legend_active
    from public.league_memberships
   where season_id = p_old_season_id and tier = 7 and is_late_entry = false and points > 0;

  if v_legend_active >= 5 then
    select student_id into v_crown
      from public.league_memberships
     where season_id = p_old_season_id and tier = 7 and is_late_entry = false and points > 0
     order by place asc
     limit 1;

    if v_crown is not null then
      insert into public.league_season_awards
        (award_code, student_id, earned_season_id, active_season_id)
        values ('legend_crown', v_crown, p_old_season_id, p_new_season_id)
        on conflict (award_code, earned_season_id, student_id) do nothing;
    end if;
  end if;

  -- 10e. Посев когорт нового сезона по обновлённым лигам и месту закрытого сезона.
  perform public.build_season_cohorts(p_new_season_id, p_old_season_id);
end;
$function$;

-- --- 11. close_season — расширение лигами (без изменения global top-3 / фонда 190) ---
-- Единственные добавления относительно 018: захват id открытого нового сезона и вызов
-- close_league_season между глобальной выплатой и обнулением rating. Порядок гарантирует,
-- что лиговые места считаются по ещё не обнулённому season_results, а короне/посеву доступен
-- уже открытый следующий сезон.
create or replace function public.close_season()
 returns json
 language plpgsql
as $function$
declare
  v_season_id    bigint;
  v_new_season_id bigint;
  v_start_date   date;
  v_start_ts     timestamptz;
  v_today        date := (now() at time zone 'Europe/Moscow')::date;
  v_archived     integer;
  v_awarded      integer := 0;
  v_reward       integer;
  r record;
begin
  select id, start_date into v_season_id, v_start_date
    from seasons
    where end_date is null
    order by id desc
    limit 1
    for update;

  if v_season_id is null then
    raise exception 'Нет открытого сезона';
  end if;

  if v_start_date >= v_today then
    raise exception 'Сезон №% открыт сегодня — закрывать можно не раньше следующего дня', v_season_id;
  end if;

  v_start_ts := (v_start_date::timestamp) at time zone 'Europe/Moscow';

  perform 1 from students for update;

  insert into season_results (season_id, student_id, points, place)
  select v_season_id, s.telegram_id, s.rating,
         row_number() over (
           order by s.rating desc,
                    coalesce(pen.cnt, 0) asc,
                    pts.last_scored asc nulls last,
                    s.telegram_id asc)
    from students s
    left join (
      select student_id, count(*) as cnt
        from balance_history
       where reason like 'penalty:%' and created_at >= v_start_ts
       group by student_id) pen on pen.student_id = s.telegram_id
    left join (
      select student_id, max(created_at) as last_scored
        from season_points_log
       where season_id = v_season_id and amount <> 0
       group by student_id) pts on pts.student_id = s.telegram_id;
  get diagnostics v_archived = row_count;

  for r in
    select student_id, place
      from season_results
      where season_id = v_season_id and place <= 3 and points > 0
      order by place
  loop
    v_reward := case r.place when 1 then 100 when 2 then 60 else 30 end;
    perform add_huikons(r.student_id, v_reward, 'season_place_' || r.place);
    v_awarded := v_awarded + 1;
  end loop;

  -- Открываем следующий сезон заранее, чтобы короне и посеву когорт было куда встать.
  update seasons set end_date = v_today where id = v_season_id;
  insert into seasons (start_date) values (v_today) returning id into v_new_season_id;

  -- Лиги: места/переходы/корона закрытого сезона + посев когорт нового (L01). Использует
  -- ещё не обнулённый season_results; для legacy-сезона без когорт — тихий no-op.
  perform public.close_league_season(v_season_id, v_new_season_id);

  update students set rating = 0 where rating <> 0;

  return json_build_object(
    'season_id', v_season_id,
    'archived', v_archived,
    'awarded', v_awarded
  );
end;
$function$;

-- --- 12. preview_league_close — read-only проекция закрытия текущего сезона -----
-- Для L02 (учитель): что произойдёт, если закрыть сейчас. Live-данные (rating/штрафы/ledger),
-- тот же tie-break, что и close_season. Ничего не пишет. Возвращает по одному ряду на
-- участника обычной когорты открытого сезона.
create or replace function public.preview_league_close()
 returns table(
   student_id      bigint,
   tier            integer,
   tier_name       text,
   cohort_index    integer,
   points          integer,
   place           integer,
   active_in_cohort integer,
   projected_movement text,
   projected_tier  integer)
 language sql
 stable
as $function$
  with season as (
    select id from public.seasons where end_date is null order by id desc limit 1
  ),
  live as (
    -- живой глобальный порядок сезона — тот же tie-break, что в close_season
    select s.telegram_id as student_id,
           s.rating       as points,
           row_number() over (
             order by s.rating desc,
                      coalesce(pen.cnt, 0) asc,
                      pts.last_scored asc nulls last,
                      s.telegram_id asc) as global_place
      from public.students s
      left join (
        select student_id, count(*) as cnt
          from public.balance_history
         where reason like 'penalty:%'
           and created_at >= (
             (select start_date from public.seasons where end_date is null order by id desc limit 1)::timestamp
             at time zone 'Europe/Moscow')
         group by student_id) pen on pen.student_id = s.telegram_id
      left join (
        select l.student_id, max(l.created_at) as last_scored
          from public.season_points_log l
         where l.season_id = (select id from season) and l.amount <> 0
         group by l.student_id) pts on pts.student_id = s.telegram_id
  ),
  ranked as (
    select m.student_id,
           m.tier,
           c.cohort_index,
           m.cohort_id,
           m.is_late_entry,
           coalesce(lv.points, 0) as points,
           row_number() over (
             partition by m.cohort_id
             order by lv.global_place asc nulls last, m.student_id asc) as place
      from public.league_memberships m
      join season se on se.id = m.season_id
      join public.league_cohorts c on c.id = m.cohort_id
      left join live lv on lv.student_id = m.student_id
     where m.is_late_entry = false
  ),
  active_ranked as (
    select r.*,
           count(*) filter (where r.points > 0) over (partition by r.cohort_id) as active_in_cohort,
           case when r.points > 0 then
             row_number() over (
               partition by r.cohort_id, (r.points > 0) order by r.place asc)
           end as active_rank
      from ranked r
  ),
  moved as (
    select ar.*,
           case when ar.active_in_cohort between 5 and 9 then 1
                when ar.active_in_cohort between 10 and 19 then 3
                when ar.active_in_cohort between 20 and 30 then 5
                else 0 end as promote_n,
           case when ar.active_in_cohort between 5 and 9 then 1
                when ar.active_in_cohort between 10 and 19 then 3
                when ar.active_in_cohort between 20 and 30 then 5
                else 0 end as demote_n
      from active_ranked ar
  ),
  projected as (
    select m.*,
           case
             when m.points > 0 and m.active_rank <= m.promote_n and m.tier < 7 then 'promote'
             when m.points > 0 and m.active_rank > m.active_in_cohort - m.demote_n and m.tier > 1 then 'demote'
             else 'stayed'
           end as projected_movement
      from moved m
  )
  select p.student_id,
         p.tier,
         t.name as tier_name,
         p.cohort_index,
         p.points,
         p.place::integer,
         p.active_in_cohort::integer,
         p.projected_movement,
         case p.projected_movement
           when 'promote' then p.tier + 1
           when 'demote'  then p.tier - 1
           else p.tier
         end as projected_tier
    from projected p
    join public.league_tiers t on t.tier = p.tier
$function$;

-- --- 13. get_student_league_snapshot — текущая лига/место/следующая ступень -----
-- Для L03 (ученик): постоянное состояние + live-место в своей когорте открытого сезона +
-- активная корона. Место считается тем же tie-break; ничего не пишет.
create or replace function public.get_student_league_snapshot(p_student_id bigint)
 returns json
 language plpgsql
 stable
as $function$
declare
  v_season      bigint;
  v_tier        integer;
  v_inactive    integer;
  v_cohort      bigint;
  v_late        boolean;
  v_place       integer;
  v_cohort_size integer;
  v_active      integer;
  v_has_crown   boolean := false;
begin
  select id into v_season from public.seasons where end_date is null order by id desc limit 1;

  select tier, inactive_seasons into v_tier, v_inactive
    from public.student_league_state where student_id = p_student_id;

  if v_tier is null then
    -- ученик ещё не в лигах (не начислял очков) — показываем Бронзу как стартовую ступень
    v_tier := 1;
    v_inactive := 0;
  end if;

  select m.cohort_id, m.is_late_entry into v_cohort, v_late
    from public.league_memberships m
   where m.season_id = v_season and m.student_id = p_student_id;

  if v_cohort is not null then
    select place, size, active into v_place, v_cohort_size, v_active from (
      select m.student_id,
             row_number() over (
               order by s.rating desc, s.telegram_id asc) as place,
             count(*) over () as size,
             count(*) filter (where s.rating > 0) over () as active
        from public.league_memberships m
        join public.students s on s.telegram_id = m.student_id
       where m.cohort_id = v_cohort
    ) q where q.student_id = p_student_id;
  end if;

  select exists (
    select 1 from public.league_season_awards
     where award_code = 'legend_crown'
       and student_id = p_student_id
       and active_season_id = v_season) into v_has_crown;

  return json_build_object(
    'season_id',        v_season,
    'tier',             v_tier,
    'tier_name',        (select name from public.league_tiers where tier = v_tier),
    'next_tier',        case when v_tier < 7 then v_tier + 1 end,
    'next_tier_name',   (select name from public.league_tiers where tier = v_tier + 1),
    'inactive_seasons', v_inactive,
    'is_late_entry',    coalesce(v_late, false),
    'in_season',        v_cohort is not null,
    'place',            v_place,
    'cohort_size',      v_cohort_size,
    'active_in_cohort', v_active,
    'has_crown',        v_has_crown
  );
end;
$function$;

-- --- 14. get_student_rank_title — производное трудовое звание из P01A -----------
-- Звание не понижается и вычисляется из get_student_task_totals (solved_tasks + active_days):
-- берётся высшая ступень, где выполнены ОБА порога. Баллы пробников не участвуют. Флаг
-- has_unknown_legacy сигналит UI, что счётчик задач ведётся с запуска (legacy task_count null).
create or replace function public.get_student_rank_title(p_student_id bigint)
 returns json
 language plpgsql
 stable
as $function$
declare
  v_tasks   bigint;
  v_days    bigint;
  v_unknown bigint;
  v_name    text;
  v_level   integer;
begin
  select solved_tasks, active_days, unknown_approved_assignments
    into v_tasks, v_days, v_unknown
    from public.get_student_task_totals(p_student_id, null, null);

  v_tasks := coalesce(v_tasks, 0);
  v_days  := coalesce(v_days, 0);

  -- Пороги SPEC_STAGE3 §8 (оба условия обязательны), от высшего к низшему.
  if    v_tasks >= 5000 and v_days >= 250 then v_name := 'Легенда ЕГЭ'; v_level := 7;
  elsif v_tasks >= 3500 and v_days >= 190 then v_name := 'Профессор';   v_level := 6;
  elsif v_tasks >= 2000 and v_days >= 130 then v_name := 'Академик';    v_level := 5;
  elsif v_tasks >= 1000 and v_days >= 80  then v_name := 'Магистр';     v_level := 4;
  elsif v_tasks >= 400  and v_days >= 40  then v_name := 'Решатель';    v_level := 3;
  elsif v_tasks >= 100  and v_days >= 15  then v_name := 'Ученик';      v_level := 2;
  else                                         v_name := 'Новичок';     v_level := 1;
  end if;

  return json_build_object(
    'title',             v_name,
    'level',             v_level,
    'solved_tasks',      v_tasks,
    'active_days',       v_days,
    'has_unknown_legacy', coalesce(v_unknown, 0) > 0
  );
end;
$function$;

-- --- 15. Bootstrap первого лигового сезона -------------------------------------
-- Все существующие ученики → Бронза (state), затем посев когорт текущего открытого сезона
-- по telegram_id (без калибровки по историческому rating). Идемпотентно: state с
-- on conflict do nothing, build_season_cohorts выходит при уже существующих memberships.
do $bootstrap$
declare
  v_season bigint;
begin
  insert into public.student_league_state (student_id)
    select telegram_id from public.students
    on conflict (student_id) do nothing;

  select id into v_season from public.seasons where end_date is null order by id desc limit 1;
  if v_season is not null then
    perform public.build_season_cohorts(v_season, null);   -- bootstrap: посев по telegram_id
  end if;
end;
$bootstrap$;

-- =============================================================================
-- ROLLBACK (если потребуется откатить L01 на dev, выполнять целиком):
--   -- вернуть функции к версии 018:
--   --   close_season, award_season_points — переприменить их тела из
--   --   018_stage25_cutover_hardening.sql (разделы 2 и 5);
--   drop function if exists public.get_student_rank_title(bigint);
--   drop function if exists public.get_student_league_snapshot(bigint);
--   drop function if exists public.preview_league_close();
--   drop function if exists public.close_league_season(bigint, bigint);
--   drop function if exists public.ensure_league_membership(bigint);
--   drop function if exists public.build_season_cohorts(bigint, bigint);
--   drop table if exists public.league_season_awards;
--   drop table if exists public.league_movements;
--   drop table if exists public.league_memberships;
--   drop table if exists public.league_cohorts;
--   drop table if exists public.student_league_state;
--   drop table if exists public.league_tiers;
-- Прод не затронут — миграция применяется только на dev-Supabase форка.
-- =============================================================================
