-- =============================================================================
-- 013_task_count_totals.sql — серверный счётчик задач и дней занятий
-- (Bot 2.0, Stage 2.5, карточка P01A; SPEC_STAGE2_5.md §§4, 6, 13-14)
--
-- Зачем: единый серверный источник lifetime/range итогов для будущих званий, групповых
-- целей и хроники (Stage 3+), построенный поверх lifecycle-полей W01/W04
-- (task_count, first_submitted_at) без отдельного изменяемого счётчика в students.
-- Итоги — read-only производные от assignments, ничего не пишут и не начисляют.
--
-- get_student_task_totals(p_student_id, p_from, p_to) возвращает одну строку:
--   solved_tasks               — сумма task_count принятых assignments (lifetime либо диапазон);
--   active_days                — число уникальных дат МСК первой отправки принятой работы;
--   unknown_approved_assignments — принятые assignments без известного task_count (legacy).
-- p_from/p_to = null → lifetime; иначе диапазон дат МСК включительно с обеих сторон
-- (каждая граница независима: null с одной стороны = открыт с этой стороны).
--
-- УТОЧНЕНИЕ КОНТРАКТА (решение пользователя, 2026-07-16), фиксируется здесь, т.к. в
-- карточке текст неоднозначен:
--   Фраза карточки «Считаются только принятые assignments с task_count > 0» относится
--   ТОЛЬКО к арифметической сумме solved_tasks — там нельзя складывать null. active_days
--   считается по ВСЕМ принятым assignments с известной датой первой отправки, ВКЛЮЧАЯ
--   legacy с task_count IS NULL: день реально был активным независимо от того, известно ли
--   число задач в этот день. Такие legacy-строки одновременно увеличивают
--   unknown_approved_assignments. Без этого уточнения на момент написания миграции
--   active_days был бы 0 у всех учеников: 100% сейчас принятых работ — legacy без
--   task_count (P01A/P01B ещё не существовали, когда их сдавали).
--
-- Принятая работа = status = 'checked' and approval_status = 'approved' (тот же критерий,
-- что использует W04 в recalc_student_week и вся покупка/выдача в проекте). «Одна assignment
-- входит один раз независимо от числа пересдач/повторной приёмки» и «две приёмки одной
-- работы дают тот же итог» выполняются автоматически: assignments не хранит историю
-- переходов статуса, только ТЕКУЩЕЕ состояние строки, поэтому функция — чистый SELECT по
-- текущему снимку, а не накопитель событий; вызывать её повторно безопасно.
--
-- Дата активности = coalesce(first_submitted_at, submitted_at) — тот же read-time fallback
-- для legacy, что использует is_first_submission_on_time (W04): не backfill колонки, а
-- чтение единственного доступного свидетельства. По Москве, тем же паттерном
-- (at time zone 'Europe/Moscow')::date, что next_monday_msk/is_first_submission_on_time.
--
-- Диапазон на границе 00:00 MSK детерминирован через null-propagation: сравнение
-- `date_msk >= p_from` с NULL-датой (нет ни first_submitted_at, ни submitted_at — на
-- практике сейчас таких принятых строк нет, проверено read-only перед миграцией) даёт NULL
-- и строка исключается из WHERE при заданной границе диапазона, но участвует в lifetime
-- (граница = null). Type не ограничивается (daily/weekly/individual) — контракт не сужает
-- типы, а task_count есть у всех трёх с W01/P01B.
--
-- Данные проверены перед написанием миграции (read-only): task_count <= 0 в БД нет (CHECK
-- уже это гарантирует), у всех текущих принятых строк есть хотя бы одна дата отправки.
--
-- Повторный запуск безопасен (create or replace). Ничего не меняет в assignments, наградах,
-- UI, RLS/T10 и не переписывает историю.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.get_student_task_totals(
  p_student_id bigint,
  p_from       date DEFAULT null,
  p_to         date DEFAULT null
)
 RETURNS TABLE(
   solved_tasks                 bigint,
   active_days                  bigint,
   unknown_approved_assignments bigint
 )
 LANGUAGE sql
 STABLE
AS $function$
  with accepted as (
    select
      a.task_count,
      (coalesce(a.first_submitted_at, a.submitted_at) at time zone 'Europe/Moscow')::date as date_msk
    from public.assignments a
    where a.student_id = p_student_id
      and a.status = 'checked'
      and a.approval_status = 'approved'
      and (p_from is null or (coalesce(a.first_submitted_at, a.submitted_at) at time zone 'Europe/Moscow')::date >= p_from)
      and (p_to   is null or (coalesce(a.first_submitted_at, a.submitted_at) at time zone 'Europe/Moscow')::date <= p_to)
  )
  select
    coalesce(sum(task_count) filter (where task_count > 0), 0)::bigint as solved_tasks,
    count(distinct date_msk)::bigint                                   as active_days,
    count(*) filter (where task_count is null)::bigint                 as unknown_approved_assignments
  from accepted;
$function$;
