-- Season System V2: канонические пресеты, редактируемое планирование и runtime-контракт
-- утверждённой визуальной ревизии 4.
--
-- Миграция ничего не активирует сама по себе. Автоматический переход выполняется только
-- ensure_season_schedule() по опубликованному окну [starts_at, ends_at).

begin;

-- ---------------------------------------------------------------------------
-- 1. Канонический каталог и редактируемые снимки будущих периодов
-- ---------------------------------------------------------------------------

create table if not exists public.season_v2_presets (
  preset_code             text        primary key,
  catalog_code            text        not null,
  catalog_revision        integer     not null check (catalog_revision > 0),
  sequence_no             smallint    not null unique check (sequence_no between 1 and 23),
  competition_season_no   smallint    check (competition_season_no between 1 and 21),
  season_type             text        not null check (season_type in ('interseason', 'regular')),
  default_start_date      date        not null,
  default_end_date        date        not null,
  suggested_name          text        not null check (char_length(suggested_name) between 1 and 60),
  short_description       text        not null check (char_length(short_description) between 1 and 500),
  theme_key               text        not null,
  economy_profile         text        not null check (economy_profile in ('summer', 'regular')),
  pricing_status          text        not null check (pricing_status in ('provisional', 'recommended')),
  collection_code         text        not null unique,
  collection_bonus        integer     not null check (collection_bonus >= 0),
  collection_total_target integer     not null check (collection_total_target > 0),
  catalog_only            boolean     not null default false,
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now(),
  check (default_end_date > default_start_date),
  check ((sequence_no <= 2) = (season_type = 'interseason')),
  check ((season_type = 'interseason') = (competition_season_no is null))
);

create table if not exists public.season_v2_preset_items (
  preset_code       text        not null references public.season_v2_presets(preset_code) on delete restrict,
  item_code         text        not null unique,
  slot              text        not null check (slot in ('avatar', 'frame', 'title', 'background')),
  item_kind         text        not null default 'cosmetic' check (item_kind = 'cosmetic'),
  name              text        not null check (char_length(name) between 1 and 80),
  description       text        not null check (char_length(description) between 1 and 500),
  rarity            text        not null check (rarity in ('common', 'rare', 'epic', 'legendary')),
  price             integer     not null check (price > 0),
  currency          text        not null,
  asset_key         text        not null,
  render_payload    text        not null,
  visual_key        text        not null,
  motion_policy     text        not null check (motion_policy in ('static', 'subtle', 'expressive')),
  sort_order        integer     not null,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  primary key (preset_code, item_code),
  unique (preset_code, slot)
);

-- Редактируемый снимок предметов конкретного будущего периода. Редкость и slot сюда
-- намеренно не копируются: они всегда читаются из неизменяемого канонического пресета.
create table if not exists public.season_v2_plan_items (
  season_id       bigint      not null references public.seasons(id) on delete cascade,
  item_code       text        not null references public.season_v2_preset_items(item_code) on delete restrict,
  name            text        not null check (char_length(name) between 1 and 80),
  description     text        not null check (char_length(description) between 1 and 500),
  price           integer     not null check (price > 0),
  render_payload  text        not null,
  updated_at      timestamptz not null default now(),
  updated_by      uuid,
  primary key (season_id, item_code)
);

-- ---------------------------------------------------------------------------
-- 2. Расширение существующего магазина и сезонов без второй параллельной системы
-- ---------------------------------------------------------------------------

alter table public.shop_items drop constraint if exists shop_items_slot_check;
alter table public.shop_items add constraint shop_items_slot_check
  check (slot in ('name_color', 'crown', 'status_emoji', 'title', 'frame', 'background', 'avatar'));

alter table public.shop_items add column if not exists description   text;
alter table public.shop_items add column if not exists rarity        text;
alter table public.shop_items add column if not exists currency      text not null default 'huikons';
alter table public.shop_items add column if not exists asset_key     text;
alter table public.shop_items add column if not exists visual_key    text;
alter table public.shop_items add column if not exists motion_policy text;
alter table public.shop_items add column if not exists preset_code   text;

alter table public.shop_items drop constraint if exists shop_items_rarity_check;
alter table public.shop_items add constraint shop_items_rarity_check
  check (rarity is null or rarity in ('common', 'rare', 'epic', 'legendary'));
