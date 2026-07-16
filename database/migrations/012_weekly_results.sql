-- =============================================================================
-- 012_weekly_results.sql — недельный результат, дедлайны исправлений и щиты недели
-- (Bot 2.0, Stage 2.5, карточка W04; SPEC_STAGE2_5.md §§3, 6-8, 13; ECONOMY_V2.md §§3-6)
--
-- Зачем: создать СЕРВЕРНЫЙ источник истины для недельного результата, окон исправления и
-- ручного применения щитов. Награды на этом шаге НЕ начисляются: finalize считает и
-- сохраняет reward_amount, но add_huikons не зовёт — выплату включает экономический
-- cutover (W09, миграция 015). Расписание (pg_cron) тоже не включается: W04 только создаёт
-- finalize_due_student_weeks(), запуск по расписанию добавляет W09 вместе с cutover_at.
--
-- Состав:
--   1. Щит недели: цена 90, лимит запаса 7 (shop_items + buy_streak_shield).
--   2. Утилиты: week_start_of, next_monday_msk, weekly_reward_amount,
--      is_first_submission_on_time.
--   3. Триггер жизненного цикла assignments: серверное заполнение first_submitted_at,
--      revision_count, revision_deadline_at + нормализация submitted_at/checked_at.
--   4. student_week_results — снимок недельного расчёта.
--   5. weekly_shield_uses — резерв щита на конкретную assignment (requested/consumed/cancelled).
--   6. RPC: request_weekly_shield, cancel_weekly_shield.
--   7. RPC: recalc_student_week, finalize_student_week, finalize_due_student_weeks.
--
-- РЕШЕНИЯ ПОЛЬЗОВАТЕЛЯ (2026-07-16), зафиксированы здесь по требованию карточки:
--
--   * ПОЗДНЯЯ ПЕРВАЯ СДАЧА НЕ ЗАСЧИТЫВАЕТСЯ В `A`. Ежедневка попадает в `A`, только если её
--     ПЕРВАЯ отправка была в свой scheduled_date (SPEC §6.1: «должна быть впервые отправлена
--     в свой scheduled_date»; §6.3: финализацию блокирует только «отправленная вовремя»
--     работа). Поздняя работа остаётся в истории и даёт очки сезона, но не меняет недельный
--     результат. Иначе щит за 90 бубликов терял бы смысл — было бы дешевле сдать всё в
--     воскресенье. После СВОЕВРЕМЕННОЙ первой отправки все пересдачи относятся к исходной
--     неделе независимо от того, когда они приняты (SPEC §6.1).
--
--   * ЦЕНА 90 И ЛИМИТ 7 ВНОСЯТСЯ ЗДЕСЬ, а не в W09. Карточка W04 формально запрещает менять
--     цены магазина, но требует «лимит инвентаря 7»; пользователь решил, что щит — часть W04,
--     а не общий пересчёт магазина. Остальные товары не переоцениваются. Существующие щиты
--     сохраняются один к одному: лимит только поднимается (2 → 7), количество не обрезается.
--
-- ЧАСЫ. submitted_at/checked_at сейчас пишут КЛИЕНТЫ (new Date() в index.html/teacher.html).
-- SPEC §6.2 требует, чтобы право на окно определяли timestamps БД, а не клиентские часы,
-- поэтому триггер перезаписывает эти поля серверным now() в момент самой отправки/проверки.
-- Клиенты при этом не меняются: они по-прежнему пишут своё значение, сервер его нормализует.
--
-- LEGACY. Backfill не делается (карточка): у строк, отправленных до 012, first_submitted_at
-- остаётся null. Там, где нужна дата первой отправки, используется read-time fallback
-- coalesce(first_submitted_at, submitted_at) — это не заполнение колонки, а чтение
-- единственного доступного свидетельства. Legacy-строки остаются читаемыми.
--
-- Повторный запуск миграции безопасен (if not exists / or replace / drop trigger if exists).
-- RLS у новых таблиц выключен, как у всех таблиц проекта (T10).
-- =============================================================================

-- --- 1. Щит недели: цена 90, лимит запаса 7 ----------------------------------
-- Решение пользователя (см. шапку). UI-название остаётся «Щит стрика» до cutover W09:
-- пока действует старый processStreak(), щит фактически чинит календарный стрик, и
-- переименование в «Щит недели» (SPEC §7.2) вводило бы в заблуждение.

