-- =============================================================================
-- b2_t10d_rehearsal.sql — репетиция импорта legacy-данных (B2-T10D, T10-10D)
-- Выполняется ТОЛЬКО на dev-проекте Bot 2.0, на обезличенных синтетических данных.
-- Реальные ФИО, username и telegram_id здесь не используются: ID из диапазона 9951xxxxx.
--
-- Блоки выполняются ПО ОДНОМУ, сверху вниз. Проверочные блоки сами печатают PASS/FAIL.
-- =============================================================================

-- =============================================================================
-- БЛОК 1. Синтетические данные в staging.
-- Форма повторяет боевую и намеренно содержит все конфликты, включая полный tie,
-- которого на боевых данных нет (0 случаев) — иначе эта ветка осталась бы непроверенной.
-- =============================================================================

truncate legacy_import.legacy_students, legacy_import.legacy_payments,
         legacy_import.legacy_mock_exams, legacy_import.legacy_parent_links,
         legacy_import.legacy_assignments;

insert into legacy_import.legacy_students
  (telegram_id, name, telegram_username, group_name, huikons, rating, current_streak, lives)
values
  (995110001, 'Ученик 1', 'rehearsal_user1', '10А', 115, 50, 7, 2),
  (995110002, 'Ученик 2', 'rehearsal_user2', '10А',   0, 50, 0, 3),
  (995110003, 'Ученик 3', 'rehearsal_user3', '10Б',  70, 90, 3, 1),
  (995110004, 'Ученик 4', 'rehearsal_user4', '10Б',  50, 50, 0, 3);

-- Ученик 4 уже существует в Bot 2.0 (например, успел зайти) — импорт обязан его пропустить,
-- но открывающий баланс всё равно начислить.
insert into public.students (telegram_id, name, telegram_username)
values (995110004, 'Ученик 4 (уже в Bot 2.0)', 'rehearsal_user4')
on conflict (telegram_id) do nothing;

insert into legacy_import.legacy_payments (student_id, payment_date)
values (995110001, date '2026-07-01'),
       (995110002, null);                       -- пустая дата допустима

insert into legacy_import.legacy_mock_exams
  (id, student_id, exam_name, score, exam_date, updated_at, created_at)
values
  -- Ученик 1: коллизия недели (обе среда/пятница одной недели) — победить должен более поздний
  ('11111111-0000-4000-8000-000000000001', 995110001, 'Проб 1', '70', date '2026-06-03',
   timestamptz '2026-06-03 10:00+03', timestamptz '2026-06-03 10:00+03'),
  ('11111111-0000-4000-8000-000000000002', 995110001, 'Проб 2', '75', date '2026-06-05',
   timestamptz '2026-06-05 10:00+03', timestamptz '2026-06-05 10:00+03'),
  -- Ученик 1: три категории непригодных значений
  ('11111111-0000-4000-8000-000000000003', 995110001, 'Проб не писал', 'не писал', date '2026-06-10',
   timestamptz '2026-06-10 10:00+03', timestamptz '2026-06-10 10:00+03'),
  ('11111111-0000-4000-8000-000000000004', 995110001, 'Проб вне диапазона', '150', date '2026-06-17',
   timestamptz '2026-06-17 10:00+03', timestamptz '2026-06-17 10:00+03'),
  ('11111111-0000-4000-8000-000000000005', 995110001, 'Проб без даты', '80', null,
   timestamptz '2026-06-24 10:00+03', timestamptz '2026-06-24 10:00+03'),
  -- Ученик 3: ПОЛНЫЙ tie — одинаковые exam_date/updated_at/created_at, решает только id.
  -- id ...0002 больше, чем ...0001, порядок id desc => победить должен балл 65.
  ('33333333-0000-4000-8000-000000000001', 995110003, 'Проб A', '60', date '2026-06-03',
   timestamptz '2026-06-03 10:00+03', timestamptz '2026-06-03 10:00+03'),
  ('33333333-0000-4000-8000-000000000002', 995110003, 'Проб B', '65', date '2026-06-03',
   timestamptz '2026-06-03 10:00+03', timestamptz '2026-06-03 10:00+03');

insert into legacy_import.legacy_parent_links (parent_telegram_id, student_id, linked_at)
values (995120001, 995110001, now());