alter table public.shop_items drop constraint if exists shop_items_motion_policy_check;
alter table public.shop_items add constraint shop_items_motion_policy_check
  check (motion_policy is null or motion_policy in ('static', 'subtle', 'expressive'));

alter table public.seasons add column if not exists preset_code  text;
alter table public.seasons add column if not exists sequence_no  smallint;
alter table public.seasons add column if not exists description  text;
alter table public.seasons add column if not exists updated_at   timestamptz not null default now();
alter table public.seasons add column if not exists updated_by   uuid;
alter table public.seasons add column if not exists scheduled_at timestamptz;
alter table public.seasons add column if not exists archived_at  timestamptz;

alter table public.seasons drop constraint if exists seasons_status_check;
alter table public.seasons drop constraint if exists seasons_planned_window_required;

update public.seasons set status = 'scheduled' where status = 'planned';
update public.seasons set status = 'archived', archived_at = coalesce(archived_at, now())
 where status = 'completed';

alter table public.seasons add constraint seasons_status_check
  check (status in ('draft', 'scheduled', 'active', 'closed', 'archived'));
alter table public.seasons alter column status set default 'draft';
alter table public.seasons add constraint seasons_scheduled_window_required
  check (status <> 'scheduled' or (starts_at is not null and ends_at is not null));
alter table public.seasons drop constraint if exists seasons_sequence_no_check;
alter table public.seasons add constraint seasons_sequence_no_check
  check (sequence_no is null or sequence_no between 1 and 23);

create unique index if not exists idx_seasons_preset_code
  on public.seasons (preset_code) where preset_code is not null;
create index if not exists idx_seasons_v2_schedule
  on public.seasons (status, starts_at, sequence_no);

alter table public.shop_items drop constraint if exists shop_items_preset_code_fkey;
alter table public.shop_items add constraint shop_items_preset_code_fkey
  foreign key (preset_code) references public.season_v2_presets(preset_code) on delete restrict;
alter table public.seasons drop constraint if exists seasons_preset_code_fkey;
alter table public.seasons add constraint seasons_preset_code_fkey
  foreign key (preset_code) references public.season_v2_presets(preset_code) on delete restrict;

comment on column public.shop_items.currency is
  'Каталожная единица. Для Season V2 значение gears списывается из существующего students.huikons; отдельный кошелёк не создаётся.';
comment on column public.seasons.status is
  'draft | scheduled | active | closed | archived. Только active имеет end_date is null.';

-- ---------------------------------------------------------------------------
-- 3. Публичная косметика: безопасная карта для профиля и обоих топов
-- ---------------------------------------------------------------------------

create or replace function public.student_public_cosmetics(p_student_id bigint)
 returns jsonb
 language sql
 stable
 set search_path = public, pg_temp
as $function$
  select coalesce(
           jsonb_object_agg(e.slot, jsonb_build_object(
             'item_code',     e.item_code,
             'variant',       e.variant,
             'payload',       si.render_payload,
             'name',          si.name,
             'description',   si.description,
             'rarity',        si.rarity,
             'visual_key',    si.visual_key,
             'motion_policy', si.motion_policy)),
           '{}'::jsonb)
    from public.student_equipment e
    join public.shop_items si on si.item_code = e.item_code
   where e.student_id = p_student_id
$function$;

revoke all on function public.student_public_cosmetics(bigint) from public, anon;
grant execute on function public.student_public_cosmetics(bigint) to authenticated;

drop function if exists public.get_student_inventory_self();
create function public.get_student_inventory_self()
 returns table(
   item_code          text,
   name               text,
   description        text,
   slot               text,
   item_kind          text,
   rarity             text,
   price              integer,
   currency           text,
   render_payload     text,
   visual_key         text,
   motion_policy      text,
   has_render_payload boolean,
   available_now      boolean,
   season_id          bigint,
   is_equipped        boolean,
   equipped_variant   text,
   showcase_position  smallint,
   sort_order         integer)
 language plpgsql
 security definer
 set search_path = public, pg_temp
as $function$
#variable_conflict use_column
declare
  v_tid    bigint;
  v_bundle integer;
