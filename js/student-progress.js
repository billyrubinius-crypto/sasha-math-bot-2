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
            const progress = document.getElementById('rank-progress');
            try {
                // claim-based self-обёртка (T10-08B): identity из JWT, без p_student_id.
                const { data, error } = await db.rpc('get_student_rank_title_self');
                if (error) throw error;

                badge.textContent = `🎓 ${data.title}`;
                badge.style.display = 'inline-block';

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
                badge.style.display = 'none';
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
                container.innerHTML = `<div class="chart-empty" style="color:#f44336;">Ошибка загрузки графика</div>`;
                log(e.message);
            }
        }

        // Свой SVG-график без внешних библиотек: точка = один пробник, ось X — порядковый номер
        // недели (в хронологическом порядке; пропущенные недели не интерполируются — здесь просто
        // нет промежуточной точки, ось не «знает» про календарный разрыв, как и раньше).
        function renderMockChart(container, trajectory) {
            const points = trajectory.points || [];
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
            box.innerHTML = `Неделя от ${d}.${m}.${y} • ${esc(p.score)} баллов`;
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
                        'weekly_reward': 'Награда за неделю 🥯',
                        'mock_exam_weekly': 'Пробник недели',
                        'mock_exam_record': 'Личный рекорд на пробнике',
                        'daily_quest_life_1': 'Испытание дня 1',
                        'daily_quest_life_2': 'Испытание дня 2',
                        'daily_quest_combo': 'Бонус за два испытания'
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
            // Достижения жизненных привычек Stage 4 (U06) — без бубликов, только badge.
            { code: 'life_first',           icon: '🌿', name: 'Первый челлендж' },
            { code: 'life_7',               icon: '🏃', name: 'Семь челленджей' },
            { code: 'life_30',              icon: '🧗', name: 'Тридцать челленджей' },
            { code: 'life_100',             icon: '🏆', name: 'Сотня челленджей' },
            { code: 'life_variety_5',       icon: '🎨', name: 'Пять разных' },
            { code: 'life_streak_7',        icon: '🌈', name: 'Неделя привычки' },
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
            // Ленивое создание сезона теперь на сервере (T10-08B): seasons закрыт RLS от прямой
            // записи. ensure_current_season (definer) возвращает открытый сезон, создаёт при
            // отсутствии; гонку ловит partial-unique idx_seasons_one_active.
            const { data, error } = await db.rpc('ensure_current_season');
            if (error) return null;
            return data ?? null;
        }

        // --- ЛИГИ (L03) ---
        // Вкладка «Лидеры» имеет два режима: «Моя лига» (по умолчанию) и «Общий топ»
        // (прежний сезонный топ-10, где топ-3 получают 100/60/30). loadLeaderboard остаётся
        // точкой входа из switchTab и просто открывает режим лиги. Места и переходы НЕ считаются
        // на клиенте: их отдаёт сервер (get_student_league_snapshot / preview_league_close, L01).
        // Названия семи лиг — снимок league_tiers (миграция 019), для лестницы без запроса.
        const LEAGUE_LADDER = ['Бронза', 'Серебро', 'Золото', 'Платина', 'Алмаз', 'Мастер', 'Легенда'];

        async function loadLeaderboard() {
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
                html += `<li class="${cls}"><span>${mark}</span><span>${esc(LEAGUE_LADDER[t - 1])}</span></li>`;
            }
            html += '</ul>';
            return html;
        }

        async function loadLeague() {
            const box = document.getElementById('league-content');
            box.innerHTML = '<div style="text-align:center; padding:30px; opacity:0.5;">Загрузка...</div>';
            try {
                // claim-based self-обёртки (T10-08B): identity из JWT; preview — leaderboard
                // (student+teacher), definer, без раскрытия telegram_username.
                const [{ data: snap, error: snapErr }, { data: preview, error: prevErr }] = await Promise.all([
                    db.rpc('get_student_league_snapshot_self'),
                    db.rpc('preview_league_close_self')
                ]);
                if (snapErr) throw snapErr;
                if (prevErr) throw prevErr;

                const tier = snap && snap.tier ? snap.tier : 1;
                const tierName = (snap && snap.tier_name) || LEAGUE_LADDER[tier - 1];

                // Шапка: текущая лига + корона (снимок отдаёт has_crown только в её действующий сезон).
                let html = `<div class="league-badge">🏅 ${esc(tierName)}`;
                if (snap && snap.has_crown) html += ' 👑';
                html += '</div>';

                if (!snap || !snap.in_season) {
                    // Нет membership в текущем сезоне (ещё не заработал очков) либо сезон не идёт.
                    html += '<div class="league-note">Вы ещё не в сезоне. Заработайте очки сезона (принятая домашка, пробники) — и попадёте в лигу.</div>';
                    html += renderLeagueLadder(tier);
                    box.innerHTML = html;
                    return;
                }

                if (snap.season_id) html += `<div class="league-note">Сезон №${snap.season_id} идёт. Места, переходы и Корона фиксируются при закрытии сезона учителем.</div>`;

                if (snap.is_late_entry) {
                    // Поздний вход: видит место, но в этот неполный сезон без повышения/понижения.
                    html += '<div class="league-note">Вы присоединились в середине сезона: ваше место видно, но повышения и понижения в этом неполном сезоне не будет — они начнутся со следующего сезона.</div>';
                    if (snap.place && snap.cohort_size) {
                        html += `<div class="league-standing">Ваше место: <b>${snap.place}</b> из ${snap.cohort_size}</div>`;
                    }
                    html += renderLeagueLadder(tier);
                    box.innerHTML = html;
                    return;
                }

                // Обычный участник: standings своей когорты из preview (серверные места/переходы).
                const myRow = (preview || []).find(r => r.student_id === currentUser.id);
                const cohort = myRow
                    ? (preview || []).filter(r => r.tier === myRow.tier && r.cohort_index === myRow.cohort_index)
                        .sort((a, b) => a.place - b.place)
                    : [];
                const active = snap.active_in_cohort || 0;

                // Пояснение зон переходов по фактическому числу активных (SPEC_STAGE3 §4).
                if (active < 5) {
                    html += `<div class="league-note">В когорте ${active} активных (нужно 5+). В этом сезоне переходов между лигами не будет.</div>`;
                } else {
                    const up = cohort.filter(r => r.projected_movement === 'promote').length;
                    const down = cohort.filter(r => r.projected_movement === 'demote').length;
                    html += `<div class="league-note">Активных в когорте: ${active}. Сейчас повышаются <b>${up}</b> сверху, понижаются <b>${down}</b> снизу (по текущим очкам).</div>`;
                }

                box.innerHTML = html;

                if (cohort.length) {
                    const listEl = document.createElement('ul');
                    listEl.className = 'leaderboard-list';

                    // Имена и косметика участников когорты — батчами (не N+1), как в общем топе.
                    const ids = cohort.map(r => r.student_id);
                    const nameById = {};
                    const { data: studs } = await db.from('students').select('name, telegram_id').in('telegram_id', ids);
                    (studs || []).forEach(s => { nameById[s.telegram_id] = s.name || ''; });
                    const eqByStudent = {};
                    const { data: eqAll } = await equipmentQuery(ids, true);
                    (eqAll || []).forEach(r => { (eqByStudent[r.student_id] = eqByStudent[r.student_id] || []).push(r); });

                    cohort.forEach(r => {
                        const isMe = r.student_id === currentUser.id;
                        const eq = buildEquipMap(eqByStudent[r.student_id] || []);
                        const li = document.createElement('li');
                        li.className = 'lb-item' + (isMe ? ' lb-me' : '') +
                            (r.projected_movement === 'promote' ? ' lb-promote' : '') +
                            (r.projected_movement === 'demote' ? ' lb-demote' : '');

                        const rank = document.createElement('div');
                        rank.className = 'lb-rank'; rank.textContent = `#${r.place}`;

                        const avatar = document.createElement('div');
                        avatar.className = 'lb-avatar';
                        avatar.textContent = nameById[r.student_id] ? nameById[r.student_id][0].toUpperCase() : '?';
                        applyAvatarFrame(avatar, eq);

                        const wrap = document.createElement('div');
                        wrap.className = 'lb-name-wrap';
                        const line = document.createElement('div');
                        line.className = 'lb-name-line';
                        renderNick(line, nameById[r.student_id] || '', eq, isMe ? ' (Вы)' : '');
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
                        score.className = 'lb-score';
                        const arrow = r.projected_movement === 'promote' ? ' ↑' : (r.projected_movement === 'demote' ? ' ↓' : '');
                        score.textContent = `${r.points} ⭐${arrow}`;

                        li.appendChild(rank);
                        li.appendChild(avatar);
                        li.appendChild(wrap);
                        li.appendChild(score);
                        listEl.appendChild(li);
                    });
                    box.appendChild(listEl);
                }

                // Предупреждение о неактивных сезонах (второй пустой сезон подряд — понижение).
                if (snap.inactive_seasons >= 1) {
                    const warn = document.createElement('div');
                    warn.className = 'league-note';
                    warn.style.color = '#e67e22';
                    warn.textContent = `Пропущено сезонов подряд без очков: ${snap.inactive_seasons}. Ещё один такой сезон — понижение на лигу.`;
                    box.appendChild(warn);
                }

                const ladder = document.createElement('div');
                ladder.innerHTML = renderLeagueLadder(tier);
                box.appendChild(ladder);
            } catch (e) {
                box.innerHTML = '<div style="text-align:center; color:#f44336; padding:30px;">Ошибка лиги</div>';
                log('❌ Лига: ' + (e.message || e));
            }
        }

        async function loadGlobalTop() {
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

