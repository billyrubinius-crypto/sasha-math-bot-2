-- =============================================================================
-- B2-T11 — live dev security matrix after t10_anon_closure.sql
--
-- Run as the Supabase SQL owner. The whole test is transactional and ends with ROLLBACK:
-- synthetic rows, ACL probes and temporary result storage do not remain.
-- =============================================================================

begin;

create temporary table b2_t11_results (
  check_name text primary key,
  passed     boolean not null,
  detail     text
) on commit drop;
grant select, insert on table pg_temp.b2_t11_results to anon, authenticated;

insert into b2_t11_results
select '01 auth_mode=enforced',
       count(*) = 1 and min(auth_mode) = 'enforced',
       format('rows=%s mode=%s', count(*), min(auth_mode))
  from private.security_runtime_config;

insert into b2_t11_results
select '02 exact object and policy inventory',
       pub_tables = 39 and private_tables = 5 and pub_sequences = 6
         and pub_functions = 102 and private_functions = 5 and policies = 29,
       format(
         'public tables=%s private tables=%s sequences=%s public funcs=%s private funcs=%s policies=%s',
         pub_tables, private_tables, pub_sequences, pub_functions, private_functions, policies
       )
  from (
    select
      (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'public' and c.relkind in ('r', 'p')) as pub_tables,
      (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'private' and c.relkind in ('r', 'p')) as private_tables,
      (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'public' and c.relkind = 'S') as pub_sequences,
      (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public') as pub_functions,
      (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'private') as private_functions,
      (select count(*) from pg_policies where schemaname = 'public') as policies
  ) inventory;

insert into b2_t11_results
select '03 anon catalog surface',
       mode_rpc = 1 and business_rpc = 0 and readable_tables = 0
         and writable_tables = 0 and usable_sequences = 0,
       format(
         'mode_rpc=%s business_rpc=%s readable_tables=%s writable_tables=%s sequences=%s',
         mode_rpc, business_rpc, readable_tables, writable_tables, usable_sequences
       )
  from (
    select
      count(*) filter (
        where has_function_privilege('anon', p.oid, 'EXECUTE')
          and p.oid = 'public.security_auth_mode()'::regprocedure
      ) as mode_rpc,
      count(*) filter (
        where has_function_privilege('anon', p.oid, 'EXECUTE')
          and p.oid <> 'public.security_auth_mode()'::regprocedure
      ) as business_rpc,
      (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'public'
          and case when c.relkind in ('r', 'p')
                   then has_table_privilege('anon', c.oid, 'SELECT')
                   else false end) as readable_tables,
      (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'public'
          and case when c.relkind in ('r', 'p') then
            has_table_privilege('anon', c.oid, 'INSERT')
            or has_table_privilege('anon', c.oid, 'UPDATE')
            or has_table_privilege('anon', c.oid, 'DELETE')
            or has_table_privilege('anon', c.oid, 'TRUNCATE')
          else false end) as writable_tables,
      (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'public'
          and case when c.relkind = 'S' then
            has_sequence_privilege('anon', c.oid, 'USAGE')
            or has_sequence_privilege('anon', c.oid, 'SELECT')
          else false end) as usable_sequences
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
  ) surface;

insert into b2_t11_results
select '04 no browser direct DML',
       count(*) = 0,
       format('direct DML grants=%s', count(*))
  from pg_roles r
 cross join pg_class c
  join pg_namespace n on n.oid = c.relnamespace
 where r.rolname in ('anon', 'authenticated')
   and n.nspname = 'public'
   and case when c.relkind in ('r', 'p') then
     has_table_privilege(r.rolname, c.oid, 'INSERT')
     or has_table_privilege(r.rolname, c.oid, 'UPDATE')
     or has_table_privilege(r.rolname, c.oid, 'DELETE')
     or has_table_privilege(r.rolname, c.oid, 'TRUNCATE')
   else false end;

insert into b2_t11_results
with allowed(rel) as (
  values
    ('public.students'), ('public.assignments'), ('public.balance_history'),
    ('public.weekly_mock_exams'), ('public.mock_exam_results'), ('public.student_items'),
    ('public.student_equipment'), ('public.student_showcase'), ('public.student_custom_titles'),
    ('public.student_achievements'), ('public.season_results'), ('public.student_week_results'),
    ('public.weekly_shield_uses'), ('public.streak_shield_uses'), ('public.league_memberships'),
    ('public.league_movements'), ('public.league_season_awards'), ('public.student_daily_quests'),
    ('public.student_daily_quest_options'), ('public.shop_items'), ('public.season_bundles'),
    ('public.seasons'), ('public.life_quest_templates'), ('public.weekly_plans'),
    ('public.weekly_plan_items')
),
counts as (
  select
    count(*) filter (
      where not has_table_privilege('authenticated', to_regclass(rel), 'SELECT')
    ) as missing,
    (
      select count(*)
        from pg_class c join pg_namespace n on n.oid = c.relnamespace
       where n.nspname = 'public'
         and case when c.relkind in ('r', 'p')
                  then has_table_privilege('authenticated', c.oid, 'SELECT')
                  else false end
         and not exists (
           select 1 from allowed a where to_regclass(a.rel) = c.oid
         )
    ) as unexpected
  from allowed
)
select '04b authenticated SELECT allowlist exact',
       missing = 0 and unexpected = 0,
       format('missing=%s unexpected=%s', missing, unexpected)
  from counts;

insert into b2_t11_results
with deny(sig) as (
  values
    ('public.student_auth_upsert_principal(bigint)'),
    ('public.student_auth_upsert_principal(bigint,text,text)'),
    ('public.teacher_auth_upsert_principal(text)'),
    ('public.teacher_session_create(uuid,uuid,text,timestamp with time zone,integer)'),
    ('public.teacher_session_rotate(text,text,integer)'),
    ('public.security_rate_limit_hit(text,text,integer,integer)'),
    ('public.security_rate_limit_peek(text,text,integer,integer)'),
    ('public.security_audit(text,text,uuid,text,jsonb)'),
    ('public.consume_parent_invite(text,bigint)'),
    ('public.record_weekly_mock_exam_service(bigint,date,integer)'),
    ('public.get_student_league_snapshot(bigint)'),
    ('public.get_student_rank_title(bigint)'),
    ('public.preview_league_close()'),
    ('public.settle_legacy_approval(uuid)')
)
select '05 service/internal RPC denied to browser roles',
       count(*) = 0,
       format('exposed denylisted role/RPC pairs=%s', count(*))
  from deny d cross join pg_roles r
 where r.rolname in ('anon', 'authenticated')
   and has_function_privilege(r.rolname, to_regprocedure(d.sig), 'EXECUTE');

insert into b2_t11_results
with allowed(sig) as (
  values
    ('public.security_auth_mode()'), ('public.jwt_app_role()'), ('public.jwt_student_id()'),
    ('public.ensure_student_self(text,text)'), ('public.submit_assignment_self(uuid,text)'),
    ('public.buy_item_self(text,text)'), ('public.buy_streak_shield_self()'),
    ('public.equip_item_self(text,text)'), ('public.set_showcase_self(smallint,text,text)'),
    ('public.submit_custom_title_self(text)'), ('public.request_weekly_shield_self(uuid)'),
    ('public.cancel_weekly_shield_self(uuid)'), ('public.get_daily_quests_self()'),
    ('public.replace_life_quest_self(smallint)'), ('public.claim_life_quest_self(smallint)'),
    ('public.review_assignment_self(uuid,text,text)'),
    ('public.apply_penalty_self(uuid,integer,text)'), ('public.get_review_queue_self(text)'),
    ('public.publish_weekly_plan_self(date,text,text,jsonb)'),
    ('public.cancel_weekly_plan_self(uuid)'),
    ('public.create_individual_assignment_self(bigint,text,text,text,integer)'),
    ('public.delete_individual_assignment_self(uuid)'), ('public.close_season_self()'),
    ('public.record_weekly_mock_exam_self(bigint,date,integer)'),
    ('public.review_custom_title_self(bigint,text,text)'),
    ('public.admin_list_life_quest_templates()'),
    ('public.admin_upsert_life_quest_template_self(text,text,text,text,integer)'),
    ('public.admin_set_life_quest_template_active_self(text,boolean)'),
    ('public.claim_collection_bonus_self(bigint)'), ('public.activate_due_assignments_self()'),
    ('public.get_economy_flags()'), ('public.ensure_current_season()'),
    ('public.ensure_season_rotation()'), ('public.get_student_league_snapshot_self()'),
    ('public.get_student_rank_title_self()'), ('public.preview_league_close_self()'),
    ('public.create_parent_invite_self()'), ('public.get_student_current_week(bigint)'),
    ('public.available_shield_quantity(bigint)'), ('public.get_mock_exam_trajectory(bigint)'),
    ('public.is_first_submission_on_time(timestamp with time zone,timestamp with time zone,date)'),
    ('public.week_start_of(date)'), ('public.weekly_reward_amount(integer)')
),
counts as (
  select
    count(*) filter (
      where not has_function_privilege('authenticated', to_regprocedure(sig), 'EXECUTE')
    ) as missing,
    (
      select count(*)
        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public'
         and has_function_privilege('authenticated', p.oid, 'EXECUTE')
         and not exists (
           select 1 from allowed a where to_regprocedure(a.sig) = p.oid
         )
    ) as unexpected
  from allowed
)
select '05b authenticated gateway allowlist exact',
       missing = 0 and unexpected = 0,
       format('missing=%s unexpected=%s', missing, unexpected)
  from counts;

insert into b2_t11_results
select '06 service_role integration contracts',
       has_schema_privilege('service_role', 'public', 'USAGE')
         and has_table_privilege('service_role', 'public.assignments', 'SELECT')
         and has_table_privilege('service_role', 'public.assignments', 'INSERT')
         and has_table_privilege('service_role', 'public.assignments', 'UPDATE')
         and has_table_privilege('service_role', 'public.assignments', 'DELETE')
         and has_table_privilege('service_role', 'public.bot_notification_state', 'SELECT')
         and has_table_privilege('service_role', 'public.bot_notification_state', 'INSERT')
         and has_table_privilege('service_role', 'public.bot_notification_state', 'UPDATE')
         and has_table_privilege('service_role', 'public.bot_notification_state', 'DELETE')
         and has_table_privilege('service_role', 'public.parent_links', 'SELECT')
         and has_table_privilege('service_role', 'public.parent_links', 'INSERT')
         and has_table_privilege('service_role', 'public.parent_links', 'UPDATE')
         and has_table_privilege('service_role', 'public.parent_links', 'DELETE')
         and has_table_privilege('service_role', 'public.student_payments', 'SELECT')
         and has_table_privilege('service_role', 'public.student_payments', 'INSERT')
         and has_table_privilege('service_role', 'public.student_payments', 'UPDATE')
         and has_table_privilege('service_role', 'public.student_payments', 'DELETE')
         and has_function_privilege(
           'service_role',
           'public.consume_parent_invite(text,bigint)'::regprocedure,
           'EXECUTE'
         )
         and has_function_privilege(
           'service_role',
           'public.record_weekly_mock_exam_service(bigint,date,integer)'::regprocedure,
           'EXECUTE'
         )
         and has_function_privilege(
           'service_role',
           'public.student_auth_upsert_principal(bigint)'::regprocedure,
           'EXECUTE'
         )
         and has_function_privilege(
           'service_role',
           'public.student_auth_upsert_principal(bigint,text,text)'::regprocedure,
           'EXECUTE'
         )
         and has_function_privilege(
           'service_role',
           'public.teacher_auth_upsert_principal(text)'::regprocedure,
           'EXECUTE'
         ),
       'main bot + parent bot + Sheets + auth/media server surface';

insert into b2_t11_results
select '07 legacy_import closed',
       to_regnamespace('legacy_import') is null
         or (
           not has_schema_privilege('anon', 'legacy_import', 'USAGE')
           and not has_schema_privilege('authenticated', 'legacy_import', 'USAGE')
           and not exists (
             select 1 from information_schema.role_table_grants
              where table_schema = 'legacy_import' and grantee in ('anon', 'authenticated')
           )
           and not exists (
             select 1 from information_schema.role_routine_grants
              where specific_schema = 'legacy_import' and grantee in ('anon', 'authenticated')
           )
         ),
       case when to_regnamespace('legacy_import') is null then 'schema already removed'
            else 'schema present but not exposed' end;

insert into b2_t11_results
select '08 migration 047 properties',
       bool_and(
         p.prosecdef and exists (
           select 1 from unnest(coalesce(p.proconfig, '{}'::text[])) c
            where replace(c, ' ', '') = 'search_path=public,pg_temp'
         )
       ) and count(*) = 2,
       format('matching hardened functions=%s', count(*))
  from pg_proc p
 where p.oid in (
   'public.ensure_season_rotation()'::regprocedure,
   'public.admin_list_life_quest_templates()'::regprocedure
 );

insert into b2_t11_results
select '09 default privileges closed',
       browser_entries = 0 and service_types = 3,
       format('browser/default PUBLIC entries=%s service object types=%s', browser_entries, service_types)
  from (
    select
      count(*) filter (where a.grantee = 0 or r.rolname in ('anon', 'authenticated'))
        as browser_entries,
      count(distinct d.defaclobjtype) filter (
        where d.defaclnamespace = 'public'::regnamespace
          and r.rolname = 'service_role'
      )
        as service_types
      from pg_default_acl d
      cross join lateral aclexplode(coalesce(d.defaclacl, acldefault(d.defaclobjtype, d.defaclrole))) a
      left join pg_roles r on r.oid = a.grantee
     where pg_get_userbyid(d.defaclrole) = 'postgres'
       and d.defaclnamespace in (0, 'public'::regnamespace)
       and d.defaclobjtype in ('r', 'S', 'f')
  ) defaults;

-- Fixed high values avoid sequence consumption. Abort before synthetic writes on any collision.
do $seed_guard$
begin
  if exists (
    select 1 from public.students
     where telegram_id in (9223372036854700001, 9223372036854700002)
  ) or exists (
    select 1 from public.seasons where id = 9223372036854700001
  ) or exists (
    select 1 from public.league_cohorts where id = 9223372036854700001
  ) then
    raise exception 'B2-T11 synthetic identifiers collide with existing dev data';
  end if;
end
$seed_guard$;

insert into public.students (id, telegram_id, name)
values
  (9223372036854700001, 9223372036854700001, 'B2-T11 own'),
  (9223372036854700002, 9223372036854700002, 'B2-T11 foreign');

insert into public.assignments (id, student_id, type, title)
values
  ('00000000-0000-4000-8000-000000001101', 9223372036854700001, 'individual', 'B2-T11 own'),
  ('00000000-0000-4000-8000-000000001102', 9223372036854700002, 'individual', 'B2-T11 foreign');

insert into public.student_items (id, student_id, item_code, quantity)
values
  ('00000000-0000-4000-8000-000000001111', 9223372036854700001, 'b2_t11_probe', 1),
  ('00000000-0000-4000-8000-000000001112', 9223372036854700002, 'b2_t11_probe', 1);

insert into public.weekly_mock_exams (id, student_id, week_start, score)
values
  ('00000000-0000-4000-8000-000000001121', 9223372036854700001, date '2099-01-05', 80),
  ('00000000-0000-4000-8000-000000001122', 9223372036854700002, date '2099-01-05', 90);

insert into public.seasons (id, start_date, end_date)
values (9223372036854700001, date '2098-12-01', date '2098-12-31');

insert into public.league_cohorts (id, season_id, tier, cohort_index, is_late_entry)
values (9223372036854700001, 9223372036854700001, 1, 922337203, false);

insert into public.league_memberships (
  id, season_id, cohort_id, student_id, tier, is_late_entry, points, place
)
values
  (
    9223372036854700001, 9223372036854700001, 9223372036854700001,
    9223372036854700001, 1, false, 10, 2
  ),
  (
    9223372036854700002, 9223372036854700001, 9223372036854700001,
    9223372036854700002, 1, false, 20, 1
  );

-- Real anon calls: mode succeeds, table and business RPC are denied by privileges.
set local role anon;
select set_config('request.jwt.claims', '{}', true);

insert into pg_temp.b2_t11_results
select '10 anon real mode call',
       public.security_auth_mode() = 'enforced',
       public.security_auth_mode();

do $anon_denials$
begin
  begin
    perform 1 from public.students limit 1;
    insert into pg_temp.b2_t11_results values
      ('11 anon real table/RPC denials', false, 'students SELECT unexpectedly succeeded');
  exception when insufficient_privilege then
    begin
      perform public.jwt_app_role();
      insert into pg_temp.b2_t11_results values
        ('11 anon real table/RPC denials', false, 'business RPC unexpectedly succeeded');
    exception when insufficient_privilege then
      insert into pg_temp.b2_t11_results values
        ('11 anon real table/RPC denials', true, 'table and business RPC denied');
    end;
  end;
end
$anon_denials$;

reset role;

-- Student claim: own rows visible, foreign rows hidden across core/game/mock/league.
set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-4000-8000-000000001101","app_role":"student","telegram_id":"9223372036854700001"}',
  true
);

