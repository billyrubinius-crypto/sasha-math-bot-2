-- Rollback-only synthetic students; no real student's assignments are modified.
begin;
insert into private.security_principals(id, app_role, telegram_id)
values ('00000000-0000-4000-8000-000000007601', 'student', 995076001);
insert into public.students(telegram_id, name, group_name)
values (995076001, 'Weekly window regression', 'Window test'), (995076002, 'Weekly foreign regression', 'Window test');
delete from public.assignments where student_id in (995076001,995076002);
insert into public.assignments(student_id,type,title,scheduled_date,week_label,activation_status,status)
select 995076001,'weekly',title,day,day::text,activation,'assigned'
from (values
  ('old active',public.week_start_of((now() at time zone 'Europe/Moscow')::date)-7,'active'),
  ('old scheduled',public.week_start_of((now() at time zone 'Europe/Moscow')::date)-14,'scheduled'),
  ('current',public.week_start_of((now() at time zone 'Europe/Moscow')::date),'scheduled'),
  ('future',public.week_start_of((now() at time zone 'Europe/Moscow')::date)+7,'scheduled'),
  ('future active',public.week_start_of((now() at time zone 'Europe/Moscow')::date)+7,'active')
) fixtures(title,day,activation);
insert into public.assignments(student_id,type,title,scheduled_date,week_label,activation_status,status,approval_status)
values (995076001,'weekly','old returned',current_date-21,(public.week_start_of(current_date)-21)::text,'active','checked','rejected');
insert into public.assignments(student_id,type,title,scheduled_date,activation_status,status)
values (995076001,'daily','daily today',(now() at time zone 'Europe/Moscow')::date,'scheduled','assigned'),
       (995076001,'individual','individual',current_date-100,'active','assigned');
insert into public.assignments(student_id,type,title,scheduled_date,week_label,activation_status,status)
values (995076002,'weekly','foreign',current_date,public.week_start_of(current_date)::text,'active','assigned');
select set_config('weeklytest.foreign_id',(select id::text from public.assignments where student_id=995076002),true);

set local role authenticated;
select set_config('request.jwt.claims','{"sub":"00000000-0000-4000-8000-000000007601","app_role":"student","telegram_id":"995076001"}',true);
select public.activate_due_assignments_self();
do $test$
declare v_a public.assignments%rowtype; v_title text;
begin
  if not exists(select 1 from public.assignments where student_id=995076001 and title='current' and activation_status='active')
    or not exists(select 1 from public.assignments where student_id=995076001 and title='old scheduled' and activation_status='scheduled')
    or not exists(select 1 from public.assignments where student_id=995076001 and title='future' and activation_status='scheduled') then
    raise exception 'weekly activation escaped its week';
  end if;
  foreach v_title in array array['old active','old returned','future','future active'] loop
    select * into strict v_a from public.assignments where student_id=995076001 and title=v_title;
    begin
      perform public.submit_assignment_self(v_a.id,'["https://example.test/weekly-window.jpg"]');
      raise exception 'expired or future weekly accepted';
    exception when invalid_parameter_value then null; end;
  end loop;
  begin
    perform public.submit_assignment_self(current_setting('weeklytest.foreign_id')::uuid,'["https://example.test/weekly-window.jpg"]');
    raise exception 'foreign assignment accepted';
  exception when insufficient_privilege then null; end;
  foreach v_title in array array['current','daily today','individual'] loop
    select * into strict v_a from public.assignments where student_id=995076001 and title=v_title;
    perform public.submit_assignment_self(v_a.id,'["https://example.test/weekly-window.jpg"]');
    if not exists(select 1 from public.assignments where id=v_a.id and status='submitted') then
      raise exception 'valid submission failed';
    end if;
  end loop;
end;
$test$;
reset role;
do $test$
begin
  if (select count(*) from public.assignments where student_id=995076001) <> 8 then
    raise exception 'historical work deleted';
  end if;
  if has_function_privilege('anon','public.submit_assignment_self(uuid,text)','execute')
    or has_function_privilege('anon','public.activate_due_assignments_self()','execute') then
    raise exception 'anonymous mutation access';
  end if;
  if not exists(select 1 from public.assignments where student_id=995076002 and status='assigned') then
    raise exception 'another pupil changed';
  end if;
end;
$test$;
select 'PASS weekly assignment window regression' as result;
rollback;
