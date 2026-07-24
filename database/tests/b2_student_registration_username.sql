-- Regression test for migration 050. Run in SQL Editor; leaves no data.
begin;

select public.student_auth_upsert_principal(
  995099991,
  'Registration Test',
  'first_username'
);

do $test$
begin
  if not exists (
    select 1
      from public.students
     where telegram_id = 995099991
       and name = 'Registration Test'
       and telegram_username = 'first_username'
  ) then
    raise exception 'registration did not capture Telegram metadata';
  end if;
end;
$test$;

-- A later Telegram username change must not rewrite the value maintained in Sheets.
select public.student_auth_upsert_principal(
  995099991,
  'Changed Name',
  'changed_username'
);

do $test$
begin
  if not exists (
    select 1
      from public.students
     where telegram_id = 995099991
       and name = 'Registration Test'
       and telegram_username = 'first_username'
  ) then
    raise exception 'repeat login rewrote registered Telegram metadata';
  end if;
end;
$test$;

-- A row created by the broken auth path is repaired once on its next login.
insert into public.students (telegram_id)
values (995099992);

select public.student_auth_upsert_principal(
  995099992,
  'Repair Test',
  'repaired_username'
);

do $test$
begin
  if not exists (
    select 1
      from public.students
     where telegram_id = 995099992
       and name = 'Repair Test'
       and telegram_username = 'repaired_username'
  ) then
    raise exception 'empty legacy row was not repaired';
  end if;
end;
$test$;

rollback;