insert into pg_temp.b2_t11_results
select '12 student own-only RLS',
       students = 1 and assignments = 1 and inventory = 1 and mock = 1 and league = 1,
       json_build_object(
         'students', students,
         'assignments', assignments,
         'inventory', inventory,
         'mock', mock,
         'league', league
       )::text
  from (
    select
      (select count(*) from public.students
        where telegram_id in (9223372036854700001, 9223372036854700002)) as students,
      (select count(*) from public.assignments
        where id in (
          '00000000-0000-4000-8000-000000001101',
          '00000000-0000-4000-8000-000000001102'
        )) as assignments,
      (select count(*) from public.student_items
        where student_id in (9223372036854700001, 9223372036854700002)) as inventory,
      (select count(*) from public.weekly_mock_exams
        where student_id in (9223372036854700001, 9223372036854700002)) as mock,
      (select count(*) from public.league_memberships
        where student_id in (9223372036854700001, 9223372036854700002)) as league
  ) counts;

do $student_checks$
begin
  begin
    perform public.admin_list_life_quest_templates();
    insert into pg_temp.b2_t11_results values
      ('13 student role gates and direct-DML denial', false, 'teacher catalog unexpectedly succeeded');
  exception when insufficient_privilege then
    begin
      update public.students set name = 'forbidden' where telegram_id = 9223372036854700001;
      insert into pg_temp.b2_t11_results values
        ('13 student role gates and direct-DML denial', false, 'direct UPDATE unexpectedly succeeded');
    exception when insufficient_privilege then
      begin
        perform public.buy_item(9223372036854700001, 'missing', null);
        insert into pg_temp.b2_t11_results values
          ('13 student role gates and direct-DML denial', false, 'legacy RPC unexpectedly executable');
      exception when insufficient_privilege then
        if public.get_student_current_week(9223372036854700001) is null then
          raise exception 'student current-week RPC returned null';
        end if;
        perform public.get_daily_quests_self();
        perform public.ensure_season_rotation();
        insert into pg_temp.b2_t11_results values
          (
            '13 student role gates and direct-DML denial',
            true,
            'teacher/direct/legacy denied; current week + quests + 047 helper passed'
          );
      end;
    end;
  end;
