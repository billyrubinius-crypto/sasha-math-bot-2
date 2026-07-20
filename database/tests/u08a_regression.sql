-- =============================================================================
-- database/tests/u08a_regression.sql — U08A/U08B regression harness
-- (Bot 2.0, Stage 4; SPEC_STAGE4.md §§2, 8, 9; карточки U08A, U08B)
--
-- Проверки 1–8 карточки U08A (toggle-проверки 9 и живой smoke 10 — в браузере, не в SQL) +
-- проверка 9 (B2-U23, карточка U08B) — singleton-guard economy_config в release firing.
-- Каждый ГРУППОВОЙ блок выполняется в отдельной begin;...rollback; — dev не изменяется, вся
-- синтетика (telegram_id >= 995000000, шаблон 'u08_r') откатывается. Прогонять по одному блоку;
-- каждый блок отдаёт свой грид отчёта последним SELECT перед rollback.
--
-- Предусловие: dev dormant после migration 031 (started_at=NULL, generation=false, pre-cutover
-- цены, никаких строк student_daily_quests / daily_quest_reward_log).
-- =============================================================================


-- =========================================================================
-- БЛОК 1 — read-модель daily_quest_state (проверки 1–5). Создаёт дневные строки.
-- =========================================================================
begin;
create temp table u08_report(seq int, code text, title text, pass boolean, detail text) on commit drop;

insert into public.life_quest_templates(template_code,name,description,category,weight)
  values ('u08_r','U08A R','d','T',1);
insert into public.students(telegram_id,name,huikons)
  select gs,'U08A '||gs,0 from generate_series(995000701,995000706) gs;

do $$
declare today date := (now() at time zone 'Europe/Moscow')::date;
        a_asgn uuid; a_rej uuid; a_sub uuid; a_appr uuid;
        j1 json; j2a json; j2b json; j3 json; j4 json; j5 json; combo_after int;
