-- =============================================================================
-- 029_stage4_life_achievements.sql — Достижения жизненных привычек без эмиссии бубликов
-- (Bot 2.0, Stage 4, карточка U06; SPEC_STAGE4.md §6; ECONOMY_V2.md §10.4)
--
-- Зачем: шесть pay-zero достижений по серверной life/math-истории. Они НЕ начисляют бублики
-- (не увеличивают бюджеты 505/675, §10.4) — награда только badge/условие доступа к будущей
-- косметике. Жизненные действия при этом не раскрываются teacher/parent: это личные бейджи на
-- профиле ученика, и данная миграция teacher/parent-код не трогает.
--
-- Коды (стабильные): life_first, life_7, life_30, life_100, life_variety_5, life_streak_7.
--
-- Источник истины — только U02-ledger:
--   * количество оплаченных life = count(daily_quest_reward_log where reward_kind='life');
--   * «пять разных» = count(distinct student_daily_quests.life_template_code) по датам с
--     оплаченным life. Берётся ИТОГОВЫЙ сохранённый шаблон дня (после всех замен) — замена
--     прогрессу не мешает (§6);
--   * «семь подряд» = максимальный run из подряд идущих календарных MSK-дат, где за дату есть
--     ОБА ledger-kind: math И life (combo и щиты в расчёте не участвуют — combo отфильтрован,
--     щиты в этом ledger вообще не пишутся).
--
-- Ретроактив до Stage 4 start структурно невозможен: daily_quest_reward_log наполняется только
-- settlement'ом (life — claim при активной генерации, math — settle с timestamp-гейтом старта),
-- поэтому «догадок» про доквестовую активность здесь нет.
--
-- Pay-zero: используется СУЩЕСТВУЮЩИЙ grant_achievement_server(id, code, reward) — он вызывает
-- add_huikons только при reward > 0, поэтому с reward=0 идемпотентно вставляет достижение и НЕ
-- трогает баланс/balance_history. Отдельный helper не нужен и фиктивная сумма не передаётся.
--
-- Идемпотентность: grant_life_achievements пересчитывает всё из текущего ledger и выдаёт через
-- ON CONFLICT DO NOTHING — повторный claim/settlement дубля не создаёт. Вызывается в двух местах
-- (хвост claim_life_quest и settle_daily_math), т.к. math может быть оплачен позже life (поздняя
-- приёмка) и завершить math+life-streak уже после того, как life был подтверждён.
-- =============================================================================

-- --- 1. Идемпотентная выдача шести life-достижений (pay-zero) --------------------------------
create or replace function public.grant_life_achievements(p_student_id bigint)
 returns void
 language plpgsql
as $function$
declare
  v_life_count integer;
  v_variety    integer;
  v_max_streak integer;
begin
  select count(*) into v_life_count
    from public.daily_quest_reward_log
   where student_id = p_student_id and reward_kind = 'life';

  if v_life_count >= 1   then perform public.grant_achievement_server(p_student_id, 'life_first', 0); end if;
  if v_life_count >= 7   then perform public.grant_achievement_server(p_student_id, 'life_7',     0); end if;
  if v_life_count >= 30  then perform public.grant_achievement_server(p_student_id, 'life_30',    0); end if;
  if v_life_count >= 100 then perform public.grant_achievement_server(p_student_id, 'life_100',   0); end if;

  -- Пять разных фактически подтверждённых (итоговых) шаблонов.
  select count(distinct q.life_template_code) into v_variety
    from public.daily_quest_reward_log r
    join public.student_daily_quests q
      on q.student_id = r.student_id and q.quest_date = r.quest_date
   where r.student_id = p_student_id and r.reward_kind = 'life'
     and q.life_template_code is not null;

  if v_variety >= 5 then perform public.grant_achievement_server(p_student_id, 'life_variety_5', 0); end if;

  -- Семь календарных MSK-дат подряд с оплаченными ОБОИМИ kind (math+life).
  -- gaps-and-islands: у подряд идущих дат (quest_date - row_number()) одинаков.
  with both_days as (
    select quest_date
      from public.daily_quest_reward_log
     where student_id = p_student_id and reward_kind in ('math', 'life')
     group by quest_date
    having count(distinct reward_kind) = 2
  ),
  grouped as (
    select quest_date - (row_number() over (order by quest_date))::int as grp
      from both_days
  )
  select coalesce(max(cnt), 0) into v_max_streak
    from (select count(*) as cnt from grouped group by grp) runs;

  if v_max_streak >= 7 then perform public.grant_achievement_server(p_student_id, 'life_streak_7', 0); end if;
end;
$function$;

