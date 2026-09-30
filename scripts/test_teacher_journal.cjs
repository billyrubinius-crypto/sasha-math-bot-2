// Run with node --preserve-symlinks. Uses the bundled Playwright runtime, no live services.
const assert = require('node:assert/strict');
const path = require('node:path');
const { pathToFileURL } = require('node:url');
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'C:/Users/shubi/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright');

(async () => {
    const browser = await chromium.launch({ headless: true });
    try {
        const page = await browser.newPage({ viewport: { width: 1440, height: 1000 } });
        const errors = [];
        page.on('pageerror', e => errors.push(e.message));
        // The teacher page normally loads the Supabase SDK from a CDN. No external traffic
        // or real teacher session is needed for this UI regression.
        await page.route(/^https?:/, route => route.fulfill({ status: 200, contentType: 'application/javascript', body: '' }));
        await page.goto(pathToFileURL(path.resolve(__dirname, '../teacher.html')).href);
        await page.evaluate(() => {
            getTodayMSK = () => '2026-09-30';
            const students = [
                { telegram_id: '1001', name: 'Анна Иванова', group_name: 'ЕГЭ · 11 класс', telegram_username: 'anna', current_streak: 4,
                    stats: { total: 3, approved: 1, submitted: 1, missed: 1, solved: 7, task_total: 24, last_upload: '2026-09-30T09:00:00Z' } },
                { telegram_id: '1002', name: '<img src=x onerror=alert(1)>', group_name: 'ОГЭ · 9 класс', stats: {} },
                { telegram_id: '1003', name: 'Пётр Смирнов', group_name: null, stats: {} }
            ];
            const tasks = [
                { id: 'past', student_id: 1001, type: 'daily', title: 'Логарифмы · пропущенный вторник', scheduled_date: '2026-09-29',
                    journal_date: '2026-09-29', activation_status: 'archived', status: 'assigned', approval_status: null,
                    correct_task_count: null, task_count: 8, photo_url: null, journal_status: 'missed', journal_version: 'v1' },
                { id: 'pending', type: 'daily', title: 'Тригонометрия', scheduled_date: '2026-09-30', journal_date: '2026-09-30',
                    status: 'submitted', task_count: 8, journal_status: 'submitted', photo_url: '["https://example.test/solution.jpg"]', journal_version: 'v1' },
                { id: 'future', type: 'daily', title: 'Будущий день', scheduled_date: '2026-10-01', journal_date: '2026-10-01',
                    status: 'assigned', activation_status: 'draft', task_count: 8, journal_status: 'planned', journal_version: 'v1' }
            ];
            window.journalCalls = [];
            window.journalFixture = { students, tasks };
            const changes = [];
            db = { rpc: async (name, params = {}) => {
                window.journalCalls.push({ name, params });
                if (name === 'get_review_queue_self') return { data: { pending_count: 1 } };
                if (name === 'correct_journal_assignment_self') {
                    const a = tasks.find(a => a.id === params.p_assignment_id);
                    if (window.forceJournalConflict) return { error: { message: 'journal_conflict' } };
                    const before = { status: a.status, approval_status: a.approval_status, correct_task_count: a.correct_task_count, teacher_excused_at: a.teacher_excused_at };
                    a.status = 'checked'; a.approval_status = params.p_status; a.correct_task_count = params.p_correct_task_count;
                    a.teacher_excused_at = params.p_excuse ? '2026-09-30T09:10:00Z' : null;
                    a.journal_status = params.p_excuse ? 'approved' : 'approved_late'; a.journal_version = 'v2';
                    a.teacher_feedback = params.p_reason;
                    students[0].stats = { total: 3, approved: 2, submitted: 1, late: params.p_excuse ? 0 : 1, excused: params.p_excuse ? 1 : 0, solved: 15, task_total: 24 };
                    changes.unshift({ assignment_id: a.id, created_at: '2026-09-30T09:10:00Z', reason: params.p_reason, before_state: before, after_state: { ...a } });
                    return { data: { ok: true, achievements_awarded: params.p_excuse ? 2 : 0 } };
                }
                return { data: { students: params.p_student_id ? students.filter(s => s.telegram_id === params.p_student_id) : students,
                    assignments: params.p_student_id === '1001' ? tasks : [], changes, exams: [] } };
            } };
            document.getElementById('login-screen').style.display = 'none';
        });
        await page.getByText('📒 Журнал', { exact: true }).click();
        await page.getByRole('button', { name: 'Анна Иванова', exact: true }).waitFor();
        assert.equal(await page.locator('.journal-group').count(), 3);
        assert.equal(await page.locator('.journal-student-button img').count(), 0, 'Student names must remain text');
        await page.locator('#journal-search').fill('anna');
        assert.equal(await page.locator('.journal-student-button').count(), 1);
        await page.locator('#journal-search').fill('');
        await page.locator('#journal-group').selectOption('__ungrouped__');
        await page.getByRole('button', { name: 'Пётр Смирнов', exact: true }).waitFor();
        await page.locator('#journal-group').selectOption('');
        await page.locator('#journal-attention').check();
        assert.equal(await page.locator('.journal-student-button').count(), 1);
        await page.getByRole('button', { name: 'Анна Иванова', exact: true }).click();
        const past = page.locator('.journal-task').filter({ hasText: 'Логарифмы · пропущенный вторник' });
        await past.waitFor();
        assert.match(await past.innerText(), /Фото решения не загружены/);
        assert.equal(await page.locator('.journal-task').filter({ hasText: 'Будущий день' }).getByRole('button').count(), 0);
        await past.getByRole('button', { name: 'Исправить отчёт / зачесть исключение' }).click();
        let editor = past.locator('.journal-editor');
        await editor.locator('select').selectOption('approved');
        assert.equal(await editor.locator('input[type=checkbox]').isChecked(), false, 'Approval must not implicitly excuse a late day');
        await editor.locator('input[type=number]').fill('8');
        await editor.locator('textarea').fill('Принята поздняя работа без исключения');
        await editor.getByRole('button', { name: 'Сохранить исправление' }).click();
        await past.getByText('× Принято с опозданием', { exact: true }).waitFor();
        await past.getByRole('button', { name: 'Исправить отчёт / зачесть исключение' }).click();
        editor = past.locator('.journal-editor');
        await editor.locator('input[type=checkbox]').check();
        await editor.locator('textarea').fill('Решено вовремя. Проверено на занятии; разрешаю исключение.');
        await editor.getByRole('button', { name: 'Сохранить исправление' }).click();
        await past.getByText('✓ Принято', { exact: true }).waitFor();
        assert.match(await past.innerText(), /День сохраняет серию/);
        await page.locator('#journal-message').getByText(/Выдано новых достижений: 2/).waitFor();
        const calls = await page.evaluate(() => window.journalCalls.filter(c => c.name === 'correct_journal_assignment_self'));
        assert.equal(calls.length, 2);
        assert.equal(calls[0].params.p_excuse, false);
        assert.equal(calls[1].params.p_excuse, true);
        assert.equal(calls[1].params.p_assignment_id, 'past');
        assert.equal(calls[1].params.p_correct_task_count, 8);
        assert.equal(calls[1].params.p_expected_version, 'v2');
        assert.equal(await page.evaluate(() => window.journalCalls.some(c => c.name === 'submit_assignment_self')), false);
        await page.locator('.journal-history summary').click();
        assert.equal(await page.locator('.journal-history-entry').count(), 2);
        await past.getByRole('button', { name: 'Исправить отчёт / зачесть исключение' }).click();
        await page.evaluate(() => { window.forceJournalConflict = true; });
        await past.locator('textarea').fill('Проверка одновременного изменения');
        await past.getByRole('button', { name: 'Сохранить исправление' }).click();
        await past.getByText(/Работу уже изменили/).waitFor();
        assert.equal(await past.getByRole('button', { name: 'Сохранить исправление' }).isEnabled(), true);
        await past.getByRole('button', { name: 'Отмена', exact: true }).click();
        await page.evaluate(() => { window.journalFixture.students[1].name = 'Михаил Сергеев'; renderJournal(true); });
        await page.locator('#journal-attention').uncheck();
        await page.locator('#tab-journal').evaluate(el => { el.scrollTop = 0; });
        await page.screenshot({ path: path.resolve(__dirname, '../dev/teacher-journal-desktop.png'), fullPage: false });
        await page.setViewportSize({ width: 390, height: 844 });
        assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth), true, 'Mobile page must not overflow horizontally');
        await page.locator('#tab-journal').evaluate(el => { el.scrollTop = 0; });
        await page.screenshot({ path: path.resolve(__dirname, '../dev/teacher-journal-mobile.png'), fullPage: false });
        await page.locator('#journal-from').fill('2026-01-01');
        await page.locator('#journal-from').dispatchEvent('change');
        await page.getByText(/период должен составлять от 1 до 93 дней/).waitFor();
        assert.equal(await page.locator('.journal-student-button').count(), 0, 'Invalid dates must clear stale rows');
        await page.evaluate(() => clearTeacherJournal());
        assert.equal(await page.locator('#journal-detail').isVisible(), false);
        assert.deepEqual(errors, []);
        console.log('PASS teacher journal: groups, search, filters, past day without upload, explicit exception, conflict, history, mobile, period, logout.');
    } finally { await browser.close(); }
})().catch(e => { console.error(e); process.exitCode = 1; });