begin
  -- 1. life paid + math unavailable (нет target assignment) -> combo locked
  insert into public.student_daily_quests(student_id,quest_date,life_template_code) values (995000701,today,'u08_r');
  insert into public.daily_quest_reward_log(student_id,quest_date,reward_kind,bubliks) values (995000701,today,'life',3);
  j1 := public.daily_quest_state(995000701,today);
  insert into u08_report values (1,'U08A-1','life paid + math unavailable -> combo locked',
    j1->>'math_status'='unavailable' and j1->>'combo_status'='locked',
    format('math=%s combo=%s', j1->>'math_status', j1->>'combo_status'));

  -- 2. life paid + math assigned/rejected -> combo locked, math active
  insert into public.assignments(student_id,type,status) values (995000702,'daily','assigned') returning id into a_asgn;
  insert into public.student_daily_quests(student_id,quest_date,daily_assignment_id,life_template_code) values (995000702,today,a_asgn,'u08_r');
  insert into public.daily_quest_reward_log(student_id,quest_date,reward_kind,bubliks) values (995000702,today,'life',3);
  j2a := public.daily_quest_state(995000702,today);
  insert into public.assignments(student_id,type,status,approval_status) values (995000703,'daily','checked','rejected') returning id into a_rej;
  insert into public.student_daily_quests(student_id,quest_date,daily_assignment_id,life_template_code) values (995000703,today,a_rej,'u08_r');
  insert into public.daily_quest_reward_log(student_id,quest_date,reward_kind,bubliks) values (995000703,today,'life',3);
  j2b := public.daily_quest_state(995000703,today);
  insert into u08_report values (2,'U08A-2','life paid + math assigned/rejected -> combo locked',
    j2a->>'math_status'='active' and j2a->>'combo_status'='locked'
    and j2b->>'math_status'='active' and j2b->>'combo_status'='locked',
    format('assigned(math=%s combo=%s) rejected(math=%s combo=%s)',
      j2a->>'math_status', j2a->>'combo_status', j2b->>'math_status', j2b->>'combo_status'));

  -- 3. life paid + math submitted -> combo waiting_review
  insert into public.assignments(student_id,type,status) values (995000704,'daily','submitted') returning id into a_sub;
  insert into public.student_daily_quests(student_id,quest_date,daily_assignment_id,life_template_code) values (995000704,today,a_sub,'u08_r');
  insert into public.daily_quest_reward_log(student_id,quest_date,reward_kind,bubliks) values (995000704,today,'life',3);
  j3 := public.daily_quest_state(995000704,today);
  insert into u08_report values (3,'U08A-3','life paid + math submitted -> combo waiting_review',
    j3->>'math_status'='waiting_review' and j3->>'combo_status'='waiting_review',
    format('math=%s combo=%s', j3->>'math_status', j3->>'combo_status'));

  -- 4. checked+approved БЕЗ math ledger -> math unavailable и combo locked (ключевой фикс)
  insert into public.assignments(student_id,type,status,approval_status) values (995000705,'daily','checked','approved') returning id into a_appr;
  insert into public.student_daily_quests(student_id,quest_date,daily_assignment_id,life_template_code) values (995000705,today,a_appr,'u08_r');
  insert into public.daily_quest_reward_log(student_id,quest_date,reward_kind,bubliks) values (995000705,today,'life',3);
  j4 := public.daily_quest_state(995000705,today);
  insert into u08_report values (4,'U08A-4','terminal checked+approved no math ledger -> math unavailable, combo locked',
    j4->>'math_status'='unavailable' and j4->>'combo_status'='locked',
    format('math=%s combo=%s', j4->>'math_status', j4->>'combo_status'));

  -- 5. math+combo ledger -> completed; retry settle_daily_combo не меняет ledger
  insert into public.student_daily_quests(student_id,quest_date,life_template_code) values (995000706,today,'u08_r');
  insert into public.daily_quest_reward_log(student_id,quest_date,reward_kind,bubliks) values
    (995000706,today,'life',3),(995000706,today,'math',3),(995000706,today,'combo',2);
  j5 := public.daily_quest_state(995000706,today);
  perform public.settle_daily_combo(995000706,today);   -- retry: on-conflict do nothing, без add_huikons
  select count(*) into combo_after from public.daily_quest_reward_log where student_id=995000706 and reward_kind='combo';
  insert into u08_report values (5,'U08A-5','math/combo ledger -> completed; retry idempotent',
    j5->>'math_status'='completed' and j5->>'combo_status'='completed' and combo_after=1,
    format('math=%s combo=%s combo_rows_after_retry=%s', j5->>'math_status', j5->>'combo_status', combo_after));
end $$;

select seq,code,title,case when pass then 'PASS' else 'FAIL' end as result,detail from u08_report order by seq;
rollback;


-- =========================================================================
-- БЛОК 2 — bootstrap-neutralizer и release firing preflight (проверки 6–8).
-- Стартует с чистого dormant слейта (блок 1 откатан). Каждый check сам ставит свой
-- config/price precondition и чистит свою синтетику.
-- =========================================================================
begin;
create temp table u08_report(seq int, code text, title text, pass boolean, detail text) on commit drop;
insert into public.life_quest_templates(template_code,name,description,category,weight)
  values ('u08_r','U08A R','d','T',1);

