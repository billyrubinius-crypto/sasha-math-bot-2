-- =============================================================================
-- 017_weekly_economy_cutover.sql — экономический cutover на недельную модель
-- (Bot 2.0, Stage 2.5, карточка W09; ECONOMY_V2.md полностью; SPEC_STAGE2_5.md §§6.3-8, 12-13)
--
-- Зачем: включить серверную часть недельной экономики — выплату недельной награды,
-- недельные достижения, идемпотентный per-approval поток (season points + first_step +
-- clean_10), season-ledger и детерминированный tie-break сезона — так, чтобы старая
-- (календарный стрик) и новая (недельная) модели НИКОГДА не платили за одну и ту же неделю.
--
-- --- РЕШЕНИЯ ПОЛЬЗОВАТЕЛЯ (2026-07-16), зафиксированы здесь по требованию карточки -----
--
--   1. «ЗАРЯДИТЬ СЕЙЧАС, ВЫСТРЕЛИТЬ С W10». Старый reward-path целиком клиентский
--      (teacher.html: processStreak/grantAchievement/awardApprovalBonus) и идёт через
--      generic add_huikons/add_season_points — серверная миграция не может его погасить,
--      не сломав тот же generic-путь новой модели. Поэтому 017 строит всё в СПЯЩЕМ виде:
--      economy_config.cutover_at = NULL и Supabase Cron НЕ включается. Пока cutover_at пуст,
--      finalize_student_week считает reward_amount, но НЕ платит; per-approval RPC создана,
--      но её ещё никто не зовёт. Фактический «выстрел» — UPDATE cutover_at = <понедельник> +
--      cron.schedule(...) — выполняется вручную ОДНОВРЕМЕННО с деплоем клиента W10 (скрипт
--      firing/rollback приложен к карточке). Граница проходит по понедельнику: недельная
--      награда платится только за недели с week_start >= неделя(cutover_at); недели до
--      cutover оплачены старым клиентом. Так окно двойных выплат исключено по построению.
--
--   2. НОВЫЙ КОД 'perfect_month_weekly' для достижения «Идеальный месяц» (4 недели 7/7 без
--      щитов). Legacy 'perfect_month' (все ежедневки календарного месяца) конфликтует по
--      коду и остаётся у владельцев нетронутым; новая выдача идёт под отдельным кодом
--      (ECONOMY §8, §10.1). Никаких коллизий выдачи.
--
--   3. PER-APPROVAL — СЕРВЕРНАЯ RPC. first_step и clean_10 оцениваются в момент приёма
--      работы, а не при финализации недели. 017 создаёт идемпотентную RPC
--      record_approved_assignment(assignment): season points 10/40/30, first_step, clean_10.
--      W10 будет звать её из teacher.html при приёме — достижения НЕ откладываются до
--      финализации и НЕ выдаются напрямую клиентом.
--
--   4. ПОЛНЫЙ season-ledger + tie-break 190. Добавляется событийный season_points_log;
--      close_season переписан на детерминированный tie-break (rating desc → меньше штрафов →
--      раньше набрал очки → telegram_id) с фиксированным фондом 190 (100/60/30, по одному
--      ученику на место). Старый rank()-фонд мог превышать 190 при массовой ничьей.
--
-- ИЗВЕСТНЫЙ ПРЕДЕЛ ЛЕДЖЕРА. Season points пробников (миграция 016, P02A — заморожена, не
-- трогаем) начисляются напрямую через add_season_points и в season_points_log НЕ попадают.
-- Поэтому вторичный tie-break «раньше набрал очки» для ученика, у которого очки только от
-- пробников, деградирует к финальному ключу telegram_id. Первичный tie-break «меньше
-- штрафов» (из balance_history) полон. Полное покрытие леджером — отдельная будущая карточка.
--
-- ГРАНИЦЫ. Полная переоценка постоянной/ротационной витрины и 4-недельные коллекции НЕ
-- включаются (ECONOMY §8, §12: только вместе с квестовым доходом Stage 4). Цены остальных
-- товаров не меняются; щит уже 90/лимит 7 (миграция 012). Купленные предметы, титулы и
-- реальные completed counts не трогаются. P3 не затрагивается.
--
-- Повторный прогон безопасен (if not exists / or replace). RLS у новых таблиц выключен (T10).
-- =============================================================================

