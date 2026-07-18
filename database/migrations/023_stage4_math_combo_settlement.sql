-- =============================================================================
-- 023_stage4_math_combo_settlement.sql — Math settlement и combo без срока проверки учителем
-- (Bot 2.0, Stage 4, карточка U02C; SPEC_STAGE4.md §§2, 5, 8)
--
-- Зачем: подключает принятие сегодняшней daily к pay-once math=3 и автоматически доплачивает
-- combo=2 после обоих слотов, не наказывая ученика за позднюю проверку учителя. Только функции;
-- таблиц/колонок/индексов не добавляет. Achievements/UI/teacher/shop/cron — отдельные карточки.
--
-- Ключевые правила:
--   * Math eligibility = сохранённый daily_assignment_id принят И первая отправка была в
--     quest_date по МСК И (возврата не было ИЛИ финальное исправление уложилось в
--     revision_deadline_at). Дословно повторяет каноническое выражение недельного расчёта.
--   * Время teacher approval settlement не ограничивает: pending math может быть оплачен через
--     недели. Никакого expiry review и нового deadline здесь нет.
--   * Гейт выплат — stage4_settlement_active(quest_date), НЕ текущий generation-флаг:
--       - stage4_started_at IS NULL (дормант / обычный dev) => выплат нет вообще;
--       - после cutover => платит за quest_date >= дата старта (не задним числом, §8);
--       - generation можно отключить (rollback), но settlement уже созданных наборов идёт.
--   * Combo pay-once вставляется общим helper при наличии обоих ledger-kind. И math settlement,
--     и life claim держат FOR UPDATE дневной строки перед ledger+combo => конкурентные
--     approval+claim сериализуются и дают ровно один combo.
--
-- Расширяет существующие функции минимально: record_approved_assignment (settle для daily),
-- claim_life_quest (вызов combo helper), get_daily_quests (резервный settle принятого target).
-- Остальная логика этих функций не меняется.
-- =============================================================================

-- --- 1. Гейт settlement по неизменяемому времени старта (не по generation-флагу) -------------
create or replace function public.stage4_settlement_active(p_quest_date date)
 returns boolean
 language sql
 stable
as $function$
  select ec.stage4_started_at is not null
     and p_quest_date >= (ec.stage4_started_at at time zone 'Europe/Moscow')::date
    from public.economy_config ec
   where ec.id;
$function$;

-- --- 2. Combo helper: pay-once 2 бублика при наличии math и life за дату --------------------
-- Идемпотентно по unique(student_id, quest_date, 'combo'); add_huikons только при вставке.
-- Вызывается под FOR UPDATE дневной строки (из settle_daily_math и claim_life_quest), поэтому
-- конкурентные math+life сериализуются и combo начисляется ровно один раз.
create or replace function public.settle_daily_combo(p_student_id bigint, p_quest_date date)
 returns void
 language plpgsql
as $function$
declare
  v_paid integer;
begin
  if exists (select 1 from public.daily_quest_reward_log
              where student_id = p_student_id and quest_date = p_quest_date and reward_kind = 'math')
     and exists (select 1 from public.daily_quest_reward_log
                  where student_id = p_student_id and quest_date = p_quest_date and reward_kind = 'life') then
    insert into public.daily_quest_reward_log (student_id, quest_date, reward_kind, bubliks)
      values (p_student_id, p_quest_date, 'combo', 2)
      on conflict (student_id, quest_date, reward_kind) do nothing;
    get diagnostics v_paid = row_count;
    if v_paid = 1 then
      perform public.add_huikons(p_student_id, 2, 'daily_quest_combo');
    end if;
  end if;
end;
$function$;

-- --- 3. Internal math settlement сегодняшней/прошлой принятой daily -------------------------
-- Платит только по серверным полям assignment. Клиент никогда не сообщает о выполнении math.
-- Безопасно вызывать многократно (record_approved_assignment и резервно get_daily_quests):
-- при неподходящей/неоплачиваемой работе просто выходит, ничего не начисляя.
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

  -- eligibility: принято + первая отправка вовремя + (без возврата или исправление в срок)
  if not (a.status = 'checked' and a.approval_status = 'approved'
          and public.is_first_submission_on_time(a.first_submitted_at, a.submitted_at, a.scheduled_date)
          and (coalesce(a.revision_count, 0) = 0
               or (a.revision_deadline_at is not null
                   and a.submitted_at is not null
                   and a.submitted_at <= a.revision_deadline_at))) then
    return;
  end if;

  v_qdate := a.scheduled_date;
  if not public.stage4_settlement_active(v_qdate) then
    return;  -- до cutover / вне окна старта — не платим (и не создаём набор)
  end if;

  -- Гарантируем дневной набор для даты первой отправки; life задним числом НЕ генерируем.
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
    return;  -- целевой daily набора — другая строка; эта работа не платит math
  end if;

  insert into public.daily_quest_reward_log (student_id, quest_date, reward_kind, bubliks)
    values (a.student_id, v_qdate, 'math', 3)
    on conflict (student_id, quest_date, reward_kind) do nothing;
  get diagnostics v_paid = row_count;
  if v_paid = 1 then
    perform public.add_huikons(a.student_id, 3, 'daily_quest_math');
  end if;

  perform public.settle_daily_combo(a.student_id, v_qdate);
