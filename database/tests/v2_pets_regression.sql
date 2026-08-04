-- =============================================================================
-- database/tests/v2_pets_regression.sql — регрессия питомцев Stage 5
-- (миграции 064 «питомцы», 065 «сон», 066 «настроение», 068 «оси комнаты», 069 «эволюция», 070 «предметы»;
-- SPEC_STAGE5_PETS.md, SPEC_STAGE5_PET_ROOM.md, карточки V2/V3 и PET1)
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


-- =========================================================================
-- БЛОК 6 — PET1: оси внимания и игры, связь (миграция 068)
--
-- Отдельно проверяется главное уточнение реализации: связь считает ДНИ С ЗАБОТОЙ, а не
-- количество действий. Иначе «60 дней заботы» из условия эволюции набирались бы тапами.
-- =========================================================================
begin;
create temp table pet_report(seq int, code text, title text, pass boolean, detail text) on commit drop;

insert into public.students (telegram_id, name, huikons) values (995000507, 'pet_r7', 500);
update public.economy_config set stage5_pets_enabled = true where id;

do $$
declare v_msg text; v_bond integer; v_cnt integer; v_room json;
begin
  -- 1. действие без питомца отклоняется
  begin
    perform public.pet_care(995000507, 'pet');
    insert into pet_report values (1, 'CARE_NO_PET', 'забота без питомца отклоняется', false, 'прошло');
  exception when others then
    get stacked diagnostics v_msg = message_text;
    insert into pet_report values (1, 'CARE_NO_PET', 'забота без питомца отклоняется',
      not exists (select 1 from public.pet_care_log where student_id = 995000507), v_msg);
  end;

  insert into public.student_items (student_id, item_code, quantity) values (995000507, 'pet_cat', 1);
  insert into public.student_equipment (student_id, slot, item_code) values (995000507, 'pet', 'pet_cat');

  -- 2. первое «погладить»: одна строка лога, связь 1
  perform public.pet_care(995000507, 'pet');
  select bond into v_bond from public.student_pet_state where student_id = 995000507;
  select count(*) into v_cnt from public.pet_care_log where student_id = 995000507;
  insert into pet_report values (2, 'CARE_FIRST', 'первое действие: лог 1, связь 1',
    v_cnt = 1 and v_bond = 1, format('лог %s, связь %s', v_cnt, v_bond));

  -- 3. повтор в том же окне отклоняется и ничего не пишет
  begin
    perform public.pet_care(995000507, 'pet');
    insert into pet_report values (3, 'CARE_SAME_WINDOW', 'повтор в окне отклоняется', false, 'прошло');
  exception when others then
    get stacked diagnostics v_msg = message_text;
    select count(*) into v_cnt from public.pet_care_log where student_id = 995000507;
    select bond into v_bond from public.student_pet_state where student_id = 995000507;
    insert into pet_report values (3, 'CARE_SAME_WINDOW', 'повтор в окне отклоняется',
      v_cnt = 1 and v_bond = 1, format('лог %s, связь %s', v_cnt, v_bond));
  end;

  -- 4. «поиграть» — независимая ось: своё окно, своя строка
  perform public.pet_care(995000507, 'play');
  select count(*) into v_cnt from public.pet_care_log where student_id = 995000507;
  select bond into v_bond from public.student_pet_state where student_id = 995000507;
  insert into pet_report values (4, 'CARE_INDEPENDENT', 'игра не мешает поглаживанию',
    v_cnt = 2 and v_bond = 1,
    format('лог %s, связь %s (в тот же день связь не растёт второй раз)', v_cnt, v_bond));

  -- 5. новое окно: действие снова доступно
  update public.pet_care_log set window_start = window_start - interval '48 hours'
   where student_id = 995000507 and action = 'pet';
  perform public.pet_care(995000507, 'pet');
  select count(*) into v_cnt from public.pet_care_log
   where student_id = 995000507 and action = 'pet';
  insert into pet_report values (5, 'CARE_NEW_WINDOW', 'в новом окне действие доступно',
    v_cnt = 2, format('строк поглаживания %s', v_cnt));

  -- 6. связь считает ДНИ: в пределах одних суток она осталась 1 при четырёх действиях
  select bond into v_bond from public.student_pet_state where student_id = 995000507;
  insert into pet_report values (6, 'BOND_IS_DAYS', 'связь считает дни, а не нажатия',
    v_bond = 1, format('связь %s после трёх засчитанных действий за день', v_bond));

  -- 7. новый день заботы двигает связь на единицу.
  -- Сдвигаем И день связи, И окно кулдауна: иначе «поиграть» из проверки 4 всё ещё в своём
  -- 12-часовом окне и функция откажет — как она и должна.
  update public.student_pet_state set last_bond_date = last_bond_date - 1
   where student_id = 995000507;
  update public.pet_care_log set window_start = window_start - interval '48 hours'
   where student_id = 995000507 and action = 'play';
  perform public.pet_care(995000507, 'play');
  select bond into v_bond from public.student_pet_state where student_id = 995000507;
  insert into pet_report values (7, 'BOND_NEXT_DAY', 'новый день заботы: связь +1',
    v_bond = 2, format('связь %s', v_bond));

  -- 8. кормление тоже двигает связь и тоже один раз за день
  update public.student_pet_state set last_bond_date = last_bond_date - 1
   where student_id = 995000507;
  perform public.feed_pet(995000507, 1);
  select bond into v_bond from public.student_pet_state where student_id = 995000507;
  insert into pet_report values (8, 'BOND_FEED', 'кормление засчитывает день заботы',
    v_bond = 3, format('связь %s', v_bond));

  -- 9. сон тоже двигает связь
  update public.student_pet_state set last_bond_date = last_bond_date - 1
   where student_id = 995000507;
  perform public.put_pet_to_sleep(995000507);
  select bond into v_bond from public.student_pet_state where student_id = 995000507;
  insert into pet_report values (9, 'BOND_SLEEP', 'сон засчитывает день заботы',
    v_bond = 4, format('связь %s', v_bond));

  -- 10. бесплатные оси не создали ни одной денежной операции
  insert into pet_report values (10, 'CARE_FREE', 'внимание и игра бесплатны',
    (select count(*) from public.balance_history
      where student_id = 995000507 and reason <> 'pet_feed') = 0,
    'строк истории кроме корма: ' ||
      (select count(*) from public.balance_history
        where student_id = 995000507 and reason <> 'pet_feed'));

  -- 11. read-модель отдаёт доступность обеих осей и связь
  v_room := public.get_pet_room(995000507);
  insert into pet_report values (11, 'ROOM_MODEL', 'комната отдаёт оси, связь и питомца',
    (v_room -> 'care' -> 'petting' ->> 'available') is not null
      and (v_room -> 'care' -> 'play' ->> 'available') is not null
      and (v_room ->> 'bond')::int = 4
      and (v_room -> 'pet' ->> 'item_code') = 'pet_cat',
    format('bond=%s, petting=%s, play=%s', v_room ->> 'bond',
           v_room -> 'care' -> 'petting' ->> 'available',
           v_room -> 'care' -> 'play' ->> 'available'));

  -- 12. реакции: плохих событий в контракте нет вовсе
  insert into pet_report values (12, 'CHEERS_ONLY_GOOD', 'в реакциях только хорошее',
    (v_room -> 'cheers' ->> 'good_week') is not null
      and (v_room -> 'cheers') ::text not like '%bad%'
      and (v_room -> 'cheers') ::text not like '%missed%'
      and (v_room -> 'cheers') ::text not like '%demote%',
    (v_room -> 'cheers')::text);

  -- 13. связь не уменьшилась ни в одном сценарии
  select bond into v_bond from public.student_pet_state where student_id = 995000507;
  insert into pet_report values (13, 'BOND_NEVER_DROPS', 'связь только росла',
    v_bond = 4, format('связь %s', v_bond));
