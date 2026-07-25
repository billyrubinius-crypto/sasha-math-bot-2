// student-app.js — финальная инициализация/оркестрация (R01)

        // --- Telegram Theme (Cosmic Academy, этап 1) ---
        // Проставляет активную тему для CSS-токенов (html[data-ca-theme]) и подкрашивает
        // хром Telegram под фон Mini App. Методы SDK опциональны: старые клиенты часть из них
        // не знают, поэтому каждый вызов идёт через feature detection и try/catch — ошибка темы
        // не должна ломать старт приложения. Порядок инициализации не меняется.
        function applyTelegramTheme(tg) {
            try {
                const scheme = tg && tg.colorScheme === 'dark' ? 'dark'
                    : (tg && tg.colorScheme === 'light' ? 'light' : null);
                if (scheme) document.documentElement.setAttribute('data-ca-theme', scheme);
            } catch (_e) { /* тема — косметика, стартовать без неё можно */ }

            let appBg = '';
            try {
                appBg = getComputedStyle(document.documentElement).getPropertyValue('--ca-bg-app').trim();
            } catch (_e) { appBg = ''; }
            if (!/^#[0-9a-fA-F]{6}$/.test(appBg)) return;

            const supports = (v) => {
                try { return typeof tg.isVersionAtLeast !== 'function' ? false : tg.isVersionAtLeast(v); }
                catch (_e) { return false; }
            };
            if (typeof tg.setBackgroundColor === 'function' && supports('6.1')) {
                try { tg.setBackgroundColor(appBg); } catch (_e) {}
            }
            // Hex для шапки поддерживается с 6.9; на более старых клиентах шапку не трогаем.
            if (typeof tg.setHeaderColor === 'function' && supports('6.9')) {
                try { tg.setHeaderColor(appBg); } catch (_e) {}
            }
            if (typeof tg.setBottomBarColor === 'function' && supports('7.10')) {
                try { tg.setBottomBarColor(appBg); } catch (_e) {}
            }
        }

        document.addEventListener('DOMContentLoaded', async () => {
            try {
                const tg = window.Telegram.WebApp;
                tg.ready(); tg.expand();

                // Тема применяется сразу после ready/expand и переприменяется по themeChanged,
                // чтобы смена темы Telegram не требовала перезагрузки Mini App.
                applyTelegramTheme(tg);
                try {
                    if (typeof tg.onEvent === 'function') {
                        tg.onEvent('themeChanged', () => applyTelegramTheme(tg));
                    }
                } catch (_e) { /* подписка недоступна — тема останется стартовой */ }

                const tgUser = tg.initDataUnsafe?.user; // косметика (имя/аватар) до подтверждения auth

                let session = null;
                try {
                    session = await initStudentSession(tg);
                } catch (e) {
                    log('❌ student-auth: ' + e.message);
                    document.getElementById('user-name').innerText = 'Откройте приложение заново';
                    return;
                }

                if (session) {
                    db = session.db;
                    currentUser = tgUser ? { ...tgUser, id: session.telegramId } : { id: session.telegramId };
                } else {
                    db = window.supabase.createClient(SUPABASE_URL, SUPABASE_KEY);

                    if (tgUser && tgUser.id) {
                        currentUser = tgUser;
                    } else {
                        currentUser = null;
                        document.getElementById('user-name').innerText = 'Ошибка доступа';
                        log('❌ Нет данных пользователя.');
                        return;
                    }
                }

                document.getElementById('user-name').innerText = currentUser.first_name;
                setupAvatar(currentUser);
                
                // 1. Активируем задания, если пора
                await checkAndActivateAssignments();
                
                // 2. Загружаем профиль и активные задания
                await loadProfile();
                await loadActiveAssignments();

                // 3. Блок «Сегодня» (Stage 4, U04) — единственная точка подключения; сам блок
                // не обновляется при переключении вкладок (loadProfile этого не делает для
                // него), только при полной перезагрузке страницы, как и было решено в карточке.
                await loadTodayQuests();
            } catch (e) {
                log('❌ КРИТИЧЕСКАЯ ОШИБКА ИНИЦИАЛИЗАЦИИ: ' + e.message);
                document.getElementById('user-name').innerText = 'Ошибка запуска';
            }
        });

