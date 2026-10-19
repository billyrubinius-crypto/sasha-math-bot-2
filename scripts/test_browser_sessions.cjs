// Offline request/session regression. No credentials or live services are used.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const root = path.resolve(__dirname, '..');

function harness(kind = 'teacher', authSource) {
    let now = Date.parse('2026-10-20T08:00:00Z');
    let sequence = 0;
    const storage = new Map(), timers = new Map(), listeners = new Map();
    const state = { refreshes: 0, requests: [], clients: 0, expired: 0, refreshError: null, serverError: null };
    const token = () => 'test.' + Buffer.from(JSON.stringify({
        exp: Math.floor(now / 1000) + 3600, telegram_id: 12345, jti: ++sequence,
    })).toString('base64url') + '.test';
    const json = (data, status = 200) => new Response(JSON.stringify(data), {
        status, headers: { 'Content-Type': 'application/json' },
    });
    const session = () => ({ access_token: token(), refresh_token: 'test-refresh-' + sequence });
    const on = (name, fn) => listeners.set(name, fn);
    const context = vm.createContext({
        Headers, Request, Response, URL, atob, console,
        Date: class extends Date { static now() { return now; } },
        setTimeout(fn, delay) { const id = ++sequence; timers.set(id, { fn, delay }); return id; },
        clearTimeout(id) { timers.delete(id); },
        sessionStorage: { getItem: k => storage.get(k) || null, setItem: (k, v) => storage.set(k, v), removeItem: k => storage.delete(k) },
        document: { visibilityState: 'visible', addEventListener: on, getElementById: () => ({ textContent: '' }) },
        window: { addEventListener: on, supabase: { createClient(_url, _key, options) {
            ++state.clients;
            return { options, rpc: async (name, params = {}) => {
                const jwt = await options.accessToken();
                const res = await (options.global?.fetch || context.fetch)('https://example.supabase.co/rest/v1/rpc/' + name, {
                    method: 'POST', headers: { Authorization: 'Bearer ' + jwt, 'Content-Type': 'application/json' },
                    body: JSON.stringify(params),
                });
                return { status: res.status, data: await res.json() };
            } };
        } } },
        fetch: async (input, init) => {
            const req = new Request(input, init);
            if (/teacher-auth$/.test(req.url)) return json(session());
            if (/teacher-refresh$|student-auth$/.test(req.url)) {
                ++state.refreshes;
                if (state.holdRefresh) await state.holdRefresh;
                if (state.refreshError === 'network') throw new TypeError('offline');
                if (state.refreshError) return json({ error: state.refreshError }, state.refreshError === 'invalid_token' ? 401 : 503);
                return json(session());
            }
            state.requests.push({ jwt: req.headers.get('Authorization'), body: await req.text(), url: req.url });
            if (state.serverError) return json(state.serverError.body, state.serverError.status);
            if (state.rejectNext) {
                --state.rejectNext;
                return json({ code: 'PGRST301', message: 'JWT expired' }, 401);
            }
            return json({ ok: true });
        },
        teacherSessionExpired() { ++state.expired; },
        log() {},
    });
    const run = code => vm.runInContext(code, context);
    run('let db;');
    run(fs.readFileSync(path.join(root, 'shared.js'), 'utf8'));
    run(authSource || fs.readFileSync(path.join(root, 'js/' + kind + '-auth.js'), 'utf8'));
    return { state, run, storage, timers, listeners, advance: ms => { now += ms; },
        login: () => kind === 'teacher' ? run("teacherLogin('test-only')")
            : run("initStudentSession({ initData: 'synthetic-test-only' }).then(session => { db = session.db; })") };
}