-- --- 1. Флаг cutover: economy_config (singleton) ------------------------------
-- Одна строка (id=true). cutover_at = NULL → недельная экономика спит; момент времени →
-- активна для недель, начинающихся не раньше понедельника этой даты (решение 1).
create table if not exists public.economy_config (
  id         boolean      primary key default true check (id),
  cutover_at timestamptz,
  updated_at timestamptz  not null default now()
);
insert into public.economy_config (id, cutover_at) values (true, null)
  on conflict (id) do nothing;
alter table public.economy_config disable row level security;

-- Активна ли недельная выплата/достижения для недели p_week_start (граница — понедельник).
create or replace function public.weekly_economy_active(p_week_start date)
 returns boolean
 language sql
 stable
as $function$
  select v.cutover_at is not null
     and p_week_start >= public.week_start_of((v.cutover_at at time zone 'Europe/Moscow')::date)
  from (select cutover_at from public.economy_config where id) v;
$function$;

-- --- 2. Season-ledger: событийный журнал очков сезона + идемпотентная выдача -----
-- 005 сознательно не завёл журнал очков (только students.rating). Для детерминированного
-- tie-break сезона (кто раньше набрал очки) нужен именно событийный лог. event_key —
-- ключ идемпотентности (например, 'season_approve_<assignment_id>'): один и тот же приём
-- не начисляет очки дважды даже при повторном вызове/двойном клике.
create table if not exists public.season_points_log (
  id         uuid         primary key default gen_random_uuid(),
  season_id  bigint       references public.seasons (id),
  student_id bigint       not null references public.students (telegram_id),
  amount     integer      not null,
  reason     text         not null,
  event_key  text,
  created_at timestamptz  not null default now()
);
create unique index if not exists uq_season_points_event
  on public.season_points_log (event_key) where event_key is not null;
create index if not exists idx_season_points_student
  on public.season_points_log (season_id, student_id);
alter table public.season_points_log disable row level security;

-- award_season_points — начислить очки сезона, записав событие в ledger. При заданном
-- event_key повторный вызов не начисляет повторно (страховка от retry/двойного клика).
-- Не заменяет add_season_points (005): та остаётся низкоуровневым атомарным +N к rating,
-- эта — обёртка «начисление + журнал» для нового недельного потока.
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
  select id into v_season from public.seasons where end_date is null order by id desc limit 1;

  insert into public.season_points_log (season_id, student_id, amount, reason, event_key)
    values (v_season, p_student_id, p_amount, p_reason, p_event_key)
    on conflict (event_key) where event_key is not null do nothing;
  get diagnostics v_inserted = row_count;

  -- Событие уже было (тот же event_key) — очки не начисляем повторно, возвращаем текущий rating.
  if v_inserted = 0 and p_event_key is not null then
    select rating into v_rating from public.students where telegram_id = p_student_id;
    return v_rating;
  end if;

  return public.add_season_points(p_student_id, p_amount);
end;
$function$;

-- --- 3. Идемпотентная выдача достижения на сервере -----------------------------
-- Серверный аналог клиентского grantAchievement (teacher.html), но без окна между вставкой
-- и начислением: обе операции в одной транзакции функции. Награда идёт ТОЛЬКО если строка
-- реально вставилась (уникальность (student_id, achievement_code) из 005).
create or replace function public.grant_achievement_server(
  p_student_id bigint, p_code text, p_reward integer)
 returns boolean
 language plpgsql
as $function$
declare
  v_inserted integer;
