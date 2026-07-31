// teacher-students.js — ученики, сезоны, индивидуальные задания, пробники (R02)

        // --- ПЛАНИРОВАНИЕ СЕЗОНОВ V2 (миграции 057–058) ---
        // Проектный часовой пояс — Europe/Moscow (МСК = UTC+3 круглый год, как и в
        // moscowDateTimeToInstant ученического приложения). Учитель вводит время в МСК, на
        // сервер уходит явный timestamptz со смещением +03:00 — часовой пояс устройства и UTC
        // здесь не участвуют вообще. Обратно значения печатаются тоже в МСК.
        const MSK_OFFSET = '+03:00';

        // 'YYYY-MM-DDTHH:mm' из <input type="datetime-local"> → ISO с московским смещением.
        function mskLocalToIso(value) {
            if (!value) return null;
            const m = String(value).match(/^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})/);
            if (!m) return null;
            return `${m[1]}-${m[2]}-${m[3]}T${m[4]}:${m[5]}:00${MSK_OFFSET}`;
        }

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
            catalog_only: { text: 'Только каталог', className: 'catalog' },
            draft:        { text: 'Черновик', className: 'draft' },
            scheduled:    { text: 'Запланирован', className: 'scheduled' },
            active:       { text: 'Текущий', className: 'active' },
            closed:       { text: 'Закрыт', className: 'closed' },
            archived:     { text: 'Архив', className: 'archived' }
        };

        const SEASON_ERROR_TEXT = {
            title_required: 'Укажите название сезона (до 60 символов).',
            description_required: 'Добавьте описание сезона (до 500 символов).',
            window_required: 'Укажите начало и окончание.',
            window_order: 'Окончание должно быть позже начала.',
            start_in_past: 'Опубликовать сезон с началом в прошлом нельзя.',
            season_overlap: 'Даты пересекаются с опубликованным сезоном.',
            season_gap: 'Между опубликованными сезонами не должно быть разрыва.',
            four_items_required: 'В периоде должно быть ровно четыре предмета.',
            invalid_item_payload: 'Один из предметов содержит недопустимые данные.',
            season_not_editable: 'Активный или завершённый сезон редактировать нельзя.',
            catalog_only_period: 'Этот период остаётся только в каталоге и никогда не запускается.',
            markup_not_allowed: 'HTML-разметка в текстах запрещена.',
            forbidden: 'Недостаточно прав.'
        };

        function seasonErrorText(e) {
            const raw = (e && (e.message || e.code)) ? String(e.message || e.code) : '';
            const key = Object.keys(SEASON_ERROR_TEXT).find(k => raw.includes(k));
            return key ? SEASON_ERROR_TEXT[key] : (raw || 'Не удалось сохранить сезон');
        }

        function showSeasonFormError(text) {
            const box = document.getElementById('season-form-error');
            if (!box) return;
            box.textContent = text || '';
            box.style.display = text ? 'block' : 'none';
        }

        let seasonV2Rows = [];
        let seasonV2Editing = null;

        function toMskInput(iso) {
            if (!iso) return '';
            const parts = new Intl.DateTimeFormat('sv-SE', {
                timeZone: 'Europe/Moscow',
                year: 'numeric', month: '2-digit', day: '2-digit',
                hour: '2-digit', minute: '2-digit', hour12: false
            }).formatToParts(new Date(iso));
            const value = Object.fromEntries(parts.map((part) => [part.type, part.value]));
            return `${value.year}-${value.month}-${value.day}T${value.hour}:${value.minute}`;
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
                    title.textContent = `${String(row.sequence_no).padStart(2, '0')} · ${row.title}`;
                    const badge = document.createElement('span');
                    badge.className = `season-v2-status season-v2-status--${meta.className}`;
                    badge.textContent = meta.text;
                    head.append(title, badge);

                    const dates = document.createElement('div');
                    dates.className = 'card-meta';
                    dates.textContent = `${formatMsk(row.starts_at)} — ${formatMsk(row.ends_at)}`;
                    const items = document.createElement('div');
                    items.className = 'season-v2-rarity-line';
                    items.textContent = (row.items || []).map((item) => `${item.slot}: ${item.rarity}`).join(' · ');
                    card.append(head, dates, items);

                    const actions = document.createElement('div');
                    actions.className = 'season-v2-card-actions';
                    const preview = document.createElement('button');
                    preview.className = 'btn-secondary';
                    preview.type = 'button';
                    preview.textContent = 'Предпросмотр';
                    preview.onclick = () => openSeasonV2Editor(row.preset_code, true);
                    actions.appendChild(preview);
                    if (row.status === 'draft' || row.status === 'scheduled') {
                        const edit = document.createElement('button');
                        edit.className = 'btn-secondary';
                        edit.type = 'button';
                        edit.textContent = 'Редактировать';
                        edit.onclick = () => openSeasonV2Editor(row.preset_code, false);
                        actions.appendChild(edit);
                    }
                    card.appendChild(actions);
                    box.appendChild(card);
                });
            } catch (e) {
                box.textContent = 'Не удалось загрузить сезоны.';
                log('❌ Season V2: ' + (e.message || e));
            }
        }

        function openSeasonV2Editor(presetCode, previewOnly) {
            const row = seasonV2Rows.find((item) => item.preset_code === presetCode);
            if (!row) return;
            seasonV2Editing = structuredClone(row);
            const modal = document.getElementById('season-v2-modal');
            modal.classList.add('open');
            modal.setAttribute('aria-hidden', 'false');
            document.getElementById('season-v2-modal-title').textContent =
                `${String(row.sequence_no).padStart(2, '0')} · ${row.title}`;
            document.getElementById('season-v2-title').value = row.title;
            document.getElementById('season-v2-description').value = row.description;
            document.getElementById('season-v2-starts-at').value = toMskInput(row.starts_at);
            document.getElementById('season-v2-ends-at').value = toMskInput(row.ends_at);
            document.getElementById('season-v2-title').oninput = (event) => {
                seasonV2Editing.title = event.target.value;
                seasonPreviewCard(seasonV2Editing, document.getElementById('season-v2-live-preview'));
            };
            document.getElementById('season-v2-editor-fields').hidden = previewOnly;
            document.getElementById('season-v2-save-draft').hidden = previewOnly;
            document.getElementById('season-v2-schedule').hidden = previewOnly || row.catalog_only;
            showSeasonFormError('');
            renderSeasonV2Items(previewOnly);
            seasonPreviewCard(seasonV2Editing, document.getElementById('season-v2-live-preview'));
        }

        function closeSeasonV2Editor() {
            const modal = document.getElementById('season-v2-modal');
            modal.classList.remove('open');
            modal.setAttribute('aria-hidden', 'true');
            seasonV2Editing = null;
        }

        document.addEventListener('keydown', (event) => {
            if (event.key === 'Escape' && document.getElementById('season-v2-modal')?.classList.contains('open')) {
                closeSeasonV2Editor();
            }
        });

        document.addEventListener('click', (event) => {
            if (event.target?.id === 'season-v2-modal') closeSeasonV2Editor();
        });

        function renderSeasonV2Items(previewOnly) {
            const list = document.getElementById('season-v2-items');
            list.replaceChildren();
            (seasonV2Editing.items || []).forEach((item, index) => {
                const card = document.createElement('div');
                card.className = `season-v2-item-editor rarity-${item.rarity}`;
                const label = document.createElement('strong');
                label.textContent = `${item.slot} · ${item.rarity}`;
                card.appendChild(label);
                if (!previewOnly) {
                    const name = document.createElement('input');
                    name.value = item.name;
                    name.maxLength = 80;
                    name.setAttribute('aria-label', `Название ${item.slot}`);
                    const description = document.createElement('textarea');
                    description.value = item.description;
                    description.maxLength = 500;
                    description.setAttribute('aria-label', `Описание ${item.slot}`);
                    const price = document.createElement('input');
                    price.type = 'number';
                    price.min = '1';
                    price.value = item.price;
                    price.setAttribute('aria-label', `Цена ${item.slot}`);
                    const visual = document.createElement('select');
                    visual.setAttribute('aria-label', `Визуал ${item.slot}`);
                    const options = [...new Set(seasonV2Rows.flatMap((row) =>
                        (row.items || []).filter((candidate) => candidate.slot === item.slot)
                            .map((candidate) => candidate.render_payload)))];
                    options.forEach((payload) => {
                        const option = document.createElement('option');
                        option.value = payload;
                        option.textContent = payload.replace(/^(avatar|frame|scene|title)_v4_/, '');
                        option.selected = payload === item.render_payload;
                        visual.appendChild(option);
                    });
                    const update = () => {
                        Object.assign(seasonV2Editing.items[index], {
                            name: name.value,
                            description: description.value,
                            price: Number(price.value),
                            render_payload: visual.value
                        });
                        seasonPreviewCard(seasonV2Editing, document.getElementById('season-v2-live-preview'));
                    };
                    [name, description, price, visual].forEach((field) => field.addEventListener('input', update));
                    card.append(name, description, price, visual);
                } else {
                    const name = document.createElement('span');
                    name.textContent = item.name;
                    card.appendChild(name);
                }
                list.appendChild(card);
            });
        }

        async function saveSeasonV2(schedule) {
            if (!seasonV2Editing) return;
            const title = document.getElementById('season-v2-title').value.trim();
            const description = document.getElementById('season-v2-description').value.trim();
            const startsAt = mskLocalToIso(document.getElementById('season-v2-starts-at').value);
            const endsAt = mskLocalToIso(document.getElementById('season-v2-ends-at').value);
            const buttons = [
                document.getElementById('season-v2-save-draft'),
                document.getElementById('season-v2-schedule')
            ];
            buttons.forEach((button) => { button.disabled = true; });
            try {
                const items = seasonV2Editing.items.map((item) => ({
                    item_code: item.item_code,
                    slot: item.slot,
                    name: item.name.trim(),
                    description: item.description.trim(),
                    price: Number(item.price),
                    render_payload: item.render_payload
                }));
                const { error } = await db.rpc('admin_save_season_v2_self', {
                    p_preset_code: seasonV2Editing.preset_code,
                    p_title: title,
                    p_description: description,
                    p_starts_at: startsAt,
                    p_ends_at: endsAt,
                    p_items: items,
                    p_schedule: !!schedule
                });
                if (error) throw error;
                closeSeasonV2Editor();
                await loadSeasons();
            } catch (e) {
                showSeasonFormError(seasonErrorText(e));
            } finally {
                buttons.forEach((button) => { button.disabled = false; });
            }
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

        // Закрытие сезона (G8, лиги — L01/L02): вся операция — одна транзакция RPC close_season
        // (миграция 006, расширена close_league_season в 019): архив мест всех учеников, награды
        // топ-3 (100/60/30), лиговые переходы и Корона, обнуление очков. Следующий период
        // открывается только если его плановое время уже наступило. Клиент не считает места/
        // переходы — только вызывает эту одну RPC. Кнопка блокируется синхронно до подтверждения
        // диалогом (confirm блокирует поток) и до ответа RPC — двойной клик не создаёт вторую
        // параллельную цепочку запросов.
        async function closeSeason() {
            const btn = document.getElementById('btn-close-season');
            if (btn.disabled) return; // защита от двойного клика
            btn.disabled = true;
            try {
                const { data: seasons, error } = await db.from('seasons').select('id, start_date').is('end_date', null).order('id', { ascending: false }).limit(1);
                if (error) throw error;
                if (!seasons || !seasons.length) {
                    alert('Сейчас нет активного сезона. Следующий включится автоматически по расписанию.');
                    return;
                }
                const season = seasons[0];
                const startText = new Date(season.start_date).toLocaleDateString('ru-RU');
                if (!confirm(`Закрыть сезон №${season.id} (идёт с ${startText})?\n\nИтоги уйдут в архив, топ-3 получат 100/60/30 бубликов, лиговые переходы и Корона будут посчитаны сервером, очки всех учеников обнулятся. Общий топ за все сезоны при этом не уменьшится.\n\nБудущий период раньше его плановой даты не включится. Действие необратимо.`)) return;

                const { data, error: rpcError } = await db.rpc('close_season_self');
                if (rpcError) throw rpcError;
                if (data && data.already_completed) {
                    // Сезон успел завершиться по расписанию (ends_at) между чтением и вызовом.
                    alert('Сезон уже был завершён — повторное закрытие ничего не изменило.');
                } else {
                    const nextText = data.next_season_id
                        ? `Текущим стал сезон №${data.next_season_id}.`
                        : 'Следующий сезон включится автоматически по расписанию.';
                    alert(`Сезон №${data.season_id} закрыт!\nУчеников в архиве: ${data.archived}, наград топ-3 выдано: ${data.awarded}.\n${nextText}`);
                }
                document.getElementById('season-preview').innerHTML = '';
                await loadSeasons();
            } catch (e) {
                alert('Ошибка: ' + e.message);
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
                if (data.base_awarded) msg += '\n+20 🥯 за пробник';
                if (data.record_awarded) msg += '\n+30 🥯 личный рекорд!';
                alert(msg);

                // Траектория сразу отражает исправление (U05B) — до сброса выбранного ученика.
                await loadMockTrajectory(selectedMockStudentId);

                document.getElementById('mock-username-input').value = '';
                selectedMockStudentId = null;
                document.getElementById('mock-score').value = '';
            } catch(e) { alert('Ошибка: ' + e.message); }
            finally { btn.disabled = false; }
        }

