// student-pets.js — питомец в шапке профиля и его раскрывающаяся карточка (Stage 5, V3).
//
// Контракт: всё состояние приходит с сервера (get_pet_state_self). Клиент не считает ни
// настроение, ни цену, ни остаток сытости, ни доступность кормления — он только показывает.
//
// Визуалы — явный allowlist по образцу season-cosmetics.js: из БД принимается только
// pet_v1_cat / pet_v1_owl / pet_v1_capybara. Произвольный render_payload не рендерится вовсе.
//
// Механика раскрытия повторяет визитку сезонного профиля (openSeasonProfileCard): бэкдроп,
// крестик, Escape, кнопка «Назад» через history и возврат фокуса на плитку.
        const PET_VISUALS = {
            pet_v1_cat:      { glyph: '🐱', cls: 'pet-art-cat',      name: 'Кот' },
            pet_v1_owl:      { glyph: '🦉', cls: 'pet-art-owl',      name: 'Сова' },
            pet_v1_capybara: { glyph: '🦫', cls: 'pet-art-capybara', name: 'Капибара' }
        };

        // Подписи настроения задаёт сервер кодом; клиент только переводит код в текст.
        // sleeping — общее состояние (overall_mood), остальные приходят и как ось питания.
        const PET_MOODS = {
            sleeping:    { badge: '😴', short: 'Спит',         long: 'Спит' },
            tired:       { badge: '🥱', short: 'Не выспался',  long: 'Выспаться бы' },
            happy:       { badge: '😊', short: 'Доволен',      long: 'Сыт и доволен' },
            fed:         { badge: '🙂', short: 'Накормлен',    long: 'Накормлен на сегодня' },
            hungry_soon: { badge: '😐', short: 'Скоро проголодается', long: 'Сегодня последний сытый день' },
            hungry:      { badge: '😢', short: 'Голоден',      long: 'Проголодался и грустит' }
        };

        // Вторая ось заботы — отдых. Бесплатная: сон платится вниманием, а не бубликами.
        const PET_REST = {
            sleeping: 'Спит',
            rested:   'Выспался и бодрый',
            tired:    'Давно не спал'
        };

        let petState = null;
        let petBusy = false;            // синхронная защита от двойного клика (урок W05/U08A)
        let petCardTrigger = null;
        let petCardHistoryEntry = false;

        function petVisual(state) {
            if (!state || !state.render_payload) return null;
            return PET_VISUALS[state.render_payload] || null;
        }

        function petFormatDate(value) {
            if (!value) return '';
            const parts = String(value).split('-');
            if (parts.length !== 3) return '';
            // Собираем локальную дату из частей: строка YYYY-MM-DD в new Date() читается как UTC
            // и на московском времени уезжает на день назад.
            const date = new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2]));
            if (Number.isNaN(date.getTime())) return '';
            return date.toLocaleDateString('ru-RU', { day: 'numeric', month: 'long' });
        }

        // Относительное время вместо абсолютного: сервер отдаёт timestamptz, а часовой пояс
        // устройства может не совпадать с московским — «через 5 ч» honest, «в 07:30» нет.
        function petRelative(iso, bare) {
            const target = iso ? new Date(iso) : null;
            if (!target || Number.isNaN(target.getTime())) return bare ? 'какое-то время' : 'скоро';
            const minutes = Math.max(0, Math.round((target - Date.now()) / 60000));
            const hours = Math.floor(minutes / 60);
            const rest = minutes % 60;
            const text = hours > 0
                ? `${hours} ч${rest > 0 ? ' ' + rest + ' мин' : ''}`
                : `${minutes} мин`;
            return bare ? text : `через ${text}`;
        }

        function petPluralDays(n) {
            const mod10 = n % 10, mod100 = n % 100;
            if (mod10 === 1 && mod100 !== 11) return 'день';
            if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) return 'дня';
            return 'дней';
        }

        async function loadPetBlock() {
            const tile = document.getElementById('pet-tile');
            const header = document.querySelector('.profile-header');
            if (!tile || !header) return;

            // Прямые feed_pet/get_pet_state отозваны у authenticated: без JWT показывать нечего.
            if (!studentSecurePathActive()) { petHide(); return; }

            try {
                const { data, error } = await db.rpc('get_pet_state_self');
                if (error) throw error;
                petState = data || null;
            } catch (error) {
                petHide();
                log('⚠️ Питомец: ' + (error.message || error));
                return;
            }

            if (!petState || !petState.enabled || !petState.item_code) { petHide(); return; }
            const visual = petVisual(petState);
            if (!visual) { petHide(); return; }   // неизвестный визуал — молча не рендерим

            // На плитке — общее состояние: худшее из двух осей заботы, сон показывается отдельно.
            const overall = petState.overall_mood || petState.mood;
            const art = document.getElementById('pet-tile-art');
            const mood = PET_MOODS[overall] || PET_MOODS.hungry;
            art.textContent = visual.glyph;
            art.className = `pet-art ${visual.cls}`;
            document.getElementById('pet-tile-mood').textContent = mood.badge;
            tile.className = `pet-tile pet-mood-${overall}`;
            tile.setAttribute('aria-label', `${visual.name}: ${mood.short}. Открыть карточку питомца`);
            tile.style.display = 'grid';
            header.classList.add('has-pet');

            if (!document.getElementById('pet-card-overlay').hidden) renderPetCard();
        }

        function petHide() {
            const tile = document.getElementById('pet-tile');
            const header = document.querySelector('.profile-header');
            if (tile) tile.style.display = 'none';
            if (header) header.classList.remove('has-pet');
            closePetCard();
        }

        function renderPetCard() {
            if (!petState) return;
            const visual = petVisual(petState);
            if (!visual) return;
            const overall = petState.overall_mood || petState.mood;
            const mood = PET_MOODS[overall] || PET_MOODS.hungry;
            const days = Number(petState.days_left) || 0;
            const price = Number(petState.feed_price) || 0;
            const max = Number(petState.max_prepaid_days) || 0;

            const art = document.getElementById('pet-card-art');
            art.textContent = visual.glyph;
            art.className = `pet-card-art pet-art ${visual.cls}`;
            document.getElementById('pet-card-name').textContent = visual.name;
            document.getElementById('pet-card-mood').textContent = mood.long;
            document.getElementById('pet-card-mood').className = `pet-card-mood pet-mood-${overall}`;

            // Ось отдыха отдельной строкой: две оси заботы независимы и показываются раздельно.
            const restEl = document.getElementById('pet-card-rest');
            const sleepBtn = document.getElementById('pet-sleep-btn');
            const rest = petState.rest_state;
            if (rest) {
                let restText = PET_REST[rest] || '';
                if (rest === 'sleeping') {
                    restText = `Спит, проснётся ${petRelative(petState.sleep_ends_at)}`;
                } else if (rest === 'rested' && petState.rested_until) {
                    restText = `Выспался, бодрый ещё ${petRelative(petState.rested_until, true)}`;
                }
                restEl.textContent = restText;
                restEl.className = `pet-card-rest pet-rest-${rest}`;
                sleepBtn.textContent = rest === 'sleeping' ? 'Уже спит' : 'Уложить спать';
                sleepBtn.disabled = !petState.can_sleep || petBusy;
                sleepBtn.style.display = 'inline-flex';
            } else {
                restEl.textContent = '';
                sleepBtn.style.display = 'none';
            }

            document.getElementById('pet-card-satiety').textContent = days > 0
                ? `Сыт до ${petFormatDate(petState.satiety_until)} — это ещё ${days} ${petPluralDays(days)}`
                : 'Сегодня ещё не кормлен';

            const feedBtn = document.getElementById('pet-feed-btn');
            const fillBtn = document.getElementById('pet-feed-more');
            const full = days >= max;
            feedBtn.textContent = full ? 'Сыт на всю неделю' : `Покормить — ${price} 🥯`;
            feedBtn.disabled = full || petBusy;

            // Запас вперёд — вторичное действие: одна кнопка добирает сытость до потолка.
            // Свободная ёмкость = потолок минус уже оплаченные дни (включая сегодняшний), ровно
            // столько дней и оплатит сервер: v_start..today + max - 1. Показываем кнопку только
            // когда она делает больше основной, то есть от двух дней.
            const fillDays = Math.max(0, max - days);
            if (fillDays >= 2) {
                fillBtn.textContent = `Ещё ${fillDays} ${petPluralDays(fillDays)} — ${fillDays * price} 🥯`;
                fillBtn.dataset.days = String(fillDays);
                fillBtn.disabled = petBusy;
                fillBtn.style.display = 'inline-flex';
            } else {
                fillBtn.style.display = 'none';
            }

            const total = Number(petState.days_fed_total) || 0;
            document.getElementById('pet-card-total').textContent =
                total > 0 ? `Всего дней заботы: ${total}` : 'Забота только начинается';
        }

        function openPetCard(trigger) {
            const overlay = document.getElementById('pet-card-overlay');
            if (!overlay || !petState || !petState.item_code) return;
            petCardTrigger = trigger || document.getElementById('pet-tile');
            document.getElementById('pet-card-error').textContent = '';
            renderPetCard();
            overlay.hidden = false;
            document.body.classList.add('pet-card-open');
            if (!petCardHistoryEntry) {
                try {
                    history.pushState({ petCard: true }, '');
                    petCardHistoryEntry = true;
                } catch (_error) {
                    petCardHistoryEntry = false;
                }
            }
            overlay.querySelector('.pet-card-close').focus();
        }

        function closePetCard(fromPopstate) {
            const overlay = document.getElementById('pet-card-overlay');
            if (!overlay || overlay.hidden) return;
            overlay.hidden = true;
            document.body.classList.remove('pet-card-open');
            if (petCardTrigger) petCardTrigger.focus();
            petCardTrigger = null;
            if (petCardHistoryEntry) {
                petCardHistoryEntry = false;
                if (!fromPopstate) history.back();
            }
        }

        function feedPetFill(btn) {
            feedPet(Number(btn && btn.dataset.days) || 1, btn);
        }

        // Сон бесплатен и заканчивается сам через pet_sleep_hours: будить руками не нужно,
        // иначе механика наказывала бы за то, что человек не открыл приложение в нужный час.
        async function putPetToSleep(btn) {
            if (petBusy || (btn && btn.disabled)) return;
            petBusy = true;
            const sleepBtn = document.getElementById('pet-sleep-btn');
            const errorEl = document.getElementById('pet-card-error');
            const restore = sleepBtn.textContent;
            sleepBtn.disabled = true;
            errorEl.textContent = '';
            sleepBtn.textContent = 'Укладываем...';
            try {
                const { error } = await db.rpc('put_pet_to_sleep_self');
                if (error) throw error;
                await loadPetBlock();
            } catch (error) {
                sleepBtn.textContent = restore;
                errorEl.textContent = error.message || String(error);
            } finally {
                petBusy = false;
                renderPetCard();
            }
        }

        // Кормление: ровно один RPC за действие, кнопка блокируется синхронно ДО await.
        // Идемпотентность по календарной дате обеспечивает сервер, клиент её не дублирует.
        async function feedPet(days, btn) {
            if (petBusy || (btn && btn.disabled)) return;
            petBusy = true;
            const feedBtn = document.getElementById('pet-feed-btn');
            const fillBtn = document.getElementById('pet-feed-more');
            const errorEl = document.getElementById('pet-card-error');
            const restore = feedBtn.textContent;
            feedBtn.disabled = true;
            fillBtn.disabled = true;
            errorEl.textContent = '';
            if (btn === feedBtn) feedBtn.textContent = 'Кормим...';

            try {
                const { data, error } = await db.rpc('feed_pet_self', { p_days: days });
                if (error) throw error;
                if (data && typeof data.balance === 'number') {
                    document.getElementById('val-huikons').innerText = data.balance;
                }
                await loadPetBlock();       // состояние и настроение перечитываем с сервера
                renderPetCard();
            } catch (error) {
                feedBtn.textContent = restore;
                errorEl.textContent = error.message || String(error);
            } finally {
                petBusy = false;
                renderPetCard();
            }
        }

        document.addEventListener('keydown', (event) => {
            if (event.key === 'Escape') closePetCard();
        });
        window.addEventListener('popstate', () => {
            if (petCardHistoryEntry) closePetCard(true);
        });
