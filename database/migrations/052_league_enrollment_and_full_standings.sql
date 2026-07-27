-- =============================================================================
-- 052_league_enrollment_and_full_standings.sql — стабилизация: вступление в лигу по первому
-- начислению рейтинга + полный список участников лиги.
-- (Bot 2.0, стабилизационный этап; правки к 019 L01/L02/L03 и 043)
--
-- ПРОБЛЕМА 1 — в лигу попадали просто по факту регистрации.
--   Bootstrap миграции 019 (раздел 15) залил в student_league_state ВСЕХ учеников, а
--   build_season_cohorts на старте каждого сезона сеет когорты из student_league_state
--   целиком — включая пустые аккаунты с 0 очков. ensure_league_membership («ленивое»
--   вступление новичка) существовал и вызывался из award_season_points, но реального
--   гейта «пока не заработал — не участвуешь» не было. Плюс legacy-ветка приёмки ДЗ
--   (settle_legacy_approval, миграция 039) начисляет очки прямым add_season_points и
--   лиги вообще не касалась.
--   РЕШЕНИЕ: разделены ПЛАН участия и ФАКТ участия.
--     * build_season_cohorts продолжает работать как есть — он раскладывает учеников по
--       когортам (snake-seeding по месту прошлого сезона) и создаёт memberships-ЗАГОТОВКИ
--       с activated_at = null. Заготовка невидима: ни в списке лиги, ни в снимке, ни в
--       превью учителя. Она нужна, чтобы сохранить существующую механику лестницы —
--       посев, размеры когорт и счётчик неактивных сезонов (2 пустых сезона подряд →
--       понижение до Бронзы) считает close_league_season по всем memberships сезона, как
--       и раньше. close_league_season этой миграцией НЕ меняется.
--     * ФАКТ участия ставит первое реальное положительное начисление рейтинга:
--       add_season_points (единственная точка, где rating увеличивается) вызывает
--       ensure_league_membership, а тот проставляет activated_at (или создаёт late_entry
--       membership новичку, у которого заготовки нет). Идемпотентно: повтор, retry и
--       перезагрузка не создают второго участия — участие уникально по
--       (season_id, student_id), а активация делается `where activated_at is null`.
--     * Атомарность: enrollment происходит внутри той же транзакции, что и само
--       начисление (add_season_points вызывается из record_approved_assignment /
--       settle_legacy_approval / award_season_points, все — внутри одной серверной
--       транзакции gateway'а). Рейтинг не может начислиться без участия и наоборот.
--     * Снижение рейтинга до нуля участие НЕ снимает (activated_at не сбрасывается) —
--       отдельного правила выхода из лиги в проекте нет.
--
-- ПРОБЛЕМА 2 — на экране лиги была видна только часть участников. Три независимые причины:
--     а) preview_league_close (019) содержит `where m.is_late_entry = false` — ученики,
--        вступившие по ходу сезона, вообще не попадали в выдачу, а клиент строил список
--        лиги именно из неё;
--     б) сам late_entry-ученик получал ранний выход без списка (student-progress.js);
--     в) имена и косметика участников тянулись прямыми select из students /
--        student_equipment, а после T10-08A/08B (миграции 042/043) на этих таблицах RLS
--        «своя строка» — ученику возвращалась ровно одна строка, его собственная.
--   РЕШЕНИЕ: новый definer-RPC get_student_league_standings_self отдаёт ВСЕХ активированных
--   участников своей лиги текущего сезона (обе когорты — обычную и late_entry — как
--   отдельные группы, места считаются внутри когорты), вместе с именами и косметикой.
--   Без LIMIT и без клиентской фильтрации.
--
-- Миграция аддитивна и идемпотентна. Ничего не удаляется.
-- =============================================================================

begin;

-- --- 1. Факт участия: league_memberships.activated_at -----------------------------------------
alter table public.league_memberships add column if not exists activated_at timestamptz;

create index if not exists idx_league_memberships_activated
  on public.league_memberships (season_id, activated_at);

comment on column public.league_memberships.activated_at is
  'Момент фактического вступления в лигу = первое положительное начисление рейтинга в этом '
  'сезоне. NULL = заготовка посева (build_season_cohorts): в списках/снимке/превью не '
  'показывается, но участвует в бухгалтерии неактивных сезонов close_league_season.';

-- --- 2. ensure_league_membership — активация участия по факту начисления -----------------------
-- Было (019): создать late_entry membership, если его нет. Стало: активировать заготовку
-- посева, если она есть; иначе создать late_entry membership уже активированным.
create or replace function public.ensure_league_membership(p_student_id bigint)
 returns void
 language plpgsql
