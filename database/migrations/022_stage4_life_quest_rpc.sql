-- =============================================================================
-- 022_stage4_life_quest_rpc.sql — Персональный life challenge: random, замена, self-report
-- (Bot 2.0, Stage 4, карточка U02B; SPEC_STAGE4.md §§2–5)
--
-- Зачем: поверх спящей схемы U02A (миграция 021) добавляет ТОЛЬКО серверный жизненный слот:
-- один сохранённый случайный вариант на календарную дату MSK, до двух замен и атомарные
-- 3 бублика по self-report. Math, combo, достижения, teacher CRUD, UI, цены и cron —
-- отдельные карточки (U02C/U03/U04/U06/U07), здесь их НЕТ.
--
-- Только функции; таблиц/колонок/индексов не добавляет. Имена RPC фиксируются здесь и
-- переиспользуются U02C (ensure_daily_quest) и U03/U04 (get/replace/claim).
--
-- Гейт генерации/выплат: stage4_generation_active(). Пока economy_config
-- stage4_generation_enabled=false (U02A) — RPC ничего не генерируют и не платят. Dev-тест
-- временно включает флаг и полностью очищает синтетические данные.
--
-- RLS/идентичность: как во всём проекте — функции SECURITY INVOKER, RLS выключен. Привязка
-- student_id к Telegram identity и production-доступ — gate T10, внутри карточки не проектируются.
--
-- Идемпотентность и конкуренция:
--   * первое чтение под FOR UPDATE создаёт максимум одну дневную строку и один option 0;
--   * повтор/второй клиент возвращают сохранённый вариант, а не новый random;
--   * замена сериализуется, исключает все показанные сегодня шаблоны, пишет option 1/2;
--   * claim пишет ledger life=3 и вызывает add_huikons ровно при реальной вставке (pay-once).
-- =============================================================================

-- --- 1. Гейт запуска Stage 4 -------------------------------------------------
-- true только когда генерация включена и фактическое время старта наступило (или ещё не задано
-- в dev). До cutover (stage4_started_at в будущем) и при disabled — false: ничего не генерим.
create or replace function public.stage4_generation_active()
 returns boolean
 language sql
 stable
as $function$
  select ec.stage4_generation_enabled
     and (ec.stage4_started_at is null or now() >= ec.stage4_started_at)
    from public.economy_config ec
   where ec.id;
$function$;

-- --- 2. Взвешенный случайный выбор активного шаблона -------------------------
-- A-Res (Efraimidis–Spirakis): ключ power(random(), 1/weight), больший weight — выше шанс.
-- p_exclude — коды, которые нельзя выдавать (вчерашний / уже показанные сегодня). Пустой
-- массив ничего не исключает; null трактуется как пустой.
create or replace function public.pick_life_template(p_exclude text[])
 returns text
 language sql
 volatile
as $function$
  select template_code
    from public.life_quest_templates
   where active
     and (p_exclude is null or template_code <> all(p_exclude))
   order by power(random(), 1.0 / weight) desc
   limit 1;
$function$;

-- --- 3. Read-модель дневного набора (переиспользуется всеми RPC) -------------
-- Только для собственного ученика (student Mini App, §9). Teacher/parent life history не
-- читают — это отдельные RPC U03/U05, здесь не создаются.
create or replace function public.daily_quest_state(p_student_id bigint, p_quest_date date)
 returns json
 language sql
 stable
as $function$
  with q as (
    select * from public.student_daily_quests
     where student_id = p_student_id and quest_date = p_quest_date
  ),
  life_paid as (
    select 1 from public.daily_quest_reward_log
     where student_id = p_student_id and quest_date = p_quest_date and reward_kind = 'life'
  )
  select json_build_object(
    'quest_date',          p_quest_date,
    'exists',              exists (select 1 from q),
    'daily_assignment_id', (select daily_assignment_id from q),
    'replacements_used',   coalesce((select replacements_used from q), 0),
    'replacements_left',   greatest(2 - coalesce((select replacements_used from q), 0), 0),
    'life_paid',           exists (select 1 from life_paid),
    'generation_active',   public.stage4_generation_active(),
    'life', (
      select json_build_object(
        'template_code', t.template_code,
        'name',          t.name,
        'description',   t.description,
        'category',      t.category
      )
      from q join public.life_quest_templates t on t.template_code = q.life_template_code
    ),
    'can_replace',
      coalesce((select replacements_used from q), 0) < 2
      and (select life_template_code from q) is not null
      and not exists (select 1 from life_paid)
      and public.stage4_generation_active(),
    'options', coalesce((
      select json_agg(
               json_build_object('ordinal', o.ordinal, 'template_code', o.template_code)
               order by o.ordinal)
        from public.student_daily_quest_options o
        join q on o.daily_quest_id = q.id
    ), '[]'::json)
  );
