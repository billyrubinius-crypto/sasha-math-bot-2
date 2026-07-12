-- Миграция 007 — щит стрика: первый товар (задача G9)
--
-- Щит замораживает стрик при пропуске ровно одного дня. Цена 40 бубликов, не больше
-- 2 в запасе. SPEC_STAGE1.md раздел 4, GAME_DESIGN.md §4.
--
-- ---------------------------------------------------------------------------
-- ЗАЧЕМ ОТДЕЛЬНАЯ ТАБЛИЦА streak_shield_uses, а не только счётчик в student_items.
--
-- processStreak() (teacher.html) по фиксу T15 пересчитывает всю цепочку стрика с нуля
-- при каждом приёме ежедневки (самоисцеление: пачка проверки и приём из архива не
-- в хронологическом порядке не портят счёт). Если щит «сшивает» 1-дневный разрыв, но
-- хранить только счётчик израсходованных щитов, то на КАЖДОМ следующем пересчёте тот же
-- исторический разрыв будет виден снова, и наивный код списал бы ещё один щит — щиты
-- утекут на ровном месте. Чтобы сшивание было идемпотентным, надо персистить, КАКИЕ
-- ИМЕННО дни покрыты щитом (одного числа-счётчика для этого мало). Это и хранит
-- streak_shield_uses: одна строка = «этот пропущенный день покрыт щитом у этого ученика».
-- Пересчёт строит цепочку по объединению принятых ежедневок и покрытых дней, поэтому
-- повторный пересчёт видит день уже покрытым и щит второй раз не тратит.
-- ---------------------------------------------------------------------------
--
-- FK на students.telegram_id, как везде. RLS не включаем (тот же принятый риск, что
-- у всего проекта — ROADMAP.md T10; не создаёт дыры сверх существующей).

create table if not exists public.streak_shield_uses (
  id           uuid         primary key default gen_random_uuid(),
  student_id   bigint       not null references public.students (telegram_id),
  bridged_date date         not null,                 -- пропущенный день, покрытый щитом
  created_at   timestamptz  not null default now(),
  unique (student_id, bridged_date)                   -- один день покрывается один раз
);

create index if not exists idx_streak_shield_uses_student
  on public.streak_shield_uses (student_id);

-- Явно выключаем RLS: в dev-Supabase новые таблицы иногда создаются с включённым RLS без
-- политик (зафиксировано в PROGRESS.md, запись F2 — тогда так залипли 5 таблиц). При
-- включённом RLS без политики anon-ключ молча читает 0 строк и получает отказ на insert,
-- из-за чего consume_streak_shield падает. Весь проект работает без RLS (принятый риск T10),
-- эта таблица — не исключение.
alter table public.streak_shield_uses disable row level security;

-- buy_streak_shield — атомарная покупка щита (правило 2 BOT2_CONTEXT: списание бубликов
-- только через add_huikons; RPC вызывает её внутри своей транзакции, не дублируя логику).
-- Проверки лимита (≤2) и баланса (≥40) атомарны с инкрементом за счёт for update:
--   * если строка инвентаря уже есть (quantity ≥ 1) — она блокируется, второй
--     одновременный вызов ждёт коммита и получает актуальный quantity, лимит не
--     превышается;
--   * если строки ещё нет (quantity = 0) — два гонящихся вызова оба дойдут до
--     insert ... on conflict do update, итог quantity = 2 (оба реально купили по 40,
--     это в пределах лимита), выше 2 не уйдёт.
create or replace function public.buy_streak_shield(p_student_id bigint)
 returns json
 language plpgsql
as $function$
declare
  v_price  integer := 40;
  v_max    integer := 2;
  v_qty    integer;
  v_balance integer;
  v_new_balance integer;
begin
  select quantity into v_qty
    from student_items
    where student_id = p_student_id and item_code = 'streak_shield'
    for update;
  if v_qty is null then v_qty := 0; end if;

  if v_qty >= v_max then
    raise exception 'Лимит: не больше % щитов в запасе', v_max;
  end if;

  select huikons into v_balance
    from students
    where telegram_id = p_student_id
    for update;
  if v_balance is null then
    raise exception 'Ученик % не найден', p_student_id;
  end if;
  if v_balance < v_price then
    raise exception 'Недостаточно бубликов: нужно %, есть %', v_price, v_balance;
  end if;

  select new_balance into v_new_balance
    from add_huikons(p_student_id, -v_price, 'buy_streak_shield');

  insert into student_items (student_id, item_code, quantity)
    values (p_student_id, 'streak_shield', 1)
    on conflict (student_id, item_code)
    do update set quantity = student_items.quantity + 1, updated_at = now();

  select quantity into v_qty
    from student_items
    where student_id = p_student_id and item_code = 'streak_shield';

  return json_build_object('quantity', v_qty, 'balance', v_new_balance);
end;
$function$;

-- consume_streak_shield — атомарно «сшить» один пропущенный день щитом. Вызывается из
-- processStreak при обнаружении 1-дневного разрыва перед только что принятой ежедневкой.
-- Возвращает true, если день покрыт (списали щит сейчас ИЛИ он уже был покрыт раньше —
-- идемпотентно), false, если щита нет и покрыть нечем.
create or replace function public.consume_streak_shield(p_student_id bigint, p_bridged_date date)
 returns boolean
 language plpgsql
as $function$
declare
  v_qty integer;
begin
  -- Уже покрыт — идемпотентно, второй щит не тратим.
  if exists (select 1 from streak_shield_uses
               where student_id = p_student_id and bridged_date = p_bridged_date) then
    return true;
  end if;

  select quantity into v_qty
    from student_items
    where student_id = p_student_id and item_code = 'streak_shield'
    for update;

  if v_qty is null or v_qty <= 0 then
    return false;                                     -- щита нет — разрыв не сшиваем
  end if;

  insert into streak_shield_uses (student_id, bridged_date)
    values (p_student_id, p_bridged_date)
    on conflict (student_id, bridged_date) do nothing;

  update student_items
    set quantity = quantity - 1, updated_at = now()
    where student_id = p_student_id and item_code = 'streak_shield';

  return true;
end;
$function$;
