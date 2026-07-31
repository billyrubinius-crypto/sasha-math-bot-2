-- Season V2 post-migration invariants. Run after 057 and 058 in a disposable database.
begin;

do $test$
declare
  v_count integer;
begin
  select count(*) into v_count from public.season_v2_presets;
  if v_count <> 23 then
    raise exception 'expected 23 Season V2 presets, got %', v_count;
  end if;

  select count(*) into v_count from public.season_v2_preset_items;
  if v_count <> 92 then
    raise exception 'expected 92 Season V2 items, got %', v_count;
  end if;

  if exists (
    select preset_code
      from public.season_v2_preset_items
     group by preset_code
    having count(*) <> 4
       or count(distinct slot) <> 4
       or count(distinct rarity) <> 4
  ) then
    raise exception 'every preset must contain four unique slots and rarities';
  end if;

  if exists (
    select 1
      from public.season_v2_presets p
      join public.season_v2_preset_items i using (preset_code)
     where i.rarity <> (
       case p.sequence_no % 4
         when 1 then case i.slot
           when 'avatar' then 'legendary' when 'frame' then 'rare'
           when 'title' then 'common' else 'epic' end
         when 2 then case i.slot
           when 'avatar' then 'rare' when 'frame' then 'common'
           when 'title' then 'epic' else 'legendary' end
         when 3 then case i.slot
           when 'avatar' then 'common' when 'frame' then 'epic'
           when 'title' then 'legendary' else 'rare' end
         else case i.slot
           when 'avatar' then 'epic' when 'frame' then 'legendary'
           when 'title' then 'rare' else 'common' end
       end)
  ) then
    raise exception 'rarity rotation changed';
  end if;

  if not exists (
    select 1 from public.season_v2_presets
     where sequence_no = 1 and catalog_only
  ) then
    raise exception 'sequence 1 must be catalog-only';
  end if;

  if exists (
    select 1 from public.seasons where sequence_no = 1
  ) then
    raise exception 'catalog-only sequence 1 must not have a seasons row';
  end if;

  select count(*) into v_count
    from public.seasons
   where sequence_no between 2 and 23 and status = 'scheduled';
  if v_count <> 22 then
    raise exception 'expected 22 scheduled runtime periods, got %', v_count;
  end if;

  if not exists (
    select 1
      from public.seasons
     where sequence_no = 2
       and starts_at = timestamptz '2026-08-01 00:00:00+03'
       and status = 'scheduled'
  ) then
    raise exception 'first automatic period must start 2026-08-01 00:00 MSK';
  end if;

  if exists (
    select 1
      from public.seasons current_period
      join public.seasons next_period
        on next_period.sequence_no = current_period.sequence_no + 1
     where current_period.sequence_no between 2 and 22
       and current_period.ends_at <> next_period.starts_at
  ) then
    raise exception 'scheduled periods must be contiguous';
  end if;

  select count(*) into v_count
    from public.shop_items
   where preset_code is not null
     and slot in ('avatar', 'frame', 'title', 'background');
  if v_count <> 92 then
    raise exception 'expected 92 Season V2 shop rows, got %', v_count;
  end if;

  if exists (
    select 1
      from public.seasons s
      left join public.season_bundles b on b.season_id = s.id
     where s.sequence_no between 2 and 23
       and b.bundle is distinct from 2600 + s.sequence_no
  ) then
    raise exception 'runtime bundle mapping changed';
  end if;
end;
$test$;

rollback;