as $function$
declare
  v_season   bigint;
  v_cohort   bigint;
  v_count    integer;
  v_next_idx integer;
  v_exists   boolean;
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

  -- Участие на этот сезон уже есть: активируем заготовку посева (или ничего не делаем,
  -- если ученик уже соревнуется). Никакой смены лиги/когорты при каждом новом ДЗ.
  v_exists := exists (
    select 1 from public.league_memberships
     where season_id = v_season and student_id = p_student_id);

  if v_exists then
    update public.league_memberships
       set activated_at = now()
     where season_id = v_season
       and student_id = p_student_id
       and activated_at is null;
    return;
  end if;

  -- Новичок без заготовки: отдельная late_entry-когорта Бронзы (до 30, при переполнении —
  -- следующая). Обычные когорты не трогаем и уже соревнующихся не двигаем (SPEC_STAGE3 §3).
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
      on conflict (season_id, tier, cohort_index, is_late_entry) do nothing
      returning id into v_cohort;

    -- Гонка двух первых начислений: когорту успел создать конкурент — берём её.
    if v_cohort is null then
      select id into v_cohort
        from public.league_cohorts
       where season_id = v_season and tier = 1 and is_late_entry = true
         and cohort_index = v_next_idx;
    end if;
  end if;

  -- on conflict — защита от гонки двух первых начислений: второй не создаёт второе участие,
  -- а лишь дозаполняет activated_at (в DO UPDATE к текущей строке обращаемся по имени таблицы).
  insert into public.league_memberships as lm
    (season_id, cohort_id, student_id, tier, is_late_entry, activated_at)
    values (v_season, v_cohort, p_student_id, 1, true, now())
    on conflict (season_id, student_id) do update
      set activated_at = coalesce(lm.activated_at, now());
end;
$function$;

-- --- 3. add_season_points — единственная точка роста rating, здесь же и вступление в лигу ------
-- Раньше вступление висело только на award_season_points, из-за чего legacy-приёмка ДЗ
-- (settle_legacy_approval → add_season_points) начисляла очки, не заводя участия.
-- Теперь любое фактическое ПОЛОЖИТЕЛЬНОЕ начисление гарантирует участие в текущем сезоне.
-- Отрицательные корректировки и нулевые дельты участия не создают и не снимают.
create or replace function public.add_season_points(p_student_id bigint, p_amount integer)
 returns integer
 language plpgsql
as $function$
declare
  v_new integer;
begin
  update public.students
    set rating = greatest(0, rating + p_amount)
    where telegram_id = p_student_id
    returning rating into v_new;

  if v_new is null then
    raise exception 'Student % not found', p_student_id;
  end if;

  -- Та же транзакция, что и начисление: рейтинг не может вырасти без участия в лиге.
  if p_amount > 0 then
    perform public.ensure_league_membership(p_student_id);
  end if;

  return v_new;
end;
$function$;

-- --- 4. get_student_league_snapshot — место/размер когорты по ФАКТИЧЕСКИМ участникам ----------
-- Изменения против 019: in_season/place/cohort_size/active_in_cohort считаются только по
-- activated_at is not null; добавлены cohort_index и season_title (UI показывает название
-- сезона из планирования). Остальные ключи ответа сохранены — клиент не ломается.
create or replace function public.get_student_league_snapshot(p_student_id bigint)
 returns json
 language plpgsql
 stable
as $function$
declare
  v_season      bigint;
  v_season_title text;
  v_tier        integer;
  v_inactive    integer;
  v_cohort      bigint;
  v_cohort_index integer;
  v_late        boolean;
  v_place       integer;
  v_cohort_size integer;
  v_active      integer;
  v_has_crown   boolean := false;
begin
  select id, title into v_season, v_season_title
    from public.seasons where end_date is null order by id desc limit 1;

  select tier, inactive_seasons into v_tier, v_inactive
    from public.student_league_state where student_id = p_student_id;

  if v_tier is null then
    -- ученик ещё не в лигах (не начислял очков) — показываем Бронзу как стартовую ступень
    v_tier := 1;
    v_inactive := 0;
  end if;

  -- Только фактическое участие: заготовка посева (activated_at is null) сезоном не считается.
  select m.cohort_id, m.is_late_entry, c.cohort_index
    into v_cohort, v_late, v_cohort_index
    from public.league_memberships m
    join public.league_cohorts c on c.id = m.cohort_id
   where m.season_id = v_season
     and m.student_id = p_student_id
     and m.activated_at is not null;

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
         and m.activated_at is not null
    ) q where q.student_id = p_student_id;
  end if;

  select exists (
    select 1 from public.league_season_awards
     where award_code = 'legend_crown'
       and student_id = p_student_id
       and active_season_id = v_season) into v_has_crown;

  return json_build_object(
    'season_id',        v_season,
    'season_title',     v_season_title,
    'tier',             v_tier,
    'tier_name',        (select name from public.league_tiers where tier = v_tier),
    'next_tier',        case when v_tier < 7 then v_tier + 1 end,
    'next_tier_name',   (select name from public.league_tiers where tier = v_tier + 1),
    'inactive_seasons', v_inactive,
    'is_late_entry',    coalesce(v_late, false),
    'in_season',        v_cohort is not null,
    'cohort_index',     v_cohort_index,
    'place',            v_place,
    'cohort_size',      v_cohort_size,
    'active_in_cohort', v_active,
    'has_crown',        v_has_crown
  );