exception when others then
  insert into pg_temp.b2_t11_results values
    ('13 student role gates and direct-DML denial', false, sqlstate || ': ' || sqlerrm)
  on conflict (check_name) do update set passed = false, detail = excluded.detail;
end
$student_checks$;

reset role;

-- Teacher claim: approved academic reads pass, private inventory remains hidden.
set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-4000-8000-000000001199","app_role":"teacher","teacher_id":"owner"}',
  true
);

insert into pg_temp.b2_t11_results
select '14 teacher RLS read surface',
       students = 2 and assignments = 2 and mock = 2 and inventory = 0,
       json_build_object(
         'students', students,
         'assignments', assignments,
         'mock', mock,
         'inventory', inventory
       )::text
  from (
    select
      (select count(*) from public.students
        where telegram_id in (9223372036854700001, 9223372036854700002)) as students,
      (select count(*) from public.assignments
        where id in (
          '00000000-0000-4000-8000-000000001101',
          '00000000-0000-4000-8000-000000001102'
        )) as assignments,
      (select count(*) from public.weekly_mock_exams
        where student_id in (9223372036854700001, 9223372036854700002)) as mock,
      (select count(*) from public.student_items
        where student_id in (9223372036854700001, 9223372036854700002)) as inventory
  ) counts;

