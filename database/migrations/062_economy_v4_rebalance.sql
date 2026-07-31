-- =============================================================================
-- 062_economy_v4_rebalance.sql — экономический ребаланс V4
-- (Bot 2.0, Stage 5; ECONOMY_V4_PROPOSAL.md §§4.1-4.12)
--
-- ЗАЧЕМ. Ученик, сдающий 5-6 ежедневок в неделю и двигающийся по лигам, должен за один период
-- каталога (14 дней) уметь купить все четыре сезонных предмета, кормить питомца и понемногу
-- копить. Сейчас его доход 300-370 за период при цене периода 740 + корм 70 — дефицит 440-510.
--
-- --- РЕШЕНИЯ ПОЛЬЗОВАТЕЛЯ (2026-07-31) --------------------------------------------------
--
--   1. Недельные тиры 30/55/80/110 → 60/165/230/300. Шаг 4→5 самый большой (105) намеренно:
--      это порог, на который вытаскиваем учеников; сегодняшняя разница в 25 бубликов не видна.
--   2. Принятое недельное задание 20 → 30, индивидуальное 15 → 25.
--   3. Пробник: база 20 → 30, рекорд 30 → 50.
--   4. Жизненные квесты (3+3+2, потолок 8/день) и суммы достижений НЕ меняются. Квесты —
--      self-report без проверки, их доля в доходе должна падать. Достижения одноразовые, их
--      совокупный лимит 505 за всю жизнь ученика и регулярный дефицит ими не закрывается.
--   5. НОВОЕ: денежная выплата за место в лиге. Лиги закрываются раз в период — совпадение с
--      единицей бюджета, и платят ровно за то поведение, которое требовалось поощрить.
--   6. Приз за глобальный топ-3 сезона (100/60/30) УБИРАЕТСЯ ПОЛНОСТЬЮ: его каждый сезон
--      занимают одни и те же ученики, это надбавка сильнейшим, а не цель. Место в лиге
--      выполняет ту же роль честнее — соревнование идёт внутри своей когорты.
--   7. Сезонный каталог дешевеет на 38% (740 → 460 за период), постоянная витрина дорожает
--      ×2, щит 90 → 150.
--   8. Компенсация балансов НЕ выполняется: реальных учеников в боте ещё нет, обесценивать
--      нечего. Поэтому же ребаланс применяется одной транзакцией, а не dormant+firing:
--      окна двойных выплат, ради которого делалась двухфазность Stage 2.5/Stage 4, здесь нет.
--
-- ГРАНИЦЫ. Миграция не трогает: питомцев (миграция 063), жизненные квесты, суммы достижений,
-- season points, лиговые правила переходов, Корону Легенды, `close_league_season`,
-- legacy-путь `settle_legacy_approval`, купленные предметы, инвентарь и балансы.
--
-- КЛИЕНТ. После применения обязательны правки текстов, где суммы зашиты в разметке:
-- `index.html` кнопка щита «Купить — 90 🥯» и FAQ (тиры 30/55/80/110, 20/15 за задания,
-- 20/30 за пробник), `js/teacher-students.js` «+30 🥯 личный рекорд». Это отдельный шаг.
--
-- НОМЕР. 061 занят миграцией public_season_numbering_from_zero (коммит ddd0105),
-- поэтому ребаланс идёт номером 062.
--
-- ИДЕМПОТЕНТНОСТЬ. Повторный прогон безопасен: create or replace / if not exists, а preflight
-- отвергает уже применённый ребаланс (цены и тиры не совпадут с ожидаемыми pre-значениями).
-- =============================================================================

begin;

-- --- 0. PREFLIGHT: окружение обязано быть ровно pre-ребалансным ---------------
do $preflight$
declare
  v_bad      integer;
  v_missing  integer;
  v_cat_reg  integer;
  v_cat_sum  integer;