begin
  insert into public.student_achievements (student_id, achievement_code)
    values (p_student_id, p_code)
    on conflict (student_id, achievement_code) do nothing;
  get diagnostics v_inserted = row_count;

  if v_inserted = 1 and p_reward > 0 then
    perform public.add_huikons(p_student_id, p_reward, 'achievement_' || p_code);
  end if;

  return v_inserted = 1;
end;
$function$;

-- --- 4. Per-approval поток: season points + first_step + clean_10 --------------
-- Идемпотентная RPC приёма работы (решение 3). W10 будет звать её из teacher.html ВМЕСТО
-- старых processStreak/awardApprovalBonus/grantAchievement('first_step'). До деплоя W10 её
-- никто не зовёт — старый клиент продолжает старую экономику (arm-now/fire-with-W10).
--
-- Начисляет ТОЛЬКО за реально принятую работу (ECONOMY §3.2):
--   ежедневка +10, недельное +40, индивидуальное +30 season points (через ledger,
--   event_key на конкретную assignment — один приём = одно начисление за всё время);
--   first_step (10) — первая принятая работа любого типа;
--   clean_10 (25) — 10 принятых работ подряд без возврата (revision_count=0 в серии).
-- Недельные бублики за тир 0/30/55/80/110 здесь НЕ выдаются — они приходят при финализации.
create or replace function public.record_approved_assignment(p_assignment_id uuid)
 returns json
 language plpgsql
as $function$
declare
  v_asn       public.assignments%rowtype;
  v_pts       integer;
  v_reason    text;
  v_run       integer := 0;
  v_clean_10  boolean := false;
  r           record;
begin
  select * into v_asn from public.assignments where id = p_assignment_id;
  if not found then
    raise exception 'Задание % не найдено', p_assignment_id;
  end if;
  if not (v_asn.status = 'checked' and v_asn.approval_status = 'approved') then
    raise exception 'Задание % не принято — начислять нечего', p_assignment_id;
  end if;

  -- Season points по типу принятой работы (ECONOMY §3.2, §14). Пробники сюда не попадают —
  -- их очки начисляет record_weekly_mock_exam (016).
  v_pts := case v_asn.type when 'daily' then 10 when 'weekly' then 40 when 'individual' then 30 else 0 end;
  if v_pts > 0 then
    v_reason := 'approve_' || v_asn.type;
    perform public.award_season_points(
      v_asn.student_id, v_pts, v_reason, 'season_approve_' || v_asn.id::text);
  end if;

  -- first_step — первая принятая работа любого типа (ECONOMY §10.1), идемпотентно.
  perform public.grant_achievement_server(v_asn.student_id, 'first_step', 10);

  -- clean_10 — 10 принятых работ подряд без возврата. Серия строится по принятым работам в
  -- порядке checked_at; работа с revision_count>0 когда-то возвращалась и обрывает серию.
  for r in
    select coalesce(revision_count, 0) = 0 as clean
      from public.assignments
     where student_id = v_asn.student_id
       and status = 'checked' and approval_status = 'approved'
     order by checked_at, id
  loop
    if r.clean then
      v_run := v_run + 1;
      if v_run >= 10 then v_clean_10 := true; end if;
    else
      v_run := 0;
    end if;
  end loop;
  if v_clean_10 then
    perform public.grant_achievement_server(v_asn.student_id, 'clean_10', 25);
  end if;

  return json_build_object('student_id', v_asn.student_id, 'type', v_asn.type, 'season_points', v_pts);
end;
$function$;

-- --- 5. Недельные достижения (оцениваются при финализации) ---------------------
-- Проходит финализированные (не нейтральные) недели ученика в хронологическом порядке.
-- Нейтральные недели (status='neutral') в выборку не входят — они «пропускаются» в
-- последовательности и не ломают её (SPEC §8). Слабая неделя (successful=false) обрывает
-- серии. Достижение перманентно: условие проверяется «когда-либо выполнялось», выдача
-- идемпотентна. Щиты допускают только rhythm_* (ECONOMY §10.2).
create or replace function public.grant_weekly_achievements(p_student_id bigint, p_week_start date)
 returns void
 language plpgsql