begin
  if private.current_app_role() is distinct from 'student' then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  v_tid := private.current_telegram_id();
  if v_tid is null or v_tid <= 0 then
    raise exception 'no student identity' using errcode = '42501';
  end if;

  select b.bundle into v_bundle
    from public.season_bundles b
   where b.season_id = public.current_season_id();

  return query
  select si.item_code,
         si.name,
         coalesce(si.description, ''),
         si.slot,
         si.item_kind,
         si.rarity,
         si.price,
         si.currency,
         si.render_payload,
         si.visual_key,
         si.motion_policy,
         (si.render_payload is not null and btrim(si.render_payload) <> ''),
         (si.active and (si.availability = 'always'
                         or (v_bundle is not null and si.rotation_bundle = v_bundle))),
         sb.season_id,
         (eq.item_code is not null),
         eq.variant,
         sc.position,
         si.sort_order
    from public.student_items own
    join public.shop_items si on si.item_code = own.item_code
    left join public.season_bundles sb on sb.bundle = si.rotation_bundle
    left join public.student_equipment eq
           on eq.student_id = v_tid and eq.slot = si.slot and eq.item_code = si.item_code
    left join public.student_showcase sc
           on sc.student_id = v_tid and sc.kind = 'item' and sc.ref_code = si.item_code
   where own.student_id = v_tid
     and si.slot is not null
     and si.item_kind in ('cosmetic', 'service')
   order by si.slot asc, si.sort_order asc, si.name asc;
end;
$function$;

revoke all on function public.get_student_inventory_self() from public, anon;
grant execute on function public.get_student_inventory_self() to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Жизненный цикл: только опубликованное расписание, без ad-hoc сезона
-- ---------------------------------------------------------------------------

create or replace function public.start_next_season(p_seed_cohorts boolean default true)
 returns bigint
 language plpgsql
 set search_path = public, pg_temp
as $function$
declare
  v_id   bigint;
  v_seed bigint;
begin
  select id into v_id
    from public.seasons
   where status = 'scheduled'
     and starts_at <= now()
     and ends_at > now()
   order by starts_at asc, sequence_no asc nulls last, id asc
   limit 1
   for update;

  if v_id is null then
    return null;
  end if;

  update public.seasons
     set status       = 'active',
         end_date     = null,
         start_date   = (starts_at at time zone 'Europe/Moscow')::date,
         scheduled_at = coalesce(scheduled_at, now()),
         updated_at   = now()
   where id = v_id;

  if p_seed_cohorts then
    select max(id) into v_seed
      from public.seasons
     where status in ('closed', 'archived');
    perform public.build_season_cohorts(v_id, v_seed);
  end if;
  return v_id;
end;
$function$;

create or replace function public.finish_season(p_season_id bigint)
 returns json
 language plpgsql
 set search_path = public, pg_temp
as $function$
declare
  v_status       text;
  v_start_date   date;
  v_start_ts     timestamptz;
  v_today        date := (now() at time zone 'Europe/Moscow')::date;
  v_archived     integer := 0;
  v_awarded      integer := 0;
  v_reward       integer;
  r              record;
begin
  select status, start_date into v_status, v_start_date
    from public.seasons where id = p_season_id for update;
  if v_status is null then
    raise exception 'season % not found', p_season_id;
  end if;
  if v_status <> 'active' then
    return json_build_object(
      'season_id', p_season_id, 'archived', 0, 'awarded', 0,
      'next_season_id', public.current_season_id(), 'already_completed', true);
  end if;

  v_start_ts := (v_start_date::timestamp) at time zone 'Europe/Moscow';
  update public.seasons
     set status = 'closed', end_date = v_today, updated_at = now()
   where id = p_season_id;

  perform 1 from public.students for update;
  insert into public.season_results (season_id, student_id, points, place)
  select p_season_id, s.telegram_id, s.rating,
         row_number() over (
           order by s.rating desc, coalesce(pen.cnt, 0) asc,
                    pts.last_scored asc nulls last, s.telegram_id asc)
    from public.students s
    left join (
      select student_id, count(*) as cnt
        from public.balance_history
       where reason like 'penalty:%' and created_at >= v_start_ts
       group by student_id
    ) pen on pen.student_id = s.telegram_id
    left join (
      select student_id, max(created_at) as last_scored
        from public.season_points_log
       where season_id = p_season_id and amount <> 0
       group by student_id
    ) pts on pts.student_id = s.telegram_id
  on conflict (season_id, student_id) do nothing;
  get diagnostics v_archived = row_count;

  for r in
    select student_id, place
      from public.season_results
     where season_id = p_season_id and place <= 3 and points > 0
     order by place
  loop
    v_reward := case r.place when 1 then 100 when 2 then 60 else 30 end;
    perform public.add_huikons(r.student_id, v_reward, 'season_place_' || r.place);
    v_awarded := v_awarded + 1;
  end loop;

  perform public.close_league_season(p_season_id, null);
  update public.students set rating = 0 where rating <> 0;

  return json_build_object(
    'season_id', p_season_id, 'archived', v_archived, 'awarded', v_awarded,
    'next_season_id', null, 'already_completed', false);
