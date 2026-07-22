// student-core.js — глобальное состояние, безопасные helpers, bootstrap-helpers и навигация (R01, механический вынос из index.html)
        // --- КОНФИГУРАЦИЯ ---
        // SUPABASE_URL/KEY и CLOUDINARY_* вынесены в shared.js (F4) — здесь только index-специфичное.
        // Бот для родителей — username нужен для ссылки-приглашения
        const PARENT_BOT_USERNAME = 'sashamathparents_bot';
        
        let currentUser = null;
        let db = null;
        let selectedFiles = [];
        let activeAssignments = [];

        function log(msg) { console.log(msg); }

        // esc(), getTodayMSK(), normalizeUrl(), pluralBubliks() — в shared.js (F4).

        // Момент времени, соответствующий указанным часам/минутам по московскому времени (МСК = UTC+3 круглый год)
        function moscowDateTimeToInstant(y, m, d, hh, mm) {
            return new Date(Date.UTC(y, m - 1, d, hh, mm) - 3 * 60 * 60 * 1000);
        }

        // Одноразовое приглашение для родителей/родственников (T10-10B, миграция 044).
        // Раньше в ссылке лежал telegram_id ученика — знание ID давало доступ к результатам.
        // Теперь сервер выдаёт случайный токен: он живёт 24 часа, срабатывает ровно один раз и
        // ничего не сообщает о самом ученике. Ссылку нужно генерировать заново на каждого родителя.
        async function inviteParent() {
            if (!currentUser) return;

            let token = null;
            try {
                const { data, error } = await db.rpc('create_parent_invite_self');
                if (error) throw error;
                token = data;
            } catch (e) {
                log('inviteParent: ' + (e.message || e));
            }

            if (!token) {
                alert('Не удалось создать приглашение. Попробуй ещё раз чуть позже.');
                return;
            }

            const inviteLink = `https://t.me/${PARENT_BOT_USERNAME}?start=${token}`;
            const shareText = 'Подключись к моим результатам в Sasha Math!';
            const shareUrl = `https://t.me/share/url?url=${encodeURIComponent(inviteLink)}&text=${encodeURIComponent(shareText)}`;
            window.Telegram.WebApp.openTelegramLink(shareUrl);
        }

        function setupAvatar(user) {
            const container = document.getElementById('user-avatar-container');
            if (user.photo_url) {
                container.innerHTML = `<img src="${user.photo_url}" class="avatar-img">`;
            } else {
                const initial = user.first_name ? user.first_name[0].toUpperCase() : '?';
                container.innerHTML = `<div class="avatar-placeholder">${esc(initial)}</div>`;
            }
        }

        // --- НАВИГАЦИЯ ---
        async function switchTab(tabName) {
            document.querySelectorAll('.screen').forEach(el => el.classList.remove('active'));
            document.querySelectorAll('.nav-btn').forEach(el => el.classList.remove('active'));

            if (tabName === 'profile') {
                document.getElementById('screen-profile').classList.add('active');
                document.querySelectorAll('.nav-btn')[0].classList.add('active');
                loadProfile();
            } else if (tabName === 'homework') {
                document.getElementById('screen-homework').classList.add('active');
                document.querySelectorAll('.nav-btn')[1].classList.add('active');
                loadMyHomework();
                await loadActiveAssignments();
            } else if (tabName === 'leaderboard') {
                document.getElementById('screen-leaderboard').classList.add('active');
                document.querySelectorAll('.nav-btn')[2].classList.add('active');
                loadLeaderboard();
            } else if (tabName === 'shop') {
                document.getElementById('screen-shop').classList.add('active');
                document.querySelectorAll('.nav-btn')[3].classList.add('active');
                loadShop();
            } else if (tabName === 'more') {
                document.getElementById('screen-more').classList.add('active');
                document.querySelectorAll('.nav-btn')[4].classList.add('active');
            }
        }

        async function switchHwTab(viewName) {
            document.querySelectorAll('.hw-view').forEach(el => el.classList.remove('active'));
            document.querySelectorAll('.tab-btn').forEach(el => el.classList.remove('active'));
            
            if (viewName === 'upload') {
                document.getElementById('hw-upload').classList.add('active');
                document.querySelectorAll('.tab-btn')[0].classList.add('active');
                await loadActiveAssignments();
            } else {
                document.getElementById('hw-archive').classList.add('active');
                document.querySelectorAll('.tab-btn')[1].classList.add('active');
                loadMyHomework();
            }
        }