end;
$function$;

-- --- 5. get_student_league_standings_self — ПОЛНЫЙ список своей лиги --------------------------
-- Все фактические участники своей лиги (tier) текущего сезона: и обычная когорта, и
-- late_entry. Места считаются ВНУТРИ когорты тем же tie-break, что close_season/
-- preview_league_close (очки → меньше штрафов в сезоне → раньше набрал → telegram_id), поэтому
-- когорты не смешиваются. Имена и косметика приезжают тут же (student_public_cosmetics,
-- миграция 051) — прямые select их не отдают из-за RLS. Никакого LIMIT: сколько участников
-- есть, столько и вернётся, текущий ученик присутствует всегда (иначе выдача пустая и клиент
-- показывает «вы ещё не в сезоне»).
create or replace function public.get_student_league_standings_self()
 returns table(
   student_id         bigint,
   name               text,
   tier               integer,
   tier_name          text,
   cohort_index       integer,
   is_late_entry      boolean,
   place              integer,
   points             integer,
   projected_movement text,
   active_in_cohort   integer,
   cohort_size        integer,
   is_me              boolean,
   equipment          jsonb)
 language plpgsql
 security definer
 set search_path = public, pg_temp
as $function$
#variable_conflict use_column
declare
  v_tid        bigint;
  v_season     bigint;
  v_my_tier    integer;
  v_season_start timestamptz;
begin
  if private.current_app_role() is distinct from 'student' then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  v_tid := private.current_telegram_id();
  if v_tid is null or v_tid <= 0 then
    raise exception 'no student identity' using errcode = '42501';
  end if;

  v_season := public.current_season_id();
  if v_season is null then
    return;
  end if;

  select (s.start_date::timestamp) at time zone 'Europe/Moscow'
    into v_season_start
    from public.seasons s where s.id = v_season;

  select m.tier into v_my_tier
    from public.league_memberships m
   where m.season_id = v_season
     and m.student_id = v_tid
     and m.activated_at is not null;
  if v_my_tier is null then
    return;                                   -- ещё не вступил — список пуст по определению
  end if;

  return query
  with live as (
    select s.telegram_id as sid,
           coalesce(s.rating, 0) as pts,
           row_number() over (
             order by s.rating desc,
                      coalesce(pen.cnt, 0) asc,
                      lg.last_scored asc nulls last,
                      s.telegram_id asc) as global_place
      from public.students s
      left join (
        select bh.student_id, count(*) as cnt
          from public.balance_history bh
         where bh.reason like 'penalty:%'
           and bh.created_at >= v_season_start
         group by bh.student_id) pen on pen.student_id = s.telegram_id
      left join (
        select l.student_id, max(l.created_at) as last_scored
          from public.season_points_log l
         where l.season_id = v_season and l.amount <> 0
         group by l.student_id) lg on lg.student_id = s.telegram_id
  ),
  members as (
    select m.student_id as sid,
           m.cohort_id  as cid,
           m.tier       as mtier,
           m.is_late_entry as late,
           c.cohort_index  as cidx,
           coalesce(lv.pts, 0) as pts,
           lv.global_place    as gplace
      from public.league_memberships m
      join public.league_cohorts c on c.id = m.cohort_id
      left join live lv on lv.sid = m.student_id
     where m.season_id = v_season
       and m.tier = v_my_tier
       and m.activated_at is not null
  ),
  ranked as (
    select mb.*,
           row_number() over (partition by mb.cid
                              order by mb.gplace asc nulls last, mb.sid asc) as rplace,
           count(*) over (partition by mb.cid) as csize,
           count(*) filter (where mb.pts > 0) over (partition by mb.cid) as cactive
      from members mb
  ),
  moved as (
    select rk.*,
           case when rk.pts > 0 then
             row_number() over (partition by rk.cid, (rk.pts > 0) order by rk.rplace asc)
           end as arank,
           case when rk.cactive between 5 and 9   then 1
                when rk.cactive between 10 and 19 then 3
                when rk.cactive between 20 and 30 then 5
                else 0 end as move_n
      from ranked rk
  )
  select mv.sid,
         coalesce(st.name, ''),
         mv.mtier,
         lt.name,
         mv.cidx,
         mv.late,
         mv.rplace::integer,
         mv.pts,
         case
           when mv.late then 'stayed'
           when mv.pts > 0 and mv.arank <= mv.move_n and mv.mtier < 7 then 'promote'
           when mv.pts > 0 and mv.arank > mv.cactive - mv.move_n and mv.mtier > 1 then 'demote'
           else 'stayed'
         end,
         mv.cactive::integer,
         mv.csize::integer,
         (mv.sid = v_tid),
         public.student_public_cosmetics(mv.sid)
    from moved mv
    join public.students st on st.telegram_id = mv.sid
    join public.league_tiers lt on lt.tier = mv.mtier
   order by mv.late asc, mv.cidx asc, mv.rplace asc;
