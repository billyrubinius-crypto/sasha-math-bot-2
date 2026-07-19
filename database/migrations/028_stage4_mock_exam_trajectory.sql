-- =============================================================================
-- 028_stage4_mock_exam_trajectory.sql — Серверная read-модель траектории пробников
-- (Bot 2.0, Stage 4, карточка U05A; SPEC_STAGE4.md §7)
--
-- Зачем: student/teacher/parent должны читать ОДНУ готовую RPC вместо трёх копий одной и той
-- же формулы (avg/range/trend) в разных клиентах. Источник — только raw score из
-- weekly_mock_exams; сезонные points (record_weekly_mock_exam, P02A) не смешиваются с этим
-- графиком и здесь не читаются и не пишутся. Функция read-only/STABLE, ничего не записывает и
-- не начисляет — только вычисляет производные по уже существующим строкам.
--
-- Только новая функция; ни одна существующая таблица/функция (включая record_weekly_mock_exam
-- и его reward-ledger) не меняется.
--
-- Правила (SPEC §7, дословно):
--   0 результатов  -> пустое состояние (count=0, points=[], всё остальное null);
--   1 результат    -> одна точка (last_score, delta_last/avg/min/max/trend = null);
--   2 результата   -> + delta_last (последний минус предпоследний);
--   3+ результата  -> + avg_last_3/min_last_3/max_last_3 (по последним трём фактическим);
--   6+ результатов -> + trend: среднее последних 3 против среднего ПРЕДЫДУЩИХ 3 (две
--                      непересекающиеся тройки по позиции в списке, не по календарным неделям
--                      — разрыв между ними не мешает); |diff| < 2 => 'flat', иначе 'up'/'down'
--                      по знаку разницы;
--   пропущенная неделя не интерполируется — в points только реально существующие строки;
--   исправление результата (record_weekly_mock_exam) пересчитывает всё при следующем чтении
--   (функция STABLE и всегда читает текущие данные, кэша нет).
--
-- Реализация: array_agg(order by week_start) + slice-нотация Postgres для «последних N» без
-- явных window-подзапросов. array_agg/unnest над пустым набором дают NULL/0 строк без ошибок —
-- отдельная обработка count=0 не нужна, но CASE-guards оставлены для точного соответствия
-- порогам SPEC (явный null ниже порога, а не то, что случайно получится).
-- =============================================================================

create or replace function public.get_mock_exam_trajectory(p_student_id bigint)
 returns jsonb
 language sql
 stable
as $function$
  with ordered as (
    select array_agg(week_start order by week_start) as week_starts,
           array_agg(score      order by week_start) as scores,
           count(*)::int as cnt
      from public.weekly_mock_exams
     where student_id = p_student_id
  )
  select jsonb_build_object(
    'count', cnt,
    'points', (
      select coalesce(jsonb_agg(jsonb_build_object('week_start', ws, 'score', sc) order by ws), '[]'::jsonb)
        from ordered, unnest(week_starts, scores) as u(ws, sc)
    ),
    'last_score', case when cnt >= 1 then scores[cnt] else null end,
    'delta_last', case when cnt >= 2 then scores[cnt] - scores[cnt - 1] else null end,
    'avg_last_3', case when cnt >= 3
      then (select round(avg(x), 1) from unnest(scores[cnt - 2:cnt]) as x)
      else null end,
    'min_last_3', case when cnt >= 3
      then (select min(x) from unnest(scores[cnt - 2:cnt]) as x)
      else null end,
    'max_last_3', case when cnt >= 3
      then (select max(x) from unnest(scores[cnt - 2:cnt]) as x)
      else null end,
    'trend', case when cnt >= 6 then (
      case
        when (select avg(x) from unnest(scores[cnt - 2:cnt]) as x)
           - (select avg(x) from unnest(scores[cnt - 5:cnt - 3]) as x) >= 2 then 'up'
        when (select avg(x) from unnest(scores[cnt - 5:cnt - 3]) as x)
           - (select avg(x) from unnest(scores[cnt - 2:cnt]) as x) >= 2 then 'down'
        else 'flat'
      end
    ) else null end
  )
  from ordered;
$function$;

-- =============================================================================
-- ROLLBACK (только функция; данные weekly_mock_exams/ledger не затрагиваются):
--   drop function if exists public.get_mock_exam_trajectory(bigint);
-- =============================================================================
