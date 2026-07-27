-- =============================================================================
-- b2_stabilize_inventory.sql — стабилизационный этап, задача 5.
-- Инвентарь: владение постоянно, предмет завершённого сезона надевается, чужой — нет.
-- Выполняется владельцем БД после миграций 051–053. Всё откатывается (ROLLBACK).
--
-- Покрывает обязательные сценарии отчёта:
--   ИНВЕНТАРЬ
--     1. купленный предмет текущего сезона отображается;
--     2. предмет завершённого сезона отображается;
--     3. предмет, отсутствующий в текущем магазине, можно надеть;
--     4. неприобретённый предмет надеть нельзя;
--     5. экипировка переживает «перезагрузку» (состояние в БД, а не в клиенте);
--     6. снятие возвращает базовое оформление;
--     7. витрина и экипировка не перезаписывают друг друга;
--     8. глобальный фон остаётся надетым (слот background в student_equipment).
--   Плюс: снятый с продажи (active = false) предмет надевается; удалить каталожную
--   строку, которой владеет ученик, нельзя.
--
-- В конце — ДИАГНОСТИКА: список косметики без render_payload. Она не выдумывается:
-- у титулов и короны payload пуст по устройству каталога (миграции 008/010), превью
-- строится по слоту. Запрос показывает, есть ли пустой payload там, где он действительно
-- нужен (frame / background / name_color).
-- =============================================================================

begin;

-- --- ДИАГНОСТИКА (до теста, чтобы synthetic-правки не попали в выборку) -----------------------
-- Косметика без render_payload там, где он несёт оформление. Пустой результат = fallback
-- показывать не для чего. Непустой список нужно перенести в отчёт: эти payload НЕ выдумываются,
-- инвентарь и магазин рисуют для таких предметов нейтральное превью по слоту.
select item_code, name, slot, availability, rotation_bundle, active
  from public.shop_items
 where item_kind = 'cosmetic'
   and slot in ('frame', 'background', 'name_color')
   and (render_payload is null or btrim(render_payload) = '')
 order by slot, item_code;

do $test$
declare
  v_student  bigint := 995053001;
  v_other    bigint := 995053002;
  v_season   bigint;
  v_rot      text;      -- ротационный предмет НЕ текущего бандла (предмет прошлого сезона)
  v_rot_slot text;
  v_always   text;      -- предмет постоянной витрины
  v_always_slot text;
  v_bundle   integer;
  v_failed   text;
  v_cnt      integer;
  v_row      record;
