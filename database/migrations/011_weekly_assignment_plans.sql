-- =============================================================================
-- 011_weekly_assignment_plans.sql — недельные планы и серверная материализация
-- (Bot 2.0, Stage 2.5, карточка W01; SPEC_STAGE2_5.md §§3–5, 13)
--
-- Зачем: отделить шаблон недельного плана от персонального прогресса.
-- Сейчас scheduleWeek() в teacher.html размножает контент недели по строке
-- assignments на каждого ученика; новый ученик, смена группы и публикация
-- all/group не имеют единого алгоритма. Эта миграция вводит weekly_plans /
-- weekly_plan_items как источник контента и один идемпотентный серверный
-- алгоритм материализации. assignments остаётся персональным фактом задания
-- и единственным владельцем статуса сдачи. Legacy-строки (plan_item_id = null)
-- не изменяются и не удаляются.
--
-- Состав:
--   0. Аудит (до DDL): RAISE NOTICE о legacy-дублях daily
--      (student_id, scheduled_date) и weekly (student_id, week_label).
--      Дубли НЕ блокируют миграцию: все новые уникальности частичные
--      (where plan_item_id is not null), а у всех существующих строк
--      plan_item_id = null.
--   1. weekly_plans / weekly_plan_items + уникальности активных строк/слотов.
--   2. Nullable-поля assignments: plan_item_id, task_count, first_submitted_at,
--      revision_deadline_at, revision_count (дедлайны/возвраты заполняются
--      начиная с W04 — здесь только схема) + частичные уникальности.
--   3. sync_student_week_assignments — единственный алгоритм материализации
--      (публикация, редактирование, отмена, новый ученик, смена группы).
--   4. publish_weekly_plan (публикация И редактирование — upsert по слотам),
--      cancel_weekly_plan; синхронизация учеников той же транзакцией.
--   5. Trigger на insert students и update students.group_name.
--
-- Ключевые решения:
--   * Приоритет group над all — ПО СЛОТУ (SPEC §5.1): группа может
--     переопределить одну среду, остальные дни придут из плана all.
--   * «Начатая» строка = status <> 'assigned' ИЛИ submitted_at / photo_url /
--     first_submitted_at не null. Начатая история неприкосновенна.
--   * Правка/удаление существующего daily-item текущей недели, чей день уже
--     наступил (slot_date <= today MSK), запрещены (SPEC §5.5, «редактирование
--     текущей daily после наступления дня запрещено»). ДОБАВЛЕНИЕ нового item
--     на сегодняшний слот разрешено (согласовано с §5.3: новичок получает daily
--     от today); добавление на прошедшие дни запрещено.
--   * Публикация заменяет/удаляет только БУДУЩИЕ неначатые daily-строки
--     (с завтра, SPEC §5.2); смена группы — с сегодня (SPEC §5.4); ВСТАВКА
--     отсутствующих строк — всегда от сегодня (SPEC §5.3). weekly меняется,
--     пока конкретная персональная строка не начата (SPEC §5.5), без гейта
--     по дате.
--   * Материализация пишет activation_status = 'scheduled' + scheduled_date:
--     существующая активация (checkAndActivateAssignments() в index.html,
--     эффективная активность в main.py) подхватывает плановые строки без
--     изменения клиентов. week_label = to_char(week_start, 'YYYY-MM-DD');
--     assigned_group = group_name плана либо 'Все ученики' — тот же снимок
--     аудитории, что у legacy scheduleWeek().
--   * Мультивыбор групп в UI = отдельный вызов publish_weekly_plan на каждую
--     группу (SPEC §4.1), а не строка «Группа A, Группа B».
--   * Повторная публикация тех же данных не создаёт дублей: item'ы сравниваются
--     по контенту, вставка персональных строк идёт с on conflict do nothing
--     по (student_id, plan_item_id).
--   * Удалённый из плана item получает active = false (история не уничтожается);
--     его неначатые персональные строки пересобираются на fallback или удаляются.
--
-- Повторный запуск миграции безопасен (if not exists / or replace /
-- drop trigger if exists; check-констрейнты assignments — через DO-блок).
-- RLS у новых таблиц выключен, как у всех таблиц проекта (T10).
-- =============================================================================

-- --- 0. Аудит legacy-дублей (до DDL; только документирование) ----------------

do $$
declare
  v_cnt bigint;
  r record;
