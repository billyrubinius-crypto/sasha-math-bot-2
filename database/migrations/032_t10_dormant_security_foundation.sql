-- =============================================================================
-- 032_t10_dormant_security_foundation.sql — T10-01
-- (Bot 2.0, T10 production security gate; SPEC_T10.md §§1-3, 6; карточка T10-01)
--
-- ВЫКЛЮЧЕННЫЙ (dormant) фундамент T10. Ничего в поведении текущих клиентов не меняет:
--   * НЕ включает RLS на существующих business-таблицах и НЕ создаёт на них политик;
--   * НЕ отзывает старые grants и НЕ трогает legacy anon-путь (index/teacher/боты работают как есть);
--   * НЕ зависит от legacy JWT secret и НЕ печатает никаких секретов.
--
-- Создаёт ЗАКРЫТУЮ схему `private` (не входит в exposed schemas Data API — PostgREST её не видит),
-- пять security-таблиц, claim-helper функции с фиксированным search_path='' и ОДНУ публичную
-- read-only RPC минимального runtime-mode. Все security-объекты — opt-in: явные revoke от
-- anon/authenticated, RLS deny-client как defense-in-depth (даже при будущем экспонировании схемы).
--
-- runtime mode стартует как 'legacy' (§6 шаг 1). Реальный auth/RLS/enforced включаются
-- следующими карточками очереди SPEC_T10 §7; здесь их НЕТ.
--
-- Ключевая церемония (ES256 signing key) выполняется owner'ом вне SQL: private JWK генерируется
-- официальным Supabase CLI локально, импортируется как signing key и живёт только в Edge secrets.
-- В git/SQL/отчёты/чат попадает только kid. Эта миграция от legacy JWT secret не зависит.
-- =============================================================================

-- --- 1. Закрытая схема private (не exposed для Data API) -------------------------------------
create schema if not exists private;
-- Ни PUBLIC, ни anon/authenticated не получают USAGE: схема недостижима через publishable key.
revoke all on schema private from public;
revoke usage on schema private from anon, authenticated;

-- --- 2. security_principals — стабильная личность (sub в claims) -----------------------------
-- Student привязан к Telegram ID, teacher — к стабильному коду. token_version — per-principal
-- ревокейшн (в claim). FK на students НЕ добавляется: строку students создаёт student-auth Edge
-- (T10-02); в dormant-фундаменте связь не форсируется.
create table if not exists private.security_principals (
  id            uuid        primary key default gen_random_uuid(),
  app_role      text        not null check (app_role in ('student','teacher')),
  telegram_id   bigint,                                    -- только student
  teacher_id    text,                                      -- только teacher
  token_version integer     not null default 1,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint security_principals_shape check (
    (app_role = 'student' and telegram_id is not null and teacher_id is null) or
    (app_role = 'teacher' and teacher_id  is not null and telegram_id is null)
  )
);
create unique index if not exists uq_security_principals_student
  on private.security_principals (telegram_id) where app_role = 'student';
create unique index if not exists uq_security_principals_teacher
  on private.security_principals (teacher_id)  where app_role = 'teacher';

-- --- 3. security_runtime_config — singleton runtime-mode ------------------------------------
-- auth_mode: legacy -> shadow -> enforced (§6). teacher_token_version — глобальная немедленная
-- ревокация всех teacher JWT/refresh-сессий (§3.3).
create table if not exists private.security_runtime_config (
  id                    boolean     primary key default true check (id),
  auth_mode             text        not null default 'legacy' check (auth_mode in ('legacy','shadow','enforced')),
  teacher_token_version integer     not null default 1,
  updated_at            timestamptz not null default now()
);
insert into private.security_runtime_config (id, auth_mode) values (true, 'legacy')
  on conflict (id) do nothing;

-- --- 4. security_audit_log — вход/отказ/события без пароля и токенов -------------------------
create table if not exists private.security_audit_log (
  id             uuid        primary key default gen_random_uuid(),
  event_type     text        not null,
  app_role       text,
  principal_id   uuid        references private.security_principals (id),
  ip_fingerprint text,
  detail         jsonb,
  created_at     timestamptz not null default now()
);
create index if not exists idx_security_audit_log_created on private.security_audit_log (created_at);

