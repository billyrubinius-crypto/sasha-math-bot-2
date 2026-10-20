// Offline regression: current-week availability, dropdown data, Monday/resume.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
let today = '2026-10-18', activated = 0, weekReloads = 0, columns = '';
const rows = [
    { id: 'old', type: 'weekly', week_label: '2026-10-05' },
    { id: 'sunday', type: 'weekly', week_label: '2026-10-12' },
    { id: 'monday', type: 'weekly', week_label: '2026-10-19' },
    { id: 'future', type: 'weekly', week_label: '2026-10-26' },
    { id: 'unlabeled', type: 'weekly', week_label: null },
    { id: 'individual', type: 'individual' },
    { id: 'daily', type: 'daily', scheduled_date: '2026-10-18' },
    { id: 'revision', type: 'daily', scheduled_date: '2026-10-15', status: 'checked',
        approval_status: 'rejected', revision_deadline_at: '2026-11-01T00:00:00Z' },
].map(a => ({ status: 'assigned', activation_status: 'active', created_at: '2026-10-01', ...a }));
const elements = new Map();
function node() { return { innerHTML: '', textContent: '', value: '', disabled: false, querySelectorAll: () => [], appendChild() {} }; }
const context = vm.createContext({ Date, console,
    db: { rpc: async () => { activated++; return {}; }, from: () => {
        const query = { select(c) { columns = c; return query; }, eq() { return query; }, or() { return query; },
            order: async () => ({ data: rows }) };
        return query;
    } }, currentUser: { id: 1 }, activeAssignments: [],
    getTodayMSK: () => today, studentSecurePathActive: () => true, log: console.log,
    esc: String, loadWeekBlock: async () => { weekReloads++; },
    document: { visibilityState: 'visible', addEventListener() {}, createElement: node,
        getElementById(id) { if (!elements.has(id)) elements.set(id, node()); return elements.get(id); } },
    window: { addEventListener() {} },
});
vm.runInContext(fs.readFileSync(path.resolve(__dirname, '../js/student-assignments.js'), 'utf8'), context);
(async () => {
    assert.equal(vm.runInContext("assignmentWeekStart('2027-01-01')", context), '2026-12-28');
    assert.deepEqual(Array.from(await context.getActionableAssignments(), a => a.id), ['revision', 'daily', 'sunday', 'individual']);
    assert.match(columns, /week_label/, 'the real read must fetch the weekly identity');
    // 21:00 UTC Sunday is Monday 00:00 in Moscow. No page reload.
    today = '2026-10-19';
    await context.refreshAssignmentsAfterSleep();
    assert.deepEqual(Array.from(context.activeAssignments, a => a.id), ['revision', 'monday', 'individual']);
    assert.equal(weekReloads, 1);
    const calls = activated;
    await context.refreshAssignmentsAfterSleep();
    assert.equal(activated, calls, 'unchanged date must not repeat requests');
    assert.equal(context.isAssignmentAvailable(rows[1], new Date(), today), false, 'an open Sunday upload becomes unavailable on Monday');
    const rejected = { ...rows[1], status: 'checked', approval_status: 'rejected' };
    assert.equal(context.isAssignmentAvailable(rejected, new Date(), today), false, 'rejected weekly work cannot extend into the next week');
    assert.ok(activated > 0, 'current slots must activate before reads');
    console.log('PASS weekly UI: Sunday/Monday MSK, year boundary, current-only dropdown and summary, resume, daily revision and individual unchanged.');
})().catch(e => { console.error(e); process.exitCode = 1; });
