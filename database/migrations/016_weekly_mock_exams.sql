-- =============================================================================
-- 016_weekly_mock_exams.sql — серверный поток еженедельных пробников
-- (Bot 2.0, Stage 2.5, карточка P02A; SPEC_STAGE2_5.md §9; ECONOMY_V2.md §§3.2-3.3, 11, 14;
--  PRE_TASKS.md P2)
--
-- Зачем: безопасная запись ОДНОГО результата пробника на ученика и учебную неделю с
-- идемпотентной наградой. В форке ничто не пишет mock_exam_results (Apps Script не перенесён),
-- поэтому создаётся серверный weekly-upsert с атомарным ledger. teacher-форма — P02B.
--
-- Награды (ECONOMY_V2 §§11, 14; SPEC §9):
--   * база: +20 бубликов за факт валидного недельного пробника (один раз на неделю);
--   * личный рекорд: +30 бубликов, если score превосходит максимум ВСЕХ предыдущих валидных
--     недельных результатов минимум на 3 и не чаще раза в календарный месяц MSK;
--   * season points: 50 + min(max(score - предыдущий хронологический результат, 0), 20)
--     — не бублики, через add_season_points.
--
-- РЕШЕНИЯ (данные dev проверены read-only перед миграцией; в mock_exam_results 3 legacy-строки,
-- все score — валидные целые 0-100, нечисловых нет, поэтому триггер карточки «спросить про
-- нечисловой legacy-score» не сработал):
--
--   1. score text НЕ переименовывается и НЕ конвертируется (SPEC §9). Канонический результат —
--      новая таблица weekly_mock_exams с score integer 0-100. Legacy-строки mock_exam_results
--      не трогаются.
--
--   2. ИДЕМПОТЕНТНОСТЬ БЕЗ ОТКАТА ТРАНЗАКЦИЙ (поэтому «исправление нельзя без отмены транзакций»
--      не сработало):
--        - бублики (база/рекорд) — pay-once через явный ledger mock_exam_reward_log с
--          уникальностью (student_id, week_start, reward_kind): повторный вызов/edit НЕ платит
--          второй раз (SPEC §9 «исправление не выдаёт награды повторно»);
--        - season points — ДЕТЕРМИНИРОВАННАЯ КОМПЕНСИРУЮЩАЯ ДЕЛЬТА (карточка допускает «явно
--          описанную компенсирующую запись»): в weekly_mock_exams.season_points_awarded хранится
--          сколько очков этот результат уже дал; на каждом вызове target = 50 + рост, применяется
--          add_season_points(delta = target - awarded), awarded := target. Итог сезонного вклада
--          этой недели всегда равен формуле для текущего score, сколько бы ни было правок.
--
--   3. ЗЕРКАЛО В mock_exam_results делает САМ RPC (единственная точка записи, SPEC §9 «только
--      через атомарную RPC, не прямой клиентский upsert»): отдельная display-строка с
--      exam_name = 'Недельный пробник DD.MM.YYYY', score = текст числа, exam_date = week_start —
--      чтобы существующие графики index.html (loadMockExamChart) и списки parent_bot
--      (get_mock_exams) работали без изменений клиента (SPEC §9 «используют существующие
--      графики/списки после обновления данных»). Формат имени не пересекается с legacy
--      («Пробник номер N»), уникальность (student_id, exam_name) даёт одну строку на неделю.
--
--   4. ГРАНИЦЫ:
--        - «предыдущий хронологический результат» (для роста) = недельный результат с
--          наибольшим week_start < текущего; первой недели рост 0 (season = 50);
--        - «максимум всех предыдущих» (для рекорда) = max score недельных результатов с
--          week_start < текущего; первая неделя рекордом быть не может (нет предыдущего максимума);
--        - месячный лимit рекорда — по времени начисления now() MSK (rate-limit эмиссии бонуса),
--          не по week_start; после начисления строка ledger делает его неповторяемым;
--        - редактирование старой недели пересчитывает вклад ТОЛЬКО этой недели (её сезонная
--          дельта и её награды), downstream-недели не трогаются — детерминизм на уровне недели.
--
-- Конкурентность: record_weekly_mock_exam блокирует строку students (for update) в начале —
-- параллельные вызовы для одного ученика сериализуются, двойной результат/двойная награда
-- невозможны. Повторный запуск миграции безопасен (create table if not exists / or replace).
-- RLS у новых таблиц выключен, как у всех таблиц проекта (T10).
-- =============================================================================

