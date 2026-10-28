-- Independent daily / weekly publication from the create form.
-- Preserve every omitted slot under the plan lock; explicit editing/removal still uses
-- publish_weekly_plan_self with the complete plan. No historical data is backfilled.
begin;

create or replace function public.publish_homework_self(
  p_task_type text,
  p_week_start date,
  p_audience_type text,
  p_group_name text default null,
  p_items jsonb default '[]'::jsonb
) returns json
 language plpgsql security definer set search_path = ''
as $function$
declare
  v_plan_id uuid;
  v_items jsonb;
begin
  if private.current_app_role() is distinct from 'teacher' then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_task_type is null or p_task_type not in ('daily', 'weekly') then
    raise exception 'Выберите ежедневные или еженедельное задание' using errcode = '22023';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' then
    raise exception 'items должен быть json-массивом' using errcode = '22023';
  end if;
  if jsonb_array_length(p_items) = 0 then
    raise exception 'Заполните хотя бы одно задание' using errcode = '22023';
  end if;
  if exists (
    select 1 from jsonb_array_elements(p_items) as incoming(item)
     where jsonb_typeof(item) <> 'object' or item->>'type' is distinct from p_task_type
  ) then
    raise exception 'Отправляйте ежедневные и еженедельные задания отдельно' using errcode = '22023';
  end if;

  -- Also serialize the first publication, before a plan row exists.
  perform pg_advisory_xact_lock(hashtextextended(
    jsonb_build_array('publish_homework', p_week_start, p_audience_type, p_group_name)::text, 0));
  select id into v_plan_id from public.weekly_plans
   where week_start = p_week_start and audience_type = p_audience_type
     and group_name is not distinct from p_group_name and status = 'published'
   for update;

  -- Merge on the server after acquiring the lock, never from a stale browser snapshot.
  select coalesce(jsonb_agg(jsonb_build_object(
    'type', i.type, 'day_of_week', i.day_of_week, 'title', i.title,
    'content_url', i.content_url, 'teacher_comment', i.teacher_comment, 'task_count', i.task_count
  )), '[]'::jsonb) into v_items
    from public.weekly_plan_items i
   where i.plan_id = v_plan_id and i.active
     and not exists (
       select 1 from jsonb_array_elements(p_items) as incoming(item)
        where item->>'type' = i.type
          and (item->>'day_of_week')::integer is not distinct from i.day_of_week
     );

  -- Keep the existing authorization, audit, validation, synchronization and retry contract.
  return public.publish_weekly_plan_self(p_week_start, p_audience_type, p_group_name, v_items || p_items);
end;
$function$;

revoke all on function public.publish_homework_self(text,date,text,text,jsonb) from public, anon;
grant execute on function public.publish_homework_self(text,date,text,text,jsonb) to authenticated;

commit;
