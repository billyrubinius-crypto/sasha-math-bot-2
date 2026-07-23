-- =============================================================================
-- 048_stage4_two_life_quests.sql — T10-12C
--
-- Product decision 2026-07-23:
--   * блок «Сегодня» больше не дублирует ежедневную математику;
--   * два независимых life-квеста по 3 бублика + combo 2 за оба;
--   * максимум две замены суммарно на день;
--   * серия = подряд идущие дни с выполненными ОБОИМИ life-квестами, без отдельной выплаты;
--   * математика остаётся в assignments/weekly economy/season points.
--
-- Перед применением на уже fired dev выполнить database/releases/dev_game_reset.sql.
-- Миграция аварийно остановится, если найдёт runtime-строки квестов: реальные данные не
-- преобразуются и не удаляются молча.
-- =============================================================================

do $preflight$
begin
  if exists (select 1 from public.student_daily_quests)
     or exists (select 1 from public.student_daily_quest_options)
     or exists (select 1 from public.daily_quest_reward_log) then
    raise exception
      '048 ABORT: quest runtime не пуст; в dev сначала выполните dev_game_reset.sql';
  end if;
end
$preflight$;

-- Первый слот сохраняет историческое имя life_template_code; второй добавляется рядом.
alter table public.student_daily_quests
  add column if not exists life_template_code_2 text
    references public.life_quest_templates (template_code);

-- История замен теперь различает два слота. Один и тот же шаблон не показывается в двух
-- слотах одного дня благодаря прежнему unique(daily_quest_id, template_code).
alter table public.student_daily_quest_options
  add column if not exists slot smallint not null default 1
    check (slot in (1, 2));

alter table public.student_daily_quest_options
  drop constraint if exists student_daily_quest_options_daily_quest_id_ordinal_key;

alter table public.student_daily_quest_options
  add constraint student_daily_quest_options_daily_quest_slot_ordinal_key
  unique (daily_quest_id, slot, ordinal);

-- Новый pay-once ledger: life_1=3, life_2=3, combo=2. Preflight гарантирует отсутствие
-- старых math/life строк, поэтому изменение constraint не требует неоднозначной конвертации.
alter table public.daily_quest_reward_log
  drop constraint if exists daily_quest_reward_log_reward_kind_check;
alter table public.daily_quest_reward_log
  drop constraint if exists daily_quest_reward_log_check;

alter table public.daily_quest_reward_log
  add constraint daily_quest_reward_log_reward_kind_two_life_check
  check (reward_kind in ('life_1', 'life_2', 'combo'));

alter table public.daily_quest_reward_log
  add constraint daily_quest_reward_log_amount_two_life_check
  check (
    (reward_kind = 'life_1' and bubliks = 3) or
    (reward_kind = 'life_2' and bubliks = 3) or
    (reward_kind = 'combo'  and bubliks = 2)
  );

-- Read-модель двух life-слотов. streak_current считает текущую непрерывную серию дней,
-- закрытых обоими слотами; незавершённый сегодняшний день не обрывает вчерашнюю серию.
create or replace function public.daily_quest_state(p_student_id bigint, p_quest_date date)
 returns json
 language sql
 stable