end;
$function$;

create or replace function public.ensure_season_schedule()
 returns bigint
 language plpgsql
 set search_path = public, pg_temp
as $function$
declare
  v_active      bigint;
  v_active_end  timestamptz;
  v_due         bigint;
  v_missed      bigint;
  v_steps       integer := 0;
begin
  perform pg_advisory_xact_lock(hashtext('sasha_math_season_schedule'));
  loop
    v_steps := v_steps + 1;
    if v_steps > 10000 then
      raise exception 'season_schedule_transition_limit';
    end if;

    select id, ends_at into v_active, v_active_end
      from public.seasons where status = 'active' order by id desc limit 1;
    if v_active is not null then
      select id into v_due
        from public.seasons
       where status = 'scheduled' and starts_at <= now()
       order by starts_at asc, sequence_no asc nulls last, id asc
       limit 1;
      if (v_active_end is not null and v_active_end <= now()) or v_due is not null then
        perform public.finish_season(v_active);
        continue;
      end if;
      return v_active;
    end if;

    select id into v_missed
      from public.seasons
     where status = 'scheduled' and ends_at <= now()
     order by starts_at asc, sequence_no asc nulls last, id asc
     limit 1;
    if v_missed is not null then
      update public.seasons
         set status = 'closed',
             end_date = (ends_at at time zone 'Europe/Moscow')::date,
             updated_at = now()
       where id = v_missed and status = 'scheduled';
      continue;
    end if;

    v_active := public.start_next_season(true);
    if v_active is not null then
      return v_active;
    end if;
    return null;
  end loop;
end;
$function$;

-- Совместимость с существующей учительской кнопкой досрочного закрытия. Следующий период
-- запускается только если его starts_at уже наступил; будущий scheduled не включается вручную.
create or replace function public.close_season()
 returns json
 language plpgsql
 set search_path = public, pg_temp
as $function$
declare
  v_active bigint;
  v_result jsonb;
  v_next   bigint;
begin
  select id into v_active
    from public.seasons
   where status = 'active'
   order by id desc
   limit 1
   for update;
  if v_active is null then
    return json_build_object(
      'season_id', null, 'archived', 0, 'awarded', 0,
      'next_season_id', public.ensure_season_schedule(), 'already_completed', true);
  end if;

  v_result := public.finish_season(v_active)::jsonb;
  v_next := public.ensure_season_schedule();
  return (v_result || jsonb_build_object('next_season_id', v_next))::json;
end;
$function$;
revoke all on function public.close_season() from public, anon, authenticated;

-- Магазин тоже является точкой ленивого запуска расписания. Он больше не ищет сезон по
-- end_date is null и не назначает произвольный свободный бандл: бандл каждого периода уже
-- закреплён каталогом 058.
create or replace function public.ensure_season_rotation()
 returns integer
 language plpgsql
 security definer
 set search_path = public, pg_temp
as $function$
declare
  v_season bigint;
  v_bundle integer;
begin
  if private.current_app_role() is distinct from 'student' then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  v_season := public.ensure_season_schedule();
  if v_season is null then
    return null;
  end if;

  select bundle into v_bundle
    from public.season_bundles
   where season_id = v_season;
  return v_bundle;
end;
$function$;

-- ---------------------------------------------------------------------------
-- 5. Учитель: единый безопасный read-model и сохранение draft/scheduled
-- ---------------------------------------------------------------------------

create or replace function public.admin_list_season_v2_self()
 returns jsonb
 language plpgsql
 security definer
 set search_path = public, pg_temp
as $function$
declare
  v_result jsonb;