begin
  -- 0.1 тиры ещё старые
  if public.weekly_reward_amount(4) <> 30 or public.weekly_reward_amount(5) <> 55
     or public.weekly_reward_amount(6) <> 80 or public.weekly_reward_amount(7) <> 110 then
    raise exception '062 ABORT: weekly_reward_amount уже не pre-ребалансная (%/%/%/%)',
      public.weekly_reward_amount(4), public.weekly_reward_amount(5),
      public.weekly_reward_amount(6), public.weekly_reward_amount(7);
  end if;

  -- 0.2 постоянная витрина держит ровно post-Stage4 цены
  with expected(item_code, old_price) as (values
    ('color_red',80),('color_orange',80),('color_green',80),('color_teal',80),
    ('color_blue',80),('color_indigo',80),('color_pink',80),('color_brown',80),
    ('status_emoji_change',40),('crown',900),('golden_nick',1100),
    ('title_yaschenko',1300),('title_custom',3000),
    ('title_groza',250),('title_elon',250),('title_sanchez',250),('title_derivative',250),
    ('frame_notebook',300),('frame_winter',300),
    ('bg_grid',380),('bg_space',380),('bg_aurora',380),('bg_draft',380),
    ('frame_pulsar',1200),('frame_orbit',1200),
    ('frame_legend_1',2200),('frame_legend_2',2200),('frame_legend_3',2200),('frame_legend_4',2200),
    ('streak_shield',90)
  )
  select count(*) filter (where s.item_code is null),
         count(*) filter (where s.item_code is not null and s.price is distinct from e.old_price)
    into v_missing, v_bad
    from expected e left join public.shop_items s on s.item_code = e.item_code;
  if v_missing > 0 then
    raise exception '062 ABORT: отсутствует % ожидаемых item_code постоянной витрины', v_missing;
  end if;
  if v_bad > 0 then
    raise exception '062 ABORT: % товар(ов) постоянной витрины с неожиданной ценой', v_bad;
  end if;

  -- 0.3 сезонный каталог держит цены ревизии 4
  select count(*) into v_cat_reg
    from public.shop_items
   where item_code like 'ca26\_%' and price in (100,140,180,320);
  select count(*) into v_cat_sum
    from public.shop_items
   where item_code like 'ca26\_%' and price in (90,130,170,300);
  if v_cat_reg <> 84 or v_cat_sum <> 8 then
    raise exception '062 ABORT: каталог ca26 не в ревизии 4 (regular=%, summer=%; ожидалось 84 и 8)',
      v_cat_reg, v_cat_sum;
  end if;

  -- 0.4 лиговый ledger ещё не заводился
  if to_regclass('public.league_reward_log') is not null then
    raise exception '062 ABORT: league_reward_log уже существует — ребаланс, похоже, применён';
  end if;
end
$preflight$;

-- --- 1. Недельные тиры (ECONOMY_V4 §4.1) --------------------------------------
-- 0-3 остаются нулём: недельная награда — за результат, а не за присутствие.
CREATE OR REPLACE FUNCTION public.weekly_reward_amount(p_effective integer)
 RETURNS integer
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select case
    when p_effective >= 7 then 300
    when p_effective = 6  then 230
    when p_effective = 5  then 165
    when p_effective = 4  then 60
    else 0
  end;
$function$;

-- --- 2. Принятые задания: 20/15 → 30/25 (ECONOMY_V4 §4.2) ---------------------
-- Тело перенесено без изменений из действующей версии; правится ровно одна строка v_bonus.
-- Season points 10/40/30, first_step, clean_10, settle_daily_math и ledger не трогаются.
create or replace function public.record_approved_assignment(p_assignment_id uuid)
 returns json
 language plpgsql
 set search_path = public, pg_temp
as $function$
declare
  v_asn public.assignments%rowtype;
  v_pts integer;
  v_reason text;
  v_run integer := 0;
  v_clean_10 boolean := false;
  v_bonus integer;
  v_paid integer;
  r record;
