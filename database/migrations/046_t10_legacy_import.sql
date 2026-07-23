-- =============================================================================
-- 046_t10_legacy_import.sql — T10-10D (перенос данных действующих учеников)
-- (Bot 2.0, T10; карточка tasks/T10-10D.md; решения владельца Q1-Q7 в §7 карточки)
--
-- Зачем. Bot 2.0 заменяет код действующего ученического бота с сохранением аудитории. Данные
-- действующих учеников переезжают из боевого проекта в Bot 2.0. Эта миграция создаёт ТОЛЬКО
-- инструмент переноса: staging-схему, идемпотентный импорт с dry-run, отчёт и точечный откат.
-- Ни одной строки боевых данных она не переносит — это делает владелец отдельным вызовом.
--
-- Схема называется legacy_import, а не import: IMPORT — ключевое слово SQL-стандарта
-- (IMPORT FOREIGN SCHEMA), формально unreserved, но неоднозначно читается в каждом обращении.
-- Схема НЕ экспонируется в Data API и дополнительно закрыта revoke; функции SECURITY DEFINER,
-- доступны только service_role и владельцу из SQL Editor.
--
-- ЧТО ПЕРЕНОСИТСЯ (решения владельца):
--   students          — telegram_id, name, telegram_username, group_name;
--   huikons           — 1:1 через add_huikons с причиной legacy_opening_balance (Q5);
--   student_payments  — payment_date как есть (Q1);
--   mock_exam_results — ВСЕ legacy-строки 1:1 как архив (Q2);
--   weekly_mock_exams — только пригодные, по одной на неделю, БЕЗ наград и season points (Q2);
--   parent_links      — подтверждённые связки (Q7);
--   assignments       — только незакрытые: активные, на проверке, возвращённые (Q3).
--
-- ЧТО НЕ ПЕРЕНОСИТСЯ: rating (иная семантика), current_streak, lives, last_submission_date_msk,
-- balance_history построчно, завершённые задания, homework_submissions, bot_notification_state.
--
-- ВАЖНО ПРО ПРИВЕДЕНИЕ ТИПА. score в legacy — text, там встречаются пометки вроде «не писал».
-- Условия вида "score !~ regex or score::int not between..." небезопасны: PostgreSQL не
-- гарантирует порядок вычисления OR/AND и может выполнить приведение до проверки регуляркой,
-- уронив весь импорт. Поэтому число вычисляется ОДИН раз через CASE (гарантированное короткое
-- замыкание) в CTE numeric_src, а дальше используется уже готовый score_int.
-- =============================================================================

create schema if not exists legacy_import;
revoke all on schema legacy_import from anon, authenticated;
grant usage on schema legacy_import to service_role;

-- --- 1. Staging: точные копии колонок источника ------------------------------------------------
-- Заполняются владельцем из боевого проекта. Ключи и ограничения минимальны: staging принимает
-- данные КАК ЕСТЬ, вся валидация — в импорте.

create table if not exists legacy_import.legacy_students (
  telegram_id       bigint primary key,
  name              text,
  telegram_username text,
  group_name        text,
  huikons           integer,
  rating            integer,   -- принимается, но НЕ переносится (Q5)
  current_streak    integer,   -- принимается, но НЕ переносится (Q6)
  lives             integer,   -- принимается, но НЕ переносится (Q6)
  loaded_at         timestamptz not null default now()
);

create table if not exists legacy_import.legacy_payments (
  student_id   bigint primary key,
  payment_date date,
  loaded_at    timestamptz not null default now()
);

-- id нужен: он участвует в детерминированном tie-break при коллизии недели (§3.1 карточки).
create table if not exists legacy_import.legacy_mock_exams (
  id         uuid primary key,
  student_id bigint not null,
  exam_name  text   not null,
  score      text,
  exam_date  date,
  updated_at timestamptz,
  created_at timestamptz,
  loaded_at  timestamptz not null default now()
);

create table if not exists legacy_import.legacy_parent_links (
  parent_telegram_id bigint not null,
  student_id         bigint not null,
  linked_at          timestamptz,
  loaded_at          timestamptz not null default now(),
  primary key (parent_telegram_id, student_id)
);

