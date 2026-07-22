// shared.js — общие константы и утилиты для index.html и teacher.html (Bot 2.0, задача F4).
// Подключается тегом <script src="shared.js"></script> в <head> ОБЕИХ страниц, ДО инлайн-кода,
// который эти константы/функции использует (иначе ReferenceError при первом вызове).
//
// Сюда переносится только то, что реально дублировалось в обоих файлах один-в-один. Функции,
// встречающиеся лишь в одном файле (moscowDateTimeToInstant, addDaysToDate, daysBetweenDates,
// pluralShields), остаются на своих местах — это не дублирование.
//
// Bot 2.0 dev-окружение — НЕ прод. См. bot2/BOT2_CONTEXT.md в приватном репозитории.

const SUPABASE_URL = 'https://ewwmsoecabfdldccrjfc.supabase.co';
const SUPABASE_KEY = 'sb_publishable_LB2cXXcEvYODJMzOa6rJ-A_8dhmGE4b';

// Cloudinary — один аккаунт на обе страницы (ученик грузит фото ДЗ, учитель — PDF заданий).
// T10-09: unsigned preset удалён. Клиент НИКОГДА не отправляет upload_preset и не выбирает
// folder/public_id/resource_type — всё это приходит подписанным из Edge Function sign-upload
// (cloud_name тоже отдаёт сервер, поэтому отдельная константа больше не нужна).
const SIGN_UPLOAD_URL = SUPABASE_URL + '/functions/v1/sign-upload';

// Загружает файл в Cloudinary через серверную подпись и возвращает secure_url.
//   kind         — 'student_photo' | 'teacher_pdf' (политику сервер проверяет по роли в JWT);
//   accessToken  — JWT текущего actor, живёт только в памяти адаптера сессии;
//   assignmentId — только для student_photo (сервер проверяет владение заданием).
async function uploadSignedToCloudinary(file, kind, accessToken, assignmentId) {
    if (!accessToken) throw new Error('Нет активной сессии — открой приложение заново');

    const signRes = await fetch(SIGN_UPLOAD_URL, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + accessToken },
        body: JSON.stringify({
            kind: kind,
            filename: file.name,
            bytes: file.size,
            assignment_id: assignmentId || undefined
        })
    });
    const sign = await signRes.json().catch(() => null);
    if (!signRes.ok || !sign || !sign.signature) {
        if (sign && sign.error === 'file_too_large') throw new Error('Файл слишком большой');
        if (sign && sign.error === 'format_not_allowed') throw new Error('Недопустимый тип файла');
        throw new Error('Загрузка не разрешена');
    }

    const formData = new FormData();
    formData.append('file', file);
    formData.append('api_key', sign.api_key);
    formData.append('signature', sign.signature);
    // Подписанные сервером параметры уходят как есть — изменение любого ломает подпись.
    Object.keys(sign.params).forEach(k => formData.append(k, sign.params[k]));

    const res = await fetch(
        `https://api.cloudinary.com/v1_1/${sign.cloud_name}/${sign.resource_type}/upload`,
        { method: 'POST', body: formData }
    );
    if (!res.ok) throw new Error('Ошибка загрузки в Cloudinary');
    const data = await res.json();

    // Принимаем только ссылку своего аккаунта Cloudinary — чужой URL дальше в базу не пойдёт.
    if (typeof data.secure_url !== 'string' ||
        !data.secure_url.startsWith(`https://res.cloudinary.com/${sign.cloud_name}/`)) {
        throw new Error('Некорректная ссылка загрузки');
    }
    return data.secure_url;
}

// Экранирует пользовательский текст перед вставкой через innerHTML (имена, названия заданий,
// комментарии, названия групп и т.п. — всё, что вводит человек, а не сам код)
function esc(str) {
    const div = document.createElement('div');
    div.textContent = str ?? '';
    return div.innerHTML;
}

// Текущая дата в Москве (YYYY-MM-DD), не зависит от часового пояса устройства
function getTodayMSK() {
    return new Date().toLocaleDateString('en-CA', { timeZone: 'Europe/Moscow' });
}

// Ссылка без http(s):// браузер считает относительным путём текущей страницы — достраиваем схему
function normalizeUrl(url) {
    if (!url) return '';
    return /^https?:\/\//i.test(url) ? url : 'https://' + url;
}

// Склонение слова «бублик» по числу (1 бублик / 2 бублика / 5 бубликов) — Bot 2.0, G1
function pluralBubliks(n) {
    const abs = Math.abs(n);
    const mod10 = abs % 10, mod100 = abs % 100;
    if (mod10 === 1 && mod100 !== 11) return 'бублик';
    if (mod10 >= 2 && mod10 <= 4 && (mod100 < 10 || mod100 >= 20)) return 'бублика';
    return 'бубликов';
}