begin
  select count(*) into v_cnt from (
    select student_id, scheduled_date
      from public.assignments
     where type = 'daily' and scheduled_date is not null
     group by student_id, scheduled_date
    having count(*) > 1
  ) d;
  raise notice 'W01-аудит: групп legacy-дублей daily (student_id, scheduled_date): %', v_cnt;

  for r in
    select student_id, scheduled_date, count(*) as cnt
      from public.assignments
     where type = 'daily' and scheduled_date is not null
     group by student_id, scheduled_date
    having count(*) > 1
     order by student_id, scheduled_date
     limit 20
  loop
    raise notice '  daily-дубль: student_id=%, scheduled_date=%, строк=%',
      r.student_id, r.scheduled_date, r.cnt;
  end loop;

  select count(*) into v_cnt from (
    select student_id, week_label
      from public.assignments
     where type = 'weekly' and week_label is not null
     group by student_id, week_label
    having count(*) > 1
  ) d;
  raise notice 'W01-аудит: групп legacy-дублей weekly (student_id, week_label): %', v_cnt;

  for r in
    select student_id, week_label, count(*) as cnt
      from public.assignments
     where type = 'weekly' and week_label is not null
     group by student_id, week_label
    having count(*) > 1
     order by student_id, week_label
     limit 20
  loop
    raise notice '  weekly-дубль: student_id=%, week_label=%, строк=%',
      r.student_id, r.week_label, r.cnt;
  end loop;

  raise notice 'W01-аудит: дубли только документируются, ничего не удаляется. Новые уникальности частичные (plan_item_id is not null) — legacy-строки (plan_item_id = null) их не нарушают.';
end $$;

-- --- 1. Шаблон недельного плана ----------------------------------------------

-- weekly_plans — одна строка = один план одной аудитории на одну неделю (SPEC §4.1).
create table if not exists public.weekly_plans (
  id            uuid         primary key default gen_random_uuid(),
  week_start    date         not null check (extract(isodow from week_start) = 1),
  audience_type text         not null check (audience_type in ('all', 'group')),
  group_name    text,
  status        text         not null default 'published'
                             check (status in ('published', 'cancelled')),
  created_at    timestamptz  not null default now(),
  updated_at    timestamptz  not null default now(),
  check ((audience_type = 'all'   and group_name is null)
      or (audience_type = 'group' and group_name is not null and btrim(group_name) <> ''))
);

-- Одна АКТИВНАЯ строка на (week_start, audience_type, group_name);
-- отменённые планы остаются историей и не мешают переизданию.
create unique index if not exists uq_weekly_plans_active_all
  on public.weekly_plans (week_start)
  where status = 'published' and audience_type = 'all';
create unique index if not exists uq_weekly_plans_active_group
  on public.weekly_plans (week_start, group_name)
  where status = 'published' and audience_type = 'group';

alter table public.weekly_plans disable row level security;  -- как все таблицы проекта (T10)

-- weekly_plan_items — слот плана: один daily на номер дня, один weekly (SPEC §4.2).
create table if not exists public.weekly_plan_items (
  id              uuid         primary key default gen_random_uuid(),
  plan_id         uuid         not null references public.weekly_plans (id),
  type            text         not null check (type in ('daily', 'weekly')),
  day_of_week     integer,
  title           text         not null check (btrim(title) <> ''),
  content_url     text         not null check (btrim(content_url) <> ''),
  teacher_comment text,
  task_count      integer      check (task_count is null or task_count > 0),
  active          boolean      not null default true,
  created_at      timestamptz  not null default now(),
  updated_at      timestamptz  not null default now(),
  check ((type = 'daily'  and day_of_week between 1 and 7)
      or (type = 'weekly' and day_of_week is null))
);

-- Один активный слот внутри плана; деактивированные item'ы — история.
create unique index if not exists uq_weekly_plan_items_daily_slot
  on public.weekly_plan_items (plan_id, day_of_week)
  where active and type = 'daily';
create unique index if not exists uq_weekly_plan_items_weekly_slot
  on public.weekly_plan_items (plan_id)
  where active and type = 'weekly';

alter table public.weekly_plan_items disable row level security;

-- --- 2. Расширение assignments (SPEC §4.3) ------------------------------------

alter table public.assignments
  add column if not exists plan_item_id         uuid references public.weekly_plan_items (id),
  add column if not exists task_count           integer,
  add column if not exists first_submitted_at   timestamptz,
  add column if not exists revision_deadline_at timestamptz,
  add column if not exists revision_count       integer;