as $function$
  with q as (
    select * from public.student_daily_quests
     where student_id = p_student_id and quest_date = p_quest_date
  ),
  life_1_paid as (
    select 1 from public.daily_quest_reward_log
     where student_id = p_student_id and quest_date = p_quest_date and reward_kind = 'life_1'
  ),
  life_2_paid as (
    select 1 from public.daily_quest_reward_log
     where student_id = p_student_id and quest_date = p_quest_date and reward_kind = 'life_2'
  ),
  combo_paid as (
    select 1 from public.daily_quest_reward_log
     where student_id = p_student_id and quest_date = p_quest_date and reward_kind = 'combo'
  ),
  both_days as (
    select quest_date
      from public.daily_quest_reward_log
     where student_id = p_student_id and reward_kind in ('life_1', 'life_2')
     group by quest_date
    having count(distinct reward_kind) = 2
  ),
  numbered as (
    select quest_date,
           quest_date - (row_number() over (order by quest_date))::integer as grp
      from both_days
  ),
  latest as (
    select quest_date, grp from numbered order by quest_date desc limit 1
  ),
  current_streak as (
    select case
      when not exists (select 1 from latest) then 0
      when (select quest_date from latest) < p_quest_date - 1 then 0
      else (select count(*) from numbered where grp = (select grp from latest))
    end as value
  )
  select json_build_object(
    'quest_date',        p_quest_date,
    'exists',            exists (select 1 from q),
    'replacements_used', coalesce((select replacements_used from q), 0),
    'replacements_left', greatest(2 - coalesce((select replacements_used from q), 0), 0),
    'life_1_paid',       exists (select 1 from life_1_paid),
    'life_2_paid',       exists (select 1 from life_2_paid),
    'combo_paid',        exists (select 1 from combo_paid),
    'generation_active', public.stage4_generation_active(),
    'streak_current',    coalesce((select value from current_streak), 0),
    'life_1', (
      select json_build_object(
        'template_code', t.template_code,
        'name', t.name,
        'description', t.description,
        'category', t.category
      )
      from q
      join public.life_quest_templates t on t.template_code = q.life_template_code
    ),
    'life_2', (
      select json_build_object(
        'template_code', t.template_code,
        'name', t.name,
        'description', t.description,
        'category', t.category
      )
      from q
      join public.life_quest_templates t on t.template_code = q.life_template_code_2
    ),
    'can_replace_1',
      coalesce((select replacements_used from q), 0) < 2
      and (select life_template_code from q) is not null
      and not exists (select 1 from life_1_paid)
      and public.stage4_generation_active(),
    'can_replace_2',
      coalesce((select replacements_used from q), 0) < 2
      and (select life_template_code_2 from q) is not null
      and not exists (select 1 from life_2_paid)
      and public.stage4_generation_active(),
    'combo_status',
      case when exists (select 1 from combo_paid) then 'completed' else 'locked' end,
    'options', coalesce((
      select json_agg(
               json_build_object(
                 'slot', o.slot,
                 'ordinal', o.ordinal,
                 'template_code', o.template_code
               )
               order by o.slot, o.ordinal)
        from public.student_daily_quest_options o
        join q on o.daily_quest_id = q.id
    ), '[]'::json)
  );
$function$;

-- Ensure создаёт два разных life-шаблона. По возможности оба отличаются и от двух шаблонов
-- предыдущего дня; fallback сохраняет главное правило — слоты текущего дня не совпадают.
create or replace function public.ensure_daily_quest(
  p_student_id     bigint,
  p_quest_date     date,
  p_generate_life  boolean
)
 returns uuid
 language plpgsql
as $function$
declare
  v_id       uuid;
  v_life_1   text;
  v_life_2   text;
  v_today    date := (now() at time zone 'Europe/Moscow')::date;
  v_prev_1   text;
  v_prev_2   text;
  v_exclude  text[];
  v_pick     text;
begin
  insert into public.student_daily_quests (student_id, quest_date)
    values (p_student_id, p_quest_date)
    on conflict (student_id, quest_date) do nothing;

  select id, life_template_code, life_template_code_2
    into v_id, v_life_1, v_life_2
    from public.student_daily_quests
   where student_id = p_student_id and quest_date = p_quest_date
   for update;

  if not p_generate_life
     or p_quest_date <> v_today
     or not public.stage4_generation_active() then
    return v_id;
  end if;

  select life_template_code, life_template_code_2
    into v_prev_1, v_prev_2
    from public.student_daily_quests
   where student_id = p_student_id and quest_date = p_quest_date - 1;

  if v_life_1 is null then
    v_exclude := array_remove(array[v_prev_1, v_prev_2], null);
    v_pick := public.pick_life_template(v_exclude);
    if v_pick is null then
      v_pick := public.pick_life_template(array[]::text[]);
    end if;
    if v_pick is not null then
      update public.student_daily_quests
         set life_template_code = v_pick, updated_at = now()
       where id = v_id;
      insert into public.student_daily_quest_options
        (daily_quest_id, template_code, slot, ordinal)
      values (v_id, v_pick, 1, 0);
      v_life_1 := v_pick;
    end if;
  end if;

  if v_life_2 is null then
    v_exclude := array_remove(array[v_life_1, v_prev_1, v_prev_2], null);
    v_pick := public.pick_life_template(v_exclude);
    if v_pick is null then
      v_pick := public.pick_life_template(array_remove(array[v_life_1], null));
    end if;
    if v_pick is not null and v_pick is distinct from v_life_1 then
      update public.student_daily_quests
         set life_template_code_2 = v_pick, updated_at = now()
       where id = v_id;
      insert into public.student_daily_quest_options
        (daily_quest_id, template_code, slot, ordinal)
      values (v_id, v_pick, 2, 0);
    end if;
  end if;

  return v_id;
end;
$function$;

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

-- Старые одноаргументные функции заменяются slot-aware сигнатурами без появления
-- дублирующих RPC. Self-gateway удаляется первым из-за зависимости от base-функции.
drop function if exists public.replace_life_quest_self();
drop function if exists public.claim_life_quest_self();
drop function if exists public.replace_life_quest(bigint);
drop function if exists public.claim_life_quest(bigint);