end;
$function$;

revoke all on function public.get_student_league_standings_self() from public, anon;
grant execute on function public.get_student_league_standings_self() to authenticated;

-- --- 6. preview_league_close — только фактические участники ------------------------------------
-- Тело 019 сохранено дословно, добавлено единственное условие m.activated_at is not null:
-- заготовки посева, которые ещё никто не активировал, не должны попадать в учительское
-- превью переходов (они и раньше проецировались как 'stayed' с 0 очками — модель переходов
-- не меняется, из выдачи уходит только шум).
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
       and m.activated_at is not null
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

revoke all on function public.preview_league_close() from public, anon, authenticated;

-- --- 7. admin_list_seasons_self — участники = только фактические ------------------------------
-- Переопределение версии 051 (там колонки activated_at ещё не существовало).
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
#variable_conflict use_column
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
         (select count(*)::integer from public.league_memberships m
           where m.season_id = s.id and m.activated_at is not null) as participants,
         (select count(*)::integer from public.season_results r where r.season_id = s.id) as archived
    from public.seasons s
   order by s.id desc;
end;
$function$;

revoke all on function public.admin_list_seasons_self() from public, anon;
grant execute on function public.admin_list_seasons_self() to authenticated;

-- --- 8. Backfill существующих данных ---------------------------------------------------------

-- 8a. ЗАКРЫТЫЕ сезоны: история сохраняется как есть — все memberships считаются
--     фактическими (иначе прошлые лиговые итоги внезапно «опустели» бы).
update public.league_memberships m
   set activated_at = m.created_at
  from public.seasons s
 where s.id = m.season_id
   and s.status <> 'active'
   and m.activated_at is null;

-- 8b. ТЕКУЩИЙ сезон: фактическими считаются те, кто реально набирал очки в этом сезоне
--     (season_points_log) ЛИБО имеет положительный сезонный рейтинг сейчас. Момент
--     вступления берём из журнала, если он там есть — не выдумываем. Остальные (пустые
--     аккаунты, залитые bootstrap'ом 019) остаются заготовками и из лиг исчезают.
update public.league_memberships m
   set activated_at = coalesce(
         (select min(l.created_at) from public.season_points_log l
           where l.season_id = m.season_id and l.student_id = m.student_id and l.amount > 0),
         m.created_at)
  from public.seasons s
 where s.id = m.season_id
   and s.status = 'active'
   and m.activated_at is null
   and (
     exists (select 1 from public.season_points_log l
              where l.season_id = m.season_id and l.student_id = m.student_id and l.amount > 0)
     or coalesce((select st.rating from public.students st
                   where st.telegram_id = m.student_id), 0) > 0
   );

-- 8c. Ученики с положительным сезонным рейтингом, у которых участия нет вовсе — добавляем
--     (задача 4, п.9). Нулевые не добавляются: ни здесь, ни автоматически где-либо ещё.
do $backfill$
declare
  v_season bigint;
  r        record;
begin
  v_season := public.current_season_id();
  if v_season is null then
    return;
  end if;

  for r in
    select st.telegram_id
      from public.students st
     where coalesce(st.rating, 0) > 0
       and not exists (
         select 1 from public.league_memberships m
          where m.season_id = v_season and m.student_id = st.telegram_id)
     order by st.telegram_id
  loop
    perform public.ensure_league_membership(r.telegram_id);
  end loop;
end;
$backfill$;

commit;

-- =============================================================================
-- ROLLBACK (dev-форк; исторические данные не затрагиваются):
--   begin;
--   -- вернуть тела из 019_leagues.sql: ensure_league_membership (раздел 8),
--   -- get_student_league_snapshot (раздел 13), preview_league_close (раздел 12);
--   -- add_season_points — из 005_gamification_core.sql;
--   -- admin_list_seasons_self — из 051_lifetime_rating_and_scheduled_seasons.sql (раздел 8).
--   drop function if exists public.get_student_league_standings_self();
--   drop index if exists public.idx_league_memberships_activated;
--   alter table public.league_memberships drop column if exists activated_at;
--   commit;
-- =============================================================================
