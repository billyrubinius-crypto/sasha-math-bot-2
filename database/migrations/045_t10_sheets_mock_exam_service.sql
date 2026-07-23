-- =============================================================================
-- 045_t10_sheets_mock_exam_service.sql — T10-10C2 (пробники из Sheets в canonical таблицу)
-- (Bot 2.0, T10; карточка tasks/T10-10C2.md; corrective к T10-10C; решение владельца Q4 в T10-10D)
--
-- Зачем. T10-10C честно повторил спецификацию Apps Script: sheets-sync-api писал в
-- mock_exam_results. Но в Bot 2.0 эту таблицу не читает НИ ОДИН экран — график ученика, панель
-- учителя и родительский /progress берут данные из weekly_mock_exams через
-- get_mock_exam_trajectory. После cutover (Bot 2.0 заменяет действующего бота) ввод пробников
-- помощниками уходил бы в мёртвую таблицу.
--
-- Что НЕ делаем. Новая экономическая логика не пишется. Переиспользуется существующая
-- record_weekly_mock_exam (миграция 016, P02A) — та же единственная точка записи, что зовёт панель
-- учителя: бублики +20/+30 pay-once через mock_exam_reward_log, season points компенсирующей
-- дельтой через weekly_mock_exams.season_points_awarded, зеркало display-строки в
-- mock_exam_results. Отсюда требование «повторная синхронизация не начисляет повторно»
-- выполняется по построению: at-least-once доставка от Apps Script безопасна.
--
-- Что добавляем. Ровно один узкий service-gateway для sheets-sync-api. Teacher-путь
-- (record_weekly_mock_exam_self) НЕ изменяется.
-- =============================================================================

-- Принимает ДАТУ пробника, а не week_start: приведение к понедельнику остаётся в одном месте (SQL),
-- Edge и Apps Script её не считают. search_path = public, pg_temp — как у teacher-гейтвея: внутренняя
-- record_weekly_mock_exam SECURITY INVOKER и обращается к таблицам без схемы.
create or replace function public.record_weekly_mock_exam_service(
  p_student_id bigint,
  p_exam_date  date,
  p_score      integer
)
 returns json
 language plpgsql
 security definer
 set search_path = public, pg_temp
as $function$
declare
  v_week date;
  v_res  json;
begin
  if p_student_id is null or p_student_id <= 0 then
    raise exception 'student required' using errcode = '22023';
  end if;
  if p_exam_date is null then
    raise exception 'exam date required' using errcode = '22023';
  end if;
  -- Диапазон дублирует check самой weekly_mock_exams: отказ должен быть внятным ДО записи.
  if p_score is null or p_score < 0 or p_score > 100 then
    raise exception 'score out of range' using errcode = '22023';
  end if;

  v_week := public.week_start_of(p_exam_date);

  -- Та же функция, что у панели учителя: награды pay-once, season points дельтой, зеркало в архив.
  v_res := public.record_weekly_mock_exam(p_student_id, v_week, p_score);

  -- actor 'sheets' — чтобы в аудите было видно, что запись пришла от помощников, а не от учителя.
  perform public.security_audit('sheets_record_mock', 'sheets', null, null,
    json_build_object('student_id', p_student_id, 'week_start', v_week, 'score', p_score,
                      'base_awarded', v_res -> 'base_awarded',
                      'record_awarded', v_res -> 'record_awarded')::jsonb);

  return json_build_object('week_start', v_week, 'result', v_res);
end;
$function$;

revoke all on function public.record_weekly_mock_exam_service(bigint, date, integer)
  from public, anon, authenticated;
grant execute on function public.record_weekly_mock_exam_service(bigint, date, integer)
  to service_role;

-- =============================================================================
-- ROLLBACK (безопасен до переключения sheets-sync-api; teacher-путь не затрагивается):
--   drop function if exists public.record_weekly_mock_exam_service(bigint, date, integer);
-- После отката sheets-sync-api должен вернуться к архивной записи (git revert коммита кода) —
-- иначе действие mock_exam_upsert будет получать db_error.
-- =============================================================================