$function$;

-- --- 4. Internal ensure дневного набора (вызывается U02C) --------------------
-- Создаёт максимум одну дневную строку, привязывает сегодняшнюю daily по scheduled_date,
-- и (только для сегодня, при активной генерации, один раз) выбирает life template + option 0.
-- p_generate_life=false (U02C settlement) — прошлый/сегодняшний life НЕ генерируется:
-- задним числом жизненный слот недоступен.
create or replace function public.ensure_daily_quest(
  p_student_id     bigint,
  p_quest_date     date,
  p_generate_life  boolean
)
 returns uuid
 language plpgsql
as $function$
declare
  v_id        uuid;
  v_life      text;
  v_target    uuid;
  v_today     date := (now() at time zone 'Europe/Moscow')::date;
  v_daily     uuid;
  v_prev_life text;
  v_pick      text;
begin
  -- 1. одна дневная строка на (ученик, дата)
  insert into public.student_daily_quests (student_id, quest_date)
    values (p_student_id, p_quest_date)
    on conflict (student_id, quest_date) do nothing;

  -- 2. блокировка строки: сериализует конкурентные первое чтение / замену
  select id, life_template_code, daily_assignment_id
    into v_id, v_life, v_target
    from public.student_daily_quests
   where student_id = p_student_id and quest_date = p_quest_date
   for update;

  -- 3. привязать сегодняшнюю daily, если target ещё пуст (начатый target не подменяем)
  if v_target is null then
    select a.id into v_daily
      from public.assignments a
     where a.student_id = p_student_id
       and a.type = 'daily'
       and a.scheduled_date = p_quest_date
     order by (a.plan_item_id is not null) desc, a.created_at
     limit 1;
    if v_daily is not null then
      update public.student_daily_quests
         set daily_assignment_id = v_daily, updated_at = now()
       where id = v_id;
    end if;
  end if;

  -- 4. генерация life — только сегодня, только при активной генерации, только один раз
  if p_generate_life
     and p_quest_date = v_today
     and v_life is null
     and public.stage4_generation_active() then
    -- по возможности исключить точный шаблон предыдущего дня
    select life_template_code into v_prev_life
      from public.student_daily_quests
     where student_id = p_student_id and quest_date = p_quest_date - 1;
    v_pick := public.pick_life_template(
                case when v_prev_life is null then array[]::text[] else array[v_prev_life] end);
    if v_pick is null then
      -- активен только вчерашний шаблон (или каталог пуст) — разрешаем его/пропускаем
      v_pick := public.pick_life_template(array[]::text[]);
    end if;
    if v_pick is not null then
      update public.student_daily_quests
         set life_template_code = v_pick, updated_at = now()
       where id = v_id;
      insert into public.student_daily_quest_options (daily_quest_id, template_code, ordinal)
        values (v_id, v_pick, 0);
    end if;
  end if;

  return v_id;
end;
$function$;

-- --- 5. Публичный read/generate сегодняшнего набора --------------------------
-- При активной генерации гарантирует дневной набор и life; при disabled ничего не пишет,
-- просто возвращает read-модель (exists=false, generation_active=false).
create or replace function public.get_daily_quests(p_student_id bigint)
 returns json
 language plpgsql
as $function$
declare
  v_today date := (now() at time zone 'Europe/Moscow')::date;
begin
  if public.stage4_generation_active() then
    perform public.ensure_daily_quest(p_student_id, v_today, true);
  end if;
  return public.daily_quest_state(p_student_id, v_today);
end;
$function$;

