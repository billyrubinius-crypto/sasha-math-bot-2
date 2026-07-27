-- =============================================================================
-- 053_permanent_cosmetic_inventory.sql — стабилизация: купленная косметика остаётся
-- носимой навсегда + серверный инвентарь.
-- (Bot 2.0, стабилизационный этап; правки к 008 S1/S3 и 009 S7)
--
-- ПРОБЛЕМА. Предмет прошлого сезона нельзя было надеть, но можно было выставить на витрину.
--   Ровно две причины, обе найдены в коде:
--     1) СЕРВЕР: equip_item (миграция 008) искал слот как
--            select slot from shop_items where item_code = p_item_code and active
--        — у предмета, снятого с продажи (active = false), экипировка падала с «Товар не
--        подходит слоту». set_showcase (миграция 009) такого гейта не имел и проверял только
--        владение (student_items) — отсюда наблюдаемая асимметрия «на витрину можно, надеть
--        нельзя».
--     2) КЛИЕНТ: единственное место с кнопкой «Надеть» — карточка магазина, а loadShop
--        рисует только active = true и только ротацию ТЕКУЩЕГО бандла (season_bundles).
--        Карточки предмета прошлого сезона на экране просто не было. Исправляется
--        отдельным разделом «Инвентарь» во вкладке «Ещё» (js/student-shop.js).
--
-- РАЗДЕЛЕНИЕ ПОНЯТИЙ (фиксируется этой миграцией):
--     магазин   = shop_items с active = true, для ротации — только бандл текущего сезона
--                 (season_bundles). Это ПРОДАЖА.
--     владение  = student_items (одна строка на предмет). Постоянно, сезоном не ограничено.
--     экипировка= student_equipment, unique(student_id, slot) — в слоте всегда не больше
--                 одного предмета; снятие = удаление строки (возврат базового оформления).
--     витрина   = student_showcase, 3 слота, предмет ИЛИ достижение. Независима от
--                 экипировки: предмет может быть надет и не стоять на витрине и наоборот.
--
-- ВОСПРОИЗВОДИМОСТЬ СТАРЫХ ПРЕДМЕТОВ. Каталог shop_items — постоянный: item_code это PK,
--   на него ссылается FK student_equipment.item_code, и render_payload/name/slot живут именно
--   там, а не в записи о покупке. То есть визуальные параметры не исчезают вместе с окончанием
--   сезона — «снят с продажи» это active = false, а не удаление строки. Единственный
--   оставшийся риск — физическое удаление каталожной строки (student_items.item_code FK не
--   имеет, историческое решение: таблица старше магазина). Закрывается триггером ниже:
--   удалить предмет, которым кто-то владеет/который надет/стоит на витрине, теперь нельзя.
--   Backfill покупок не требуется — данные уже лежат в правильном месте; предметы с пустым
--   render_payload не выдумываются, для них инвентарь показывает безопасный fallback
--   (диагностический запрос — в database/tests/b2_stabilize_inventory.sql).
-- =============================================================================

begin;

-- --- 1. equip_item — экипировка по ВЛАДЕНИЮ, а не по наличию в продаже -----------------------
-- Единственное смысловое изменение против 008: каталожная строка читается без фильтра active.
-- Проверка владения (student_items) остаётся серверной и обязательной — подменой запроса
-- надеть чужой или некупленный предмет нельзя. Остальные правила сохранены дословно:
-- status_emoji меняется только покупкой смены, персональный титул — только после approved,
-- в одном слоте один предмет (unique(student_id, slot)), p_item_code = null снимает слот.
create or replace function public.equip_item(
  p_student_id bigint, p_slot text, p_item_code text default null)
 returns void
 language plpgsql
as $function$
declare
  v_slot         text;
  v_kind         text;
  v_custom_title text;
begin
  if p_item_code is null then
    delete from public.student_equipment where student_id = p_student_id and slot = p_slot;
    return;
  end if;

  if p_slot = 'status_emoji' then
    raise exception 'Эмодзи-статус меняется только покупкой смены';
  end if;

  -- Без `and active`: предмет завершённого сезона снят с ПРОДАЖИ, но принадлежит ученику
  -- и обязан надеваться (задача 5, п.1).
  select slot, item_kind into v_slot, v_kind
    from public.shop_items where item_code = p_item_code;
  if v_slot is null or v_slot <> p_slot then
    raise exception 'Товар % не подходит слоту %', p_item_code, p_slot;
  end if;
  if v_kind not in ('cosmetic', 'service') then
    raise exception 'Товар % не является косметикой', p_item_code;
  end if;

  if not exists (select 1 from public.student_items
                   where student_id = p_student_id and item_code = p_item_code) then
    raise exception 'Сначала нужно купить этот предмет';
  end if;

  if p_item_code = 'title_custom' then
    select title_text into v_custom_title
      from public.student_custom_titles
      where student_id = p_student_id and status = 'approved';
    if v_custom_title is null then
      raise exception 'Персональный титул ещё не одобрен';
    end if;

    insert into public.student_equipment (student_id, slot, item_code, variant)
      values (p_student_id, p_slot, p_item_code, v_custom_title)
      on conflict (student_id, slot)
      do update set item_code = excluded.item_code,
                    variant = excluded.variant,
                    updated_at = now();
    return;
  end if;

  insert into public.student_equipment (student_id, slot, item_code)
    values (p_student_id, p_slot, p_item_code)
    on conflict (student_id, slot)
    do update set item_code = excluded.item_code, variant = null, updated_at = now();
