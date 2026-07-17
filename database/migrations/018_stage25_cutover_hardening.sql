-- =============================================================================
-- 018_stage25_cutover_hardening.sql — устранение дефектов cutover перед firing
-- (Bot 2.0, Stage 2.5, карточка W11; SPEC_STAGE2_5.md §§8, 13-14)
--
-- Зачем: закрыть три дефекта, найденных при ревизии W09/W10, до включения недельной
-- экономики. Firing остаётся ручным: миграция НЕ устанавливает economy_config.cutover_at и
-- НЕ создаёт Supabase Cron. После применения — dormant + искусственный active тест с rollback.
--
-- --- ИСПРАВЛЕНИЯ (карточка W11) ------------------------------------------------
--
--   1. ПОЛНЫЙ SEASON LEDGER. record_weekly_mock_exam писал сезонную дельту напрямую через
--      add_season_points — мимо season_points_log, из-за чего tie-break сезона не видел
--      момент, когда пробник изменил счёт. Теперь ненулевая компенсирующая дельта идёт через
--      award_season_points (событие ledger). Повтор того же результата даёт дельту 0 и не
--      создаёт событие (award_season_points no-op на 0). close_season определяет «момент
--      достижения финального score» по последнему НЕНУЛЕВОМУ событию ledger (amount <> 0),
--      включая отрицательную корректировку пробника при edit.
--
--   2. ИДЕМПОТЕНТНЫЕ 20/15 БУБЛИКОВ. Выплата за принятое weekly/individual перенесена с клиента
--      (W10) внутрь record_approved_assignment и защищена ledger'ом assignment_reward_log с
--      уникальностью по assignment: повторный/конкурентный вызов не платит второй раз. Daily
--      отдельную per-approval выплату не получает (её тир приходит при финализации недели).
--
--   3. Клиент (teacher.html submitReview) правится ОТДЕЛЬНО, после применения этой миграции:
--      серверная часть (record_approved_assignment платит 20/15) должна существовать раньше,
--      чем клиент перестанет платить их сам, иначе в окне между деплоями выплата потерялась бы.
--
-- Идемпотентность record_approved_assignment (её теперь зовут на КАЖДОЕ post-cutover «Принять»,
-- включая уже принятую работу — восстановление награды после сетевого сбоя):
--   season points — event_key 'season_approve_<id>' (одно начисление за всё время);
--   first_step / clean_10 — уникальность student_achievements;
--   20/15 — уникальность assignment_reward_log(assignment_id).
-- Конкурентный двойной вызов сериализуется этими уникальными индексами: второй видит конфликт
-- и не платит. Явная блокировка строки ученика не нужна.
--
-- Повторный прогон миграции безопасен (create ... if not exists / or replace). RLS у новой
-- таблицы выключен, как у всех таблиц проекта (T10).
-- =============================================================================

-- --- 1. Ledger выплаты за принятое weekly/individual (идемпотентность 20/15) -----
-- on delete cascade к assignments — как у weekly_shield_uses (012): если строка задания
-- удаляется, её reward-лог уходит вместе; уже начисленные бублики остаются у ученика.
create table if not exists public.assignment_reward_log (
  id            uuid         primary key default gen_random_uuid(),
  assignment_id uuid         not null references public.assignments (id) on delete cascade,
  student_id    bigint       not null references public.students (telegram_id),
  reward_amount integer      not null,
  paid_at       timestamptz  not null default now(),
  unique (assignment_id)
);
alter table public.assignment_reward_log disable row level security;

-- --- 2. award_season_points: no-op на нулевой дельте (исправление 1) -----------
-- Нулевая дельта не создаёт событие ledger (повтор того же пробника не «набирает очки»).
-- Остальная семантика без изменений: событийный лог + идемпотентность по event_key.
create or replace function public.award_season_points(
  p_student_id bigint, p_amount integer, p_reason text, p_event_key text default null)
 returns integer
 language plpgsql
as $function$
declare
  v_season   bigint;
  v_inserted integer;
  v_rating   integer;
begin
  -- Нулевая дельта: ничего не пишем и не начисляем (карточка W11, исправление 1).
  if p_amount = 0 then
    select rating into v_rating from public.students where telegram_id = p_student_id;
    return v_rating;
  end if;

  select id into v_season from public.seasons where end_date is null order by id desc limit 1;

  insert into public.season_points_log (season_id, student_id, amount, reason, event_key)
    values (v_season, p_student_id, p_amount, p_reason, p_event_key)
    on conflict (event_key) where event_key is not null do nothing;
  get diagnostics v_inserted = row_count;

  if v_inserted = 0 and p_event_key is not null then
    select rating into v_rating from public.students where telegram_id = p_student_id;
    return v_rating;
  end if;

  return public.add_season_points(p_student_id, p_amount);