-- 6. neutralizer при пустом Stage 4 -> точный dormant каталог/config
do $$
declare crown_p int; pulsar_p int; frame_a boolean; sa timestamptz; gen boolean;
begin
  -- симулируем fired
  update public.shop_items set price=900 where item_code='crown';
  update public.shop_items set price=1200 where item_code in ('frame_pulsar','frame_orbit');
  update public.shop_items set active=false where item_code='frame_fire100';
  update public.economy_config set stage4_started_at=now(), stage4_generation_enabled=true where id;
  -- neutralizer (inline = migration 031 §2): guard + reset
  if exists(select 1 from public.student_daily_quests) or exists(select 1 from public.daily_quest_reward_log) then
    raise exception 'neutralizer guard (unexpected quest data)'; end if;
  update public.shop_items set price=50 where item_code in ('color_red','color_orange','color_green','color_teal','color_blue','color_indigo','color_pink','color_brown');
  update public.shop_items set price=30 where item_code='status_emoji_change';
  update public.shop_items set price=600 where item_code='crown';
  update public.shop_items set price=700 where item_code='golden_nick';
  update public.shop_items set price=900 where item_code='title_yaschenko';
  update public.shop_items set price=2000 where item_code='title_custom';
  update public.shop_items set active=true where item_code='frame_fire100';
  update public.shop_items set price=200 where item_code='title_groza';
  update public.shop_items set price=150 where item_code in ('title_elon','title_derivative');
  update public.shop_items set price=120 where item_code='title_sanchez';
  update public.shop_items set price=150 where item_code in ('frame_notebook','frame_winter');
  update public.shop_items set price=200 where item_code in ('bg_grid','bg_space','bg_aurora','bg_draft');
  update public.shop_items set price=750 where item_code in ('frame_pulsar','frame_orbit');
  update public.shop_items set price=1500 where item_code in ('frame_legend_1','frame_legend_2','frame_legend_3','frame_legend_4');
  update public.economy_config set stage4_generation_enabled=false, stage4_started_at=null where id;
  -- assert dormant
  select price into crown_p from public.shop_items where item_code='crown';
  select price into pulsar_p from public.shop_items where item_code='frame_pulsar';
  select active into frame_a from public.shop_items where item_code='frame_fire100';
  select stage4_started_at, stage4_generation_enabled into sa, gen from public.economy_config where id;
  insert into u08_report values (6,'U08A-6','neutralizer on empty Stage 4 -> exact dormant',
    crown_p=600 and pulsar_p=750 and frame_a and sa is null and gen=false,
    format('crown=%s pulsar=%s frame_active=%s started=%s gen=%s', crown_p, pulsar_p, frame_a, sa, gen));
end $$;

-- 7. neutralizer при наличии Stage 4 строки -> аварийный откат без изменений
do $$
declare crown_p int; sa timestamptz; gen boolean; raised boolean:=false;
begin
  update public.shop_items set price=900 where item_code='crown';
  update public.economy_config set stage4_started_at=now(), stage4_generation_enabled=true where id;
  insert into public.students(telegram_id,name,huikons) values (995000707,'U08A s707',0);
  insert into public.student_daily_quests(student_id,quest_date,life_template_code)
    values (995000707,(now() at time zone 'Europe/Moscow')::date,'u08_r');
  begin
    if exists(select 1 from public.student_daily_quests) or exists(select 1 from public.daily_quest_reward_log) then
      raise exception 'U08A neutralizer refuses (Stage 4 data present)'; end if;
    update public.shop_items set price=600 where item_code='crown';                 -- reset (не должен выполниться)
    update public.economy_config set stage4_generation_enabled=false, stage4_started_at=null where id;
  exception when others then raised:=true;
  end;
  select price into crown_p from public.shop_items where item_code='crown';
  select stage4_started_at, stage4_generation_enabled into sa, gen from public.economy_config where id;
  insert into u08_report values (7,'U08A-7','neutralizer aborts on any Stage 4 row (no change)',
    raised and crown_p=900 and sa is not null and gen=true,
    format('raised=%s crown=%s started_notnull=%s gen=%s (fired state intact)', raised, crown_p, (sa is not null), gen));
  delete from public.student_daily_quests where student_id>=995000000;   -- чистим для check 8
end $$;

-- 8. release firing preflight -> partial firing невозможен (не-NULL start / неожиданная цена)
do $$
declare gen boolean; crown_p int; raised_a boolean:=false; raised_b boolean:=false;
        v_missing int; v_badprice int;
