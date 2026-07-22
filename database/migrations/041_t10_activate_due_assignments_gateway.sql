-- =============================================================================
-- 041_t10_activate_due_assignments_gateway.sql — T10-06E (activate due assignments gateway)
-- (Bot 2.0, T10; корректирующая мини-карта перед T10-08A; SPEC_T10.md §4; паттерн T10-04A)
--
-- Зачем: checkAndActivateAssignments (student-assignments.js) на КАЖДОМ старте приложения ученика
-- делает прямой client update(assignments.activation_status) под ролью authenticated — единственный
-- оставшийся ungatewated write в secure path после T10-06C/D. Блокирует write-lockdown T10-08A.
--
-- Gateway: app_role='student', identity из JWT-claim (T10-01), НЕ принимает student_id. Активирует
-- ТОЛЬКО свои задания (student_id = telegram_id из claim) в статусе 'scheduled', у которых
-- scheduled_date <= сегодня по МСК — тот же фильтр, что делал клиент. Прямая бизнес-логика
-- (bulk update по WHERE), не делегирование — как ensure_student_self/submit_assignment_self (034),
-- так как отдельного internal primitive для этого действия в схеме не было.
-- =============================================================================

create or replace function public.activate_due_assignments_self()
 returns void
 language plpgsql
 security definer
 set search_path = ''
as $function$
declare
  v_tid bigint;
begin
  if private.current_app_role() is distinct from 'student' then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  v_tid := private.current_telegram_id();
  if v_tid is null or v_tid <= 0 then
    raise exception 'no student identity' using errcode = '42501';
  end if;

  update public.assignments
     set activation_status = 'active'
   where student_id = v_tid
     and activation_status = 'scheduled'
     and scheduled_date <= (now() at time zone 'Europe/Moscow')::date;
end;
$function$;

revoke all on function public.activate_due_assignments_self() from public, anon;
grant execute on function public.activate_due_assignments_self() to authenticated;

-- =============================================================================
-- ROLLBACK (до переключения клиента — безопасно):
--   drop function if exists public.activate_due_assignments_self();
-- =============================================================================