do $teacher_checks$
begin
  begin
    perform public.admin_list_life_quest_templates();
    begin
      perform public.create_parent_invite_self();
      insert into pg_temp.b2_t11_results values
        ('15 teacher/student role separation', false, 'student gateway unexpectedly succeeded');
    exception when insufficient_privilege then
      begin
        perform public.ensure_season_rotation();
        insert into pg_temp.b2_t11_results values
          ('15 teacher/student role separation', false, 'student 047 helper unexpectedly succeeded');
      exception when insufficient_privilege then
        begin
          delete from public.assignments where id = '00000000-0000-4000-8000-000000001101';
          insert into pg_temp.b2_t11_results values
            ('15 teacher/student role separation', false, 'direct DELETE unexpectedly succeeded');
        exception when insufficient_privilege then
          insert into pg_temp.b2_t11_results values
            ('15 teacher/student role separation', true, 'teacher catalog passed; student helpers/direct DELETE denied');
        end;
      end;
    end;
  exception when others then
    insert into pg_temp.b2_t11_results values
      ('15 teacher/student role separation', false, sqlstate || ': ' || sqlerrm)
    on conflict (check_name) do update set passed = false, detail = excluded.detail;
  end;
end
$teacher_checks$;

reset role;
set local role postgres;

-- Prove that closed default ACLs apply to every new object type and that unknown-object
-- detection sees the probes. Explicit postgres is required here: RESET ROLE in Supabase SQL
-- Editor returns its session role, which is not necessarily the owner of the public objects whose
-- default ACL T10-11 closed. Everything is dropped explicitly and the outer ROLLBACK is backup.
create table public.b2_t11_acl_probe (
  id bigint generated by default as identity primary key
);
create function public.b2_t11_acl_probe_fn()
returns integer language sql as $$ select 1 $$;

