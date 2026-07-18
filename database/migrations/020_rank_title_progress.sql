-- =============================================================================
-- 020_rank_title_progress.sql — get_student_rank_title: пороги следующей ступени
-- (Bot 2.0, Stage 3, карточка L04; SPEC_STAGE3.md §8)
--
-- Зачем: L04 показывает в UI прогресс к следующему званию («осталось N задач и M дней»).
-- Контракт L04 прямо запрещает копировать таблицу порогов в JavaScript — семь ступеней и их
-- пороги должны оставаться единственным источником истины в этой функции (как уже сделано
-- в 019 для текущего звания). Решение пользователя (в ходе L04): расширить эту функцию сейчас,
-- а не откладывать прогресс до отдельной карточки.
--
-- Единственное изменение — добавленные поля в JSON-ответ; существующие title/level/
-- solved_tasks/active_days/has_unknown_legacy не меняются, вызывающий код L01-L03 не задет.
-- На топ-уровне (Легенда ЕГЭ) next_* — null: дальше повышать некуда.
-- Функция read-only (stable), новых таблиц/индексов/RLS нет.
-- =============================================================================

create or replace function public.get_student_rank_title(p_student_id bigint)
 returns json
 language plpgsql
 stable
as $function$
declare
  v_tasks   bigint;
  v_days    bigint;
  v_unknown bigint;
  v_name    text;
  v_level   integer;
  v_next_name  text;
  v_next_level integer;
  v_next_tasks integer;
  v_next_days  integer;
begin
  select solved_tasks, active_days, unknown_approved_assignments
    into v_tasks, v_days, v_unknown
    from public.get_student_task_totals(p_student_id, null, null);

  v_tasks := coalesce(v_tasks, 0);
  v_days  := coalesce(v_days, 0);

  -- Пороги SPEC_STAGE3 §8 (оба условия обязательны), от высшего к низшему.
  if    v_tasks >= 5000 and v_days >= 250 then v_name := 'Легенда ЕГЭ'; v_level := 7;
  elsif v_tasks >= 3500 and v_days >= 190 then v_name := 'Профессор';   v_level := 6;
  elsif v_tasks >= 2000 and v_days >= 130 then v_name := 'Академик';    v_level := 5;
  elsif v_tasks >= 1000 and v_days >= 80  then v_name := 'Магистр';     v_level := 4;
  elsif v_tasks >= 400  and v_days >= 40  then v_name := 'Решатель';    v_level := 3;
  elsif v_tasks >= 100  and v_days >= 15  then v_name := 'Ученик';      v_level := 2;
  else                                         v_name := 'Новичок';     v_level := 1;
  end if;

  -- Следующая ступень (для прогресса в UI). На седьмой ступени некуда — next_* остаются null.
  case v_level
    when 1 then v_next_name := 'Ученик';      v_next_level := 2; v_next_tasks := 100;  v_next_days := 15;
    when 2 then v_next_name := 'Решатель';    v_next_level := 3; v_next_tasks := 400;  v_next_days := 40;
    when 3 then v_next_name := 'Магистр';     v_next_level := 4; v_next_tasks := 1000; v_next_days := 80;
    when 4 then v_next_name := 'Академик';    v_next_level := 5; v_next_tasks := 2000; v_next_days := 130;
    when 5 then v_next_name := 'Профессор';   v_next_level := 6; v_next_tasks := 3500; v_next_days := 190;
    when 6 then v_next_name := 'Легенда ЕГЭ'; v_next_level := 7; v_next_tasks := 5000; v_next_days := 250;
    else        v_next_name := null;          v_next_level := null; v_next_tasks := null; v_next_days := null;
  end case;

  return json_build_object(
    'title',               v_name,
    'level',                v_level,
    'solved_tasks',         v_tasks,
    'active_days',          v_days,
    'has_unknown_legacy',   coalesce(v_unknown, 0) > 0,
    'next_title',           v_next_name,
    'next_level',           v_next_level,
    'next_tasks_required',  v_next_tasks,
    'next_days_required',   v_next_days,
    'tasks_to_next',        case when v_next_tasks is null then null else greatest(v_next_tasks - v_tasks, 0) end,
    'days_to_next',         case when v_next_days is null then null else greatest(v_next_days - v_days, 0) end
  );
end;
$function$;

-- =============================================================================
-- ROLLBACK: воспроизвести тело get_student_rank_title из 019_leagues.sql (раздел 14),
-- которое не включало next_*/tasks_to_next/days_to_next.
-- =============================================================================
