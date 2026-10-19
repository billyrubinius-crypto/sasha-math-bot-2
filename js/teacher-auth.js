// Teacher JWT stays in memory; the rotating refresh token survives reload in this
// tab only. Request-time refresh also works after browser sleep/background throttling.
const TEACHER_AUTH_URL = SUPABASE_URL + '/functions/v1/teacher-auth';
const TEACHER_REFRESH_URL = SUPABASE_URL + '/functions/v1/teacher-refresh';
const TEACHER_REFRESH_STORAGE_KEY = 'teacher_refresh_token';
const TEACHER_JWT_REFRESH_DELAY_MS = 55 * 60 * 1000;
const TEACHER_REFRESH_MARGIN_MS = 60 * 1000;

let _teacherToken = null;
let _teacherRefreshTimer = null;
let _teacherRefreshPromise = null;
let _teacherSessionGeneration = 0;
let _teacherClient = null;

function teacherAccessToken() { return _teacherToken; }

class TeacherAuthError extends Error {
    constructor(code) { super(code); this.code = code; }
}

async function _postTeacherAuthEndpoint(url, body) {
    let res;
    try {
        res = await fetch(url, {
            method: 'POST', headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(body),
        });
    } catch { throw new TeacherAuthError('network_error'); }
    const json = await res.json().catch(() => null);
    if (!res.ok || !json?.access_token || !json?.refresh_token) {
        throw new TeacherAuthError(json?.error || 'unknown_error');
    }
    return json;
}

function _applyTeacherSession(resp) {
    _teacherToken = resp.access_token;
    sessionStorage.setItem(TEACHER_REFRESH_STORAGE_KEY, resp.refresh_token);
    if (!_teacherClient) {
        _teacherClient = window.supabase.createClient(SUPABASE_URL, SUPABASE_KEY, {
            accessToken: () => ensureTeacherAccessToken(),
            global: { fetch: createSessionFetch(ensureTeacherAccessToken, _expireTeacherSession) },
        });
    }
    db = _teacherClient;
    _scheduleTeacherRefresh();
}

function _clearTeacherSession() {
    ++_teacherSessionGeneration;
    if (_teacherRefreshTimer) clearTimeout(_teacherRefreshTimer);
    _teacherRefreshTimer = null;
    _teacherRefreshPromise = null;
    _teacherToken = null;
    _teacherClient = null;
    db = undefined;
    sessionStorage.removeItem(TEACHER_REFRESH_STORAGE_KEY);
}

function _expireTeacherSession() {
    const hadSession = !!(_teacherToken || sessionStorage.getItem(TEACHER_REFRESH_STORAGE_KEY));
    _clearTeacherSession();
    if (hadSession && typeof teacherSessionExpired === 'function') teacherSessionExpired();
}

function _scheduleTeacherRefresh(delay = TEACHER_JWT_REFRESH_DELAY_MS) {
    if (_teacherRefreshTimer) clearTimeout(_teacherRefreshTimer);
    _teacherRefreshTimer = setTimeout(() => {
        _refreshTeacherSession().catch(() => {
            if (sessionStorage.getItem(TEACHER_REFRESH_STORAGE_KEY)) _scheduleTeacherRefresh(60000);
        });
    }, delay);
}

function _refreshTeacherSession() {
    if (_teacherRefreshPromise) return _teacherRefreshPromise;
    const stored = sessionStorage.getItem(TEACHER_REFRESH_STORAGE_KEY);
    if (!stored) {
        _expireTeacherSession();
        return Promise.reject(new TeacherAuthError('session_expired'));
    }
    const generation = _teacherSessionGeneration;
    const pending = (async () => {
        try {
            const resp = await _postTeacherAuthEndpoint(TEACHER_REFRESH_URL, { refresh_token: stored });
            if (generation !== _teacherSessionGeneration) throw new TeacherAuthError('session_changed');
            _applyTeacherSession(resp);
            return _teacherToken;
        } catch (e) {
            if (generation === _teacherSessionGeneration && e.code === 'invalid_token') _expireTeacherSession();
            throw e;
        }
    })();
    _teacherRefreshPromise = pending;
    pending.finally(() => {
        if (_teacherRefreshPromise === pending) _teacherRefreshPromise = null;
    }).catch(() => {});
    return pending;
}

async function ensureTeacherAccessToken(rejectedToken) {
    if (_teacherRefreshPromise) return _teacherRefreshPromise;
    if (_teacherToken && sessionJwtExpiresAt(_teacherToken) > Date.now() + TEACHER_REFRESH_MARGIN_MS
        && (!rejectedToken || rejectedToken !== _teacherToken)) return _teacherToken;
    return _refreshTeacherSession();
}

async function _silentTeacherRefresh() {
    try { await _refreshTeacherSession(); return true; } catch { return false; }
}

async function tryResumeTeacherSession() {
    if (!sessionStorage.getItem(TEACHER_REFRESH_STORAGE_KEY)) return false;
    return _silentTeacherRefresh();
}

async function teacherLogin(password) {
    const generation = ++_teacherSessionGeneration;
    const resp = await _postTeacherAuthEndpoint(TEACHER_AUTH_URL, { password });
    if (generation !== _teacherSessionGeneration) throw new TeacherAuthError('session_changed');
    _applyTeacherSession(resp);
}

async function teacherLogout() {
    const stored = sessionStorage.getItem(TEACHER_REFRESH_STORAGE_KEY);
    _clearTeacherSession();
    if (stored) {
        try { await _postTeacherAuthEndpoint(TEACHER_REFRESH_URL, { refresh_token: stored }); }
        catch { /* best effort; the local session is already cleared */ }
    }
}

function _resumeTeacherAfterSleep() {
    if (document.visibilityState === 'hidden' || !_teacherToken) return;
    ensureTeacherAccessToken().catch(() => {
        if (sessionStorage.getItem(TEACHER_REFRESH_STORAGE_KEY)) _scheduleTeacherRefresh(60000);
    });
}
document.addEventListener('visibilitychange', _resumeTeacherAfterSleep);
window.addEventListener('focus', _resumeTeacherAfterSleep);
window.addEventListener('online', _resumeTeacherAfterSleep);