-- --- 5. teacher_sessions — opaque refresh-сессии (хеш токена, ротация) -----------------------
create table if not exists private.teacher_sessions (
  id                 uuid        primary key default gen_random_uuid(),
  principal_id       uuid        not null references private.security_principals (id),
  refresh_token_hash text        not null,
  created_at         timestamptz not null default now(),
  expires_at         timestamptz not null,
  rotated_at         timestamptz,
  revoked            boolean     not null default false
);
create index if not exists idx_teacher_sessions_principal on private.teacher_sessions (principal_id);

-- --- 6. security_rate_limits — окна попыток по fingerprint -----------------------------------
create table if not exists private.security_rate_limits (
  bucket       text        not null,                       -- напр. 'teacher_login'
  fingerprint  text        not null,                       -- IP fingerprint
  window_start timestamptz not null,
  attempts     integer     not null default 0,
  primary key (bucket, fingerprint, window_start)
);

-- --- 7. RLS deny-client на все security-таблицы (defense-in-depth) ---------------------------
-- Схема private и так недостижима через Data API; RLS без политик = запрет всем ролям, кроме
-- владельца и SECURITY DEFINER-функций. Политик на business-таблицах здесь НЕТ.
alter table private.security_principals     enable row level security;
alter table private.security_runtime_config enable row level security;
alter table private.security_audit_log      enable row level security;
alter table private.teacher_sessions        enable row level security;
alter table private.security_rate_limits    enable row level security;

-- --- 8. Claim-helpers (private, search_path='') ----------------------------------------------
-- Читают внешне выпущенный JWT из request.jwt.claims. В dormant-фазе НИ ОДНА политика/шлюз их
-- ещё не вызывает — они готовятся для T10-02+. Клиентский аргумент ID никогда не даёт прав (§3.1).
create or replace function private.jwt_claims()
 returns jsonb language sql stable
 set search_path = ''
as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb;
$$;

create or replace function private.current_app_role()
 returns text language sql stable
 set search_path = ''
as $$
  select private.jwt_claims() ->> 'app_role';
$$;

create or replace function private.current_principal()
 returns uuid language sql stable
 set search_path = ''
as $$
  select nullif(private.jwt_claims() ->> 'sub', '')::uuid;
$$;

create or replace function private.current_telegram_id()
 returns bigint language sql stable
 set search_path = ''
as $$
  select case when private.jwt_claims() ->> 'app_role' = 'student'
              then nullif(private.jwt_claims() ->> 'telegram_id', '')::bigint
         end;
$$;

create or replace function private.current_teacher_id()
 returns text language sql stable
 set search_path = ''
as $$
  select case when private.jwt_claims() ->> 'app_role' = 'teacher'
              then private.jwt_claims() ->> 'teacher_id'
         end;
$$;

-- --- 9. Публичная read-only RPC минимального runtime-mode ------------------------------------
-- Единственный anon-доступный новый объект. Возвращает ТОЛЬКО auth_mode (не персональные данные).
-- SECURITY DEFINER: читает private.security_runtime_config под владельцем, не давая anon USAGE на private.
create or replace function public.security_auth_mode()
 returns text language sql stable security definer
 set search_path = ''
as $$
  select auth_mode from private.security_runtime_config where id;
$$;

-- --- 10. Явные grants: security-объекты opt-in ----------------------------------------------
revoke all on all tables    in schema private from anon, authenticated;
revoke all on all functions in schema private from anon, authenticated, public;
-- Публичная runtime-RPC: снять default PUBLIC execute, выдать только anon/authenticated.
revoke all on function public.security_auth_mode() from public;
grant execute on function public.security_auth_mode() to anon, authenticated;

-- =============================================================================
-- ROLLBACK (dormant foundation; ни одной business-политики/гранта не тронуто):
--   drop function if exists public.security_auth_mode();
--   drop schema if exists private cascade;   -- удаляет private.* таблицы и helper-функции
-- =============================================================================
