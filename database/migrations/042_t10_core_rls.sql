-- =============================================================================
-- 042_t10_core_rls.sql — T10-08A (Core RLS: identity, assignments, деньги, пробники)
-- (Bot 2.0, T10; SPEC_T10.md §5; карточка T10-08A; после T10-04A/06A/07 + prereq T10-06C/D/E)
--
-- Включает RLS и минимальные grants на core personal-data таблицах. СТРОГО, без временных
-- anon-compat политик (решение пользователя: Railway-боты НЕ подключены к dev; они получат Edge-
-- endpoints в T10-10 до реального выхода в бой; браузерный teacher — JWT-only после T10-07;
-- браузерный student в anon-fallback — только dev). Game scope (inventory/achievements/leagues/
-- daily quests/прочие reward ledgers) НЕ трогается — это T10-08B.
--
-- Модель владения: identity из внешне выпущенного JWT (claim telegram_id/app_role). Политики зовут
-- ДВА новых public SECURITY DEFINER хелпера jwt_app_role()/jwt_student_id() (тонкие обёртки над
-- private.current_*), т.к. политики исполняются под ролью authenticated/anon, а у них нет USAGE на
-- схему private. Клиентский аргумент ID прав не даёт: политики сверяют строку с claim, поэтому даже
-- read-RPC, принимающие p_student_id (get_mock_exam_trajectory и т.п.), под RLS возвращают только
-- свои строки (чужой id → 0 строк).
--
-- Writes: все прямые client-writes в эти таблицы уже уведены в SECURITY DEFINER gateway'и
-- (T10-04A/06A/B/C/D/E) — они во владении postgres, обходят RLS и не зависят от role-grants; поэтому
-- REVOKE INSERT/UPDATE/DELETE от anon/authenticated их не ломает. Service (Apps Script) — service_role,
-- BYPASSRLS. auth_mode остаётся 'legacy' (переключение в enforced — T10-11).
--
-- Таблицы (9): students, assignments, balance_history, weekly_mock_exams, mock_exam_results
-- (student own [+ teacher где нужно review]); mock_exam_reward_log, parent_links,
-- homework_submissions, student_payments (deny-client / deny-all). student_payments RLS уже был on.
-- =============================================================================

-- --- 0. Public policy-хелперы (SECURITY DEFINER; видны политикам под anon/authenticated) --------
-- STABLE => планировщик вычисляет один раз на запрос (RLS-предикат становится student_id=<const>,
-- использует существующие индексы). Возвращают ТОЛЬКО claim текущей сессии, не lookup по id.
create or replace function public.jwt_app_role()
 returns text language sql stable security definer set search_path = ''
as $function$ select private.current_app_role() $function$;

create or replace function public.jwt_student_id()
 returns bigint language sql stable security definer set search_path = ''
as $function$ select private.current_telegram_id() $function$;

revoke all on function public.jwt_app_role() from public;
revoke all on function public.jwt_student_id() from public;
grant execute on function public.jwt_app_role() to anon, authenticated;
grant execute on function public.jwt_student_id() to anon, authenticated;

-- --- 0b. Индекс под RLS-фильтр balance_history.student_id (остальные покрыты PK/unique) ---------
create index if not exists idx_balance_history_student on public.balance_history (student_id);

-- --- Атомарное включение RLS + политик + grants после preflight -------------------------------
begin;

-- Preflight: прерваться до любого ENABLE, если фундамент/таблицы не на месте.
do $$
declare
  v_missing text;
begin
  if to_regprocedure('public.jwt_student_id()') is null
     or to_regprocedure('public.jwt_app_role()') is null
     or to_regprocedure('private.current_telegram_id()') is null then
    raise exception 'preflight: claim helpers missing';
  end if;
  select string_agg(t, ', ') into v_missing from unnest(array[
    'public.students','public.assignments','public.balance_history','public.weekly_mock_exams',
    'public.mock_exam_results','public.mock_exam_reward_log','public.parent_links',
    'public.homework_submissions','public.student_payments']) t
  where to_regclass(t) is null;
  if v_missing is not null then
    raise exception 'preflight: missing tables: %', v_missing;
  end if;
end $$;

-- === STUDENT-OWN [+ TEACHER READ] таблицы ====================================================

-- students: ученик видит свою строку; учитель — все (review/planning). Writes — только gateway.
alter table public.students enable row level security;
drop policy if exists students_select_own     on public.students;
drop policy if exists students_select_teacher on public.students;
create policy students_select_own     on public.students for select to authenticated
  using (telegram_id = public.jwt_student_id());
create policy students_select_teacher on public.students for select to authenticated
  using (public.jwt_app_role() = 'teacher');
revoke insert, update, delete on public.students from anon, authenticated;

-- assignments: ученик — свои; учитель — все (проверка/планирование/индивидуальные).
alter table public.assignments enable row level security;
drop policy if exists assignments_select_own     on public.assignments;
drop policy if exists assignments_select_teacher on public.assignments;
create policy assignments_select_own     on public.assignments for select to authenticated
  using (student_id = public.jwt_student_id());
