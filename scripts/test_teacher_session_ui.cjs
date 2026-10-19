// Browser regression with the site's real Supabase SDK and mocked HTTP endpoints.
// SUPABASE_SDK_PATH points to a downloaded copy of the SDK; no live login/data is used.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { pathToFileURL } = require('node:url');
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'C:/Users/shubi/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright');
const sdkPath = process.env.SUPABASE_SDK_PATH || path.join(os.tmpdir(), 'sasha-math-audit-supabase.min.js');

(async () => {
    assert(fs.existsSync(sdkPath), 'Set SUPABASE_SDK_PATH to the Supabase SDK used by teacher.html');
    const browser = await chromium.launch({ headless: true });
    try {
        const page = await browser.newPage();
        page.setDefaultTimeout(8000);
        const errors = [], alerts = [], publications = [], journalPeriods = [];
        let refreshes = 0, sequence = 0, refreshExpired = false;
        page.on('pageerror', e => errors.push(e.message));
        page.on('dialog', async d => { alerts.push(d.message()); await d.accept(); });
        await page.clock.install({ time: new Date('2026-10-20T08:00:00Z') });
        const jwt = async () => {
            const now = await page.evaluate(() => Date.now());
            return Buffer.from(JSON.stringify({ alg: 'ES256', typ: 'JWT' })).toString('base64url') + '.'
                + Buffer.from(JSON.stringify({ exp: Math.floor(now / 1000) + 3600, role: 'authenticated', jti: ++sequence })).toString('base64url') + '.test';
        };
        await page.route('https://cdn.jsdelivr.net/**', route => route.fulfill({
            status: 200, contentType: 'application/javascript', body: fs.readFileSync(sdkPath, 'utf8'),
        }));
        await page.route('https://ewwmsoecabfdldccrjfc.supabase.co/**', async route => {
            const url = new URL(route.request().url());
            let data = [], status = 200;
            if (/teacher-auth$|teacher-refresh$/.test(url.pathname)) {
                if (url.pathname.endsWith('teacher-refresh')) ++refreshes;
                if (refreshExpired && url.pathname.endsWith('teacher-refresh')) {
                    status = 401; data = { error: 'invalid_token' };
                } else data = { access_token: await jwt(), refresh_token: 'test-only-refresh-' + sequence };
            } else if (url.pathname.endsWith('/students')) {
                data = [{ telegram_id: 12345, name: 'Тестовый ученик', group_name: '11А' }];
            } else if (url.pathname.endsWith('/get_review_queue_self')) data = { items: [], pending_count: 0 };
            else if (url.pathname.endsWith('/publish_weekly_plan_self')) {
                publications.push(route.request().postDataJSON()); data = { students_synced: 1 };
            } else if (url.pathname.endsWith('/get_teacher_journal_self')) {
                const args = route.request().postDataJSON(); journalPeriods.push(args);
                data = { students: [{ telegram_id: '12345', name: 'Тестовый ученик', group_name: '11А', stats: { total: 1, approved: 1 } }],
                    assignments: args.p_student_id ? [{ id: 'october', type: 'daily', title: 'Задание за октябрь', task_count: 8,
                        scheduled_date: '2026-10-15', journal_date: '2026-10-15', journal_status: 'approved', status: 'checked', approval_status: 'approved' }] : [],
                    changes: [], exams: [] };
            }
            await route.fulfill({ status, contentType: 'application/json', headers: {
                'Access-Control-Allow-Origin': '*', 'Content-Range': '0-0/0',
            }, body: JSON.stringify(data) });
        });
        await page.goto(pathToFileURL(path.resolve(__dirname, '../teacher.html')).href);
        await page.locator('#pass').fill('synthetic-test-only');
        await page.getByRole('button', { name: 'Войти', exact: true }).click();
        await page.locator('#login-screen').waitFor({ state: 'hidden' });
        await page.getByText('📅 Планирование', { exact: true }).click();
        const fillPlan = async () => {
            await page.locator('#activation-date').fill('2026-10-19');
            await page.locator('#day-title-0').fill('Октябрьская работа');
            await page.locator('#day-url-0').fill('https://example.test/october');
            await page.locator('#day-count-0').fill('8');
            await page.locator('.week-group-checkbox[value="11А"]').check();
        };
        await fillPlan();
        // setSystemTime changes the wall clock without running delayed timers (laptop sleep).
        await page.clock.setSystemTime(new Date('2026-10-20T10:05:00Z'));
        await page.locator('#btn-schedule-week').click();
        await page.waitForFunction(() => document.getElementById('day-title-0').value === '');
        assert.equal(refreshes, 1);
        assert.equal(publications.length, 1);
        assert.equal(publications[0].p_group_name, '11А');
        assert.equal(publications[0].p_items[0].title, 'Октябрьская работа');
        assert(!alerts.some(s => /JWT expired/.test(s)));
        await page.getByText('📒 Журнал', { exact: true }).click();
        await page.getByRole('button', { name: 'Текущий месяц', exact: true }).click();
        await page.getByRole('button', { name: 'Тестовый ученик', exact: true }).click();
        await page.getByText('Задание за октябрь', { exact: true }).waitFor();
        assert.equal(journalPeriods.at(-1).p_from, '2026-10-01');
        assert.equal(journalPeriods.at(-1).p_to, '2026-10-20');
        await page.getByText('📅 Планирование', { exact: true }).click();
        await fillPlan();
        refreshExpired = true;
        await page.clock.setSystemTime(new Date('2026-10-21T00:05:00Z'));
        await page.locator('#btn-schedule-week').click();
        await page.locator('#login-screen').waitFor({ state: 'visible' });
        assert.equal(publications.length, 1, 'expired family must stop publication before any write');
        assert.equal(await page.locator('#day-title-0').inputValue(), 'Октябрьская работа');
        refreshExpired = false;
        await page.locator('#pass').fill('synthetic-test-only');
        await page.getByRole('button', { name: 'Войти', exact: true }).click();
        await page.locator('#login-screen').waitFor({ state: 'hidden' });
        assert.equal(await page.locator('.week-group-checkbox[value="11А"]').isChecked(), true);
        assert.equal(await page.locator('#week-group-all').isChecked(), false);
        await page.locator('#btn-schedule-week').click();
        await page.waitForFunction(() => document.getElementById('day-title-0').value === '');
        assert.equal(publications.length, 2);
        assert.equal(publications[1].p_group_name, '11А');
        for (const tab of ['✅ Проверка', '🏷️ Титулы', '🎲 Квесты']) await page.getByText(tab, { exact: true }).click();
        assert.deepEqual(errors, []);
        console.log('PASS real SDK browser: publish after sleep, October journal, expired family, preserved plan/audience after re-login, teacher tabs.');
    } finally { await browser.close(); }
})().catch(e => { console.error(e); process.exitCode = 1; });