end;
$function$;

-- --- 2. Запрет физического удаления косметики, которой уже владеют ---------------------------
-- «Убрать из магазина» = active = false. Удаление каталожной строки сделало бы купленный
-- предмет невоспроизводимым (пропал бы render_payload) — теперь это невозможно.
create or replace function public.trg_shop_items_protect_owned()
 returns trigger
 language plpgsql
as $function$
begin
  if exists (select 1 from public.student_items      where item_code = old.item_code)
     or exists (select 1 from public.student_equipment where item_code = old.item_code)
     or exists (select 1 from public.student_showcase  where kind = 'item' and ref_code = old.item_code) then
    raise exception
      'Предмет % принадлежит ученикам: снимайте с продажи через active = false, удалять нельзя',
      old.item_code using errcode = '23503';
  end if;
  return old;
end;
$function$;

drop trigger if exists shop_items_protect_owned on public.shop_items;
create trigger shop_items_protect_owned
  before delete on public.shop_items
  for each row execute function public.trg_shop_items_protect_owned();

-- --- 3. get_student_inventory_self — весь инвентарь ученика ------------------------------------
-- Отдаёт ВСЁ, чем ученик владеет, независимо от сезона получения, наличия предмета в текущем
-- магазине, активности предложения и ротации. Источник владения — student_items (постоянный),
-- каталожные атрибуты — shop_items без фильтра active. Щит (item_kind='shield') и разовые
-- услуги без слота в инвентарь косметики не попадают — у них свой виджет.
-- Флаги is_equipped / showcase_position считаются сервером, чтобы клиент не сверял состояние
-- сам. has_render_payload — факт, а НЕ признак поломки: у титулов и короны render_payload
-- пустой по устройству каталога (миграции 008/010), их превью строится по слоту. Флаг нужен
-- для слотов, где payload действительно несёт оформление (frame/background/name_color): если
-- он там пуст, UI даёт нейтральный fallback и ничего не выдумывает.
create or replace function public.get_student_inventory_self()
 returns table(
   item_code          text,
   name               text,
   slot               text,
   item_kind          text,
   render_payload     text,
   has_render_payload boolean,
   available_now      boolean,
   season_id          bigint,
   is_equipped        boolean,
   equipped_variant   text,
   showcase_position  smallint,
   sort_order         integer)
 language plpgsql
 security definer
 set search_path = public, pg_temp
as $function$
#variable_conflict use_column
declare
  v_tid    bigint;
  v_bundle integer;
begin
  if private.current_app_role() is distinct from 'student' then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  v_tid := private.current_telegram_id();
  if v_tid is null or v_tid <= 0 then
    raise exception 'no student identity' using errcode = '42501';
  end if;

  -- Бандл текущего сезона — только чтобы пометить «ещё продаётся»; на возможность
  -- экипировки он не влияет (задача 5, п.9).
  select b.bundle into v_bundle
    from public.season_bundles b
   where b.season_id = public.current_season_id();

  return query
  select si.item_code,
         si.name,
         si.slot,
         si.item_kind,
         si.render_payload,
         (si.render_payload is not null and btrim(si.render_payload) <> ''),
         (si.active and (si.availability = 'always'
                         or (v_bundle is not null and si.rotation_bundle = v_bundle))),
         sb.season_id,
         (eq.item_code is not null),
         eq.variant,
         sc.position,
         si.sort_order
    from public.student_items own
    join public.shop_items si on si.item_code = own.item_code
    left join public.season_bundles sb on sb.bundle = si.rotation_bundle
    left join public.student_equipment eq
           on eq.student_id = v_tid and eq.slot = si.slot and eq.item_code = si.item_code
    left join public.student_showcase sc
           on sc.student_id = v_tid and sc.kind = 'item' and sc.ref_code = si.item_code
   where own.student_id = v_tid
     and si.slot is not null
     and si.item_kind in ('cosmetic', 'service')
   order by si.slot asc, si.sort_order asc, si.name asc;
end;
$function$;

revoke all on function public.get_student_inventory_self() from public, anon;
grant execute on function public.get_student_inventory_self() to authenticated;

commit;

-- =============================================================================
-- ROLLBACK (dev-форк; данные не затрагиваются):
--   begin;
--   drop function if exists public.get_student_inventory_self();
--   drop trigger if exists shop_items_protect_owned on public.shop_items;
--   drop function if exists public.trg_shop_items_protect_owned();
--   -- вернуть equip_item из database/migrations/008_shop_core.sql (раздел equip_item):
--   --   отличие только в `and active` в выборке слота и отсутствии проверки item_kind.
--   commit;
-- =============================================================================
