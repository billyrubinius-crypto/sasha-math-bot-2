// teacher-auth.js — teacher browser session adapter (T10-07, SPEC_T10 §§3.3, 6).
// Заменяет клиентскую проверку PASS (sasha2024) серверной identity (T10-05). Пароль отправляется
// ТОЛЬКО на teacher-auth Edge по HTTPS и нигде не сохраняется. Access JWT живёт ТОЛЬКО в памяти
// модуля (не localStorage/sessionStorage/лог); opaque refresh-токен — в sessionStorage (переживает
// reload той же вкладки, но не новую вкладку/окно — предсказуемо до explicit logout/истечения).
// Supabase client создаётся через поддерживаемую опцию accessToken (как js/student-auth.js).

const TEACHER_AUTH_URL = SUPABASE_URL + '/functions/v1/teacher-auth';
const TEACHER_REFRESH_URL = SUPABASE_URL + '/functions/v1/teacher-refresh';
const TEACHER_REFRESH_STORAGE_KEY = 'teacher_refresh_token';
const TEACHER_JWT_REFRESH_DELAY_MS = 55 * 60 * 1000; // JWT живёт 60 минут (SPEC §3.3)

let _teacherToken = null; // access JWT, только в памяти модуля
let _teacherRefreshTimer = null;

// Текущий JWT для прямых вызовов Edge Function (sign-upload, T10-09). Как и у ученика, токен
// остаётся в памяти модуля — не сохраняется и не логируется.
function teacherAccessToken() {
    return _teacherToken;
}

class TeacherAuthError extends Error {
    constructor(code) { super(code); this.code = code; }
}

async function _postTeacherAuthEndpoint(url, body) {
    let res;
    try {
        res = await fetch(url, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(body),
        });
    } catch (_e) {
        throw new TeacherAuthError('network_error');
    }
    const json = await res.json().catch(() => null);
    if (!res.ok || !json?.access_token) {
        throw new TeacherAuthError(json?.error || 'unknown_error');
    }
    return json;
}

function _applyTeacherSession(resp) {
    _teacherToken = resp.access_token;
    sessionStorage.setItem(TEACHER_REFRESH_STORAGE_KEY, resp.refresh_token);
    db = window.supabase.createClient(SUPABASE_URL, SUPABASE_KEY, {
        accessToken: async () => _teacherToken,
    });
    _scheduleTeacherRefresh();
}

function _clearTeacherSession() {
    if (_teacherRefreshTimer) clearTimeout(_teacherRefreshTimer);
    _teacherRefreshTimer = null;
    _teacherToken = null;
    sessionStorage.removeItem(TEACHER_REFRESH_STORAGE_KEY);
}

function _scheduleTeacherRefresh() {
    if (_teacherRefreshTimer) clearTimeout(_teacherRefreshTimer);
    _teacherRefreshTimer = setTimeout(async () => {
        const ok = await _silentTeacherRefresh();
        if (!ok) {
            _clearTeacherSession();
            if (typeof teacherSessionExpired === 'function') teacherSessionExpired();
        }
    }, TEACHER_JWT_REFRESH_DELAY_MS);
}

// true = JWT+refresh успешно ротированы; false = сессия недействительна (истекла, reuse
// обнаружен, kill-switch версии, сеть недоступна) — вызывающий должен показать экран логина.
async function _silentTeacherRefresh() {
    const stored = sessionStorage.getItem(TEACHER_REFRESH_STORAGE_KEY);
    if (!stored) return false;
    try {
        const resp = await _postTeacherAuthEndpoint(TEACHER_REFRESH_URL, { refresh_token: stored });
        _applyTeacherSession(resp);
        return true;
    } catch (_e) {
        return false;
    }
}

// Вызывается при старте страницы: пытается восстановить сессию по refresh-токену из
// sessionStorage (переживает reload той же вкладки). Возвращает true, если сессия жива.
async function tryResumeTeacherSession() {
    if (!sessionStorage.getItem(TEACHER_REFRESH_STORAGE_KEY)) return false;
    const ok = await _silentTeacherRefresh();
    if (!ok) sessionStorage.removeItem(TEACHER_REFRESH_STORAGE_KEY);
    return ok;
}

// Логин по паролю. Бросает TeacherAuthError с machine-кодом сервера (bad_request/
// origin_not_allowed/rate_limited/invalid_credentials/internal_error/network_error) —
// вызывающий показывает generic-сообщение (§3.3: не помогаем подбирать пароль).
async function teacherLogin(password) {
    const resp = await _postTeacherAuthEndpoint(TEACHER_AUTH_URL, { password });
    _applyTeacherSession(resp);
}

// Logout: очищает локальное состояние немедленно (JWT из памяти, refresh из sessionStorage).
// Явного "revoke по требованию" RPC клиенту не выдано (добавление отдельного примитива
// потребовало бы новой migration — вне scope T10-07 "без migration"). Вместо этого — форсируем
// ОДНУ дополнительную ротацию сохранённым refresh-токеном и результат отбрасываем:
// teacher_session_rotate (036) сам помечает предъявленный токен rotated+revoked при успехе, а
// новый токен, который она вернёт, нигде не сохраняется и не используется — он немедленно
// недостижим с этого клиента. Осиротевшая строка семьи истечёт сама (жёсткий дедлайн 12h).
async function teacherLogout() {
    const stored = sessionStorage.getItem(TEACHER_REFRESH_STORAGE_KEY);
    if (stored) {
        try { await _postTeacherAuthEndpoint(TEACHER_REFRESH_URL, { refresh_token: stored }); }
        catch (_e) { /* best effort — очистка ниже выполняется в любом случае */ }
    }
    _clearTeacherSession();
    db = undefined;
}
