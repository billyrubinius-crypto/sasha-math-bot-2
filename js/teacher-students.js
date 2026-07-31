// teacher-students.js — ученики, сезоны, индивидуальные задания, пробники (R02)

        // --- ПЛАНИРОВАНИЕ СЕЗОНОВ V2 (миграции 057–059) ---

        function formatMsk(iso) {
            if (!iso) return '—';
            const d = new Date(iso);
            if (isNaN(d.getTime())) return '—';
            return d.toLocaleString('ru-RU', {
                timeZone: 'Europe/Moscow',
                day: '2-digit', month: '2-digit', year: 'numeric',
                hour: '2-digit', minute: '2-digit'
            }) + ' МСК';
        }

        const SEASON_STATUS_LABELS = {
            catalog_only: { text: 'Архив', className: 'archived' },
            draft:        { text: 'Черновик', className: 'draft' },
            scheduled:    { text: 'Запланирован', className: 'scheduled' },
            active:       { text: 'Текущий', className: 'active' },
            closed:       { text: 'Закрыт', className: 'closed' },
            archived:     { text: 'Архив', className: 'archived' }
        };

        const SEASON_ERROR_TEXT = {
            title_required: 'Укажите название сезона (до 60 символов).',
            season_number_required: 'Укажите номер сезона от 0 до 999.',
            scheduled_season_not_found: 'Редактировать можно только запланированный сезон.',
            markup_not_allowed: 'HTML-разметка в текстах запрещена.',
            forbidden: 'Недостаточно прав.'
        };

        function seasonErrorText(e) {
            const raw = (e && (e.message || e.code)) ? String(e.message || e.code) : '';
            const key = Object.keys(SEASON_ERROR_TEXT).find(k => raw.includes(k));
            return key ? SEASON_ERROR_TEXT[key] : (raw || 'Не удалось сохранить сезон');
        }

        let seasonV2Rows = [];
        let seasonV2Previewing = null;
        let seasonV2EditingCode = null;

        function seasonDisplayLabel(row) {
            if (row.catalog_only) return 'Архив';
            const displayNumber = row.display_number ?? row.competition_season_no;
            return displayNumber === null || displayNumber === undefined
                ? 'Сезон'
                : `Сезон №${displayNumber}`;
        }

        function seasonItemMap(row) {
            return Object.fromEntries((row.items || []).map((item) => [item.slot, {
                item_code: item.item_code,
                slot: item.slot,
                name: item.name,
                description: item.description,
                rarity: item.rarity,
                payload: item.render_payload,
                render_payload: item.render_payload,
                price: Number(item.price),
                motion_policy: item.motion_policy
            }]));
        }

        function seasonPreviewCard(row, target) {
            target.replaceChildren();
            const eq = seasonItemMap(row);
            const grid = document.createElement('div');
            grid.className = 'season-v2-preview-grid';

            [
                { label: 'Магазин · 112 px', size: 112, mode: 'expanded', theme: 'dark' },
                { label: 'Профиль · 48 px', size: 48, mode: 'profile', theme: 'light' },
                { label: 'Оба топа · 32 px', size: 32, mode: 'compact', theme: 'dark' },
                { label: 'Раскрытие · 160 px', size: 160, mode: 'expanded', theme: 'dark' }
            ].forEach((preview) => {
                const card = document.createElement('div');
                card.className = `season-v2-preview-card season-v2-preview-card--${preview.theme}`;
                const scene = window.SeasonCosmetics?.createScene(eq.background, 'season-v2-preview-scene');
                if (scene) card.appendChild(scene);

                const label = document.createElement('small');
                label.className = 'season-v2-preview-label';
                label.textContent = preview.label;
                card.appendChild(label);

                const avatar = window.SeasonCosmetics?.createAvatar(eq, preview.size, preview.mode, 'A');
                if (avatar) card.appendChild(avatar);

                const copy = document.createElement('div');
                copy.className = 'season-v2-preview-copy';
                const name = document.createElement('strong');
                name.textContent = row.title;
                const title = document.createElement('span');
                title.className = `season-v2-title rarity-title-${eq.title?.rarity || 'common'} title-visual-${window.SeasonCosmetics?.titleVisual(eq.title) || 'plain'}`;
                title.textContent = eq.title?.name || '';
                copy.append(name, title);
                card.appendChild(copy);
                grid.appendChild(card);
            });
            target.appendChild(grid);
        }

        async function loadSeasons() {
            const box = document.getElementById('season-list');
            if (!box) return;
            box.textContent = 'Загрузка сезонов…';
            try {
                const { data, error } = await db.rpc('admin_list_season_v2_self');
                if (error) throw error;
                seasonV2Rows = Array.isArray(data) ? data : [];
                box.replaceChildren();
                seasonV2Rows.forEach((row) => {
                    const meta = SEASON_STATUS_LABELS[row.status] || { text: row.status, className: 'draft' };
                    const card = document.createElement('article');
                    card.className = 'season-v2-plan-card';
                    const head = document.createElement('div');
                    head.className = 'season-v2-plan-head';
                    const title = document.createElement('strong');
                    title.textContent = `${seasonDisplayLabel(row)} · ${row.title}`;
                    const badge = document.createElement('span');
                    badge.className = `season-v2-status season-v2-status--${meta.className}`;
                    badge.textContent = meta.text;
                    const headControls = document.createElement('div');
                    headControls.className = 'season-v2-head-controls';
                    headControls.appendChild(badge);
                    if (row.status === 'scheduled') {
                        const edit = document.createElement('button');
                        edit.className = 'season-v2-edit-btn';
                        edit.type = 'button';
                        edit.textContent = '✏️ Изменить';
                        edit.setAttribute('aria-label', `Изменить ${seasonDisplayLabel(row)}`);
                        edit.onclick = () => openSeasonV2InlineEditor(row.preset_code, card);
                        headControls.appendChild(edit);
                    }
                    head.append(title, headControls);

                    const dates = document.createElement('div');
                    dates.className = 'card-meta';
                    dates.textContent = `${formatMsk(row.starts_at)} — ${formatMsk(row.ends_at)}`;
                    const items = document.createElement('div');
                    items.className = 'season-v2-rarity-line';
                    items.textContent = `${(row.items || []).length} товара: ` +
                        (row.items || []).map((item) => item.name).join(' · ');
                    card.append(head, dates, items);

                    const actions = document.createElement('div');
                    actions.className = 'season-v2-card-actions';
                    const preview = document.createElement('button');
                    preview.className = 'btn-secondary';
                    preview.type = 'button';
                    preview.textContent = 'Товары и предпросмотр';
                    preview.onclick = () => openSeasonV2Preview(row.preset_code);
                    actions.appendChild(preview);
                    card.appendChild(actions);
                    if (seasonV2EditingCode === row.preset_code) {
                        renderSeasonV2InlineEditor(row, card);
                    }
                    box.appendChild(card);
                });
            } catch (e) {
                box.textContent = 'Не удалось загрузить сезоны.';
                log('❌ Season V2: ' + (e.message || e));
            }
        }

        function openSeasonV2InlineEditor(presetCode, card) {
            const row = seasonV2Rows.find((item) => item.preset_code === presetCode);
            if (!row || row.status !== 'scheduled') return;
            document.querySelectorAll('.season-v2-inline-editor').forEach((editor) => editor.remove());
            seasonV2EditingCode = presetCode;
            renderSeasonV2InlineEditor(row, card);
        }

        function renderSeasonV2InlineEditor(row, card) {
            const editor = document.createElement('div');
            editor.className = 'season-v2-inline-editor';

            const titleLabel = document.createElement('label');
            titleLabel.textContent = 'Название';
            const titleInput = document.createElement('input');
            titleInput.type = 'text';
            titleInput.maxLength = 60;
            titleInput.value = row.title || '';
            titleLabel.appendChild(titleInput);
            editor.appendChild(titleLabel);

            const numberLabel = document.createElement('label');
            numberLabel.className = 'season-v2-inline-number';
            numberLabel.textContent = 'Номер';
            const numberInput = document.createElement('input');
            numberInput.type = 'number';
            numberInput.min = '0';
            numberInput.max = '999';
            numberInput.step = '1';
            numberInput.required = true;
            numberInput.value = row.display_number ?? row.competition_season_no ?? '';
            numberLabel.appendChild(numberInput);
            editor.appendChild(numberLabel);

            const errorBox = document.createElement('div');
            errorBox.className = 'season-v2-inline-error';
            errorBox.hidden = true;

            const buttons = document.createElement('div');
            buttons.className = 'season-v2-inline-actions';
            const save = document.createElement('button');
            save.className = 'btn-primary season-v2-inline-save';
            save.type = 'button';
            save.textContent = 'Сохранить';
            save.onclick = () => saveSeasonV2InlineMeta(row, titleInput, numberInput, save, errorBox);
            const cancel = document.createElement('button');
            cancel.className = 'btn-secondary season-v2-inline-cancel';
            cancel.type = 'button';
            cancel.textContent = 'Отмена';
            cancel.onclick = () => {
                seasonV2EditingCode = null;
                editor.remove();
            };
            buttons.append(save, cancel);
            editor.append(errorBox, buttons);
            card.appendChild(editor);
            titleInput.focus();
        }

        async function saveSeasonV2InlineMeta(row, titleInput, numberInput, button, errorBox) {
            const title = titleInput.value.trim();
            const displayNumber = numberInput.value === '' ? null : Number(numberInput.value);
            button.disabled = true;
            errorBox.hidden = true;
            try {
                const { error } = await db.rpc('admin_update_scheduled_season_meta_self', {
                    p_preset_code: row.preset_code,
                    p_title: title,
                    p_display_number: displayNumber
                });
                if (error) throw error;
                seasonV2EditingCode = null;
                await loadSeasons();
            } catch (e) {
                errorBox.textContent = seasonErrorText(e);
                errorBox.hidden = false;
            } finally {
                button.disabled = false;
            }
        }

        function openSeasonV2Preview(presetCode) {
            const row = seasonV2Rows.find((item) => item.preset_code === presetCode);
            if (!row) return;
            // Работает и в WebView без structuredClone.
            seasonV2Previewing = JSON.parse(JSON.stringify(row));
            const modal = document.getElementById('season-v2-modal');
            modal.classList.add('open');
            modal.setAttribute('aria-hidden', 'false');
            document.getElementById('season-v2-modal-title').textContent =
                `${seasonDisplayLabel(row)} · ${row.title}`;
            renderSeasonV2Items(seasonV2Previewing);
            seasonPreviewCard(seasonV2Previewing, document.getElementById('season-v2-live-preview'));
        }

        function closeSeasonV2Preview() {
            const modal = document.getElementById('season-v2-modal');
            modal.classList.remove('open');
            modal.setAttribute('aria-hidden', 'true');
            seasonV2Previewing = null;
        }

        document.addEventListener('keydown', (event) => {
            if (event.key === 'Escape' && document.getElementById('season-v2-modal')?.classList.contains('open')) {
                closeSeasonV2Preview();
            }
        });

        document.addEventListener('click', (event) => {
            if (event.target?.id === 'season-v2-modal') closeSeasonV2Preview();
        });

        function renderSeasonV2Items(row) {
            const list = document.getElementById('season-v2-items');
            list.replaceChildren();
            (row.items || []).forEach((item) => {
                const card = document.createElement('div');
                card.className = `season-v2-item-editor rarity-${item.rarity}`;
                const label = document.createElement('strong');
                const slotLabel = {
                    avatar: 'Аватар',
                    frame: 'Рамка',
                    title: 'Титул',
                    background: 'Фон'
                }[item.slot] || item.slot;
                const rarityLabel = {
                    common: 'обычный',
                    rare: 'редкий',
                    epic: 'эпический',
                    legendary: 'легендарный'
                }[item.rarity] || item.rarity;
                label.textContent = `${slotLabel} · ${rarityLabel}`;
                card.appendChild(label);

                const itemData = {
                    item_code: item.item_code,
                    payload: item.render_payload,
                    rarity: item.rarity,
                    motion_policy: item.motion_policy
                };
                const visual = document.createElement('div');
                visual.className = `season-v2-item-visual season-v2-item-visual--${item.slot}`;
                if (item.slot === 'avatar' || item.slot === 'frame') {
                    visual.appendChild(SeasonCosmetics.createAvatar(
                        { [item.slot]: itemData }, 72, 'expanded', 'A'
                    ));
                } else if (item.slot === 'background') {
                    const scene = SeasonCosmetics.createScene(itemData, 'season-v2-item-scene');
                    if (scene) visual.appendChild(scene);
                } else {
                    const title = document.createElement('span');
                    title.className = `rarity-title-${item.rarity}`;
                    title.textContent = item.name;
                    visual.appendChild(title);
                }
                const name = document.createElement('b');
                name.textContent = item.name;
                const description = document.createElement('span');
                description.className = 'season-v2-item-description';
                description.textContent = item.description;
                const price = document.createElement('span');
                price.className = 'season-v2-item-price';
                price.textContent = `${item.price} 🥯`;
                card.append(visual, name, description, price);
                list.appendChild(card);
            });
        }

        async function loadStudents() {
            const { data } = await db.from('students').select('telegram_id, name, group_name');
            studentsList = data || [];
            populateGroupFilter();
        }

        function populateGroupFilter() {
            const container = document.getElementById('week-group-list');
            if (!container) return;
            const groups = [...new Set(studentsList.map(s => s.group_name).filter(Boolean))].sort();

            container.querySelectorAll('.week-group-item').forEach(el => el.remove());
            groups.forEach(g => {
                const label = document.createElement('label');
                label.className = 'week-group-item';
                label.style.cssText = 'display:flex; align-items:center; gap:8px;';
                // Название группы — через DOM API, а не строкой в innerHTML: esc() не защищает
                // атрибут value="..." от кавычек (только текстовое содержимое), а group_name — не код,
                // а введённое помощником значение из Google Sheets
                const checkbox = document.createElement('input');
                checkbox.type = 'checkbox';
                checkbox.className = 'week-group-checkbox';
                checkbox.value = g;
                checkbox.onchange = onWeekGroupPick;
                label.appendChild(checkbox);
                label.appendChild(document.createTextNode(' ' + g));
                container.appendChild(label);
            });
        }

        // Превью закрытия лиг (L02): read-only RPC preview_league_close() — активные/размер
        // когорты, проекция переходов на живых данных. Global top-3 здесь не считаем — его
        // tie-break (rating → штрафы → ledger → telegram_id) не выведен отдельным RPC,
        // решение пользователя: показывать только лиговое превью. Ничего не пишет и не
        // подставляет клиентский расчёт — только группирует и отображает готовые ряды RPC.
        async function previewSeasonClose() {
            const btn = document.getElementById('btn-preview-season');
            const box = document.getElementById('season-preview');
            if (btn.disabled) return; // защита от двойного клика
            btn.disabled = true;
            box.innerHTML = '<p style="font-size:13px; color:#666;">Загрузка превью…</p>';
            try {
                // definer self-обёртка (T10-08B): teacher/student, без раскрытия telegram_username.
                const { data, error } = await db.rpc('preview_league_close_self');
                if (error) throw error;

                if (!data || !data.length) {
                    box.innerHTML = '<p style="font-size:13px; color:#666;">Лиговых участников пока нет.</p>';
                    return;
                }

                const nameById = {};
                studentsList.forEach(s => { nameById[s.telegram_id] = s.name || s.telegram_id; });

                // Группировка по (tier, cohort_index) — каждая строка RPC уже несёт tier_name/
                // active_in_cohort/projected_movement, клиент только раскладывает по когортам.
                const cohorts = new Map();
                data.forEach(row => {
                    const key = row.tier + ':' + row.cohort_index;
                    if (!cohorts.has(key)) {
                        cohorts.set(key, { tier: row.tier, tierName: row.tier_name, cohortIndex: row.cohort_index, rows: [] });
                    }
                    cohorts.get(key).rows.push(row);
                });

                const sorted = [...cohorts.values()].sort((a, b) => a.tier - b.tier || a.cohortIndex - b.cohortIndex);

                let html = '';
                sorted.forEach(c => {
                    const active = c.rows[0].active_in_cohort;
                    const promoted = c.rows.filter(r => r.projected_movement === 'promote');
                    const demoted = c.rows.filter(r => r.projected_movement === 'demote');
                    html += `<div style="border:1px solid #eee; border-radius:8px; padding:10px; margin-top:10px;">`;
                    html += `<b>${esc(c.tierName)}${c.cohortIndex > 1 ? ' — когорта ' + c.cohortIndex : ''}</b> `;
                    html += `<span style="color:#666; font-size:13px;">(${c.rows.length} участников, ${active} активных)</span>`;
                    if (active < 5) {
                        html += `<p style="font-size:13px; color:#666; margin:6px 0 0;">Меньше 5 активных — переходов не будет.</p>`;
                    } else {
                        if (promoted.length) {
                            html += `<p style="font-size:13px; color:green; margin:6px 0 0;">↑ Повышение: ${promoted.map(r => esc(nameById[r.student_id])).join(', ')}</p>`;
                        }
                        if (demoted.length) {
                            html += `<p style="font-size:13px; color:#b00; margin:6px 0 0;">↓ Понижение: ${demoted.map(r => esc(nameById[r.student_id])).join(', ')}</p>`;
                        }
                        if (!promoted.length && !demoted.length) {
                            html += `<p style="font-size:13px; color:#666; margin:6px 0 0;">Переходов нет.</p>`;
                        }
                    }
                    html += `</div>`;
                });
                box.innerHTML = html;
            } catch (e) {
                box.innerHTML = '';
                alert('Ошибка превью: ' + e.message);
            } finally {
                btn.disabled = false;
            }
        }

        // --- ПОИСК УЧЕНИКА ПО USERNAME (индивидуальное задание) ---
        let selectedIndivStudentId = null;
        let indivSearchTimeout = null;

        function onIndivUsernameInput() {
            selectedIndivStudentId = null; // при ручном изменении текста выбор сбрасывается — нужно выбрать заново из подсказок
            const query = document.getElementById('indiv-username-input').value.trim();
            const box = document.getElementById('indiv-username-suggestions');
            clearTimeout(indivSearchTimeout);

            if (!query) { box.style.display = 'none'; box.innerHTML = ''; return; }

            indivSearchTimeout = setTimeout(async () => {
                const { data } = await db.from('students')
                    .select('telegram_id, name, telegram_username')
                    .ilike('telegram_username', `%${query}%`)
                    .not('telegram_username', 'is', null)
                    .limit(8);

                if (!data || data.length === 0) {
                    box.innerHTML = '<div class="username-suggestion-item" style="color:#999; cursor:default;">Не найдено</div>';
                    box.style.display = 'block';
                    return;
                }

                box.innerHTML = '';
                data.forEach(s => {
                    const item = document.createElement('div');
                    item.className = 'username-suggestion-item';
                    item.innerHTML = `<b>@${esc(s.telegram_username)}</b> — ${esc(s.name || '')}`;
                    item.onclick = () => selectIndivStudent(s.telegram_id, s.telegram_username, s.name);
                    box.appendChild(item);
                });
                box.style.display = 'block';
            }, 250);
        }

        function selectIndivStudent(telegramId, username, name) {
            selectedIndivStudentId = telegramId;
            document.getElementById('indiv-username-input').value = username;
            document.getElementById('indiv-username-suggestions').style.display = 'none';
        }

        async function assignIndividual() {
            const title = document.getElementById('indiv-title').value.trim();
            const url = document.getElementById('indiv-url').value.trim();
            const comment = document.getElementById('indiv-comment').value.trim();

            if (!selectedIndivStudentId || !title) return alert('Выберите ученика из подсказок и укажите название!');

            // Тот же parseTaskCount/диапазон 1–200, что и у недельных заданий (W02) — один
            // источник количества задач, не второй способ подсчёта (P01B).
            let taskCount;
            try { taskCount = parseTaskCount(document.getElementById('indiv-count').value, 'Индивидуальное задание'); }
            catch(e) { return alert(e.message); }

            // Блокируем кнопку на время сохранения — двойной клик назначил бы задание дважды
            const btn = document.getElementById('btn-assign-indiv');
            btn.disabled = true;
            try {
                // create_individual_assignment_self (T10-06B/07): заменяет прямой browser insert;
                // student_id — легитимный бизнес-аргумент учителя (target ученика), не self-claim.
                const { error } = await db.rpc('create_individual_assignment_self', {
                    p_student_id: selectedIndivStudentId,
                    p_title: title,
                    p_content_url: url,
                    p_teacher_comment: comment,
                    p_task_count: taskCount
                });
                if (error) throw error;
                alert('Индивидуальное задание назначено!');
                document.getElementById('indiv-username-input').value = '';
                selectedIndivStudentId = null;
                document.getElementById('indiv-title').value = '';
                document.getElementById('indiv-url').value = '';
                document.getElementById('indiv-count').value = '';
                document.getElementById('indiv-comment').value = '';
            } catch(e) { alert('Ошибка: ' + e.message); }
            finally { btn.disabled = false; }
        }

        // --- ПОИСК УЧЕНИКА ПО USERNAME (пробник недели, P02B) ---
        // Отдельная копия поиска по username (не переиспользует indiv-*): это Bot 2.0-специфичное
        // правило («не делать сопутствующий рефакторинг существующего кода без карточки») —
        // выносить общий хелпер значило бы менять уже работающий indiv-поиск вне карточки.
        let selectedMockStudentId = null;
        let mockSearchTimeout = null;

        function onMockUsernameInput() {
            selectedMockStudentId = null;
            document.getElementById('mock-trajectory-container').innerHTML = '';
            const query = document.getElementById('mock-username-input').value.trim();
            const box = document.getElementById('mock-username-suggestions');
            clearTimeout(mockSearchTimeout);

            if (!query) { box.style.display = 'none'; box.innerHTML = ''; return; }

            mockSearchTimeout = setTimeout(async () => {
                const { data } = await db.from('students')
                    .select('telegram_id, name, telegram_username')
                    .ilike('telegram_username', `%${query}%`)
                    .not('telegram_username', 'is', null)
                    .limit(8);

                if (!data || data.length === 0) {
                    box.innerHTML = '<div class="username-suggestion-item" style="color:#999; cursor:default;">Не найдено</div>';
                    box.style.display = 'block';
                    return;
                }

                box.innerHTML = '';
                data.forEach(s => {
                    const item = document.createElement('div');
                    item.className = 'username-suggestion-item';
                    item.innerHTML = `<b>@${esc(s.telegram_username)}</b> — ${esc(s.name || '')}`;
                    item.onclick = () => selectMockStudent(s.telegram_id, s.telegram_username);
                    box.appendChild(item);
                });
                box.style.display = 'block';
            }, 250);
        }

        function selectMockStudent(telegramId, username) {
            selectedMockStudentId = telegramId;
            document.getElementById('mock-username-input').value = username;
            document.getElementById('mock-username-suggestions').style.display = 'none';
            loadMockTrajectory(telegramId);
        }

        // Траектория пробников выбранного ученика (U05B) — единственный источник —
        // get_mock_exam_trajectory (U05A, только weekly_mock_exams); avg/range/trend уже
        // посчитаны сервером, здесь их не пересчитываем. Никакой life-истории — эта RPC её и не
        // возвращает (SPEC_STAGE4 §9: teacher видит каталог + траекторию, без life quests).
        async function loadMockTrajectory(studentId) {
            const container = document.getElementById('mock-trajectory-container');
            container.innerHTML = '<div style="text-align:center; padding:10px; color:#999; font-size:12px;">Загрузка траектории...</div>';
            try {
                const { data, error } = await db.rpc('get_mock_exam_trajectory', { p_student_id: studentId });
                if (error) throw error;
                renderMockTrajectory(container, data);
            } catch (e) {
                container.innerHTML = '<div style="text-align:center; padding:10px; color:#dc3545; font-size:12px;">Не удалось загрузить траекторию</div>';
            }
        }

        // Компактная inline-SVG «искра» + текстовая сводка — тот же приём, что в student-progress.js
        // (index.html), но минимальный и независимый: teacher.html не подключает student-скрипты.
        function renderMockTrajectory(container, trajectory) {
            if (!trajectory || !trajectory.count) {
                container.innerHTML = '<div style="text-align:center; padding:10px; color:#999; font-size:12px;">Пока нет результатов пробников</div>';
                return;
            }

            const points = trajectory.points || [];
            const W = 260, H = 70, padL = 24, padR = 8, padT = 6, padB = 6;
            const plotW = W - padL - padR, plotH = H - padT - padB;
            const scores = points.map(p => Number(p.score) || 0);
            const minScore = Math.min(40, Math.floor(Math.min(...scores) / 10) * 10);
            const maxScore = Math.max(minScore + 20, Math.ceil(Math.max(...scores) / 10) * 10);
            const xFor = (i) => points.length > 1 ? padL + (plotW * i / (points.length - 1)) : padL + plotW / 2;
            const yFor = (v) => padT + plotH - (plotH * (v - minScore) / (maxScore - minScore));
            const linePoints = points.map((p, i) => `${xFor(i)},${yFor(Number(p.score) || 0)}`).join(' ');
            const dots = points.map((p, i) => `<circle cx="${xFor(i)}" cy="${yFor(Number(p.score) || 0)}" r="3" fill="#2481cc"/>`).join('');

            const trendLabels = { up: 'растёт 📈', flat: 'стабильно ➖', down: 'снижается 📉' };
            const parts = [`Последний результат: ${trajectory.last_score}`];
            if (trajectory.delta_last !== null && trajectory.delta_last !== undefined) {
                const sign = trajectory.delta_last > 0 ? '+' : '';
                parts.push(`(${sign}${trajectory.delta_last})`);
            }
            if (trajectory.avg_last_3 !== null && trajectory.avg_last_3 !== undefined) {
                parts.push(`· среднее по 3: ${trajectory.avg_last_3} (${trajectory.min_last_3}–${trajectory.max_last_3})`);
            }
            if (trajectory.trend) parts.push(`· ${trendLabels[trajectory.trend] || trajectory.trend}`);

            container.innerHTML = `
                <svg viewBox="0 0 ${W} ${H}" style="width:100%; max-width:260px; height:auto; display:block; margin-top:10px;">
                    <polyline points="${linePoints}" fill="none" stroke="#2481cc" stroke-width="1.5" opacity="0.5"/>
                    ${dots}
                </svg>
                <div style="font-size:12px; color:#666; margin-top:4px;">${esc(parts.join(' '))}</div>
                <div style="font-size:10px; color:#999; margin-top:2px;">Диапазон последних пробников — не гарантия балла ЕГЭ.</div>
            `;
        }

        // Запись результата пробника — только через RPC record_weekly_mock_exam (P02A):
        // бублики/очки сезона считает сервер, клиент их не начисляет (P02B, "не начисляют валюты").
        async function submitMockExam() {
            const btn = document.getElementById('btn-submit-mock');
            if (btn.disabled) return;

            if (!selectedMockStudentId) return alert('Выберите ученика из подсказок!');

            const weekStart = document.getElementById('mock-week').value;
            if (!weekStart) return alert('Выберите неделю!');
            if (!isMonday(weekStart)) return alert('Неделя начинается только с понедельника — выберите понедельник.');

            const scoreRaw = document.getElementById('mock-score').value;
            const score = Number(scoreRaw);
            if (scoreRaw.trim() === '' || !Number.isInteger(score) || score < 0 || score > 100) {
                return alert('Результат должен быть целым числом от 0 до 100.');
            }

            // Синхронная защита от двойного клика ДО любого await (урок W05/W06).
            btn.disabled = true;
            try {
                // Уже есть результат на эту неделю — подтверждение перед заменой ("может
                // исправить его с подтверждением", P02B). Отсутствие строки или совпадающий
                // score подтверждения не требуют.
                const { data: existing, error: existingError } = await db.from('weekly_mock_exams')
                    .select('score')
                    .eq('student_id', selectedMockStudentId)
                    .eq('week_start', weekStart)
                    .maybeSingle();
                if (existingError) throw existingError;

                if (existing && existing.score !== score) {
                    if (!confirm(`На неделю ${weekStart} уже записан результат ${existing.score}. Заменить на ${score}?`)) {
                        return;
                    }
                }

                const { data, error } = await db.rpc('record_weekly_mock_exam_self', {
                    p_student_id: selectedMockStudentId,
                    p_week_start: weekStart,
                    p_score: score
                });
                if (error) throw error;

                let msg = `Результат ${score} за неделю ${weekStart} сохранён.`;
                if (data.base_awarded) msg += '\n+30 🥯 за пробник';
                if (data.record_awarded) msg += '\n+50 🥯 личный рекорд!';
                alert(msg);

                // Траектория сразу отражает исправление (U05B) — до сброса выбранного ученика.
                await loadMockTrajectory(selectedMockStudentId);

                document.getElementById('mock-username-input').value = '';
                selectedMockStudentId = null;
                document.getElementById('mock-score').value = '';
            } catch(e) { alert('Ошибка: ' + e.message); }
            finally { btn.disabled = false; }
        }

