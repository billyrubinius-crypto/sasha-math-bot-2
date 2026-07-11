-- Миграция 003 — индексы под архивные и профильные запросы (ROADMAP.md, задача T7)
--
-- Зачем: часть запросов фильтрует/сортирует по полям без подходящего индекса. Индексы НЕ меняют
-- результаты — только ускоряют; откат безопасен (DROP INDEX). Все — IF NOT EXISTS (можно повторять).
--
-- ВАЖНО: список намеренно короткий. Снимок схемы (database/schema.sql, задача T2) показал, что в БД
-- уже есть индексы idx_assignments_activation (activation_status, scheduled_date),
-- idx_assignments_student_status (student_id, status), idx_assignments_week (week_label, type) и
-- уникальный idx_students_telegram_id. Они покрывают активацию, «мои работы» и архив недель
-- (loadArchiveWeeks идёт по week_label — ведущему столбцу idx_assignments_week). Поэтому здесь
-- добавляются ТОЛЬКО реально недостающие индексы: лишние индексы на assignments (строка на ученика
-- в день, частые bulk-вставки) замедляли бы запись без пользы.

-- Архив/очередь проверки у учителя: loadSubmissions делает eq(status) + order(submitted_at desc).
-- Существующие индексы ведут со student_id, не со status — этот запрос ничем не покрыт, а архив
-- «принятых» растёт быстрее всего.
create index if not exists idx_assignments_status_submitted
  on public.assignments (status, submitted_at desc);

-- История баланса: loadBalanceHistory делает eq(student_id) + order(created_at desc) + limit(20)
-- при каждом открытии профиля. На balance_history сейчас только первичный ключ — полный пробел.
create index if not exists idx_balance_history_student_created
  on public.balance_history (student_id, created_at desc);

-- Сопоставление по username: Apps Script ищет ученика по telegram_username в каждом цикле
-- синхронизации + поиск ученика у учителя. Индекса по username нет.
create index if not exists idx_students_username
  on public.students (telegram_username);