end $$;

-- 14. выключенная механика отвергает обе бесплатные оси
do $$
declare v_msg text;
begin
  update public.economy_config set stage5_pets_enabled = false where id;
  begin
    perform public.pet_care(995000507, 'pet');
    insert into pet_report values (14, 'CARE_OFF', 'выключенная механика не даёт заботиться', false, 'прошло');
  exception when others then
    get stacked diagnostics v_msg = message_text;
    -- Проверка обязана доказывать именно флаг, а не кулдаун: в pet_care флаг проверяется
    -- раньше окна, поэтому сообщение должно быть про недоступность механики.
    insert into pet_report values (14, 'CARE_OFF', 'выключенная механика не даёт заботиться',
      v_msg like '%недоступны%', v_msg);
  end;
end $$;

select * from pet_report order by seq;
rollback;


-- =========================================================================
-- БЛОК 7 — PET4: эволюция питомца (миграция 069)
--
-- Главное, что проверяется: эволюцию нельзя купить в обход заботы и нельзя получить
-- заботой в обход денег — нужны обе оси сразу.
-- =========================================================================
begin;
create temp table pet_report(seq int, code text, title text, pass boolean, detail text) on commit drop;

insert into public.students (telegram_id, name, huikons) values (995000508, 'pet_r8', 5000);
update public.economy_config set stage5_pets_enabled = true where id;