create policy assignments_select_teacher on public.assignments for select to authenticated
  using (public.jwt_app_role() = 'teacher');
revoke insert, update, delete on public.assignments from anon, authenticated;

-- balance_history: только свой ученик (учителю не нужна). Запись — только add_huikons (definer).
alter table public.balance_history enable row level security;
drop policy if exists balance_history_select_own on public.balance_history;
create policy balance_history_select_own on public.balance_history for select to authenticated
  using (student_id = public.jwt_student_id());
revoke insert, update, delete on public.balance_history from anon, authenticated;

-- weekly_mock_exams: ученик — свои; учитель — все (запись/траектория пробника).
alter table public.weekly_mock_exams enable row level security;
drop policy if exists weekly_mock_exams_select_own     on public.weekly_mock_exams;
drop policy if exists weekly_mock_exams_select_teacher on public.weekly_mock_exams;
create policy weekly_mock_exams_select_own     on public.weekly_mock_exams for select to authenticated
  using (student_id = public.jwt_student_id());
create policy weekly_mock_exams_select_teacher on public.weekly_mock_exams for select to authenticated
  using (public.jwt_app_role() = 'teacher');
revoke insert, update, delete on public.weekly_mock_exams from anon, authenticated;

-- mock_exam_results: только свой ученик (legacy; live-читатель — будущий parent Edge, T10-10B).
alter table public.mock_exam_results enable row level security;
drop policy if exists mock_exam_results_select_own on public.mock_exam_results;
create policy mock_exam_results_select_own on public.mock_exam_results for select to authenticated
  using (student_id = public.jwt_student_id());
revoke insert, update, delete on public.mock_exam_results from anon, authenticated;

-- === DENY-CLIENT / DENY-ALL таблицы (RLS on, без политик, revoke all) =========================
-- Доступ только definer-gateway'ям (owner) и service_role (BYPASSRLS). Клиент — ни read, ни write.

-- mock_exam_reward_log: pay-once ledger пробника.
alter table public.mock_exam_reward_log enable row level security;
revoke all on public.mock_exam_reward_log from anon, authenticated;

-- parent_links: privacy; доступ только будущему parent-bot Edge (T10-10B).
alter table public.parent_links enable row level security;
revoke all on public.parent_links from anon, authenticated;

-- homework_submissions: legacy, не используется (SPEC §8 — deny-all).
alter table public.homework_submissions enable row level security;
revoke all on public.homework_submissions from anon, authenticated;

-- student_payments: RLS уже был on (deny-all); фиксируем deny-client и по grants. Пишет Apps
-- Script под service_role (BYPASSRLS).
alter table public.student_payments enable row level security;
revoke all on public.student_payments from anon, authenticated;

commit;

-- =============================================================================
-- ROLLBACK — возвращает pre-card grants/policies ТОЧНО (student_payments остаётся RLS-on, каким и
-- был до карты; остальные 8 — RLS off; политики сняты; default-гранты anon/authenticated возвращены):
--   begin;
--   drop policy if exists students_select_own            on public.students;
--   drop policy if exists students_select_teacher        on public.students;
--   drop policy if exists assignments_select_own         on public.assignments;
--   drop policy if exists assignments_select_teacher     on public.assignments;
--   drop policy if exists balance_history_select_own     on public.balance_history;
--   drop policy if exists weekly_mock_exams_select_own     on public.weekly_mock_exams;
--   drop policy if exists weekly_mock_exams_select_teacher on public.weekly_mock_exams;
--   drop policy if exists mock_exam_results_select_own   on public.mock_exam_results;
--   alter table public.students             disable row level security;
--   alter table public.assignments          disable row level security;
--   alter table public.balance_history      disable row level security;
--   alter table public.weekly_mock_exams    disable row level security;
--   alter table public.mock_exam_results    disable row level security;
--   alter table public.mock_exam_reward_log disable row level security;
--   alter table public.parent_links         disable row level security;
--   alter table public.homework_submissions disable row level security;
--   -- student_payments НЕ трогаем (был on до карты).
--   grant select, insert, update, delete on public.students             to anon, authenticated;
--   grant select, insert, update, delete on public.assignments          to anon, authenticated;
--   grant select, insert, update, delete on public.balance_history      to anon, authenticated;
--   grant select, insert, update, delete on public.weekly_mock_exams    to anon, authenticated;
--   grant select, insert, update, delete on public.mock_exam_results    to anon, authenticated;
--   grant select, insert, update, delete on public.mock_exam_reward_log to anon, authenticated;
--   grant select, insert, update, delete on public.parent_links         to anon, authenticated;
--   grant select, insert, update, delete on public.homework_submissions to anon, authenticated;
--   grant select, insert, update, delete on public.student_payments     to anon, authenticated;
--   commit;
--   drop index if exists public.idx_balance_history_student;
--   drop function if exists public.jwt_student_id();
--   drop function if exists public.jwt_app_role();
-- =============================================================================