create function public.replace_life_quest(p_student_id bigint, p_slot smallint)
 returns json
 language plpgsql
as $function$
declare
  v_today   date := (now() at time zone 'Europe/Moscow')::date;
  v_id      uuid;
  v_used    integer;
  v_current text;
  v_exclude text[];
  v_pick    text;
  v_ordinal integer;
  v_kind    text;
begin
  if p_slot is null or p_slot not in (1, 2) then
    raise exception 'Некорректный номер квеста';
  end if;
  if not public.stage4_generation_active() then
    raise exception 'Ежедневные квесты ещё не запущены';
  end if;

  select id, replacements_used,
         case p_slot when 1 then life_template_code else life_template_code_2 end
    into v_id, v_used, v_current
    from public.student_daily_quests
   where student_id = p_student_id and quest_date = v_today
   for update;

  if not found or v_current is null then
    raise exception 'Сегодняшний квест не сгенерирован';
  end if;

  v_kind := case p_slot when 1 then 'life_1' else 'life_2' end;
  if exists (
    select 1 from public.daily_quest_reward_log
     where student_id = p_student_id
       and quest_date = v_today
       and reward_kind = v_kind
  ) then
    raise exception 'Этот квест уже подтверждён — замена недоступна';
  end if;
  if v_used >= 2 then
    raise exception 'Достигнут общий лимит замен на сегодня';
  end if;

  select coalesce(array_agg(template_code), array[]::text[])
    into v_exclude
    from public.student_daily_quest_options
   where daily_quest_id = v_id;

  v_pick := public.pick_life_template(v_exclude);
  if v_pick is null then
    raise exception 'Нет нового варианта для замены';
  end if;

  select coalesce(max(ordinal), -1) + 1
    into v_ordinal
    from public.student_daily_quest_options
   where daily_quest_id = v_id and slot = p_slot;

  update public.student_daily_quests
     set life_template_code =
           case when p_slot = 1 then v_pick else life_template_code end,
         life_template_code_2 =
           case when p_slot = 2 then v_pick else life_template_code_2 end,
         replacements_used = v_used + 1,
         updated_at = now()
   where id = v_id;

  insert into public.student_daily_quest_options
    (daily_quest_id, template_code, slot, ordinal)
  values (v_id, v_pick, p_slot, v_ordinal);

  return public.daily_quest_state(p_student_id, v_today);
end;
$function$;

create or replace function public.settle_daily_combo(
  p_student_id bigint,
  p_quest_date date
)
 returns void
 language plpgsql
as $function$
declare
  v_paid integer;
begin
  if exists (
       select 1 from public.daily_quest_reward_log
        where student_id = p_student_id
          and quest_date = p_quest_date
          and reward_kind = 'life_1'
     )
     and exists (
       select 1 from public.daily_quest_reward_log
        where student_id = p_student_id
          and quest_date = p_quest_date
          and reward_kind = 'life_2'
     ) then
    insert into public.daily_quest_reward_log
      (student_id, quest_date, reward_kind, bubliks)
    values (p_student_id, p_quest_date, 'combo', 2)
    on conflict (student_id, quest_date, reward_kind) do nothing;
    get diagnostics v_paid = row_count;
    if v_paid = 1 then
      perform public.add_huikons(p_student_id, 2, 'daily_quest_combo');
    end if;
  end if;
end;
$function$;

-- Достижения считаются по ДНЯМ, когда закрыты оба life-слота. Дополнительных бубликов нет.
create or replace function public.grant_life_achievements(p_student_id bigint)
 returns void
 language plpgsql
as $function$
declare
  v_count      integer;
  v_variety    integer;
  v_max_streak integer;
begin
  with both_days as (
    select quest_date
      from public.daily_quest_reward_log
     where student_id = p_student_id and reward_kind in ('life_1', 'life_2')
     group by quest_date
    having count(distinct reward_kind) = 2
  )
  select count(*) into v_count from both_days;

  if v_count >= 1   then perform public.grant_achievement_server(p_student_id, 'life_first', 0); end if;
  if v_count >= 7   then perform public.grant_achievement_server(p_student_id, 'life_7', 0); end if;
  if v_count >= 30  then perform public.grant_achievement_server(p_student_id, 'life_30', 0); end if;
  if v_count >= 100 then perform public.grant_achievement_server(p_student_id, 'life_100', 0); end if;

  select count(distinct template_code)
    into v_variety
    from (
      select q.life_template_code as template_code
        from public.daily_quest_reward_log r
        join public.student_daily_quests q
          on q.student_id = r.student_id and q.quest_date = r.quest_date
       where r.student_id = p_student_id and r.reward_kind = 'life_1'
      union all
      select q.life_template_code_2
        from public.daily_quest_reward_log r
        join public.student_daily_quests q
          on q.student_id = r.student_id and q.quest_date = r.quest_date
       where r.student_id = p_student_id and r.reward_kind = 'life_2'
    ) completed
   where template_code is not null;

  if v_variety >= 5 then
    perform public.grant_achievement_server(p_student_id, 'life_variety_5', 0);
  end if;

  with both_days as (
    select quest_date
      from public.daily_quest_reward_log
     where student_id = p_student_id and reward_kind in ('life_1', 'life_2')
     group by quest_date
    having count(distinct reward_kind) = 2
  ),
  grouped as (
    select quest_date - (row_number() over (order by quest_date))::integer as grp
      from both_days
  )
  select coalesce(max(cnt), 0)
    into v_max_streak
    from (select count(*) as cnt from grouped group by grp) runs;

  if v_max_streak >= 7 then
    perform public.grant_achievement_server(p_student_id, 'life_streak_7', 0);
  end if;
