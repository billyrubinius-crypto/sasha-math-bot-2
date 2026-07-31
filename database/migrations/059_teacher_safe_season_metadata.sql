-- Season V2: безопасное редактирование только номера и названия scheduled-сезона.
-- Миграции 057–058 уже могли быть применены, поэтому изменение оформлено отдельно.

begin;

alter table public.seasons
  add column if not exists display_number integer;

update public.seasons s
   set display_number = p.competition_season_no
  from public.season_v2_presets p
 where s.preset_code = p.preset_code
   and s.display_number is null
   and p.competition_season_no is not null;

alter table public.seasons drop constraint if exists seasons_display_number_check;
alter table public.seasons add constraint seasons_display_number_check
  check (display_number is null or display_number between 1 and 999);

create unique index if not exists idx_seasons_v2_display_number
  on public.seasons(display_number)
  where preset_code is not null and display_number is not null;

comment on column public.seasons.display_number is
  'Редактируемый учителем номер регулярного сезона. Межсезонные периоды остаются без номера.';

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
               'display_number', coalesce(s.display_number, p.competition_season_no),
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

create or replace function public.admin_update_scheduled_season_meta_self(
  p_preset_code   text,
  p_display_number integer,
  p_title          text)
 returns jsonb
 language plpgsql
 security definer
 set search_path = public, pg_temp
as $function$
declare
  v_principal  uuid;
  v_season_id  bigint;
  v_season_type text;
  v_title      text;
begin
  if private.current_app_role() is distinct from 'teacher' then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  select p.season_type, s.id
    into v_season_type, v_season_id
    from public.season_v2_presets p
    join public.seasons s on s.preset_code = p.preset_code
   where p.preset_code = p_preset_code
     and s.status = 'scheduled'
   for update of s;

  if v_season_id is null then
    raise exception 'scheduled_season_not_found' using errcode = 'P0002';
  end if;

  v_title := btrim(coalesce(p_title, ''));
  if char_length(v_title) < 1 or char_length(v_title) > 60 then
    raise exception 'title_required' using errcode = '22023';
  end if;
  if position('<' in v_title) > 0 or position('>' in v_title) > 0 then
    raise exception 'markup_not_allowed' using errcode = '22023';
  end if;

  if v_season_type = 'regular'
     and (p_display_number is null or p_display_number not between 1 and 999) then
    raise exception 'season_number_required' using errcode = '22023';
  end if;
  if v_season_type = 'interseason' and p_display_number is not null then
    raise exception 'interseason_has_no_number' using errcode = '22023';
  end if;
  if p_display_number is not null and exists (
    select 1
      from public.seasons other
     where other.id <> v_season_id
       and other.preset_code is not null
       and other.display_number = p_display_number
  ) then
    raise exception 'season_number_taken' using errcode = '23505';
  end if;

  v_principal := private.current_principal();
  update public.seasons
     set title = v_title,
         display_number = case when v_season_type = 'regular' then p_display_number else null end,
         updated_at = now(),
         updated_by = v_principal
   where id = v_season_id and status = 'scheduled';

  perform public.security_audit(
    'teacher_update_scheduled_season_meta',
    'teacher',
    v_principal,
    null,
    jsonb_build_object(
      'season_id', v_season_id,
      'preset_code', p_preset_code,
      'display_number', p_display_number));

  return jsonb_build_object(
    'season_id', v_season_id,
    'preset_code', p_preset_code,
    'display_number', case when v_season_type = 'regular' then p_display_number else null end,
    'title', v_title,
    'status', 'scheduled');
end;
$function$;

-- Полное изменение предметов/дат и ручное закрытие больше не доступны из учительского
-- клиента. Система продолжает переключать сезоны только по опубликованному расписанию.
revoke all on function public.admin_save_season_v2_self(
  text, text, text, timestamptz, timestamptz, jsonb, boolean)
  from public, anon, authenticated;
revoke all on function public.close_season_self()
  from public, anon, authenticated;

revoke all on function public.admin_update_scheduled_season_meta_self(text, integer, text)
  from public, anon;
grant execute on function public.admin_update_scheduled_season_meta_self(text, integer, text)
  to authenticated;

commit;