end;
$function$;

-- --- 4. Расширение claim_life_quest: после life-выплаты доплатить combo ---------------------
-- Единственное отличие от U02B — вызов settle_daily_combo под тем же FOR UPDATE. Random/replace
-- не переписываются.
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

  return public.daily_quest_state(p_student_id, v_today);
end;
$function$;

-- --- 5. Расширение get_daily_quests: резервный settlement уже принятого target -------------
-- Единственное отличие от U02B — backstop-вызов settle_daily_math для привязанного assignment.
-- Работает и при disabled generation: pending math/combo не блокируются отключением генерации.
create or replace function public.get_daily_quests(p_student_id bigint)
 returns json
 language plpgsql
as $function$
declare
  v_today  date := (now() at time zone 'Europe/Moscow')::date;
  v_target uuid;
begin
  if public.stage4_generation_active() then
    perform public.ensure_daily_quest(p_student_id, v_today, true);
  end if;

  select daily_assignment_id into v_target
    from public.student_daily_quests
   where student_id = p_student_id and quest_date = v_today;
  if v_target is not null then
    perform public.settle_daily_math(v_target);
  end if;

  return public.daily_quest_state(p_student_id, v_today);
end;
$function$;

-- --- 6. Расширение record_approved_assignment: settle math для принятой daily ---------------
-- Идентична фактической (W11) версии; добавлен ТОЛЬКО хвостовой вызов settle_daily_math для
-- type='daily'. Начисления weekly/individual, season points и достижения не изменены.
create or replace function public.record_approved_assignment(p_assignment_id uuid)
 returns json
 language plpgsql
as $function$
declare
  v_asn       public.assignments%rowtype;
  v_pts       integer;
  v_reason    text;
  v_run       integer := 0;
  v_clean_10  boolean := false;
  v_bonus     integer;
  v_paid      integer;
  r           record;
begin
  select * into v_asn from public.assignments where id = p_assignment_id;
  if not found then
    raise exception 'Задание % не найдено', p_assignment_id;
  end if;
  if not (v_asn.status = 'checked' and v_asn.approval_status = 'approved') then
    raise exception 'Задание % не принято — начислять нечего', p_assignment_id;
  end if;

  v_pts := case v_asn.type when 'daily' then 10 when 'weekly' then 40 when 'individual' then 30 else 0 end;
  if v_pts > 0 then
    v_reason := 'approve_' || v_asn.type;
    perform public.award_season_points(
      v_asn.student_id, v_pts, v_reason, 'season_approve_' || v_asn.id::text);
  end if;

  perform public.grant_achievement_server(v_asn.student_id, 'first_step', 10);

  for r in
    select coalesce(revision_count, 0) = 0 as clean
      from public.assignments
     where student_id = v_asn.student_id
       and status = 'checked' and approval_status = 'approved'
     order by checked_at, id
  loop
    if r.clean then
      v_run := v_run + 1;
      if v_run >= 10 then v_clean_10 := true; end if;
    else
      v_run := 0;
    end if;
  end loop;
  if v_clean_10 then
    perform public.grant_achievement_server(v_asn.student_id, 'clean_10', 25);
  end if;

  -- Бублики за принятое weekly/individual (ECONOMY §4), идемпотентно по assignment (W11).
  if v_asn.type in ('weekly', 'individual') then
    v_bonus := case v_asn.type when 'weekly' then 20 else 15 end;
    insert into public.assignment_reward_log (assignment_id, student_id, reward_amount)
      values (v_asn.id, v_asn.student_id, v_bonus)
      on conflict (assignment_id) do nothing;
    get diagnostics v_paid = row_count;
    if v_paid = 1 then
      perform public.add_huikons(v_asn.student_id, v_bonus, v_asn.type || '_approved');
    end if;
  end if;

  -- U02C: math settlement принятой ежедневки (pay-once, время проверки не ограничивает).
  if v_asn.type = 'daily' then
    perform public.settle_daily_math(v_asn.id);
  end if;

  return json_build_object('student_id', v_asn.student_id, 'type', v_asn.type, 'season_points', v_pts);
end;
$function$;

-- =============================================================================
-- ROLLBACK (только функции; балансы/ledger не отзываются — dev-тест сам чистит синтетику и
-- возвращает stage4_started_at=NULL):
--
--   -- восстановить тела из предыдущих миграций:
--   --   record_approved_assignment — из 017_weekly_economy_cutover.sql (версия W11, без daily settle);
--   --   claim_life_quest, get_daily_quests — из 022_stage4_life_quest_rpc.sql (версии U02B);
--   drop function if exists public.settle_daily_math(uuid);
--   drop function if exists public.settle_daily_combo(bigint, date);
--   drop function if exists public.stage4_settlement_active(date);
-- =============================================================================