update public.shop_items set price = 90 where item_code = 'streak_shield';

-- buy_streak_shield — единственная точка покупки щита (008 делегирует в неё из buy_item).
-- Меняются только v_price и v_max; остальная логика G9 без изменений.
CREATE OR REPLACE FUNCTION public.buy_streak_shield(p_student_id bigint)
 RETURNS json
 LANGUAGE plpgsql
AS $function$
declare
  v_price  integer := 90;   -- было 40 (G9); ECONOMY_V2 §6, решение пользователя W04
  v_max    integer := 7;    -- было 2  (G9); SPEC §7.2 «лимит запаса 7»
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

-- --- 2. Утилиты недельного расчёта --------------------------------------------

-- Понедельник учебной недели, содержащей дату (SPEC §3).
CREATE OR REPLACE FUNCTION public.week_start_of(p_date date)
 RETURNS date
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select p_date - (extract(isodow from p_date)::int - 1);
$function$;

-- Момент следующего понедельника 00:00 МСК после недели этой даты — граница учебной недели
-- [понедельник 00:00; следующий понедельник 00:00) (SPEC §3).
CREATE OR REPLACE FUNCTION public.next_monday_msk(p_date date)
 RETURNS timestamptz
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select ((public.week_start_of(p_date) + 7)::timestamp) at time zone 'Europe/Moscow';
$function$;

-- Недельная награда по эффективному результату E (SPEC §7.3, ECONOMY_V2 §4).
-- W04 только считает и сохраняет сумму; выплату включает W09.
CREATE OR REPLACE FUNCTION public.weekly_reward_amount(p_effective integer)
 RETURNS integer
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select case
    when p_effective >= 7 then 110
    when p_effective = 6  then 80
    when p_effective = 5  then 55
    when p_effective = 4  then 30
    else 0
  end;
$function$;

-- Была ли ПЕРВАЯ отправка своевременной (в свой scheduled_date, МСК) — решение пользователя
-- 2026-07-16 + SPEC §6.1. coalesce(...) — read-time fallback для legacy-строк без
-- first_submitted_at, а не backfill колонки.
CREATE OR REPLACE FUNCTION public.is_first_submission_on_time(
  p_first_submitted_at timestamptz,
  p_submitted_at       timestamptz,
  p_scheduled_date     date
)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select coalesce(p_first_submitted_at, p_submitted_at) is not null
     and p_scheduled_date is not null
     and (coalesce(p_first_submitted_at, p_submitted_at) at time zone 'Europe/Moscow')::date
         <= p_scheduled_date;
$function$;

-- --- 3. Триггер жизненного цикла assignments ----------------------------------
-- Поля first_submitted_at / revision_deadline_at / revision_count созданы миграцией 011 как
-- nullable storage; здесь закрепляется их серверная семантика и заполнение. Триггером, а не
-- RPC: писать в assignments продолжают существующие клиенты (uploadDZ в index.html,
-- проверка работ в teacher.html), а карточка W04 запрещает менять UI — так правило
-- действует независимо от того, кто выполнил запись.
CREATE OR REPLACE FUNCTION public.trg_assignments_revision_lifecycle()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
declare
  v_attempt_on_time boolean;
  v_next_monday     timestamptz;
