-- =============================================================================
-- 025_stage4_teacher_quest_catalog.sql — Admin RPC каталога жизненных челленджей
-- (Bot 2.0, Stage 4, карточка U03; SPEC_STAGE4.md §§3, 9)
--
-- Зачем: даёт учителю простое управление справочником `life_quest_templates` (U02A):
-- добавить, изменить текст/категорию/вес, включить/выключить. Никакой истории учеников,
-- completion-статистики или life-выполнений здесь нет и быть не должно (§9 — teacher видит
-- только каталог и траекторию пробников, без life history учеников).
--
-- Три узких RPC:
--   * admin_list_life_quest_templates()  — весь каталог (active и неактивные) для списка UI;
--   * admin_upsert_life_quest_template(...) — добавить новый ИЛИ изменить текст/категорию/вес
--     существующего по template_code. code — ключ конфликта, поэтому уже структурно неизменяем
--     после создания: RPC не даёт способа его сменить, только вставить новый или обновить поля
--     существующего. active этим RPC не трогается (чтобы редактирование текста не включало
--     случайно выключенный шаблон) — для этого отдельный RPC ниже;
--   * admin_set_life_quest_template_active(...) — только toggle active; выключение не удаляет
--     строку и не портит уже выданные/сохранённые daily_quest_options/student_daily_quests,
--     ссылающиеся на этот template_code (FK на них и так запрещает удаление, RPC удаления нет).
--
-- Валидация: template_code — стабильный ASCII (^[a-z][a-z0-9_]*$, 2–64 символа), name/
-- description/category — непустые после trim с разумным потолком длины, weight — целое 1..100
-- (положительный и ограниченный: table CHECK уже требует >0, RPC добавляет верхнюю границу,
-- чтобы опечатка не создавала произвольно большой вес для взвешенного random-выбора U02B).
--
-- Production доступ по-прежнему блокирует T10; RLS не менялся (life_quest_templates была и
-- остаётся disable row level security, как весь проект). SECURITY DEFINER не вводится — функции
-- invoker, как везде в схеме.
-- =============================================================================

-- --- 1. Список всего каталога (active и неактивные) для teacher UI --------------------------
create or replace function public.admin_list_life_quest_templates()
 returns table (
   template_code text,
   name          text,
   description   text,
   category      text,
   active        boolean,
   weight        integer,
   created_at    timestamptz,
   updated_at    timestamptz
 )
 language sql
 stable
as $function$
  select template_code, name, description, category, active, weight, created_at, updated_at
    from public.life_quest_templates
   order by category, name;
$function$;

-- --- 2. Добавить новый ИЛИ изменить текст/категорию/вес существующего -----------------------
-- template_code — ключ конфликта: новый код создаёт строку, существующий обновляет её поля.
-- active не трогается (см. заголовок). Возвращает актуальную строку.
create or replace function public.admin_upsert_life_quest_template(
  p_template_code text,
  p_name          text,
  p_description   text,
  p_category      text,
  p_weight        integer
)
 returns table (
   template_code text,
   name          text,
   description   text,
   category      text,
   active        boolean,
   weight        integer,
   created_at    timestamptz,
   updated_at    timestamptz
 )
 language plpgsql
as $function$
declare
  v_code text        := trim(coalesce(p_template_code, ''));
  v_name text        := trim(coalesce(p_name, ''));
  v_desc text        := trim(coalesce(p_description, ''));
  v_cat  text        := trim(coalesce(p_category, ''));
begin
  if v_code !~ '^[a-z][a-z0-9_]{1,63}$' then
    raise exception 'Код шаблона должен начинаться с латинской буквы и содержать только строчные латинские буквы, цифры и "_" (2–64 символа)';
  end if;
  if v_name = '' or char_length(v_name) > 300 then
    raise exception 'Текст задания обязателен (до 300 символов)';
  end if;
  if v_desc = '' or char_length(v_desc) > 1000 then
    raise exception 'Описание обязательно (до 1000 символов)';
  end if;
  if v_cat = '' or char_length(v_cat) > 100 then
    raise exception 'Категория обязательна (до 100 символов)';
  end if;
  if p_weight is null or p_weight < 1 or p_weight > 100 then
    raise exception 'Вес должен быть целым числом от 1 до 100';
  end if;

  insert into public.life_quest_templates (template_code, name, description, category, weight)
    values (v_code, v_name, v_desc, v_cat, p_weight)
  on conflict (template_code) do update
    set name        = excluded.name,
        description = excluded.description,
        category    = excluded.category,
        weight      = excluded.weight,
        updated_at  = now();

  return query
    select t.template_code, t.name, t.description, t.category, t.active, t.weight, t.created_at, t.updated_at
      from public.life_quest_templates t
     where t.template_code = v_code;
end;
$function$;

-- --- 3. Включить/выключить template (не удаляет, не трогает текст/вес) ----------------------
create or replace function public.admin_set_life_quest_template_active(
  p_template_code text,
  p_active        boolean
)
 returns table (
   template_code text,
   name          text,
   description   text,
   category      text,
   active        boolean,
   weight        integer,
   created_at    timestamptz,
   updated_at    timestamptz
 )
 language plpgsql
as $function$
begin
  if p_active is null then
    raise exception 'p_active обязателен';
  end if;

  update public.life_quest_templates
     set active = p_active, updated_at = now()
   where template_code = p_template_code;

  if not found then
    raise exception 'Шаблон % не найден', p_template_code;
  end if;

  return query
    select t.template_code, t.name, t.description, t.category, t.active, t.weight, t.created_at, t.updated_at
      from public.life_quest_templates t
     where t.template_code = p_template_code;
end;
$function$;

-- =============================================================================
-- ROLLBACK (только функции; данные каталога/history не затрагиваются):
--   drop function if exists public.admin_set_life_quest_template_active(text, boolean);
--   drop function if exists public.admin_upsert_life_quest_template(text, text, text, text, integer);
--   drop function if exists public.admin_list_life_quest_templates();
-- =============================================================================
