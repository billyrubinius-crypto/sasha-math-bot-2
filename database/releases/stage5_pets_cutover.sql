-- =============================================================================
-- database/releases/stage5_pets_cutover.sql — РЕАЛЬНЫЙ запуск питомцев (Stage 5)
-- (SPEC_STAGE5_PETS.md §4.6; ECONOMY_V4_PROPOSAL.md §4.11)
--
-- ЭТО НЕ МИГРАЦИЯ. Применение миграции 064 оставляет питомцев спящими: товары `active=false`,
-- `stage5_pets_enabled=false`. Этот скрипт — отдельный осознанный шаг, выполняемый вручную
-- после деплоя клиента с блоком питомца (карточка V3).
--
-- Одна guarded-транзакция: включает три товара и флаг. Любой preflight raise откатывает всё —
-- частичный запуск невозможен.
--
-- Аварийная остановка при: отсутствующей singleton-строке economy_config; уже включённом
-- флаге; уже активных товарах; неверной цене или условии покупки; наличии runtime-строк
-- (питомцев в инвентаре, состояния заботы, оплаченных дней) — это означало бы, что запуск
-- уже происходил.
-- =============================================================================
do $$
declare
  v_config_cnt int;
  v_rows       int;
begin
  select count(*) into v_config_cnt from public.economy_config where id;
  if v_config_cnt <> 1 then
    raise exception 'PETS FIRING ABORT: economy_config singleton отсутствует (count=%)', v_config_cnt;
  end if;

  if (select stage5_pets_enabled from public.economy_config where id) then
    raise exception 'PETS FIRING ABORT: stage5_pets_enabled уже true';
  end if;

  if (select count(*) from public.shop_items where slot = 'pet') <> 3 then
    raise exception 'PETS FIRING ABORT: в каталоге не три питомца';
  end if;

  if exists (select 1 from public.shop_items where slot = 'pet' and active) then
    raise exception 'PETS FIRING ABORT: питомцы уже в продаже';
  end if;

  if exists (select 1 from public.shop_items where slot = 'pet'
              and (price <> 1200 or condition_achievement is distinct from 'rhythm_4')) then
    raise exception 'PETS FIRING ABORT: цена или условие покупки отличаются от утверждённых';
  end if;

  if exists (select 1 from public.student_pet_state)
     or exists (select 1 from public.pet_feed_log)
     or exists (select 1 from public.student_equipment where slot = 'pet') then
    raise exception 'PETS FIRING ABORT: уже есть runtime-данные питомцев — запуск повторный';
  end if;

  update public.shop_items set active = true where slot = 'pet';
  get diagnostics v_rows = row_count;
  if v_rows <> 3 then
    raise exception 'PETS FIRING ABORT: активировано % товаров вместо 3', v_rows;
  end if;

  update public.economy_config set stage5_pets_enabled = true, updated_at = now() where id;
  get diagnostics v_rows = row_count;
  if v_rows <> 1 then
    raise exception 'PETS FIRING ABORT: обновлено % строк конфига вместо 1', v_rows;
  end if;

  raise notice 'Stage 5 PETS FIRED: три питомца в продаже по 1200 с условием rhythm_4, кормление включено';
end $$;

-- =============================================================================
-- ROLLBACK (снимает питомцев с продажи и выключает кормление; купленные питомцы, оплаченные
-- дни и накопленная забота СОХРАНЯЮТСЯ — clawback не предусмотрен):
--   begin;
--     update public.shop_items set active = false where slot = 'pet';
--     update public.economy_config set stage5_pets_enabled = false, updated_at = now() where id;
--   commit;
-- =============================================================================