do $$
declare v_msg text; v_bal integer; v_stage smallint; v_bond integer; v_state json; v_room json;
begin
  -- 1. эволюция без питомца отклоняется
  begin
    perform public.evolve_pet(995000508);
    insert into pet_report values (1, 'EVO_NO_PET', 'эволюция без питомца отклоняется', false, 'прошло');
  exception when others then
    get stacked diagnostics v_msg = message_text;
    insert into pet_report values (1, 'EVO_NO_PET', 'эволюция без питомца отклоняется', true, v_msg);
  end;

  insert into public.student_items (student_id, item_code, quantity) values (995000508, 'pet_cat', 1);
  insert into public.student_equipment (student_id, slot, item_code) values (995000508, 'pet', 'pet_cat');
  insert into public.student_pet_state (student_id, satiety_until, days_fed_total, bond, last_bond_date)
    values (995000508, null, 0, 10, (now() at time zone 'Europe/Moscow')::date);

  -- 2. денег хватает, заботы нет → отказ, ничего не списано, ступень прежняя
  begin
    perform public.evolve_pet(995000508);
    insert into pet_report values (2, 'EVO_NEED_BOND', 'без 60 дней заботы эволюции нет', false, 'прошло');
  exception when others then
    get stacked diagnostics v_msg = message_text;
    select huikons into v_bal from public.students where telegram_id = 995000508;
    select stage into v_stage from public.student_pet_state where student_id = 995000508;
    insert into pet_report values (2, 'EVO_NEED_BOND', 'без 60 дней заботы эволюции нет',
      v_bal = 5000 and v_stage = 1, format('%s | баланс %s, ступень %s', v_msg, v_bal, v_stage));
  end;

  -- 3. заботы хватает, денег нет → отказ, ступень прежняя
  update public.student_pet_state set bond = 60 where student_id = 995000508;
  update public.students set huikons = 100 where telegram_id = 995000508;
  begin
    perform public.evolve_pet(995000508);
    insert into pet_report values (3, 'EVO_NEED_MONEY', 'без 1500 бубликов эволюции нет', false, 'прошло');
  exception when others then
    get stacked diagnostics v_msg = message_text;
    select stage into v_stage from public.student_pet_state where student_id = 995000508;
    select huikons into v_bal from public.students where telegram_id = 995000508;
    insert into pet_report values (3, 'EVO_NEED_MONEY', 'без 1500 бубликов эволюции нет',
      v_stage = 1 and v_bal = 100, format('%s | баланс %s, ступень %s', v_msg, v_bal, v_stage));
  end;

  -- 4. обе оси сошлись → эволюция проходит, списано ровно 1500
  update public.students set huikons = 2000 where telegram_id = 995000508;
  perform public.evolve_pet(995000508);
  select huikons into v_bal from public.students where telegram_id = 995000508;
  select stage, bond into v_stage, v_bond from public.student_pet_state where student_id = 995000508;
  insert into pet_report values (4, 'EVO_OK', 'обе оси сошлись: ступень 2, списано 1500',
    v_bal = 500 and v_stage = 2 and v_bond = 60,
    format('баланс %s, ступень %s, связь %s', v_bal, v_stage, v_bond));

  -- 5. повторная эволюция отклоняется и не списывает второй раз
  begin
    perform public.evolve_pet(995000508);
    insert into pet_report values (5, 'EVO_TWICE', 'повторная эволюция отклоняется', false, 'прошло');
  exception when others then
    get stacked diagnostics v_msg = message_text;
    select huikons into v_bal from public.students where telegram_id = 995000508;
    insert into pet_report values (5, 'EVO_TWICE', 'повторная эволюция отклоняется',
      v_bal = 500, format('%s | баланс %s', v_msg, v_bal));
  end;

  -- 6. связь эволюция не тратит: 60 дней заботы остаются накопленными
  insert into pet_report values (6, 'EVO_KEEPS_BOND', 'эволюция не сбрасывает связь',
    v_bond = 60, format('связь %s', v_bond));

  -- 7. get_pet_state отдаёт ступень (её читает задеплоенный клиент)
  v_state := public.get_pet_state(995000508);
  insert into pet_report values (7, 'STATE_STAGE', 'get_pet_state отдаёт ступень',
    (v_state ->> 'stage')::int = 2, format('stage=%s', v_state ->> 'stage'));

  -- 8. комната отдаёт блок эволюции с прогрессом
  v_room := public.get_pet_room(995000508);
  insert into pet_report values (8, 'ROOM_EVOLUTION', 'комната отдаёт блок эволюции',
    (v_room -> 'evolution' ->> 'stage')::int = 2
      and (v_room -> 'evolution' ->> 'price')::int = 1500
      and (v_room -> 'evolution' ->> 'bond_required')::int = 60
      and (v_room -> 'evolution' ->> 'available') = 'false',
    (v_room -> 'evolution')::text);
