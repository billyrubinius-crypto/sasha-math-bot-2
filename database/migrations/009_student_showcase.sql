-- Миграция 009 — витрина профиля: 3 слота, предмет ИЛИ достижение (задача S7, этап 2)
--
-- Зачем отдельная таблица, а не расширение student_equipment (как предполагал ориентир
-- карточки S7 «slot='showcase_1..3'»): student_equipment.item_code жёстко ссылается на
-- shop_items (FK, миграция 008) — это верно для настоящей экипировки (рамка/цвет/титул
-- ДОЛЖНЫ быть реальным товаром), но витрина профиля должна уметь показывать ещё и
-- ДОСТИЖЕНИЯ (student_achievements.achievement_code) — коды из другого, не пересекающегося
-- пространства имён. Одна FK-колонка не может ссылаться на две разные таблицы одновременно;
-- ослаблять FK у student_equipment ради этого — плохая цена за одну фичу (теряем гарантию
-- целостности у настоящей экипировки). Отдельная маленькая таблица с полем-дискриминатором
-- kind — дешевле и не трогает уже проверенную схему S1.
--
-- Валидация владения — внутри RPC set_showcase (тот же принцип, что buy_item/equip_item в
-- S1: проверка не только в UI, хотя тут её обходит только сам ученик, себе — риск карточки
-- S7 признаёт это низким, но раз RPC-проверка дёшева, делаем её всё равно, единообразия ради).
--
-- RLS выключаем сразу явным alter (урок F2/G9/S1: dev-Supabase включает RLS на новых таблицах
-- молча) — тот же принятый риск, что у всего проекта (ROADMAP.md T10).

create table if not exists public.student_showcase (
  id          uuid         primary key default gen_random_uuid(),
  student_id  bigint       not null references public.students (telegram_id),
  position    smallint     not null check (position between 1 and 3),
  kind        text         not null check (kind in ('item', 'achievement')),
  ref_code    text         not null,          -- shop_items.item_code ИЛИ student_achievements.achievement_code
  updated_at  timestamptz  not null default now(),
  created_at  timestamptz  not null default now(),
  unique (student_id, position)               -- один предмет/достижение в слоте
);

alter table public.student_showcase disable row level security;

-- set_showcase — поставить/снять предмет витрины. p_ref_code = null → снять (удалить строку
-- слота), иначе p_kind обязателен и ref_code должен реально принадлежать ученику: владение
-- (student_items) для 'item', получение (student_achievements) для 'achievement'. Апсерт по
-- (student_id, position) — повторный выбор в тот же слот просто переписывает его.
create or replace function public.set_showcase(p_student_id bigint, p_position smallint, p_kind text, p_ref_code text)
 returns void
 language plpgsql
as $function$
begin
  if p_ref_code is null then
    delete from student_showcase where student_id = p_student_id and position = p_position;
    return;
  end if;

  if p_kind = 'item' then
    if not exists (select 1 from student_items where student_id = p_student_id and item_code = p_ref_code) then
      raise exception 'Предмет % не куплен', p_ref_code;
    end if;
  elsif p_kind = 'achievement' then
    if not exists (select 1 from student_achievements where student_id = p_student_id and achievement_code = p_ref_code) then
      raise exception 'Достижение % не получено', p_ref_code;
    end if;
  else
    raise exception 'Неизвестный тип витрины: %', p_kind;
  end if;

  insert into student_showcase (student_id, position, kind, ref_code)
    values (p_student_id, p_position, p_kind, p_ref_code)
    on conflict (student_id, position)
    do update set kind = excluded.kind, ref_code = excluded.ref_code, updated_at = now();
end;
$function$;
