-- Описание жизненного челленджа необязательно.
-- Форма учителя передаёт пустую строку; сервер по-прежнему ограничивает описание 1000 символами.
create or replace function public.admin_upsert_life_quest_template(
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
  if char_length(v_desc) > 1000 then
    raise exception 'Описание должно содержать не более 1000 символов';
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
