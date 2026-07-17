// student-app.js — финальная инициализация/оркестрация (R01)
        document.addEventListener('DOMContentLoaded', async () => {
            try {
                const tg = window.Telegram.WebApp;
                tg.ready(); tg.expand();

                db = window.supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
                
                const tgUser = tg.initDataUnsafe?.user;
                
                if (tgUser && tgUser.id) {
                    currentUser = tgUser;
                } else {
                    currentUser = null;
                    document.getElementById('user-name').innerText = 'Ошибка доступа';
                    log('❌ Нет данных пользователя.');
                    return; 
                }

                document.getElementById('user-name').innerText = currentUser.first_name;
                setupAvatar(currentUser);
                
                // 1. Активируем задания, если пора
                await checkAndActivateAssignments();
                
                // 2. Загружаем профиль и активные задания
                await loadProfile();
                await loadActiveAssignments();
            } catch (e) {
                log('❌ КРИТИЧЕСКАЯ ОШИБКА ИНИЦИАЛИЗАЦИИ: ' + e.message);
                document.getElementById('user-name').innerText = 'Ошибка запуска';
            }
        });

