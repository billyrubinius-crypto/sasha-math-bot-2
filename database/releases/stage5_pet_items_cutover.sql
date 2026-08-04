-- =============================================================================
-- database/releases/stage5_pet_items_cutover.sql — включение предметов комнаты (PET3)
--
-- ЭТО НЕ МИГРАЦИЯ. Применение 070 оставляет предметы спящими (`active=false`): ученик не
-- должен купить лежанку раньше, чем комната научится её показывать. Скрипт выполняется
-- вручную ПОСЛЕ деплоя клиента с рендером предметов.
--
-- Аварийная остановка при: отсутствии шести предметов; уже активных предметах; неожиданной
-- цене; предмете, попавшем в ротацию (он оказался бы в требовании коллекционного бонуса —
-- ровно то, чего решение PET3 избегает).
-- =============================================================================
do $$
declare
  v_rows int;
begin
  if (select count(*) from public.shop_items where slot in ('pet_bed', 'pet_toy')) <> 6 then
    raise exception 'ITEMS FIRING ABORT: в каталоге не шесть предметов комнаты';
  end if;

  if exists (select 1 from public.shop_items where slot in ('pet_bed', 'pet_toy') and active) then
    raise exception 'ITEMS FIRING ABORT: предметы уже в продаже';
  end if;

  if exists (select 1 from public.shop_items
              where slot = 'pet_bed' and price <> 600)
     or exists (select 1 from public.shop_items
                 where slot = 'pet_toy' and price <> 300) then
    raise exception 'ITEMS FIRING ABORT: цены отличаются от утверждённых (лежанка 600, игрушка 300)';
  end if;

  if exists (select 1 from public.shop_items
              where slot in ('pet_bed', 'pet_toy') and availability <> 'always') then
    raise exception 'ITEMS FIRING ABORT: предмет в ротации — он попадёт в бонус за коллекцию';
  end if;

  update public.shop_items set active = true where slot in ('pet_bed', 'pet_toy');
  get diagnostics v_rows = row_count;
  if v_rows <> 6 then
    raise exception 'ITEMS FIRING ABORT: активировано % предметов вместо 6', v_rows;
  end if;

  raise notice 'Pet room items FIRED: 3 лежанки по 600 и 3 игрушки по 300 в продаже';
end $$;

-- =============================================================================
-- ROLLBACK (снимает с продажи; купленные предметы остаются у владельцев):
--   begin;
--     update public.shop_items set active = false where slot in ('pet_bed', 'pet_toy');
--   commit;
-- =============================================================================
