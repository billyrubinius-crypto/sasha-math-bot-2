// student-app.js — финальная инициализация/оркестрация (R01)
        document.addEventListener('DOMContentLoaded', async () => {
            try {
                const tg = window.Telegram.WebApp;
                tg.ready(); tg.expand();

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

