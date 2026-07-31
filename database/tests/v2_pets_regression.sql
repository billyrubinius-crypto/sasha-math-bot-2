-- =============================================================================
-- database/tests/v2_pets_regression.sql — регрессия питомцев Stage 5
-- (миграции 064 «питомцы» и 065 «сон»; SPEC_STAGE5_PETS.md, карточки V2/V3)
--
-- Каждый БЛОК выполняется в отдельной begin;...rollback; — dev не изменяется, вся синтетика
-- (telegram_id >= 995000000) откатывается. Прогонять по одному блоку; каждый отдаёт свой грид
-- отчёта последним SELECT перед rollback. Строка с pass=false означает провал проверки.
--
-- Механику включает сам тест (`stage5_pets_enabled = true` внутри транзакции) и откатывает
-- вместе со всем остальным: после прогона dev остаётся спящим, питомцы не запущены.
--
-- Время: сон опирается на now(), поэтому переходы «выспался» и «устал» проверяются сдвигом
-- sleep_started_at / last_rested_at в прошлое — это единственный способ проверить сутки
-- переходов, не дожидаясь суток.
-- =============================================================================


-- =========================================================================
-- БЛОК 1 — покупка питомца: условие rhythm_4, списание, повтор
-- =========================================================================
begin;
create temp table pet_report(seq int, code text, title text, pass boolean, detail text) on commit drop;

insert into public.students (telegram_id, name, huikons) values (995000501, 'pet_r1', 5000);
update public.economy_config set stage5_pets_enabled = true where id;
update public.shop_items set active = true where item_code = 'pet_cat';

do $$
declare v_msg text; v_bal integer;
begin
  -- 1. без достижения rhythm_4 покупка невозможна
  begin
    perform public.buy_item(995000501, 'pet_cat');
    insert into pet_report values (1, 'BUY_NO_ACH', 'покупка без rhythm_4 отклоняется', false, 'покупка прошла');
  exception when others then
    select huikons into v_bal from public.students where telegram_id = 995000501;
    insert into pet_report values (1, 'BUY_NO_ACH', 'покупка без rhythm_4 отклоняется',
      v_bal = 5000, 'баланс ' || v_bal);
  end;

  -- 2. с достижением покупка списывает ровно 1200 и экипирует питомца
  insert into public.student_achievements (student_id, achievement_code) values (995000501, 'rhythm_4');
  perform public.buy_item(995000501, 'pet_cat');
  select huikons into v_bal from public.students where telegram_id = 995000501;
  insert into pet_report values (2, 'BUY_OK', 'покупка списывает 1200 и экипирует',
    v_bal = 3800
      and exists (select 1 from public.student_items where student_id = 995000501 and item_code = 'pet_cat')
      and exists (select 1 from public.student_equipment where student_id = 995000501 and slot = 'pet'),
    'баланс ' || v_bal);

  -- 3. повторная покупка отклоняется и не списывает второй раз
  begin
    perform public.buy_item(995000501, 'pet_cat');
    insert into pet_report values (3, 'BUY_TWICE', 'повторная покупка отклоняется', false, 'покупка прошла');
  exception when others then
    get stacked diagnostics v_msg = message_text;
    select huikons into v_bal from public.students where telegram_id = 995000501;
    insert into pet_report values (3, 'BUY_TWICE', 'повторная покупка отклоняется',
      v_bal = 3800, v_msg);
  end;
end $$;

select * from pet_report order by seq;
rollback;


-- =========================================================================
-- БЛОК 2 — кормление: списание, накопление запаса, потолок, деньги, диапазон
-- =========================================================================
begin;
create temp table pet_report(seq int, code text, title text, pass boolean, detail text) on commit drop;

insert into public.students (telegram_id, name, huikons) values (995000502, 'pet_r2', 1000);
update public.economy_config set stage5_pets_enabled = true where id;

do $$
declare
  v_today date := (now() at time zone 'Europe/Moscow')::date;
  v_bal integer; v_sat date; v_total integer; v_cnt integer; v_msg text;
