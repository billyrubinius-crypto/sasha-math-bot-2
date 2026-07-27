begin;

-- Only memberships activated by a homework award are contestants. Seed rows remain
-- available for the next planned season but are never settled as participants.
create or replace function public.close_league_season(
  p_old_season_id bigint,
  p_new_season_id bigint)
 returns void
 language plpgsql
 set search_path = public, pg_temp
as $function$
declare
  r record;
  v_active integer;
  v_promote integer;
  v_demote integer;
  v_to integer;
  v_kind text;
  v_move text;
  v_new_inactive integer;
  v_legend_active integer;
  v_crown bigint;
begin
  if not exists (select 1 from public.league_cohorts where season_id = p_old_season_id) then
    return;
  end if;

  for r in
    select m.id as membership_id, m.student_id, m.cohort_id, m.tier,
           coalesce(sr.points, 0) as points,
           row_number() over (
             partition by m.cohort_id
             order by sr.place asc nulls last, m.student_id asc) as place
      from public.league_memberships m
      left join public.season_results sr
        on sr.season_id = p_old_season_id and sr.student_id = m.student_id
     where m.season_id = p_old_season_id
       and m.activated_at is not null
  loop
    update public.league_memberships
       set points = r.points, place = r.place
     where id = r.membership_id;
  end loop;

  for r in
    select m.id as membership_id, m.student_id, m.cohort_id, m.tier, m.points,
           case when m.points > 0 then
             row_number() over (partition by m.cohort_id, (m.points > 0) order by m.place asc)
           end as active_rank
      from public.league_memberships m
     where m.season_id = p_old_season_id
       and m.is_late_entry = false
       and m.activated_at is not null
  loop
    select count(*) into v_active
      from public.league_memberships
     where cohort_id = r.cohort_id
       and is_late_entry = false
       and activated_at is not null
       and points > 0;

    if v_active between 5 and 9 then
      v_promote := 1; v_demote := 1;
    elsif v_active between 10 and 19 then
      v_promote := 3; v_demote := 3;
    elsif v_active between 20 and 30 then
      v_promote := 5; v_demote := 5;
    else
      v_promote := 0; v_demote := 0;
    end if;

    v_to := r.tier;
    v_kind := null;
    v_move := 'stayed';
    if r.points > 0 then
      update public.student_league_state
         set inactive_seasons = 0, updated_at = now()
       where student_id = r.student_id;
      if r.active_rank <= v_promote and r.tier < 7 then
        v_to := r.tier + 1; v_kind := 'promote'; v_move := 'promote';
      elsif r.active_rank > v_active - v_demote and r.tier > 1 then
        v_to := r.tier - 1; v_kind := 'demote'; v_move := 'demote';
      end if;
    else
      update public.student_league_state
         set inactive_seasons = inactive_seasons + 1, updated_at = now()
       where student_id = r.student_id
       returning inactive_seasons into v_new_inactive;
      if v_new_inactive >= 2 and r.tier > 1 then
        v_to := r.tier - 1; v_kind := 'inactive_demote'; v_move := 'inactive_demote';
      end if;
    end if;

    update public.league_memberships set movement = v_move where id = r.membership_id;
    if v_kind is not null then
      insert into public.league_movements (season_id, student_id, from_tier, to_tier, kind)
      values (p_old_season_id, r.student_id, r.tier, v_to, v_kind)
      on conflict (season_id, student_id) do nothing;
      update public.student_league_state set tier = v_to, updated_at = now()
       where student_id = r.student_id;
    end if;
  end loop;

  update public.league_memberships
     set movement = 'stayed'
   where season_id = p_old_season_id
     and is_late_entry = true
     and activated_at is not null;

  if p_new_season_id is not null then
    select count(*) into v_legend_active
      from public.league_memberships
     where season_id = p_old_season_id and tier = 7 and is_late_entry = false
       and activated_at is not null and points > 0;
    if v_legend_active >= 5 then
      select student_id into v_crown
        from public.league_memberships
       where season_id = p_old_season_id and tier = 7 and is_late_entry = false
         and activated_at is not null and points > 0
       order by place asc
       limit 1;
      if v_crown is not null then
        insert into public.league_season_awards
          (award_code, student_id, earned_season_id, active_season_id)
        values ('legend_crown', v_crown, p_old_season_id, p_new_season_id)
        on conflict (award_code, earned_season_id, student_id) do nothing;
      end if;
    end if;
    perform public.build_season_cohorts(p_new_season_id, p_old_season_id);
  end if;
end;
$function$;

-- Generic adjustments never enroll a student. These two wrappers are used only by
-- the confirmed-homework flows below.
create or replace function public.add_homework_season_points(p_student_id bigint, p_amount integer)
 returns integer
 language plpgsql
 set search_path = public, pg_temp