do $$
begin
  if not exists (select 1 from pg_constraint
                  where conname = 'assignments_task_count_positive'
                    and conrelid = 'public.assignments'::regclass) then
    alter table public.assignments
      add constraint assignments_task_count_positive
      check (task_count is null or task_count > 0);
  end if;
  if not exists (select 1 from pg_constraint
                  where conname = 'assignments_revision_count_nonnegative'
                    and conrelid = 'public.assignments'::regclass) then
    alter table public.assignments
      add constraint assignments_revision_count_nonnegative
      check (revision_count is null or revision_count >= 0);
  end if;
end $$;

-- Частичные уникальности новых плановых строк; legacy (plan_item_id = null)
-- под них не попадает и миграцию не блокирует (SPEC §4.3).
create unique index if not exists uq_assignments_plan_daily
  on public.assignments (student_id, scheduled_date)
  where plan_item_id is not null and type = 'daily';
create unique index if not exists uq_assignments_plan_weekly
  on public.assignments (student_id, week_label)
  where plan_item_id is not null and type = 'weekly';
create unique index if not exists uq_assignments_plan_item
  on public.assignments (student_id, plan_item_id)
  where plan_item_id is not null;

create index if not exists idx_assignments_plan_item
  on public.assignments (plan_item_id)
  where plan_item_id is not null;

-- --- 3. Материализация: один ученик × одна неделя -----------------------------

-- sync_student_week_assignments — единственный алгоритм материализации (SPEC §5).
-- Вызывается публикацией/редактированием/отменой плана и триггером students.
--
--   p_replace_from — с какой scheduled_date разрешено заменять/удалять
--   НЕНАЧАТЫЕ daily-строки: публикация и отмена передают завтра (SPEC §5.2,
--   «только будущие»), смена группы/новый ученик — сегодня (SPEC §5.3–5.4;
--   null = сегодня). Вставка отсутствующих строк — всегда от сегодня.
--   weekly заменяется/удаляется, пока строка не начата, без гейта по дате
--   (SPEC §5.5).
create or replace function public.sync_student_week_assignments(
  p_student_id   bigint,
  p_week_start   date,
  p_replace_from date default null
) returns void
 LANGUAGE plpgsql
AS $function$
declare
  v_today        date := (now() at time zone 'Europe/Moscow')::date;
  v_week_label   text;
  v_insert_from  date;
  v_replace_from date;
  v_group        text;
  v_eff_ids      uuid[] := '{}';
  v_slot_date    date;
  v_existing     public.assignments%rowtype;
  v_started      boolean;
  r              record;
