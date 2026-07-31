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
            pet_v1_cat:      { key: 'cat',      cls: 'pet-art-cat',      name: 'Кот' },
            pet_v1_owl:      { key: 'owl',      cls: 'pet-art-owl',      name: 'Сова' },
            pet_v1_capybara: { key: 'capybara', cls: 'pet-art-capybara', name: 'Капибара' }
        };

        // Питомец рисуется ЦЕЛИКОМ, а не портретом: в маленьком окне фигура читается
        // лучше бюста, поэтому здесь свои SVG-силуэты, а не портретная система сезонных
        // аватаров. Формы — в JS, цвета — в styles/pets.css (классы pet-visual-*), чтобы
        // палитра правилась там же, где остальная косметика.
        const PET_FACES = {
            // Глаза и рот по состоянию заботы. Настроение приходит с сервера, здесь только
            // отражается: голод и усталость меняют лицо и ничего не отнимают.
            happy:       { eyes: 'open',   mouth: 'M27 30 q5 5 10 0' },
            fed:         { eyes: 'open',   mouth: 'M28 30 q4 3 8 0' },
            hungry_soon: { eyes: 'open',   mouth: 'M28 31 h8' },
            hungry:      { eyes: 'open',   mouth: 'M27 32 q5 -5 10 0' },
            tired:       { eyes: 'half',   mouth: 'M28 31 h8' },
            sleeping:    { eyes: 'closed', mouth: 'M29 31 h6' }
        };

        function petFace(mood) {
            const face = PET_FACES[mood] || PET_FACES.fed;
            const eyes = face.eyes === 'closed'
                ? '<path class="pet-line" d="M23 24 q3 3 6 0"/><path class="pet-line" d="M35 24 q3 3 6 0"/>'
                : face.eyes === 'half'
                    ? '<path class="pet-line" d="M23 25 q3 -3 6 0"/><path class="pet-line" d="M35 25 q3 -3 6 0"/>'
                    : '<circle class="pet-ink" cx="26" cy="24" r="2.6"/><circle class="pet-ink" cx="38" cy="24" r="2.6"/>'
                      + '<circle class="pet-spark" cx="27" cy="23" r="0.9"/><circle class="pet-spark" cx="39" cy="23" r="0.9"/>';
            return eyes + `<path class="pet-line" d="${face.mouth}"/>`;
        }

        // Каждый силуэт — целая фигура: голова, туловище, лапы и хвост в одном кадре 64×64.
        const PET_SHAPES = {
            cat: (mood) => `
                <path class="pet-body" d="M46 50 q9 -3 8 -12 q-1 -6 -5 -5 q-4 1 -3 7"/>
                <ellipse class="pet-body" cx="32" cy="45" rx="15" ry="12"/>
                <ellipse class="pet-belly" cx="32" cy="48" rx="8" ry="7"/>
                <path class="pet-body" d="M20 16 L23 5 L30 13 Z"/>
                <path class="pet-body" d="M44 16 L41 5 L34 13 Z"/>
                <circle class="pet-body" cx="32" cy="24" r="13"/>
                <path class="pet-line" d="M14 22 h6 M14 26 h6 M44 22 h6 M44 26 h6"/>
                ${petFace(mood)}
                <circle class="pet-body" cx="24" cy="55" r="4"/>
                <circle class="pet-body" cx="40" cy="55" r="4"/>`,
            owl: (mood) => `
                <path class="pet-body" d="M22 14 L24 5 L30 12 Z"/>
                <path class="pet-body" d="M42 14 L40 5 L34 12 Z"/>
                <ellipse class="pet-body" cx="32" cy="34" rx="17" ry="21"/>
                <ellipse class="pet-belly" cx="32" cy="40" rx="10" ry="13"/>
                <path class="pet-body" d="M15 30 q-3 12 4 18 q3 -9 2 -18 Z"/>
                <path class="pet-body" d="M49 30 q3 12 -4 18 q-3 -9 -2 -18 Z"/>
                <circle class="pet-belly" cx="26" cy="24" r="7"/>
                <circle class="pet-belly" cx="38" cy="24" r="7"/>
                ${petFace(mood)}
                <path class="pet-beak" d="M30 29 h4 l-2 4 Z"/>
                <path class="pet-line" d="M27 57 v-4 M32 57 v-4 M37 57 v-4"/>`,
            capybara: (mood) => `
                <ellipse class="pet-body" cx="34" cy="42" rx="19" ry="13"/>
                <ellipse class="pet-belly" cx="36" cy="46" rx="12" ry="7"/>
                <circle class="pet-body" cx="24" cy="55" r="4"/>
                <circle class="pet-body" cx="44" cy="55" r="4"/>
                <circle class="pet-body" cx="20" cy="12" r="3"/>
                <circle class="pet-body" cx="44" cy="12" r="3"/>
                <ellipse class="pet-body" cx="32" cy="24" rx="15" ry="12"/>
                <ellipse class="pet-belly" cx="32" cy="31" rx="9" ry="6"/>
                ${petFace(mood)}
                <ellipse class="pet-ink" cx="32" cy="30" rx="2.2" ry="1.6"/>`
        };

        // Структура превью: одно окно фиксированного размера, внутри — целая фигура.
        function petArtNode(visual, size, mood) {
            const wrap = document.createElement('span');
            wrap.className = `pet-figure pet-visual-${visual.key} pet-face-${mood || 'fed'}`;
            wrap.style.setProperty('--pet-size', `${size}px`);
            const shape = PET_SHAPES[visual.key];
            if (!shape) return wrap;
            wrap.innerHTML =
                `<svg class="pet-svg" viewBox="0 0 64 64" aria-hidden="true" focusable="false">`
                + shape(mood || 'fed') + `</svg>`;
            return wrap;
        }

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
            art.replaceChildren(petArtNode(visual, 44, overall));
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
            art.replaceChildren(petArtNode(visual, 96, overall));
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