insert into legacy_import.legacy_assignments
  (id, student_id, type, title, activation_status, status, approval_status, scheduled_date, created_at)
values
  ('aaaaaaaa-0000-4000-8000-000000000001', 995110001, 'daily',  'Незакрытое активное',
   'active', 'assigned', null, current_date, now()),
  ('aaaaaaaa-0000-4000-8000-000000000002', 995110001, 'weekly', 'На проверке',
   'active', 'submitted', null, current_date, now()),
  ('aaaaaaaa-0000-4000-8000-000000000003', 995110001, 'daily',  'Возвращено на исправление',
   'active', 'checked', 'rejected', current_date, now()),
  ('aaaaaaaa-0000-4000-8000-000000000004', 995110001, 'daily',  'Завершено — НЕ переносим',
   'active', 'checked', 'approved', current_date, now());

-- контроль: 4 / 2 / 7 / 1 / 4
select 'students' t, count(*) from legacy_import.legacy_students
union all select 'payments', count(*) from legacy_import.legacy_payments
union all select 'mock_exams', count(*) from legacy_import.legacy_mock_exams
union all select 'parent_links', count(*) from legacy_import.legacy_parent_links
union all select 'assignments', count(*) from legacy_import.legacy_assignments;


-- =============================================================================
-- БЛОК 2. DRY-RUN. Возвращает отчёт и НЕ ДОЛЖЕН ничего записать.
-- Запомните run_id из ответа — он понадобится только для просмотра отчёта.
-- =============================================================================

select legacy_import.migrate_legacy();   -- p_dry_run = true по умолчанию


-- =============================================================================
-- БЛОК 3. Проверка, что dry-run действительно ничего не записал.
-- Ученик 4 создан вручную в блоке 1, поэтому его строка ожидаема — остальных быть не должно.
-- =============================================================================

select 'D1 dry-run не создал учеников' as check_name,
       case when (select count(*) from public.students
                   where telegram_id in (995110001, 995110002, 995110003)) = 0
            then 'PASS' else 'FAIL' end as result
union all
select 'D2 dry-run не создал пробников',
       case when (select count(*) from public.weekly_mock_exams
                   where student_id between 995110001 and 995110004) = 0
            then 'PASS' else 'FAIL' end
union all
select 'D3 dry-run не создал заданий',
       case when (select count(*) from public.assignments
                   where student_id between 995110001 and 995110004) = 0
            then 'PASS' else 'FAIL' end
union all
select 'D4 dry-run не начислил баланс',
       case when (select count(*) from public.balance_history
                   where student_id between 995110001 and 995110004) = 0
            then 'PASS' else 'FAIL' end;


-- =============================================================================
-- БЛОК 4. APPLY. Возвращает отчёт. СКОПИРУЙТЕ run_id из ответа — он нужен для отката.
-- =============================================================================

select legacy_import.migrate_legacy(p_dry_run => false);


-- =============================================================================
-- БЛОК 5. Проверка последствий apply.
-- =============================================================================

select 'A1 перенесены 3 новых ученика (4-й уже был)' as check_name,
       case when (select count(*) from public.students
                   where telegram_id between 995110001 and 995110004) = 4
            then 'PASS' else 'FAIL' end as result
union all
select 'A2 rating НЕ перенесён (остался 0)',
       case when (select count(*) from public.students
                   where telegram_id between 995110001 and 995110004
                     and coalesce(rating,0) <> 0) = 0
            then 'PASS' else 'FAIL' end
union all
select 'A3 стрик и жизни НЕ перенесены',
       case when (select count(*) from public.students
                   where telegram_id between 995110001 and 995110004
                     and (coalesce(current_streak,0) <> 0 or coalesce(lives,3) <> 3)) = 0
            then 'PASS' else 'FAIL' end
union all
select 'A4 открывающий баланс: 3 записи (у кого huikons > 0)',
       case when (select count(*) from public.balance_history
                   where student_id between 995110001 and 995110004
                     and reason = 'legacy_opening_balance') = 3
            then 'PASS' else 'FAIL' end
union all
select 'A5 баланс ученика 1 равен 115',
       case when (select huikons from public.students where telegram_id = 995110001) = 115
            then 'PASS' else 'FAIL' end
union all
select 'A6 архив пробников: все 7 строк',
       case when (select count(*) from public.mock_exam_results
                   where student_id between 995110001 and 995110004) = 7
            then 'PASS' else 'FAIL' end