create table if not exists legacy_import.legacy_assignments (
  id                uuid primary key,
  student_id        bigint,
  type              text,
  title             text,
  content_url       text,
  teacher_comment   text,
  day_of_week       integer,
  week_label        text,
  scheduled_date    date,
  activation_status text,
  status            text,
  created_at        timestamptz,
  submitted_at      timestamptz,
  checked_at        timestamptz,
  photo_url         text,
  teacher_feedback  text,
  approval_status   text,
  assigned_group    text,
  loaded_at         timestamptz not null default now()
);

-- --- 2. Журнал прогонов -----------------------------------------------------------------------
-- Единственный источник правды для отчёта и точечного отката: что именно вставил КОНКРЕТНЫЙ
-- прогон. Строки, созданные живыми учениками после импорта, здесь не значатся и откатом не
-- затрагиваются. detail хранит всё, что нужно откату, поэтому откат не зависит от staging.
create table if not exists legacy_import.import_log (
  id          bigint generated by default as identity primary key,
  run_id      uuid        not null,
  dry_run     boolean     not null,
  table_name  text        not null,
  entity_key  text        not null,   -- telegram_id / uuid / составной ключ
  action      text        not null check (action in ('inserted','skipped','conflict','rolled_back')),
  detail      jsonb,
  created_at  timestamptz not null default now()
);
create index if not exists idx_import_log_run on legacy_import.import_log (run_id, table_name);

revoke all on all tables in schema legacy_import from anon, authenticated;

-- --- 3. Отчёт ----------------------------------------------------------------------------------
-- Определён до импорта: migrate_legacy возвращает его же в конце.
-- Четыре обязательные строки по пробникам (карточка §3.1) считаются здесь:
-- недель с несколькими результатами, отброшено только из canonical, выбрано точек, полных tie.
create or replace function legacy_import.report(p_run_id uuid)
 returns json
 language sql
 security definer
 set search_path = public, pg_temp
as $function$
  select json_build_object(
    'run_id', p_run_id,
    'dry_run', (select bool_or(dry_run) from legacy_import.import_log where run_id = p_run_id),
    'by_table', (
      select coalesce(json_agg(t order by t.table_name), '[]'::json) from (
        select table_name,
               count(*) filter (where action = 'inserted')    as inserted,
               count(*) filter (where action = 'skipped')     as skipped,
               count(*) filter (where action = 'conflict')    as conflicts,
               count(*) filter (where action = 'rolled_back') as rolled_back
          from legacy_import.import_log
         where run_id = p_run_id
         group by table_name) t
    ),
    'mock_conflicts', (
      select coalesce(json_object_agg(category, cnt), '{}'::json) from (
        select detail ->> 'category' as category, count(*) as cnt
          from legacy_import.import_log
         where run_id = p_run_id and table_name = 'weekly_mock_exams'
           and action = 'conflict' and detail ->> 'category' is not null
         group by 1) c
    ),
    'weeks_with_multiple_results', (
      select count(*) from (
        select distinct detail ->> 'student_id' as sid, detail ->> 'week_start' as wk
          from legacy_import.import_log
         where run_id = p_run_id and table_name = 'weekly_mock_exams'
           and coalesce((detail ->> 'rows_in_week')::int, 1) > 1) w
    ),
    'rows_dropped_from_canonical_only', (
      select count(*) from legacy_import.import_log
       where run_id = p_run_id and table_name = 'weekly_mock_exams'
         and detail ->> 'category' = 'week_collision_dropped'
    ),
    'canonical_points_chosen', (
      select count(*) from legacy_import.import_log
       where run_id = p_run_id and table_name = 'weekly_mock_exams'
         and action in ('inserted','skipped')
    ),
    'full_ties_resolved_by_id', (
      select count(*) from legacy_import.import_log
       where run_id = p_run_id and table_name = 'weekly_mock_exams'
         and (detail ->> 'full_tie')::boolean is true
    ),
    'opening_balance_total', (
      select coalesce(sum((detail ->> 'amount')::int), 0) from legacy_import.import_log
       where run_id = p_run_id and table_name = 'opening_balance' and action = 'inserted'
    )
  );
$function$;