begin
  select * into v_asn from public.assignments where id = p_assignment_id;
  if not found then raise exception 'assignment % not found', p_assignment_id; end if;
  if not (v_asn.status = 'checked' and v_asn.approval_status = 'approved') then
    raise exception 'assignment % is not approved', p_assignment_id;
  end if;
  v_pts := case v_asn.type when 'daily' then 10 when 'weekly' then 40 when 'individual' then 30 else 0 end;
  if v_pts > 0 then
    v_reason := 'approve_' || v_asn.type;
    perform public.award_homework_season_points(
      v_asn.student_id, v_pts, v_reason, 'season_approve_' || v_asn.id::text);
  end if;
  perform public.grant_achievement_server(v_asn.student_id, 'first_step', 10);
  for r in
    select coalesce(revision_count, 0) = 0 as clean
      from public.assignments
     where student_id = v_asn.student_id and status = 'checked' and approval_status = 'approved'
     order by checked_at, id
  loop
    if r.clean then v_run := v_run + 1; if v_run >= 10 then v_clean_10 := true; end if;
    else v_run := 0; end if;
  end loop;
  if v_clean_10 then perform public.grant_achievement_server(v_asn.student_id, 'clean_10', 25); end if;
  if v_asn.type in ('weekly', 'individual') then
    v_bonus := case v_asn.type when 'weekly' then 30 else 25 end;   -- V4: было 20/15
    insert into public.assignment_reward_log (assignment_id, student_id, reward_amount)
    values (v_asn.id, v_asn.student_id, v_bonus) on conflict (assignment_id) do nothing;
    get diagnostics v_paid = row_count;
    if v_paid = 1 then perform public.add_huikons(v_asn.student_id, v_bonus, v_asn.type || '_approved'); end if;
  end if;
  if v_asn.type = 'daily' then perform public.settle_daily_math(v_asn.id); end if;
  return json_build_object('student_id', v_asn.student_id, 'type', v_asn.type, 'season_points', v_pts);
end;
$function$;

-- --- 3. Пробник: база 20 → 30, рекорд 30 → 50 (ECONOMY_V4 §4.3) ---------------
-- Тело перенесено без изменений; правятся только четыре числа выплат. Season points 50 + рост
-- (cap 20), компенсирующая дельта, зеркало в mock_exam_results и правило «один рекорд в
-- календарный месяц» сохраняются дословно.
CREATE OR REPLACE FUNCTION public.record_weekly_mock_exam(
  p_student_id bigint,
  p_week_start date,
  p_score      integer
)
 RETURNS json
 LANGUAGE plpgsql
AS $function$
declare
  v_prev_score   integer;
  v_prev_max     integer;
  v_growth       integer;
  v_season_target integer;
  v_season_prev  integer;
  v_season_delta integer;
  v_is_record    boolean;
  v_record_this_month boolean;
  v_base_awarded boolean := false;
  v_record_awarded boolean := false;
  v_now          timestamptz := now();
  v_month_start  date := date_trunc('month', (v_now at time zone 'Europe/Moscow'))::date;
  v_exam_name    text;
