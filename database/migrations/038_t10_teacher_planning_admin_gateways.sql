-- =============================================================================
-- 038_t10_teacher_planning_admin_gateways.sql — T10-06B (teacher planning + admin gateways)
-- (Bot 2.0, T10; SPEC_T10.md §4; карточка T10-06B; foundation T10-01/05, паттерн T10-06A)
--
-- Закрывает оставшуюся teacher server surface: weekly planning, individual assignments, mock
-- exams, season/league close, custom-title moderation, life-template catalog. Каждый gateway
-- требует app_role='teacher' (из JWT-claims), имеет фиксированный search_path и audit значимого
-- действия (object id/result, без photo/feedback/free-text content). Экономика/бизнес-логика не
-- переписываются — делегирование в существующие атомарные RPC (W/P/L/U idempotency, counts,
-- tie-break, фонд 190, privacy life-history сохранены). Два прямых browser-write в assignments
-- (individual create/delete) заменяются серверными gateway с проверками (тип/статус).
--
-- Preview/read routes (preview_league_close, admin_list_life_quest_templates, get_mock_exam_
-- trajectory, table selects) в этой карте НЕ трогаются — они относятся к read surface T10-08.
-- UI не переключается (T10-07); auth_mode=legacy, RLS не включается. Grant только authenticated;
-- app_role проверяется внутри (student → forbidden), anon execute не получает. Legacy RPC/прямые
-- writes остаются рабочими до final revoke T10-11.
--
-- SECURITY DEFINER обязателен (доступ к private.* claim-хелперам). search_path=public,pg_temp:
-- делегируем в функции с неполными public-именами; путь фиксирован, pg_temp последним.
-- =============================================================================

-- --- 1. publish_weekly_plan_self — публикация недельного плана группе/всем -------------------
create or replace function public.publish_weekly_plan_self(
  p_week_start    date,
  p_audience_type text,
  p_group_name    text default null,
  p_items         jsonb default '[]'::jsonb)
 returns json
 language plpgsql security definer set search_path = public, pg_temp
as $function$
declare v_princ uuid; v_res json;
begin
  if private.current_app_role() is distinct from 'teacher' then
    raise exception 'forbidden' using errcode = '42501'; end if;
  v_princ := private.current_principal();
  v_res := public.publish_weekly_plan(p_week_start, p_audience_type, p_group_name, p_items);
  perform public.security_audit('teacher_publish_plan', 'teacher', v_princ, null,
    json_build_object('week_start', p_week_start, 'audience_type', p_audience_type,
                      'group_name', p_group_name)::jsonb);
  return v_res;
end;
$function$;

-- --- 2. cancel_weekly_plan_self — отмена недели (история сохраняется, неначатые снимаются) ----
create or replace function public.cancel_weekly_plan_self(p_plan_id uuid)
 returns json
 language plpgsql security definer set search_path = public, pg_temp
as $function$
declare v_princ uuid; v_res json;
begin
  if private.current_app_role() is distinct from 'teacher' then
    raise exception 'forbidden' using errcode = '42501'; end if;
  if p_plan_id is null then raise exception 'plan required' using errcode = '22023'; end if;
  v_princ := private.current_principal();
  v_res := public.cancel_weekly_plan(p_plan_id);
  perform public.security_audit('teacher_cancel_plan', 'teacher', v_princ, null,
    json_build_object('plan_id', p_plan_id)::jsonb);
  return v_res;
end;
$function$;

-- --- 3. create_individual_assignment_self — назначить индивидуальное задание ученику ---------
-- Заменяет прямой browser insert(assignments) в teacher-students.js. Target student — бизнес-
-- аргумент учителя (SPEC §4). Фиксированные поля type/status/activation как в legacy insert.
create or replace function public.create_individual_assignment_self(
  p_student_id     bigint,
  p_title          text,
  p_content_url    text,
  p_teacher_comment text,
  p_task_count     integer)
 returns json
 language plpgsql security definer set search_path = public, pg_temp
