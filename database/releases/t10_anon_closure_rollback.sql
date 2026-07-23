-- =============================================================================
-- t10_anon_closure_rollback.sql — T10-11 controlled rollback to DB mode "legacy"
--
-- DEV ONLY. Idempotent. RLS and migrations 032-047 stay in place. This does not restore secrets,
-- old teacher password, unsigned uploads, imported data, ledgers, balances, or Stage 4 firing.
-- =============================================================================

begin;

do $preflight$
declare
  v_rows integer;
  v_mode text;
  v_detail text;
  v_deny constant text[] := array[
    'public.student_auth_upsert_principal(bigint)',
    'public.teacher_auth_upsert_principal(text)',
    'public.teacher_session_create(uuid,uuid,text,timestamp with time zone,integer)',
    'public.teacher_session_rotate(text,text,integer)',
    'public.security_rate_limit_hit(text,text,integer,integer)',
    'public.security_rate_limit_peek(text,text,integer,integer)',
    'public.security_audit(text,text,uuid,text,jsonb)',
    'public.consume_parent_invite(text,bigint)',
    'public.record_weekly_mock_exam_service(bigint,date,integer)',
    'public.get_student_league_snapshot(bigint)',
    'public.get_student_rank_title(bigint)',
    'public.preview_league_close()',
    'public.settle_legacy_approval(uuid)'
  ];
begin
  select count(*), min(auth_mode) into v_rows, v_mode
    from private.security_runtime_config;
  if v_rows <> 1 or v_mode not in ('enforced', 'legacy') then
    raise exception 'T10-11 rollback preflight: runtime rows %, mode %', v_rows, v_mode;
  end if;

  perform id from private.security_runtime_config where id for update;
  get diagnostics v_rows = row_count;
  if v_rows <> 1 then
    raise exception 'T10-11 rollback preflight: singleton lock count %, expected 1', v_rows;
  end if;

  if (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
       where n.nspname = 'public' and c.relkind in ('r', 'p')) <> 39
     or (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
          where n.nspname = 'private' and c.relkind in ('r', 'p')) <> 5
     or (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
          where n.nspname = 'public' and c.relkind = 'S') <> 6
     or (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
          where n.nspname = 'public') <> 102
     or (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
          where n.nspname = 'private') <> 5
     or (select count(*) from pg_policies where schemaname = 'public') <> 29 then
    raise exception 'T10-11 rollback preflight: object/policy inventory drift';
  end if;

  select string_agg(format('%I.%I', n.nspname, c.relname), ', ' order by n.nspname, c.relname)
    into v_detail
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname in ('public', 'private') and c.relkind in ('r', 'p')
     and not c.relrowsecurity;
  if v_detail is not null then
    raise exception 'T10-11 rollback preflight: RLS disabled on %', v_detail;
  end if;

  select string_agg(r.rolname || ':' || c.relname, ', ' order by r.rolname, c.relname)
    into v_detail
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
  if v_detail is not null then
    raise exception 'T10-11 rollback preflight: browser DML drift: %', v_detail;
  end if;

  select string_agg(r.rolname || ':' || f, ', ' order by r.rolname, f) into v_detail
    from pg_roles r cross join unnest(v_deny) f
   where r.rolname in ('anon', 'authenticated')
     and has_function_privilege(r.rolname, to_regprocedure(f), 'EXECUTE');
  if v_detail is not null then
    raise exception 'T10-11 rollback preflight: service/internal RPC exposed: %', v_detail;
  end if;

  if to_regnamespace('legacy_import') is not null
     and (has_schema_privilege('anon', 'legacy_import', 'USAGE')
       or has_schema_privilege('authenticated', 'legacy_import', 'USAGE')) then
    raise exception 'T10-11 rollback preflight: legacy_import exposed';
  end if;

  if v_mode = 'enforced' and (
    (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public'
        and case when c.relkind in ('r', 'p')
                 then has_table_privilege('anon', c.oid, 'SELECT')
                 else false end) <> 0
    or (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
         where n.nspname = 'public'
           and case when c.relkind in ('r', 'p')
                    then has_table_privilege('authenticated', c.oid, 'SELECT')
                    else false end) <> 25
    or (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public'
           and has_function_privilege('anon', p.oid, 'EXECUTE')) <> 1
    or (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public'
           and has_function_privilege('authenticated', p.oid, 'EXECUTE')) <> 43
    or not has_function_privilege(
      'anon', 'public.security_auth_mode()'::regprocedure, 'EXECUTE'
    )
  ) then
    raise exception 'T10-11 rollback preflight: enforced role-matrix drift';
  end if;
end
$preflight$;