begin
  -- 1. без питомца кормить нельзя
  begin
    perform public.feed_pet(995000502, 1);
    insert into pet_report values (1, 'FEED_NO_PET', 'кормление без питомца отклоняется', false, 'прошло');
  exception when others then
    get stacked diagnostics v_msg = message_text;
    insert into pet_report values (1, 'FEED_NO_PET', 'кормление без питомца отклоняется',
      not exists (select 1 from public.pet_feed_log where student_id = 995000502), v_msg);
  end;

  insert into public.student_items (student_id, item_code, quantity) values (995000502, 'pet_cat', 1);
  insert into public.student_equipment (student_id, slot, item_code) values (995000502, 'pet', 'pet_cat');

  -- 2. одно кормление: -5, «сыт до» = сегодня, один день заботы
  perform public.feed_pet(995000502, 1);
  select huikons into v_bal from public.students where telegram_id = 995000502;
  select satiety_until, days_fed_total into v_sat, v_total
    from public.student_pet_state where student_id = 995000502;
  insert into pet_report values (2, 'FEED_ONE', 'первое кормление: -5, сыт по сегодня',
    v_bal = 995 and v_sat = v_today and v_total = 1,
    format('баланс %s, сыт до %s, дней заботы %s', v_bal, v_sat, v_total));

  -- 3. второе кормление в тот же заход оплачивает СЛЕДУЮЩУЮ дату, а не ту же
  perform public.feed_pet(995000502, 1);
  select huikons into v_bal from public.students where telegram_id = 995000502;
  select satiety_until into v_sat from public.student_pet_state where student_id = 995000502;
  select count(*) into v_cnt from public.pet_feed_log where student_id = 995000502;
  insert into pet_report values (3, 'FEED_NEXT_DAY', 'повтор оплачивает следующий день, не тот же',
    v_bal = 990 and v_sat = v_today + 1 and v_cnt = 2,
    format('баланс %s, сыт до %s, строк лога %s', v_bal, v_sat, v_cnt));

  -- 4. добор до потолка: всего 7 оплаченных дней, списано 35
  perform public.feed_pet(995000502, 5);
  select huikons into v_bal from public.students where telegram_id = 995000502;
  select satiety_until into v_sat from public.student_pet_state where student_id = 995000502;
  select count(*) into v_cnt from public.pet_feed_log where student_id = 995000502;
  insert into pet_report values (4, 'FEED_CAP', 'потолок 7 дней: списано 35, лог из 7 строк',
    v_bal = 965 and v_cnt = 7 and v_sat = v_today + 6,
    format('баланс %s, сыт до %s, строк лога %s', v_bal, v_sat, v_cnt));

  -- 5. дальше кормить нечего — отказ без списания
  begin
    perform public.feed_pet(995000502, 1);
    insert into pet_report values (5, 'FEED_FULL', 'полный запас отклоняет кормление', false, 'прошло');
  exception when others then
    get stacked diagnostics v_msg = message_text;
    select huikons into v_bal from public.students where telegram_id = 995000502;
    insert into pet_report values (5, 'FEED_FULL', 'полный запас отклоняет кормление',
      v_bal = 965, v_msg);
  end;

  -- 6. диапазон p_days проверяется
  begin
    perform public.feed_pet(995000502, 99);
    insert into pet_report values (6, 'FEED_RANGE', 'p_days вне диапазона отклоняется', false, 'прошло');
  exception when others then
    get stacked diagnostics v_msg = message_text;
    insert into pet_report values (6, 'FEED_RANGE', 'p_days вне диапазона отклоняется', true, v_msg);
  end;
end $$;

-- 7. недостаток средств: отказ до записи в лог и до изменения состояния
do $$
declare v_bal integer; v_cnt integer; v_msg text;
begin
  insert into public.students (telegram_id, name, huikons) values (995000503, 'pet_r3', 3);
  insert into public.student_items (student_id, item_code, quantity) values (995000503, 'pet_owl', 1);
  insert into public.student_equipment (student_id, slot, item_code) values (995000503, 'pet', 'pet_owl');
  begin
    perform public.feed_pet(995000503, 1);
    insert into pet_report values (7, 'FEED_POOR', 'нехватка бубликов отклоняет кормление', false, 'прошло');
  exception when others then
    get stacked diagnostics v_msg = message_text;
    select huikons into v_bal from public.students where telegram_id = 995000503;
    select count(*) into v_cnt from public.pet_feed_log where student_id = 995000503;
    insert into pet_report values (7, 'FEED_POOR', 'нехватка бубликов отклоняет кормление',
      v_bal = 3 and v_cnt = 0 and not exists (select 1 from public.student_pet_state where student_id = 995000503),
      v_msg);
  end;
