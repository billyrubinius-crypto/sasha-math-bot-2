-- Миграция 002 — изоляция payment_date от публичного чтения (ROADMAP.md, задача T9)
--
-- Зачем: payment_date — платёжные данные о несовершеннолетних, сейчас читаются кем угодно вместе
-- со всей таблицей students (RLS выключен, публичный ключ используется и клиентами, и раньше —
-- Apps Script). Ни index.html, ни teacher.html это поле вообще не используют (проверено grep'ом
-- по обоим файлам перед написанием этой миграции) — клиентам оно не нужно.
--
-- Стало возможно дёшево (без Edge Functions), т.к. Apps Script переведён на service_role ключ
-- (ROADMAP.md, T9, шаг 0) — service_role в Supabase по умолчанию обходит RLS, поэтому таблица
-- с RLS без единой policy будет полностью недоступна анонимному ключу (index.html/teacher.html/
-- parent_bot.py), но останется доступна Apps Script.
--
-- students.payment_date НЕ удаляется (правило проекта — не удалять существующие поля), но её
-- значения обнуляются: если оставить их как есть, старые значения остались бы читаемы публично
-- навсегда, и вся миграция потеряла бы смысл.

-- 1. Новая таблица — один платёж-снимок на ученика (текущая модель, как и было в students.payment_date)
create table if not exists public.student_payments (
  student_id bigint primary key,
  payment_date date
);

alter table public.student_payments enable row level security;
-- Ни одной policy не создаётся: RLS без policy = запрет всем, кроме service_role (он обходит RLS
-- по конструкции Supabase). anon-ключ (index.html/teacher.html/parent_bot.py) не получит доступа.

-- 2. Переносим уже накопленные значения, чтобы не потерять историю оплат
insert into public.student_payments (student_id, payment_date)
select telegram_id, payment_date
from public.students
where payment_date is not null
on conflict (student_id) do update set payment_date = excluded.payment_date;

-- 3. Обнуляем старое поле — иначе оно останется читаемым всем через students, сводя миграцию на нет
update public.students set payment_date = null where payment_date is not null;