begin
  if private.current_app_role() is distinct from 'teacher' then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(row_data order by sequence_no), '[]'::jsonb)
    into v_result
    from (
      select p.sequence_no,
             jsonb_build_object(
               'preset_code', p.preset_code,
               'sequence_no', p.sequence_no,
               'competition_season_no', p.competition_season_no,
               'season_type', p.season_type,
               'catalog_only', p.catalog_only,
               'season_id', s.id,
               'status', case when p.catalog_only then 'catalog_only' else coalesce(s.status, 'draft') end,
               'title', coalesce(s.title, p.suggested_name),
               'description', coalesce(s.description, p.short_description),
               'starts_at', coalesce(s.starts_at, (p.default_start_date::timestamp at time zone 'Europe/Moscow')),
               'ends_at', coalesce(s.ends_at, (p.default_end_date::timestamp at time zone 'Europe/Moscow')),
               'timezone', 'Europe/Moscow',
               'pricing_status', p.pricing_status,
               'items', (
                 select jsonb_agg(jsonb_build_object(
                   'item_code', pi.item_code,
                   'slot', pi.slot,
                   'name', coalesce(pli.name, pi.name),
                   'description', coalesce(pli.description, pi.description),
                   'rarity', pi.rarity,
                   'price', coalesce(pli.price, pi.price),
                   'currency', pi.currency,
                   'render_payload', coalesce(pli.render_payload, pi.render_payload),
                    'visual_key', coalesce((
                      select approved_visual.visual_key
                        from public.season_v2_preset_items approved_visual
                       where approved_visual.slot = pi.slot
                         and approved_visual.render_payload =
                             coalesce(pli.render_payload, pi.render_payload)
                       limit 1
                    ), pi.visual_key),
                   'motion_policy', pi.motion_policy,
                   'sort_order', pi.sort_order
                 ) order by pi.sort_order)
                   from public.season_v2_preset_items pi
                   left join public.season_v2_plan_items pli
                          on pli.season_id = s.id and pli.item_code = pi.item_code
                  where pi.preset_code = p.preset_code
               )
             ) as row_data
        from public.season_v2_presets p
        left join public.seasons s on s.preset_code = p.preset_code
    ) q;

  return v_result;
end;
$function$;

create or replace function public.admin_save_season_v2_self(
  p_preset_code text,
  p_title       text,
  p_description text,
  p_starts_at   timestamptz,
  p_ends_at     timestamptz,
  p_items       jsonb,
  p_schedule    boolean default false)
 returns jsonb
 language plpgsql
 security definer
 set search_path = public, pg_temp
as $function$
declare
  v_principal  uuid;
  v_sequence   smallint;
  v_catalog_only boolean;
  v_season_id  bigint;
  v_status     text;
  v_title      text;
  v_description text;
  v_bundle     integer;
  v_prev_end   timestamptz;
  v_next_start timestamptz;
  r            record;