begin
  if p_week_start is null or extract(isodow from p_week_start) <> 1 then
    raise exception 'week_start % — не понедельник', p_week_start;
  end if;
  if p_score is null or p_score < 0 or p_score > 100 then
    raise exception 'score должен быть целым от 0 до 100';
  end if;

  perform 1 from public.students where telegram_id = p_student_id for update;
  if not found then
    raise exception 'Ученик % не найден', p_student_id;
  end if;

  select score into v_prev_score
    from public.weekly_mock_exams
    where student_id = p_student_id and week_start < p_week_start
    order by week_start desc
    limit 1;

  select max(score) into v_prev_max
    from public.weekly_mock_exams
    where student_id = p_student_id and week_start < p_week_start;

  v_growth := least(greatest(p_score - coalesce(v_prev_score, p_score), 0), 20);
  v_season_target := 50 + v_growth;

  select season_points_awarded into v_season_prev
    from public.weekly_mock_exams
    where student_id = p_student_id and week_start = p_week_start
    for update;

  if not found then
    insert into public.weekly_mock_exams (student_id, week_start, score, season_points_awarded)
      values (p_student_id, p_week_start, p_score, v_season_target);
    v_season_prev := 0;
  else
    update public.weekly_mock_exams
      set score = p_score,
          season_points_awarded = v_season_target,
          updated_at = v_now
      where student_id = p_student_id and week_start = p_week_start;
  end if;

  v_season_delta := v_season_target - v_season_prev;
  if v_season_delta <> 0 then
    perform public.award_season_points(p_student_id, v_season_delta, 'mock_exam_season', null);
  end if;

  v_exam_name := 'Недельный пробник ' || to_char(p_week_start, 'DD.MM.YYYY');
  insert into public.mock_exam_results (student_id, exam_name, score, exam_date, updated_at)
    values (p_student_id, v_exam_name, p_score::text, p_week_start, v_now)
    on conflict (student_id, exam_name)
    do update set score = excluded.score, exam_date = excluded.exam_date, updated_at = v_now;

  insert into public.mock_exam_reward_log (student_id, week_start, reward_kind, bubliks)
    values (p_student_id, p_week_start, 'base', 30)                 -- V4: было 20
    on conflict (student_id, week_start, reward_kind) do nothing;
  if found then
    perform public.add_huikons(p_student_id, 30, 'mock_exam_weekly');  -- V4: было 20
    v_base_awarded := true;
  end if;

  v_is_record := v_prev_max is not null and p_score >= v_prev_max + 3;
  if v_is_record then
    select exists (
      select 1 from public.mock_exam_reward_log
        where student_id = p_student_id and reward_kind = 'record'
          and (awarded_at at time zone 'Europe/Moscow')::date >= v_month_start
          and (awarded_at at time zone 'Europe/Moscow')::date < (v_month_start + interval '1 month')
    ) into v_record_this_month;

    if not v_record_this_month then
      insert into public.mock_exam_reward_log (student_id, week_start, reward_kind, bubliks)
        values (p_student_id, p_week_start, 'record', 50)            -- V4: было 30
        on conflict (student_id, week_start, reward_kind) do nothing;
      if found then
        perform public.add_huikons(p_student_id, 50, 'mock_exam_record');  -- V4: было 30
        v_record_awarded := true;
      end if;
    end if;
  end if;

  return json_build_object(
    'week_start', p_week_start,
    'score', p_score,
    'season_points_awarded', v_season_target,
    'season_points_delta', v_season_delta,
    'base_awarded', v_base_awarded,
    'record_eligible', v_is_record,
    'record_awarded', v_record_awarded
  );
end;
$function$;

-- --- 4. Щит: 90 → 150 (ECONOMY_V4 §4.9) ---------------------------------------
-- Цена щита живёт в коде функции, а не в shop_items (строка каталога — витринная). Меняется
-- ровно v_price; лимит запаса 7 и вся механика покупки сохраняются.
-- Проверка арбитража: максимальная прибавка от одного щита в новой шкале — 105 (E4→E5),
-- цена 150, то есть покупка ради денег убыточна на 45.
CREATE OR REPLACE FUNCTION public.buy_streak_shield(p_student_id bigint)
 RETURNS json
 LANGUAGE plpgsql
AS $function$
declare
  v_price  integer := 150;   -- V4: было 90
  v_max    integer := 7;
  v_qty    integer;
  v_balance integer;
  v_new_balance integer;
begin
  select quantity into v_qty
    from student_items
    where student_id = p_student_id and item_code = 'streak_shield'
    for update;
  if v_qty is null then v_qty := 0; end if;

  if v_qty >= v_max then
    raise exception 'Лимит: не больше % щитов в запасе', v_max;
  end if;

  select huikons into v_balance
    from students
    where telegram_id = p_student_id
    for update;
  if v_balance is null then
    raise exception 'Ученик % не найден', p_student_id;
  end if;
  if v_balance < v_price then
    raise exception 'Недостаточно бубликов: нужно %, есть %', v_price, v_balance;
  end if;

  select new_balance into v_new_balance
    from add_huikons(p_student_id, -v_price, 'buy_streak_shield');

  insert into student_items (student_id, item_code, quantity)
    values (p_student_id, 'streak_shield', 1)
    on conflict (student_id, item_code)
    do update set quantity = student_items.quantity + 1, updated_at = now();

  select quantity into v_qty
    from student_items
    where student_id = p_student_id and item_code = 'streak_shield';

  return json_build_object('quantity', v_qty, 'balance', v_new_balance);
end;
$function$;