insert into b2_t11_results
select '16 future objects default-deny',
       anon_table_denied
         and auth_table_denied
         and service_table_select
         and service_table_insert
         and service_table_update
         and service_table_delete
         and anon_sequence_denied
         and auth_sequence_denied
         and service_sequence_usage
         and anon_function_denied
         and auth_function_denied
         and service_function_execute,
       json_build_object(
         'anon_table_denied', anon_table_denied,
         'auth_table_denied', auth_table_denied,
         'service_table_select', service_table_select,
         'service_table_insert', service_table_insert,
         'service_table_update', service_table_update,
         'service_table_delete', service_table_delete,
         'anon_sequence_denied', anon_sequence_denied,
         'auth_sequence_denied', auth_sequence_denied,
         'service_sequence_usage', service_sequence_usage,
         'anon_function_denied', anon_function_denied,
         'auth_function_denied', auth_function_denied,
         'service_function_execute', service_function_execute
       )::text
  from (
    select
      not has_table_privilege('anon', 'public.b2_t11_acl_probe', 'SELECT')
        as anon_table_denied,
      not has_table_privilege('authenticated', 'public.b2_t11_acl_probe', 'SELECT')
        as auth_table_denied,
      has_table_privilege('service_role', 'public.b2_t11_acl_probe', 'SELECT')
        as service_table_select,
      has_table_privilege('service_role', 'public.b2_t11_acl_probe', 'INSERT')
        as service_table_insert,
      has_table_privilege('service_role', 'public.b2_t11_acl_probe', 'UPDATE')
        as service_table_update,
      has_table_privilege('service_role', 'public.b2_t11_acl_probe', 'DELETE')
        as service_table_delete,
      not has_sequence_privilege('anon', 'public.b2_t11_acl_probe_id_seq', 'USAGE')
        as anon_sequence_denied,
      not has_sequence_privilege('authenticated', 'public.b2_t11_acl_probe_id_seq', 'USAGE')
        as auth_sequence_denied,
      has_sequence_privilege('service_role', 'public.b2_t11_acl_probe_id_seq', 'USAGE')
        as service_sequence_usage,
      not has_function_privilege(
        'anon', 'public.b2_t11_acl_probe_fn()'::regprocedure, 'EXECUTE'
      ) as anon_function_denied,
      not has_function_privilege(
        'authenticated', 'public.b2_t11_acl_probe_fn()'::regprocedure, 'EXECUTE'
      ) as auth_function_denied,
      has_function_privilege(
        'service_role', 'public.b2_t11_acl_probe_fn()'::regprocedure, 'EXECUTE'
      ) as service_function_execute
  ) probe_acl;