-- --- 6. Замена жизненного челленджа ------------------------------------------
-- Только сегодня, до self-report, максимум два раза. Исключает все показанные сегодня
-- шаблоны, атомарно меняет current template и счётчик, пишет option 1/2. Нехватка вариантов
-- или недоступность — raise (откат транзакции => без изменения состояния).
create or replace function public.replace_life_quest(p_student_id bigint)
 returns json
 language plpgsql
as $function$
declare
  v_today date := (now() at time zone 'Europe/Moscow')::date;
  v_id    uuid;
  v_used  integer;
  v_life  text;
  v_excl  text[];
  v_pick  text;
begin
  if not public.stage4_generation_active() then
    raise exception 'Ежедневные квесты ещё не запущены';
  end if;

  select id, replacements_used, life_template_code
    into v_id, v_used, v_life
    from public.student_daily_quests
   where student_id = p_student_id and quest_date = v_today
   for update;

  if not found or v_life is null then
    raise exception 'Сегодняшний жизненный челлендж не сгенерирован';
  end if;
  if exists (select 1 from public.daily_quest_reward_log
              where student_id = p_student_id and quest_date = v_today and reward_kind = 'life') then
    raise exception 'Жизненный челлендж уже подтверждён — замена недоступна';
  end if;
  if v_used >= 2 then
    raise exception 'Достигнут лимит замен на сегодня';
  end if;

  -- исключить все шаблоны, уже показанные сегодня
  select coalesce(array_agg(template_code), array[]::text[])
    into v_excl
    from public.student_daily_quest_options
   where daily_quest_id = v_id;

  v_pick := public.pick_life_template(v_excl);
  if v_pick is null then
    raise exception 'Нет других доступных челленджей для замены';
  end if;

  update public.student_daily_quests
     set life_template_code = v_pick,
         replacements_used  = v_used + 1,
         updated_at         = now()
   where id = v_id;

  insert into public.student_daily_quest_options (daily_quest_id, template_code, ordinal)
    values (v_id, v_pick, v_used + 1);

  return public.daily_quest_state(p_student_id, v_today);
end;
$function$;

-- --- 7. Self-report жизненного челленджа (life = 3) --------------------------
-- Только сегодня, только текущий template. Вставляет ledger life=3, затем вызывает
-- add_huikons ТОЛЬКО при реальной вставке. Повтор/двойной клик/конкуренция — no-op с тем же
-- read result. Combo и math здесь не платятся (U02C).
create or replace function public.claim_life_quest(p_student_id bigint)
 returns json
 language plpgsql
as $function$
declare
  v_today date := (now() at time zone 'Europe/Moscow')::date;
  v_id    uuid;
  v_life  text;
  v_paid  integer;
begin
  if not public.stage4_generation_active() then
    raise exception 'Ежедневные квесты ещё не запущены';
  end if;

  select id, life_template_code
    into v_id, v_life
    from public.student_daily_quests
   where student_id = p_student_id and quest_date = v_today
   for update;

  if not found or v_life is null then
    raise exception 'Сегодняшний жизненный челлендж не сгенерирован';
  end if;

  insert into public.daily_quest_reward_log (student_id, quest_date, reward_kind, bubliks)
    values (p_student_id, v_today, 'life', 3)
    on conflict (student_id, quest_date, reward_kind) do nothing;
  get diagnostics v_paid = row_count;
  if v_paid = 1 then
    perform public.add_huikons(p_student_id, 3, 'daily_quest_life');
  end if;

  return public.daily_quest_state(p_student_id, v_today);
end;
$function$;

-- =============================================================================
-- ROLLBACK (только функции; данные/балансы/ledger не затрагиваются — dev-тест сам чистит
-- синтетику и возвращает stage4_generation_enabled=false):
--
--   drop function if exists public.claim_life_quest(bigint);
--   drop function if exists public.replace_life_quest(bigint);
--   drop function if exists public.get_daily_quests(bigint);
--   drop function if exists public.ensure_daily_quest(bigint, date, boolean);
--   drop function if exists public.daily_quest_state(bigint, date);
--   drop function if exists public.pick_life_template(text[]);
--   drop function if exists public.stage4_generation_active();
-- =============================================================================