union all
select 'A7 canonical: ровно 2 точки (по одной на спорную неделю)',
       case when (select count(*) from public.weekly_mock_exams
                   where student_id between 995110001 and 995110004) = 2
            then 'PASS' else 'FAIL' end
union all
select 'A8 коллизия недели: победил более поздний балл 75',
       case when (select score from public.weekly_mock_exams
                   where student_id = 995110001) = 75
            then 'PASS' else 'FAIL' end
union all
select 'A9 полный tie разрешён по id: победил балл 65',
       case when (select score from public.weekly_mock_exams
                   where student_id = 995110003) = 65
            then 'PASS' else 'FAIL' end
union all
select 'A10 импорт НЕ начислил season points',
       case when (select coalesce(sum(season_points_awarded),0) from public.weekly_mock_exams
                   where student_id between 995110001 and 995110004) = 0
            then 'PASS' else 'FAIL' end
union all
select 'A11 импорт НЕ создал ledger наград за пробники',
       case when (select count(*) from public.mock_exam_reward_log
                   where student_id between 995110001 and 995110004) = 0
            then 'PASS' else 'FAIL' end
union all
select 'A12 импорт НЕ начислил очки сезона',
       case when (select count(*) from public.season_points_log
                   where student_id between 995110001 and 995110004) = 0
            then 'PASS' else 'FAIL' end
union all
select 'A13 задания: перенесены только 3 незакрытых',
       case when (select count(*) from public.assignments
                   where student_id between 995110001 and 995110004) = 3
            then 'PASS' else 'FAIL' end
union all
select 'A14 завершённое задание НЕ перенесено',
       case when (select count(*) from public.assignments
                   where id = 'aaaaaaaa-0000-4000-8000-000000000004') = 0
            then 'PASS' else 'FAIL' end
union all
select 'A15 связка родителя перенесена',
       case when (select count(*) from public.parent_links
                   where parent_telegram_id = 995120001 and student_id = 995110001) = 1
            then 'PASS' else 'FAIL' end
union all
select 'A16 оплата перенесена',
       case when (select payment_date from public.student_payments where student_id = 995110001)
                 = date '2026-07-01'
            then 'PASS' else 'FAIL' end;


-- =============================================================================
-- БЛОК 6. ПОВТОРНЫЙ APPLY. Идемпотентность: не должно появиться ни одной новой строки.
-- В ответе у всех таблиц inserted = 0.
-- =============================================================================

select legacy_import.migrate_legacy(p_dry_run => false);


-- =============================================================================
-- БЛОК 7. Проверка идемпотентности.
-- =============================================================================

select 'R1 учеников по-прежнему 4' as check_name,
       case when (select count(*) from public.students
                   where telegram_id between 995110001 and 995110004) = 4
            then 'PASS' else 'FAIL' end as result
union all
select 'R2 архив пробников по-прежнему 7',
       case when (select count(*) from public.mock_exam_results
                   where student_id between 995110001 and 995110004) = 7
            then 'PASS' else 'FAIL' end
union all
select 'R3 canonical по-прежнему 2',
       case when (select count(*) from public.weekly_mock_exams
                   where student_id between 995110001 and 995110004) = 2
            then 'PASS' else 'FAIL' end
union all
select 'R4 заданий по-прежнему 3',
       case when (select count(*) from public.assignments
                   where student_id between 995110001 and 995110004) = 3
            then 'PASS' else 'FAIL' end
union all
select 'R5 открывающий баланс НЕ начислен второй раз (3 записи, баланс 115)',
       case when (select count(*) from public.balance_history
                   where student_id between 995110001 and 995110004
                     and reason = 'legacy_opening_balance') = 3
            and (select huikons from public.students where telegram_id = 995110001) = 115
            then 'PASS' else 'FAIL' end;


-- =============================================================================
-- БЛОК 8. ОТКАТ. Подставьте run_id ПЕРВОГО apply (из блока 4).
--
-- p_purge_ledger => true — режим «как будто импорта не было»: вместе со строками удаляются
-- записи legacy_opening_balance* этого прогона, иначе ученик, получивший открывающий баланс,
-- останется неудаляемым (balance_history ссылается на students). Найдено на этой репетиции.
-- Для БОЕВОГО отката после подключения живых учеников используется режим по умолчанию (false):
-- там журнал начислений не переписывается, а такие ученики честно помечаются skipped.
-- =============================================================================