begin
  if private.current_app_role() is distinct from 'teacher' then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  select sequence_no, catalog_only
    into v_sequence, v_catalog_only
    from public.season_v2_presets
   where preset_code = p_preset_code;
  if v_sequence is null then
    raise exception 'preset_not_found' using errcode = 'P0002';
  end if;
  if v_catalog_only then
    raise exception 'catalog_only_period' using errcode = '22023';
  end if;

  v_title := btrim(coalesce(p_title, ''));
  v_description := btrim(coalesce(p_description, ''));
  if char_length(v_title) < 1 or char_length(v_title) > 60 then
    raise exception 'title_required' using errcode = '22023';
  end if;
  if char_length(v_description) < 1 or char_length(v_description) > 500 then
    raise exception 'description_required' using errcode = '22023';
  end if;
  if position('<' in v_title) > 0 or position('>' in v_title) > 0
     or position('<' in v_description) > 0 or position('>' in v_description) > 0 then
    raise exception 'markup_not_allowed' using errcode = '22023';
  end if;
  if p_starts_at is null or p_ends_at is null then
    raise exception 'window_required' using errcode = '22023';
  end if;
  if p_ends_at <= p_starts_at then
    raise exception 'window_order' using errcode = '22023';
  end if;
  if p_schedule and p_starts_at <= now() then
    raise exception 'start_in_past' using errcode = '22023';
  end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) <> 4 then
    raise exception 'four_items_required' using errcode = '22023';
  end if;
  if (
    select count(distinct x.item_code) <> 4
        or count(distinct x.slot) <> 4
        or array_agg(distinct x.slot order by x.slot)
           <> array['avatar', 'background', 'frame', 'title']::text[]
      from jsonb_to_recordset(p_items) as x(item_code text, slot text)
  ) then
    raise exception 'four_items_required' using errcode = '22023';
  end if;

  if exists (
    select 1
      from jsonb_to_recordset(p_items) as x(
        item_code text, slot text, name text, description text, price integer, render_payload text)
     where x.price is null or x.price <= 0
        or btrim(coalesce(x.name, '')) = ''
        or btrim(coalesce(x.description, '')) = ''
        or position('<' in coalesce(x.name, '')) > 0
        or position('>' in coalesce(x.name, '')) > 0
        or position('<' in coalesce(x.description, '')) > 0
        or position('>' in coalesce(x.description, '')) > 0
        or not exists (
          select 1
            from public.season_v2_preset_items own_item
           where own_item.preset_code = p_preset_code
             and own_item.item_code = x.item_code
             and own_item.slot = x.slot)
        or not exists (
          select 1
            from public.season_v2_preset_items approved_visual
           where approved_visual.slot = x.slot
             and approved_visual.render_payload = x.render_payload)
  ) then
    raise exception 'invalid_item_payload' using errcode = '22023';
  end if;

  select id, status into v_season_id, v_status
    from public.seasons
   where preset_code = p_preset_code
   for update;

  if v_season_id is null then
    insert into public.seasons(
      title, description, status, start_date, end_date, starts_at, ends_at,
      preset_code, sequence_no, updated_at, updated_by)
    values (
      v_title, v_description, 'draft',
      (p_starts_at at time zone 'Europe/Moscow')::date,
      (p_ends_at at time zone 'Europe/Moscow')::date,
      p_starts_at, p_ends_at, p_preset_code, v_sequence, now(), private.current_principal())
    returning id into v_season_id;
    v_status := 'draft';
  end if;

  if v_status not in ('draft', 'scheduled') then
    raise exception 'season_not_editable' using errcode = '22023';
  end if;

  if p_schedule then
    if exists (
      select 1 from public.seasons other
       where other.id <> v_season_id
         and other.status in ('scheduled', 'active')
         and other.starts_at is not null and other.ends_at is not null
         and tstzrange(other.starts_at, other.ends_at, '[)')
             && tstzrange(p_starts_at, p_ends_at, '[)')
    ) then
      raise exception 'season_overlap' using errcode = '22023';
    end if;

    select max(other.ends_at) into v_prev_end
      from public.seasons other
     where other.id <> v_season_id
       and other.status in ('scheduled', 'active')
       and other.ends_at <= p_starts_at;
    select min(other.starts_at) into v_next_start
      from public.seasons other
     where other.id <> v_season_id
       and other.status in ('scheduled', 'active')
       and other.starts_at >= p_ends_at;
    if (v_prev_end is not null and v_prev_end <> p_starts_at)
       or (v_next_start is not null and v_next_start <> p_ends_at) then
      raise exception 'season_gap' using errcode = '22023';
    end if;
  end if;

  v_principal := private.current_principal();
  update public.seasons
     set title = v_title,
         description = v_description,
         starts_at = p_starts_at,
         ends_at = p_ends_at,
         start_date = (p_starts_at at time zone 'Europe/Moscow')::date,
         end_date = (p_ends_at at time zone 'Europe/Moscow')::date,
         status = case when p_schedule then 'scheduled' else 'draft' end,
         scheduled_at = case when p_schedule then now() else null end,
         updated_at = now(),
         updated_by = v_principal
   where id = v_season_id;

  for r in
    select x.item_code, x.name, x.description, x.price, x.render_payload
      from jsonb_to_recordset(p_items) as x(
        item_code text, slot text, name text, description text, price integer, render_payload text)
  loop
    insert into public.season_v2_plan_items(
      season_id, item_code, name, description, price, render_payload, updated_at, updated_by)
    values (
      v_season_id, r.item_code, btrim(r.name), btrim(r.description), r.price,
      r.render_payload, now(), v_principal)
    on conflict (season_id, item_code) do update
      set name = excluded.name,
          description = excluded.description,
          price = excluded.price,
          render_payload = excluded.render_payload,
          updated_at = excluded.updated_at,
          updated_by = excluded.updated_by;

    update public.shop_items as target
       set name = btrim(r.name),
           description = btrim(r.description),
           price = r.price,
           render_payload = r.render_payload,
           visual_key = (
             select approved_visual.visual_key
               from public.season_v2_preset_items approved_visual
              where approved_visual.slot = target.slot
                and approved_visual.render_payload = r.render_payload
              limit 1)
     where item_code = r.item_code;
  end loop;

  v_bundle := 2600 + v_sequence;
  insert into public.season_bundles(season_id, bundle)
  values (v_season_id, v_bundle)
  on conflict (season_id) do update set bundle = excluded.bundle;

  perform public.security_audit(
    'teacher_save_season_v2',
    'teacher',
    v_principal,
    null,
    jsonb_build_object(
      'season_id', v_season_id,
      'preset_code', p_preset_code,
      'status', case when p_schedule then 'scheduled' else 'draft' end,
      'starts_at', p_starts_at,
      'ends_at', p_ends_at));

  return jsonb_build_object(
    'season_id', v_season_id,
    'preset_code', p_preset_code,
    'status', case when p_schedule then 'scheduled' else 'draft' end);