-- --- 4. Импорт ---------------------------------------------------------------------------------
-- p_dry_run = true (ПО УМОЛЧАНИЮ) — ни одной записи в public, только предсказания в import_log.
-- p_scope — необязательный список секций: students, payments, mock_archive, mock_canonical,
--           parent_links, assignments, opening_balance. null = все.
-- search_path = public, pg_temp: внутренняя add_huikons — SECURITY INVOKER и обращается к
-- таблицам без схемы, поэтому public обязан быть в пути.
create or replace function legacy_import.migrate_legacy(
  p_dry_run boolean default true,
  p_scope   text[]  default null,
  p_run_id  uuid    default null
)
 returns json
 language plpgsql
 security definer
 set search_path = public, pg_temp
as $function$
declare
  v_run uuid := coalesce(p_run_id, gen_random_uuid());
  r     record;
begin
  -- --- 4.1. students --------------------------------------------------------------------------
  if p_scope is null or 'students' = any(p_scope) then
    insert into legacy_import.import_log (run_id, dry_run, table_name, entity_key, action, detail)
    select v_run, p_dry_run, 'students', ls.telegram_id::text,
           case when s.telegram_id is null then 'inserted' else 'skipped' end,
           jsonb_build_object('reason',
             case when s.telegram_id is null then 'new' else 'already present in Bot 2.0' end)
      from legacy_import.legacy_students ls
      left join public.students s on s.telegram_id = ls.telegram_id;

    if not p_dry_run then
      -- rating/huikons/current_streak/lives НЕ переносятся: остаются значения по умолчанию.
      insert into public.students (telegram_id, name, telegram_username, group_name)
      select ls.telegram_id,
             nullif(btrim(ls.name), ''),
             lower(nullif(btrim(ls.telegram_username), '')),
             nullif(btrim(ls.group_name), '')
        from legacy_import.legacy_students ls
      on conflict (telegram_id) do nothing;
    end if;
  end if;

  -- --- 4.2. student_payments ------------------------------------------------------------------
  if p_scope is null or 'payments' = any(p_scope) then
    insert into legacy_import.import_log (run_id, dry_run, table_name, entity_key, action, detail)
    select v_run, p_dry_run, 'student_payments', lp.student_id::text,
           case when sp.student_id is null then 'inserted' else 'skipped' end,
           jsonb_build_object('payment_date', lp.payment_date)
      from legacy_import.legacy_payments lp
      left join public.student_payments sp on sp.student_id = lp.student_id;

    if not p_dry_run then
      insert into public.student_payments (student_id, payment_date)
      select lp.student_id, lp.payment_date from legacy_import.legacy_payments lp
      on conflict (student_id) do nothing;
    end if;
  end if;

  -- --- 4.3. mock_exam_results (архив 1:1, Q2) --------------------------------------------------
  if p_scope is null or 'mock_archive' = any(p_scope) then
    insert into legacy_import.import_log (run_id, dry_run, table_name, entity_key, action, detail)
    select v_run, p_dry_run, 'mock_exam_results',
           lm.student_id::text || '|' || lm.exam_name,
           case when mr.student_id is null then 'inserted' else 'skipped' end,
           jsonb_build_object('score', lm.score, 'exam_date', lm.exam_date)
      from legacy_import.legacy_mock_exams lm
      left join public.mock_exam_results mr
             on mr.student_id = lm.student_id and mr.exam_name = lm.exam_name;

    if not p_dry_run then
      insert into public.mock_exam_results (student_id, exam_name, score, exam_date, created_at, updated_at)
      select lm.student_id, lm.exam_name, lm.score, lm.exam_date,
             coalesce(lm.created_at, now()), coalesce(lm.updated_at, now())
        from legacy_import.legacy_mock_exams lm
      on conflict (student_id, exam_name) do nothing;
    end if;
  end if;

  -- --- 4.4. weekly_mock_exams (canonical, Q2) --------------------------------------------------
  -- БЕЗ наград: season_points_awarded = 0, ни строки в mock_exam_reward_log, ни add_huikons,
  -- ни достижений. Поэтому запись идёт напрямую, а НЕ через record_weekly_mock_exam — тот по
  -- контракту платит базу и рекорд. Единственный оправданный обход штатного примитива во всём
  -- T10, ограничен историческим импортом.
  if p_scope is null or 'mock_canonical' = any(p_scope) then

    -- 4.4a. Непригодные значения: остаются только в архиве, canonical-строку не создают.
    insert into legacy_import.import_log (run_id, dry_run, table_name, entity_key, action, detail)
    with numeric_src as (
      select lm.*,
             case when lm.score ~ '^-?[0-9]{1,3}$' then (lm.score)::int end as score_int
        from legacy_import.legacy_mock_exams lm
    )
    select v_run, p_dry_run, 'weekly_mock_exams', n.id::text, 'conflict',
           jsonb_build_object(
             'category', case when n.exam_date is null then 'no_exam_date'
                              when n.score_int is null then 'score_not_number'
                              else                          'score_out_of_range' end,
             'student_id', n.student_id, 'exam_name', n.exam_name, 'score', n.score)
      from numeric_src n
     where n.exam_date is null
        or n.score_int is null
        or n.score_int not between 0 and 100;

    -- 4.4b. Пригодные: ровно один итоговый результат на пару (ученик, неделя).
    -- Порядок выбора: exam_date -> updated_at -> created_at -> id (§3.1 карточки).
    insert into legacy_import.import_log (run_id, dry_run, table_name, entity_key, action, detail)
    with numeric_src as (
      select lm.*,
             case when lm.score ~ '^-?[0-9]{1,3}$' then (lm.score)::int end as score_int
        from legacy_import.legacy_mock_exams lm
    ),
    eligible as (
      select n.id, n.student_id, n.exam_name, n.score_int as score,
             n.exam_date, n.updated_at, n.created_at,
             public.week_start_of(n.exam_date) as wk
        from numeric_src n
       where n.exam_date is not null
         and n.score_int between 0 and 100
    ),
    ranked as (
      select e.*,
             row_number() over (partition by e.student_id, e.wk
                                order by e.exam_date  desc nulls last,
                                         e.updated_at desc nulls last,
                                         e.created_at desc nulls last,
                                         e.id desc) as rn,
             count(*) over (partition by e.student_id, e.wk) as rows_in_week,
             count(*) over (partition by e.student_id, e.wk,
                                         e.exam_date, e.updated_at, e.created_at) as same_triple
        from eligible e
    )
    select v_run, p_dry_run, 'weekly_mock_exams', rk.id::text,
           case when rk.rn > 1                then 'conflict'
                when w.student_id is not null then 'skipped'
                else                               'inserted' end,
           jsonb_build_object(
             'student_id', rk.student_id,
             'week_start', rk.wk,
             'score', rk.score,
             'rows_in_week', rk.rows_in_week,
             'category', case when rk.rn > 1 then 'week_collision_dropped' end,
             'full_tie', (rk.rn = 1 and rk.same_triple > 1),
             'reason', case when rk.rn = 1 and w.student_id is not null
                            then 'week already present in Bot 2.0' end)
      from ranked rk
      left join public.weekly_mock_exams w
             on w.student_id = rk.student_id and w.week_start = rk.wk;

    if not p_dry_run then
      with numeric_src as (
        select lm.*,
               case when lm.score ~ '^-?[0-9]{1,3}$' then (lm.score)::int end as score_int
          from legacy_import.legacy_mock_exams lm
      ),
      eligible as (
        select n.id, n.student_id, n.score_int as score,
               n.exam_date, n.updated_at, n.created_at,
               public.week_start_of(n.exam_date) as wk
          from numeric_src n
         where n.exam_date is not null
           and n.score_int between 0 and 100
      ),
      chosen as (
        select e.*, row_number() over (partition by e.student_id, e.wk
                                       order by e.exam_date  desc nulls last,
                                                e.updated_at desc nulls last,
                                                e.created_at desc nulls last,
                                                e.id desc) as rn
          from eligible e
      )
      insert into public.weekly_mock_exams (student_id, week_start, score, season_points_awarded)
      select c.student_id, c.wk, c.score, 0
        from chosen c
       where c.rn = 1
      on conflict (student_id, week_start) do nothing;
    end if;
  end if;

  -- --- 4.5. parent_links (Q7) ------------------------------------------------------------------
  if p_scope is null or 'parent_links' = any(p_scope) then
    insert into legacy_import.import_log (run_id, dry_run, table_name, entity_key, action, detail)
    select v_run, p_dry_run, 'parent_links',
           lpl.parent_telegram_id::text || '|' || lpl.student_id::text,
           case when pl.student_id is null then 'inserted' else 'skipped' end,
           jsonb_build_object('parent_telegram_id', lpl.parent_telegram_id,
                              'student_id', lpl.student_id)
      from legacy_import.legacy_parent_links lpl
      left join public.parent_links pl
             on pl.parent_telegram_id = lpl.parent_telegram_id and pl.student_id = lpl.student_id;

    if not p_dry_run then
      insert into public.parent_links (parent_telegram_id, student_id, linked_at)
      select lpl.parent_telegram_id, lpl.student_id, coalesce(lpl.linked_at, now())
        from legacy_import.legacy_parent_links lpl
      on conflict (parent_telegram_id, student_id) do nothing;
    end if;
  end if;

  -- --- 4.6. assignments: только незакрытые (Q3) ------------------------------------------------
  -- Активные (назначено и активировано/запланировано), отправленные на проверку и возвращённые
  -- на исправление. Завершённые остаются архивом старой базы. Поля W04+ (plan_item_id,
  -- task_count, revision_*) остаются NULL — legacy их не знает, частичные unique-индексы
  -- плановых строк на такие записи не распространяются.
  if p_scope is null or 'assignments' = any(p_scope) then
    insert into legacy_import.import_log (run_id, dry_run, table_name, entity_key, action, detail)
    select v_run, p_dry_run, 'assignments', la.id::text,
           case when a.id is null then 'inserted' else 'skipped' end,
           jsonb_build_object('type', la.type, 'status', la.status,
                              'approval_status', la.approval_status)
      from legacy_import.legacy_assignments la
      left join public.assignments a on a.id = la.id
     where (la.activation_status in ('active','scheduled') and la.status = 'assigned')
        or la.status = 'submitted'
        or (la.status = 'checked' and la.approval_status = 'rejected');

    if not p_dry_run then
      insert into public.assignments (
        id, student_id, type, title, content_url, teacher_comment, day_of_week, week_label,
        scheduled_date, activation_status, status, created_at, submitted_at, checked_at,
        photo_url, teacher_feedback, approval_status, assigned_group)
      select la.id, la.student_id, la.type, la.title, la.content_url, la.teacher_comment,
             la.day_of_week, la.week_label, la.scheduled_date, la.activation_status, la.status,
             coalesce(la.created_at, now()), la.submitted_at, la.checked_at,
             la.photo_url, la.teacher_feedback, la.approval_status, la.assigned_group
        from legacy_import.legacy_assignments la
       where (la.activation_status in ('active','scheduled') and la.status = 'assigned')
          or la.status = 'submitted'
          or (la.status = 'checked' and la.approval_status = 'rejected')
      on conflict (id) do nothing;
    end if;
  end if;

  -- --- 4.7. Открывающий баланс (Q5) ------------------------------------------------------------
  -- Только через add_huikons — единственный разрешённый способ менять huikons; он же пишет
  -- объяснимую строку в balance_history. Защита от повторного начисления — наличие строки с
  -- reason = 'legacy_opening_balance' у этого ученика, а не только запись в import_log.
  if p_scope is null or 'opening_balance' = any(p_scope) then
    for r in
      select ls.telegram_id, ls.huikons
        from legacy_import.legacy_students ls
       where coalesce(ls.huikons, 0) > 0
       order by ls.telegram_id
    loop
      if exists (select 1 from public.balance_history bh
                  where bh.student_id = r.telegram_id
                    and bh.reason = 'legacy_opening_balance') then
        insert into legacy_import.import_log (run_id, dry_run, table_name, entity_key, action, detail)
        values (v_run, p_dry_run, 'opening_balance', r.telegram_id::text, 'skipped',
                jsonb_build_object('reason', 'already granted', 'amount', r.huikons));

      elsif not exists (select 1 from public.students s where s.telegram_id = r.telegram_id) then
        -- В dry-run это нормальный случай: ученика ещё нет, потому что сам импорт не выполнялся.
        insert into legacy_import.import_log (run_id, dry_run, table_name, entity_key, action, detail)
        values (v_run, p_dry_run, 'opening_balance', r.telegram_id::text,
                case when p_dry_run then 'inserted' else 'conflict' end,
                jsonb_build_object('amount', r.huikons,
                                   'category', case when p_dry_run then null else 'student_missing' end));

      else
        insert into legacy_import.import_log (run_id, dry_run, table_name, entity_key, action, detail)
        values (v_run, p_dry_run, 'opening_balance', r.telegram_id::text, 'inserted',
                jsonb_build_object('amount', r.huikons));
        if not p_dry_run then
          perform public.add_huikons(r.telegram_id, r.huikons, 'legacy_opening_balance');
        end if;
      end if;
    end loop;
  end if;

  return legacy_import.report(v_run);
