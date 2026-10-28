// Actual teacher form; server preservation is separately checked by the rollback-only SQL regression.
const assert = require('node:assert/strict');
const path = require('node:path');
const { pathToFileURL } = require('node:url');
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'C:/Users/shubi/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright');

(async () => {
    const browser = await chromium.launch({ headless: true });
    try {
        const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
        const errors = [], alerts = [];
        page.on('pageerror', e => errors.push(e.message));
        page.on('dialog', async d => { alerts.push(d.message()); await d.accept(); });
        await page.route(/^https?:/, route => route.fulfill({ status: 200, contentType: 'application/javascript', body: '' }));
        await page.goto(pathToFileURL(path.resolve(__dirname, '../teacher.html')).href);
        await page.evaluate(() => {
            document.getElementById('login-screen').style.display = 'none';
            document.querySelectorAll('.content-area').forEach(el => el.classList.remove('active'));
            document.getElementById('tab-plan').classList.add('active');
            window.publications = [];
            window.publicationError = null;
            window.holdPublication = false;
            db = { rpc: async (name, params) => {
                window.publications.push({ name, params });
                if (window.holdPublication) await new Promise(resolve => { window.finishPublication = resolve; });
                return window.publicationError && params.p_group_name === 'B'
                    ? { error: { message: window.publicationError } } : { data: { students_synced: 1 } };
            } };
            for (const group of ['A', 'B']) {
                const input = document.createElement('input');
                input.type = 'checkbox'; input.className = 'week-group-checkbox'; input.value = group;
                input.onchange = onWeekGroupPick;
                document.getElementById('week-group-list').append(input);
            }
        });
        const fillDaily = async () => {
            await page.locator('#day-title-3').fill('Thursday');
            await page.locator('#day-url-3').fill('https://example.test/thursday');
            await page.locator('#day-count-3').fill('10');
        };
        const fillWeekly = async () => {
            await page.locator('#weekly-title').fill('Variant 1');
            await page.locator('#weekly-url').fill('https://example.test/weekly');
            await page.locator('#weekly-count').fill('12');
        };
        await page.locator('#activation-date').fill('2026-10-26');
        await page.locator('.week-group-checkbox[value="A"]').check();
        await fillDaily(); await fillWeekly();
        await page.locator('#btn-schedule-week').click();
        let calls = await page.evaluate(() => window.publications);
        assert.equal(calls.length, 1);
        assert.equal(calls[0].name, 'publish_homework_self');
        assert.equal(calls[0].params.p_task_type, 'daily');
        assert.deepEqual(calls[0].params.p_items.map(i => i.type), ['daily']);
        assert.equal(calls[0].params.p_items[0].day_of_week, 4);
        assert.equal(await page.locator('#weekly-title').inputValue(), 'Variant 1');
        assert.equal(await page.locator('#day-title-3').inputValue(), '');
        assert.equal(await page.locator('#activation-date').inputValue(), '2026-10-26');
        assert(await page.locator('.week-group-checkbox[value="A"]').isChecked());
        assert.equal(await page.locator('#week-group-all').isChecked(), false);

        // Incomplete daily fields must not block or enter a weekly-only request.
        await page.locator('#day-title-4').fill('Unfinished daily draft');
        await page.locator('#btn-schedule-weekly').click();
        calls = await page.evaluate(() => window.publications);
        assert.equal(calls[1].params.p_task_type, 'weekly');
        assert.deepEqual(calls[1].params.p_items.map(i => i.type), ['weekly']);
        assert.equal(await page.locator('#weekly-title').inputValue(), '');
        assert.equal(await page.locator('#day-title-4').inputValue(), 'Unfinished daily draft');

        await page.locator('#btn-schedule-week').click();
        assert.equal((await page.evaluate(() => window.publications)).length, 2);
        assert.match(alerts.at(-1), /Пятница.*название и ссылку/);
        await page.locator('#day-title-4').fill('');
        await page.locator('#btn-schedule-week').click();
        assert.equal((await page.evaluate(() => window.publications)).length, 2);
        await page.locator('#btn-schedule-weekly').click();
        assert.equal((await page.evaluate(() => window.publications)).length, 2);

        // A failure after one group succeeds preserves both drafts and the selected audience.
        await fillDaily(); await fillWeekly();
        await page.locator('.week-group-checkbox[value="B"]').check();
        await page.evaluate(() => { window.publicationError = 'test failure'; });
        await page.locator('#btn-schedule-weekly').click();
        assert.match(alerts.at(-1), /Опубликовано: A.*[\s\S]*test failure/);
        assert.equal(await page.locator('#weekly-title').inputValue(), 'Variant 1');
        assert.equal(await page.locator('#day-title-3').inputValue(), 'Thursday');
        assert.equal(await page.locator('.week-group-checkbox:checked').count(), 2);

        await page.evaluate(() => { window.publicationError = null; window.holdPublication = true; });
        const before = (await page.evaluate(() => window.publications)).length;
        await page.locator('#btn-schedule-weekly').click();
        await page.waitForFunction(() => typeof window.finishPublication === 'function');
        assert(await page.locator('#btn-schedule-week').isDisabled());
        assert(await page.locator('#btn-schedule-weekly').isDisabled());
        await page.evaluate(async () => { await scheduleWeek('daily'); await scheduleWeek('weekly'); });
        assert.equal((await page.evaluate(() => window.publications)).length, before + 1);
        await page.evaluate(() => { window.holdPublication = false; window.finishPublication(); });
        await page.waitForFunction(() => !document.getElementById('btn-schedule-weekly').disabled);
        assert.equal(await page.locator('#weekly-title').inputValue(), '');
        assert.equal(await page.locator('#day-title-3').inputValue(), 'Thursday');

        // Date and audience validation is shared by both independent submissions.
        await page.locator('#activation-date').fill('2026-10-28');
        const invalidBefore = (await page.evaluate(() => window.publications)).length;
        await page.locator('#btn-schedule-week').click();
        assert.match(alerts.at(-1), /понедельник/);
        assert.equal((await page.evaluate(() => window.publications)).length, invalidBefore);
        await page.locator('#activation-date').fill('2026-10-26');
        await page.evaluate(() => document.querySelectorAll('.week-group-checkbox').forEach(cb => cb.checked = false));
        await page.locator('#btn-schedule-week').click();
        assert.match(alerts.at(-1), /Выберите группу/);
        assert.equal((await page.evaluate(() => window.publications)).length, invalidBefore);

        // Actual layout at desktop and phone widths.
        for (const width of [1280, 390]) {
            await page.setViewportSize({ width, height: 900 });
            for (const id of ['activation-date', 'btn-schedule-week', 'btn-schedule-weekly']) {
                const box = await page.locator('#' + id).boundingBox();
                assert(box && box.x >= 0 && box.x + box.width <= width + 1, `${id} overflows at ${width}`);
            }
        }
        assert.deepEqual(errors, []);
        console.log('PASS split homework browser: independent payloads, draft/audience retention, validation, partial failure, retry, busy guard, desktop/mobile layout.');
    } finally { await browser.close(); }
})().catch(e => { console.error(e); process.exitCode = 1; });