begin
  -- Отправка (первая или пересдача): серверные часы + фиксация первой отправки.
  if new.status = 'submitted' and new.submitted_at is distinct from old.submitted_at then
    new.submitted_at := now();
    if new.first_submitted_at is null then
      new.first_submitted_at := now();
    end if;
  end if;

  -- Решение учителя: серверные часы.
  if new.status = 'checked' and new.checked_at is distinct from old.checked_at then
    new.checked_at := now();
  end if;

  -- Возврат работы. Только реальный возврат отправленной работы (old.status = 'submitted'):
  -- повторный клик «Возврат» по уже возвращённой строке из архива счётчик не наращивает.
  if new.status = 'checked'
     and new.approval_status = 'rejected'
     and old.status = 'submitted' then

    new.revision_count := coalesce(old.revision_count, 0) + 1;

    -- Окна исправления определены спецификацией только для ежедневок (SPEC §6): у weekly и
    -- individual дедлайна нет, придумывать его здесь нельзя.
    if new.type = 'daily' then
      -- Была ли возвращаемая попытка отправлена в действовавший срок?
      if coalesce(old.revision_count, 0) = 0 then
        -- первая сдача — в свой scheduled_date (§6.1)
        v_attempt_on_time := public.is_first_submission_on_time(
          old.first_submitted_at, old.submitted_at, new.scheduled_date);
      else
        -- пересдача — в действовавшее окно исправления (§6.2)
        v_attempt_on_time := old.revision_deadline_at is not null
                         and old.submitted_at is not null
                         and old.submitted_at <= old.revision_deadline_at;
      end if;

      if v_attempt_on_time then
        v_next_monday := public.next_monday_msk(new.scheduled_date);
        if now() < v_next_monday then
          -- возврат до понедельника 00:00 МСК: срок — понедельник (§6.1)
          new.revision_deadline_at := v_next_monday;
        else
          -- поздний возврат вовремя отправленной работы: 24 часа с момента возврата (§6.2)
          new.revision_deadline_at := now() + interval '24 hours';
        end if;
      else
        -- попытка была не в срок — поздний возврат окна не даёт (§6.2)
        new.revision_deadline_at := null;
      end if;
    end if;
  end if;

  return new;
end;
$function$;

drop trigger if exists trg_assignments_revision_lifecycle on public.assignments;
create trigger trg_assignments_revision_lifecycle
  before update on public.assignments
  for each row
  execute function public.trg_assignments_revision_lifecycle();

-- --- 4. Недельный результат ----------------------------------------------------

-- student_week_results — снимок расчёта одной недели одного ученика (SPEC §7.1).
-- Источником реальной работы остаются assignments; строка — кэш/итог, пересчитываемый
-- recalc_student_week до финализации.
create table if not exists public.student_week_results (
  id                    uuid         primary key default gen_random_uuid(),
  student_id            bigint       not null references public.students (telegram_id),
  week_start            date         not null check (extract(isodow from week_start) = 1),
  available_daily_count integer      not null default 0 check (available_daily_count >= 0),  -- N
  approved_daily_count  integer      not null default 0 check (approved_daily_count >= 0),   -- A
  requested_shields     integer      not null default 0 check (requested_shields >= 0),
  shields_used          integer      not null default 0 check (shields_used >= 0),           -- S
  effective_daily_count integer      not null default 0 check (effective_daily_count >= 0),  -- E
  status                text         not null default 'open'
                                     check (status in ('open', 'pending_review', 'awaiting_student', 'finalized', 'neutral')),
  successful            boolean,
  reward_amount         integer      check (reward_amount is null or reward_amount >= 0),
  neutral_reason        text,
  finalized_at          timestamptz,
  created_at            timestamptz  not null default now(),
  updated_at            timestamptz  not null default now(),
  unique (student_id, week_start)
);

create index if not exists idx_student_week_results_open
  on public.student_week_results (week_start)
  where status not in ('finalized', 'neutral');

alter table public.student_week_results disable row level security;

-- weekly_shield_uses — резерв щита на КОНКРЕТНУЮ ежедневку (SPEC §7.2). Отдельная таблица от
-- streak_shield_uses (007): та закрывает календарные разрывы старого processStreak() и по
-- карточке W04 не трогается; эта резервирует щит под недельный результат.
-- on delete cascade: sync_student_week_assignments (011) удаляет НЕНАЧАТЫЕ плановые строки при
-- правке/отмене плана, а именно на неначатую ежедневку и ставится резерв щита. Без cascade
-- FK уронил бы publish_weekly_plan. Списанный (consumed) резерв так не пропадёт: sync не
-- трогает прошедшие недели и начатые строки, а щит списывается только при финализации.
create table if not exists public.weekly_shield_uses (
  id            uuid         primary key default gen_random_uuid(),
  student_id    bigint       not null references public.students (telegram_id),
  week_start    date         not null check (extract(isodow from week_start) = 1),
  assignment_id uuid         not null references public.assignments (id) on delete cascade,
  status        text         not null check (status in ('requested', 'consumed', 'cancelled')),
  requested_at  timestamptz  not null default now(),
  consumed_at   timestamptz,
  cancelled_at  timestamptz,
  created_at    timestamptz  not null default now(),
  updated_at    timestamptz  not null default now()
);