as $function$
declare v_rating integer;
begin
  v_rating := public.add_season_points(p_student_id, p_amount);
  if p_amount > 0 then
    perform public.ensure_league_membership(p_student_id);
  end if;
  return v_rating;
end;
$function$;

create or replace function public.award_homework_season_points(
  p_student_id bigint, p_amount integer, p_reason text, p_event_key text default null)
 returns integer
 language plpgsql
 set search_path = public, pg_temp
as $function$
declare v_rating integer;
begin
  v_rating := public.award_season_points(p_student_id, p_amount, p_reason, p_event_key);
  if p_amount > 0 then
    perform public.ensure_league_membership(p_student_id);
  end if;
  return v_rating;
end;
$function$;

create or replace function public.record_approved_assignment(p_assignment_id uuid)
 returns json
 language plpgsql
 set search_path = public, pg_temp
as $function$
declare
  v_asn public.assignments%rowtype;
  v_pts integer;
  v_reason text;
  v_run integer := 0;
  v_clean_10 boolean := false;
  v_bonus integer;
  v_paid integer;
  r record;
begin
  select * into v_asn from public.assignments where id = p_assignment_id;
  if not found then raise exception 'assignment % not found', p_assignment_id; end if;
  if not (v_asn.status = 'checked' and v_asn.approval_status = 'approved') then
    raise exception 'assignment % is not approved', p_assignment_id;
  end if;
  v_pts := case v_asn.type when 'daily' then 10 when 'weekly' then 40 when 'individual' then 30 else 0 end;
  if v_pts > 0 then
    v_reason := 'approve_' || v_asn.type;
    perform public.award_homework_season_points(
      v_asn.student_id, v_pts, v_reason, 'season_approve_' || v_asn.id::text);
  end if;
  perform public.grant_achievement_server(v_asn.student_id, 'first_step', 10);
  for r in
    select coalesce(revision_count, 0) = 0 as clean
      from public.assignments
     where student_id = v_asn.student_id and status = 'checked' and approval_status = 'approved'
     order by checked_at, id
  loop
    if r.clean then v_run := v_run + 1; if v_run >= 10 then v_clean_10 := true; end if;
    else v_run := 0; end if;
  end loop;
  if v_clean_10 then perform public.grant_achievement_server(v_asn.student_id, 'clean_10', 25); end if;
  if v_asn.type in ('weekly', 'individual') then
    v_bonus := case v_asn.type when 'weekly' then 20 else 15 end;
    insert into public.assignment_reward_log (assignment_id, student_id, reward_amount)
    values (v_asn.id, v_asn.student_id, v_bonus) on conflict (assignment_id) do nothing;
    get diagnostics v_paid = row_count;
    if v_paid = 1 then perform public.add_huikons(v_asn.student_id, v_bonus, v_asn.type || '_approved'); end if;
  end if;
  if v_asn.type = 'daily' then perform public.settle_daily_math(v_asn.id); end if;
  return json_build_object('student_id', v_asn.student_id, 'type', v_asn.type, 'season_points', v_pts);
end;
$function$;

create or replace function public.settle_legacy_approval(p_assignment_id uuid)
 returns void
 language plpgsql
 set search_path = public, pg_temp
as $function$
declare
  v_a public.assignments%rowtype; v_sid bigint; v_sched date;
  v_dates date[]; v_bridged date[] := '{}'; v_effective date[];
  v_prevappr date; v_missing date; v_lastdate date; v_d date; v_prev date;
  v_position integer; v_max integer; v_count30 integer; v_pos_this integer; v_pos_last integer;
  v_current integer; v_reward integer; v_idx integer; v_month_start date; v_next_month date;