end $$;

select * from pet_report order by seq;
rollback;


-- =========================================================================
-- БЛОК 3 — ось питания: четыре состояния настроения
-- =========================================================================
begin;
create temp table pet_report(seq int, code text, title text, pass boolean, detail text) on commit drop;

insert into public.students (telegram_id, name, huikons) values (995000504, 'pet_r4', 100);
insert into public.student_items (student_id, item_code, quantity) values (995000504, 'pet_cat', 1);
insert into public.student_equipment (student_id, slot, item_code) values (995000504, 'pet', 'pet_cat');
update public.economy_config set stage5_pets_enabled = true where id;

do $$
declare
  v_today date := (now() at time zone 'Europe/Moscow')::date;
  v_state json; v_seq int := 0;
  r record;
begin
  for r in
    select * from (values
      (v_today + 2, 'happy'), (v_today + 1, 'fed'), (v_today, 'hungry_soon'), (v_today - 1, 'hungry')
    ) as t(sat, expected)
  loop
    v_seq := v_seq + 1;
    insert into public.student_pet_state (student_id, satiety_until, days_fed_total)
      values (995000504, r.sat, 0)
      on conflict (student_id) do update set satiety_until = excluded.satiety_until;
    v_state := public.get_pet_state(995000504);
    insert into pet_report values (v_seq, 'MOOD_' || r.expected,
      format('сыт до %s → %s', r.sat - v_today, r.expected),
      (v_state ->> 'mood') = r.expected,
      format('mood=%s, days_left=%s', v_state ->> 'mood', v_state ->> 'days_left'));
  end loop;
end $$;

select * from pet_report order by seq;
rollback;


-- =========================================================================
-- БЛОК 4 — ось отдыха: сон, автопробуждение, усталость, отсутствие списаний
-- =========================================================================
begin;
create temp table pet_report(seq int, code text, title text, pass boolean, detail text) on commit drop;

insert into public.students (telegram_id, name, huikons) values (995000505, 'pet_r5', 500);
insert into public.student_items (student_id, item_code, quantity) values (995000505, 'pet_capybara', 1);
insert into public.student_equipment (student_id, slot, item_code) values (995000505, 'pet', 'pet_capybara');
update public.economy_config set stage5_pets_enabled = true where id;