-- Активный резерв уникален для assignment; списанный — тоже (нельзя списать дважды).
create unique index if not exists uq_weekly_shield_requested
  on public.weekly_shield_uses (assignment_id) where status = 'requested';
create unique index if not exists uq_weekly_shield_consumed
  on public.weekly_shield_uses (assignment_id) where status = 'consumed';
create index if not exists idx_weekly_shield_student_week
  on public.weekly_shield_uses (student_id, week_start);

alter table public.weekly_shield_uses disable row level security;

-- --- 5. Автоосвобождение резерва при принятии работы ----------------------------
-- SPEC §7.2: «если assignment принята до финализации, её резерв отменяется сервером
-- автоматически» — щит не тратится на день, который в итоге зачли по-настоящему.
CREATE OR REPLACE FUNCTION public.trg_assignments_release_shield()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  if new.status = 'checked' and new.approval_status = 'approved'
     and (old.status is distinct from 'checked' or old.approval_status is distinct from 'approved') then
    update public.weekly_shield_uses
       set status = 'cancelled', cancelled_at = now(), updated_at = now()
     where assignment_id = new.id and status = 'requested';
  end if;
  return null;
end;
$function$;

drop trigger if exists trg_assignments_release_shield on public.assignments;
create trigger trg_assignments_release_shield
  after update on public.assignments
  for each row
  execute function public.trg_assignments_release_shield();

-- --- 6. Ручное применение щитов ------------------------------------------------

-- Доступный запас = инвентарь минус все активные резервы ЛЮБЫХ нефинализированных недель:
-- одну единицу нельзя обещать двум открытым неделям (SPEC §7.2).
CREATE OR REPLACE FUNCTION public.available_shield_quantity(p_student_id bigint)
 RETURNS integer
 LANGUAGE sql
 STABLE
AS $function$
  select coalesce((select quantity from public.student_items
                    where student_id = p_student_id and item_code = 'streak_shield'), 0)
       - (select count(*) from public.weekly_shield_uses
           where student_id = p_student_id and status = 'requested')::int;
$function$;

-- request_weekly_shield — зарезервировать щит под конкретную пропущенную ежедневку.
-- Ничего не списывает: списание происходит только при финализации (SPEC §7.2).
CREATE OR REPLACE FUNCTION public.request_weekly_shield(p_student_id bigint, p_assignment_id uuid)
 RETURNS json
 LANGUAGE plpgsql
AS $function$
declare
  v_asn        public.assignments%rowtype;
  v_week_start date;
  v_status     text;
  v_available  integer;
begin
  -- Блокируем инвентарь: параллельные запросы не должны обещать один щит дважды.
  perform 1 from public.student_items
    where student_id = p_student_id and item_code = 'streak_shield' for update;

  select * into v_asn from public.assignments where id = p_assignment_id;
  if not found or v_asn.student_id is distinct from p_student_id then
    raise exception 'Задание не найдено у этого ученика';
  end if;
  if v_asn.type <> 'daily' then
    raise exception 'Щит применяется только к ежедневкам';
  end if;
  if v_asn.scheduled_date is null then
    raise exception 'У задания нет даты — щит применить нельзя';
  end if;
  -- Щит закрывает только реально назначенный НЕПРИНЯТЫЙ день (ECONOMY_V2 §6).
  if v_asn.status = 'checked' and v_asn.approval_status = 'approved' then
    raise exception 'Работа уже принята — щит не нужен';
  end if;

  v_week_start := public.week_start_of(v_asn.scheduled_date);

  select status into v_status from public.student_week_results
    where student_id = p_student_id and week_start = v_week_start for update;
  if v_status in ('finalized', 'neutral') then
    raise exception 'Неделя уже закрыта — выбор щитов изменить нельзя';
  end if;

  -- Идемпотентность: повтор/двойной клик не создаёт второй резерв.
  if exists (select 1 from public.weekly_shield_uses
               where assignment_id = p_assignment_id and status = 'requested') then
    return json_build_object('status', 'requested', 'available', public.available_shield_quantity(p_student_id));
  end if;
  if exists (select 1 from public.weekly_shield_uses
               where assignment_id = p_assignment_id and status = 'consumed') then
    raise exception 'На это задание щит уже списан';
  end if;

  v_available := public.available_shield_quantity(p_student_id);
  if v_available < 1 then
    raise exception 'Нет свободных щитов: все либо не куплены, либо уже обещаны другой неделе';
  end if;

  insert into public.weekly_shield_uses (student_id, week_start, assignment_id, status)
    values (p_student_id, v_week_start, p_assignment_id, 'requested');

  perform public.recalc_student_week(p_student_id, v_week_start);

  return json_build_object('status', 'requested', 'available', public.available_shield_quantity(p_student_id));