as $function$
declare
  r                  record;
  v_total_succ       integer := 0;
  v_run_succ         integer := 0;   -- подряд успешных (щиты разрешены)
  v_max_run_succ     integer := 0;
  v_run_succ_ns      integer := 0;   -- подряд успешных без щитов
  v_max_run_succ_ns  integer := 0;
  v_run_77ns         integer := 0;   -- подряд 7/7 без щитов
  v_max_run_77ns     integer := 0;
  v_any_good         boolean := false;
  v_any_perfect_week boolean := false;
  v_rebirth          boolean := false;
  v_prev_weak        boolean := false;
  v_is_succ          boolean;
  v_is_77            boolean;
begin
  for r in
    select approved_daily_count, shields_used, successful
      from public.student_week_results
     where student_id = p_student_id and status = 'finalized'
     order by week_start
  loop
    v_is_succ := coalesce(r.successful, false);
    v_is_77   := (r.approved_daily_count = 7 and r.shields_used = 0);

    if v_is_succ then
      v_total_succ := v_total_succ + 1;
      v_any_good := true;

      v_run_succ := v_run_succ + 1;
      if v_run_succ > v_max_run_succ then v_max_run_succ := v_run_succ; end if;

      if r.shields_used = 0 then
        v_run_succ_ns := v_run_succ_ns + 1;
      else
        v_run_succ_ns := 0;
      end if;
      if v_run_succ_ns > v_max_run_succ_ns then v_max_run_succ_ns := v_run_succ_ns; end if;

      -- «Возвращение»: после слабой недели — A>=5 без щитов (ECONOMY §10.1).
      if v_prev_weak and r.approved_daily_count >= 5 and r.shields_used = 0 then
        v_rebirth := true;
      end if;
    else
      v_run_succ := 0;
      v_run_succ_ns := 0;
    end if;

    if v_is_77 then
      v_any_perfect_week := true;
      v_run_77ns := v_run_77ns + 1;
      if v_run_77ns > v_max_run_77ns then v_max_run_77ns := v_run_77ns; end if;
    else
      v_run_77ns := 0;
    end if;

    v_prev_weak := not v_is_succ;   -- слабая неделя (не нейтральная, successful=false)
  end loop;

  if v_any_good              then perform public.grant_achievement_server(p_student_id, 'first_good_week', 10); end if;
  if v_any_perfect_week      then perform public.grant_achievement_server(p_student_id, 'perfect_week', 15); end if;
  if v_max_run_succ >= 4     then perform public.grant_achievement_server(p_student_id, 'rhythm_4', 25); end if;
  if v_max_run_succ >= 12    then perform public.grant_achievement_server(p_student_id, 'rhythm_12', 50); end if;
  if v_max_run_succ >= 24    then perform public.grant_achievement_server(p_student_id, 'rhythm_24', 100); end if;
  if v_total_succ >= 36      then perform public.grant_achievement_server(p_student_id, 'good_weeks_36', 150); end if;
  if v_max_run_succ_ns >= 8  then perform public.grant_achievement_server(p_student_id, 'no_shields_8', 40); end if;
  if v_max_run_77ns >= 4     then perform public.grant_achievement_server(p_student_id, 'perfect_month_weekly', 50); end if;
  if v_rebirth               then perform public.grant_achievement_server(p_student_id, 'rebirth_week', 30); end if;
end;
$function$;

-- --- 6. Ledger недельной награды (страховка от двойной выплаты) ----------------
create table if not exists public.weekly_reward_log (
  id            uuid         primary key default gen_random_uuid(),
  student_id    bigint       not null references public.students (telegram_id),
  week_start    date         not null,
  reward_amount integer      not null,
  paid_at       timestamptz  not null default now(),
  unique (student_id, week_start)
);
alter table public.weekly_reward_log disable row level security;

