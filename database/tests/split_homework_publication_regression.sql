-- Run as the database owner after the migration. Synthetic fixtures only; always roll back.
begin;
insert into private.security_principals(id, app_role, teacher_id)
values ('00000000-0000-4000-8000-000000007801', 'teacher', 'split-homework-regression');
insert into public.students(telegram_id, name, group_name)
values (995078001, 'Split publication regression', '__split_homework_regression__');
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000007801","app_role":"teacher"}', true);

do $test$
declare
  v_week date := public.week_start_of((now() at time zone 'Europe/Moscow')::date) + 7;
  v_group text := '__split_homework_regression__';
  v_daily jsonb;
  v_weekly jsonb := '[{"type":"weekly","title":"Weekly test","content_url":"https://example.test/weekly","task_count":12}]';
  v_before jsonb;
  v_after jsonb;
  v_result json;
  v_plan uuid;
  v_items jsonb;
begin
  if has_function_privilege('anon', 'public.publish_homework_self(text,date,text,text,jsonb)', 'execute') then
    raise exception 'anonymous publication allowed';
  end if;
  if not has_function_privilege('authenticated', 'public.publish_homework_self(text,date,text,text,jsonb)', 'execute') then
    raise exception 'teacher cannot invoke publication';
  end if;
  select jsonb_agg(jsonb_build_object('type','daily','day_of_week',d,'title','Day '||d,
    'content_url','https://example.test/day/'||d,'task_count',10)) into v_daily from generate_series(1,7) d;
  v_result := public.publish_homework_self('daily',v_week,'group',v_group,v_daily);
  v_plan := (v_result->>'plan_id')::uuid;
  select jsonb_agg(to_jsonb(a) order by id) into v_before from public.assignments a
    where student_id=995078001 and week_label=v_week::text and type='daily';
  if jsonb_array_length(v_before) <> 7 then raise exception 'daily publication incomplete'; end if;

  -- The video scenario: only a weekly task is sent after the daily plan already exists.
  perform public.publish_homework_self('weekly',v_week,'group',v_group,v_weekly);
  select jsonb_agg(to_jsonb(a) order by id) into v_after from public.assignments a
    where student_id=995078001 and week_label=v_week::text and type='daily';
  if v_after is distinct from v_before then raise exception 'weekly publication changed daily assignments'; end if;
  if (select count(*) from public.weekly_plan_items where plan_id=v_plan and active) <> 8 then
    raise exception 'weekly publication removed daily slots'; end if;

  -- Retrying either action must not duplicate items or assignments.
  perform public.publish_homework_self('weekly',v_week,'group',v_group,v_weekly);
  perform public.publish_homework_self('daily',v_week,'group',v_group,v_daily);
  if (select count(*) from public.weekly_plan_items where plan_id=v_plan and active) <> 8
    or (select count(*) from public.assignments where student_id=995078001 and week_label=v_week::text) <> 8 then
    raise exception 'retry duplicated or removed homework'; end if;

  -- A partial daily publication preserves the weekly and all omitted daily tasks.
  select jsonb_agg(to_jsonb(a) order by id) into v_before from public.assignments a
    where student_id=995078001 and week_label=v_week::text and (type='weekly' or day_of_week<>4);
  perform public.publish_homework_self('daily',v_week,'group',v_group,
    '[{"type":"daily","day_of_week":4,"title":"Updated Thursday","content_url":"https://example.test/new","task_count":11}]');
  select jsonb_agg(to_jsonb(a) order by id) into v_after from public.assignments a
    where student_id=995078001 and week_label=v_week::text and (type='weekly' or day_of_week<>4);
  if v_after is distinct from v_before then raise exception 'partial daily changed other slots'; end if;
  if not exists(select 1 from public.assignments where student_id=995078001 and week_label=v_week::text
    and day_of_week=4 and title='Updated Thursday' and task_count=11) then
    raise exception 'daily update not materialized'; end if;

  -- Reject empty or mixed submissions instead of interpreting them as deletion.
  begin
    perform public.publish_homework_self('weekly',v_week,'group',v_group,'[]');
    raise exception 'empty publication accepted';
  exception when invalid_parameter_value then null; end;
  begin
    perform public.publish_homework_self('weekly',v_week,'group',v_group,v_daily);
    raise exception 'mixed publication accepted';
  exception when invalid_parameter_value then null; end;
  begin
    perform public.publish_homework_self('daily',v_week,'group',v_group,v_daily || v_daily);
    raise exception 'duplicate slots accepted';
  exception when raise_exception then
    if sqlerrm not like 'Слот % указан в items дважды' then raise; end if;
  end;

  -- Explicit removal in the existing editor retains its original meaning.
  select jsonb_agg(jsonb_build_object('type',type,'day_of_week',day_of_week,'title',title,
    'content_url',content_url,'task_count',task_count,'teacher_comment',teacher_comment)) into v_items
    from public.weekly_plan_items where plan_id=v_plan and active and type<>'weekly';
  perform public.publish_weekly_plan_self(v_week,'group',v_group,v_items);
  if exists(select 1 from public.weekly_plan_items where plan_id=v_plan and active and type='weekly') then
    raise exception 'explicit removal broken'; end if;

  -- Current-week daily tasks (including frozen days) also survive adding the weekly variant.
  v_week := v_week - 7;
  v_daily := jsonb_build_array(jsonb_build_object('type','daily','day_of_week',
    extract(isodow from (now() at time zone 'Europe/Moscow')::date)::integer,
    'title','Today','content_url','https://example.test/today','task_count',5));
  perform public.publish_homework_self('daily',v_week,'group',v_group,v_daily);
  select jsonb_agg(to_jsonb(i) order by i.id) into v_before
    from public.weekly_plan_items i join public.weekly_plans p on p.id=i.plan_id
    where p.week_start=v_week and p.group_name=v_group and i.type='daily' and i.active;
  perform public.publish_homework_self('weekly',v_week,'group',v_group,v_weekly);
  select jsonb_agg(to_jsonb(i) order by i.id) into v_after
    from public.weekly_plan_items i join public.weekly_plans p on p.id=i.plan_id
    where p.week_start=v_week and p.group_name=v_group and i.type='daily' and i.active;
  if v_after is distinct from v_before then raise exception 'current daily changed'; end if;
end;
$test$;

set local role authenticated;
select public.publish_homework_self('weekly',public.week_start_of(current_date)+7,'group',
  '__split_homework_regression__','[{"type":"weekly","title":"Authenticated teacher","content_url":"https://example.test/teacher"}]');
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000007801","app_role":"student"}', true);
do $test$
begin
  begin
    perform public.publish_homework_self('weekly',public.week_start_of(current_date)+7,'group',
      '__split_homework_regression__','[{"type":"weekly","title":"Unauthorized","content_url":"https://example.test"}]');
    raise exception 'student publication accepted';
  exception when insufficient_privilege then null; end;
end;
$test$;
reset role;
select 'PASS split homework: weekly/daily preservation, partial update, retry, validation, explicit removal, current week, role checks' as result;
rollback;