-- --- 2. claim_life_quest: выдать life-достижения после подтверждения (хвост) -----------------
-- Единственное отличие от U02C — вызов grant_life_achievements под тем же FOR UPDATE. Random/
-- replace/выплата не меняются.
create or replace function public.claim_life_quest(p_student_id bigint)
 returns json
 language plpgsql
as $function$
declare
  v_today date := (now() at time zone 'Europe/Moscow')::date;
  v_id    uuid;
  v_life  text;
  v_paid  integer;
begin
  if not public.stage4_generation_active() then
    raise exception 'Ежедневные квесты ещё не запущены';
  end if;

  select id, life_template_code
    into v_id, v_life
    from public.student_daily_quests
   where student_id = p_student_id and quest_date = v_today
   for update;

  if not found or v_life is null then
    raise exception 'Сегодняшний жизненный челлендж не сгенерирован';
  end if;

  insert into public.daily_quest_reward_log (student_id, quest_date, reward_kind, bubliks)
    values (p_student_id, v_today, 'life', 3)
    on conflict (student_id, quest_date, reward_kind) do nothing;
  get diagnostics v_paid = row_count;
  if v_paid = 1 then
    perform public.add_huikons(p_student_id, 3, 'daily_quest_life');
  end if;

  -- U02C: combo, если math за сегодня уже оплачен (сериализовано FOR UPDATE выше).
  perform public.settle_daily_combo(p_student_id, v_today);

  -- U06: pay-zero достижения жизненных привычек (идемпотентно).
  perform public.grant_life_achievements(p_student_id);

  return public.daily_quest_state(p_student_id, v_today);
end;
$function$;

-- --- 3. settle_daily_math: выдать life-достижения после math settlement (хвост) --------------
-- Единственное отличие от U02D — вызов grant_life_achievements после combo: поздняя приёмка
-- math может завершить math+life-streak уже после подтверждения life. Eligibility/гейт/выплаты
-- не меняются.
create or replace function public.settle_daily_math(p_assignment_id uuid)
 returns void
 language plpgsql
as $function$
declare
  a        public.assignments%rowtype;
  v_qdate  date;
  v_qid    uuid;
  v_target uuid;
  v_paid   integer;
begin
  select * into a from public.assignments where id = p_assignment_id;
  if not found or a.type <> 'daily' then
    return;
  end if;

  if not (a.status = 'checked' and a.approval_status = 'approved'
          and public.is_first_submission_on_time(a.first_submitted_at, a.submitted_at, a.scheduled_date)
          and (coalesce(a.revision_count, 0) = 0
               or (a.revision_deadline_at is not null
                   and a.submitted_at is not null
                   and a.submitted_at <= a.revision_deadline_at))) then
    return;
  end if;

  v_qdate := a.scheduled_date;

  -- U02D: точный timestamp-гейт cutover по моменту ПЕРВОГО действия (не по календарной дате).
  if not public.stage4_settlement_active(coalesce(a.first_submitted_at, a.submitted_at)) then
    return;
  end if;

  perform public.ensure_daily_quest(a.student_id, v_qdate, false);

  select id, daily_assignment_id
    into v_qid, v_target
    from public.student_daily_quests
   where student_id = a.student_id and quest_date = v_qdate
   for update;

  if v_target is null then
    update public.student_daily_quests
       set daily_assignment_id = a.id, updated_at = now()
     where id = v_qid;
    v_target := a.id;
  end if;

  if v_target <> a.id then
    return;
  end if;

  insert into public.daily_quest_reward_log (student_id, quest_date, reward_kind, bubliks)
    values (a.student_id, v_qdate, 'math', 3)
    on conflict (student_id, quest_date, reward_kind) do nothing;
  get diagnostics v_paid = row_count;
  if v_paid = 1 then
    perform public.add_huikons(a.student_id, 3, 'daily_quest_math');
  end if;

  perform public.settle_daily_combo(a.student_id, v_qdate);

  -- U06: pay-zero достижения жизненных привычек (идемпотентно; поздний math может закрыть streak).
  perform public.grant_life_achievements(a.student_id);
end;
$function$;

-- =============================================================================
-- ROLLBACK (только функции; выданные pay-zero достижения — badge без баланса — можно оставить):
--   восстановить claim_life_quest (версия U02C) из 023_stage4_math_combo_settlement.sql;
--   восстановить settle_daily_math (версия U02D) из 024_stage4_exact_cutover_gate.sql;
--   drop function if exists public.grant_life_achievements(bigint);
--   -- по желанию: delete from public.student_achievements
--   --   where achievement_code in ('life_first','life_7','life_30','life_100','life_variety_5','life_streak_7');
-- =============================================================================
