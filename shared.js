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

// Cloudinary — один аккаунт на обе страницы (ученик грузит фото ДЗ, учитель — PDF заданий)
const CLOUDINARY_CLOUD_NAME = 'ddrn3vxm0';
const CLOUDINARY_UPLOAD_PRESET = 'sasha-math-dz';

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
