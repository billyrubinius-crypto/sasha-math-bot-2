// Regression for a journal tab left open across days/months. Mock data is filtered
// by the requested dates, so stale queries also produce stale student statistics.
const assert = require('node:assert/strict');
const path = require('node:path');
const { pathToFileURL } = require('node:url');
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'C:/Users/shubi/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright');

(async () => {
    const browser = await chromium.launch({ headless: true });
    try {
        const page = await browser.newPage();
        const errors = [];
        page.on('pageerror', error => errors.push(error.message));
        await page.route(/^https?:/, route => route.fulfill({ status: 200, contentType: 'application/javascript', body: '' }));
        await page.goto(pathToFileURL(path.resolve(__dirname, '../teacher.html')).href);
        await page.evaluate(() => {
            window.testToday = '2026-10-10';
            getTodayMSK = () => window.testToday;
            // Browsers can restore old form values when reopening a page.
            document.getElementById('journal-from').value = '2026-09-01';
            document.getElementById('journal-to').value = '2026-09-30';
            const dates = ['2025-01-01', '2026-09-30', '2026-10-09', '2026-10-15', '2026-10-19', '2026-11-01'];
            window.periodCalls = [];
            db = { rpc: async (name, params = {}) => {
                if (name !== 'get_teacher_journal_self') return { data: { pending_count: 0 } };
                window.periodCalls.push(params);
                const filtered = dates.filter(date => params.p_from === null && params.p_to === null
                    || date >= params.p_from && date <= params.p_to);
                return { data: { students: [{ telegram_id: '1001', name: 'Проверка периода', group_name: '11А',
                    stats: { total: filtered.length, approved: filtered.length, solved: filtered.length * 7, task_total: filtered.length * 8 } }],
                    assignments: [], changes: [], exams: [] } };
            } };
            document.getElementById('login-screen').style.display = 'none';
        });
        await page.getByText('📒 Журнал', { exact: true }).click();
        const row = page.locator('.journal-table tbody tr');
        await row.waitFor();
        assert.equal(await row.locator('td').nth(1).innerText(), '6 / 6', 'default must include history older than 93 days');
        assert.equal(await page.locator('#journal-period-label').innerText(), 'За всё время');
        assert.equal(await page.locator('#journal-from').inputValue(), '');
        assert.equal(await page.locator('[data-journal-period="all"]').getAttribute('aria-pressed'), 'true');
        await page.getByRole('button', { name: 'Проверка периода', exact: true }).click();
        assert.match(await page.locator('#journal-detail').innerText(), /За всё время/);
        assert.deepEqual(await page.evaluate(() => window.periodCalls.at(-1)), { p_from: null, p_to: null, p_student_id: '1001' });
        await page.getByRole('button', { name: '30 дней', exact: true }).click();
        assert.equal(await row.locator('td').nth(1).innerText(), '2 / 2');
        assert.equal(await page.locator('#journal-to').inputValue(), '2026-10-10');
        // No button for another period is clicked: simply return ten days later.
        await page.evaluate(async () => { window.testToday = '2026-10-20'; await loadJournal(); });
        assert.equal(await page.locator('#journal-to').inputValue(), '2026-10-20', 'automatic range must advance on refresh');
        assert.equal(await row.locator('td').nth(1).innerText(), '4 / 4', 'October 15/19 work must enter roster statistics');
        assert.equal(await row.locator('td').nth(2).innerText(), '28 / 32');
        // Relative month follows today; browser-restored stale inputs cannot pin it.
        await page.getByRole('button', { name: 'Текущий месяц', exact: true }).click();
        assert.equal(await row.locator('td').nth(1).innerText(), '3 / 3');
        await page.evaluate(() => { window.testToday = '2026-11-01'; window.dispatchEvent(new Event('focus')); });
        await page.waitForFunction(() => document.getElementById('journal-to').value === '2026-11-01');
        await page.waitForFunction(() => document.querySelector('.journal-table tbody tr td:nth-child(2)')?.textContent === '1 / 1');
        assert.equal(await page.locator('#journal-from').inputValue(), '2026-11-01');
        // A deliberately selected historical range must NOT be silently moved.
        await page.locator('#journal-from').fill('2026-10-01');
        await page.locator('#journal-to').fill('2026-10-10');
        await page.locator('#journal-to').dispatchEvent('change');
        await page.waitForFunction(() => document.querySelector('.journal-table tbody tr td:nth-child(2)')?.textContent === '1 / 1');
        await page.evaluate(async () => { window.testToday = '2026-11-02'; await loadJournal(); });
        assert.equal(await page.locator('#journal-from').inputValue(), '2026-10-01');
        assert.equal(await page.locator('#journal-to').inputValue(), '2026-10-10');
        assert.match(await page.locator('#journal-period-label').innerText(), /01\.10\.2026.*10\.10\.2026/);
        await page.getByRole('button', { name: '30 дней', exact: true }).click();
        assert.equal(await page.locator('#journal-to').inputValue(), '2026-11-02');
        assert.equal(await row.locator('td').nth(1).innerText(), '4 / 4');
        await page.getByRole('button', { name: 'За всё время', exact: true }).click();
        assert.equal(await row.locator('td').nth(1).innerText(), '6 / 6');
        assert.equal(await page.locator('#journal-period-label').innerText(), 'За всё время');
        assert.equal(await page.locator('#journal-to').inputValue(), '');
        assert.deepEqual(errors, []);
        console.log('PASS journal periods: all-time default and detail, switches, ten-day refresh, month rollover, explicit dates preserved.');
    } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
