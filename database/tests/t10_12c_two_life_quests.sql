-- T10-12C: два life-квеста, общий лимит замен, 3+3+2, серия без выплаты.
-- Выполняется владельцем после migration 048. Все synthetic данные откатываются.

begin;

do $test$
declare
  v_student bigint := 995012001;
  v_today   date := (now() at time zone 'Europe/Moscow')::date;
  v_state   json;
  v_before  integer;
  v_after   integer;
  v_failed  boolean;
  v_day     date;
begin
  insert into public.students
    (telegram_id, name, telegram_username, huikons, rating, lives, current_streak)
  values (v_student, 'T10-12C synthetic', 't10_12c_synthetic', 0, 0, 3, 0);

  update public.economy_config
     set stage4_started_at = now() - interval '1 minute',
         stage4_generation_enabled = true
   where id;

  v_state := public.get_daily_quests(v_student);
  if v_state->>'life_1' is null
     or v_state->>'life_2' is null
     or v_state->'life_1'->>'template_code' = v_state->'life_2'->>'template_code' then
    raise exception 'FAIL T10-12C: два разных life-слота не сгенерированы: %', v_state;
  end if;
  if (v_state->>'replacements_left')::integer <> 2 then
    raise exception 'FAIL T10-12C: стартовый лимит замен не равен 2: %', v_state;
  end if;

  v_state := public.replace_life_quest(v_student, 1::smallint);
  v_state := public.replace_life_quest(v_student, 2::smallint);
  if (v_state->>'replacements_left')::integer <> 0 then
    raise exception 'FAIL T10-12C: общий лимит замен не исчерпан: %', v_state;
  end if;

  v_failed := false;
  begin
    perform public.replace_life_quest(v_student, 1::smallint);
  exception when others then
    v_failed := position('лимит замен' in sqlerrm) > 0;
  end;
  if not v_failed then
    raise exception 'FAIL T10-12C: третья замена не отклонена';
  end if;

  select huikons into v_before from public.students where telegram_id = v_student;
  v_state := public.claim_life_quest(v_student, 1::smallint);
  perform public.claim_life_quest(v_student, 1::smallint);
  select huikons into v_after from public.students where telegram_id = v_student;
  if v_after - v_before <> 3
     or (select count(*) from public.daily_quest_reward_log
          where student_id = v_student and quest_date = v_today
            and reward_kind = 'life_1') <> 1 then
    raise exception 'FAIL T10-12C: slot 1 не pay-once';
  end if;

  v_state := public.claim_life_quest(v_student, 2::smallint);
  select huikons into v_after from public.students where telegram_id = v_student;
  if v_after - v_before <> 8
     or (select count(*) from public.daily_quest_reward_log
          where student_id = v_student and quest_date = v_today
            and reward_kind = 'life_2') <> 1
     or (select count(*) from public.daily_quest_reward_log
          where student_id = v_student and quest_date = v_today
            and reward_kind = 'combo') <> 1
     or v_state->>'combo_status' <> 'completed'
     or (v_state->>'streak_current')::integer <> 1 then
    raise exception 'FAIL T10-12C: итог дня не равен 3+3+2 или серия не стартовала: %', v_state;
  end if;

  -- Добавляем шесть предыдущих закрытых дней. Achievement-функция должна дать badge,
  -- но не менять баланс.
  for v_day in
    select generate_series(v_today - 6, v_today - 1, interval '1 day')::date
  loop
    insert into public.student_daily_quests
      (student_id, quest_date, life_template_code, life_template_code_2)
    select v_student, v_day, a.template_code, b.template_code
      from (
        select template_code from public.life_quest_templates
         where active order by template_code limit 1
      ) a
      cross join (
        select template_code from public.life_quest_templates
         where active order by template_code offset 1 limit 1
      ) b;

    insert into public.daily_quest_reward_log
      (student_id, quest_date, reward_kind, bubliks)
    values
      (v_student, v_day, 'life_1', 3),
      (v_student, v_day, 'life_2', 3),
      (v_student, v_day, 'combo', 2);
  end loop;

  select huikons into v_before from public.students where telegram_id = v_student;
  perform public.grant_life_achievements(v_student);
  select huikons into v_after from public.students where telegram_id = v_student;
  v_state := public.daily_quest_state(v_student, v_today);

  if (v_state->>'streak_current')::integer <> 7
     or not exists (
       select 1 from public.student_achievements
        where student_id = v_student and achievement_code = 'life_streak_7'
     )
     or v_after <> v_before then
    raise exception
      'FAIL T10-12C: серия/achievement должны быть 7 и без выплаты: state=% balance %->%',
      v_state, v_before, v_after;
  end if;

  if to_regprocedure('public.claim_life_quest_self(smallint)') is null
     or to_regprocedure('public.replace_life_quest_self(smallint)') is null
     or to_regprocedure('public.claim_life_quest_self()') is not null
     or to_regprocedure('public.replace_life_quest_self()') is not null then
    raise exception 'FAIL T10-12C: exact self-RPC signatures';
  end if;

  raise notice 'PASS T10-12C: two life quests, shared replacements, 3+3+2, streak without payout';
end
$test$;

select 'PASS T10-12C; transaction will be rolled back' as summary;

rollback;