async function testSessions() {
    for (const kind of ['teacher', 'student']) {
        const h = harness(kind);
        await h.login();
        const initialToken = h.run(kind + 'AccessToken()');
        const initialRefreshes = h.state.refreshes;
        await h.run("db.rpc('get_teacher_journal_self', { p_from: '2026-10-01', p_to: '2026-10-31' })");
        assert.equal(h.state.refreshes, initialRefreshes, 'valid token must not refresh');
        h.advance(2 * 3600000); // All background timers stayed suspended.
        await h.run("Promise.all([db.rpc('get_teacher_journal_self'), db.rpc('get_review_queue_self'), db.rpc('publish_weekly_plan_self')])");
        assert.equal(h.state.refreshes, initialRefreshes + 1, kind + ': concurrent requests must rotate once after sleep');
        assert.equal(h.state.clients, 1, 'refresh must preserve existing clients/query builders');
        assert(h.state.requests.slice(-3).every(req => req.jwt !== 'Bearer ' + initialToken));
        h.state.rejectNext = 2;
        const before = h.state.refreshes;
        await h.run("Promise.all([db.rpc('read_one'), db.rpc('read_two')])");
        assert.equal(h.state.refreshes, before + 1, kind + ': concurrent expired-JWT responses share rotation');
        const beforeWrite = h.state.requests.length;
        h.state.rejectNext = 1;
        await h.run("db.rpc('publish_weekly_plan_self', { p_week_start: '2026-10-19', p_items: [{ title: 'October' }] })");
        assert.equal(h.state.requests.length, beforeWrite + 2);
        assert.equal(h.state.requests.at(-2).body, h.state.requests.at(-1).body, 'retry preserves exact publication payload');
        for (const error of [
            { status: 403, body: { message: 'forbidden' } },
            { status: 401, body: { message: 'invalid signature' } },
            { status: 400, body: { message: 'invalid_period' } },
            { status: 503, body: { message: 'unavailable' } },
        ]) {
            h.state.serverError = error;
            const count = h.state.requests.length;
            await h.run("db.rpc('write_must_not_repeat')");
            assert.equal(h.state.requests.length, count + 1, 'non-expiry errors must never repeat a write');
        }
        h.state.serverError = null;
        h.advance(2 * 3600000);
        h.state.refreshError = 'network';
        await assert.rejects(h.run("db.rpc('offline_write')"));
        const failedRequests = h.state.requests.length;
        assert.equal(h.state.expired, 0, 'network failure must not clear the session');
        if (kind === 'teacher') assert(h.storage.get('teacher_refresh_token'));
        h.state.refreshError = null;
        await h.run("db.rpc('connection_restored')");
        assert.equal(h.state.requests.length, failedRequests + 1);
        h.advance(2 * 3600000);
        h.state.refreshError = 'internal_error';
        await assert.rejects(h.run("db.rpc('server_unavailable')"));
        assert(h.run(kind + 'AccessToken()'), '5xx must preserve the existing session');
        h.state.refreshError = null;
        h.advance(2 * 3600000);
        await h.listeners.get('visibilitychange')();
        await h.run(kind === 'teacher' ? 'ensureTeacherAccessToken()' : 'ensureStudentAccessToken()');
        assert(h.run("sessionJwtExpiresAt(" + kind + "AccessToken()) > Date.now()"));
        // An unrecoverable/repeated expiry is bounded, never an infinite retry loop.
        h.state.serverError = { status: 401, body: { message: 'JWT expired' } };
        const count = h.state.requests.length;
        await h.run("db.rpc('expired_again')");
        assert.equal(h.state.requests.length, count + 2);
        assert.equal(h.run(kind + 'AccessToken()'), null);
        if (kind === 'student') assert.equal(h.run('studentSecurePathActive()'), true);
    }

    const expired = harness();
    await expired.login();
    expired.advance(13 * 3600000);
    expired.state.refreshError = 'invalid_token';
    await assert.rejects(expired.run("db.rpc('expired_family')"));
    assert.equal(expired.state.requests.length, 0);
    assert.equal(expired.state.expired, 1);
    assert.equal(expired.storage.size, 0);

    const noIdentity = harness('student');
    await assert.rejects(noIdentity.run('initStudentSession({})'), /student_auth_no_initdata/);
    assert.equal(noIdentity.state.clients, 0, 'enforced mode must never create an anonymous fallback client');
    const expiredStudent = harness('student');
    await expiredStudent.login();
    expiredStudent.advance(25 * 3600000);
    expiredStudent.state.refreshError = 'invalid_token';
    await assert.rejects(expiredStudent.run("db.rpc('expired_initdata')"), /Сессия ученика истекла/);
    assert.equal(expiredStudent.run('studentAccessToken()'), null);
    assert.equal(expiredStudent.run('studentSecurePathActive()'), true);

    const logout = harness();
    await logout.login();
    logout.advance(2 * 3600000);
    let release;
    logout.state.holdRefresh = new Promise(resolve => { release = resolve; });
    const refresh = logout.run('ensureTeacherAccessToken()');
    const rejection = assert.rejects(refresh, /session_changed/);
    const loggingOut = logout.run('teacherLogout()');
    release();
    await Promise.all([loggingOut, rejection]);
    assert.equal(logout.run('teacherAccessToken()'), null, 'late refresh cannot resurrect logged-out session');
    assert.equal(logout.storage.size, 0);
    console.log('PASS browser sessions: teacher/student sleep, parallel refresh, rejected JWT retry, exact write payload, no unsafe retries, network recovery, expiry, logout race.');
}

module.exports = { harness };
if (require.main === module) testSessions().catch(e => { console.error(e); process.exitCode = 1; });