-- Deterministic reset makes a repeated rollback safe.
revoke all privileges on all tables in schema public from public, anon, authenticated;
revoke all privileges on all sequences in schema public from public, anon, authenticated;
revoke all privileges on all functions in schema public from public, anon, authenticated;

grant all privileges on all tables in schema public to service_role;
grant all privileges on all sequences in schema public to service_role;
grant all privileges on all functions in schema public to service_role;

-- The authenticated secure client remains fully usable while the adapter observes DB mode legacy.
grant select on table
  public.students,
  public.assignments,
  public.balance_history,
  public.weekly_mock_exams,
  public.mock_exam_results,
  public.student_items,
  public.student_equipment,
  public.student_showcase,
  public.student_custom_titles,
  public.student_achievements,
  public.season_results,
  public.student_week_results,
  public.weekly_shield_uses,
  public.streak_shield_uses,
  public.league_memberships,
  public.league_movements,
  public.league_season_awards,
  public.student_daily_quests,
  public.student_daily_quest_options,
  public.shop_items,
  public.season_bundles,
  public.seasons,
  public.life_quest_templates,
  public.weekly_plans,
  public.weekly_plan_items
to authenticated;

grant execute on function
  public.security_auth_mode(),
  public.jwt_app_role(),
  public.jwt_student_id(),
  public.ensure_student_self(text,text),
  public.submit_assignment_self(uuid,text),
  public.buy_item_self(text,text),
  public.buy_streak_shield_self(),
  public.equip_item_self(text,text),
  public.set_showcase_self(smallint,text,text),
  public.submit_custom_title_self(text),
  public.request_weekly_shield_self(uuid),
  public.cancel_weekly_shield_self(uuid),
  public.get_daily_quests_self(),
  public.replace_life_quest_self(),
  public.claim_life_quest_self(),
  public.review_assignment_self(uuid,text,text),
  public.apply_penalty_self(uuid,integer,text),
  public.get_review_queue_self(text),
  public.publish_weekly_plan_self(date,text,text,jsonb),
  public.cancel_weekly_plan_self(uuid),
  public.create_individual_assignment_self(bigint,text,text,text,integer),
  public.delete_individual_assignment_self(uuid),
  public.close_season_self(),
  public.record_weekly_mock_exam_self(bigint,date,integer),
  public.review_custom_title_self(bigint,text,text),
  public.admin_list_life_quest_templates(),
  public.admin_upsert_life_quest_template_self(text,text,text,text,integer),
  public.admin_set_life_quest_template_active_self(text,boolean),
  public.claim_collection_bonus_self(bigint),
  public.activate_due_assignments_self(),
  public.get_economy_flags(),
  public.ensure_current_season(),
  public.ensure_season_rotation(),
  public.get_student_league_snapshot_self(),
  public.get_student_rank_title_self(),
  public.preview_league_close_self(),
  public.create_parent_invite_self(),
  public.get_student_current_week(bigint),
  public.available_shield_quantity(bigint),
  public.get_mock_exam_trajectory(bigint),
  public.is_first_submission_on_time(timestamp with time zone,timestamp with time zone,date),
  public.week_start_of(date),
  public.weekly_reward_amount(integer)
to authenticated;

-- Pre-T10-11 dev compatibility only. RLS and direct-DML revokes still make this fail closed for
-- anonymous personal data; service-only RPC and the two role-hardened 047 RPC stay closed.
grant select on table
  public.students,
  public.assignments,
  public.balance_history,
  public.weekly_mock_exams,
  public.mock_exam_results,
  public.student_items,
  public.student_equipment,
  public.student_showcase,
  public.student_custom_titles,
  public.student_achievements,
  public.season_results,
  public.student_week_results,
  public.weekly_shield_uses,
  public.streak_shield_uses,
  public.league_memberships,
  public.league_movements,
  public.league_season_awards,
  public.student_daily_quests,
  public.student_daily_quest_options,
  public.shop_items,
  public.season_bundles,
  public.seasons,
  public.life_quest_templates,
  public.weekly_plans,
  public.weekly_plan_items
to anon;

grant execute on function
  public.security_auth_mode(),
  public.jwt_app_role(),
  public.jwt_student_id(),
  public.add_huikons(bigint,integer,text),
  public.buy_item(bigint,text,text),
  public.buy_streak_shield(bigint),
  public.equip_item(bigint,text,text),
  public.set_showcase(bigint,smallint,text,text),
  public.submit_custom_title(bigint,text),
  public.request_weekly_shield(bigint,uuid),
  public.cancel_weekly_shield(bigint,uuid),
  public.get_daily_quests(bigint),
  public.replace_life_quest(bigint),
  public.claim_life_quest(bigint),
  public.get_student_current_week(bigint),
  public.available_shield_quantity(bigint),
  public.get_mock_exam_trajectory(bigint),
  public.is_first_submission_on_time(timestamp with time zone,timestamp with time zone,date),
  public.week_start_of(date),
  public.weekly_reward_amount(integer)
