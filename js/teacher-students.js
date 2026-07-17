// teacher-students.js — ученики, закрытие сезона, индивидуальные задания, пробники (R02)
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
                const { data, error } = await db.rpc('preview_league_close');
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
        // топ-3 (100/60/30), лиговые переходы и Корона, обнуление очков, открытие следующего
        // сезона. Клиент не считает места/переходы — только вызывает эту одну RPC. Сезон,
        // открытый сегодня, RPC закрыть не даст. Кнопка блокируется синхронно до подтверждения
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
                    alert('Нет открытого сезона — он появится, когда кто-то откроет лидерборд.');
                    return;
                }
                const season = seasons[0];
                const startText = new Date(season.start_date).toLocaleDateString('ru-RU');
                if (!confirm(`Закрыть сезон №${season.id} (идёт с ${startText})?\n\nИтоги уйдут в архив, топ-3 получат 100/60/30 бубликов, лиговые переходы и Корона будут посчитаны сервером, очки всех учеников обнулятся. Действие необратимо.`)) return;

                const { data, error: rpcError } = await db.rpc('close_season');
                if (rpcError) throw rpcError;
                alert(`Сезон №${data.season_id} закрыт!\nУчеников в архиве: ${data.archived}, наград топ-3 выдано: ${data.awarded}.\nНовый сезон открыт.`);
                document.getElementById('season-preview').innerHTML = '';
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
                await db.from('assignments').insert([{
                    student_id: selectedIndivStudentId,
                    type: 'individual',
                    title,
                    content_url: url,
                    teacher_comment: comment,
                    activation_status: 'active',
                    status: 'assigned',
                    task_count: taskCount
                }]);
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

                const { data, error } = await db.rpc('record_weekly_mock_exam', {
                    p_student_id: selectedMockStudentId,
                    p_week_start: weekStart,
                    p_score: score
                });
                if (error) throw error;

                let msg = `Результат ${score} за неделю ${weekStart} сохранён.`;
                if (data.base_awarded) msg += '\n+20 🥯 за пробник';
                if (data.record_awarded) msg += '\n+30 🥯 личный рекорд!';
                alert(msg);

                document.getElementById('mock-username-input').value = '';
                selectedMockStudentId = null;
                document.getElementById('mock-score').value = '';
            } catch(e) { alert('Ошибка: ' + e.message); }
            finally { btn.disabled = false; }
        }

