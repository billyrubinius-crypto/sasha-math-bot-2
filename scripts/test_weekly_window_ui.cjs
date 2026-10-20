// Browser integration for the actual student summary and upload dropdown.
const assert = require('node:assert/strict');
const path = require('node:path');
const { pathToFileURL } = require('node:url');
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'C:/Users/shubi/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright');
(async () => {
    const browser = await chromium.launch({ headless: true });
    try {
        const page = await browser.newPage();
        await page.route(/^https?:/, route => route.fulfill({ status: 200, contentType: 'application/javascript', body: '' }));
        await page.goto(pathToFileURL(path.resolve(__dirname, '../index.html')).href);
        await page.evaluate(async () => {
            window.weeklyToday = '2026-10-18';
            getTodayMSK = () => window.weeklyToday;
            currentUser = { id: 12345 };
            studentSecurePathActive = () => true;
            loadWeekBlock = async () => {};
            const rows = [
                { id: 'older', type: 'weekly', title: '5 October', week_label: '2026-10-05' },
                { id: 'sunday', type: 'weekly', title: '12 October', week_label: '2026-10-12' },
                { id: 'monday', type: 'weekly', title: '19 October', week_label: '2026-10-19' },
                { id: 'future', type: 'weekly', title: '26 October', week_label: '2026-10-26' },
            ].map(a => ({ status: 'assigned', created_at: '2026-10-01', ...a }));
            db = { rpc: async () => ({}), from: () => {
                const query = { select() { return query; }, eq() { return query; }, or() { return query; }, order: async () => ({ data: rows }) };
                return query;
            } };
            await loadAssignmentsSummary();
            await loadActiveAssignments();
        });
        assert.equal(await page.locator('#now-count').innerText(), '1');
        assert.equal(await page.locator('#assignment-select option').count(), 2);
        assert.equal(await page.locator('#assignment-select option').nth(1).getAttribute('value'), 'sunday');
        assert.match(await page.locator('#now-list').innerText(), /12 October/);
        await page.evaluate(() => { window.weeklyToday = '2026-10-19'; window.dispatchEvent(new Event('focus')); });
        await page.waitForFunction(() => document.querySelector('#assignment-select option:nth-child(2)')?.value === 'monday');
        assert.equal(await page.locator('#now-count').innerText(), '1');
        assert.match(await page.locator('#now-list').innerText(), /19 October/);
        assert.doesNotMatch(await page.locator('#now-list').innerText(), /12 October|5 October|26 October/);
        console.log('PASS weekly browser: one current weekly task in summary/dropdown, Monday focus replaces old week without page reload.');
    } finally { await browser.close(); }
})().catch(e => { console.error(e); process.exitCode = 1; });