to anon, authenticated;

-- Keep T10-11 secure default privileges even during rollback: reopening future objects is never
-- required for dev legacy compatibility.
alter default privileges for role postgres
  revoke all privileges on tables from public, anon, authenticated;
alter default privileges for role postgres
  revoke all privileges on sequences from public, anon, authenticated;
alter default privileges for role postgres
  revoke all privileges on functions from public, anon, authenticated;
alter default privileges for role postgres in schema public
  grant all privileges on tables to service_role;
alter default privileges for role postgres in schema public
  grant all privileges on sequences to service_role;
alter default privileges for role postgres in schema public
  grant all privileges on functions to service_role;

update private.security_runtime_config
   set auth_mode = 'legacy',
       updated_at = now()
 where id;

do $postflight$
declare
  v_rows integer;
  v_mode text;
  v_detail text;
  v_deny constant text[] := array[
    'public.student_auth_upsert_principal(bigint)',
    'public.teacher_auth_upsert_principal(text)',
    'public.teacher_session_create(uuid,uuid,text,timestamp with time zone,integer)',
    'public.teacher_session_rotate(text,text,integer)',
    'public.security_rate_limit_hit(text,text,integer,integer)',
    'public.security_rate_limit_peek(text,text,integer,integer)',
    'public.security_audit(text,text,uuid,text,jsonb)',
    'public.consume_parent_invite(text,bigint)',
    'public.record_weekly_mock_exam_service(bigint,date,integer)',
    'public.get_student_league_snapshot(bigint)',
    'public.get_student_rank_title(bigint)',
    'public.preview_league_close()',
    'public.settle_legacy_approval(uuid)'
  ];
begin
  select count(*), min(auth_mode) into v_rows, v_mode
    from private.security_runtime_config;
  if v_rows <> 1 or v_mode is distinct from 'legacy' then
    raise exception 'T10-11 rollback postflight: runtime rows %, mode %', v_rows, v_mode;
  end if;

  select string_agg(r.rolname || ':' || c.relname, ', ' order by r.rolname, c.relname)
    into v_detail
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
  if v_detail is not null then
    raise exception 'T10-11 rollback postflight: browser DML remains: %', v_detail;
  end if;

  select string_agg(r.rolname || ':' || f, ', ' order by r.rolname, f) into v_detail
    from pg_roles r cross join unnest(v_deny) f
   where r.rolname in ('anon', 'authenticated')
     and has_function_privilege(r.rolname, to_regprocedure(f), 'EXECUTE');
  if v_detail is not null then
    raise exception 'T10-11 rollback postflight: service/internal RPC exposed: %', v_detail;
  end if;

  if has_function_privilege('anon', 'public.ensure_season_rotation()'::regprocedure, 'EXECUTE')
     or has_function_privilege(
       'anon', 'public.admin_list_life_quest_templates()'::regprocedure, 'EXECUTE'
     ) then
    raise exception 'T10-11 rollback postflight: migration 047 hardening was weakened';
  end if;

  if (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
       where n.nspname = 'public'
         and case when c.relkind in ('r', 'p')
                  then has_table_privilege('anon', c.oid, 'SELECT')
                  else false end) <> 25
     or (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
          where n.nspname = 'public'
            and case when c.relkind in ('r', 'p')
                     then has_table_privilege('authenticated', c.oid, 'SELECT')
                     else false end) <> 25
     or (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
          where n.nspname = 'public'
            and has_function_privilege('anon', p.oid, 'EXECUTE')) <> 20
     or (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
          where n.nspname = 'public'
            and has_function_privilege('authenticated', p.oid, 'EXECUTE')) <> 54 then
    raise exception 'T10-11 rollback postflight: legacy compatibility role-matrix drift';
  end if;

  if exists (
    select 1 from pg_default_acl d
    cross join lateral aclexplode(coalesce(d.defaclacl, acldefault(d.defaclobjtype, d.defaclrole))) a
    left join pg_roles r on r.oid = a.grantee
    where pg_get_userbyid(d.defaclrole) = 'postgres'
      and d.defaclnamespace in (0, 'public'::regnamespace)
      and d.defaclobjtype in ('r', 'S', 'f')
      and (a.grantee = 0 or r.rolname in ('anon', 'authenticated'))
  ) then
    raise exception 'T10-11 rollback postflight: insecure default privilege restored';
  end if;

  raise notice 'PASS T10-11 rollback: auth_mode=legacy, RLS/hardening/default-deny preserved';
end
$postflight$;

commit;
