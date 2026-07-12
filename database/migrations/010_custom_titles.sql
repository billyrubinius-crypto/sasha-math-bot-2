-- Миграция 010 — персональный титул с модерацией (задача S8, этап 2)
--
-- Что создаёт: одну заявку/оплаченное право на ученика (student_custom_titles),
-- постоянный товар title_custom, RPC submit_custom_title / review_custom_title и
-- точечные защитные ветки в существующих buy_item / equip_item.
--
-- Решения пользователя от 2026-07-12:
-- 1. Первая отправка стоит 2000 бубликов; отказ не возвращает деньги, но повторные
--    отправки после rejected бесплатны.
-- 2. После approved текст фиксируется и больше не отправляется на бесплатную замену.
-- 3. Текст: 3-24 символа, одна строка; причина отказа обязательна (3-200 символов).
-- 4. Учителю нужна только очередь pending, без отдельного архива решений в v1.
-- 5. RLS остаётся выключен как принятый dev-риск T10. До T10 pending-текст скрыт UI,
--    но не защищён от прямого anon-запроса; реальных учеников подключать нельзя.
--
-- Архитектура:
-- - shop_items хранит общий товар и цену;
-- - student_custom_titles хранит персональный текст и состояние модерации;
-- - student_items получает title_custom только после approved;
-- - student_equipment.variant хранит только ОДОБРЕННЫЙ текст надетого титула;
-- - деньги меняются исключительно через add_huikons.
--
-- Миграция повторно применима: таблица создаётся if not exists, сид — on conflict,
-- функции — create or replace.

-- --- Заявка и оплаченное право -------------------------------------------------

create table if not exists public.student_custom_titles (
  student_id       bigint       primary key references public.students (telegram_id),
  title_text       text         not null,
  status           text         not null check (status in ('pending', 'rejected', 'approved')),
  teacher_comment  text,
  purchased_at     timestamptz  not null default now(),
  submitted_at     timestamptz  not null default now(),
  reviewed_at      timestamptz,
  updated_at       timestamptz  not null default now(),

  check (char_length(title_text) between 3 and 24),
  check (title_text = btrim(title_text)),
  check (title_text !~ '[[:cntrl:]]'),
  check (teacher_comment is null or char_length(btrim(teacher_comment)) between 3 and 200),
  check (
    (status = 'pending'  and teacher_comment is null     and reviewed_at is null) or
    (status = 'rejected' and teacher_comment is not null and reviewed_at is not null) or
    (status = 'approved' and teacher_comment is null     and reviewed_at is not null)
  )
);

alter table public.student_custom_titles disable row level security;

-- --- Постоянный товар ----------------------------------------------------------

insert into public.shop_items
  (item_code, name, item_kind, slot, price, availability, rotation_bundle,
   condition_achievement, render_payload, sort_order)
values
  ('title_custom', 'Персональный титул', 'cosmetic', 'title', 2000, 'always',
   null, null, null, 43)
on conflict (item_code) do nothing;

-- --- submit_custom_title: первая оплата или бесплатный retry -------------------

create or replace function public.submit_custom_title(p_student_id bigint, p_title_text text)
 returns json
 language plpgsql
as $function$
declare
  v_title       text;
  v_status      text;
  v_price       integer;
  v_balance     integer;
  v_new_balance integer;