do $$
declare v_state json; v_bal integer; v_msg text; v_before integer;
begin
  -- 1. до первого сна питомец уставший и уложить его можно
  v_state := public.get_pet_state(995000505);
  insert into pet_report values (1, 'REST_INITIAL', 'без сна питомец уставший, уложить можно',
    (v_state ->> 'rest_state') = 'tired' and (v_state ->> 'can_sleep') = 'true',
    format('rest=%s, can_sleep=%s', v_state ->> 'rest_state', v_state ->> 'can_sleep'));

  -- 2. укладывание переводит в сон и не трогает баланс
  select huikons into v_before from public.students where telegram_id = 995000505;
  perform public.put_pet_to_sleep(995000505);
  v_state := public.get_pet_state(995000505);
  select huikons into v_bal from public.students where telegram_id = 995000505;
  insert into pet_report values (2, 'SLEEP_START', 'сон начался, баланс не изменился',
    (v_state ->> 'rest_state') = 'sleeping' and (v_state ->> 'can_sleep') = 'false' and v_bal = v_before,
    format('rest=%s, баланс %s → %s', v_state ->> 'rest_state', v_before, v_bal));

  -- 3. повторное укладывание во время сна отклоняется
  begin
    perform public.put_pet_to_sleep(995000505);
    insert into pet_report values (3, 'SLEEP_TWICE', 'повторное укладывание отклоняется', false, 'прошло');
  exception when others then
    get stacked diagnostics v_msg = message_text;
    insert into pet_report values (3, 'SLEEP_TWICE', 'повторное укладывание отклоняется', true, v_msg);
  end;

  -- 4. сон, начатый 9 часов назад, уже закончился сам: питомец выспался
  update public.student_pet_state set sleep_started_at = now() - interval '9 hours'
   where student_id = 995000505;
  v_state := public.get_pet_state(995000505);
  insert into pet_report values (4, 'SLEEP_AUTO_WAKE', 'сон 9 часов назад засчитан как отдых',
    (v_state ->> 'rest_state') = 'rested' and (v_state ->> 'can_sleep') = 'true',
    format('rest=%s, rested_until=%s', v_state ->> 'rest_state', v_state ->> 'rested_until'));

  -- 5. отдых старше 48 часов истекает
  update public.student_pet_state
     set sleep_started_at = now() - interval '60 hours',
         last_rested_at   = now() - interval '52 hours'
   where student_id = 995000505;
  v_state := public.get_pet_state(995000505);
  insert into pet_report values (5, 'REST_EXPIRES', 'отдых старше 48 часов истекает',
    (v_state ->> 'rest_state') = 'tired',
    format('rest=%s', v_state ->> 'rest_state'));

  -- 6. общее настроение — худшее из осей: сытый, но уставший не «доволен»
  insert into public.student_pet_state (student_id, satiety_until, days_fed_total)
    values (995000505, ((now() at time zone 'Europe/Moscow')::date) + 3, 0)
    on conflict (student_id) do update set satiety_until = excluded.satiety_until;
  v_state := public.get_pet_state(995000505);
  -- Ключевая проверка: у сытого, но уставшего общее состояние — «устал», а НЕ «голоден».
  -- Именно она поймала дефект 065, исправленный миграцией 066.
  insert into pet_report values (6, 'OVERALL_TIRED', 'сытый, но уставший → tired, не hungry',
    (v_state ->> 'mood') = 'happy' and (v_state ->> 'rest_state') = 'tired'
      and (v_state ->> 'overall_mood') = 'tired',
    format('mood=%s, rest=%s, overall=%s',
           v_state ->> 'mood', v_state ->> 'rest_state', v_state ->> 'overall_mood'));

  -- 7. спящий питомец показывается спящим независимо от сытости
  perform public.put_pet_to_sleep(995000505);
  v_state := public.get_pet_state(995000505);
  insert into pet_report values (7, 'OVERALL_SLEEPING', 'спящий показывается спящим',
    (v_state ->> 'overall_mood') = 'sleeping',
    format('overall=%s', v_state ->> 'overall_mood'));

  -- 8. сон не создал ни одной денежной операции
  insert into pet_report values (8, 'SLEEP_FREE', 'сон не пишет в баланс и историю',
    not exists (select 1 from public.balance_history where student_id = 995000505),
    'строк истории: ' || (select count(*) from public.balance_history where student_id = 995000505));
end $$;

select * from pet_report order by seq;
rollback;


-- =========================================================================
-- БЛОК 5 — выключенная механика отвергает и кормление, и сон
-- =========================================================================
begin;
create temp table pet_report(seq int, code text, title text, pass boolean, detail text) on commit drop;

insert into public.students (telegram_id, name, huikons) values (995000506, 'pet_r6', 500);
insert into public.student_items (student_id, item_code, quantity) values (995000506, 'pet_cat', 1);
insert into public.student_equipment (student_id, slot, item_code) values (995000506, 'pet', 'pet_cat');
-- Флаг НЕ включаем: воспроизводим боевое состояние до firing.

do $$
declare v_msg text;
begin
  begin
    perform public.feed_pet(995000506, 1);
    insert into pet_report values (1, 'OFF_FEED', 'выключенная механика не кормит', false, 'прошло');
  exception when others then
    get stacked diagnostics v_msg = message_text;
    insert into pet_report values (1, 'OFF_FEED', 'выключенная механика не кормит',
      not exists (select 1 from public.pet_feed_log where student_id = 995000506), v_msg);
  end;

  begin
    perform public.put_pet_to_sleep(995000506);
    insert into pet_report values (2, 'OFF_SLEEP', 'выключенная механика не укладывает', false, 'прошло');
  exception when others then
    get stacked diagnostics v_msg = message_text;
    insert into pet_report values (2, 'OFF_SLEEP', 'выключенная механика не укладывает',
      not exists (select 1 from public.student_pet_state where student_id = 995000506), v_msg);
  end;
end $$;

select * from pet_report order by seq;
rollback;
