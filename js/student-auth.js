// student-auth.js — student browser session adapter, shadow mode (T10-03, SPEC_T10 §§3.2, 6).
// Подключается ПОСЛЕ shared.js (SUPABASE_URL/KEY) и ПЕРЕД student-app.js. Вызывает Edge Function
// student-auth (T10-02, публичная, --no-verify-jwt) сырым Telegram.WebApp.initData, получает
// 60-минутный JWT и создаёт authenticated Supabase client через supported accessToken-опцию.
// Identity после успешного auth берётся только из claims JWT (telegram_id), не из initDataUnsafe.
// Токен живёт только в памяти модуля — не localStorage, не sessionStorage, не лог.

// Режим: 'legacy' — старый anon-путь без auth; 'shadow' — auth обязателен для диагностики, но
// controlled fallback на legacy разрешён явным флагом ниже; 'enforced' — fallback запрещён.
const STUDENT_AUTH_MODE = 'shadow';
// Явный runtime flag controlled fallback (SPEC §6, шаг 2). true — при недоступности/ошибке
// auth в shadow-режиме используется старый anon-путь, чтобы не ломать dev/диагностику.
const STUDENT_AUTH_SHADOW_FALLBACK = true;

const STUDENT_AUTH_URL = SUPABASE_URL + '/functions/v1/student-auth';
const STUDENT_JWT_REFRESH_DELAY_MS = 55 * 60 * 1000; // SPEC §3.2: JWT живёт 60 минут

let _studentToken = null;
let _refreshTimer = null;
let _secureActive = false; // true — установлена authenticated session (JWT), secure gateway-путь активен

// Активен ли secure path (есть подтверждённый JWT). Клиентские writes при true идут через
// серверные gateway (T10-04A+); при false работает legacy-путь (shadow fallback / legacy mode).
function studentSecurePathActive() {
    return _secureActive;
}

function _decodeJwtPayload(jwt) {
    try {
        const part = jwt.split('.')[1];
        const b64 = part.replace(/-/g, '+').replace(/_/g, '/');
        return JSON.parse(decodeURIComponent(escape(atob(b64))));
    } catch (_e) {
        return null;
    }
}

async function _requestStudentToken(rawInitData) {
    const res = await fetch(STUDENT_AUTH_URL, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ initData: rawInitData }),
    });
    const body = await res.json().catch(() => null);
    if (!res.ok || !body?.access_token) throw new Error('student_auth_failed');
    return body.access_token;
}

function _scheduleStudentTokenRefresh(rawInitData) {
    if (_refreshTimer) clearTimeout(_refreshTimer);
    _refreshTimer = setTimeout(async () => {
        try {
            _studentToken = await _requestStudentToken(rawInitData);
            _scheduleStudentTokenRefresh(rawInitData);
        } catch (_e) {
            log('⚠️ student-auth: не удалось обновить токен, следующий вызов Supabase получит устаревший JWT.');
        }
    }, STUDENT_JWT_REFRESH_DELAY_MS);
}

// Возвращает { db, telegramId } при успешном auth, или null, если auth не используется/недоступен
// и режим разрешает controlled fallback на legacy anon-путь. Бросает исключение, если auth
// обязателен (enforced, либо shadow без разрешённого fallback) и не удался.
async function initStudentSession(tg) {
    if (STUDENT_AUTH_MODE === 'legacy') return null;

    const rawInitData = tg?.initData;
    const fallbackAllowed = STUDENT_AUTH_MODE === 'shadow' && STUDENT_AUTH_SHADOW_FALLBACK;

    if (!rawInitData) {
        if (fallbackAllowed) return null;
        throw new Error('student_auth_no_initdata');
    }

    let token;
    try {
        token = await _requestStudentToken(rawInitData);
    } catch (e) {
        if (fallbackAllowed) return null;
        throw e;
    }

    const claims = _decodeJwtPayload(token);
    const telegramId = claims?.telegram_id ? Number(claims.telegram_id) : null;
    if (!telegramId) {
        if (fallbackAllowed) return null;
        throw new Error('student_auth_bad_claims');
    }

    _studentToken = token;
    _scheduleStudentTokenRefresh(rawInitData);

    const authedDb = window.supabase.createClient(SUPABASE_URL, SUPABASE_KEY, {
        accessToken: async () => _studentToken,
    });

    _secureActive = true; // JWT подтверждён — secure gateway-путь активен
    return { db: authedDb, telegramId };
}