begin
  if p_title_text is null or p_title_text ~ '[[:cntrl:]]' then
    raise exception 'Титул должен быть одной строкой без управляющих символов';
  end if;

  v_title := regexp_replace(btrim(p_title_text), '[[:space:]]+', ' ', 'g');
  if char_length(v_title) < 3 or char_length(v_title) > 24 then
    raise exception 'Длина титула должна быть от 3 до 24 символов';
  end if;

  -- Общий замок на ученика сериализует двойной клик и денежные операции.
  select huikons into v_balance
    from public.students
    where telegram_id = p_student_id
    for update;
  if v_balance is null then
    raise exception 'Ученик % не найден', p_student_id;
  end if;

  -- Замок заявки синхронизирует отправку с одновременным решением учителя.
  select status into v_status
    from public.student_custom_titles
    where student_id = p_student_id
    for update;

  if v_status = 'pending' then
    raise exception 'Титул уже находится на модерации';
  elsif v_status = 'approved' then
    raise exception 'Персональный титул уже одобрен и не может быть изменён';
  elsif v_status = 'rejected' then
    update public.student_custom_titles
      set title_text = v_title,
          status = 'pending',
          teacher_comment = null,
          submitted_at = now(),
          reviewed_at = null,
          updated_at = now()
      where student_id = p_student_id;

    return json_build_object(
      'status', 'pending',
      'balance', v_balance,
      'charged', 0
    );
  end if;

  select price into v_price
    from public.shop_items
    where item_code = 'title_custom' and active;
  if v_price is null then
    raise exception 'Персональный титул сейчас недоступен';
  end if;
  if v_balance < v_price then
    raise exception 'Недостаточно бубликов: нужно %, есть %', v_price, v_balance;
  end if;

  select new_balance into v_new_balance
    from public.add_huikons(p_student_id, -v_price, 'buy_title_custom');

  insert into public.student_custom_titles
    (student_id, title_text, status)
  values
    (p_student_id, v_title, 'pending');

  return json_build_object(
    'status', 'pending',
    'balance', v_new_balance,
    'charged', v_price
  );
end;
$function$;

-- --- review_custom_title: атомарное решение и публикация -----------------------

create or replace function public.review_custom_title(
  p_student_id bigint,
  p_decision text,
  p_teacher_comment text default null
)
 returns json
 language plpgsql
as $function$
declare
  v_title   text;
  v_status  text;
  v_comment text;
begin
  if p_decision is null or p_decision not in ('approved', 'rejected') then
    raise exception 'Решение должно быть approved или rejected';
  end if;

  select title_text, status into v_title, v_status
    from public.student_custom_titles
    where student_id = p_student_id
    for update;
  if v_status is null then
    raise exception 'Заявка ученика % не найдена', p_student_id;
  end if;
  if v_status <> 'pending' then
    raise exception 'Заявка уже рассмотрена: %', v_status;
  end if;

  if p_decision = 'rejected' then
    if p_teacher_comment is null or p_teacher_comment ~ '[[:cntrl:]]' then
      raise exception 'При отказе нужна причина одной строкой';
    end if;
    v_comment := regexp_replace(btrim(p_teacher_comment), '[[:space:]]+', ' ', 'g');
    if char_length(v_comment) < 3 or char_length(v_comment) > 200 then
      raise exception 'Причина отказа должна быть от 3 до 200 символов';
    end if;

    update public.student_custom_titles
      set status = 'rejected',
          teacher_comment = v_comment,
          reviewed_at = now(),
          updated_at = now()
      where student_id = p_student_id;

    return json_build_object('status', 'rejected');
  end if;

  update public.student_custom_titles
    set status = 'approved',
        teacher_comment = null,
        reviewed_at = now(),
        updated_at = now()
    where student_id = p_student_id;

  insert into public.student_items (student_id, item_code, quantity)
    values (p_student_id, 'title_custom', 1)
    on conflict (student_id, item_code)
    do update set quantity = greatest(student_items.quantity, 1), updated_at = now();

  insert into public.student_equipment (student_id, slot, item_code, variant)
    values (p_student_id, 'title', 'title_custom', v_title)
    on conflict (student_id, slot)
    do update set item_code = excluded.item_code,
                  variant = excluded.variant,
                  updated_at = now();

  return json_build_object('status', 'approved', 'title_text', v_title);
end;
$function$;

-- --- buy_item: запрещаем обход модерации через старую точку покупки ------------

create or replace function public.buy_item(p_student_id bigint, p_item_code text, p_variant text default null)
 returns json
 language plpgsql
as $function$
declare
  v_item        shop_items%rowtype;
  v_bundle      integer;
  v_balance     integer;
  v_new_balance integer;
