begin;

-- Activation is deliberately limited to a currently open planned window. It never
-- manufactures an unplanned season.
create or replace function public.start_next_season(p_seed_cohorts boolean default true)
 returns bigint
 language plpgsql
 set search_path = public, pg_temp
as $function$
declare
  v_id bigint;
  v_seed bigint;
begin
  select id into v_id
    from public.seasons
   where status = 'planned'
     and starts_at <= now()
     and ends_at > now()
   order by starts_at asc, id asc
   limit 1
   for update;
  if v_id is null then
    return null;
  end if;
  update public.seasons
     set status = 'active', end_date = null,
         start_date = (starts_at at time zone 'Europe/Moscow')::date
   where id = v_id;
  if p_seed_cohorts then
    select max(id) into v_seed from public.seasons where status = 'completed';
    perform public.build_season_cohorts(v_id, v_seed);
  end if;
  return v_id;
end;
$function$;

-- Completion is still idempotent, but a gap in the teacher's schedule leaves no
-- active season instead of inventing an ad-hoc one.
create or replace function public.finish_season(p_season_id bigint)
 returns json
 language plpgsql
 set search_path = public, pg_temp
as $function$
declare
  v_status text;
  v_start_date date;
  v_start_ts timestamptz;
  v_today date := (now() at time zone 'Europe/Moscow')::date;
  v_archived integer := 0;
  v_awarded integer := 0;
  v_reward integer;
  r record;
begin
  select status, start_date into v_status, v_start_date
    from public.seasons where id = p_season_id for update;
  if v_status is null then raise exception 'season % not found', p_season_id; end if;
  if v_status <> 'active' then
    return json_build_object('season_id', p_season_id, 'archived', 0, 'awarded', 0,
      'next_season_id', public.current_season_id(), 'already_completed', true);
  end if;
  v_start_ts := (v_start_date::timestamp) at time zone 'Europe/Moscow';
  update public.seasons set status = 'completed', end_date = v_today where id = p_season_id;
  perform 1 from public.students for update;
  insert into public.season_results (season_id, student_id, points, place)
  select p_season_id, s.telegram_id, s.rating,
         row_number() over (order by s.rating desc, coalesce(pen.cnt, 0) asc,
                            pts.last_scored asc nulls last, s.telegram_id asc)
    from public.students s
    left join (
      select student_id, count(*) as cnt from public.balance_history
       where reason like 'penalty:%' and created_at >= v_start_ts group by student_id
    ) pen on pen.student_id = s.telegram_id
    left join (
      select student_id, max(created_at) as last_scored from public.season_points_log
       where season_id = p_season_id and amount <> 0 group by student_id
    ) pts on pts.student_id = s.telegram_id
  on conflict (season_id, student_id) do nothing;
  get diagnostics v_archived = row_count;
  for r in select student_id, place from public.season_results
             where season_id = p_season_id and place <= 3 and points > 0 order by place
  loop
    v_reward := case r.place when 1 then 100 when 2 then 60 else 30 end;
    perform public.add_huikons(r.student_id, v_reward, 'season_place_' || r.place);
    v_awarded := v_awarded + 1;
  end loop;
  -- A nullable next season means a planned pause. close_league_season then skips
  -- temporary awards and cohort creation instead of creating phantom participants.
  perform public.close_league_season(p_season_id, null);
  update public.students set rating = 0 where rating <> 0;
  return json_build_object('season_id', p_season_id, 'archived', v_archived,
    'awarded', v_awarded, 'next_season_id', null, 'already_completed', false);
end;
$function$;

create or replace function public.ensure_season_schedule()
 returns bigint
 language plpgsql
 set search_path = public, pg_temp
as $function$
declare
  v_active bigint;
  v_active_end timestamptz;
  v_due_planned bigint;
  v_missed bigint;
  v_steps integer := 0;
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
      select id into v_due_planned from public.seasons
       where status = 'planned' and starts_at <= now() order by starts_at asc, id asc limit 1;
      if (v_active_end is not null and v_active_end <= now()) or v_due_planned is not null then
        perform public.finish_season(v_active);
        continue;
      end if;
      return v_active;
    end if;

    -- A window entirely in the past was never active: complete it without results,
    -- rewards, league cohorts, or a temporary replacement season.
    select id into v_missed from public.seasons
     where status = 'planned' and ends_at <= now()
     order by starts_at asc, id asc limit 1;
    if v_missed is not null then
      update public.seasons
         set status = 'completed', end_date = (ends_at at time zone 'Europe/Moscow')::date
       where id = v_missed and status = 'planned';
      continue;
    end if;

    v_active := public.start_next_season(true);
    if v_active is not null then
      return v_active;
    end if;
    -- Future plan, intentional pause, or no plan: rating is refused by the helper.
    return null;
  end loop;
end;
$function$;

create or replace function public.ensure_current_season()
 returns bigint
 language plpgsql
 security definer
 set search_path = public, pg_temp
as $function$
begin
  if private.current_app_role() not in ('student', 'teacher') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  return public.ensure_season_schedule();
end;
$function$;

-- All rating writers use this guard. It serializes schedule repair before selecting
-- a season and gives callers one stable failure for a pause/no-plan state.
create or replace function public.require_current_season_id()
 returns bigint
 language plpgsql
 set search_path = public, pg_temp
as $function$
declare v_id bigint;
begin
  v_id := public.ensure_season_schedule();
  if v_id is null then
    raise exception 'no_active_season' using errcode = 'P0001';
  end if;
  return v_id;
end;
$function$;

create or replace function public.add_season_points(p_student_id bigint, p_amount integer)
 returns integer
 language plpgsql
 set search_path = public, pg_temp
as $function$
declare v_new integer;
begin
  perform public.require_current_season_id();
  update public.students set rating = greatest(0, rating + p_amount)
   where telegram_id = p_student_id returning rating into v_new;
  if v_new is null then raise exception 'Student % not found', p_student_id; end if;
  return v_new;
end;
$function$;

create or replace function public.award_season_points(
  p_student_id bigint, p_amount integer, p_reason text, p_event_key text default null)
 returns integer
 language plpgsql
 set search_path = public, pg_temp
as $function$
declare v_season bigint; v_inserted integer; v_rating integer;
begin
  if p_amount = 0 then
    select rating into v_rating from public.students where telegram_id = p_student_id;
    return v_rating;
  end if;
  v_season := public.require_current_season_id();
  insert into public.season_points_log (season_id, student_id, amount, reason, event_key)
  values (v_season, p_student_id, p_amount, p_reason, p_event_key)
  on conflict (event_key) where event_key is not null do nothing;
  get diagnostics v_inserted = row_count;
  if v_inserted = 0 and p_event_key is not null then
    select rating into v_rating from public.students where telegram_id = p_student_id;
    return v_rating;
  end if;
  return public.add_season_points(p_student_id, p_amount);
end;
$function$;

revoke all on function public.require_current_season_id() from public, anon, authenticated;
commit;