end;
$function$;

-- cancel_weekly_shield — снять резерв до финализации; освобождает единицу запаса.
CREATE OR REPLACE FUNCTION public.cancel_weekly_shield(p_student_id bigint, p_assignment_id uuid)
 RETURNS json
 LANGUAGE plpgsql
AS $function$
declare
  v_week_start date;
  v_status     text;
begin
  select week_start into v_week_start from public.weekly_shield_uses
    where assignment_id = p_assignment_id and student_id = p_student_id and status = 'requested'
    for update;
  if not found then
    -- Идемпотентно: отменять нечего.
    return json_build_object('status', 'cancelled', 'available', public.available_shield_quantity(p_student_id));
  end if;

  select status into v_status from public.student_week_results
    where student_id = p_student_id and week_start = v_week_start for update;
  if v_status in ('finalized', 'neutral') then
    raise exception 'Неделя уже закрыта — выбор щитов изменить нельзя';
  end if;

  update public.weekly_shield_uses
     set status = 'cancelled', cancelled_at = now(), updated_at = now()
   where assignment_id = p_assignment_id and status = 'requested';

  perform public.recalc_student_week(p_student_id, v_week_start);

  return json_build_object('status', 'cancelled', 'available', public.available_shield_quantity(p_student_id));
end;
$function$;

-- --- 7. Пересчёт и финализация недели ------------------------------------------

-- recalc_student_week — обновляет снимок недели по фактическим assignments (SPEC §3, §7.1).
-- Финализированную неделю не трогает: её счётчики заморожены (SPEC §6.3).
--   N — ежедневки, реально назначенные ученику на дни этой недели (по scheduled_date, поэтому
--       legacy-строки без плана тоже учитываются корректно, а неверный legacy week_label — нет);
--   A — принятые ежедневки, чья ПЕРВАЯ отправка была своевременной (решение пользователя);
--   S — списанные щиты (до финализации 0), requested_shields — активные резервы;
--   E = min(N, A + щиты, 7).
CREATE OR REPLACE FUNCTION public.recalc_student_week(p_student_id bigint, p_week_start date)
 RETURNS public.student_week_results
 LANGUAGE plpgsql
AS $function$
declare
  v_row       public.student_week_results%rowtype;
  v_n         integer;
  v_a         integer;
  v_requested integer;
  v_consumed  integer;
  v_shields   integer;
  v_e         integer;
  v_pending   boolean;
  v_awaiting  boolean;
  v_status    text;
