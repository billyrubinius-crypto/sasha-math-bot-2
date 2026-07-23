-- =============================================================================
-- t10_anon_closure.sql — T10-11 atomic anon closure
--
-- DEV ONLY. Run manually after migration 047. This is a release transaction, not a migration.
-- Any drift raises before the first REVOKE/GRANT/UPDATE. Production stays untouched until T10-12.
-- =============================================================================

begin;

-- The first loop iteration is read-only. The second takes the singleton row lock and repeats the
-- same complete preflight, so no grant or runtime-mode mutation can happen on stale assumptions.
do $preflight$
declare
  v_pass integer;
  v_rows integer;
  v_detail text;
  v_expected_public_tables constant text[] := array[
    'public.assignment_reward_log', 'public.assignments', 'public.balance_history',
    'public.bot_notification_state', 'public.daily_quest_reward_log', 'public.economy_config',
    'public.homework_submissions', 'public.league_cohorts', 'public.league_memberships',
    'public.league_movements', 'public.league_season_awards', 'public.league_tiers',
    'public.life_quest_templates', 'public.mock_exam_results', 'public.mock_exam_reward_log',
    'public.parent_invites', 'public.parent_links', 'public.season_bundles',
    'public.season_points_log', 'public.season_results', 'public.seasons', 'public.shop_items',
    'public.streak_shield_uses', 'public.student_achievements', 'public.student_custom_titles',
    'public.student_daily_quest_options', 'public.student_daily_quests',
    'public.student_equipment', 'public.student_items', 'public.student_league_state',
    'public.student_payments', 'public.student_showcase', 'public.student_week_results',
    'public.students', 'public.weekly_mock_exams', 'public.weekly_plan_items',
    'public.weekly_plans', 'public.weekly_reward_log', 'public.weekly_shield_uses'
  ];
  v_expected_private_tables constant text[] := array[
    'private.security_audit_log', 'private.security_principals',
    'private.security_rate_limits', 'private.security_runtime_config',
    'private.teacher_sessions'
  ];
  v_expected_sequences constant text[] := array[
    'public.league_cohorts_id_seq', 'public.league_memberships_id_seq',
    'public.league_movements_id_seq', 'public.league_season_awards_id_seq',
    'public.seasons_id_seq', 'public.students_id_seq'
  ];
  v_expected_public_functions constant text[] := array[
    'public.activate_due_assignments_self()',
    'public.add_huikons(bigint,integer,text)',
    'public.add_season_points(bigint,integer)',
    'public.admin_list_life_quest_templates()',
    'public.admin_set_life_quest_template_active(text,boolean)',
    'public.admin_set_life_quest_template_active_self(text,boolean)',
    'public.admin_upsert_life_quest_template(text,text,text,text,integer)',
    'public.admin_upsert_life_quest_template_self(text,text,text,text,integer)',
    'public.apply_penalty_self(uuid,integer,text)',
    'public.available_shield_quantity(bigint)',
    'public.award_season_points(bigint,integer,text,text)',
    'public.build_season_cohorts(bigint,bigint)',
    'public.buy_item(bigint,text,text)',
    'public.buy_item_self(text,text)',
    'public.buy_streak_shield(bigint)',
    'public.buy_streak_shield_self()',
    'public.cancel_weekly_plan(uuid)',
    'public.cancel_weekly_plan_self(uuid)',
    'public.cancel_weekly_shield(bigint,uuid)',
    'public.cancel_weekly_shield_self(uuid)',
    'public.claim_collection_bonus_self(bigint)',
    'public.claim_life_quest(bigint,smallint)',
    'public.claim_life_quest_self(smallint)',
    'public.close_league_season(bigint,bigint)',
    'public.close_season()',
    'public.close_season_self()',
    'public.consume_parent_invite(text,bigint)',
    'public.consume_streak_shield(bigint,date)',
    'public.create_individual_assignment_self(bigint,text,text,text,integer)',
    'public.create_parent_invite_self()',
    'public.daily_quest_state(bigint,date)',
    'public.delete_individual_assignment_self(uuid)',
    'public.ensure_current_season()',
    'public.ensure_daily_quest(bigint,date,boolean)',
    'public.ensure_league_membership(bigint)',
    'public.ensure_season_rotation()',
    'public.ensure_student_self(text,text)',
    'public.equip_item(bigint,text,text)',
    'public.equip_item_self(text,text)',
    'public.finalize_due_student_weeks()',
    'public.finalize_student_week(bigint,date)',
    'public.get_daily_quests(bigint)',
    'public.get_daily_quests_self()',
    'public.get_economy_flags()',
    'public.get_mock_exam_trajectory(bigint)',
    'public.get_review_queue_self(text)',
    'public.get_student_current_week(bigint)',
    'public.get_student_league_snapshot(bigint)',
    'public.get_student_league_snapshot_self()',
    'public.get_student_progress(bigint)',
    'public.get_student_rank_title(bigint)',
    'public.get_student_rank_title_self()',
    'public.get_student_task_totals(bigint,date,date)',
    'public.grant_achievement_server(bigint,text,integer)',
    'public.grant_life_achievements(bigint)',
    'public.grant_weekly_achievements(bigint,date)',
    'public.is_first_submission_on_time(timestamp with time zone,timestamp with time zone,date)',
    'public.jwt_app_role()',
    'public.jwt_student_id()',
    'public.next_monday_msk(date)',
    'public.pick_life_template(text[])',
    'public.preview_league_close()',
    'public.preview_league_close_self()',
    'public.publish_weekly_plan(date,text,text,jsonb)',
    'public.publish_weekly_plan_self(date,text,text,jsonb)',
    'public.recalc_student_week(bigint,date)',
    'public.record_approved_assignment(uuid)',
    'public.record_weekly_mock_exam(bigint,date,integer)',
    'public.record_weekly_mock_exam_self(bigint,date,integer)',
    'public.record_weekly_mock_exam_service(bigint,date,integer)',
    'public.replace_life_quest(bigint,smallint)',
    'public.replace_life_quest_self(smallint)',
    'public.request_weekly_shield(bigint,uuid)',
    'public.request_weekly_shield_self(uuid)',
    'public.review_assignment_self(uuid,text,text)',
    'public.review_custom_title(bigint,text,text)',
    'public.review_custom_title_self(bigint,text,text)',
    'public.security_audit(text,text,uuid,text,jsonb)',
    'public.security_auth_mode()',
    'public.security_rate_limit_hit(text,text,integer,integer)',
    'public.security_rate_limit_peek(text,text,integer,integer)',
    'public.set_showcase(bigint,smallint,text,text)',
    'public.set_showcase_self(smallint,text,text)',
    'public.settle_daily_combo(bigint,date)',
    'public.settle_daily_math(uuid)',
    'public.settle_legacy_approval(uuid)',
    'public.stage4_generation_active()',
    'public.stage4_settlement_active(timestamp with time zone)',
    'public.student_auth_upsert_principal(bigint)',
    'public.submit_assignment_self(uuid,text)',
    'public.submit_custom_title(bigint,text)',
    'public.submit_custom_title_self(text)',
    'public.sync_student_week_assignments(bigint,date,date)',
    'public.teacher_auth_upsert_principal(text)',
    'public.teacher_session_create(uuid,uuid,text,timestamp with time zone,integer)',
    'public.teacher_session_rotate(text,text,integer)',
    'public.trg_assignments_release_shield()',
    'public.trg_assignments_revision_lifecycle()',
    'public.trg_students_sync_weekly_plans()',
    'public.week_start_of(date)',
    'public.weekly_economy_active(date)',
    'public.weekly_reward_amount(integer)'
  ];
  v_expected_private_functions constant text[] := array[
    'private.current_app_role()', 'private.current_principal()',
    'private.current_teacher_id()', 'private.current_telegram_id()', 'private.jwt_claims()'
  ];
  v_select_allowlist constant text[] := array[
    'public.students', 'public.assignments', 'public.balance_history',
    'public.weekly_mock_exams', 'public.mock_exam_results', 'public.student_items',
    'public.student_equipment', 'public.student_showcase', 'public.student_custom_titles',
    'public.student_achievements', 'public.season_results', 'public.student_week_results',
    'public.weekly_shield_uses', 'public.streak_shield_uses', 'public.league_memberships',
    'public.league_movements', 'public.league_season_awards', 'public.student_daily_quests',
    'public.student_daily_quest_options', 'public.shop_items', 'public.season_bundles',
    'public.seasons', 'public.life_quest_templates', 'public.weekly_plans',
    'public.weekly_plan_items'
  ];
  v_execute_allowlist constant text[] := array[
    'public.security_auth_mode()', 'public.jwt_app_role()', 'public.jwt_student_id()',
    'public.ensure_student_self(text,text)', 'public.submit_assignment_self(uuid,text)',
    'public.buy_item_self(text,text)', 'public.buy_streak_shield_self()',
    'public.equip_item_self(text,text)', 'public.set_showcase_self(smallint,text,text)',
    'public.submit_custom_title_self(text)', 'public.request_weekly_shield_self(uuid)',
    'public.cancel_weekly_shield_self(uuid)', 'public.get_daily_quests_self()',
    'public.replace_life_quest_self(smallint)', 'public.claim_life_quest_self(smallint)',
    'public.review_assignment_self(uuid,text,text)',
    'public.apply_penalty_self(uuid,integer,text)', 'public.get_review_queue_self(text)',
    'public.publish_weekly_plan_self(date,text,text,jsonb)',
    'public.cancel_weekly_plan_self(uuid)',
    'public.create_individual_assignment_self(bigint,text,text,text,integer)',
    'public.delete_individual_assignment_self(uuid)', 'public.close_season_self()',
    'public.record_weekly_mock_exam_self(bigint,date,integer)',
    'public.review_custom_title_self(bigint,text,text)',
    'public.admin_list_life_quest_templates()',
    'public.admin_upsert_life_quest_template_self(text,text,text,text,integer)',
    'public.admin_set_life_quest_template_active_self(text,boolean)',
    'public.claim_collection_bonus_self(bigint)', 'public.activate_due_assignments_self()',
    'public.get_economy_flags()', 'public.ensure_current_season()',
    'public.ensure_season_rotation()', 'public.get_student_league_snapshot_self()',
    'public.get_student_rank_title_self()', 'public.preview_league_close_self()',
    'public.create_parent_invite_self()', 'public.get_student_current_week(bigint)',
    'public.available_shield_quantity(bigint)', 'public.get_mock_exam_trajectory(bigint)',
    'public.is_first_submission_on_time(timestamp with time zone,timestamp with time zone,date)',
    'public.week_start_of(date)', 'public.weekly_reward_amount(integer)'
  ];
  v_browser_deny_functions constant text[] := array[
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
  v_expected_policies constant text[] := array[
    'assignments|assignments_select_own',
    'assignments|assignments_select_teacher',
    'balance_history|balance_history_select_own',
    'league_memberships|league_memberships_select_own',
    'league_movements|league_movements_select_own',
    'league_season_awards|league_season_awards_select_own',
    'life_quest_templates|life_quest_templates_select',
    'mock_exam_results|mock_exam_results_select_own',
    'season_bundles|season_bundles_select_auth',
    'season_results|season_results_select_own',
    'seasons|seasons_select_auth',
    'shop_items|shop_items_select_auth',
    'streak_shield_uses|streak_shield_uses_select_own',
    'student_achievements|student_achievements_select_own',
    'student_custom_titles|student_custom_titles_select_own',
    'student_custom_titles|student_custom_titles_select_teacher',
    'student_daily_quest_options|student_daily_quest_options_select_own',
    'student_daily_quests|student_daily_quests_select_own',
    'student_equipment|student_equipment_select_own',
    'student_items|student_items_select_own',
    'student_showcase|student_showcase_select_own',
    'student_week_results|student_week_results_select_own',
    'students|students_select_own',
    'students|students_select_teacher',
    'weekly_mock_exams|weekly_mock_exams_select_own',
    'weekly_mock_exams|weekly_mock_exams_select_teacher',
    'weekly_plan_items|weekly_plan_items_select_teacher',
    'weekly_plans|weekly_plans_select_teacher',
    'weekly_shield_uses|weekly_shield_uses_select_own'
  ];
begin
  for v_pass in 1..2 loop
    if v_pass = 2 then
      perform id
        from private.security_runtime_config
       where id
       for update;
      get diagnostics v_rows = row_count;
      if v_rows <> 1 then
        raise exception 'T10-11 preflight after lock: singleton lock count %, expected 1', v_rows;
      end if;
    end if;

    select count(*), min(auth_mode)
      into v_rows, v_detail
      from private.security_runtime_config;
    if v_rows <> 1 or v_detail is distinct from 'legacy' then
      raise exception 'T10-11 preflight pass %: runtime singleton/mode drift (rows %, mode %)',
        v_pass, v_rows, v_detail;
    end if;

    select string_agg(x, ', ' order by x) into v_detail
      from unnest(v_expected_public_tables || v_expected_private_tables || v_expected_sequences) x
     where to_regclass(x) is null;
    if v_detail is not null then
      raise exception 'T10-11 preflight pass %: missing relations: %', v_pass, v_detail;
    end if;

    select string_agg(x, ', ' order by x) into v_detail
      from unnest(v_expected_public_functions || v_expected_private_functions) x
     where to_regprocedure(x) is null;
    if v_detail is not null then
      raise exception 'T10-11 preflight pass %: missing functions: %', v_pass, v_detail;
    end if;

    select count(*) into v_rows
      from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind in ('r', 'p');
    if v_rows <> cardinality(v_expected_public_tables) then
      raise exception 'T10-11 preflight pass %: public table count %, expected %',
        v_pass, v_rows, cardinality(v_expected_public_tables);
    end if;
    select count(*) into v_rows
      from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'private' and c.relkind in ('r', 'p');
    if v_rows <> cardinality(v_expected_private_tables) then
      raise exception 'T10-11 preflight pass %: private table count %, expected %',
        v_pass, v_rows, cardinality(v_expected_private_tables);
    end if;
    select count(*) into v_rows
      from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind = 'S';
    if v_rows <> cardinality(v_expected_sequences) then
      raise exception 'T10-11 preflight pass %: public sequence count %, expected %',
        v_pass, v_rows, cardinality(v_expected_sequences);
    end if;
    select count(*) into v_rows
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public';
    if v_rows <> cardinality(v_expected_public_functions) then
      raise exception 'T10-11 preflight pass %: public function count %, expected %',
        v_pass, v_rows, cardinality(v_expected_public_functions);
    end if;
    select count(*) into v_rows
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'private';
    if v_rows <> cardinality(v_expected_private_functions) then
      raise exception 'T10-11 preflight pass %: private function count %, expected %',
        v_pass, v_rows, cardinality(v_expected_private_functions);
    end if;

    select string_agg(format('%I.%I', n.nspname, c.relname), ', ' order by n.nspname, c.relname)
      into v_detail
      from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname in ('public', 'private') and c.relkind in ('r', 'p')
       and not c.relrowsecurity;
    if v_detail is not null then
      raise exception 'T10-11 preflight pass %: RLS disabled on %', v_pass, v_detail;
    end if;

    select string_agg(x, ', ' order by x) into v_detail
      from unnest(v_expected_policies) x
     where not exists (
       select 1 from pg_policies p
        where p.schemaname = 'public'
          and p.tablename || '|' || p.policyname = x
          and p.cmd = 'SELECT'
          and p.permissive = 'PERMISSIVE'
          and p.roles::text = '{authenticated}'
     );
    if v_detail is not null then
      raise exception 'T10-11 preflight pass %: missing/drifted policies: %', v_pass, v_detail;
    end if;
    select string_agg(p.tablename || '|' || p.policyname, ', ' order by p.tablename, p.policyname)
      into v_detail
      from pg_policies p
     where p.schemaname = 'public'
       and not (p.tablename || '|' || p.policyname = any(v_expected_policies));
    if v_detail is not null then
      raise exception 'T10-11 preflight pass %: unknown public policies: %', v_pass, v_detail;
    end if;
    select count(*) into v_rows from pg_policies where schemaname = 'private';
    if v_rows <> 0 then
      raise exception 'T10-11 preflight pass %: private policies found: %', v_pass, v_rows;
    end if;
    if exists (
      select 1 from pg_policies p
       where p.schemaname = 'public' and 'anon' = any(p.roles)
    ) then
      raise exception 'T10-11 preflight pass %: anon policy exists', v_pass;
    end if;
    if exists (
      select 1
        from pg_policy pol
        join pg_class c on c.oid = pol.polrelid
        join pg_namespace n on n.oid = c.relnamespace
       where n.nspname = 'public'
         and (
           pol.polqual is null
           or pol.polwithcheck is not null
           or (
             pol.polname like '%\_select\_own' escape '\'
             and pg_get_expr(pol.polqual, pol.polrelid) not like '%jwt_student_id()%'
           )
           or (
             pol.polname like '%\_select\_teacher' escape '\'
             and pg_get_expr(pol.polqual, pol.polrelid) not like '%jwt_app_role()%'
           )
           or (
             pol.polname like '%\_select\_auth' escape '\'
             and replace(replace(pg_get_expr(pol.polqual, pol.polrelid), '(', ''), ')', '')
                 <> 'true'
           )
           or (
             pol.polname = 'life_quest_templates_select'
             and (
               pg_get_expr(pol.polqual, pol.polrelid) not like '%active%'
               or pg_get_expr(pol.polqual, pol.polrelid) not like '%jwt_app_role()%'
             )
           )
         )
    ) then
      raise exception 'T10-11 preflight pass %: RLS policy expression drift', v_pass;
    end if;

    if not exists (
      select 1 from pg_proc p
       where p.oid = 'public.ensure_season_rotation()'::regprocedure
         and p.prosecdef
         and exists (
           select 1 from unnest(coalesce(p.proconfig, '{}'::text[])) c
            where replace(c, ' ', '') = 'search_path=public,pg_temp'
         )
    ) or not exists (
      select 1 from pg_proc p
       where p.oid = 'public.admin_list_life_quest_templates()'::regprocedure
         and p.prosecdef
         and exists (
           select 1 from unnest(coalesce(p.proconfig, '{}'::text[])) c
            where replace(c, ' ', '') = 'search_path=public,pg_temp'
         )
    ) then
      raise exception 'T10-11 preflight pass %: migration 047 is absent or drifted', v_pass;
    end if;

    select string_agg(x, ', ' order by x) into v_detail
      from unnest(v_select_allowlist) x where to_regclass(x) is null;
    if v_detail is not null then
      raise exception 'T10-11 preflight pass %: SELECT allowlist missing: %', v_pass, v_detail;
    end if;
    select string_agg(x, ', ' order by x) into v_detail
      from unnest(v_execute_allowlist) x where to_regprocedure(x) is null;
    if v_detail is not null then
      raise exception 'T10-11 preflight pass %: EXECUTE allowlist missing: %', v_pass, v_detail;
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
       else false end;
    if v_detail is not null then
      raise exception 'T10-11 preflight pass %: browser DML grants remain: %', v_pass, v_detail;
    end if;

    select string_agg(r.rolname || ':' || x, ', ' order by r.rolname, x) into v_detail
      from pg_roles r cross join unnest(v_browser_deny_functions) x
     where r.rolname in ('anon', 'authenticated')
       and has_function_privilege(r.rolname, to_regprocedure(x), 'EXECUTE');
    if v_detail is not null then
      raise exception 'T10-11 preflight pass %: browser can execute denylisted RPC: %',
        v_pass, v_detail;
    end if;

    if to_regnamespace('legacy_import') is not null then
      if has_schema_privilege('anon', 'legacy_import', 'USAGE')
         or has_schema_privilege('authenticated', 'legacy_import', 'USAGE')
         or exists (
           select 1
             from information_schema.role_table_grants
            where table_schema = 'legacy_import'
              and grantee in ('anon', 'authenticated')
         )
         or exists (
           select 1
             from information_schema.role_routine_grants
            where specific_schema = 'legacy_import'
              and grantee in ('anon', 'authenticated')
         ) then
        raise exception 'T10-11 preflight pass %: legacy_import exposed to browser roles', v_pass;
      end if;
    end if;

    select string_agg(distinct pg_get_userbyid(owner_oid), ', ' order by pg_get_userbyid(owner_oid))
      into v_detail
      from (
        select c.relowner as owner_oid
          from pg_class c join pg_namespace n on n.oid = c.relnamespace
         where n.nspname = 'public' and c.relkind in ('r', 'p', 'S')
        union all
        select p.proowner
          from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public'
      ) owners;
    if v_detail is distinct from 'postgres' then
      raise exception 'T10-11 preflight pass %: public object owners %, expected postgres',
        v_pass, coalesce(v_detail, '<none>');
    end if;
  end loop;
end
$preflight$;

-- Close every existing public object first. The allowlists below are the only browser reopen.
revoke all privileges on all tables in schema public from public, anon, authenticated;
revoke all privileges on all sequences in schema public from public, anon, authenticated;
revoke all privileges on all functions in schema public from public, anon, authenticated;

-- Server-side Edge/API surface remains operational under the non-publishable service role.
grant all privileges on all tables in schema public to service_role;
grant all privileges on all sequences in schema public to service_role;
grant all privileges on all functions in schema public to service_role;

-- Browser reads: grants and RLS must both allow the row.
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
  public.replace_life_quest_self(smallint),
  public.claim_life_quest_self(smallint),
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

grant execute on function public.security_auth_mode() to anon;

-- PostgreSQL's built-in PUBLIC EXECUTE for functions is a global default. A schema-local REVOKE
-- cannot override it, so browser defaults must be revoked globally for the actual object owner.
-- service_role grants stay scoped to public; client access is opt-in in a reviewed migration.
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

do $switch$
declare
  v_rows integer;
begin
  update private.security_runtime_config
     set auth_mode = 'enforced',
         updated_at = now()
   where id and auth_mode = 'legacy';
  get diagnostics v_rows = row_count;
  if v_rows <> 1 then
    raise exception 'T10-11 switch: updated % runtime rows, expected 1', v_rows;
  end if;
end
$switch$;

-- Postflight is intentionally inside the same transaction: COMMIT is unreachable on any drift.
do $postflight$
declare
  v_rows integer;
  v_detail text;
  v_select_allowlist constant text[] := array[
    'public.students', 'public.assignments', 'public.balance_history',
    'public.weekly_mock_exams', 'public.mock_exam_results', 'public.student_items',
    'public.student_equipment', 'public.student_showcase', 'public.student_custom_titles',
    'public.student_achievements', 'public.season_results', 'public.student_week_results',
    'public.weekly_shield_uses', 'public.streak_shield_uses', 'public.league_memberships',
    'public.league_movements', 'public.league_season_awards', 'public.student_daily_quests',
    'public.student_daily_quest_options', 'public.shop_items', 'public.season_bundles',
    'public.seasons', 'public.life_quest_templates', 'public.weekly_plans',
    'public.weekly_plan_items'
  ];
  v_execute_allowlist constant text[] := array[
    'public.security_auth_mode()', 'public.jwt_app_role()', 'public.jwt_student_id()',
    'public.ensure_student_self(text,text)', 'public.submit_assignment_self(uuid,text)',
    'public.buy_item_self(text,text)', 'public.buy_streak_shield_self()',
    'public.equip_item_self(text,text)', 'public.set_showcase_self(smallint,text,text)',
    'public.submit_custom_title_self(text)', 'public.request_weekly_shield_self(uuid)',
    'public.cancel_weekly_shield_self(uuid)', 'public.get_daily_quests_self()',
    'public.replace_life_quest_self(smallint)', 'public.claim_life_quest_self(smallint)',
    'public.review_assignment_self(uuid,text,text)',
    'public.apply_penalty_self(uuid,integer,text)', 'public.get_review_queue_self(text)',
    'public.publish_weekly_plan_self(date,text,text,jsonb)',
    'public.cancel_weekly_plan_self(uuid)',
    'public.create_individual_assignment_self(bigint,text,text,text,integer)',
    'public.delete_individual_assignment_self(uuid)', 'public.close_season_self()',
    'public.record_weekly_mock_exam_self(bigint,date,integer)',
    'public.review_custom_title_self(bigint,text,text)',
    'public.admin_list_life_quest_templates()',
    'public.admin_upsert_life_quest_template_self(text,text,text,text,integer)',
    'public.admin_set_life_quest_template_active_self(text,boolean)',
    'public.claim_collection_bonus_self(bigint)', 'public.activate_due_assignments_self()',
    'public.get_economy_flags()', 'public.ensure_current_season()',
    'public.ensure_season_rotation()', 'public.get_student_league_snapshot_self()',
    'public.get_student_rank_title_self()', 'public.preview_league_close_self()',
    'public.create_parent_invite_self()', 'public.get_student_current_week(bigint)',
    'public.available_shield_quantity(bigint)', 'public.get_mock_exam_trajectory(bigint)',
    'public.is_first_submission_on_time(timestamp with time zone,timestamp with time zone,date)',
    'public.week_start_of(date)', 'public.weekly_reward_amount(integer)'
  ];
begin
  select count(*), min(auth_mode) into v_rows, v_detail
    from private.security_runtime_config;
  if v_rows <> 1 or v_detail is distinct from 'enforced' then
    raise exception 'T10-11 postflight: runtime rows %, mode %', v_rows, v_detail;
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
     or (select count(*) from pg_policies where schemaname = 'public') <> 29
     or exists (
       select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
        where n.nspname in ('public', 'private') and c.relkind in ('r', 'p')
          and not c.relrowsecurity
     ) then
    raise exception 'T10-11 postflight: object/policy/RLS inventory drift';
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
    raise exception 'T10-11 postflight: browser DML remains: %', v_detail;
  end if;
  if exists (
    select 1
      from information_schema.table_privileges
     where table_schema = 'public'
       and grantee in ('PUBLIC', 'anon', 'authenticated')
       and privilege_type <> 'SELECT'
  ) then
    raise exception 'T10-11 postflight: non-SELECT browser/PUBLIC table privilege remains';
  end if;

  select string_agg(c.relname, ', ' order by c.relname) into v_detail
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public'
     and case when c.relkind in ('r', 'p')
              then has_table_privilege('anon', c.oid, 'SELECT')
              else false end;
  if v_detail is not null then
    raise exception 'T10-11 postflight: anon table reads remain: %', v_detail;
  end if;

  select string_agg(format('%I.%I', n.nspname, c.relname), ', ' order by c.relname)
    into v_detail
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public'
     and case when c.relkind in ('r', 'p')
              then has_table_privilege('authenticated', c.oid, 'SELECT')
              else false end
     and not (format('%I.%I', n.nspname, c.relname) = any(v_select_allowlist));
  if v_detail is not null then
    raise exception 'T10-11 postflight: authenticated SELECT outside allowlist: %', v_detail;
  end if;
  select string_agg(x, ', ' order by x) into v_detail
    from unnest(v_select_allowlist) x
   where not has_table_privilege('authenticated', to_regclass(x), 'SELECT');
  if v_detail is not null then
    raise exception 'T10-11 postflight: authenticated SELECT missing: %', v_detail;
  end if;

  select string_agg(p.oid::regprocedure::text, ', ' order by p.oid::regprocedure::text)
    into v_detail
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and has_function_privilege('anon', p.oid, 'EXECUTE')
     and p.oid <> 'public.security_auth_mode()'::regprocedure;
  if v_detail is not null
     or not has_function_privilege('anon', 'public.security_auth_mode()'::regprocedure, 'EXECUTE') then
    raise exception 'T10-11 postflight: anon RPC surface drift: %', coalesce(v_detail, '<mode missing>');
  end if;

  select string_agg(p.oid::regprocedure::text, ', ' order by p.oid::regprocedure::text)
    into v_detail
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and has_function_privilege('authenticated', p.oid, 'EXECUTE')
     and not (p.oid = any (
       select to_regprocedure(x) from unnest(v_execute_allowlist) x
     ));
  if v_detail is not null then
    raise exception 'T10-11 postflight: authenticated EXECUTE outside allowlist: %', v_detail;
  end if;
  select string_agg(x, ', ' order by x) into v_detail
    from unnest(v_execute_allowlist) x
   where not has_function_privilege('authenticated', to_regprocedure(x), 'EXECUTE');
  if v_detail is not null then
    raise exception 'T10-11 postflight: authenticated EXECUTE missing: %', v_detail;
  end if;

  select string_agg(c.relname, ', ' order by c.relname) into v_detail
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public'
     and case when c.relkind = 'S' then
       has_sequence_privilege('anon', c.oid, 'USAGE')
       or has_sequence_privilege('authenticated', c.oid, 'USAGE')
       or has_sequence_privilege('anon', c.oid, 'SELECT')
       or has_sequence_privilege('authenticated', c.oid, 'SELECT')
     else false end;
  if v_detail is not null then
    raise exception 'T10-11 postflight: browser sequence grants remain: %', v_detail;
  end if;

  if exists (
    select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public'
       and case when c.relkind in ('r', 'p') then
         not has_table_privilege('service_role', c.oid, 'SELECT')
         or not has_table_privilege('service_role', c.oid, 'INSERT')
         or not has_table_privilege('service_role', c.oid, 'UPDATE')
         or not has_table_privilege('service_role', c.oid, 'DELETE')
       else false end
  ) or exists (
    select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public'
       and case when c.relkind = 'S'
                then not has_sequence_privilege('service_role', c.oid, 'USAGE')
                else false end
  ) or exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and not has_function_privilege('service_role', p.oid, 'EXECUTE')
  ) then
    raise exception 'T10-11 postflight: service_role current-object grants incomplete';
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
    raise exception 'T10-11 postflight: browser global/public default privilege remains';
  end if;
  if (
    select count(distinct d.defaclobjtype)
      from pg_default_acl d
      cross join lateral aclexplode(coalesce(d.defaclacl, acldefault(d.defaclobjtype, d.defaclrole))) a
      join pg_roles r on r.oid = a.grantee
     where pg_get_userbyid(d.defaclrole) = 'postgres'
       and d.defaclnamespace = 'public'::regnamespace
       and d.defaclobjtype in ('r', 'S', 'f')
       and r.rolname = 'service_role'
  ) <> 3 then
    raise exception 'T10-11 postflight: service_role default privileges incomplete';
  end if;

  if to_regnamespace('legacy_import') is not null
     and (has_schema_privilege('anon', 'legacy_import', 'USAGE')
       or has_schema_privilege('authenticated', 'legacy_import', 'USAGE')) then
    raise exception 'T10-11 postflight: legacy_import schema exposed';
  end if;

  raise notice 'PASS B2-T11 release postflight: auth_mode=enforced, browser allowlists exact';
end
$postflight$;

commit;