end $$;

-- 9. прогресс до эволюции: сколько не хватает, считает сервер
do $$
declare v_room json;
begin
  insert into public.students (telegram_id, name, huikons) values (995000509, 'pet_r9', 5000);
  insert into public.student_items (student_id, item_code, quantity) values (995000509, 'pet_owl', 1);
  insert into public.student_equipment (student_id, slot, item_code) values (995000509, 'pet', 'pet_owl');
  insert into public.student_pet_state (student_id, satiety_until, days_fed_total, bond, last_bond_date)
    values (995000509, null, 0, 38, (now() at time zone 'Europe/Moscow')::date);

  v_room := public.get_pet_room(995000509);
  insert into pet_report values (9, 'EVO_PROGRESS', 'сервер считает прогресс и нехватку',
    (v_room -> 'evolution' ->> 'bond_current')::int = 38
      and (v_room -> 'evolution' ->> 'bond_missing')::int = 22
      and (v_room -> 'evolution' ->> 'available') = 'false',
    (v_room -> 'evolution')::text);
end $$;

-- 10. выключенная механика отвергает эволюцию
do $$
declare v_msg text;
begin
  update public.economy_config set stage5_pets_enabled = false where id;
  begin
    perform public.evolve_pet(995000508);
    insert into pet_report values (10, 'EVO_OFF', 'выключенная механика не выращивает', false, 'прошло');
  exception when others then
    get stacked diagnostics v_msg = message_text;
    insert into pet_report values (10, 'EVO_OFF', 'выключенная механика не выращивает',
      v_msg like '%недоступны%', v_msg);
  end;
end $$;

select * from pet_report order by seq;
rollback;


-- =========================================================================
-- БЛОК 8 — PET3: предметы комнаты (миграция 070)
--
-- Главное, что проверяется: предметы комнаты НЕ попадают в требование коллекционного
-- бонуса. Это решение пользователя, и оно держится не на договорённости, а на том, что
-- предметы постоянные (availability='always'), а бонус считает только rotation.
-- =========================================================================
begin;
create temp table pet_report(seq int, code text, title text, pass boolean, detail text) on commit drop;

insert into public.students (telegram_id, name, huikons) values (995000510, 'pet_r10', 5000);
update public.economy_config set stage5_pets_enabled = true where id;