end;
$function$;

-- --- 5. Точечный откат -------------------------------------------------------------------------
-- Удаляет ТОЛЬКО то, что вставил конкретный прогон (action = 'inserted'). Строки, созданные
-- живыми учениками после импорта, не затрагиваются. Все ключи берутся из import_log.detail,
-- поэтому откат не зависит от того, очищен ли staging.
--
-- Баланс НЕ откатывается удалением: это нарушило бы инвариант «huikons меняются только через
-- add_huikons». Вместо этого пишется компенсирующая запись с отрицательной суммой — журнал
-- остаётся честным. add_huikons клампит баланс нулём, поэтому если ученик уже потратил часть
-- бубликов, вернётся столько, сколько есть; фактическая дельта видна в balance_history.
--
-- students удаляются последними и только если на них не появилось зависимых строк (лиговое
-- состояние, инвентарь, квесты могли возникнуть, если ученик успел войти). Это не ошибка:
-- случай фиксируется как skipped с причиной.
--
-- ВАЖНО, найдено на репетиции B2-T10D. balance_history ссылается на students, поэтому ученик,
-- получивший открывающий баланс, БЕЗ дополнительных действий неудаляем: его держат строки,
-- созданные самим импортом, а не живой активностью. Отсюда p_purge_ledger:
--   false (по умолчанию) — журнал сохраняется, такие ученики остаются и помечаются skipped.
--                          Правильный режим для боевого отката: ledger не переписывается.
--   true               — строки legacy_opening_balance* этого прогона удаляются, и ученик
--                          удаляется полностью. Режим «как будто импорта не было»: репетиция и
--                          прерванный cutover до подключения живых учеников.
-- Повторный вызов безопасен: сущности, уже отмеченные rolled_back в этом прогоне, пропускаются —
-- иначе компенсация баланса начислилась бы второй раз.
drop function if exists legacy_import.rollback_run(uuid);