end;
$function$;

create or replace function public.admin_archive_season_v2_self(p_season_id bigint)
 returns jsonb
 language plpgsql
 security definer
 set search_path = public, pg_temp
as $function$
declare
  v_principal uuid;
begin
  if private.current_app_role() is distinct from 'teacher' then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  v_principal := private.current_principal();
  update public.seasons
     set status = 'archived', archived_at = now(), updated_at = now(), updated_by = v_principal
   where id = p_season_id and status = 'closed';
  if not found then
    raise exception 'season_not_closed' using errcode = '22023';
  end if;
  perform public.security_audit(
    'teacher_archive_season_v2', 'teacher', v_principal, null,
    jsonb_build_object('season_id', p_season_id));
  return jsonb_build_object('season_id', p_season_id, 'status', 'archived');
end;
$function$;

-- Старые CRUD-RPC создавали planned напрямую и обходили draft/scheduled-проверки V2.
revoke all on function public.admin_create_season_self(bigint, text, timestamptz, timestamptz)
  from public, anon, authenticated;
revoke all on function public.admin_update_season_self(bigint, text, timestamptz, timestamptz)
  from public, anon, authenticated;
revoke all on function public.admin_delete_season_self(bigint)
  from public, anon, authenticated;

revoke all on function public.admin_list_season_v2_self() from public, anon;
revoke all on function public.admin_save_season_v2_self(text, text, text, timestamptz, timestamptz, jsonb, boolean)
  from public, anon;
revoke all on function public.admin_archive_season_v2_self(bigint) from public, anon;
grant execute on function public.admin_list_season_v2_self() to authenticated;
grant execute on function public.admin_save_season_v2_self(text, text, text, timestamptz, timestamptz, jsonb, boolean)
  to authenticated;
grant execute on function public.admin_archive_season_v2_self(bigint) to authenticated;

-- ---------------------------------------------------------------------------
-- 6. RLS новых таблиц
-- ---------------------------------------------------------------------------

alter table public.season_v2_presets enable row level security;
alter table public.season_v2_preset_items enable row level security;
alter table public.season_v2_plan_items enable row level security;

drop policy if exists season_v2_presets_select_teacher on public.season_v2_presets;
create policy season_v2_presets_select_teacher on public.season_v2_presets
  for select to authenticated using (public.jwt_app_role() = 'teacher');
drop policy if exists season_v2_preset_items_select_teacher on public.season_v2_preset_items;
create policy season_v2_preset_items_select_teacher on public.season_v2_preset_items
  for select to authenticated using (public.jwt_app_role() = 'teacher');
drop policy if exists season_v2_plan_items_select_teacher on public.season_v2_plan_items;
create policy season_v2_plan_items_select_teacher on public.season_v2_plan_items
  for select to authenticated using (public.jwt_app_role() = 'teacher');

revoke insert, update, delete on public.season_v2_presets from anon, authenticated;
revoke insert, update, delete on public.season_v2_preset_items from anon, authenticated;
revoke insert, update, delete on public.season_v2_plan_items from anon, authenticated;

commit;