begin
  if p_week_start is null or extract(isodow from p_week_start) <> 1 then
    raise exception 'week_start % — не понедельник', p_week_start;
  end if;

  -- Прошедшие недели не материализуются и не переписываются (SPEC §5.3).
  if p_week_start + 6 < v_today then
    return;
  end if;

  select group_name into v_group
    from public.students
    where telegram_id = p_student_id;
  if not found then
    raise exception 'Ученик % не найден', p_student_id;
  end if;

  v_week_label   := to_char(p_week_start, 'YYYY-MM-DD');
  v_insert_from  := greatest(p_week_start, v_today);
  v_replace_from := greatest(p_week_start, coalesce(p_replace_from, v_today));

  -- Эффективный item на каждый слот: item точной группы ученика,
  -- иначе item плана all, иначе слота нет (SPEC §5.1, приоритет по слоту).
  for r in
    with candidate_items as (
      select i.id, i.type, i.day_of_week, i.title, i.content_url,
             i.teacher_comment, i.task_count, p.audience_type, p.group_name
        from public.weekly_plan_items i
        join public.weekly_plans p on p.id = i.plan_id
       where p.week_start = p_week_start
         and p.status = 'published'
         and i.active
         and (p.audience_type = 'all'
              or (v_group is not null
                  and p.audience_type = 'group'
                  and p.group_name = v_group))
    )
    select distinct on (c.type, coalesce(c.day_of_week, 0))
           c.id as item_id, c.type, c.day_of_week, c.title, c.content_url,
           c.teacher_comment, c.task_count,
           case when c.audience_type = 'group' then c.group_name
                else 'Все ученики' end as aud_label
      from candidate_items c
     order by c.type, coalesce(c.day_of_week, 0),
              (c.audience_type = 'group') desc
  loop
    v_eff_ids := v_eff_ids || r.item_id;

    if r.type = 'daily' then
      v_slot_date := p_week_start + (r.day_of_week - 1);
    else
      v_slot_date := p_week_start;
    end if;

    -- Существующая плановая строка слота (максимум одна — частичные уникальности).
    select a.* into v_existing
      from public.assignments a
     where a.student_id = p_student_id
       and a.plan_item_id is not null
       and ((r.type = 'daily'  and a.type = 'daily'  and a.scheduled_date = v_slot_date)
         or (r.type = 'weekly' and a.type = 'weekly' and a.week_label = v_week_label))
     limit 1
     for update;

    if found then
      v_started := v_existing.status is distinct from 'assigned'
                or v_existing.submitted_at is not null
                or v_existing.photo_url is not null
                or v_existing.first_submitted_at is not null;

      if v_started then
        continue;  -- начатая история неприкосновенна (SPEC §5.4)
      end if;

      if r.type = 'daily' and v_slot_date < v_replace_from then
        continue;  -- замена daily разрешена только с v_replace_from
      end if;

      if v_existing.plan_item_id       is distinct from r.item_id
         or v_existing.title           is distinct from r.title
         or v_existing.content_url     is distinct from r.content_url
         or v_existing.teacher_comment is distinct from r.teacher_comment
         or v_existing.task_count      is distinct from r.task_count
         or v_existing.assigned_group  is distinct from r.aud_label then
        update public.assignments
           set plan_item_id    = r.item_id,
               title           = r.title,
               content_url     = r.content_url,
               teacher_comment = r.teacher_comment,
               task_count      = r.task_count,
               assigned_group  = r.aud_label
         where id = v_existing.id;
      end if;
    else
      if r.type = 'daily' and v_slot_date < v_insert_from then
        continue;  -- прошлые дни не создаются и не входят в N (SPEC §5.3)
      end if;

      insert into public.assignments
        (student_id, type, title, content_url, teacher_comment, day_of_week,
         week_label, scheduled_date, activation_status, status, assigned_group,
         plan_item_id, task_count)
      values
        (p_student_id, r.type, r.title, r.content_url, r.teacher_comment,
         r.day_of_week, v_week_label, v_slot_date, 'scheduled', 'assigned',
         r.aud_label, r.item_id, r.task_count)
      on conflict (student_id, plan_item_id) where plan_item_id is not null
      do nothing;  -- гонка параллельных синхронизаций не даёт второй строки
    end if;
  end loop;

  -- Неначатые плановые строки недели без эффективного item (item деактивирован,
  -- план отменён, в новой аудитории слота нет) удаляются: daily — не раньше
  -- v_replace_from, weekly — пока не начата (SPEC §5.4–5.5). Legacy-строки
  -- (plan_item_id = null) не затрагиваются.
  delete from public.assignments a
   where a.student_id = p_student_id
     and a.plan_item_id is not null
     and a.week_label = v_week_label
     and a.status = 'assigned'
     and a.submitted_at is null
     and a.photo_url is null
     and a.first_submitted_at is null
     and (a.type <> 'daily'
          or (a.scheduled_date is not null and a.scheduled_date >= v_replace_from))
     and not (a.plan_item_id = any (v_eff_ids));
end;
$function$;

-- --- 4. RPC публикации/редактирования и отмены плана ---------------------------