as $function$
declare v_princ uuid; v_id uuid;
begin
  if private.current_app_role() is distinct from 'teacher' then
    raise exception 'forbidden' using errcode = '42501'; end if;
  if p_student_id is null then raise exception 'student required' using errcode = '22023'; end if;
  if p_title is null or length(btrim(p_title)) = 0 then
    raise exception 'title required' using errcode = '22023'; end if;
  if p_task_count is null or p_task_count < 1 or p_task_count > 200 then
    raise exception 'invalid task_count' using errcode = '22023'; end if;
  v_princ := private.current_principal();

  insert into public.assignments
    (student_id, type, title, content_url, teacher_comment, activation_status, status, task_count)
  values
    (p_student_id, 'individual', p_title, p_content_url, p_teacher_comment, 'active', 'assigned', p_task_count)
  returning id into v_id;

  perform public.security_audit('teacher_create_individual', 'teacher', v_princ, null,
    json_build_object('assignment_id', v_id, 'student_id', p_student_id, 'task_count', p_task_count)::jsonb);
  return json_build_object('id', v_id);
end;
$function$;

-- --- 4. delete_individual_assignment_self — удалить НЕначатое индивидуальное задание ---------
-- Заменяет прямой browser delete(assignments). Только type='individual' и status='assigned'
-- (начатую/сданную удалить нельзя — как показывает клиент кнопку только для active).
create or replace function public.delete_individual_assignment_self(p_assignment_id uuid)
 returns json
 language plpgsql security definer set search_path = public, pg_temp
as $function$
declare v_princ uuid; v_cnt integer;
begin
  if private.current_app_role() is distinct from 'teacher' then
    raise exception 'forbidden' using errcode = '42501'; end if;
  if p_assignment_id is null then raise exception 'assignment required' using errcode = '22023'; end if;
  v_princ := private.current_principal();

  delete from public.assignments
   where id = p_assignment_id and type = 'individual' and status = 'assigned';
  get diagnostics v_cnt = row_count;
  if v_cnt = 0 then raise exception 'not deletable' using errcode = '22023'; end if;

  perform public.security_audit('teacher_delete_individual', 'teacher', v_princ, null,
    json_build_object('assignment_id', p_assignment_id)::jsonb);
  return json_build_object('deleted', v_cnt);
end;
$function$;

-- --- 5. close_season_self — закрыть сезон (каскадом league close + cohort build внутри) ------
create or replace function public.close_season_self()
 returns json
 language plpgsql security definer set search_path = public, pg_temp
as $function$
declare v_princ uuid; v_res json;
begin
  if private.current_app_role() is distinct from 'teacher' then
    raise exception 'forbidden' using errcode = '42501'; end if;
  v_princ := private.current_principal();
  v_res := public.close_season();
  perform public.security_audit('teacher_close_season', 'teacher', v_princ, null,
    json_build_object('season_id', v_res->'season_id', 'archived', v_res->'archived',
                      'awarded', v_res->'awarded')::jsonb);
  return v_res;
end;
$function$;

-- --- 6. record_weekly_mock_exam_self — записать/исправить результат пробника ------------------
create or replace function public.record_weekly_mock_exam_self(
  p_student_id bigint,
  p_week_start date,
  p_score      integer)
 returns json
 language plpgsql security definer set search_path = public, pg_temp
as $function$
declare v_princ uuid; v_res json;
begin
  if private.current_app_role() is distinct from 'teacher' then
    raise exception 'forbidden' using errcode = '42501'; end if;
  if p_student_id is null then raise exception 'student required' using errcode = '22023'; end if;
  v_princ := private.current_principal();
  v_res := public.record_weekly_mock_exam(p_student_id, p_week_start, p_score);
  perform public.security_audit('teacher_record_mock', 'teacher', v_princ, null,
    json_build_object('student_id', p_student_id, 'week_start', p_week_start, 'score', p_score,
                      'base_awarded', v_res->'base_awarded', 'record_awarded', v_res->'record_awarded')::jsonb);
  return v_res;
end;
$function$;

-- --- 7. review_custom_title_self — модерация персонального титула ----------------------------
create or replace function public.review_custom_title_self(
  p_student_id      bigint,
  p_decision        text,
  p_teacher_comment text default null)
 returns json
 language plpgsql security definer set search_path = public, pg_temp
as $function$
declare v_princ uuid; v_res json;
begin
  if private.current_app_role() is distinct from 'teacher' then
    raise exception 'forbidden' using errcode = '42501'; end if;
  if p_student_id is null then raise exception 'student required' using errcode = '22023'; end if;
  v_princ := private.current_principal();
  v_res := public.review_custom_title(p_student_id, p_decision, p_teacher_comment);
  -- audit без текста титула/комментария (content) — только объект и решение.
  perform public.security_audit('teacher_review_title', 'teacher', v_princ, null,
    json_build_object('student_id', p_student_id, 'decision', p_decision)::jsonb);
  return v_res;