do $$
declare v_msg text; v_bal integer; v_room json; v_before integer; v_after integer; v_season bigint;
begin
  -- 1. пока предметы спят, купить их нельзя
  begin
    perform public.buy_item(995000510, 'pet_bed_pillow');
    insert into pet_report values (1, 'ITEM_DORMANT', 'спящий предмет не продаётся', false, 'покупка прошла');
  exception when others then
    get stacked diagnostics v_msg = message_text;
    select huikons into v_bal from public.students where telegram_id = 995000510;
    insert into pet_report values (1, 'ITEM_DORMANT', 'спящий предмет не продаётся',
      v_bal = 5000, format('%s | баланс %s', v_msg, v_bal));
  end;

  -- 2. после включения покупка списывает цену и сразу экипирует в свой слот
  update public.shop_items set active = true where slot in ('pet_bed', 'pet_toy');
  perform public.buy_item(995000510, 'pet_bed_pillow');
  perform public.buy_item(995000510, 'pet_toy_yarn');
  select huikons into v_bal from public.students where telegram_id = 995000510;
  insert into pet_report values (2, 'ITEM_BUY', 'покупка списывает 600+300 и экипирует',
    v_bal = 4100
      and exists (select 1 from public.student_equipment
                   where student_id = 995000510 and slot = 'pet_bed' and item_code = 'pet_bed_pillow')
      and exists (select 1 from public.student_equipment
                   where student_id = 995000510 and slot = 'pet_toy' and item_code = 'pet_toy_yarn'),
    format('баланс %s', v_bal));

  -- 3. слоты независимы: вторая лежанка вытесняет первую, игрушку не трогает
  perform public.buy_item(995000510, 'pet_bed_mat');
  insert into pet_report values (3, 'ITEM_SLOTS', 'слоты независимы, в каждом один предмет',
    (select item_code from public.student_equipment
      where student_id = 995000510 and slot = 'pet_bed') = 'pet_bed_mat'
      and (select item_code from public.student_equipment
            where student_id = 995000510 and slot = 'pet_toy') = 'pet_toy_yarn'
      and (select count(*) from public.student_equipment
            where student_id = 995000510 and slot like 'pet_%') = 2,
    'лежанка сменилась, игрушка на месте');

  -- 4. комната отдаёт надетые предметы
  insert into public.student_items (student_id, item_code, quantity) values (995000510, 'pet_cat', 1);
  insert into public.student_equipment (student_id, slot, item_code) values (995000510, 'pet', 'pet_cat');
  v_room := public.get_pet_room(995000510);
  insert into pet_report values (4, 'ROOM_ITEMS', 'комната отдаёт лежанку и игрушку',
    (v_room -> 'room_items' ->> 'bed') = 'bed_v1_mat'
      and (v_room -> 'room_items' ->> 'toy') = 'toy_v1_yarn',
    (v_room -> 'room_items')::text);

  -- 5. ГЛАВНОЕ: предметы комнаты не меняют требование коллекционного бонуса
  select season_id into v_season from public.season_bundles order by season_id desc limit 1;
  if v_season is null then
    insert into pet_report values (5, 'ITEM_NOT_IN_COLLECTION', 'предметы вне коллекции',
      true, 'бандлов нет — проверка неприменима, требование считается по rotation');
  else
    select count(*) into v_after
      from public.shop_items s
      join public.season_bundles b on b.bundle = s.rotation_bundle
     where s.availability = 'rotation' and b.season_id = v_season;
    select count(*) into v_before
      from public.shop_items s
      join public.season_bundles b on b.bundle = s.rotation_bundle
     where s.availability = 'rotation' and b.season_id = v_season
       and s.slot not in ('pet_bed', 'pet_toy');
    insert into pet_report values (5, 'ITEM_NOT_IN_COLLECTION', 'предметы вне коллекции',
      v_before = v_after,
      format('в бандле %s предметов, из них комнатных %s', v_after, v_after - v_before));
  end if;

  -- 6. предметы не трогают ни связь, ни сытость, ни отдых
  insert into pet_report values (6, 'ITEM_COSMETIC_ONLY', 'предметы ничего не дают механике',
    not exists (select 1 from public.pet_care_log where student_id = 995000510)
      and not exists (select 1 from public.pet_feed_log where student_id = 995000510)
      and coalesce((select bond from public.student_pet_state where student_id = 995000510), 0) = 0,
    'ни заботы, ни кормлений, связь 0');
end $$;

select * from pet_report order by seq;
rollback;
