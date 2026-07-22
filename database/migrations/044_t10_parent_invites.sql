-- =============================================================================
-- 044_t10_parent_invites.sql — T10-10B (одноразовые приглашения родителя)
-- (Bot 2.0, T10; SPEC_T10.md §§3.4-3.5; карточка T10-10B; после 042/043 RLS)
--
-- Зачем. До этой миграции родитель привязывался по ОТКРЫТОМУ telegram_id ученика из ссылки
-- (?start=<telegram_id>): любой, кто знает/подберёт ID, получал доступ к результатам ребёнка —
-- проверка «такой ученик существует» правом на привязку не является. Архитектор отклонил этот
-- контракт. Реальных пользователей у Bot 2.0 ещё нет, поэтому legacy-совместимость не сохраняем:
-- ссылка ?start=<telegram_id> удаляется из клиента и бота вместе с этой миграцией.
--
-- Новый контракт: ученик в Mini App выпускает криптографически случайный одноразовый токен;
-- в ссылку уходит ТОЛЬКО он, без student_id. В БД хранится не токен, а его SHA-256 hash, поэтому
-- дамп/лог таблицы не даёт рабочих приглашений. Поглощение атомарно (UPDATE ... WHERE consumed_at
-- is null), поэтому один токен успешно срабатывает ровно один раз даже при гонке.
--
-- Экономика/UI/существующие parent_links не затрагиваются: старые связки продолжают работать,
-- эта миграция добавляет только новый безопасный способ создать связку.
-- =============================================================================

-- --- 1. Таблица приглашений (deny-client: читает и пишет только SECURITY DEFINER ниже) ---------
create table if not exists public.parent_invites (
  id                    uuid        primary key default gen_random_uuid(),
  student_id            bigint      not null references public.students (telegram_id),
  token_hash            text        not null unique,          -- hex SHA-256; сам токен НЕ хранится
  created_at            timestamptz not null default now(),
  expires_at            timestamptz not null,
  consumed_at           timestamptz,
  consumed_by_parent_id bigint,
  -- поглощение — это всегда пара «когда» + «кем»: полусостояния быть не может
  constraint parent_invites_consumed_pair
    check ((consumed_at is null) = (consumed_by_parent_id is null))
);

create index if not exists idx_parent_invites_student on public.parent_invites (student_id);

-- Клиент (anon/authenticated) не имеет к таблице никакого доступа: RLS включён, политик нет,
-- grants отозваны. Единственные легальные пути — две функции ниже (SECURITY DEFINER, owner).
alter table public.parent_invites enable row level security;
revoke all on public.parent_invites from anon, authenticated;

-- --- 2. Ученик выпускает приглашение (student self-gateway, паттерн T10-04A/06E) ---------------
-- Не принимает student_id: ученик берётся из JWT-claim. Возвращает ПЛЕЙНТЕКСТ токена ровно один
-- раз (клиент сразу кладёт его в ссылку); в таблицу уходит только hash.
-- Токен: два gen_random_uuid() (CSPRNG ядра, ~122 бита каждый) без дефисов, обрезанные до 48 hex-
-- символов — укладывается в лимит Telegram start-payload (64 символа, [A-Za-z0-9_-]).
create or replace function public.create_parent_invite_self()
 returns text
 language plpgsql
 security definer
 set search_path = ''
as $function$
declare
  v_tid    bigint;
  v_token  text;
  v_active integer;
begin
  if private.current_app_role() is distinct from 'student' then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  v_tid := private.current_telegram_id();
  if v_tid is null or v_tid <= 0 then
    raise exception 'no student identity' using errcode = '42501';
  end if;

  -- Потолок незакрытых приглашений: ученик может выпустить ссылку маме и папе, но не может
  -- бесконтрольно плодить живые токены (и раздувать таблицу).
  select count(*) into v_active
    from public.parent_invites
   where student_id = v_tid and consumed_at is null and expires_at > now();
  if v_active >= 5 then
    raise exception 'too many active invites' using errcode = '22023';
  end if;

  v_token := replace(gen_random_uuid()::text, '-', '')
          || substr(replace(gen_random_uuid()::text, '-', ''), 1, 16);

  insert into public.parent_invites (student_id, token_hash, expires_at)
  values (v_tid,
          encode(sha256(convert_to(v_token, 'UTF8')), 'hex'),
          now() + interval '24 hours');

  return v_token;
end;
$function$;

revoke all on function public.create_parent_invite_self() from public, anon;
grant execute on function public.create_parent_invite_self() to authenticated;

-- --- 3. Родительский бот поглощает приглашение (service_role only, через parent-bot-api) -------
-- Принимает УЖЕ ПОСЧИТАННЫЙ hash: плейнтекст токена не доходит до Postgres вообще (не попадает
-- ни в pg_stat_statements, ни в логи запросов). student_id наружу не возвращается — только имя,
-- и только при успехе.
--
-- Все неуспешные ветки (нет такого токена / просрочен / уже поглощён другим родителем / битый
-- формат) дают ОДИН И ТОТ ЖЕ ответ {'status':'invalid'} — существование ученика или токена
-- по ответу не различимо.
create or replace function public.consume_parent_invite(p_token_hash text, p_parent_id bigint)
 returns json
 language plpgsql
 security definer
 set search_path = ''
as $function$
declare
  v_student_id bigint;
  v_name       text;
begin
  if p_token_hash is null or p_token_hash !~ '^[0-9a-f]{64}$'
     or p_parent_id is null or p_parent_id <= 0 then
    return json_build_object('status', 'invalid');
  end if;

  -- Атомарное поглощение: строка блокируется этим UPDATE, поэтому при гонке второй вызов увидит
  -- уже проставленный consumed_at и получит 0 строк. Отдельного SELECT ... FOR UPDATE не нужно.
  update public.parent_invites
     set consumed_at = now(),
         consumed_by_parent_id = p_parent_id
   where token_hash = p_token_hash
     and consumed_at is null
     and expires_at > now()
  returning student_id into v_student_id;

  if v_student_id is null then
    -- Идемпотентный повтор: ТОТ ЖЕ родитель повторно открыл ту же ссылку (двойной тап, перезапуск
    -- бота). Доступ у него уже есть, поэтому это успех, а не отказ. Любой ДРУГОЙ родитель сюда
    -- не попадёт — condition сверяет consumed_by_parent_id.
    select student_id into v_student_id
      from public.parent_invites
     where token_hash = p_token_hash
       and consumed_by_parent_id = p_parent_id;

    if v_student_id is null then
      return json_build_object('status', 'invalid');
    end if;
  end if;

  -- Связка идемпотентна (unique parent_telegram_id, student_id) — существующие parent_links,
  -- созданные до этой миграции, не затрагиваются.
  insert into public.parent_links (parent_telegram_id, student_id)
  values (p_parent_id, v_student_id)
  on conflict (parent_telegram_id, student_id) do nothing;

  select name into v_name from public.students where telegram_id = v_student_id;

  return json_build_object('status', 'ok', 'name', v_name);
end;
$function$;

revoke all on function public.consume_parent_invite(text, bigint) from public, anon, authenticated;
grant execute on function public.consume_parent_invite(text, bigint) to service_role;

-- =============================================================================
-- ROLLBACK (полный; существующие parent_links при этом сохраняются):
--   drop function if exists public.consume_parent_invite(text, bigint);
--   drop function if exists public.create_parent_invite_self();
--   drop table if exists public.parent_invites;
-- Клиент/бот после отката работать не будут (старый путь ?start=<telegram_id> удалён намеренно) —
-- откатывать нужно вместе с коммитом кода.
-- =============================================================================
