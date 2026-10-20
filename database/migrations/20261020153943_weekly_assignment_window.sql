-- Weekly assignments expire at Monday 00:00 MSK. Keep historical records untouched.
-- Ownership, submission statuses, daily revision windows and individual tasks retain their rules.
begin;

create or replace function public.activate_due_assignments_self()
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

  update public.assignments
     set activation_status = 'active'
   where student_id = v_tid
     and activation_status = 'scheduled'
     and scheduled_date <= (now() at time zone 'Europe/Moscow')::date
     and (type <> 'weekly' or week_label = public.week_start_of((now() at time zone 'Europe/Moscow')::date)::text);
end;
$function$;

create or replace function public.submit_assignment_self(
  p_assignment_id uuid, p_photo_url text)
 returns void language plpgsql security definer set search_path = ''
as $function$
declare
  v_tid bigint; v_a public.assignments%rowtype; v_today_msk date; v_is_photos boolean;
begin
  if private.current_app_role() is distinct from 'student' then
    raise exception 'forbidden' using errcode = '42501'; end if;
  v_tid := private.current_telegram_id();
  if v_tid is null or v_tid <= 0 then
    raise exception 'no student identity' using errcode = '42501'; end if;
  if p_assignment_id is null then
    raise exception 'assignment required' using errcode = '22023'; end if;

  begin
    select bool_and(value like 'https://%') and count(*) >= 1
      into v_is_photos from json_array_elements_text(p_photo_url::json);
  exception when others then v_is_photos := false;
  end;
  if p_photo_url is null or length(p_photo_url) = 0 or coalesce(v_is_photos, false) = false then
    raise exception 'invalid photo url' using errcode = '22023'; end if;

  select * into v_a from public.assignments
   where id = p_assignment_id and student_id = v_tid for update;
  if not found then raise exception 'forbidden' using errcode = '42501'; end if;

  if v_a.activation_status is distinct from 'active' then
    raise exception 'not submittable' using errcode = '22023'; end if;
  if not (v_a.status = 'assigned'
          or (v_a.status = 'checked' and v_a.approval_status = 'rejected')) then
    raise exception 'not submittable' using errcode = '22023'; end if;

  v_today_msk := (now() at time zone 'Europe/Moscow')::date;
  if v_a.type = 'weekly' and v_a.week_label is distinct from public.week_start_of(v_today_msk)::text then
    raise exception 'window closed' using errcode = '22023';
  end if;

  if v_a.type = 'daily' then
    if v_a.status = 'assigned' then
      if v_a.scheduled_date is distinct from v_today_msk then
        raise exception 'window closed' using errcode = '22023'; end if;
    else
      if v_a.revision_deadline_at is null or now() >= v_a.revision_deadline_at then
        raise exception 'window closed' using errcode = '22023'; end if;
    end if;
  end if;

  update public.assignments
     set photo_url = p_photo_url, status = 'submitted', submitted_at = now()
   where id = p_assignment_id;
end;
$function$;

revoke all on function public.activate_due_assignments_self() from public, anon;
revoke all on function public.submit_assignment_self(uuid,text) from public, anon;
grant execute on function public.activate_due_assignments_self() to authenticated;
grant execute on function public.submit_assignment_self(uuid,text) to authenticated;

commit;