end;
$function$;

-- --- 3. record_approved_assignment: + идемпотентные 20/15 (исправление 2) ------
-- Season points 10/40/30 + first_step + clean_10 (как в W09) И бублики за принятое
-- weekly/individual (20/15) одним атомарным идемпотентным вызовом. Daily бублики за приём не
-- получает. Функцию теперь можно звать на любое «Принять», в т.ч. по уже принятой работе.
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

  -- Season points по типу принятой работы (ECONOMY §3.2). Пробники сюда не попадают.
  v_pts := case v_asn.type when 'daily' then 10 when 'weekly' then 40 when 'individual' then 30 else 0 end;
  if v_pts > 0 then
    v_reason := 'approve_' || v_asn.type;
    perform public.award_season_points(
      v_asn.student_id, v_pts, v_reason, 'season_approve_' || v_asn.id::text);
  end if;

  -- first_step — первая принятая работа любого типа (ECONOMY §10.1), идемпотентно.
  perform public.grant_achievement_server(v_asn.student_id, 'first_step', 10);

  -- clean_10 — 10 принятых работ подряд без возврата (revision_count>0 обрывает серию).
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

  return json_build_object('student_id', v_asn.student_id, 'type', v_asn.type, 'season_points', v_pts);
end;
$function$;

-- --- 4. record_weekly_mock_exam: сезонная дельта через ledger (исправление 1) --
-- Единственное изменение относительно 016 — строка начисления сезонной дельты: вместо
-- add_season_points теперь award_season_points (событие ledger, reason 'mock_exam_season',
-- event_key null — каждая ненулевая компенсирующая дельта это отдельное легитимное событие).
-- Атомарность, сериализация по строке ученика, base/record ledger, зеркало и
-- season_points_awarded без изменений. Дельта 0 (повтор того же результата) события не создаёт.
CREATE OR REPLACE FUNCTION public.record_weekly_mock_exam(
  p_student_id bigint,
  p_week_start date,
  p_score      integer
)
 RETURNS json
 LANGUAGE plpgsql
AS $function$
declare
  v_prev_score   integer;
  v_prev_max     integer;
  v_growth       integer;
  v_season_target integer;
  v_season_prev  integer;
  v_season_delta integer;
  v_is_record    boolean;
  v_record_this_month boolean;
  v_base_awarded boolean := false;
  v_record_awarded boolean := false;
  v_now          timestamptz := now();
  v_month_start  date := date_trunc('month', (v_now at time zone 'Europe/Moscow'))::date;
  v_exam_name    text;
begin
  if p_week_start is null or extract(isodow from p_week_start) <> 1 then
    raise exception 'week_start % — не понедельник', p_week_start;
  end if;
  if p_score is null or p_score < 0 or p_score > 100 then
    raise exception 'score должен быть целым от 0 до 100';
  end if;

  perform 1 from public.students where telegram_id = p_student_id for update;
  if not found then
    raise exception 'Ученик % не найден', p_student_id;
  end if;

  select score into v_prev_score
    from public.weekly_mock_exams
    where student_id = p_student_id and week_start < p_week_start
    order by week_start desc
    limit 1;

  select max(score) into v_prev_max
    from public.weekly_mock_exams
    where student_id = p_student_id and week_start < p_week_start;

  v_growth := least(greatest(p_score - coalesce(v_prev_score, p_score), 0), 20);
  v_season_target := 50 + v_growth;

  select season_points_awarded into v_season_prev
    from public.weekly_mock_exams
    where student_id = p_student_id and week_start = p_week_start
    for update;

  if not found then
    insert into public.weekly_mock_exams (student_id, week_start, score, season_points_awarded)
      values (p_student_id, p_week_start, p_score, v_season_target);
    v_season_prev := 0;
  else
    update public.weekly_mock_exams
      set score = p_score,
          season_points_awarded = v_season_target,
          updated_at = v_now
      where student_id = p_student_id and week_start = p_week_start;
  end if;

  -- Компенсирующая дельта до целевого значения — теперь через ledger (W11, исправление 1).
  -- award_season_points сам no-op при дельте 0, поэтому повтор того же результата события не даёт.
  v_season_delta := v_season_target - v_season_prev;
  if v_season_delta <> 0 then
    perform public.award_season_points(p_student_id, v_season_delta, 'mock_exam_season', null);
  end if;

  v_exam_name := 'Недельный пробник ' || to_char(p_week_start, 'DD.MM.YYYY');
  insert into public.mock_exam_results (student_id, exam_name, score, exam_date, updated_at)
    values (p_student_id, v_exam_name, p_score::text, p_week_start, v_now)
    on conflict (student_id, exam_name)
    do update set score = excluded.score, exam_date = excluded.exam_date, updated_at = v_now;

  insert into public.mock_exam_reward_log (student_id, week_start, reward_kind, bubliks)
    values (p_student_id, p_week_start, 'base', 20)
    on conflict (student_id, week_start, reward_kind) do nothing;
  if found then
    perform public.add_huikons(p_student_id, 20, 'mock_exam_weekly');
    v_base_awarded := true;
  end if;

  v_is_record := v_prev_max is not null and p_score >= v_prev_max + 3;
  if v_is_record then
    select exists (
      select 1 from public.mock_exam_reward_log
        where student_id = p_student_id and reward_kind = 'record'
          and (awarded_at at time zone 'Europe/Moscow')::date >= v_month_start
          and (awarded_at at time zone 'Europe/Moscow')::date < (v_month_start + interval '1 month')
    ) into v_record_this_month;

    if not v_record_this_month then
      insert into public.mock_exam_reward_log (student_id, week_start, reward_kind, bubliks)
        values (p_student_id, p_week_start, 'record', 30)
        on conflict (student_id, week_start, reward_kind) do nothing;
      if found then
        perform public.add_huikons(p_student_id, 30, 'mock_exam_record');
        v_record_awarded := true;
      end if;
    end if;
  end if;

  return json_build_object(
    'week_start', p_week_start,
    'score', p_score,
    'season_points_awarded', v_season_target,
    'season_points_delta', v_season_delta,
    'base_awarded', v_base_awarded,
    'record_eligible', v_is_record,
    'record_awarded', v_record_awarded
  );