end;
$function$;

-- --- 8. admin_upsert_life_quest_template_self — добавить/изменить шаблон life-квеста ----------
create or replace function public.admin_upsert_life_quest_template_self(
  p_template_code text,
  p_name          text,
  p_description   text,
  p_category      text,
  p_weight        integer)
 returns public.life_quest_templates
 language plpgsql security definer set search_path = public, pg_temp
as $function$
declare v_princ uuid; v_row public.life_quest_templates%rowtype;
begin
  if private.current_app_role() is distinct from 'teacher' then
    raise exception 'forbidden' using errcode = '42501'; end if;
  v_princ := private.current_principal();
  v_row := public.admin_upsert_life_quest_template(p_template_code, p_name, p_description, p_category, p_weight);
  perform public.security_audit('teacher_quest_upsert', 'teacher', v_princ, null,
    json_build_object('template_code', p_template_code)::jsonb);
  return v_row;
end;
$function$;

-- --- 9. admin_set_life_quest_template_active_self — включить/выключить шаблон -----------------
create or replace function public.admin_set_life_quest_template_active_self(
  p_template_code text,
  p_active        boolean)
 returns public.life_quest_templates
 language plpgsql security definer set search_path = public, pg_temp
as $function$
declare v_princ uuid; v_row public.life_quest_templates%rowtype;
begin
  if private.current_app_role() is distinct from 'teacher' then
    raise exception 'forbidden' using errcode = '42501'; end if;
  v_princ := private.current_principal();
  v_row := public.admin_set_life_quest_template_active(p_template_code, p_active);
  perform public.security_audit('teacher_quest_active', 'teacher', v_princ, null,
    json_build_object('template_code', p_template_code, 'active', p_active)::jsonb);
  return v_row;
end;
$function$;

-- --- 10. Явные grants: authenticated (teacher JWT; app_role внутри). anon исключён -----------
revoke all on function public.publish_weekly_plan_self(date, text, text, jsonb) from public, anon;
revoke all on function public.cancel_weekly_plan_self(uuid) from public, anon;
revoke all on function public.create_individual_assignment_self(bigint, text, text, text, integer) from public, anon;
revoke all on function public.delete_individual_assignment_self(uuid) from public, anon;
revoke all on function public.close_season_self() from public, anon;
revoke all on function public.record_weekly_mock_exam_self(bigint, date, integer) from public, anon;
revoke all on function public.review_custom_title_self(bigint, text, text) from public, anon;
revoke all on function public.admin_upsert_life_quest_template_self(text, text, text, text, integer) from public, anon;
revoke all on function public.admin_set_life_quest_template_active_self(text, boolean) from public, anon;
grant execute on function public.publish_weekly_plan_self(date, text, text, jsonb) to authenticated;
grant execute on function public.cancel_weekly_plan_self(uuid) to authenticated;
grant execute on function public.create_individual_assignment_self(bigint, text, text, text, integer) to authenticated;
grant execute on function public.delete_individual_assignment_self(uuid) to authenticated;
grant execute on function public.close_season_self() to authenticated;
grant execute on function public.record_weekly_mock_exam_self(bigint, date, integer) to authenticated;
grant execute on function public.review_custom_title_self(bigint, text, text) to authenticated;
grant execute on function public.admin_upsert_life_quest_template_self(text, text, text, text, integer) to authenticated;
grant execute on function public.admin_set_life_quest_template_active_self(text, boolean) to authenticated;

-- =============================================================================
-- ROLLBACK (UI не переключён — безопасно):
--   drop function if exists public.admin_set_life_quest_template_active_self(text, boolean);
--   drop function if exists public.admin_upsert_life_quest_template_self(text, text, text, text, integer);
--   drop function if exists public.review_custom_title_self(bigint, text, text);
--   drop function if exists public.record_weekly_mock_exam_self(bigint, date, integer);
--   drop function if exists public.close_season_self();
--   drop function if exists public.delete_individual_assignment_self(uuid);
--   drop function if exists public.create_individual_assignment_self(bigint, text, text, text, integer);
--   drop function if exists public.cancel_weekly_plan_self(uuid);
--   drop function if exists public.publish_weekly_plan_self(date, text, text, jsonb);
-- =============================================================================