create or replace function legacy_import.rollback_run(
  p_run_id       uuid,
  p_purge_ledger boolean default false
)
 returns json
 language plpgsql
 security definer
 set search_path = public, pg_temp
as $function$
declare
  r record;
begin
  if not exists (select 1 from legacy_import.import_log where run_id = p_run_id) then
    raise exception 'unknown run %', p_run_id using errcode = '22023';
  end if;
  if exists (select 1 from legacy_import.import_log
              where run_id = p_run_id and dry_run is true) then
    raise exception 'run % is a dry-run: nothing was written, nothing to roll back', p_run_id
      using errcode = '22023';
  end if;

  -- 5.1. assignments
  delete from public.assignments a
   using legacy_import.import_log l
   where l.run_id = p_run_id and l.table_name = 'assignments' and l.action = 'inserted'
     and a.id = l.entity_key::uuid;

  -- 5.2. parent_links
  delete from public.parent_links pl
   using legacy_import.import_log l
   where l.run_id = p_run_id and l.table_name = 'parent_links' and l.action = 'inserted'
     and pl.parent_telegram_id = (l.detail ->> 'parent_telegram_id')::bigint
     and pl.student_id         = (l.detail ->> 'student_id')::bigint;

  -- 5.3. weekly_mock_exams (ключ из detail, без обращения к staging)
  delete from public.weekly_mock_exams w
   using legacy_import.import_log l
   where l.run_id = p_run_id and l.table_name = 'weekly_mock_exams' and l.action = 'inserted'
     and w.student_id = (l.detail ->> 'student_id')::bigint
     and w.week_start = (l.detail ->> 'week_start')::date;

  -- 5.4. mock_exam_results (exam_name может содержать '|', поэтому берём всё после первого)
  delete from public.mock_exam_results mr
   using legacy_import.import_log l
   where l.run_id = p_run_id and l.table_name = 'mock_exam_results' and l.action = 'inserted'
     and mr.student_id = split_part(l.entity_key, '|', 1)::bigint
     and mr.exam_name  = substr(l.entity_key, strpos(l.entity_key, '|') + 1);

  -- 5.5. student_payments
  delete from public.student_payments sp
   using legacy_import.import_log l
   where l.run_id = p_run_id and l.table_name = 'student_payments' and l.action = 'inserted'
     and sp.student_id = l.entity_key::bigint;

  -- 5.6. Открывающий баланс — компенсирующая запись, а не удаление.
  -- Защита от повторного отката: сущности с уже записанным rolled_back пропускаются.
  for r in
    select l.entity_key::bigint as tid, (l.detail ->> 'amount')::int as amount
      from legacy_import.import_log l
     where l.run_id = p_run_id and l.table_name = 'opening_balance' and l.action = 'inserted'
       and not exists (select 1 from legacy_import.import_log d
                        where d.run_id = p_run_id and d.table_name = 'opening_balance'
                          and d.entity_key = l.entity_key and d.action = 'rolled_back')
  loop
    if coalesce(r.amount, 0) > 0
       and exists (select 1 from public.students s where s.telegram_id = r.tid) then
      perform public.add_huikons(r.tid, -r.amount, 'legacy_opening_balance_rollback');
      insert into legacy_import.import_log (run_id, dry_run, table_name, entity_key, action, detail)
      values (p_run_id, false, 'opening_balance', r.tid::text, 'rolled_back',
              jsonb_build_object('amount', -r.amount));
    end if;
  end loop;

  -- 5.6a. Полная зачистка журнала баланса — только по явному запросу (см. шапку функции).
  -- Удаляются ТОЛЬКО строки, созданные импортом и его откатом, и только у учеников,
  -- вставленных этим прогоном.
  if p_purge_ledger then
    delete from public.balance_history bh
     using legacy_import.import_log l
     where l.run_id = p_run_id and l.table_name = 'students' and l.action = 'inserted'
       and bh.student_id = l.entity_key::bigint
       and bh.reason in ('legacy_opening_balance', 'legacy_opening_balance_rollback');
  end if;

  -- 5.7. students — последними, по одному, с честным пропуском при зависимостях.
  -- Уже откаченные пропускаются, чтобы повторный вызов не плодил записи в журнале прогона.
  for r in
    select l.entity_key::bigint as tid
      from legacy_import.import_log l
     where l.run_id = p_run_id and l.table_name = 'students' and l.action = 'inserted'
       and not exists (select 1 from legacy_import.import_log d
                        where d.run_id = p_run_id and d.table_name = 'students'
                          and d.entity_key = l.entity_key and d.action = 'rolled_back')
     order by 1
  loop
    begin
      delete from public.students where telegram_id = r.tid;
      insert into legacy_import.import_log (run_id, dry_run, table_name, entity_key, action, detail)
      values (p_run_id, false, 'students', r.tid::text, 'rolled_back', null);
    exception when foreign_key_violation then
      insert into legacy_import.import_log (run_id, dry_run, table_name, entity_key, action, detail)
      values (p_run_id, false, 'students', r.tid::text, 'skipped',
              jsonb_build_object('reason', 'dependent rows exist (student already active)'));
    end;
  end loop;

  return legacy_import.report(p_run_id);
end;
$function$;

-- --- 6. Grants ---------------------------------------------------------------------------------
revoke all on function legacy_import.migrate_legacy(boolean, text[], uuid) from public, anon, authenticated;
revoke all on function legacy_import.report(uuid)                          from public, anon, authenticated;
revoke all on function legacy_import.rollback_run(uuid, boolean)           from public, anon, authenticated;
grant execute on function legacy_import.migrate_legacy(boolean, text[], uuid) to service_role;
grant execute on function legacy_import.report(uuid)                          to service_role;
grant execute on function legacy_import.rollback_run(uuid, boolean)           to service_role;

-- =============================================================================
-- ROLLBACK миграции (сносит только инструмент; перенесённые данные останутся —
-- сначала выполните legacy_import.rollback_run(run_id), если нужно убрать и их):
--   drop function if exists legacy_import.rollback_run(uuid, boolean);
--   drop function if exists legacy_import.migrate_legacy(boolean, text[], uuid);
--   drop function if exists legacy_import.report(uuid);
--   drop schema if exists legacy_import cascade;
-- =============================================================================