-- --- 5. Лиговая выплата (ECONOMY_V4 §4.6) -------------------------------------
-- league_reward_log — pay-once ledger, ключ (season_id, student_id). Тот же приём, что у
-- weekly_reward_log: повтор закрытия сезона, retry и параллельный вызов не платят второй раз.
create table if not exists public.league_reward_log (
  id         uuid        primary key default gen_random_uuid(),
  season_id  bigint      not null references public.seasons (id),
  student_id bigint      not null references public.students (telegram_id),
  tier       integer     not null references public.league_tiers (tier),
  place      integer,
  movement   text,
  amount     integer     not null check (amount > 0),
  paid_at    timestamptz not null default now(),
  unique (season_id, student_id)
);
create index if not exists idx_league_reward_log_student
  on public.league_reward_log (student_id, paid_at);

-- DENY-CLIENT по образцу миграции 043: ledger читают только definer-функции и service_role.
alter table public.league_reward_log enable row level security;
revoke all on public.league_reward_log from anon, authenticated;

-- pay_league_season_rewards — выплата за место в СВОЕЙ лиге закрытого сезона.
-- Вызывается строго ПОСЛЕ close_league_season: та проставляет points/place/movement.
-- close_league_season намеренно не трогается — вся её логика мест, переходов и Короны
-- Легенды остаётся дословно прежней, выплата живёт отдельной функцией.
-- Платят только реально участвовавшие: activated_at is not null и points > 0.
create or replace function public.pay_league_season_rewards(p_season_id bigint)
 returns integer
 language plpgsql
 set search_path = public, pg_temp
as $function$
declare
  r        record;
  v_amount integer;
  v_paid   integer;
  v_count  integer := 0;
begin
  for r in
    select m.student_id, m.tier, m.place, m.movement
      from public.league_memberships m
     where m.season_id = p_season_id
       and m.activated_at is not null
       and coalesce(m.points, 0) > 0
     order by m.student_id
  loop
    v_amount := case
      when r.place = 1                then 150
      when r.place between 2 and 3    then 110
      when r.place between 4 and 10   then 75
      else 35
    end;
    if r.movement = 'promote' then
      v_amount := v_amount + 50;
    end if;

    insert into public.league_reward_log (season_id, student_id, tier, place, movement, amount)
      values (p_season_id, r.student_id, r.tier, r.place, r.movement, v_amount)
      on conflict (season_id, student_id) do nothing;
    get diagnostics v_paid = row_count;
    if v_paid = 1 then
      perform public.add_huikons(r.student_id, v_amount, 'league_reward');
      v_count := v_count + 1;
    end if;
  end loop;

  return v_count;
end;
$function$;

revoke all on function public.pay_league_season_rewards(bigint) from public, anon, authenticated;

-- --- 6. finish_season: убрать приз глобального топ-3, добавить лиговую выплату -
-- ИСТОЧНИК ТЕЛА: миграция 057 (Season V2), а НЕ database/schema.sql. Снимок schema.sql отстал:
-- в нём нет объектов 057-060, и его версия finish_season ставит сезону status='completed'
-- (доV2-семантика). Живая версия ставит 'closed' и пишет updated_at — состояние из контракта
-- Season V2 (draft/scheduled/active/closed/archived). Копирование из снимка молча откатило бы
-- статусную машину сезонов и сломало учительский раздел «Сезоны».
--
-- Изменения относительно 057 ровно два:
--   * удалён цикл выплаты season_place_N (ECONOMY_V4 §4.10);
--   * после close_league_season вызывается pay_league_season_rewards.
-- Сохраняются: status='closed' + updated_at, построение season_results со всеми учениками,
-- детерминированный тай-брейк, архив мест, обнуление rating и контракт возврата.
-- Поле 'awarded' в ответе теперь означает число лиговых выплат, а не призов топ-3.
create or replace function public.finish_season(p_season_id bigint)
 returns json
 language plpgsql
 set search_path = public, pg_temp
as $function$
declare
  v_status       text;
  v_start_date   date;
  v_start_ts     timestamptz;
  v_today        date := (now() at time zone 'Europe/Moscow')::date;
  v_archived     integer := 0;
  v_awarded      integer := 0;
