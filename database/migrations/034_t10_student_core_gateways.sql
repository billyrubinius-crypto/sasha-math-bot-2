-- =============================================================================
-- 034_t10_student_core_gateways.sql — T10-04A (student core mutation gateways)
-- (Bot 2.0, T10; SPEC_T10.md §§3.2, 4, 5; карточка T10-04A)
--
-- Убирает identity-sensitive прямые writes ученика для профиля и сдачи задания, оставляя legacy
-- дорогу параллельно до T10-11. Два новых public gateway RPC читают identity ТОЛЬКО из JWT-claims
-- (private.current_app_role/current_telegram_id, T10-01), не принимают student ID и проверяют
-- app_role='student'. SECURITY DEFINER с фиксированным search_path и явными grants только
-- authenticated (anon новый gateway не получает). Экономика/награды/settlement не трогаются:
-- сдача задания награды не начисляет (G11 — платит только приёмка учителем), поэтому двойной
-- награды здесь нет. RLS не включается (это T10-08A/B); auth_mode не меняется.
--
-- Дополнительно (обязательная коррекция контракта создания ученика, решение пользователя по
-- расхождению rating): forward-only смена дефолта public.students.rating 50 -> 0, чтобы новый
-- ученик стартовал с 0 очков сезона и в authed-пути (строку при auth создаёт T10-02 bridge по
-- дефолту), как и в legacy create-profile. Migration 033 НЕ переписывается — коррекция реально
-- применяется здесь, через 034. Существующие строки students массово НЕ обновляются: их текущий
-- rating — заработанные очки сезона.
-- =============================================================================

-- --- 0. Коррекция дефолта rating (forward-only; существующие строки не трогаем) --------------
alter table public.students alter column rating set default 0;

-- --- 1. ensure_student_self — идемпотентное создание СВОЕЙ строки students -------------------
-- Identity из claim (не из аргумента). Имя/username — косметика из Telegram, разрешены как
-- параметры (не дают прав). rating=0 указывается явно как defense-in-depth поверх нового дефолта.
-- on conflict do nothing: существующая строка (в т.ч. созданная T10-02 auth) не меняется.
create or replace function public.ensure_student_self(
  p_name     text default null,
  p_username text default null)
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

  insert into public.students (telegram_id, name, telegram_username, rating, huikons, lives, current_streak)
    values (v_tid, p_name, p_username, 0, 0, 3, 0)
  on conflict (telegram_id) do nothing;
end;
$function$;

-- --- 2. submit_assignment_self — сдача/пересдача СВОЕГО задания ------------------------------
-- Заменяет прямой browser UPDATE assignments (photo_url/status/submitted_at). Проверяет:
--   * app_role='student', identity из claim;
--   * owner (assignment.student_id = telegram_id из claim);
--   * допустимый source-статус: активное задание в статусе 'assigned', либо возвращённое
--     ('checked' + approval_status='rejected') — те же состояния, что показывает клиент;
--   * scheduled/revision-окно: daily-первая сдача — только в свой день по МСК; daily-возврат —
--     только пока живо серверное revision_deadline_at; weekly/individual — как раньше (без daily-окна);
--   * допустимый URL: непустой JSON-массив из >=1 https-ссылки.
-- Поля revision-жизненного цикла (first_submitted_at, submitted_at:=now(), revision_count,
-- revision_deadline_at) проставляет существующий триггер trg_assignments_revision_lifecycle —
-- он срабатывает и на этот UPDATE, поэтому здесь они НЕ дублируются. Row lock (for update)
-- сериализует конкурентные сдачи; повторная сдача уже 'submitted'-строки отсекается проверкой
-- статуса (второго эффекта нет).
create or replace function public.submit_assignment_self(
  p_assignment_id uuid,
  p_photo_url     text)
 returns void
 language plpgsql
 security definer
 set search_path = ''
as $function$
declare
  v_tid       bigint;
  v_a         public.assignments%rowtype;
  v_today_msk date;
  v_is_photos boolean;
begin
  if private.current_app_role() is distinct from 'student' then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  v_tid := private.current_telegram_id();
  if v_tid is null or v_tid <= 0 then
    raise exception 'no student identity' using errcode = '42501';
  end if;
  if p_assignment_id is null then
    raise exception 'assignment required' using errcode = '22023';
  end if;

  -- Допустимый URL: JSON-массив из >=1 элемента, каждый — https-ссылка.
  begin
    select bool_and(value like 'https://%') and count(*) >= 1
      into v_is_photos
      from json_array_elements_text(p_photo_url::json);
  exception when others then
    v_is_photos := false;
  end;
  if p_photo_url is null or length(p_photo_url) = 0 or coalesce(v_is_photos, false) = false then
    raise exception 'invalid photo url' using errcode = '22023';
  end if;

  -- Owner + row lock. Не найдено / чужое — одинаковый отказ (не раскрываем существование).
  select * into v_a
    from public.assignments
   where id = p_assignment_id and student_id = v_tid
   for update;
  if not found then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  -- Задание должно быть активным.
  if v_a.activation_status is distinct from 'active' then
    raise exception 'not submittable' using errcode = '22023';
  end if;

  -- Допустимый source-статус: первая сдача (assigned) либо возврат (checked+rejected).
  if not (v_a.status = 'assigned'
          or (v_a.status = 'checked' and v_a.approval_status = 'rejected')) then
    raise exception 'not submittable' using errcode = '22023';
  end if;

  -- scheduled/revision-окно для daily (weekly/individual окном daily не ограничены).
  if v_a.type = 'daily' then
    v_today_msk := (now() at time zone 'Europe/Moscow')::date;
    if v_a.status = 'assigned' then
      if v_a.scheduled_date is distinct from v_today_msk then
        raise exception 'window closed' using errcode = '22023';
      end if;
    else
      -- возвращённая daily: только пока живо серверное окно исправления (W04)
      if v_a.revision_deadline_at is null or now() >= v_a.revision_deadline_at then
        raise exception 'window closed' using errcode = '22023';
      end if;
    end if;
  end if;

  -- Сдача. submitted_at меняем на now() => триггер фиксирует submitted_at/first_submitted_at.
  update public.assignments
     set photo_url    = p_photo_url,
         status       = 'submitted',
         submitted_at = now()
   where id = p_assignment_id;
end;
$function$;

-- --- 3. Явные grants: authenticated (student JWT). anon/public новый gateway НЕ получают ------
revoke all on function public.ensure_student_self(text, text) from public, anon;
revoke all on function public.submit_assignment_self(uuid, text) from public, anon;
grant execute on function public.ensure_student_self(text, text) to authenticated;
grant execute on function public.submit_assignment_self(uuid, text) to authenticated;

-- =============================================================================
-- ROLLBACK:
--   drop function if exists public.submit_assignment_self(uuid, text);
--   drop function if exists public.ensure_student_self(text, text);
--   alter table public.students alter column rating set default 50;  -- вернуть прежний дефолт
-- =============================================================================