end;
$function$;

create function public.claim_life_quest(p_student_id bigint, p_slot smallint)
 returns json
 language plpgsql
as $function$
declare
  v_today date := (now() at time zone 'Europe/Moscow')::date;
  v_id    uuid;
  v_life  text;
  v_kind  text;
  v_paid  integer;
begin
  if p_slot is null or p_slot not in (1, 2) then
    raise exception 'Некорректный номер квеста';
  end if;
  if not public.stage4_generation_active() then
    raise exception 'Ежедневные квесты ещё не запущены';
  end if;

  select id,
         case p_slot when 1 then life_template_code else life_template_code_2 end
    into v_id, v_life
    from public.student_daily_quests
   where student_id = p_student_id and quest_date = v_today
   for update;

  if not found or v_life is null then
    raise exception 'Сегодняшний квест не сгенерирован';
  end if;

  v_kind := case p_slot when 1 then 'life_1' else 'life_2' end;
  insert into public.daily_quest_reward_log
    (student_id, quest_date, reward_kind, bubliks)
  values (p_student_id, v_today, v_kind, 3)
  on conflict (student_id, quest_date, reward_kind) do nothing;
  get diagnostics v_paid = row_count;
  if v_paid = 1 then
    perform public.add_huikons(p_student_id, 3, 'daily_quest_' || v_kind);
  end if;

  perform public.settle_daily_combo(p_student_id, v_today);
  perform public.grant_life_achievements(p_student_id);

  return public.daily_quest_state(p_student_id, v_today);
end;
$function$;

-- Compatibility primitive: assignments/weekly economy продолжают вызывать старую внутреннюю
-- точку, но после продуктового решения math больше не создаёт daily quest и не платит 3.
create or replace function public.settle_daily_math(p_assignment_id uuid)
 returns void
 language plpgsql
as $function$
begin
  return;
end;
$function$;

create function public.replace_life_quest_self(p_slot smallint)
 returns json
 language plpgsql
 security definer
 set search_path = public, pg_temp
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
  return public.replace_life_quest(v_tid, p_slot);
end;
$function$;

create function public.claim_life_quest_self(p_slot smallint)
 returns json
 language plpgsql
 security definer
 set search_path = public, pg_temp
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
  return public.claim_life_quest(v_tid, p_slot);
end;
$function$;

revoke all on function public.replace_life_quest(bigint, smallint)
  from public, anon, authenticated;
revoke all on function public.claim_life_quest(bigint, smallint)
  from public, anon, authenticated;
revoke all on function public.replace_life_quest_self(smallint)
  from public, anon;
revoke all on function public.claim_life_quest_self(smallint)
  from public, anon;

grant execute on function public.replace_life_quest(bigint, smallint) to service_role;
grant execute on function public.claim_life_quest(bigint, smallint) to service_role;
grant execute on function public.replace_life_quest_self(smallint) to authenticated, service_role;
grant execute on function public.claim_life_quest_self(smallint) to authenticated, service_role;

-- Post-check: сигнатуры заменены, два активных шаблона обязательны для двух разных слотов.
do $postcheck$
begin
  if (select count(*) from public.life_quest_templates where active) < 2 then
    raise exception '048 ABORT: для двух слотов нужно минимум два активных шаблона';
  end if;
  if to_regprocedure('public.claim_life_quest_self(smallint)') is null
     or to_regprocedure('public.replace_life_quest_self(smallint)') is null
     or to_regprocedure('public.claim_life_quest_self()') is not null
     or to_regprocedure('public.replace_life_quest_self()') is not null then
    raise exception '048 ABORT: неожиданный набор self-RPC сигнатур';
  end if;
end
$postcheck$;