-- --- 1. Канонический недельный результат --------------------------------------
-- Одна строка на (student_id, week_start). score — целое 0-100 (в отличие от legacy score text).
create table if not exists public.weekly_mock_exams (
  id                     uuid         primary key default gen_random_uuid(),
  student_id             bigint       not null references public.students (telegram_id),
  week_start             date         not null check (extract(isodow from week_start) = 1),
  score                  integer      not null check (score between 0 and 100),
  season_points_awarded  integer      not null default 0,  -- сколько season points уже дал этот результат (для детерминированной дельты)
  created_at             timestamptz  not null default now(),
  updated_at             timestamptz  not null default now(),
  unique (student_id, week_start)
);

create index if not exists idx_weekly_mock_exams_student
  on public.weekly_mock_exams (student_id, week_start);

alter table public.weekly_mock_exams disable row level security;

-- --- 2. Явный ledger бубличных наград ------------------------------------------
-- Одна строка = одна выданная бубличная награда. Уникальность (student_id, week_start,
-- reward_kind) гарантирует: база и рекорд выдаются не более одного раза на неделю (SPEC §9
-- «наградная история хранится отдельно/явно и проверяется уникальным ограничением»).
create table if not exists public.mock_exam_reward_log (
  id           uuid         primary key default gen_random_uuid(),
  student_id   bigint       not null references public.students (telegram_id),
  week_start   date         not null,
  reward_kind  text         not null check (reward_kind in ('base', 'record')),
  bubliks      integer      not null check (bubliks > 0),
  awarded_at   timestamptz  not null default now(),
  unique (student_id, week_start, reward_kind)
);

create index if not exists idx_mock_exam_reward_log_month
  on public.mock_exam_reward_log (student_id, reward_kind, awarded_at);

alter table public.mock_exam_reward_log disable row level security;

-- --- 3. Атомарная запись/редактирование результата -----------------------------
CREATE OR REPLACE FUNCTION public.record_weekly_mock_exam(
  p_student_id bigint,
  p_week_start date,
  p_score      integer
)
 RETURNS json
 LANGUAGE plpgsql
AS $function$
declare
  v_prev_score   integer;   -- предыдущий хронологический результат (для роста season points)
  v_prev_max     integer;   -- максимум всех предыдущих (для рекорда)
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

  -- Сериализуем все записи пробников этого ученика: параллельный вызов/двойной клик не создаст
  -- второй результат и не выдаст награду дважды.
  perform 1 from public.students where telegram_id = p_student_id for update;
  if not found then
    raise exception 'Ученик % не найден', p_student_id;
  end if;

  -- Предыдущий хронологический результат и максимум всех предыдущих (строго < текущей недели).
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

  -- Upsert результата. season_points_awarded прежнего значения нужно ДО обновления, чтобы
  -- посчитать компенсирующую дельту.
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

  -- Season points: компенсирующая дельта до целевого значения (детерминированный вклад недели).
  v_season_delta := v_season_target - v_season_prev;
  if v_season_delta <> 0 then
    perform public.add_season_points(p_student_id, v_season_delta);
  end if;

  -- Зеркало в mock_exam_results для существующих графиков/списков (единственная точка записи).
  v_exam_name := 'Недельный пробник ' || to_char(p_week_start, 'DD.MM.YYYY');
  insert into public.mock_exam_results (student_id, exam_name, score, exam_date, updated_at)
    values (p_student_id, v_exam_name, p_score::text, p_week_start, v_now)
    on conflict (student_id, exam_name)
    do update set score = excluded.score, exam_date = excluded.exam_date, updated_at = v_now;

  -- База +20: один раз на неделю (idempotent через ledger).
  insert into public.mock_exam_reward_log (student_id, week_start, reward_kind, bubliks)
    values (p_student_id, p_week_start, 'base', 20)
    on conflict (student_id, week_start, reward_kind) do nothing;
  if found then
    perform public.add_huikons(p_student_id, 20, 'mock_exam_weekly');
    v_base_awarded := true;
  end if;

  -- Рекорд +30: score выше максимума всех предыдущих минимум на 3; не чаще раза в календарный
  -- месяц MSK; один раз на неделю. Первая неделя (v_prev_max is null) рекордом быть не может.
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
        values (p_student_id, p_week_start, 'record', 30)
        on conflict (student_id, week_start, reward_kind) do nothing;
      if found then
        perform public.add_huikons(p_student_id, 30, 'mock_exam_record');
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