begin
  if p_week_start is null or extract(isodow from p_week_start) <> 1 then
    raise exception 'week_start % — не понедельник', p_week_start;
  end if;

  select * into v_row from public.student_week_results
    where student_id = p_student_id and week_start = p_week_start for update;

  if found and v_row.status in ('finalized', 'neutral') then
    return v_row;  -- итог заморожен
  end if;

  select
    count(*),
    count(*) filter (
      where a.status = 'checked' and a.approval_status = 'approved'
        and public.is_first_submission_on_time(a.first_submitted_at, a.submitted_at, a.scheduled_date)),
    -- вовремя отправленная работа без решения учителя (§6.3)
    bool_or(a.status = 'submitted'
            and public.is_first_submission_on_time(a.first_submitted_at, a.submitted_at, a.scheduled_date)),
    -- возвращённая работа с неистёкшим окном (§6.3)
    bool_or(a.status = 'checked' and a.approval_status = 'rejected'
            and a.revision_deadline_at is not null and a.revision_deadline_at > now())
  into v_n, v_a, v_pending, v_awaiting
  from public.assignments a
  where a.student_id = p_student_id
    and a.type = 'daily'
    and a.scheduled_date between p_week_start and p_week_start + 6;

  v_n := coalesce(v_n, 0);
  v_a := coalesce(v_a, 0);
  v_pending := coalesce(v_pending, false);
  v_awaiting := coalesce(v_awaiting, false);

  select count(*) filter (where status = 'requested'), count(*) filter (where status = 'consumed')
    into v_requested, v_consumed
    from public.weekly_shield_uses
   where student_id = p_student_id and week_start = p_week_start;

  v_requested := coalesce(v_requested, 0);
  v_consumed := coalesce(v_consumed, 0);
  -- Резерв либо активен (requested), либо списан (consumed) — состояния не пересекаются.
  -- До финализации E показывает предварительный результат с ВЫБРАННЫМИ щитами.
  v_shields := v_requested + v_consumed;
  v_e := least(v_n, v_a + v_shields, 7);

  if v_pending then
    v_status := 'pending_review';
  elsif v_awaiting then
    v_status := 'awaiting_student';
  else
    v_status := 'open';
  end if;

  insert into public.student_week_results as r
    (student_id, week_start, available_daily_count, approved_daily_count,
     requested_shields, shields_used, effective_daily_count, status)
  values
    (p_student_id, p_week_start, v_n, v_a, v_requested, v_consumed, v_e, v_status)
  on conflict (student_id, week_start) do update
    set available_daily_count = excluded.available_daily_count,
        approved_daily_count  = excluded.approved_daily_count,
        requested_shields     = excluded.requested_shields,
        shields_used          = excluded.shields_used,
        effective_daily_count = excluded.effective_daily_count,
        status                = excluded.status,
        updated_at            = now()
  returning * into v_row;

  return v_row;
end;
$function$;

-- finalize_student_week — идемпотентная финализация (SPEC §6.3, §7.2, §7.3).
-- Одна транзакция: пересчёт → проверка окон → списание щитов → фиксация итога.
-- НАГРАДУ НЕ НАЧИСЛЯЕТ: reward_amount сохраняется, add_huikons вызовет W09.
-- Повторный вызов возвращает существующий результат без второго списания.
CREATE OR REPLACE FUNCTION public.finalize_student_week(p_student_id bigint, p_week_start date)
 RETURNS public.student_week_results
 LANGUAGE plpgsql
AS $function$
declare
  v_row      public.student_week_results%rowtype;
  v_qty      integer;
  v_consume  integer;
  v_e        integer;
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

  -- N < 4 — нейтральная неделя: без награды, цепочка не рвётся; резервы освобождаются,
  -- щиты не тратятся впустую (SPEC §3, ECONOMY_V2 §5.1-5.2).
  if v_row.available_daily_count < 4 then
    update public.weekly_shield_uses
       set status = 'cancelled', cancelled_at = now(), updated_at = now()
     where student_id = p_student_id and week_start = p_week_start and status = 'requested';

    update public.student_week_results
       set status = 'neutral',
           -- null, а не false: нейтральная неделя не успешная и НЕ слабая — она пропускается
           -- в последовательности и не ломает её (SPEC §3, §8).
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

    -- Невыполнимые резервы (запас пропал) снимаются, а не списываются.
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

  return v_row;
end;
$function$;

-- finalize_due_student_weeks — пакетная финализация всех недель, у которых закрыты все окна.
-- W04 создаёт и проверяет её вручную; расписание (Supabase Cron каждые 30-60 минут) включает
-- W09 одновременно с cutover_at (SPEC §6.3). Возвращает число закрытых недель.
CREATE OR REPLACE FUNCTION public.finalize_due_student_weeks()
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
declare
  v_count integer := 0;
  v_row   public.student_week_results%rowtype;
  r       record;
begin
  for r in
    select student_id, week_start
      from public.student_week_results
     where status not in ('finalized', 'neutral')
       and now() >= public.next_monday_msk(week_start)
     order by week_start, student_id
  loop
    v_row := public.finalize_student_week(r.student_id, r.week_start);
    if v_row.status in ('finalized', 'neutral') then
      v_count := v_count + 1;
    end if;
  end loop;

  return v_count;
end;
$function$;
