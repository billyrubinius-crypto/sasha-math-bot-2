// student-pets.js — питомец в шапке профиля и его комната (Stage 5, V3 + PET2).
//
// Контракт: всё состояние приходит с сервера (get_pet_state_self / get_pet_room_self). Клиент
// не считает ни настроение, ни цену, ни остаток сытости, ни кулдауны осей заботы, ни связь —
// он только показывает.
//
// Визуалы — явный allowlist по образцу season-cosmetics.js: из БД принимается только
// pet_v1_cat / pet_v1_owl / pet_v1_capybara. Произвольный render_payload не рендерится вовсе.
//
// Механика раскрытия комнаты повторяет визитку сезонного профиля (openSeasonProfileCard):
// бэкдроп, крестик, Escape, кнопка «Назад» через history и возврат фокуса на плитку.
//
// Правило комнаты (SPEC_STAGE5_PET_ROOM §6): просроченного не существует. Индикаторы осей
// внимания и игры показывают только «можно сейчас» или «можно снова через N» — никаких
// счётчиков пропусков и формулировок вины.
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

        // Ступень 2 (эволюция, PET4): та же фигура плюс отличительная черта — она добавляется
        // поверх базового силуэта, чтобы вид оставался узнаваемым. Имя вида не меняется:
        // «Кот» остаётся котом, иначе ученик решит, что питомца подменили.
        const PET_GROWN = {
            cat:      '<path class="pet-mane" d="M32 11 a13 13 0 0 1 13 13 a13 13 0 0 1 -26 0 a13 13 0 0 1 13 -13 Z"/>'
                    + '<path class="pet-accent" d="M24 37 h16 l-2 5 h-12 Z"/>',
            owl:      '<path class="pet-accent" d="M20 18 q12 -7 24 0 q-12 -3 -24 0 Z"/>'
                    + '<path class="pet-mane" d="M14 32 q-5 14 5 22 q4 -11 3 -22 Z"/>'
                    + '<path class="pet-mane" d="M50 32 q5 14 -5 22 q-4 -11 -3 -22 Z"/>',
            capybara: '<path class="pet-accent" d="M22 16 q10 -6 20 0 q-10 -2 -20 0 Z"/>'
                    + '<ellipse class="pet-mane" cx="34" cy="42" rx="19" ry="13"/>'
        };

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
        // stage приходит с сервера (get_pet_state.stage); на второй ступени поверх базового
        // силуэта добавляется отличительная черта.
        function petArtNode(visual, size, mood, stage) {
            const grown = Number(stage) === 2;
            const wrap = document.createElement('span');
            wrap.className = `pet-figure pet-visual-${visual.key} pet-face-${mood || 'fed'}`
                + (grown ? ' pet-stage-2' : '');
            wrap.style.setProperty('--pet-size', `${size}px`);
            const shape = PET_SHAPES[visual.key];
            if (!shape) return wrap;
            wrap.innerHTML =
                `<svg class="pet-svg" viewBox="0 0 64 64" aria-hidden="true" focusable="false">`
                + shape(mood || 'fed') + (grown ? (PET_GROWN[visual.key] || '') : '') + `</svg>`;
            return wrap;
        }

        // Предметы комнаты (PET3). Allowlist такой же явный, как у питомцев: из БД принимается
        // только перечисленный render_payload, произвольный не рисуется вовсе.
        const PET_ROOM_ITEMS = {
            bed_v1_pillow: '<rect class="item-soft" x="6" y="12" width="52" height="18" rx="9"/>'
                         + '<path class="item-line" d="M16 21 h32"/>',
            bed_v1_basket: '<path class="item-body" d="M8 12 h48 l-5 18 h-38 Z"/>'
                         + '<path class="item-line" d="M16 16 v12 M32 16 v12 M48 16 v12 M10 22 h44"/>',
            bed_v1_mat:    '<rect class="item-soft" x="4" y="16" width="56" height="12" rx="6"/>'
                         + '<path class="item-line" d="M16 16 v12 M32 16 v12 M48 16 v12"/>',
            toy_v1_ball:   '<circle class="item-body" cx="16" cy="16" r="12"/>'
                         + '<path class="item-line" d="M6 12 q10 6 20 0 M6 20 q10 -6 20 0"/>',
            toy_v1_yarn:   '<circle class="item-soft" cx="16" cy="16" r="12"/>'
                         + '<path class="item-line" d="M8 12 q8 10 16 8 M8 20 q10 -10 16 -6 M10 24 q6 -12 14 -10"/>',
            toy_v1_block:  '<rect class="item-body" x="4" y="4" width="24" height="24" rx="5"/>'
                         + '<path class="item-line" d="M11 22 v-11 h4 a4 4 0 0 1 0 8 h-4 M17 19 l5 3"/>'
        };

        function petRoomItemNode(payload, cls, viewBox) {
            const shape = payload ? PET_ROOM_ITEMS[payload] : null;
            if (!shape) return null;
            const wrap = document.createElement('span');
            // Класс по payload несёт палитру предмета: цвета живут в styles/pets.css рядом с
            // остальной косметикой, а не в разметке.
            wrap.className = `${cls} item-${payload.replace(/_/g, '-')}`;
            wrap.innerHTML = `<svg class="pet-item-svg" viewBox="${viewBox}" aria-hidden="true" focusable="false">`
                + shape + '</svg>';
            return wrap;
        }

        // Превью для витрины магазина: тот же код рисует товар, что и комната, поэтому
        // купленное совпадает с показанным. Вызывается из student-shop.js.
        function petShopPreviewNode(slot, payload) {
            if (slot === 'pet') {
                const visual = PET_VISUALS[payload];
                return visual ? petArtNode(visual, 44, 'happy') : null;
            }
            if (slot === 'pet_bed') return petRoomItemNode(payload, 'pet-shop-item pet-shop-bed', '0 0 64 32');
            if (slot === 'pet_toy') return petRoomItemNode(payload, 'pet-shop-item pet-shop-toy', '0 0 32 32');
            return null;
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

        let petState = null;            // последнее состояние плитки (get_pet_state_self)
        let petRoomState = null;        // последнее состояние комнаты (get_pet_room_self)
        let petBusy = false;            // синхронная защита от двойного клика (урок W05/U08A)
        let petRoomTrigger = null;
        let petRoomHistoryEntry = false;

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

        // --- Плитка в шапке профиля --------------------------------------------------------

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

            renderPetTile(petState);
        }

        // Отрисовка плитки по уже полученному состоянию — вызывается и после обычной загрузки
        // профиля (get_pet_state_self), и после действий в комнате (тем же объектом petState,
        // который приходит внутри get_pet_room_self, чтобы не делать лишний RPC).
        function renderPetTile(state) {
            const tile = document.getElementById('pet-tile');
            const header = document.querySelector('.profile-header');
            if (!tile || !header) return;

            if (!state || !state.enabled || !state.item_code) { petHide(); return; }
            const visual = petVisual(state);
            if (!visual) { petHide(); return; }   // неизвестный визуал — молча не рендерим

            // На плитке — общее состояние: худшее из двух осей заботы, сон показывается отдельно.
            const overall = state.overall_mood || state.mood;
            const art = document.getElementById('pet-tile-art');
            const mood = PET_MOODS[overall] || PET_MOODS.hungry;
            art.replaceChildren(petArtNode(visual, 44, overall, state.stage));
            art.className = `pet-art ${visual.cls}`;
            document.getElementById('pet-tile-mood').textContent = mood.badge;
            tile.className = `pet-tile pet-mood-${overall}`;
            tile.setAttribute('aria-label', `${visual.name}: ${mood.short}. Открыть комнату питомца`);
            tile.style.display = 'grid';
            header.classList.add('has-pet');
        }

        function petHide() {
            const tile = document.getElementById('pet-tile');
            const header = document.querySelector('.profile-header');
            if (tile) tile.style.display = 'none';
            if (header) header.classList.remove('has-pet');
            closePetRoom();
        }

        // --- Комната -------------------------------------------------------------------

        function petIndicatorRow(prefix, ready, nextAt) {
            const valueEl = document.getElementById(`pet-room-ind-${prefix}-value`);
            const rowEl = document.getElementById(`pet-room-ind-${prefix}`);
            valueEl.textContent = ready ? 'Можно сейчас' : `Можно снова ${petRelative(nextAt)}`;
            rowEl.classList.toggle('is-ready', !!ready);
        }

        function renderPetRoom() {
            const room = petRoomState;
            if (!room || !room.pet) return;
            const pet = room.pet;
            const visual = petVisual(pet);
            if (!visual) return;
            const overall = pet.overall_mood || pet.mood;
            const mood = PET_MOODS[overall] || PET_MOODS.hungry;

            // Стена комнаты — уже купленный сезонный фон, а не отдельный товар: у ученика он
            // часто уже есть, и это добавляет ценность существующей покупке вместо второго
            // типа фонов. Экипировку профиля держит student-progress.js.
            const scene = document.querySelector('.pet-room-scene');
            const wallHost = document.getElementById('pet-room-wall');
            wallHost.replaceChildren();
            const wallItem = (typeof currentProfileEquipment === 'object' && currentProfileEquipment)
                ? currentProfileEquipment.background : null;
            if (wallItem && window.SeasonCosmetics) {
                const wall = SeasonCosmetics.createScene(wallItem, 'pet-room-wall-art');
                if (wall) wallHost.appendChild(wall);
            }
            scene.classList.toggle('has-wall', wallHost.childElementCount > 0);

            document.getElementById('pet-room-art').replaceChildren(
                petArtNode(visual, 120, overall, pet.stage));

            // Предметы комнаты: лежанка под питомцем, игрушка рядом.
            const items = room.room_items || {};
            const bedHost = document.getElementById('pet-room-bed');
            const toyHost = document.getElementById('pet-room-toy');
            const bed = petRoomItemNode(items.bed, 'pet-room-item pet-room-bed-art', '0 0 64 32');
            const toy = petRoomItemNode(items.toy, 'pet-room-item pet-room-toy-art', '0 0 32 32');
            bedHost.replaceChildren(...(bed ? [bed] : []));
            toyHost.replaceChildren(...(toy ? [toy] : []));
            document.getElementById('pet-room-art').className = `pet-room-art pet-art ${visual.cls}`;
            document.getElementById('pet-room-name').textContent = visual.name;
            document.getElementById('pet-room-mood').textContent = mood.long;
            document.getElementById('pet-room-mood').className = `pet-room-mood pet-mood-${overall}`;

            const bond = Number(room.bond) || 0;
            document.getElementById('pet-room-bond').textContent =
                bond > 0 ? `Дней заботы: ${bond}` : 'Забота только начинается';

            // Сытость — тот же текст, что был в карточке V3.
            const days = Number(pet.days_left) || 0;
            const price = Number(pet.feed_price) || 0;
            const max = Number(pet.max_prepaid_days) || 0;
            document.getElementById('pet-room-ind-food-value').textContent = days > 0
                ? `Сыт до ${petFormatDate(pet.satiety_until)} — ещё ${days} ${petPluralDays(days)}`
                : 'Сегодня ещё не кормлен';
            document.getElementById('pet-room-ind-food').classList.toggle('is-ready', days <= 0);

            // Отдых — тот же текст, что был в карточке V3.
            const rest = pet.rest_state;
            let restText = PET_REST[rest] || '';
            if (rest === 'sleeping') restText = `Спит, проснётся ${petRelative(pet.sleep_ends_at)}`;
            else if (rest === 'rested' && pet.rested_until) restText = `Выспался, бодрый ещё ${petRelative(pet.rested_until, true)}`;
            document.getElementById('pet-room-ind-rest-value').textContent = restText;
            document.getElementById('pet-room-ind-rest').classList.toggle('is-ready', rest === 'tired');

            // Внимание и игра — новые бесплатные оси (PET1): доступна или «снова через N».
            const care = room.care || {};
            petIndicatorRow('pet', !!(care.petting && care.petting.available), care.petting && care.petting.next_at);
            petIndicatorRow('play', !!(care.play && care.play.available), care.play && care.play.next_at);

            // Реакции: только хорошее, и только если сервер что-то прислал. Пустых мест для
            // отсутствующих плохих событий нет — их нет и в самом контракте read-модели.
            const cheers = room.cheers || {};
            const badges = [];
            if (cheers.good_week) badges.push('🎉 Хорошая неделя');
            if (cheers.mock_record) badges.push('🏆 Новый рекорд');
            if (cheers.promoted) badges.push('⬆️ Новая лига');
            const cheersEl = document.getElementById('pet-room-cheers');
            cheersEl.replaceChildren(...badges.map((text) => {
                const span = document.createElement('span');
                span.className = 'pet-room-cheer';
                span.textContent = text;
                return span;
            }));

            const feedBtn = document.getElementById('pet-feed-btn');
            const fillBtn = document.getElementById('pet-feed-more');
            const full = days >= max;
            feedBtn.textContent = full ? 'Сыт на всю неделю' : `Покормить — ${price} 🥯`;
            feedBtn.disabled = full || petBusy;

            // Запас вперёд — вторичное действие: одна кнопка добирает сытость до потолка.
            const fillDays = Math.max(0, max - days);
            if (fillDays >= 2) {
                fillBtn.textContent = `Ещё ${fillDays} ${petPluralDays(fillDays)} — ${fillDays * price} 🥯`;
                fillBtn.dataset.days = String(fillDays);
                fillBtn.disabled = petBusy;
                fillBtn.style.display = 'inline-flex';
            } else {
                fillBtn.style.display = 'none';
            }

            const sleepBtn = document.getElementById('pet-sleep-btn');
            sleepBtn.textContent = rest === 'sleeping' ? 'Уже спит' : 'Уложить спать';
            sleepBtn.disabled = !pet.can_sleep || petBusy;
            sleepBtn.style.display = 'inline-flex';

            document.getElementById('pet-pet-btn').disabled =
                petBusy || !(care.petting && care.petting.available);
            document.getElementById('pet-play-btn').disabled =
                petBusy || !(care.play && care.play.available);

            // Эволюция: прогресс числом, потому что приложение везде показывает конкретику
            // («сыт до 3 августа», «можно снова через 3 ч»). Полоса без цифр стала бы
            // единственным местом, где число прячется. Сервер считает и прогресс, и нехватку.
            const evo = room.evolution;
            const evoBlock = document.getElementById('pet-room-evolution');
            if (!evo) {
                evoBlock.style.display = 'none';
            } else if (Number(evo.stage) >= 2) {
                document.getElementById('pet-evo-title').textContent = 'Вырос';
                document.getElementById('pet-evo-progress').textContent =
                    `${bond} ${petPluralDays(bond)} заботы`;
                document.getElementById('pet-evo-btn').style.display = 'none';
                evoBlock.style.display = 'flex';
            } else {
                const need = Number(evo.bond_required) || 0;
                const have = Number(evo.bond_current) || 0;
                const price = Number(evo.price) || 0;
                document.getElementById('pet-evo-title').textContent = 'Может вырасти';
                document.getElementById('pet-evo-progress').textContent =
                    `${have} из ${need} ${petPluralDays(need)} заботы · ${price} 🥯`;
                const evoBtn = document.getElementById('pet-evo-btn');
                evoBtn.textContent = `Вырастить — ${price} 🥯`;
                evoBtn.disabled = petBusy || !evo.available;
                evoBtn.style.display = 'inline-flex';
                evoBlock.style.display = 'flex';
            }
        }

        async function loadPetRoom() {
            const { data, error } = await db.rpc('get_pet_room_self');
            if (error) throw error;
            petRoomState = data || null;
            if (petRoomState && petRoomState.pet) {
                petState = petRoomState.pet;
                renderPetTile(petState);   // держим плитку в согласии с комнатой без лишнего RPC
            }
            renderPetRoom();
        }

        async function openPetRoom(trigger) {
            const overlay = document.getElementById('pet-room-overlay');
            if (!overlay || !petState || !petState.item_code) return;
            petRoomTrigger = trigger || document.getElementById('pet-tile');
            document.getElementById('pet-room-error').textContent = '';
            overlay.hidden = false;
            document.body.classList.add('pet-room-open');
            if (!petRoomHistoryEntry) {
                try {
                    history.pushState({ petRoom: true }, '');
                    petRoomHistoryEntry = true;
                } catch (_error) {
                    petRoomHistoryEntry = false;
                }
            }
            overlay.querySelector('.pet-room-close').focus();

            try {
                await loadPetRoom();
            } catch (error) {
                document.getElementById('pet-room-error').textContent = error.message || String(error);
            }
        }

        function closePetRoom(fromPopstate) {
            const overlay = document.getElementById('pet-room-overlay');
            if (!overlay || overlay.hidden) return;
            overlay.hidden = true;
            document.body.classList.remove('pet-room-open');
            if (petRoomTrigger) petRoomTrigger.focus();
            petRoomTrigger = null;
            if (petRoomHistoryEntry) {
                petRoomHistoryEntry = false;
                if (!fromPopstate) history.back();
            }
        }

        // Тап по питомцу: короткая реакция без сети, доступна всегда, ничего не расходует.
        // Под prefers-reduced-motion не анимируем — фигура просто не шевелится.
        function petPokeReact(el) {
            if (window.matchMedia && matchMedia('(prefers-reduced-motion: reduce)').matches) return;
            el.classList.remove('pet-poked');
            void el.offsetWidth;   // перезапуск CSS-анимации при повторных тапах подряд
            el.classList.add('pet-poked');
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
            const errorEl = document.getElementById('pet-room-error');
            const restore = sleepBtn.textContent;
            sleepBtn.disabled = true;
            errorEl.textContent = '';
            sleepBtn.textContent = 'Укладываем...';
            try {
                const { error } = await db.rpc('put_pet_to_sleep_self');
                if (error) throw error;
                await loadPetRoom();
            } catch (error) {
                sleepBtn.textContent = restore;
                errorEl.textContent = error.message || String(error);
            } finally {
                petBusy = false;
                renderPetRoom();
            }
        }

        // Кормление: ровно один RPC за действие, кнопка блокируется синхронно ДО await.
        // Идемпотентность по календарной дате обеспечивает сервер, клиент её не дублирует.
        async function feedPet(days, btn) {
            if (petBusy || (btn && btn.disabled)) return;
            petBusy = true;
            const feedBtn = document.getElementById('pet-feed-btn');
            const fillBtn = document.getElementById('pet-feed-more');
            const errorEl = document.getElementById('pet-room-error');
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
                await loadPetRoom();       // состояние, связь и баланс перечитываем с сервера
            } catch (error) {
                feedBtn.textContent = restore;
                errorEl.textContent = error.message || String(error);
            } finally {
                petBusy = false;
                renderPetRoom();
            }
        }

        // Погладить / поиграть (PET1): один RPC, свой кулдаун на каждую ось, без денег.
        async function careForPet(action, btn) {
            if (petBusy || (btn && btn.disabled)) return;
            petBusy = true;
            const errorEl = document.getElementById('pet-room-error');
            const restore = btn.textContent;
            btn.disabled = true;
            errorEl.textContent = '';
            btn.textContent = action === 'pet' ? 'Гладим...' : 'Играем...';
            try {
                const { error } = await db.rpc('pet_care_self', { p_action: action });
                if (error) throw error;
                await loadPetRoom();
            } catch (error) {
                btn.textContent = restore;
                errorEl.textContent = error.message || String(error);
            } finally {
                petBusy = false;
                renderPetRoom();
            }
        }

        // Эволюция необратима, поэтому это отдельное явное действие, а не побочный эффект
        // кормления. Сервер сам проверит обе оси и назовёт, чего не хватает.
        async function evolvePet(btn) {
            if (petBusy || (btn && btn.disabled)) return;
            petBusy = true;
            const errorEl = document.getElementById('pet-room-error');
            const restore = btn.textContent;
            btn.disabled = true;
            errorEl.textContent = '';
            btn.textContent = 'Растём...';
            try {
                const { data, error } = await db.rpc('evolve_pet_self');
                if (error) throw error;
                if (data && typeof data.balance === 'number') {
                    document.getElementById('val-huikons').innerText = data.balance;
                }
                await loadPetRoom();
            } catch (error) {
                btn.textContent = restore;
                errorEl.textContent = error.message || String(error);
            } finally {
                petBusy = false;
                renderPetRoom();
            }
        }

        document.addEventListener('keydown', (event) => {
            if (event.key === 'Escape') closePetRoom();
        });
        window.addEventListener('popstate', () => {
            if (petRoomHistoryEntry) closePetRoom(true);
        });