begin
  select * into v_a from public.assignments where id = p_assignment_id;
  if not found then raise exception 'assignment % not found', p_assignment_id; end if;
  v_sid := v_a.student_id;
  if v_a.type = 'daily' then
    v_sched := v_a.scheduled_date;
    select array_agg(d order by d) into v_dates from (
      select distinct scheduled_date d from public.assignments where student_id = v_sid and type = 'daily'
       and status = 'checked' and approval_status = 'approved' and scheduled_date is not null
       order by d desc limit 400) t;
    if v_dates is null then v_dates := '{}'; end if;
    select coalesce(array_agg(distinct bridged_date), '{}') into v_bridged from public.streak_shield_uses where student_id = v_sid;
    select max(d) into v_prevappr from unnest(v_dates) d where d < v_sched;
    if v_prevappr is not null and (v_sched - v_prevappr) = 2 then
      v_missing := v_prevappr + 1;
      if not (v_missing = any(v_bridged)) and public.consume_streak_shield(v_sid, v_missing) then
        v_bridged := array_append(v_bridged, v_missing);
      end if;
    end if;
    select array_agg(d order by d) into v_effective from (select distinct unnest(v_dates || v_bridged) d) t;
    if v_effective is null then v_effective := '{}'; end if;
    v_prev := null; v_position := 0; v_max := 0; v_count30 := 0; v_pos_this := 1; v_pos_last := 0;
    if array_length(v_dates, 1) is not null then v_lastdate := v_dates[array_length(v_dates, 1)]; end if;
    foreach v_d in array v_effective loop
      if v_prev is not null and v_d = v_prev + 1 then v_position := v_position + 1; else v_position := 1; end if;
      if v_d = v_sched then v_pos_this := v_position; end if;
      if v_lastdate is not null and v_d = v_lastdate then v_pos_last := v_position; end if;
      if v_position > v_max then v_max := v_position; end if;
      if v_position = 30 then v_count30 := v_count30 + 1; end if;
      v_prev := v_d;
    end loop;
    v_current := case when v_lastdate is not null then v_pos_last else 0 end;
    v_reward := case when v_pos_this >= 30 then 25 when v_pos_this >= 7 then 20 when v_pos_this >= 3 then 15 when v_pos_this = 2 then 10 else 5 end;
    update public.students set current_streak = v_current, last_submission_date_msk = v_lastdate where telegram_id = v_sid;
    perform public.add_huikons(v_sid, v_reward, 'streak_day_' || v_pos_this);
    perform public.add_homework_season_points(v_sid, 12);
    v_idx := array_position(v_dates, v_sched);
    if v_idx is not null and v_idx > 1 and (v_sched - v_dates[v_idx - 1]) >= 7 then perform public.add_huikons(v_sid, 20, 'bonus_return'); end if;
    if v_max >= 7 then perform public.grant_achievement_server(v_sid, 'streak_7', 25); end if;
    if v_max >= 30 then perform public.grant_achievement_server(v_sid, 'streak_30', 100); end if;
    if v_max >= 100 then perform public.grant_achievement_server(v_sid, 'streak_100', 300); end if;
    if v_max >= 200 then perform public.grant_achievement_server(v_sid, 'streak_200', 500); end if;
    if v_max >= 365 then perform public.grant_achievement_server(v_sid, 'streak_365', 1000); end if;
    if v_count30 >= 2 then perform public.grant_achievement_server(v_sid, 'rebirth', 200); end if;
    v_month_start := date_trunc('month', v_sched)::date; v_next_month := (v_month_start + interval '1 month')::date;
    if exists (select 1 from public.assignments where student_id = v_sid and type = 'daily' and scheduled_date >= v_month_start and scheduled_date < v_next_month)
       and not exists (select 1 from public.assignments where student_id = v_sid and type = 'daily' and scheduled_date >= v_month_start and scheduled_date < v_next_month and not (status = 'checked' and approval_status = 'approved')) then
      perform public.grant_achievement_server(v_sid, 'perfect_month', 150);
    end if;
  elsif v_a.type in ('weekly', 'individual') then
    perform public.add_huikons(v_sid, case v_a.type when 'weekly' then 20 else 15 end, v_a.type || '_approved');
    perform public.add_homework_season_points(v_sid, case v_a.type when 'weekly' then 40 else 30 end);
  end if;
  perform public.grant_achievement_server(v_sid, 'first_step', 10);
end;
$function$;

-- Backfill only confirmed homework: ledger reasons written by record_approved_assignment,
-- or a checked+approved assignment inside the current season window. Existing active rows stay active.
do $backfill$
declare r record; v_season bigint; v_start timestamptz;
begin
  select id, coalesce(starts_at, start_date::timestamp at time zone 'Europe/Moscow')
    into v_season, v_start from public.seasons where status = 'active' order by id desc limit 1;
  if v_season is null then return; end if;
  for r in
    select s.telegram_id
      from public.students s
     where exists (
       select 1 from public.season_points_log l
        where l.season_id = v_season and l.student_id = s.telegram_id and l.amount > 0
          and l.reason in ('approve_daily', 'approve_weekly', 'approve_individual')
     ) or exists (
       select 1 from public.assignments a
        where a.student_id = s.telegram_id and a.type in ('daily', 'weekly', 'individual')
          and a.status = 'checked' and a.approval_status = 'approved'
          and a.checked_at >= v_start
     )
  loop
    perform public.ensure_league_membership(r.telegram_id);
  end loop;
end;
$backfill$;

revoke all on function public.add_homework_season_points(bigint, integer) from public, anon, authenticated;
revoke all on function public.award_homework_season_points(bigint, integer, text, text) from public, anon, authenticated;
commit;