begin
  select status, start_date into v_status, v_start_date
    from public.seasons where id = p_season_id for update;
  if v_status is null then
    raise exception 'season % not found', p_season_id;
  end if;
  if v_status <> 'active' then
    return json_build_object(
      'season_id', p_season_id, 'archived', 0, 'awarded', 0,
      'next_season_id', public.current_season_id(), 'already_completed', true);
  end if;

  v_start_ts := (v_start_date::timestamp) at time zone 'Europe/Moscow';
  update public.seasons
     set status = 'closed', end_date = v_today, updated_at = now()
   where id = p_season_id;

  perform 1 from public.students for update;
  insert into public.season_results (season_id, student_id, points, place)
  select p_season_id, s.telegram_id, s.rating,
         row_number() over (
           order by s.rating desc, coalesce(pen.cnt, 0) asc,
                    pts.last_scored asc nulls last, s.telegram_id asc)
    from public.students s
    left join (
      select student_id, count(*) as cnt
        from public.balance_history
       where reason like 'penalty:%' and created_at >= v_start_ts
       group by student_id
    ) pen on pen.student_id = s.telegram_id
    left join (
      select student_id, max(created_at) as last_scored
        from public.season_points_log
       where season_id = p_season_id and amount <> 0
       group by student_id
    ) pts on pts.student_id = s.telegram_id
  on conflict (season_id, student_id) do nothing;
  get diagnostics v_archived = row_count;

  -- V4: приз за глобальный топ-3 (100/60/30) удалён. season_results по-прежнему строится
  -- полностью: он нужен лиговым когортам, общему топу и истории.

  perform public.close_league_season(p_season_id, null);

  -- V4: выплата за место в своей лиге — только после того, как места и переходы проставлены.
  v_awarded := public.pay_league_season_rewards(p_season_id);

  update public.students set rating = 0 where rating <> 0;

  return json_build_object(
    'season_id', p_season_id, 'archived', v_archived, 'awarded', v_awarded,
    'next_season_id', null, 'already_completed', false);
end;
$function$;

-- --- 7. Постоянная витрина ×2 (ECONOMY_V4 §4.8) -------------------------------
update public.shop_items set price = 160
 where item_code in ('color_red','color_orange','color_green','color_teal',
                     'color_blue','color_indigo','color_pink','color_brown');
update public.shop_items set price = 80   where item_code = 'status_emoji_change';
update public.shop_items set price = 1800 where item_code = 'crown';
update public.shop_items set price = 2200 where item_code = 'golden_nick';
update public.shop_items set price = 2600 where item_code = 'title_yaschenko';
update public.shop_items set price = 6000 where item_code = 'title_custom';
update public.shop_items set price = 500  where item_code in ('title_groza','title_elon','title_sanchez','title_derivative');
update public.shop_items set price = 600  where item_code in ('frame_notebook','frame_winter');
update public.shop_items set price = 760  where item_code in ('bg_grid','bg_space','bg_aurora','bg_draft');
update public.shop_items set price = 2400 where item_code in ('frame_pulsar','frame_orbit');
update public.shop_items set price = 4400 where item_code in ('frame_legend_1','frame_legend_2','frame_legend_3','frame_legend_4');

-- Витринная строка щита держится в согласии с ценой в buy_streak_shield (§4).
update public.shop_items set price = 150 where item_code = 'streak_shield';

-- --- 8. Сезонный каталог −38% (ECONOMY_V4 §4.7) -------------------------------
-- Сначала все 92 предмета переводятся на профиль regular по редкости, затем восемь предметов
-- двух межсезонных периодов — на летний профиль. Пропорции редкостей сохранены
-- (легендарка ≈ 3 common), поэтому смысл редкости не меняется.
update public.shop_items
   set price = case rarity
                 when 'common'    then 60
                 when 'rare'      then 90
                 when 'epic'      then 120
                 when 'legendary' then 190
               end
 where item_code like 'ca26\_%'
   and rarity in ('common','rare','epic','legendary');

update public.shop_items
   set price = case rarity
                 when 'common'    then 55
                 when 'rare'      then 80
                 when 'epic'      then 110
                 when 'legendary' then 170
               end
 where item_code in (
   'ca26_01_avatar_field_notebook','ca26_01_frame_sun_route',
   'ca26_01_title_field_researcher','ca26_01_background_summer_notes',
   'ca26_02_avatar_paper_planner','ca26_02_frame_checkpoint_flight',
   'ca26_02_title_ready_to_start','ca26_02_background_august_plan');