begin
  select * into v_item from shop_items where item_code = p_item_code and active;
  if v_item.item_code is null then
    raise exception 'Товар % не найден или снят с продажи', p_item_code;
  end if;

  if p_item_code = 'title_custom' then
    raise exception 'Персональный титул покупается только через отправку на модерацию';
  end if;

  -- Щит стрика: делегируем в проверенную RPC G9 (лимит 2, цена — там)
  if v_item.item_kind = 'shield' then
    return buy_streak_shield(p_student_id);
  end if;

  -- Ротация: товар должен быть на витрине ТЕКУЩЕГО сезона
  if v_item.availability = 'rotation' then
    v_bundle := ensure_season_rotation();
    if v_bundle is null or v_bundle <> v_item.rotation_bundle then
      raise exception 'Товар «%» сейчас не на витрине', v_item.name;
    end if;
  end if;

  -- Условие-достижение (проверка на стороне БД, не только в UI)
  if v_item.condition_achievement is not null then
    if not exists (select 1 from student_achievements
                     where student_id = p_student_id
                       and achievement_code = v_item.condition_achievement) then
      raise exception 'Для покупки «%» нужно достижение', v_item.name;
    end if;
  end if;

  -- Сервис (смена эмодзи-статуса): вариант обязателен и из пула
  if v_item.item_kind = 'service' then
    if p_variant is null or position(p_variant in coalesce(v_item.render_payload, '')) = 0 then
      raise exception 'Недопустимый вариант для «%»', v_item.name;
    end if;
  end if;

  -- Косметика: повторная покупка владения запрещена
  if v_item.item_kind = 'cosmetic' then
    if exists (select 1 from student_items
                 where student_id = p_student_id and item_code = p_item_code) then
      raise exception 'Уже куплено';
    end if;
  end if;

  -- Баланс: явная проверка под замком (add_huikons клампит нулём, а не отклоняет)
  select huikons into v_balance from students where telegram_id = p_student_id for update;
  if v_balance is null then
    raise exception 'Ученик % не найден', p_student_id;
  end if;
  if v_balance < v_item.price then
    raise exception 'Недостаточно бубликов: нужно %, есть %', v_item.price, v_balance;
  end if;

  select new_balance into v_new_balance
    from add_huikons(p_student_id, -v_item.price, 'buy_' || p_item_code);

  if v_item.item_kind = 'cosmetic' then
    insert into student_items (student_id, item_code, quantity)
      values (p_student_id, p_item_code, 1);
    insert into student_equipment (student_id, slot, item_code)
      values (p_student_id, v_item.slot, p_item_code)
      on conflict (student_id, slot)
      do update set item_code = excluded.item_code, variant = null, updated_at = now();
  elsif v_item.item_kind = 'service' then
    insert into student_equipment (student_id, slot, item_code, variant)
      values (p_student_id, v_item.slot, p_item_code, p_variant)
      on conflict (student_id, slot)
      do update set item_code = excluded.item_code, variant = excluded.variant, updated_at = now();
  end if;

  return json_build_object('item_code', p_item_code, 'balance', v_new_balance);
end;
$function$;

-- --- equip_item: восстанавливаем только одобренный персональный текст -----------

create or replace function public.equip_item(p_student_id bigint, p_slot text, p_item_code text default null)
 returns void
 language plpgsql
as $function$
declare
  v_slot         text;
  v_custom_title text;
begin
  if p_item_code is null then
    delete from student_equipment where student_id = p_student_id and slot = p_slot;
    return;
  end if;

  if p_slot = 'status_emoji' then
    raise exception 'Эмодзи-статус меняется только покупкой смены';
  end if;

  select slot into v_slot from shop_items where item_code = p_item_code and active;
  if v_slot is null or v_slot <> p_slot then
    raise exception 'Товар % не подходит слоту %', p_item_code, p_slot;
  end if;

  if not exists (select 1 from student_items
                   where student_id = p_student_id and item_code = p_item_code) then
    raise exception 'Сначала нужно купить этот предмет';
  end if;

  if p_item_code = 'title_custom' then
    select title_text into v_custom_title
      from student_custom_titles
      where student_id = p_student_id and status = 'approved';
    if v_custom_title is null then
      raise exception 'Персональный титул ещё не одобрен';
    end if;

    insert into student_equipment (student_id, slot, item_code, variant)
      values (p_student_id, p_slot, p_item_code, v_custom_title)
      on conflict (student_id, slot)
      do update set item_code = excluded.item_code,
                    variant = excluded.variant,
                    updated_at = now();
    return;
  end if;

  insert into student_equipment (student_id, slot, item_code)
    values (p_student_id, p_slot, p_item_code)
    on conflict (student_id, slot)
    do update set item_code = excluded.item_code, variant = null, updated_at = now();
end;
$function$;