end;
$function$;

-- --- 5. close_season: момент достижения счёта по последнему НЕНУЛЕВОМУ событию ---
-- Единственное изменение относительно v2 (017) — предикат last_scored: amount <> 0 вместо
-- amount > 0, чтобы отрицательная корректировка пробника тоже считалась моментом изменения
-- счёта (карточка W11, исправление 1). Остальной tie-break и фонд 190 без изменений.
create or replace function public.close_season()
 returns json
 language plpgsql
as $function$
declare
  v_season_id    bigint;
  v_start_date   date;
  v_start_ts     timestamptz;
  v_today        date := (now() at time zone 'Europe/Moscow')::date;
  v_archived     integer;
  v_awarded      integer := 0;
  v_reward       integer;
  r record;
begin
  select id, start_date into v_season_id, v_start_date
    from seasons
    where end_date is null
    order by id desc
    limit 1
    for update;

  if v_season_id is null then
    raise exception 'Нет открытого сезона';
  end if;

  if v_start_date >= v_today then
    raise exception 'Сезон №% открыт сегодня — закрывать можно не раньше следующего дня', v_season_id;
  end if;

  v_start_ts := (v_start_date::timestamp) at time zone 'Europe/Moscow';

  perform 1 from students for update;

  insert into season_results (season_id, student_id, points, place)
  select v_season_id, s.telegram_id, s.rating,
         row_number() over (
           order by s.rating desc,
                    coalesce(pen.cnt, 0) asc,
                    pts.last_scored asc nulls last,
                    s.telegram_id asc)
    from students s
    left join (
      select student_id, count(*) as cnt
        from balance_history
       where reason like 'penalty:%' and created_at >= v_start_ts
       group by student_id) pen on pen.student_id = s.telegram_id
    left join (
      select student_id, max(created_at) as last_scored
        from season_points_log
       where season_id = v_season_id and amount <> 0
       group by student_id) pts on pts.student_id = s.telegram_id;
  get diagnostics v_archived = row_count;

  for r in
    select student_id, place
      from season_results
      where season_id = v_season_id and place <= 3 and points > 0
      order by place
  loop
    v_reward := case r.place when 1 then 100 when 2 then 60 else 30 end;
    perform add_huikons(r.student_id, v_reward, 'season_place_' || r.place);
    v_awarded := v_awarded + 1;
  end loop;

  update students set rating = 0 where rating <> 0;

  update seasons set end_date = v_today where id = v_season_id;

  insert into seasons (start_date) values (v_today);

  return json_build_object(
    'season_id', v_season_id,
    'archived', v_archived,
    'awarded', v_awarded
  );
end;
$function$;

-- =============================================================================
-- ВНИМАНИЕ: firing здесь НЕ выполняется — cutover_at не устанавливается, cron не создаётся.
-- Отдельный короткий firing-блок (cutover_at = будущий понедельник + cron.schedule) даётся
-- пользователю и запускается только по отдельному подтверждению вместе с деплоем клиента.
-- =============================================================================