begin
  -- (a) не-NULL start -> abort, ничего не применено
  update public.economy_config set stage4_started_at=now(), stage4_generation_enabled=false where id;
  update public.shop_items set price=600 where item_code='crown';     -- pre-cutover baseline
  begin
    if (select stage4_started_at from public.economy_config where id) is not null then
      raise exception 'FIRING ABORT: start not null'; end if;
    update public.shop_items set price=900 where item_code='crown';   -- would-be firing change
    update public.economy_config set stage4_generation_enabled=true where id;
  exception when others then raised_a:=true;
  end;
  select stage4_generation_enabled into gen from public.economy_config where id;
  select price into crown_p from public.shop_items where item_code='crown';
  -- (b) неожиданная цена -> abort до применения
  update public.economy_config set stage4_started_at=null, stage4_generation_enabled=false where id;
  update public.shop_items set price=999 where item_code='crown';     -- unexpected
  begin
    if (select stage4_started_at from public.economy_config where id) is not null then
      raise exception 'FIRING ABORT: start not null'; end if;
    with expected(item_code, old_price) as (values
      ('crown',600),('golden_nick',700),('title_custom',2000),('frame_pulsar',750),('frame_legend_1',1500))
    select count(*) filter (where s.item_code is null),
           count(*) filter (where s.item_code is not null and s.price is distinct from e.old_price)
      into v_missing, v_badprice
      from expected e left join public.shop_items s on s.item_code=e.item_code;
    if v_badprice>0 then raise exception 'FIRING ABORT: unexpected price'; end if;
    update public.economy_config set stage4_generation_enabled=true, stage4_started_at=now() where id;  -- would-be firing
  exception when others then raised_b:=true;
  end;
  insert into u08_report values (8,'U08A-8','firing preflight blocks partial firing (non-NULL start, bad price)',
    raised_a and gen=false and crown_p=600 and raised_b
    and (select not stage4_generation_enabled from public.economy_config where id)
    and (select stage4_started_at is null from public.economy_config where id),
    format('a: raised=%s gen_after=%s crown_after=%s | b: raised=%s gen_after=%s',
      raised_a, gen, crown_p, raised_b, (select stage4_generation_enabled from public.economy_config where id)));
end $$;

-- 9. B2-U23 (U08B) — singleton-guard economy_config: success ROW_COUNT=1 + missing-config abort.
-- Дословно повторяет actual preflight/APPLY блок из database/releases/stage4_cutover.sql
-- (singleton-guard + все 4 существующих preflight + полный список из 28 item_code + финальный
-- economy_config UPDATE с проверкой ROW_COUNT). Восстановление — только общим rollback блока,
-- без ручного компенсирующего UPDATE после missing-config сценария.
do $$
declare
  v_missing int; v_badprice int; v_frame boolean; v_config_cnt int; v_row_count int;
  crown_before int; crown_after_success int; crown_after_abort int;
  frame_before boolean; frame_after_abort boolean;
  gen_after_success boolean; started_after_success timestamptz; success_raised boolean := false;
  abort_raised boolean := false;