-- select legacy_import.rollback_run('ВСТАВЬТЕ-СЮДА-RUN-ID'::uuid, p_purge_ledger => true);


-- =============================================================================
-- БЛОК 9. Проверка отката.
-- Ученик 4 создавался вручную и импортом был пропущен — он ОСТАЁТСЯ, это правильно.
-- =============================================================================

select 'B1 импортированные ученики удалены' as check_name,
       case when (select count(*) from public.students
                   where telegram_id in (995110001, 995110002, 995110003)) = 0
            then 'PASS' else 'FAIL' end as result
union all
select 'B2 ученик 4 (не импортированный) остался',
       case when (select count(*) from public.students where telegram_id = 995110004) = 1
            then 'PASS' else 'FAIL' end
union all
select 'B3 архив пробников удалён',
       case when (select count(*) from public.mock_exam_results
                   where student_id between 995110001 and 995110004) = 0
            then 'PASS' else 'FAIL' end
union all
select 'B4 canonical удалён',
       case when (select count(*) from public.weekly_mock_exams
                   where student_id between 995110001 and 995110004) = 0
            then 'PASS' else 'FAIL' end
union all
select 'B5 задания удалены',
       case when (select count(*) from public.assignments
                   where student_id between 995110001 and 995110004) = 0
            then 'PASS' else 'FAIL' end
union all
select 'B6 баланс ученика 4 возвращён к нулю компенсацией',
       case when (select huikons from public.students where telegram_id = 995110004) = 0
            then 'PASS' else 'FAIL' end
union all
select 'B7 у ученика 4 (не импортированного) журнал НЕ зачищен',
       case when (select count(*) from public.balance_history
                   where student_id = 995110004
                     and reason in ('legacy_opening_balance','legacy_opening_balance_rollback')) = 2
            then 'PASS' else 'FAIL' end
union all
select 'B8 связки родителя удалены',
       case when (select count(*) from public.parent_links
                   where student_id between 995110001 and 995110004) = 0
            then 'PASS' else 'FAIL' end
union all
select 'B9 оплаты удалены',
       case when (select count(*) from public.student_payments
                   where student_id between 995110001 and 995110004) = 0
            then 'PASS' else 'FAIL' end;


-- =============================================================================
-- БЛОК 10. ОЧИСТКА.
-- Порядок учитывает все таблицы с внешним ключом на students, включая те, что могла создать
-- сама бизнес-логика (лиговое состояние появляется при начислении очков сезона).
-- =============================================================================

truncate legacy_import.legacy_students, legacy_import.legacy_payments,
         legacy_import.legacy_mock_exams, legacy_import.legacy_parent_links,
         legacy_import.legacy_assignments;
-- Удаляются ТОЛЬКО прогоны репетиции: те, где среди учеников есть синтетический ID 9951xxxxx.
-- Журнал будущих боевых прогонов не затрагивается.
delete from legacy_import.import_log
 where run_id in (select distinct run_id from legacy_import.import_log
                   where table_name = 'students' and entity_key ~ '^9951');

delete from public.season_points_log      where student_id between 995110001 and 995110004;
delete from public.mock_exam_reward_log   where student_id between 995110001 and 995110004;
delete from public.weekly_mock_exams      where student_id between 995110001 and 995110004;
delete from public.mock_exam_results      where student_id between 995110001 and 995110004;
delete from public.assignments            where student_id between 995110001 and 995110004;
delete from public.parent_links           where student_id between 995110001 and 995110004;
delete from public.student_payments       where student_id between 995110001 and 995110004;
delete from public.balance_history        where student_id between 995110001 and 995110004;
delete from public.league_movements       where student_id between 995110001 and 995110004;
delete from public.league_memberships     where student_id between 995110001 and 995110004;
delete from public.student_league_state   where student_id between 995110001 and 995110004;
delete from public.students               where telegram_id between 995110001 and 995110004;

-- контроль: все три должны вернуть 0
select count(*) from public.students             where telegram_id between 995110001 and 995110004;
select count(*) from public.weekly_mock_exams    where student_id between 995110001 and 995110004;
select count(*) from legacy_import.legacy_students;