insert into b2_t11_results
select '17 unknown public object detector',
       (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
         where n.nspname = 'public' and c.relkind in ('r', 'p')) = 40
         and (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
               where n.nspname = 'public' and c.relkind = 'S') = 7
         and (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
               where n.nspname = 'public') = 103,
       'probe changed all three exact inventory counts';

drop function public.b2_t11_acl_probe_fn();
drop table public.b2_t11_acl_probe;

insert into b2_t11_results
select '18 probe cleanup before rollback',
       to_regclass('public.b2_t11_acl_probe') is null
         and to_regclass('public.b2_t11_acl_probe_id_seq') is null
         and to_regprocedure('public.b2_t11_acl_probe_fn()') is null,
       'no persistent probe object';

-- One result set: Supabase SQL Editor otherwise shows only the final SELECT and hides which
-- individual check failed.
with report as (
  select check_name,
         case when passed then 'PASS' else 'FAIL' end as result,
         detail,
         check_name as sort_key
    from b2_t11_results
  union all
  select '99 SUMMARY',
         case when bool_and(passed) and count(*) = 20 then 'PASS' else 'FAIL' end,
         case when bool_and(passed) and count(*) = 20
              then 'PASS B2-T11 (20/20); transaction will be rolled back'
              else format(
                'FAIL B2-T11 (%s/%s passed); failed: %s; transaction will be rolled back',
                count(*) filter (where passed),
                count(*),
                string_agg(check_name, ', ' order by check_name) filter (where not passed)
              )
         end,
         '99 SUMMARY'
    from b2_t11_results
)
select check_name, result, detail
  from report
 order by sort_key;

rollback;
