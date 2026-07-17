// student-progress.js — профиль, косметика, пробники, история, достижения, лидерборд (R01)
        // --- КОСМЕТИКА / ЭКИПИРОВКА (S3) ---
        // Разрешённые классы payload — применяем только известные из каталога, чтобы строка из
        // БД не превратилась в произвольный CSS-класс.
        const FRAME_CLASSES = new Set(['frame-notebook','frame-winter','frame-fire100','frame-legend-1','frame-legend-2','frame-legend-3','frame-legend-4','frame-pulsar','frame-orbit']);
        const BG_CLASSES = new Set(['bg-grid','bg-space','bg-aurora','bg-draft']);

        // student_equipment + встроенный shop_items (render_payload/name) одним embed-запросом.
        function equipmentQuery(idsOrOne, isList) {
            const q = db.from('student_equipment')
                .select('student_id, slot, item_code, variant, shop_items(render_payload, name)');
            return isList ? q.in('student_id', idsOrOne) : q.eq('student_id', idsOrOne);
        }

        // Массив строк экипировки → карта slot → {item_code, variant, payload, name}
        function buildEquipMap(rows) {
            const map = {};
            (rows || []).forEach(r => {
                const si = r.shop_items || {};
                map[r.slot] = { item_code: r.item_code, variant: r.variant, payload: si.render_payload, name: si.name };
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

        function applyProfileCosmetics(eq) {
            renderNick(document.getElementById('user-name'), currentUser.first_name || '', eq, '');
            const titleEl = document.getElementById('profile-title');
            const title = equippedTitleText(eq.title);
            if (title) { titleEl.textContent = title; titleEl.style.display = 'block'; }
            else { titleEl.style.display = 'none'; titleEl.textContent = ''; }
            applyAvatarFrame(document.getElementById('user-avatar-container'), eq);
            const scr = document.getElementById('screen-profile');
            BG_CLASSES.forEach(c => scr.classList.remove(c));
            if (eq.background && BG_CLASSES.has(eq.background.payload)) scr.classList.add(eq.background.payload);
        }

        // --- ПРОФИЛЬ И ИСТОРИЯ ---
        async function loadProfile(isRetryAfterInsert) {
            try {
                let { data, error } = await db.from('students').select('*').eq('telegram_id', currentUser.id).single();

                if (error && error.code === 'PGRST116') {
                    // Повторяем не больше одного раза: если insert не удался, без этого select→insert зациклились бы навсегда
                    if (isRetryAfterInsert) throw new Error('Не удалось создать профиль ученика');
                    const { error: insertError } = await db.from('students').insert([{
                        telegram_id: currentUser.id, name: currentUser.first_name,
                        telegram_username: currentUser.username || null,
                        // rating = очки текущего сезона (см. database/migrations/005), не старый
                        // рейтинг — новый ученик стартует с 0, а не с наследственных 50
                        rating: 0, huikons: 0, lives: 3, current_streak: 0
                    }]);
                    if (insertError) throw insertError;
                    return loadProfile(true);
                } else if (error) { throw error; }
                
                document.getElementById('val-rating').innerText = data.rating;
                document.getElementById('val-huikons').innerText = data.huikons;

                // Отображение группы
                const groupBadge = document.getElementById('group-badge');
                groupBadge.style.display = 'inline-block';
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
                    const { data: cfg } = await db.from('economy_config').select('cutover_at').maybeSingle();
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

            } catch (e) { log('❌ Ошибка профиля: ' + e.message); }
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

        async function loadMockExamChart() {
            const container = document.getElementById('mock-chart-container');
            try {
                const { data, error } = await db
                    .from('mock_exam_results')
                    .select('exam_name, score, exam_date, created_at')
                    .eq('student_id', currentUser.id)
                    .order('created_at', { ascending: true });

                if (error) throw error;

                if (!data || data.length === 0) {
                    container.innerHTML = `<div class="chart-empty">🧮 Пока нет результатов пробников</div>`;
                    return;
                }

                renderMockChart(container, data);
            } catch (e) {
                container.innerHTML = `<div class="chart-empty" style="color:#f44336;">Ошибка загрузки графика</div>`;
                log(e.message);
            }
        }

        // Свой SVG-график без внешних библиотек: точка = один пробник, ось X — название пробника (в порядке синхронизации)
        function renderMockChart(container, points) {
            mockExamPoints = points;

            const W = 320, H = 140;
            const padL = 32, padR = 12, padT = 10, padB = 26;
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
                return `<line x1="${padL}" y1="${y}" x2="${W - padR}" y2="${y}" stroke="rgba(128,128,128,0.15)" stroke-width="1"/>
                        <text x="${padL - 6}" y="${y + 4}" font-size="9" text-anchor="end" fill="var(--tg-hint)">${val}</text>`;
            }).join('');

            const linePoints = points.map((p, i) => `${xFor(i)},${yFor(Number(p.score) || 0)}`).join(' ');

            const dots = points.map((p, i) => {
                const x = xFor(i), y = yFor(Number(p.score) || 0);
                return `<circle cx="${x}" cy="${y}" r="5" fill="var(--tg-link)" stroke="var(--tg-bg)" stroke-width="2" style="cursor:pointer" onclick="showExamInfo(${i})"/>`;
            }).join('');

            const labels = points.map((p, i) => {
                const x = xFor(i);
                return `<text x="${x}" y="${H - padB + 16}" font-size="9" text-anchor="middle" fill="var(--tg-hint)">№${i + 1}</text>`;
            }).join('');

            container.innerHTML = `
                <svg viewBox="0 0 ${W} ${H}" style="width:100%; height:auto; display:block;">
                    ${gridLines}
                    <polyline points="${linePoints}" fill="none" stroke="var(--tg-link)" stroke-width="1.5" opacity="0.4"/>
                    ${dots}
                    ${labels}
                </svg>
                <div id="exam-info-box" class="exam-info-box">${esc(lastResultSummary(points))}</div>
            `;
        }

        // Последний результат и его изменение к предыдущему пробнику (P02B) — простая разница
        // двух чисел, не прогноз: карточка запрещает медицинские/гарантирующие формулировки.
        function lastResultSummary(points) {
            const last = Number(points[points.length - 1].score) || 0;
            if (points.length < 2) return `Последний результат: ${last}. Нажми на точку, чтобы увидеть детали`;
            const prev = Number(points[points.length - 2].score) || 0;
            const delta = last - prev;
            const sign = delta > 0 ? '+' : '';
            return `Последний результат: ${last} (${sign}${delta} к предыдущему). Нажми на точку, чтобы увидеть детали`;
        }

        // exam_date — чистая дата (YYYY-MM-DD, без времени), парсим вручную, чтобы не словить сдвиг на день из-за часового пояса браузера
        function formatPlainDate(dateStr) {
            const [y, m, d] = dateStr.split('-');
            return `${d}.${m}.${y}`;
        }

        function showExamInfo(index) {
            const p = mockExamPoints[index];
            const box = document.getElementById('exam-info-box');
            if (!p || !box) return;
            const date = p.exam_date ? formatPlainDate(p.exam_date)
                : (p.created_at ? new Date(p.created_at).toLocaleDateString('ru-RU') : '—');
            box.innerHTML = `<b>${esc(p.exam_name || 'Пробник')}</b> • ${esc(p.score)} баллов • ${date}`;
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
                    list.innerHTML = '<li style="text-align:center; padding:20px; opacity:0.5;">📭 История пока пуста</li>';
                    return;
                }
                
                list.innerHTML = '';
                data.forEach(item => {
                    const isPositive = item.change_amount > 0;
                    const reasonMap = {
                        'dz_upload_daily': 'Загрузка ежедневного ДЗ',
                        'dz_upload_weekly': 'Загрузка еженедельного ДЗ',
                        'dz_upload_individual': 'Загрузка индивидуального задания',
                        'streak_day_1': 'Серия 1 день 🔥',
                        'streak_day_2': 'Серия 2 дня 🔥',
                        'streak_day_3': 'Серия 3+ дней 🔥',
                        'weekly_approved': 'Еженедельное принято ✅',
                        'individual_approved': 'Индивидуальное принято ✅',
                        'weekly_reward': 'Награда за неделю 🥯'
                    };
                  // Специальная логика для штрафов
                    let displayReason = reasonMap[item.reason];
                    if (!displayReason && item.reason && item.reason.startsWith('penalty:')) {
                        // Берем текст после "penalty: "
                        const penaltyText = item.reason.replace('penalty: ', '');
                        displayReason = `⚠️ Штраф: ${penaltyText}`;
                    }
                    // Недельные достижения и призы сезона (W09/W10): единый читаемый ярлык
                    if (!displayReason && item.reason && item.reason.startsWith('achievement_')) {
                        displayReason = 'Достижение 🏆';
                    }
                    if (!displayReason && item.reason && item.reason.startsWith('season_place_')) {
                        displayReason = 'Приз за место в сезоне 🏆';
                    }
                    if (!displayReason) {
                        displayReason = item.reason || 'Начисление';
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
                list.innerHTML = '<li style="text-align:center; color:red; padding:20px;">Ошибка загрузки истории</li>';
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
                    .select('season_id, points, place')
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
                    li.innerHTML = `
                        <div class="hist-info">
                            <div class="hist-reason">Сезон №${item.season_id} — ${placeDisplay} место</div>
                        </div>
                        <div class="hist-amount">${item.points} ⭐</div>
                    `;
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
        const ACHIEVEMENTS_META = [
            { code: 'first_step',           icon: '🌱', name: 'Первый шаг' },
            { code: 'first_good_week',      icon: '📗', name: 'Неделя получилась' },
            { code: 'perfect_week',         icon: '🌟', name: 'Семь из семи' },
            { code: 'rhythm_4',             icon: '📅', name: 'Месяц в ритме' },
            { code: 'rhythm_12',            icon: '🗓', name: 'Четверть года' },
            { code: 'rhythm_24',            icon: '🏅', name: 'Полгода в ритме' },
            { code: 'good_weeks_36',        icon: '🎓', name: 'Учебный год' },
            { code: 'no_shields_8',         icon: '💪', name: 'Своими силами' },
            { code: 'perfect_month_weekly', icon: '✨', name: 'Идеальный месяц' },
            { code: 'rebirth_week',         icon: '🕊', name: 'Возвращение' },
            { code: 'clean_10',             icon: '🎯', name: 'С первого раза' },
            { code: 'streak_7',      icon: '🔥', name: 'Неделя огня',            legacy: true },
            { code: 'streak_30',     icon: '📆', name: 'Месяц без пропусков',     legacy: true },
            { code: 'streak_100',    icon: '💯', name: 'Сотня',                  legacy: true },
            { code: 'streak_200',    icon: '⚡', name: '200 дней',               legacy: true },
            { code: 'streak_365',    icon: '👑', name: 'Год дисциплины',         legacy: true },
            { code: 'perfect_month', icon: '🌙', name: 'Идеальный месяц (стрик)', legacy: true },
            { code: 'rebirth',       icon: '🪶', name: 'Возрождение (стрик)',     legacy: true }
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
                    tile.innerHTML = `
                        <div class="ach-icon">${has ? a.icon : '🔒'}</div>
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
        // students.rating = очки ТЕКУЩЕГО сезона (database/migrations/005) — лидерборд сортирует
        // по нему без изменений с этапа, когда rating было мёртвым полем.
        //
        // Номер сезона для подписи берётся из seasons.id (открытая строка, end_date is null).
        // Строку создаёт первый, кто открыл лидерборд после применения миграции 005 или после
        // закрытия предыдущего сезона (G8) — тот же паттерн, что loadProfile() уже использует
        // для ленивого создания записи students при первом входе. Гонку двух одновременных
        // созданий предотвращает частичный уникальный индекс idx_seasons_one_active (миграция
        // 005): при конфликте просто перечитываем уже созданную кем-то строку.
        async function getCurrentSeasonId() {
            const { data } = await db.from('seasons').select('id').is('end_date', null).order('id', { ascending: false }).limit(1);
            if (data && data.length) return data[0].id;

            const { data: inserted, error } = await db.from('seasons').insert({ start_date: getTodayMSK() }).select('id').single();
            if (error) {
                const { data: retry } = await db.from('seasons').select('id').is('end_date', null).order('id', { ascending: false }).limit(1);
                return retry && retry.length ? retry[0].id : null;
            }
            return inserted.id;
        }

        async function loadLeaderboard() {
            const list = document.getElementById('lb-list');
            list.innerHTML = '<li style="text-align:center; padding:30px; opacity:0.5;">Загрузка...</li>';

            try {
                const [{ data, error }, seasonId] = await Promise.all([
                    db.from('students').select('name, rating, telegram_id').order('rating', { ascending: false }).limit(10),
                    getCurrentSeasonId()
                ]);
                document.getElementById('lb-season-label').innerText = seasonId ? `Сезон №${seasonId}` : '';

                if (error) throw error;

                // Экипировка всех из топ-10 ОДНИМ запросом (не N+1) → карта по ученику
                const ids = data.map(s => s.telegram_id);
                const eqByStudent = {};
                if (ids.length) {
                    const { data: eqAll } = await equipmentQuery(ids, true);
                    (eqAll || []).forEach(r => { (eqByStudent[r.student_id] = eqByStudent[r.student_id] || []).push(r); });
                }

                list.innerHTML = '';
                data.forEach((student, index) => {
                    const isMe = student.telegram_id === currentUser.id;
                    const eq = buildEquipMap(eqByStudent[student.telegram_id] || []);
                    const li = document.createElement('li');
                    li.className = `lb-item ${isMe ? 'lb-me' : ''}`;

                    let rankDisplay = `#${index + 1}`;
                    if (index === 0) rankDisplay = '🥇';
                    if (index === 1) rankDisplay = '🥈';
                    if (index === 2) rankDisplay = '🥉';

                    const rank = document.createElement('div');
                    rank.className = 'lb-rank'; rank.textContent = rankDisplay;

                    const avatar = document.createElement('div');
                    avatar.className = 'lb-avatar';
                    avatar.textContent = student.name ? student.name[0].toUpperCase() : '?';
                    applyAvatarFrame(avatar, eq);

                    const wrap = document.createElement('div');
                    wrap.className = 'lb-name-wrap';
                    const line = document.createElement('div');
                    line.className = 'lb-name-line';
                    renderNick(line, student.name || '', eq, isMe ? ' (Вы)' : '');
                    wrap.appendChild(line);
                    if (eq.title) {
                        const title = equippedTitleText(eq.title);
                        if (title) {
                            const t = document.createElement('div');
                            t.className = 'lb-title'; t.textContent = title;
                            wrap.appendChild(t);
                        }
                    }

                    const score = document.createElement('div');
                    score.className = 'lb-score'; score.textContent = `${student.rating} ⭐`;

                    li.appendChild(rank);
                    li.appendChild(avatar);
                    li.appendChild(wrap);
                    li.appendChild(score);
                    list.appendChild(li);
                });

            } catch (e) {
                list.innerHTML = '<li style="text-align:center; color:#f44336; padding:30px;">Ошибка</li>';
                log('❌ Лидерборд: ' + (e.message || e));
            }
        }

