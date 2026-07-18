-- =============================================================================
-- 026_stage4_teacher_quest_catalog_fix.sql — Исправление неоднозначной ссылки на колонку
-- в admin RPC каталога U03 (Bot 2.0, Stage 4)
--
-- Зачем: живая browser-проверка U03 (после применения 025) обнаружила, что
-- admin_upsert_life_quest_template и admin_set_life_quest_template_active падают с
-- ошибкой Postgres 42702 "column reference \"template_code\" is ambiguous". Причина:
-- `RETURNS TABLE(template_code text, ...)` в PL/pgSQL автоматически объявляет OUT-параметры
-- как переменные функции с теми же именами, что и колонки таблицы life_quest_templates.
-- Неквалифицированные `where template_code = ...` и `on conflict (template_code)` внутри тела
-- функции стали неоднозначны между этой OUT-переменной и реальной колонкой таблицы.
-- admin_list_life_quest_templates() (language sql, без PL/pgSQL-области видимости) этой
-- проблеме не подвержен и работает штатно — не трогается.
--
-- Исправление: обе функции возвращают `public.life_quest_templates` (одна строка, без OUT-
-- параметров, совпадающих с именами колонок) вместо RETURNS TABLE; тело использует локальную
-- rowtype-переменную и явно квалифицированные обращения к таблице. Логика (валидация,
-- upsert-по-code, отдельный toggle active, отсутствие удаления) не меняется. Смена типа
-- возврата требует DROP + CREATE (CREATE OR REPLACE не допускает смену списка выходных
-- столбцов), поэтому старые сигнатуры явно удаляются перед созданием новых.
--
-- Клиент (js/teacher-quests.js) не меняется: он читает только error, данные всегда
-- перечитывает через admin_list_life_quest_templates() — смена формы возврата на клиент не
-- влияет.
-- =============================================================================

drop function if exists public.admin_upsert_life_quest_template(text, text, text, text, integer);
drop function if exists public.admin_set_life_quest_template_active(text, boolean);

-- --- admin_upsert_life_quest_template: fixed, returns a single row ---------------------------
create function public.admin_upsert_life_quest_template(
  p_template_code text,
  p_name          text,
  p_description   text,
  p_category      text,
  p_weight        integer
)
 returns public.life_quest_templates
 language plpgsql
as $function$
declare
  v_code text := trim(coalesce(p_template_code, ''));
  v_name text := trim(coalesce(p_name, ''));
  v_desc text := trim(coalesce(p_description, ''));
  v_cat  text := trim(coalesce(p_category, ''));
  v_row  public.life_quest_templates%rowtype;
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

  select * into v_row from public.life_quest_templates where template_code = v_code;
  return v_row;
end;
$function$;

-- --- admin_set_life_quest_template_active: fixed, returns a single row -----------------------
create function public.admin_set_life_quest_template_active(
  p_template_code text,
  p_active        boolean
)
 returns public.life_quest_templates
 language plpgsql
as $function$
declare
  v_row public.life_quest_templates%rowtype;
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

  select * into v_row from public.life_quest_templates where template_code = p_template_code;
  return v_row;
end;
$function$;

-- =============================================================================
-- ROLLBACK (только функции; данные каталога не затрагиваются):
--   drop function if exists public.admin_set_life_quest_template_active(text, boolean);
--   drop function if exists public.admin_upsert_life_quest_template(text, text, text, text, integer);
--   -- восстановить RETURNS TABLE-версии (с известным багом 42702) из 025_*.sql при необходимости.
-- =============================================================================