begin
  -- Check 9 не полагается на состояние, оставленное предыдущими проверками файла (check 8
  -- намеренно не восстанавливает crown после своего sub-check 'b' с неожиданной ценой) —
  -- явно приводим каталог/config к чистому pre-cutover dormant перед success sub-check.
  update public.shop_items set price = 50
   where item_code in ('color_red','color_orange','color_green','color_teal',
                       'color_blue','color_indigo','color_pink','color_brown');
  update public.shop_items set price = 30   where item_code = 'status_emoji_change';
  update public.shop_items set price = 600  where item_code = 'crown';
  update public.shop_items set price = 700  where item_code = 'golden_nick';
  update public.shop_items set price = 900  where item_code = 'title_yaschenko';
  update public.shop_items set price = 2000 where item_code = 'title_custom';
  update public.shop_items set active = true where item_code = 'frame_fire100';
  update public.shop_items set price = 200  where item_code = 'title_groza';
  update public.shop_items set price = 150  where item_code in ('title_elon','title_derivative');
  update public.shop_items set price = 120  where item_code = 'title_sanchez';
  update public.shop_items set price = 150  where item_code in ('frame_notebook','frame_winter');
  update public.shop_items set price = 200  where item_code in ('bg_grid','bg_space','bg_aurora','bg_draft');
  update public.shop_items set price = 750  where item_code in ('frame_pulsar','frame_orbit');
  update public.shop_items set price = 1500 where item_code in ('frame_legend_1','frame_legend_2','frame_legend_3','frame_legend_4');
  update public.economy_config set stage4_generation_enabled = false, stage4_started_at = null where id;

  -- --- (a) success path на присутствующей singleton-строке: firing проходит, ROW_COUNT=1 ---
  select price into crown_before from public.shop_items where item_code='crown';
  begin
    select count(*) into v_config_cnt from public.economy_config where id;
    if v_config_cnt <> 1 then raise exception 'singleton missing (count=%)', v_config_cnt; end if;

    if (select stage4_started_at from public.economy_config where id) is not null then
      raise exception 'FIRING ABORT: start not null'; end if;
    if (select stage4_generation_enabled from public.economy_config where id) then
      raise exception 'FIRING ABORT: generation already true'; end if;
    if exists (select 1 from public.student_daily_quests) or exists (select 1 from public.daily_quest_reward_log) then
      raise exception 'FIRING ABORT: quest data present'; end if;

    with expected(item_code, old_price) as (values
      ('color_red',50),('color_orange',50),('color_green',50),('color_teal',50),
      ('color_blue',50),('color_indigo',50),('color_pink',50),('color_brown',50),
      ('status_emoji_change',30),('crown',600),('golden_nick',700),
      ('title_yaschenko',900),('title_custom',2000),
      ('title_groza',200),('title_elon',150),('title_sanchez',120),('title_derivative',150),
      ('frame_notebook',150),('frame_winter',150),
      ('bg_grid',200),('bg_space',200),('bg_aurora',200),('bg_draft',200),
      ('frame_pulsar',750),('frame_orbit',750),
      ('frame_legend_1',1500),('frame_legend_2',1500),('frame_legend_3',1500),('frame_legend_4',1500)
    )
    select count(*) filter (where s.item_code is null),
           count(*) filter (where s.item_code is not null and s.price is distinct from e.old_price)
      into v_missing, v_badprice
      from expected e left join public.shop_items s on s.item_code = e.item_code;
    if v_missing > 0 then raise exception 'FIRING ABORT: % missing item_code', v_missing; end if;
    if v_badprice > 0 then raise exception 'FIRING ABORT: % unexpected price', v_badprice; end if;

    select active into v_frame from public.shop_items where item_code = 'frame_fire100';
    if v_frame is null then raise exception 'FIRING ABORT: frame_fire100 missing'; end if;
    if v_frame is not true then raise exception 'FIRING ABORT: frame_fire100 not active'; end if;

    update public.shop_items set price = 80
     where item_code in ('color_red','color_orange','color_green','color_teal',
                         'color_blue','color_indigo','color_pink','color_brown');
    update public.shop_items set price = 40   where item_code = 'status_emoji_change';
    update public.shop_items set price = 900  where item_code = 'crown';
    update public.shop_items set price = 1100 where item_code = 'golden_nick';
    update public.shop_items set price = 1300 where item_code = 'title_yaschenko';
    update public.shop_items set price = 3000 where item_code = 'title_custom';
    update public.shop_items set active = false where item_code = 'frame_fire100';
    update public.shop_items set price = 250  where item_code in ('title_groza','title_elon','title_sanchez','title_derivative');
    update public.shop_items set price = 300  where item_code in ('frame_notebook','frame_winter');
    update public.shop_items set price = 380  where item_code in ('bg_grid','bg_space','bg_aurora','bg_draft');
    update public.shop_items set price = 1200 where item_code in ('frame_pulsar','frame_orbit');
    update public.shop_items set price = 2200 where item_code in ('frame_legend_1','frame_legend_2','frame_legend_3','frame_legend_4');

    update public.economy_config
       set stage4_started_at         = coalesce(stage4_started_at, now()),
           stage4_generation_enabled = true
     where id;
    get diagnostics v_row_count = row_count;
    if v_row_count <> 1 then raise exception 'FIRING ABORT: final UPDATE affected % rows', v_row_count; end if;
  exception when others then success_raised := true;
  end;
  select price into crown_after_success from public.shop_items where item_code='crown';
  select stage4_generation_enabled, stage4_started_at into gen_after_success, started_after_success
    from public.economy_config where id;

  -- reset to dormant для второго sub-check (внутритестовая подготовка; полное восстановление
  -- dev делает общий rollback блока в конце файла)
  update public.shop_items set price = 50
   where item_code in ('color_red','color_orange','color_green','color_teal',
                       'color_blue','color_indigo','color_pink','color_brown');
  update public.shop_items set price = 30   where item_code = 'status_emoji_change';
  update public.shop_items set price = 600  where item_code = 'crown';
  update public.shop_items set price = 700  where item_code = 'golden_nick';
  update public.shop_items set price = 900  where item_code = 'title_yaschenko';
  update public.shop_items set price = 2000 where item_code = 'title_custom';
  update public.shop_items set active = true where item_code = 'frame_fire100';
  update public.shop_items set price = 200  where item_code = 'title_groza';
  update public.shop_items set price = 150  where item_code in ('title_elon','title_derivative');
  update public.shop_items set price = 120  where item_code = 'title_sanchez';
  update public.shop_items set price = 150  where item_code in ('frame_notebook','frame_winter');
  update public.shop_items set price = 200  where item_code in ('bg_grid','bg_space','bg_aurora','bg_draft');
  update public.shop_items set price = 750  where item_code in ('frame_pulsar','frame_orbit');
  update public.shop_items set price = 1500 where item_code in ('frame_legend_1','frame_legend_2','frame_legend_3','frame_legend_4');
  update public.economy_config set stage4_generation_enabled = false, stage4_started_at = null where id;

  -- --- (b) missing-config abort: удалить singleton-строку внутри теста, прогнать тот же путь ---
  select price into crown_before from public.shop_items where item_code='crown';
  select active into frame_before from public.shop_items where item_code='frame_fire100';
  delete from public.economy_config where id;
  begin
    select count(*) into v_config_cnt from public.economy_config where id;
    if v_config_cnt <> 1 then
      raise exception 'FIRING ABORT: economy_config singleton missing (count=%)', v_config_cnt;
    end if;
    -- (недостижимо при отсутствующей строке — singleton-guard останавливает раньше)
    update public.shop_items set price = 80 where item_code = 'crown';
    update public.economy_config set stage4_generation_enabled = true where id;
  exception when others then abort_raised := true;
  end;
  select price into crown_after_abort from public.shop_items where item_code='crown';
  select active into frame_after_abort from public.shop_items where item_code='frame_fire100';

  insert into u08_report values (9,'B2-U23','singleton-guard: success ROW_COUNT=1 + missing-config abort, no partial firing',
    (not success_raised) and crown_after_success=900 and gen_after_success=true and started_after_success is not null
    and abort_raised and crown_after_abort=crown_before and crown_after_abort=600
    and frame_after_abort=frame_before and frame_after_abort=true,
    format('success(raised=%s crown=%s gen=%s started_set=%s) abort(raised=%s crown %s->%s frame %s->%s)',
      success_raised, crown_after_success, gen_after_success, (started_after_success is not null),
      abort_raised, crown_before, crown_after_abort, frame_before, frame_after_abort));
end $$;

select seq,code,title,case when pass then 'PASS' else 'FAIL' end as result,detail from u08_report order by seq;
rollback;