-- --- 9. POSTFLIGHT: результат обязан быть ровно целевым -----------------------
do $postflight$
declare
  v_bad integer;
begin
  if public.weekly_reward_amount(4) <> 60 or public.weekly_reward_amount(5) <> 165
     or public.weekly_reward_amount(6) <> 230 or public.weekly_reward_amount(7) <> 300 then
    raise exception '062 ABORT: тиры применились неверно';
  end if;

  select count(*) into v_bad
    from public.shop_items
   where item_code like 'ca26\_%'
     and price not in (60,90,120,190,55,80,110,170);
  if v_bad > 0 then
    raise exception '062 ABORT: % предмет(ов) каталога с неожиданной ценой после переоценки', v_bad;
  end if;

  select count(*) into v_bad
    from public.shop_items
   where item_code = 'streak_shield' and price <> 150;
  if v_bad > 0 then
    raise exception '062 ABORT: витринная цена щита разошлась с ценой в buy_streak_shield';
  end if;
end
$postflight$;

commit;

-- =============================================================================
-- ROLLBACK (полный возврат к состоянию до 062; балансы и купленные предметы не трогаются —
-- выплаченные по новым правилам бублики НЕ отзываются, clawback не предусмотрен):
--
--   begin;
--     -- тиры
--     create or replace function public.weekly_reward_amount(p_effective integer)
--      returns integer language sql immutable as $f$
--       select case when p_effective >= 7 then 110 when p_effective = 6 then 80
--                   when p_effective = 5 then 55  when p_effective = 4 then 30 else 0 end;
--     $f$;
--     -- задания: вернуть v_bonus на 20/15, пробник на 20/30, щит на 90 —
--     -- переопределить record_approved_assignment / record_weekly_mock_exam / buy_streak_shield
--     -- телами из миграций 054 (record_approved_assignment), 018 (record_weekly_mock_exam),
--     -- 012 (buy_streak_shield) и 057 (finish_season) — НЕ из schema.sql: снимок отстаёт.
--     -- finish_season: вернуть тело с циклом season_place_N и без pay_league_season_rewards.
--     -- цены:
--     update public.shop_items set price = 80 where item_code like 'color\_%';
--     update public.shop_items set price = 40   where item_code = 'status_emoji_change';
--     update public.shop_items set price = 900  where item_code = 'crown';
--     update public.shop_items set price = 1100 where item_code = 'golden_nick';
--     update public.shop_items set price = 1300 where item_code = 'title_yaschenko';
--     update public.shop_items set price = 3000 where item_code = 'title_custom';
--     update public.shop_items set price = 250  where item_code in ('title_groza','title_elon','title_sanchez','title_derivative');
--     update public.shop_items set price = 300  where item_code in ('frame_notebook','frame_winter');
--     update public.shop_items set price = 380  where item_code in ('bg_grid','bg_space','bg_aurora','bg_draft');
--     update public.shop_items set price = 1200 where item_code in ('frame_pulsar','frame_orbit');
--     update public.shop_items set price = 2200 where item_code in ('frame_legend_1','frame_legend_2','frame_legend_3','frame_legend_4');
--     update public.shop_items set price = 90   where item_code = 'streak_shield';
--     update public.shop_items set price = case rarity when 'common' then 100 when 'rare' then 140
--            when 'epic' then 180 when 'legendary' then 320 end
--      where item_code like 'ca26\_%' and rarity in ('common','rare','epic','legendary');
--     update public.shop_items set price = case rarity when 'common' then 90 when 'rare' then 130
--            when 'epic' then 170 when 'legendary' then 300 end
--      where item_code in ('ca26_01_avatar_field_notebook','ca26_01_frame_sun_route',
--        'ca26_01_title_field_researcher','ca26_01_background_summer_notes',
--        'ca26_02_avatar_paper_planner','ca26_02_frame_checkpoint_flight',
--        'ca26_02_title_ready_to_start','ca26_02_background_august_plan');
--     drop function if exists public.pay_league_season_rewards(bigint);
--     drop table if exists public.league_reward_log;
--   commit;
-- =============================================================================