begin
  v_season := public.current_season_id();
  if v_season is null then
    v_season := public.start_next_season(true);
  end if;

  insert into public.students (telegram_id, name, telegram_username, huikons, rating, lives, current_streak)
  values (v_student, 'STAB-INV synthetic', 'stab_inv', 100000, 0, 3, 0),
         (v_other,   'STAB-INV2 synthetic','stab_inv2', 0, 0, 3, 0);

  -- Бандл текущего сезона (создастся, если его ещё нет).
  select bundle into v_bundle from public.season_bundles where season_id = v_season;
  if v_bundle is null then
    select min(rotation_bundle) into v_bundle
      from public.shop_items
     where rotation_bundle is not null and active
       and rotation_bundle not in (select bundle from public.season_bundles);
    if v_bundle is not null then
      insert into public.season_bundles (season_id, bundle) values (v_season, v_bundle)
        on conflict (season_id) do nothing;
    end if;
  end if;

  -- Предмет ДРУГОГО (не текущего) бандла = «предмет завершённого сезона»: в магазине его
  -- сейчас нет и купить его нельзя.
  select item_code, slot into v_rot, v_rot_slot
    from public.shop_items
   where availability = 'rotation'
     and item_kind = 'cosmetic'
     and (v_bundle is null or rotation_bundle is distinct from v_bundle)
   order by rotation_bundle, sort_order
   limit 1;
  if v_rot is null then
    raise exception 'SKIP-FAIL: в каталоге нет ротационного предмета вне текущего бандла';
  end if;

  select item_code, slot into v_always, v_always_slot
    from public.shop_items
   where availability = 'always' and item_kind = 'cosmetic' and slot = 'name_color'
   order by sort_order limit 1;

  -- Владение предметом прошлого сезона (как если бы он был куплен тогда, когда продавался).
  insert into public.student_items (student_id, item_code, quantity)
  values (v_student, v_rot, 1);

  -- Покупка предмета текущей витрины обычным путём.
  perform public.buy_item(v_student, v_always, null);

  perform set_config('request.jwt.claims',
    json_build_object('app_role', 'student', 'telegram_id', v_student::text)::text, true);

  -- --- 1 и 2: оба предмета видны в инвентаре -------------------------------------------------
  if not exists (select 1 from public.get_student_inventory_self() i where i.item_code = v_always) then
    raise exception 'FAIL: купленный предмет текущего сезона не виден в инвентаре';
  end if;
  if not exists (select 1 from public.get_student_inventory_self() i where i.item_code = v_rot) then
    raise exception 'FAIL: предмет завершённого сезона не виден в инвентаре';
  end if;

  select * into v_row from public.get_student_inventory_self() i where i.item_code = v_rot;
  if v_row.available_now then
    raise exception 'FAIL: предмет вне текущего бандла помечен как доступный в магазине';
  end if;

  -- --- 3: предмет, которого нет в магазине, надевается ---------------------------------------
  perform public.equip_item(v_student, v_rot_slot, v_rot);
  if not exists (select 1 from public.student_equipment
                  where student_id = v_student and slot = v_rot_slot and item_code = v_rot) then
    raise exception 'FAIL: предмет прошлого сезона не надет';
  end if;

  -- ...и остаётся надетым даже после снятия с продажи (active = false).
  update public.shop_items set active = false where item_code = v_rot;
  perform public.equip_item(v_student, v_rot_slot, null);
  perform public.equip_item(v_student, v_rot_slot, v_rot);
  if not exists (select 1 from public.student_equipment
                  where student_id = v_student and slot = v_rot_slot and item_code = v_rot) then
    raise exception 'FAIL: снятый с продажи (active=false) предмет не надевается';
  end if;
  if not exists (select 1 from public.get_student_inventory_self() i where i.item_code = v_rot) then
    raise exception 'FAIL: предмет с active=false пропал из инвентаря';
  end if;

  -- --- 4: неприобретённый предмет надеть нельзя (проверка на сервере, не в клиенте) ----------
  v_failed := null;
  begin
    perform public.equip_item(v_other, v_rot_slot, v_rot);
  exception when others then v_failed := sqlerrm;
  end;
  if v_failed is null then
    raise exception 'FAIL: чужой/некупленный предмет удалось надеть подменой запроса';
  end if;

  -- --- В одном слоте только один предмет -----------------------------------------------------
  select count(*) into v_cnt from public.student_equipment
   where student_id = v_student and slot = v_rot_slot;
  if v_cnt <> 1 then
    raise exception 'FAIL: в слоте % оказалось % предметов', v_rot_slot, v_cnt;
  end if;

  -- --- 5: состояние живёт в БД, а не в клиенте («перезагрузка» = повторное чтение) -----------
  select * into v_row from public.get_student_inventory_self() i where i.item_code = v_rot;
  if not v_row.is_equipped then
    raise exception 'FAIL: после повторного чтения предмет не считается надетым';
  end if;

  -- --- 7: витрина и экипировка независимы ----------------------------------------------------
  perform public.set_showcase(v_student, 1::smallint, 'item', v_always);
  if not exists (select 1 from public.student_equipment
                  where student_id = v_student and slot = v_rot_slot and item_code = v_rot) then
    raise exception 'FAIL: постановка на витрину сбросила экипировку';
  end if;
  select * into v_row from public.get_student_inventory_self() i where i.item_code = v_always;
  if v_row.showcase_position <> 1 then
    raise exception 'FAIL: витрина не отражена в инвентаре';
  end if;
  -- предмет на витрине НЕ обязан быть надетым и наоборот
  perform public.equip_item(v_student, v_always_slot, null);
  if not exists (select 1 from public.student_showcase
                  where student_id = v_student and position = 1 and ref_code = v_always) then
    raise exception 'FAIL: снятие предмета убрало его с витрины';
  end if;

  -- --- 6: снятие возвращает базовое оформление ------------------------------------------------
  perform public.equip_item(v_student, v_rot_slot, null);
  if exists (select 1 from public.student_equipment
              where student_id = v_student and slot = v_rot_slot) then
    raise exception 'FAIL: снятие не удалило строку экипировки — базовое оформление не вернулось';
  end if;

  -- --- 8: глобальный фон -----------------------------------------------------------------------
  -- Фон — обычный слот background; экипировка хранится там же, значит применяется на всех
  -- экранах Mini App (глобальный слой #app-bg-layer), а не только в профиле.
  declare
    v_bg text;
  begin
    select item_code into v_bg from public.shop_items
     where slot = 'background' and item_kind = 'cosmetic' order by sort_order limit 1;
    if v_bg is not null then
      insert into public.student_items (student_id, item_code, quantity)
      values (v_student, v_bg, 1)
      on conflict (student_id, item_code) do nothing;
      update public.shop_items set active = false where item_code = v_bg;   -- «сезон закончился»
      perform public.equip_item(v_student, 'background', v_bg);
      if not exists (select 1 from public.student_equipment
                      where student_id = v_student and slot = 'background' and item_code = v_bg) then
        raise exception 'FAIL: фон завершённого сезона не надевается';
      end if;
      if (select render_payload from public.shop_items where item_code = v_bg) is null then
        raise exception 'FAIL: у фона пропал render_payload — предмет невоспроизводим';
      end if;
    end if;
  end;

  -- --- Каталожную строку, которой владеет ученик, удалить нельзя -------------------------------
  v_failed := null;
  begin
    delete from public.shop_items where item_code = v_rot;
  exception when others then v_failed := sqlerrm;
  end;
  if v_failed is null then
    raise exception 'FAIL: удалось удалить предмет, которым владеет ученик';
  end if;

  raise notice 'PASS b2_stabilize_inventory: ownership is permanent, past-season items equippable';
end
$test$;

select 'PASS b2_stabilize_inventory; transaction will be rolled back' as summary;

rollback;
