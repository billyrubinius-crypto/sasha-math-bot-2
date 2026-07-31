// student-progress.js — профиль, косметика, пробники, история, достижения, лидерборд (R01)
        // --- КОСМЕТИКА / ЭКИПИРОВКА (S3) ---
        // Разрешённые классы payload — применяем только известные из каталога, чтобы строка из
        // БД не превратилась в произвольный CSS-класс.
        const FRAME_CLASSES = new Set(['frame-notebook','frame-winter','frame-fire100','frame-legend-1','frame-legend-2','frame-legend-3','frame-legend-4','frame-pulsar','frame-orbit']);
        const BG_CLASSES = new Set(['bg-grid','bg-space','bg-aurora','bg-draft']);

        // student_equipment + встроенный shop_items (render_payload/name) одним embed-запросом.
        function equipmentQuery(idsOrOne, isList) {
            const q = db.from('student_equipment')
                .select('student_id, slot, item_code, variant, shop_items(render_payload, name, description, rarity, visual_key, motion_policy)');
            return isList ? q.in('student_id', idsOrOne) : q.eq('student_id', idsOrOne);
        }

        // Массив строк экипировки → безопасная карта slot → публичные свойства предмета.
        function buildEquipMap(rows) {
            const map = {};
            (rows || []).forEach(r => {
                const si = r.shop_items || {};
                map[r.slot] = {
                    item_code: r.item_code,
                    variant: r.variant,
                    payload: si.render_payload,
                    name: si.name,
                    description: si.description,
                    rarity: si.rarity,
                    visual_key: si.visual_key,
                    motion_policy: si.motion_policy
                };
            });
            return map;
        }

        // Отображаемый текст титула: «Ященко» из «Титул «Ященко»» (fallback — имя как есть)
        function titleText(name) {
            if (!name) return '';
            const m = name.match(/«([^»]+)»/);
            return m ? m[1] : name;
        }

        // У персонального титула публичным становится только одобренный variant из
        // student_equipment; обычные титулы продолжают извлекаться из имени товара.
        function equippedTitleText(title) {
            if (!title) return '';
            return title.item_code === 'title_custom' ? (title.variant || '') : titleText(title.name);
        }

        const SEASON_PROFILE_EQUIPMENT_SLOTS = [
            { slot: 'avatar', label: 'Аватар' },
            { slot: 'frame', label: 'Рамка' },
            { slot: 'title', label: 'Титул' },
            { slot: 'background', label: 'Фон' }
        ];
        const SEASON_PROFILE_RARITY_LABELS = {
            common: 'Обычный',
            rare: 'Редкий',
            epic: 'Эпический',
            legendary: 'Легендарный'
        };

        function seasonEquipmentName(item, slot) {
            if (!item) return '';
            if (slot === 'title') return equippedTitleText(item) || item.name || '';
            return item.name || '';
        }

        function seasonEquipmentCatalogMark(item) {
            const match = String(item && item.item_code || '').match(/^ca26_(\d{2})_/);
            return match ? ` · S${match[1]}` : '';
        }

        function renderSeasonProfileEquipment(eq) {
            const host = document.getElementById('season-profile-equipment');
            if (!host) return;
            host.replaceChildren();

            const heading = document.createElement('strong');
            heading.className = 'season-profile-equipment-heading';
            heading.textContent = 'Надето';
            host.appendChild(heading);

            const list = document.createElement('div');
            list.className = 'season-profile-equipment-list';
            SEASON_PROFILE_EQUIPMENT_SLOTS.forEach(({ slot, label }) => {
                const item = eq && eq[slot];
                if (!item) return;
                const row = document.createElement('div');
                row.className = 'season-profile-equipment-item';
                const slotName = document.createElement('span');
                slotName.textContent = label + seasonEquipmentCatalogMark(item);
                const itemName = document.createElement('b');
                itemName.textContent = seasonEquipmentName(item, slot) || label;
                const rarity = SEASON_PROFILE_RARITY_LABELS[item.rarity] ? item.rarity : 'common';
                const rarityName = document.createElement('i');
                rarityName.className = `season-profile-equipment-rarity--${rarity}`;
                rarityName.textContent = SEASON_PROFILE_RARITY_LABELS[rarity];
                row.append(slotName, itemName, rarityName);
                list.appendChild(row);
            });

            if (!list.childElementCount) {
                const empty = document.createElement('span');
                empty.className = 'season-profile-equipment-empty';
                empty.textContent = 'Нет надетых предметов';
                list.appendChild(empty);
            }
            host.appendChild(list);
        }

        // Применить цвет ника к элементу: 'gold' — градиент, валидный hex — цвет, иначе дефолт
        function applyNickColor(el, payload) {
            el.classList.remove('nick-gold');
            el.style.color = '';
            if (payload === 'gold') el.classList.add('nick-gold');
            else if (/^#[0-9a-fA-F]{6}$/.test(payload || '')) el.style.color = payload;
        }

        // Собрать «ник с косметикой» в контейнер: [эмодзи-статус] [имя в цвете] [корона]
        function renderNick(container, baseName, eq, meSuffix) {
            container.innerHTML = '';
            if (eq.status_emoji && eq.status_emoji.variant) {
                const s = document.createElement('span'); s.className = 'nick-status';
                s.textContent = eq.status_emoji.variant; container.appendChild(s);
            }
            const nameSpan = document.createElement('span');
            nameSpan.textContent = baseName + (meSuffix || '');
            if (eq.name_color) applyNickColor(nameSpan, eq.name_color.payload);
            container.appendChild(nameSpan);
            if (eq.crown) {
                const c = document.createElement('span'); c.className = 'nick-crown';
                c.textContent = '👑'; container.appendChild(c);
            }
        }

        // Применить рамку аватара к контейнеру (сброс + известный класс)
        function applyAvatarFrame(container, eq) {
            FRAME_CLASSES.forEach(c => container.classList.remove(c));
            container.classList.remove('frame');
            if (eq.frame && FRAME_CLASSES.has(eq.frame.payload)) container.classList.add(eq.frame.payload);
        }

        // Экипированный фон (слот background) — на весь Mini App, а не на один экран профиля.
        // Классы bg-* вешаются на глобальный декоративный слой #app-bg-layer, который лежит вне
        // пяти .screen: фон виден на Профиле, Домашке, Лидерах, Магазине и «Ещё» и не гаснет
        // при switchTab. Whitelist BG_CLASSES сохранён дословно — из БД в classList попадает
        // только известный payload. Функция чисто визуальная: своих запросов не делает,
        // equipment получает готовым (loadProfile → applyProfileCosmetics).
        function applyAppBackground(eq) {
            const layer = document.getElementById('app-bg-layer');
            if (!layer) return;
            BG_CLASSES.forEach(c => layer.classList.remove(c));
            layer.replaceChildren();
            const payload = eq && eq.background ? eq.background.payload : null;
            if (payload && BG_CLASSES.has(payload)) {
                layer.className = payload;
                return;
            }
            if (window.SeasonCosmetics) {
                const scene = SeasonCosmetics.createScene(eq && eq.background, '');
                if (scene) {
                    layer.className = scene.className;
                    while (scene.firstChild) layer.appendChild(scene.firstChild);
                    return;
                }
            }
            layer.className = '';
        }

        let currentProfileEquipment = {};

        function ownProfileFallback() {
            return currentUser.photo_url
                ? {
                    imageUrl: normalizeUrl(currentUser.photo_url),
                    alt: currentUser.first_name ? `Аватар ${currentUser.first_name}` : 'Аватар ученика'
                }
                : ((currentUser.first_name || '?')[0].toUpperCase());
        }

        function openOwnSeasonProfileCard(trigger) {
            if (!currentUser) return;
            openSeasonProfileCard({
                name: currentUser.first_name || '',
                meta: 'Ваш профиль',
                eq: currentProfileEquipment,
                fallback: ownProfileFallback()
            }, trigger || document.getElementById('user-avatar-container'));
        }

        function applyProfileCosmetics(eq) {
            currentProfileEquipment = eq || {};
            renderNick(document.getElementById('user-name'), currentUser.first_name || '', eq, '');
            const titleEl = document.getElementById('profile-title');
            const titleRow = document.getElementById('profile-title-row');
            const title = equippedTitleText(eq.title);
            if (title) {
                titleEl.textContent = title;
                titleRow.style.display = 'flex';
            } else {
                titleRow.style.display = 'none';
                titleEl.textContent = '';
            }
            const avatarHost = document.getElementById('user-avatar-container');
            const fallback = ownProfileFallback();
            if (window.SeasonCosmetics) {
                SeasonCosmetics.replaceAvatar(avatarHost, eq, 48, 'profile', fallback);
                avatarHost.tabIndex = 0;
                avatarHost.setAttribute('role', 'button');
                avatarHost.setAttribute('aria-label', 'Открыть мини-профиль');
            } else {
                applyAvatarFrame(avatarHost, eq);
            }
            applyAppBackground(eq);
        }

        let seasonProfileTrigger = null;
        let seasonProfileHistoryEntry = false;

        function openSeasonProfileCard(user, trigger) {
            const overlay = document.getElementById('season-profile-overlay');
            if (!overlay) return;
            const sceneHost = document.getElementById('season-profile-scene');
            const avatarHost = document.getElementById('season-profile-avatar');
            const title = equippedTitleText(user.eq && user.eq.title);

            // Сначала открываем оболочку: ошибка отдельного визуального слоя не должна делать
            // клик полностью нерабочим.
            seasonProfileTrigger = trigger || null;
            overlay.hidden = false;
            document.body.classList.add('season-profile-open');
            try {
                sceneHost.replaceChildren();
                if (!window.SeasonCosmetics) throw new Error('renderer_unavailable');
                const scene = SeasonCosmetics.createScene(user.eq && user.eq.background, 'season-profile-scene-art');
                if (scene) sceneHost.appendChild(scene);
                SeasonCosmetics.replaceAvatar(
                    avatarHost,
                    user.eq || {},
                    160,
                    'expanded',
                    user.fallback || (user.name || '?')[0].toUpperCase()
                );
            } catch (error) {
                sceneHost.replaceChildren();
                avatarHost.textContent = (user.name || '?')[0].toUpperCase();
                log('⚠️ Мини-профиль: ' + (error.message || error));
            }
            document.getElementById('season-profile-name').textContent = user.name || '';
            document.getElementById('season-profile-title').textContent = title || 'Без титула';
            document.getElementById('season-profile-title').className =
                `rarity-title-${(user.eq && user.eq.title && user.eq.title.rarity) || 'common'}`;
            renderSeasonProfileEquipment(user.eq || {});
            document.getElementById('season-profile-meta').textContent = user.meta || '';
            avatarHost.tabIndex = 0;
            avatarHost.setAttribute('role', 'button');
            avatarHost.setAttribute('aria-label', 'Закрыть визитку');
            avatarHost.onclick = () => closeSeasonProfileCard();
            avatarHost.onkeydown = (event) => {
                if (event.key === 'Enter' || event.key === ' ') {
                    event.preventDefault();
                    closeSeasonProfileCard();
                }
            };
            if (!seasonProfileHistoryEntry) {
                try {
                    history.pushState({ seasonProfileCard: true }, '');
                    seasonProfileHistoryEntry = true;
                } catch (_error) {
                    seasonProfileHistoryEntry = false;
                }
            }
            overlay.querySelector('.season-profile-close').focus();
        }

        function closeSeasonProfileCard(fromPopstate) {
            const overlay = document.getElementById('season-profile-overlay');
            if (!overlay || overlay.hidden) return;
            overlay.hidden = true;
            document.body.classList.remove('season-profile-open');
            if (seasonProfileTrigger) seasonProfileTrigger.focus();
            seasonProfileTrigger = null;
            if (seasonProfileHistoryEntry) {
                seasonProfileHistoryEntry = false;
                if (!fromPopstate) history.back();
            }
        }

        document.addEventListener('keydown', (event) => {
            if (event.key === 'Escape') closeSeasonProfileCard();
        });
        window.addEventListener('popstate', () => {
            if (seasonProfileHistoryEntry) closeSeasonProfileCard(true);
        });

        // --- ПРОФИЛЬ И ИСТОРИЯ ---
        async function loadProfile(isRetryAfterInsert) {
            try {
                // Плановый переход сезонов (миграция 051) — ленивый, на обращении: cron в
                // проекте нет, поэтому ensure_current_season сначала выполняет
                // ensure_season_schedule (завершить сезон с истёкшим ends_at, активировать
                // подошедший запланированный), а потом возвращает id текущего. Делается ДО
                // чтения students: завершение сезона обнуляет rating, и профиль должен
                // показать данные уже после перехода. Повторные открытия приложения второй раз
                // сезон не завершают — гейт по seasons.status внутри finish_season.
                if (!isRetryAfterInsert) await ensureSeasonTick();

                let { data, error } = await db.from('students').select('*').eq('telegram_id', currentUser.id).single();

                if (error && error.code === 'PGRST116') {
                    // Повторяем не больше одного раза: если insert не удался, без этого select→insert зациклились бы навсегда
                    if (isRetryAfterInsert) throw new Error('Не удалось создать профиль ученика');
                    // secure path (JWT активен) — создание своей строки только через серверный
                    // gateway ensure_student_self (identity из claim; T10-04A). Legacy fallback —
                    // прежний прямой insert. rating = очки текущего сезона (миграция 005/034):
                    // новый ученик стартует с 0, а не с наследственных 50.
                    if (studentSecurePathActive()) {
                        const { error: rpcError } = await db.rpc('ensure_student_self', {
                            p_name: currentUser.first_name,
                            p_username: currentUser.username || null
                        });
                        if (rpcError) throw rpcError;
                    } else {
                        const { error: insertError } = await db.from('students').insert([{
                            telegram_id: currentUser.id, name: currentUser.first_name,
                            telegram_username: currentUser.username || null,
                            rating: 0, huikons: 0, lives: 3, current_streak: 0
                        }]);
                        if (insertError) throw insertError;
                    }
                    return loadProfile(true);
                } else if (error) { throw error; }
                
                document.getElementById('val-rating').innerText = data.rating;
                document.getElementById('val-huikons').innerText = data.huikons;

                // Отображение группы
                const groupBadge = document.getElementById('group-badge');
                document.getElementById('profile-group-row').style.display = 'grid';
                if (data.group_name) {
                    groupBadge.innerText = data.group_name;
                    groupBadge.classList.add('assigned');
                } else {
                    groupBadge.innerText = 'Без группы';
                    groupBadge.classList.remove('assigned');
                }

                // W10 — после cutover старая календарная модель стрика уходит из активного UI
                // (историю current_streak/достижений не удаляем). cutover_at — флаг economy_config (W09);
                // NULL или будущая дата = экономика ещё старая. Ошибку чтения флага трактуем как «до cutover».
                let cutoverActive = false;
                try {
                    // economy_config закрыт RLS (deny-client); читаем флаги только через узкий
                    // read-RPC get_economy_flags (T10-08B).
                    const { data: cfg } = await db.rpc('get_economy_flags');
                    cutoverActive = !!(cfg && cfg.cutover_at) && Date.now() >= Date.parse(cfg.cutover_at);
                } catch (e) { cutoverActive = false; }

                // Отображение стрика (только до cutover; после — недельный блок ниже)
                const streakEl = document.getElementById('streak-display');
                if (!cutoverActive && data.current_streak > 0) {
                    streakEl.style.display = 'inline-block';
                    streakEl.innerText = `🔥 ${data.current_streak} дней подряд`;
                } else {
                    streakEl.style.display = 'none';
                }
                if (cutoverActive) {
                    document.getElementById('streak-progress').style.display = 'none';
                } else {
                    renderStreakProgress(data.current_streak);
                }

                // Косметика (S3): применяем экипировку к нику/аватару/фону/титулу
                const { data: eqRows } = await equipmentQuery(currentUser.id, false);
                applyProfileCosmetics(buildEquipMap(eqRows));

                currentUser.stats = data;
                loadBalanceHistory();
                loadAssignmentsSummary();
                loadWeekBlock();
                loadMockExamChart();
                loadSeasonHistory();
                loadAchievements();
                loadShields();
                loadCollections();
                loadShowcase();
                loadRankTitle();

            } catch (e) { log('❌ Ошибка профиля: ' + e.message); }
        }

        // --- ЗВАНИЕ ПО ТРУДУ (L04, SPEC_STAGE3 §8) ---
        // Читает готовый серверный RPC get_student_rank_title (L01/020) — семь ступеней и их
        // пороги остаются единственным источником истины в БД, здесь их не копируем. Звание не
        // хранится в students и не зависит от очков сезона/пробников — это отдельная сущность от
        // экипированного custom title (#profile-title), рендерится в свой собственный элемент.
        async function loadRankTitle() {
            const badge = document.getElementById('rank-badge');
            const row = document.getElementById('profile-rank-row');
            const progress = document.getElementById('rank-progress');
            try {
                // claim-based self-обёртка (T10-08B): identity из JWT, без p_student_id.
                const { data, error } = await db.rpc('get_student_rank_title_self');
                if (error) throw error;

                badge.textContent = data.title;
                row.style.display = 'grid';

                let text;
                if (data.next_title) {
                    const parts = [];
                    if (data.tasks_to_next > 0) parts.push(`${data.tasks_to_next} задач`);
                    if (data.days_to_next > 0) parts.push(`${data.days_to_next} дней занятий`);
                    text = parts.length
                        ? `До звания «${data.next_title}»: осталось ${parts.join(' и ')}`
                        : `Звание «${data.next_title}» откроется на следующей принятой работе`;
                } else {
                    text = 'Максимальное звание достигнуто';
                }
                if (data.has_unknown_legacy) {
                    text += ' · счётчик задач ведётся с даты запуска (старые работы не учтены)';
                }
                progress.textContent = text;
                progress.style.display = 'block';
            } catch (e) {
                row.style.display = 'none';
                progress.style.display = 'none';
                log('❌ Звание: ' + (e.message || e));
            }
        }

        // Мини-индикатор прогресса стрика: 3 уровня награды (5 / 10 / 15 бубликов за 1/2/3+ дня подряд)
        function renderStreakProgress(streak) {
            const el = document.getElementById('streak-progress');
            if (!streak || streak <= 0) { el.style.display = 'none'; return; }

            const tiers = [5, 10, 15];
            const filled = Math.min(streak, 3);
            const dots = tiers.map((val, i) => `<div class="streak-dot ${i < filled ? 'filled' : ''}">${val}</div>`).join('');
            const note = streak >= 3 ? 'Максимальный уровень награды 🔥' : `Ещё ${3 - streak} дн. до максимальной награды`;

            el.innerHTML = `<div class="streak-dots">${dots}</div><div class="streak-note">${note}</div>`;
            el.style.display = 'block';
        }

        // --- ГРАФИК РЕЗУЛЬТАТОВ ПРОБНИКОВ ---
        let mockExamPoints = [];

        // U05B: единственный источник — RPC get_mock_exam_trajectory (U05A), читает только
        // weekly_mock_exams. avg/range/trend/delta считает сервер; клиент их не пересчитывает
        // (SPEC_STAGE4 §7). Legacy mock_exam_results (до P02A) здесь больше не читается.
        async function loadMockExamChart() {
            const container = document.getElementById('mock-chart-container');
            try {
                const { data, error } = await db.rpc('get_mock_exam_trajectory', { p_student_id: currentUser.id });
                if (error) throw error;

                if (!data || !data.count) {
                    container.innerHTML = `<div class="chart-empty">🧮 Пока нет результатов пробников</div>`;
                    return;
                }

                renderMockChart(container, data);
            } catch (e) {
                container.innerHTML = `<div class="chart-empty is-error">Ошибка загрузки графика</div>`;
                log(e.message);
            }
        }

        // Свой SVG-график без внешних библиотек: точка = один пробник, ось X — порядковый номер
        // недели (в хронологическом порядке; пропущенные недели не интерполируются — здесь просто
        // нет промежуточной точки, ось не «знает» про календарный разрыв, как и раньше).
        function renderMockChart(container, trajectory) {
            const points = trajectory.points || [];
            mockExamPoints = points;

            // Этап 4: холст чуть выше и поля больше — только чтобы вместить подписи 11px
            // (было 9px, после масштабирования на 360px это читалось как ~8px, §17).
            // xFor/yFor, minScore/maxScore и обработчик точки не менялись.
            const W = 320, H = 152;
            const padL = 34, padR = 12, padT = 12, padB = 32;
            const plotW = W - padL - padR;
            const plotH = H - padT - padB;

            const scores = points.map(p => Number(p.score) || 0);
            // Ось начинается с 40 для читаемости разброса, но если есть балл ниже — опускаем её,
            // чтобы низкий результат не отображался «прилипшим» к отметке 40 (то есть выше реального)
            const minScore = Math.min(40, Math.floor(Math.min(...scores) / 10) * 10);
            const maxScore = Math.max(minScore + 20, Math.ceil(Math.max(...scores) / 10) * 10);

            const xFor = (i) => points.length > 1 ? padL + (plotW * i / (points.length - 1)) : padL + plotW / 2;
            const yFor = (v) => {
                const y = padT + plotH - (plotH * (v - minScore) / (maxScore - minScore));
                return Math.min(padT + plotH, Math.max(padT, y));
            };

            const gridLines = [0, 0.25, 0.5, 0.75, 1].map(f => {
                const y = padT + plotH * (1 - f);
                const val = Math.round(minScore + (maxScore - minScore) * f);
                return `<line x1="${padL}" y1="${y}" x2="${W - padR}" y2="${y}" stroke="var(--ca-divider)" stroke-width="1"/>
                        <text x="${padL - 6}" y="${y + 4}" font-size="11" text-anchor="end" fill="var(--ca-text-secondary)">${val}</text>`;
            }).join('');

            const linePoints = points.map((p, i) => `${xFor(i)},${yFor(Number(p.score) || 0)}`).join(' ');

            const dots = points.map((p, i) => {
                const x = xFor(i), y = yFor(Number(p.score) || 0);
                // stroke — цвет поверхности карточки (график лежит на .mock-chart-section),
                // раньше это был фон приложения и вокруг точки оставалось чужое кольцо.
                return `<circle cx="${x}" cy="${y}" r="6" fill="var(--ca-accent)" stroke="var(--ca-surface)" stroke-width="2" style="cursor:pointer" onclick="showExamInfo(${i})"/>`;
            }).join('');

            const labels = points.map((p, i) => {
                const x = xFor(i);
                return `<text x="${x}" y="${H - padB + 18}" font-size="11" text-anchor="middle" fill="var(--ca-text-secondary)">№${i + 1}</text>`;
            }).join('');

            container.innerHTML = `
                <svg viewBox="0 0 ${W} ${H}" style="width:100%; height:auto; display:block;">
                    ${gridLines}
                    <polyline points="${linePoints}" fill="none" stroke="var(--ca-accent)" stroke-width="2" opacity="0.55" stroke-linecap="round" stroke-linejoin="round"/>
                    ${dots}
                    ${labels}
                </svg>
                <div id="exam-info-box" class="exam-info-box">${esc(trajectorySummary(trajectory))}</div>
                <div class="chart-disclaimer">Диапазон последних пробников — не гарантия балла ЕГЭ.</div>
            `;
        }

        // Сводка по готовым серверным полям (U05A): delta/avg/range/trend клиент не считает сам.
        function trajectorySummary(trajectory) {
            const { last_score, delta_last, avg_last_3, min_last_3, max_last_3, trend } = trajectory;
            const parts = [`Последний результат: ${last_score}`];
            if (delta_last !== null && delta_last !== undefined) {
                const sign = delta_last > 0 ? '+' : '';
                parts.push(`(${sign}${delta_last} к предыдущему)`);
            }
            if (avg_last_3 !== null && avg_last_3 !== undefined) {
                parts.push(`· среднее по 3: ${avg_last_3} (${min_last_3}–${max_last_3})`);
            }
            const trendLabels = { up: 'растёт 📈', flat: 'стабильно ➖', down: 'снижается 📉' };
            if (trend) parts.push(`· ${trendLabels[trend] || trend}`);
            parts.push('· нажми на точку для деталей');
            return parts.join(' ');
        }

        function showExamInfo(index) {
            const p = mockExamPoints[index];
            const box = document.getElementById('exam-info-box');
            if (!p || !box) return;
            const [y, m, d] = p.week_start.split('-');
            box.textContent = `Неделя от ${d}.${m}.${y} • ${p.score} баллов`;
        }

        // Не используются с U05B (трактория читается из get_mock_exam_trajectory, delta/summary
        // считает сервер) — оставлены нетронутыми по правилу «не удалять существующий код».
        function lastResultSummary(points) {
            const last = Number(points[points.length - 1].score) || 0;
            if (points.length < 2) return `Последний результат: ${last}. Нажми на точку, чтобы увидеть детали`;
            const prev = Number(points[points.length - 2].score) || 0;
            const delta = last - prev;
            const sign = delta > 0 ? '+' : '';
            return `Последний результат: ${last} (${sign}${delta} к предыдущему). Нажми на точку, чтобы увидеть детали`;
        }

        function formatPlainDate(dateStr) {
            const [y, m, d] = dateStr.split('-');
            return `${d}.${m}.${y}`;
        }

        async function loadBalanceHistory() {
            const list = document.getElementById('balance-history-list');
            try {
                const { data, error } = await db
                    .from('balance_history')
                    .select('*')
                    .eq('student_id', currentUser.id)
                    .order('created_at', { ascending: false })
                    .limit(20);
                
                if (error) throw error;
                
                if (!data || data.length === 0) {
                    list.innerHTML = '<li class="ca-state ca-state--empty">📭 История пока пуста</li>';
                    return;
                }
                
                list.innerHTML = '';
                data.forEach(item => {
                    const isPositive = item.change_amount > 0;
                    const reasonMap = {
                        'dz_upload_daily': 'Загрузка ежедневного ДЗ',
                        'dz_upload_weekly': 'Загрузка еженедельного ДЗ',
                        'dz_upload_individual': 'Загрузка индивидуального задания',
                        'daily_approved': 'Ежедневное задание принято ✅',
                        'streak_day_1': 'Серия 1 день 🔥',
                        'streak_day_2': 'Серия 2 дня 🔥',
                        'streak_day_3': 'Серия 3+ дней 🔥',
                        'weekly_approved': 'Еженедельное принято ✅',
                        'individual_approved': 'Индивидуальное принято ✅',
                        'bonus_return': 'Бонус за возвращённое задание',
                        'weekly_reward': 'Награда за неделю 🥯',
                        'mock_exam_weekly': 'Пробник недели',
                        'mock_exam_record': 'Личный рекорд на пробнике',
                        'mock_exam_season': 'Очки сезона за пробник',
                        'daily_quest_life': 'Жизненное испытание дня',
                        'daily_quest_math': 'Математическое испытание дня',
                        'daily_quest_life_1': 'Испытание дня 1',
                        'daily_quest_life_2': 'Испытание дня 2',
                        'daily_quest_combo': 'Бонус за два испытания',
                        'legacy_opening_balance': 'Начальный баланс',
                        'legacy_opening_balance_rollback': 'Корректировка начального баланса',
                        'buy_streak_shield': 'Покупка щита недели',
                        'buy_color_red': 'Покупка алого цвета ника',
                        'buy_color_orange': 'Покупка оранжевого цвета ника',
                        'buy_color_green': 'Покупка изумрудного цвета ника',
                        'buy_color_teal': 'Покупка морского цвета ника',
                        'buy_color_blue': 'Покупка небесного цвета ника',
                        'buy_color_indigo': 'Покупка цвета ника «Индиго»',
                        'buy_color_pink': 'Покупка малинового цвета ника',
                        'buy_color_brown': 'Покупка шоколадного цвета ника',
                        'buy_status_emoji_change': 'Покупка смены эмодзи-статуса',
                        'buy_crown': 'Покупка короны',
                        'buy_golden_nick': 'Покупка золотого ника',
                        'buy_title_yaschenko': 'Покупка титула «Ященко»',
                        'buy_title_custom': 'Покупка персонального титула',
                        'buy_frame_fire100': 'Покупка рамки «100 дней огня»',
                        'buy_frame_notebook': 'Покупка рамки «Тетрадная клетка»',
                        'buy_bg_grid': 'Покупка фона «Миллиметровка»',
                        'buy_title_groza': 'Покупка титула «Гроза параметров»',
                        'buy_frame_legend_1': 'Покупка рамки «Сезон первый»',
                        'buy_frame_pulsar': 'Покупка рамки «Пульсар»',
                        'buy_bg_space': 'Покупка фона «Космос»',
                        'buy_title_elon': 'Покупка титула «Илон Маск»',
                        'buy_frame_legend_2': 'Покупка рамки «Золотая осень»',
                        'buy_frame_winter': 'Покупка рамки «Зимняя»',
                        'buy_bg_aurora': 'Покупка фона «Северное сияние»',
                        'buy_title_sanchez': 'Покупка титула «Санчез»',
                        'buy_frame_legend_3': 'Покупка рамки «Зимний апекс»',
                        'buy_frame_orbit': 'Покупка рамки «Орбита»',
                        'buy_bg_draft': 'Покупка фона «Черновик гения»',
                        'buy_title_derivative': 'Покупка титула «Держу производную»',
                        'buy_frame_legend_4': 'Покупка рамки «Предэкзаменационная»'
                    };
                    // Никогда не показываем внутренние коды причины пользователю.
                    let displayReason = reasonMap[item.reason];
                    if (!displayReason && item.reason && item.reason.startsWith('penalty:')) {
                        displayReason = '⚠️ Штраф';
                    }
                    // Недельные достижения и призы сезона (W09/W10): единый читаемый ярлык
                    if (!displayReason && item.reason && item.reason.startsWith('achievement_')) {
                        displayReason = 'Достижение 🏆';
                    }
                    if (!displayReason && item.reason && item.reason.startsWith('season_place_')) {
                        displayReason = 'Приз за место в сезоне 🏆';
                    }
                    if (!displayReason && item.reason && item.reason.startsWith('streak_day_')) {
                        displayReason = 'Награда за серию дней 🔥';
                    }
                    if (!displayReason && item.reason && item.reason.startsWith('buy_')) {
                        displayReason = 'Покупка в магазине';
                    }
                    if (!displayReason) {
                        displayReason = isPositive ? 'Начисление бубликов' : 'Списание бубликов';
                    }
                    const li = document.createElement('li');
                    li.className = 'history-item';
                    li.innerHTML = `
                        <div class="hist-info">
                            <div class="hist-reason">${esc(displayReason)}</div>
                            <div class="hist-date">${new Date(item.created_at).toLocaleDateString('ru-RU')}</div>
                        </div>                        
                        <div class="hist-amount ${isPositive ? 'hist-positive' : 'hist-negative'}">
                            ${isPositive ? '+' : ''}${item.change_amount}
                        </div>
                    `;
                    list.appendChild(li);
                });
                
            } catch (e) {
                list.innerHTML = '<li class="ca-state ca-state--error">Ошибка загрузки истории</li>';
                log(e.message);
            }
        }

        // Архив закрытых сезонов (season_results пишется один раз при закрытии сезона, G8).
        // Пусто до первого закрытия — секция в этом случае скрыта целиком, а не показывает
        // пустой список.
        async function loadSeasonHistory() {
            const section = document.getElementById('season-history-section');
            const list = document.getElementById('season-history-list');
            try {
                const { data, error } = await db
                    .from('season_results')
                    .select('season_id, points, place, seasons(title,display_number,preset_code)')
                    .eq('student_id', currentUser.id)
                    .order('season_id', { ascending: false })
                    .limit(10);

                if (error) throw error;
                if (!data || data.length === 0) {
                    section.style.display = 'none';
                    return;
                }

                section.style.display = '';
                list.innerHTML = '';
                data.forEach(item => {
                    const placeDisplay = item.place === 1 ? '🥇' : item.place === 2 ? '🥈' : item.place === 3 ? '🥉' : `#${item.place}`;
                    const li = document.createElement('li');
                    li.className = 'history-item';
                    const info = document.createElement('div');
                    info.className = 'hist-info';
                    const reason = document.createElement('div');
                    reason.className = 'hist-reason';
                    const season = item.seasons;
                    const seasonLabel = season?.display_number
                        ? `Сезон №${season.display_number}${season.title ? ` · ${season.title}` : ''}`
                        : (season?.preset_code
                            ? `Межсезонье${season.title ? ` · ${season.title}` : ''}`
                            : `Сезон №${item.season_id}`);
                    reason.textContent = `${seasonLabel} — ${placeDisplay} место`;
                    info.appendChild(reason);
                    const amount = document.createElement('div');
                    amount.className = 'hist-amount';
                    amount.textContent = `${item.points} ⭐`;
                    li.append(info, amount);
                    list.appendChild(li);
                });

            } catch (e) {
                section.style.display = 'none';
                log('❌ Ошибка истории сезонов: ' + e.message);
            }
        }

        // Альбом достижений (G5). Фиксированный набор из 8 достижений «Дисциплины»: полученные —
        // цветными, ещё не полученные — серым силуэтом (locked). Порядок и метаданные — константа
        // ниже; коды совпадают с achievement_code, которые выдаёт teacher.html (grantAchievement).
        // Недельные достижения (ECONOMY_V2 §10.1) — активный набор после cutover; коды совпадают
        // с теми, что выдают grant_weekly_achievements / record_approved_assignment (W09).
        // Legacy-достижения этапа 1 (streak_*, perfect_month, rebirth) показываются ТОЛЬКО их
        // владельцам: новая выдача прекращена после cutover, но полученные сохраняются (SPEC §8).
        // Поле svg (этап 2) — id символа из inline-спрайта index.html БЕЗ решётки. Оно только
        // добавлено рядом с существующим icon: сам icon остаётся эмодзи и остаётся источником
        // отрисовки (loadAchievements, витрина, пикер, «🔒 Нужно: …» в магазине читают icon/name/code
        // без изменений). Переключение рендера достижений на svg — этап 4.
        const ACHIEVEMENTS_META = [
            { code: 'first_step',           icon: '🌱', name: 'Первый шаг',            svg: 'ca-i-pencil' },
            { code: 'first_good_week',      icon: '📗', name: 'Неделя получилась',     svg: 'ca-i-book' },
            { code: 'perfect_week',         icon: '🌟', name: 'Семь из семи',          svg: 'ca-i-star' },
            { code: 'rhythm_4',             icon: '📅', name: 'Месяц в ритме',         svg: 'ca-i-calendar' },
            { code: 'rhythm_12',            icon: '🗓', name: 'Четверть года',         svg: 'ca-i-calendar' },
            { code: 'rhythm_24',            icon: '🏅', name: 'Полгода в ритме',       svg: 'ca-i-medal' },
            { code: 'good_weeks_36',        icon: '🎓', name: 'Учебный год',           svg: 'ca-i-award' },
            { code: 'no_shields_8',         icon: '💪', name: 'Своими силами',         svg: 'ca-i-medal' },
            { code: 'perfect_month_weekly', icon: '✨', name: 'Идеальный месяц',       svg: 'ca-i-star' },
            { code: 'rebirth_week',         icon: '🕊', name: 'Возвращение',           svg: 'ca-i-history' },
            { code: 'clean_10',             icon: '🎯', name: 'С первого раза',        svg: 'ca-i-star' },
            // Достижения жизненных привычек Stage 4 (U06) — без бубликов, только badge.
            { code: 'life_first',           icon: '🌿', name: 'Первый челлендж',       svg: 'ca-i-pencil' },
            { code: 'life_7',               icon: '🏃', name: 'Семь челленджей',       svg: 'ca-i-medal' },
            { code: 'life_30',              icon: '🧗', name: 'Тридцать челленджей',   svg: 'ca-i-medal' },
            { code: 'life_100',             icon: '🏆', name: 'Сотня челленджей',      svg: 'ca-i-trophy' },
            { code: 'life_variety_5',       icon: '🎨', name: 'Пять разных',           svg: 'ca-i-box' },
            { code: 'life_streak_7',        icon: '🌈', name: 'Неделя привычки',       svg: 'ca-i-star' },
            { code: 'streak_7',      icon: '🔥', name: 'Неделя огня',            svg: 'ca-i-calendar', legacy: true },
            { code: 'streak_30',     icon: '📆', name: 'Месяц без пропусков',     svg: 'ca-i-calendar', legacy: true },
            { code: 'streak_100',    icon: '💯', name: 'Сотня',                  svg: 'ca-i-trophy',   legacy: true },
            { code: 'streak_200',    icon: '⚡', name: '200 дней',               svg: 'ca-i-trophy',   legacy: true },
            { code: 'streak_365',    icon: '👑', name: 'Год дисциплины',         svg: 'ca-i-award',    legacy: true },
            { code: 'perfect_month', icon: '🌙', name: 'Идеальный месяц (стрик)', svg: 'ca-i-star',    legacy: true },
            { code: 'rebirth',       icon: '🪶', name: 'Возрождение (стрик)',     svg: 'ca-i-history', legacy: true }
        ];

        async function loadAchievements() {
            const section = document.getElementById('achievements-section');
            const grid = document.getElementById('ach-grid');
            try {
                const { data, error } = await db
                    .from('student_achievements')
                    .select('achievement_code')
                    .eq('student_id', currentUser.id);
                if (error) throw error;

                const earned = new Set((data || []).map(r => r.achievement_code));
                grid.innerHTML = '';
                ACHIEVEMENTS_META.forEach(a => {
                    const has = earned.has(a.code);
                    if (a.legacy && !has) return; // legacy — показываем только владельцам
                    const tile = document.createElement('div');
                    tile.className = `ach-tile ${has ? '' : 'locked'}`;
                    // Этап 4: полученное достижение рисуется символом спрайта (поле svg,
                    // добавленное на этапе 2), неполученное — замком. Эмодзи icon остаётся
                    // в метаданных и работает запасным вариантом; витрина, пикер и подписи
                    // условий в магазине по-прежнему читают icon/name/code без изменений.
                    const iconMarkup = has
                        ? (a.svg
                            ? `<svg class="ca-icon" aria-hidden="true" focusable="false"><use href="#${a.svg}" xlink:href="#${a.svg}"></use></svg>`
                            : a.icon)
                        : '🔒';
                    tile.innerHTML = `
                        <div class="ach-icon">${iconMarkup}</div>
                        <div class="ach-name">${esc(a.name)}</div>
                    `;
                    grid.appendChild(tile);
                });
                section.style.display = '';

            } catch (e) {
                section.style.display = 'none';
                log('❌ Ошибка достижений: ' + e.message);
            }
        }

        // Альбом коллекций (S6, GAME_DESIGN.md §10.5). «Коллекция сезона N» = набор ротационных
        // товаров бандла, который был назначен сезону N (season_bundles, S1/S4) — тот же источник
        // данных, что и витрина ротации (S4), не отдельный список (риск из карточки S6).
        // --- ЛИДЕРБОРД ---
        // Строку сезона создаёт сервер: ensure_current_season (definer, T10-08B) — seasons
        // закрыт RLS от прямой записи. С миграции 051 та же RPC ещё и выполняет плановый
        // переход (ensure_season_schedule): завершает сезон, у которого истёк ends_at, и
        // активирует подошедший запланированный. Это и есть механизм активации по расписанию —
        // ленивый, на обращении, потому что cron в инфраструктуре проекта нет. Гонку
        // одновременных вызовов снимает advisory-lock внутри функции, двойное завершение —
        // гейт по seasons.status.
        let currentSeasonTick = null;

        async function getCurrentSeasonId() {
            const { data, error } = await db.rpc('ensure_current_season');
            if (error) return null;
            currentSeasonTick = data ?? null;
            return currentSeasonTick;
        }

        // Один «тик» расписания за загрузку экрана: profile и лидерборд вызывают его оба,
        // повторный вызов дешёвый (переход уже выполнен), но и лишним его делать не нужно.
        async function ensureSeasonTick() {
            try { return await getCurrentSeasonId(); } catch (e) { return null; }
        }

        // --- ЛИГИ (L03) ---
        // Вкладка «Лидеры» имеет два режима: «Моя лига» (по умолчанию) и «Общий топ» — теперь
        // накопительный за ВСЕ сезоны (миграция 051), а не сезонный топ-10. loadLeaderboard
        // остаётся точкой входа из switchTab. Места, переходы и общий рейтинг НЕ считаются на
        // клиенте: их отдаёт сервер (get_student_league_snapshot_self /
        // get_student_league_standings_self / get_global_top_self).
        // Названия семи лиг — снимок league_tiers (миграция 019), для лестницы без запроса.
        const LEAGUE_LADDER = ['Бронза', 'Серебро', 'Золото', 'Платина', 'Алмаз', 'Мастер', 'Легенда'];

        async function loadLeaderboard() {
            // Тик расписания сезонов до отрисовки любого режима: и место в лиге, и общий топ
            // зависят от того, не сменился ли сезон прямо сейчас.
            await ensureSeasonTick();
            switchLbMode('league');
        }

        function switchLbMode(mode) {
            document.getElementById('lb-mode-league').classList.toggle('active', mode === 'league');
            document.getElementById('lb-mode-global').classList.toggle('active', mode === 'global');
            document.getElementById('lb-tab-league').classList.toggle('active', mode === 'league');
            document.getElementById('lb-tab-global').classList.toggle('active', mode === 'global');
            if (mode === 'league') loadLeague();
            else loadGlobalTop();
        }

        // Лестница семи лиг: только названия, текущая подсвечена, ниже — пройдено, выше — впереди.
        // Пустые рейтинги будущих лиг не рендерим (SPEC_STAGE3 §3).
        function renderLeagueLadder(currentTier) {
            let html = '<ul class="league-ladder">';
            for (let t = 7; t >= 1; t--) {
                let cls = 'ladder-step';
                if (t === currentTier) cls += ' current';
                else if (t < currentTier) cls += ' achieved';
                const mark = t === currentTier ? '📍' : (t < currentTier ? '✓' : '🔒');
                html += `<li class="${cls}"><span class="ladder-mark">${mark}</span><span class="ladder-name">${esc(LEAGUE_LADDER[t - 1])}</span></li>`;
            }
            html += '</ul>';
            return html;
        }

        // Строка участника рейтинга — один компонент для «Моей лиги» и «Общего топа» (§7.4:
        // раньше обе функции собирали байт-в-байт одинаковый li). Только сборка DOM: данные,
        // запросы, места и переходы по-прежнему приходят готовыми снаружи.
        //
        // DOM-путь (createElement + textContent) сохранён намеренно (R8): имя ученика и титул
        // приходят из БД, строковый шаблон здесь открыл бы XSS. Косметику по-прежнему
        // навешивают renderNick/applyAvatarFrame — их вызовы перенесены дословно.
        function buildLeaderboardRow(options) {
            const { rankText, name, eq, isMe, scoreText, modifiers } = options;
            const li = document.createElement('li');
            li.className = ['lb-item', isMe ? 'lb-me' : '', modifiers || ''].filter(Boolean).join(' ');

            if (window.SeasonCosmetics) {
                const scene = SeasonCosmetics.createScene(eq && eq.background, 'lb-equipped-scene');
                if (scene) li.appendChild(scene);
            }

            const rank = document.createElement('div');
            rank.className = 'lb-rank'; rank.textContent = rankText;

            const avatar = document.createElement('button');
            avatar.type = 'button';
            avatar.className = 'lb-avatar';
            avatar.setAttribute('aria-label', `Открыть визитку ${name || 'ученика'}`);
            if (window.SeasonCosmetics) {
                SeasonCosmetics.replaceAvatar(
                    avatar, eq || {}, 32, 'compact', name ? name[0].toUpperCase() : '?'
                );
                avatar.addEventListener('click', () => openSeasonProfileCard({
                    name: name || '',
                    meta: isMe ? 'Это вы' : 'Публичная экипировка',
                    eq: eq || {},
                    fallback: isMe && currentUser.photo_url
                        ? {
                            imageUrl: normalizeUrl(currentUser.photo_url),
                            alt: currentUser.first_name ? `Аватар ${currentUser.first_name}` : 'Аватар ученика'
                        }
                        : (name ? name[0].toUpperCase() : '?')
                }, avatar));
            } else {
                avatar.textContent = name ? name[0].toUpperCase() : '?';
                applyAvatarFrame(avatar, eq);
            }

            const wrap = document.createElement('div');
            wrap.className = 'lb-name-wrap';
            const line = document.createElement('div');
            line.className = 'lb-name-line lb-readable-window';
            renderNick(line, name || '', eq, isMe ? ' (Вы)' : '');
            wrap.appendChild(line);
            if (eq.title) {
                const title = equippedTitleText(eq.title);
                if (title) {
                    const t = document.createElement('div');
                    t.className = `lb-title lb-readable-window rarity-title-${eq.title.rarity || 'common'}`;
                    t.textContent = title;
                    wrap.appendChild(t);
                }
            }

            const score = document.createElement('div');
            score.className = 'lb-score'; score.textContent = scoreText;

            li.appendChild(rank);
            li.appendChild(avatar);
            li.appendChild(wrap);
            li.appendChild(score);
            return li;
        }

        // Подпись сезона в шапке лиги: название безопаснее внутреннего id строки seasons.
        function leagueSeasonLabel(snap) {
            if (!snap || !snap.season_id) return '';
            return snap.season_title
                ? `«${esc(snap.season_title)}»`
                : `Сезон №${snap.season_id}`;
        }

        // Полный список своей лиги. Раньше он строился из preview_league_close, который отдаёт
        // только обычные когорты (`is_late_entry = false`), поэтому вступившие по ходу сезона
        // пропадали из выдачи; сам late-entry ученик вообще получал ранний выход без списка; а
        // имена и косметика остальных тянулись прямыми select из students/student_equipment,
        // закрытых RLS «своя строка» (миграции 042/043) — у ученика возвращалась одна строка.
        // Теперь один RPC get_student_league_standings_self (миграция 052) отдаёт ВСЕХ
        // фактических участников своей лиги с именами, косметикой, местом внутри когорты и
        // проекцией перехода. Никакого LIMIT и никакой клиентской фильтрации: сколько пришло —
        // столько и рисуем, когорты идут отдельными группами (места считаются внутри когорты).
        async function loadLeague() {
            const box = document.getElementById('league-content');
            box.innerHTML = '<div class="ca-state ca-state--loading">Загрузка...</div>';
            try {
                const [{ data: snap, error: snapErr }, { data: rows, error: rowsErr }] = await Promise.all([
                    db.rpc('get_student_league_snapshot_self'),
                    db.rpc('get_student_league_standings_self')
                ]);
                if (snapErr) throw snapErr;
                if (rowsErr) throw rowsErr;

                const tier = snap && snap.tier ? snap.tier : 1;
                const tierName = (snap && snap.tier_name) || LEAGUE_LADDER[tier - 1];

                // Шапка: текущая лига + корона (снимок отдаёт has_crown только в её действующий сезон).
                let html = `<div class="league-badge">🏅 ${esc(tierName)}`;
                if (snap && snap.has_crown) html += ' 👑';
                html += '</div>';

                if (!snap || !snap.in_season) {
                    // Участия в текущем сезоне нет: с миграции 052 оно появляется не при
                    // регистрации, а после первого фактического начисления очков за домашку.
                    html += '<div class="league-note">Ты ещё не в битве лиг этого сезона. Участие открывается сразу после первого начисления очков сезона — за принятую учителем домашку.</div>';
                    html += renderLeagueLadder(tier);
                    box.innerHTML = html;
                    return;
                }

                html += `<div class="league-note">${leagueSeasonLabel(snap)} идёт. Места, переходы и Корона фиксируются при закрытии сезона.</div>`;

                if (snap.is_late_entry) {
                    html += '<div class="league-note">Ты присоединился в середине сезона: место видно, но повышения и понижения в этом неполном сезоне не будет — они начнутся со следующего сезона.</div>';
                }

                const active = snap.active_in_cohort || 0;
                const myGroup = (rows || []).filter(r => r.is_me);
                const promote = (rows || []).filter(r => !r.is_late_entry && r.projected_movement === 'promote').length;
                const demote = (rows || []).filter(r => !r.is_late_entry && r.projected_movement === 'demote').length;

                // Пояснение зон переходов по фактическому числу активных (SPEC_STAGE3 §4).
                if (snap.is_late_entry) {
                    // у late-entry когорты переходов нет по правилу — счётчики зон не показываем
                } else if (active < 5) {
                    html += `<div class="league-note">В группе ${active} активных (нужно 5+). В этом сезоне переходов между лигами не будет.</div>`;
                } else {
                    html += `<div class="league-note">Активных в группе: ${active}. Сейчас повышаются <b>${promote}</b> сверху, понижаются <b>${demote}</b> снизу (по текущим очкам).</div>`;
                }

                if (snap.place && snap.cohort_size) {
                    html += `<div class="league-standing">Твоё место: <b>${snap.place}</b> из ${snap.cohort_size}</div>`;
                }

                box.innerHTML = html;

                // Группировка по когортам. Обычная когорта и late_entry — разные соревновательные
                // группы (SPEC_STAGE3 §3), поэтому они не смешиваются в один нумерованный список.
                const groups = [];
                (rows || []).forEach(r => {
                    const key = (r.is_late_entry ? 'L' : 'R') + ':' + r.cohort_index;
                    let g = groups.find(x => x.key === key);
                    if (!g) {
                        g = { key, isLate: r.is_late_entry, index: r.cohort_index, rows: [] };
                        groups.push(g);
                    }
                    g.rows.push(r);
                });

                groups.forEach(g => {
                    if (groups.length > 1) {
                        const title = document.createElement('div');
                        title.className = 'league-group-title';
                        title.textContent = g.isLate
                            ? `Присоединились по ходу сезона${g.index > 1 ? ' — группа ' + g.index : ''}`
                            : `Основная группа${g.index > 1 ? ' ' + g.index : ''}`;
                        box.appendChild(title);
                    }
                    const listEl = document.createElement('ul');
                    listEl.className = 'leaderboard-list';
                    g.rows.forEach(r => {
                        const arrow = r.projected_movement === 'promote' ? ' ↑'
                            : (r.projected_movement === 'demote' ? ' ↓' : '');
                        listEl.appendChild(buildLeaderboardRow({
                            rankText: `#${r.place}`,
                            name: r.name || '',
                            eq: r.equipment || {},
                            isMe: !!r.is_me,
                            scoreText: `${r.points} ⭐${arrow}`,
                            modifiers: (r.projected_movement === 'promote' ? 'lb-promote' : '') +
                                (r.projected_movement === 'demote' ? 'lb-demote' : '')
                        }));
                    });
                    box.appendChild(listEl);
                });

                if (!myGroup.length) {
                    // Инвариант: свою строку ученик обязан видеть. Если её нет — это рассинхрон
                    // снимка и выдачи, о котором лучше сказать, чем молча показать чужой список.
                    const note = document.createElement('div');
                    note.className = 'league-note is-warning';
                    note.textContent = 'Не удалось найти тебя в списке — открой экран заново.';
                    box.appendChild(note);
                }

                // Предупреждение о неактивных сезонах (второй пустой сезон подряд — понижение).
                if (snap.inactive_seasons >= 1) {
                    const warn = document.createElement('div');
                    warn.className = 'league-note is-warning';
                    warn.textContent = `Пропущено сезонов подряд без очков: ${snap.inactive_seasons}. Ещё один такой сезон — понижение на лигу.`;
                    box.appendChild(warn);
                }

                const ladder = document.createElement('div');
                ladder.innerHTML = renderLeagueLadder(tier);
                box.appendChild(ladder);
            } catch (e) {
                box.innerHTML = '<div class="ca-state ca-state--error">Ошибка лиги</div>';
                log('❌ Лига: ' + (e.message || e));
            }
        }

        // --- ОБЩИЙ ТОП ЗА ВСЁ ВРЕМЯ ---
        // Раньше здесь был прямой select из students с сортировкой по rating и limit(10):
        // rating — очки ТЕКУЩЕГО сезона (обнуляются при закрытии, миграция 006), поэтому топ
        // забывал все прошлые достижения; а после включения RLS на students (миграция 042)
        // такой select у ученика возвращал вообще одну строку — его собственную.
        // Теперь считает сервер: get_global_top_self (миграция 051) = сумма итогов всех
        // закрытых сезонов (season_results) + очки текущего, стабильный tie-break, все
        // зарегистрированные ученики. Страницами по GLOBAL_TOP_PAGE до total_students —
        // скрытого «первых 10» больше нет.
        const GLOBAL_TOP_PAGE = 50;
        let globalTopLoaded = 0, globalTopTotal = 0, globalTopBusy = false;

        async function loadGlobalTop() {
            const list = document.getElementById('lb-list');
            list.innerHTML = '<li class="ca-state ca-state--loading">Загрузка...</li>';
            document.getElementById('lb-load-more').style.display = 'none';
            globalTopLoaded = 0;
            globalTopTotal = 0;
            await fetchGlobalTopPage(true);
        }

        async function loadMoreGlobalTop() {
            await fetchGlobalTopPage(false);
        }

        async function fetchGlobalTopPage(isFirst) {
            if (globalTopBusy) return;
            globalTopBusy = true;
            const list = document.getElementById('lb-list');
            const moreBtn = document.getElementById('lb-load-more');
            moreBtn.disabled = true;
            try {
                const { data, error } = await db.rpc('get_global_top_self', {
                    p_limit: GLOBAL_TOP_PAGE, p_offset: globalTopLoaded
                });
                if (error) throw error;
                const rows = data || [];

                if (isFirst) {
                    list.innerHTML = '';
                    globalTopTotal = rows.length ? rows[0].total_students : 0;
                }
                if (isFirst && !rows.length) {
                    list.innerHTML = '<li class="ca-state ca-state--empty">Пока никого нет</li>';
                }

                rows.forEach(row => {
                    // Медали — только у первых трёх мест общего топа (их считает сервер).
                    let rankDisplay = `#${row.place}`;
                    if (row.place === 1) rankDisplay = '🥇';
                    if (row.place === 2) rankDisplay = '🥈';
                    if (row.place === 3) rankDisplay = '🥉';

                    list.appendChild(buildLeaderboardRow({
                        rankText: rankDisplay,
                        name: row.name || '',
                        eq: row.equipment || {},
                        isMe: row.student_id === currentUser.id,
                        scoreText: `${row.lifetime_points} ⭐`
                    }));
                });
                globalTopLoaded += rows.length;

                document.getElementById('lb-season-label').innerText = globalTopTotal
                    ? `За все сезоны · учеников: ${globalTopTotal}`
                    : 'За все сезоны';

                const hasMore = globalTopLoaded < globalTopTotal;
                moreBtn.style.display = hasMore ? '' : 'none';
                moreBtn.textContent = hasMore
                    ? `Показать ещё (${globalTopTotal - globalTopLoaded})`
                    : 'Показать ещё';
            } catch (e) {
                if (isFirst) list.innerHTML = '<li class="ca-state ca-state--error">Ошибка</li>';
                log('❌ Лидерборд: ' + (e.message || e));
            } finally {
                moreBtn.disabled = false;
                globalTopBusy = false;
            }
        }