-- --- 7. finalize_student_week: добавляем ВЫПЛАТУ и недельные достижения --------
-- Полностью повторяет тело из 012 (счётчики → щиты → фиксация итога), но в конце
-- финализированной (не нейтральной) ветки, ЕСЛИ недельная экономика активна для этой недели,
-- один раз платит недельную награду через add_huikons (защита ledger'ом weekly_reward_log)
-- и выдаёт недельные достижения. Нейтральная ветка выплаты не делает (reward 0). Функция —
-- одна транзакция: выплата и переход в 'finalized' коммитятся вместе; повторный вызов видит
-- 'finalized' и возвращает результат без второй выплаты. weekly_economy_active(week_start)
-- ложна для недель до cutover — их оплатил старый клиент, двойной оплаты нет.
create or replace function public.finalize_student_week(p_student_id bigint, p_week_start date)
 returns public.student_week_results
 language plpgsql
as $function$
declare
  v_row      public.student_week_results%rowtype;
  v_qty      integer;
  v_consume  integer;
  v_e        integer;
  v_paid     integer;
begin
  -- Блокируем инвентарь до чтения результата: гонка с request_weekly_shield.
  perform 1 from public.student_items
    where student_id = p_student_id and item_code = 'streak_shield' for update;

  v_row := public.recalc_student_week(p_student_id, p_week_start);

  if v_row.status in ('finalized', 'neutral') then
    return v_row;  -- уже закрыта: ни второй выплаты, ни второго списания
  end if;

  -- Неделя не финализируется, пока идёт сама неделя или открыты окна (SPEC §6.3).
  if now() < public.next_monday_msk(p_week_start)
     or v_row.status in ('pending_review', 'awaiting_student') then
    return v_row;
  end if;

  -- N < 4 — нейтральная неделя: без награды, цепочка не рвётся; резервы освобождаются.
  if v_row.available_daily_count < 4 then
    update public.weekly_shield_uses
       set status = 'cancelled', cancelled_at = now(), updated_at = now()
     where student_id = p_student_id and week_start = p_week_start and status = 'requested';

    update public.student_week_results
       set status = 'neutral',
           successful = null,
           requested_shields = 0,
           shields_used = 0,
           effective_daily_count = least(available_daily_count, approved_daily_count, 7),
           reward_amount = 0,
           neutral_reason = case
             when available_daily_count = 0 then 'нет назначенных ежедневок'
             else 'меньше четырёх доступных ежедневок' end,
           finalized_at = now(),
           updated_at = now()
     where student_id = p_student_id and week_start = p_week_start
    returning * into v_row;

    return v_row;
  end if;

  -- Списываем ровно выбранные щиты, но не больше реального запаса.
  select coalesce(quantity, 0) into v_qty from public.student_items
    where student_id = p_student_id and item_code = 'streak_shield';
  v_qty := coalesce(v_qty, 0);
  v_consume := least(v_row.requested_shields, v_qty);

  if v_consume > 0 then
    update public.weekly_shield_uses
       set status = 'consumed', consumed_at = now(), updated_at = now()
     where id in (
       select id from public.weekly_shield_uses
        where student_id = p_student_id and week_start = p_week_start and status = 'requested'
        order by requested_at
        limit v_consume
     );

    update public.weekly_shield_uses
       set status = 'cancelled', cancelled_at = now(), updated_at = now()
     where student_id = p_student_id and week_start = p_week_start and status = 'requested';

    update public.student_items
       set quantity = quantity - v_consume, updated_at = now()
     where student_id = p_student_id and item_code = 'streak_shield';
  else
    update public.weekly_shield_uses
       set status = 'cancelled', cancelled_at = now(), updated_at = now()
     where student_id = p_student_id and week_start = p_week_start and status = 'requested';
  end if;

  v_e := least(v_row.available_daily_count, v_row.approved_daily_count + v_consume, 7);

  update public.student_week_results
     set requested_shields     = 0,
         shields_used          = v_consume,
         effective_daily_count = v_e,
         status                = 'finalized',
         successful            = (v_e >= 4),
         reward_amount         = public.weekly_reward_amount(v_e),
         finalized_at          = now(),
         updated_at            = now()
   where student_id = p_student_id and week_start = p_week_start
  returning * into v_row;

  -- НОВОЕ (W09): выплата и недельные достижения — только когда недельная экономика активна
  -- для этой недели (после cutover, week_start >= неделя cutover). До cutover — no-op, как в 012.
  if public.weekly_economy_active(p_week_start) then
    if v_row.reward_amount > 0 then
      -- Ledger гарантирует ровно одну выплату на (ученик, неделя) даже при ретраях.
      insert into public.weekly_reward_log (student_id, week_start, reward_amount)
        values (p_student_id, p_week_start, v_row.reward_amount)
        on conflict (student_id, week_start) do nothing;
      get diagnostics v_paid = row_count;
      if v_paid = 1 then
        perform public.add_huikons(p_student_id, v_row.reward_amount, 'weekly_reward');
      end if;
    end if;

    perform public.grant_weekly_achievements(p_student_id, p_week_start);
  end if;

  return v_row;
end;
$function$;

-- --- 8. close_season v2: детерминированный tie-break + фиксированный фонд 190 --
-- Заменяет rank()-версию (006). Порядок мест — тотальный (без деления одного места между
-- учениками): rating desc → меньше штрафов в сезоне → раньше набрал очки → telegram_id.
-- Штрафы считаются из balance_history (reason like 'penalty:%') за период сезона —
-- полный источник. «Раньше набрал очки» — по season_points_log (см. предел леджера в шапке).
-- Призы: место 1/2/3 = 100/60/30, ровно по одному ученику с ненулевыми очками; фонд ≤ 190.
create or replace function public.close_season()
 returns json
 language plpgsql
as $function$
declare
  v_season_id    bigint;
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

  -- Блокируем учеников до снимка очков (см. 006: гонка с add_season_points).
  perform 1 from students for update;

  -- Архив мест с детерминированным tie-break. row_number() даёт тотальный порядок:
  -- одинаковых мест не бывает, что и требуется для фиксированного фонда 190.
  insert into season_results (season_id, student_id, points, place)
  select v_season_id, s.telegram_id, s.rating,
         row_number() over (
           order by s.rating desc,
                    coalesce(pen.cnt, 0) asc,        -- меньше штрафов — выше
                    pts.last_scored asc nulls last,  -- раньше набрал очки — выше
                    s.telegram_id asc)               -- финальный детерминизм
    from students s
    left join (
      select student_id, count(*) as cnt
        from balance_history
       where reason like 'penalty:%' and created_at >= v_start_ts
       group by student_id) pen on pen.student_id = s.telegram_id
    left join (
      select student_id, max(created_at) as last_scored
        from season_points_log
       where season_id = v_season_id and amount > 0
       group by student_id) pts on pts.student_id = s.telegram_id;
  get diagnostics v_archived = row_count;

  -- Призы топ-3 с ненулевыми очками: по одному ученику на место, суммарно ≤ 190.
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

  update students set rating = 0 where rating <> 0;

  update seasons set end_date = v_today where id = v_season_id;

  insert into seasons (start_date) values (v_today);

  return json_build_object(
    'season_id', v_season_id,
    'archived', v_archived,
    'awarded', v_awarded
  );
end;
$function$;

-- =============================================================================
-- ВНИМАНИЕ: Supabase Cron здесь НЕ включается (решение 1, arm-now/fire-with-W10).
-- Firing-скрипт (cutover_at + cron.schedule) и rollback выполняются вручную вместе с
-- деплоем W10 — см. карточку W09 / отчёт. finalize_due_student_weeks() уже существует (012).
-- =============================================================================