-- publish_weekly_plan — публикация И редактирование (upsert item'ов по слотам)
-- одной транзакцией с синхронизацией затронутых учеников (SPEC §5.2, §5.5).
-- Мультивыбор групп в UI = отдельный вызов на каждую группу (SPEC §4.1).
-- p_items: json-массив [{type, day_of_week, title, content_url,
-- teacher_comment, task_count}]; слоты, отсутствующие в p_items, деактивируются
-- (кроме замороженных daily текущей недели, чей день уже наступил, — они
-- молча сохраняются). Повторный вызов с теми же данными ничего не меняет.
create or replace function public.publish_weekly_plan(
  p_week_start    date,
  p_audience_type text,
  p_group_name    text default null,
  p_items         jsonb default '[]'::jsonb
) returns json
 LANGUAGE plpgsql
AS $function$
declare
  v_today        date := (now() at time zone 'Europe/Moscow')::date;
  v_plan         public.weekly_plans%rowtype;
  v_item         public.weekly_plan_items%rowtype;
  itm            jsonb;
  v_type         text;
  v_dow          integer;
  v_title        text;
  v_url          text;
  v_comment      text;
  v_task_count   integer;
  v_slot_key     text;
  v_slot_date    date;
  v_touched      text[] := '{}';
  v_replace_from date;
  v_synced       integer := 0;
  v_active_items integer;
  r              record;
begin
  if p_week_start is null or extract(isodow from p_week_start) <> 1 then
    raise exception 'week_start должен быть понедельником';
  end if;
  if p_week_start + 6 < v_today then
    raise exception 'Неделя % уже прошла — публикация и редактирование запрещены', p_week_start;
  end if;
  if p_audience_type is null or p_audience_type not in ('all', 'group') then
    raise exception 'audience_type должен быть all или group';
  end if;
  if p_audience_type = 'group' and (p_group_name is null or btrim(p_group_name) = '') then
    raise exception 'Для группового плана нужна непустая группа';
  end if;
  if p_audience_type = 'all' and p_group_name is not null then
    raise exception 'Для плана all группа не указывается';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' then
    raise exception 'items должен быть json-массивом';
  end if;

  -- Активный план аудитории; отменённые остаются историей — создаётся новый.
  select * into v_plan
    from public.weekly_plans
   where week_start = p_week_start
     and audience_type = p_audience_type
     and group_name is not distinct from p_group_name
     and status = 'published'
   for update;

  if not found then
    insert into public.weekly_plans (week_start, audience_type, group_name, status)
      values (p_week_start, p_audience_type, p_group_name, 'published')
      returning * into v_plan;
  end if;

  -- Upsert item'ов по слотам.
  for itm in select value from jsonb_array_elements(p_items)
  loop
    v_type := itm->>'type';
    if v_type is null or v_type not in ('daily', 'weekly') then
      raise exception 'Тип задания должен быть daily или weekly';
    end if;

    if v_type = 'daily' then
      v_dow := (itm->>'day_of_week')::integer;
      if v_dow is null or v_dow < 1 or v_dow > 7 then
        raise exception 'day_of_week для daily должен быть 1–7';
      end if;
      v_slot_key  := 'daily-' || v_dow;
      v_slot_date := p_week_start + (v_dow - 1);
    else
      if itm->>'day_of_week' is not null then
        raise exception 'day_of_week для weekly не указывается';
      end if;
      v_dow := null;
      v_slot_key  := 'weekly';
      v_slot_date := p_week_start;
    end if;

    if v_slot_key = any (v_touched) then
      raise exception 'Слот % указан в items дважды', v_slot_key;
    end if;
    v_touched := v_touched || v_slot_key;

    v_title      := btrim(coalesce(itm->>'title', ''));
    v_url        := btrim(coalesce(itm->>'content_url', ''));
    v_comment    := nullif(btrim(coalesce(itm->>'teacher_comment', '')), '');
    v_task_count := (itm->>'task_count')::integer;
    if v_title = '' or v_url = '' then
      raise exception 'У задания слота % должны быть название и ссылка', v_slot_key;
    end if;
    if v_task_count is not null and v_task_count <= 0 then
      raise exception 'task_count должен быть положительным числом или null';
    end if;

    select * into v_item
      from public.weekly_plan_items
     where plan_id = v_plan.id
       and active
       and type = v_type
       and day_of_week is not distinct from v_dow
     for update;

    if found then
      if v_item.title = v_title
         and v_item.content_url = v_url
         and v_item.teacher_comment is not distinct from v_comment
         and v_item.task_count is not distinct from v_task_count then
        continue;  -- идемпотентный повтор публикации
      end if;
      -- Редактирование текущей daily после наступления дня запрещено (SPEC §5.5).
      if v_type = 'daily' and v_slot_date <= v_today then
        raise exception 'День % уже наступил — редактирование этого daily запрещено', v_slot_date;
      end if;
      update public.weekly_plan_items
         set title           = v_title,
             content_url     = v_url,
             teacher_comment = v_comment,
             task_count      = v_task_count,
             updated_at      = now()
       where id = v_item.id;
    else
      -- Новый item на прошедший день не добавляется; на сегодня — разрешён
      -- (согласовано с SPEC §5.3: новичок получает daily от today).
      if v_type = 'daily' and v_slot_date < v_today then
        raise exception 'День % уже прошёл — добавить daily задним числом нельзя', v_slot_date;
      end if;
      insert into public.weekly_plan_items
        (plan_id, type, day_of_week, title, content_url, teacher_comment, task_count)
      values
        (v_plan.id, v_type, v_dow, v_title, v_url, v_comment, v_task_count);
    end if;
  end loop;

  -- Слоты, отсутствующие в новой публикации: active = false (SPEC §5.5).
  -- Замороженные daily (день наступил) молча сохраняются.
  for r in
    select i.id, i.type,
           case when i.type = 'daily' then p_week_start + (i.day_of_week - 1)
                else p_week_start end as slot_date,
           case when i.type = 'daily' then 'daily-' || i.day_of_week
                else 'weekly' end as slot_key
      from public.weekly_plan_items i
     where i.plan_id = v_plan.id
       and i.active
  loop
    if r.slot_key = any (v_touched) then
      continue;
    end if;
    if r.type = 'daily' and r.slot_date <= v_today then
      continue;
    end if;
    update public.weekly_plan_items
       set active = false, updated_at = now()
     where id = r.id;
  end loop;

  update public.weekly_plans set updated_at = now() where id = v_plan.id;

  -- Синхронизация затронутых учеников той же транзакцией (SPEC §5.2):
  -- замена/удаление только будущих неначатых daily-строк (с завтра).
  v_replace_from := greatest(p_week_start, v_today + 1);
  for r in
    select telegram_id
      from public.students
     where p_audience_type = 'all' or group_name = p_group_name
  loop
    perform public.sync_student_week_assignments(r.telegram_id, p_week_start, v_replace_from);
    v_synced := v_synced + 1;
  end loop;

  select count(*) into v_active_items
    from public.weekly_plan_items
   where plan_id = v_plan.id and active;

  return json_build_object(
    'plan_id',         v_plan.id,
    'week_start',      v_plan.week_start,
    'audience_type',   v_plan.audience_type,
    'group_name',      v_plan.group_name,
    'active_items',    v_active_items,
    'students_synced', v_synced
  );
end;
$function$;

-- cancel_weekly_plan — отмена плана без удаления истории (SPEC §5.5):
-- начатые строки не трогаются; неначатые будущие пересобираются на fallback
-- (план all) либо удаляются. Повторная отмена идемпотентна.
create or replace function public.cancel_weekly_plan(p_plan_id uuid)
 RETURNS json
 LANGUAGE plpgsql
AS $function$
declare
  v_today        date := (now() at time zone 'Europe/Moscow')::date;
  v_plan         public.weekly_plans%rowtype;
  v_replace_from date;
  v_synced       integer := 0;
  r              record;
begin
  select * into v_plan
    from public.weekly_plans
    where id = p_plan_id
    for update;
  if not found then
    raise exception 'План % не найден', p_plan_id;
  end if;
  if v_plan.status = 'cancelled' then
    return json_build_object('plan_id', v_plan.id, 'status', 'cancelled', 'students_synced', 0);
  end if;
  if v_plan.week_start + 6 < v_today then
    raise exception 'Неделя % уже прошла — отменять её план нельзя', v_plan.week_start;
  end if;

  update public.weekly_plans
     set status = 'cancelled', updated_at = now()
   where id = v_plan.id;

  v_replace_from := greatest(v_plan.week_start, v_today + 1);
  for r in
    select telegram_id
      from public.students
     where v_plan.audience_type = 'all' or group_name = v_plan.group_name
  loop
    perform public.sync_student_week_assignments(r.telegram_id, v_plan.week_start, v_replace_from);
    v_synced := v_synced + 1;
  end loop;

  return json_build_object('plan_id', v_plan.id, 'status', 'cancelled', 'students_synced', v_synced);
end;
$function$;

-- --- 5. Trigger: новый ученик и смена группы (SPEC §5.3–5.4) -------------------

-- Синхронизирует текущую и опубликованные будущие недели. Пишет только в
-- assignments — рекурсия по students невозможна.
create or replace function public.trg_students_sync_weekly_plans()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
declare
  v_today date := (now() at time zone 'Europe/Moscow')::date;
  r record;
begin
  for r in
    select distinct week_start
      from public.weekly_plans
     where status = 'published'
       and week_start + 6 >= v_today
  loop
    -- Новый ученик и смена группы: замена/вставка от сегодня (SPEC §5.3–5.4).
    perform public.sync_student_week_assignments(
      new.telegram_id, r.week_start, greatest(r.week_start, v_today));
  end loop;
  return new;
end;
$function$;

drop trigger if exists trg_students_weekly_plans_insert on public.students;
create trigger trg_students_weekly_plans_insert
  after insert on public.students
  for each row
  execute function public.trg_students_sync_weekly_plans();

drop trigger if exists trg_students_weekly_plans_group_change on public.students;
create trigger trg_students_weekly_plans_group_change
  after update of group_name on public.students
  for each row
  when (old.group_name is distinct from new.group_name)
  execute function public.trg_students_sync_weekly_plans();
