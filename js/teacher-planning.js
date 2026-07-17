// teacher-planning.js — планирование недель, публикация, черновик/текущая/архив (R02)
        // "Все ученики" и конкретные группы взаимоисключающие
        function onWeekGroupAllChange() {
            if (document.getElementById('week-group-all').checked) {
                document.querySelectorAll('.week-group-checkbox').forEach(cb => cb.checked = false);
            }
        }

        function onWeekGroupPick() {
            const anyChecked = [...document.querySelectorAll('.week-group-checkbox')].some(cb => cb.checked);
            document.getElementById('week-group-all').checked = !anyChecked;
        }

        function getSelectedWeekGroups() {
            return [...document.querySelectorAll('.week-group-checkbox:checked')].map(cb => cb.value);
        }

        function clearWeekForm() {
            for (let i = 0; i < 7; i++) {
                document.getElementById(`day-title-${i}`).value = '';
                document.getElementById(`day-url-${i}`).value = '';
                document.getElementById(`day-comment-${i}`).value = '';
                document.getElementById(`day-count-${i}`).value = '';
            }
            document.getElementById('weekly-title').value = '';
            document.getElementById('weekly-url').value = '';
            document.getElementById('weekly-comment').value = '';
            document.getElementById('weekly-count').value = '';
            document.getElementById('week-group-all').checked = true;
            document.querySelectorAll('.week-group-checkbox').forEach(cb => cb.checked = false);
        }

        // Публикация недели идёт только через publish_weekly_plan (W01): RPC сам создаёт план,
        // раскладывает его по ученикам одной транзакцией и не даёт дублей при повторе.
        // Несколько выбранных групп — отдельный план на каждую группу (SPEC §4.1), а не одна
        // строка «Группа A, Группа B».
        async function scheduleWeek() {
            const weekStart = document.getElementById('activation-date').value;
            if (!weekStart) return alert('Выберите дату активации!');
            if (!isMonday(weekStart)) return alert('Неделя начинается только с понедельника — выберите понедельник.');

            const items = [];
            try {
                for (let i = 0; i < 7; i++) {
                    const title = document.getElementById(`day-title-${i}`).value.trim();
                    const url = document.getElementById(`day-url-${i}`).value.trim();
                    const comment = document.getElementById(`day-comment-${i}`).value.trim();

                    if (title && url) {
                        items.push({
                            type: 'daily', day_of_week: i + 1, title, content_url: url, teacher_comment: comment,
                            task_count: parseTaskCount(document.getElementById(`day-count-${i}`).value, DAY_NAMES[i + 1])
                        });
                    }
                }

                const weeklyTitle = document.getElementById('weekly-title').value.trim();
                const weeklyUrl = document.getElementById('weekly-url').value.trim();
                const weeklyComment = document.getElementById('weekly-comment').value.trim();

                if (weeklyTitle && weeklyUrl) {
                    items.push({
                        type: 'weekly', title: weeklyTitle, content_url: weeklyUrl, teacher_comment: weeklyComment,
                        task_count: parseTaskCount(document.getElementById('weekly-count').value, 'Еженедельное задание')
                    });
                }
            } catch(e) { return alert(e.message); }

            if (!items.length) return alert('Заполните хотя бы одно задание!');

            const selectedGroups = getSelectedWeekGroups();
            const audiences = selectedGroups.length
                ? selectedGroups.map(g => ({ audience_type: 'group', group_name: g }))
                : [{ audience_type: 'all', group_name: null }];

            // Блокируем кнопку на время сохранения — двойной клик отправил бы неделю дважды
            const btn = document.getElementById('btn-schedule-week');
            btn.disabled = true;
            try {
                const published = [];
                for (const aud of audiences) {
                    const { data, error } = await db.rpc('publish_weekly_plan', {
                        p_week_start: weekStart,
                        p_audience_type: aud.audience_type,
                        p_group_name: aud.group_name,
                        p_items: items
                    });
                    // Каждая группа публикуется своей транзакцией: показываем, что уже прошло, и
                    // НЕ очищаем форму — учитель исправляет ошибку и повторяет, повтор не дублирует.
                    if (error) {
                        const done = published.length ? `Опубликовано: ${published.join('; ')}.\n\n` : '';
                        return alert(`${done}Ошибка публикации (${aud.group_name || 'Все ученики'}): ${error.message}`);
                    }
                    published.push(`${aud.group_name || 'Все ученики'} — ${data.students_synced} уч.`);
                }

                alert(`Неделя от ${weekStart} опубликована.\n${published.join('\n')}`);
                clearWeekForm();
            } catch(e) { alert('Ошибка: ' + e.message); }
            finally { btn.disabled = false; }
        }

        // --- ПОДВКЛАДКИ ВНУТРИ "ПЛАНИРОВАНИЕ" ---
        let currentPlanSubTab = 'create';
        let currentArchiveSubTab = 'daily';
        let currentIndividualArchiveView = 'active';

        function switchPlanSubTab(view, el) {
            currentPlanSubTab = view;
            document.querySelectorAll('#plan-sub-tabs .sub-tab').forEach(b => b.classList.remove('active'));
            el.classList.add('active');
            document.querySelectorAll('.plan-view').forEach(v => v.classList.remove('active'));
            document.getElementById('plan-' + view).classList.add('active');

            if (view === 'draft') loadDrafts();
            else if (view === 'current') loadCurrentWeek();
            else if (view === 'archive') loadArchiveWeeks('daily', 'archive-daily');
        }

        function switchArchiveSubTab(view, el) {
            currentArchiveSubTab = view;
            document.querySelectorAll('#archive-sub-tabs .sub-tab').forEach(b => b.classList.remove('active'));
            el.classList.add('active');
            document.querySelectorAll('.archive-view').forEach(v => v.classList.remove('active'));
            document.getElementById('archive-' + view).classList.add('active');

            if (view === 'daily') loadArchiveWeeks('daily', 'archive-daily');
            else if (view === 'weekly') loadArchiveWeeks('weekly', 'archive-weekly');
            else if (view === 'individual') loadArchiveIndividual(currentIndividualArchiveView);
        }

        function switchIndividualArchiveView(view, el) {
            currentIndividualArchiveView = view;
            document.querySelectorAll('#archive-individual-sub-tabs .sub-tab').forEach(b => b.classList.remove('active'));
            el.classList.add('active');
            loadArchiveIndividual(view);
        }

        const PLAN_SELECT = 'id, week_start, audience_type, group_name, ' +
            'weekly_plan_items(id, type, day_of_week, title, content_url, teacher_comment, task_count, active)';
        const LEGACY_WEEK_SELECT = 'id, week_label, type, day_of_week, title, content_url, teacher_comment, scheduled_date, assigned_group';

        // Размер аудитории плана для карточки — один компактный запрос к students вместо подсчёта
        // персональных строк (их могут быть тысячи). Точное число получателей каждой публикации
        // возвращает сам RPC (students_synced).
        async function loadAudienceSizes() {
            const { data, error } = await db.from('students').select('group_name');
            if (error) return null;
            const sizes = { all: data.length, byGroup: {} };
            data.forEach(s => {
                if (s.group_name) sizes.byGroup[s.group_name] = (sizes.byGroup[s.group_name] || 0) + 1;
            });
            return sizes;
        }

        // Legacy-недели — строки assignments, созданные до перехода на планы (plan_item_id = null).
        // Показываются только для просмотра; переносить их в weekly_plans автоматически нельзя,
        // управление ими появится при cutover (W09).
        function legacyWeekQuery() {
            return db.from('assignments')
                .select(LEGACY_WEEK_SELECT)
                .in('type', ['daily', 'weekly'])
                .is('plan_item_id', null);
        }

        // --- ЧЕРНОВИК: недели, которые ещё не начались ---
        async function loadDrafts() {
            const container = document.getElementById('draft-list');
            container.innerHTML = '<div style="text-align:center; padding:30px; color:#999;">Загрузка...</div>';

            const today = getTodayMSK();
            const [plans, legacy, sizes] = await Promise.all([
                db.from('weekly_plans').select(PLAN_SELECT)
                    .eq('status', 'published')
                    .gt('week_start', today)
                    .order('week_start', { ascending: true })
                    .order('audience_type', { ascending: true })  // 'all' раньше 'group'
                    .order('group_name', { ascending: true }),
                legacyWeekQuery().gt('week_label', today).order('week_label', { ascending: true }),
                loadAudienceSizes()
            ]);

            renderWeekViews(container, plans, legacy, sizes, {
                today, deletable: true, emptyText: 'Нет запланированных недель'
            });
        }

        // --- ТЕКУЩАЯ НЕДЕЛЯ: сегодня попадает в её пн–вс, ещё не наступившие дни редактируемы ---
        async function loadCurrentWeek() {
            const container = document.getElementById('current-week-list');
            container.innerHTML = '<div style="text-align:center; padding:30px; color:#999;">Загрузка...</div>';

            const today = getTodayMSK();
            // Неделя ещё идёт, пока с её начала не прошло 6 дней — тот же критерий, что у архива,
            // но фильтром в запросе, а не в клиенте (T7).
            const weekFloor = addDaysToDate(today, -6);
            const [plans, legacy, sizes] = await Promise.all([
                db.from('weekly_plans').select(PLAN_SELECT)
                    .eq('status', 'published')
                    .lte('week_start', today)
                    .gte('week_start', weekFloor)
                    .order('week_start', { ascending: true })
                    .order('audience_type', { ascending: true })  // 'all' раньше 'group'
                    .order('group_name', { ascending: true }),
                legacyWeekQuery().lte('week_label', today).gte('week_label', weekFloor)
                    .order('week_label', { ascending: true }),
                loadAudienceSizes()
            ]);

            renderWeekViews(container, plans, legacy, sizes, { today, emptyText: 'Сейчас нет текущей недели' });
        }

        // --- АРХИВ: недели, которые полностью закончились ---
        async function loadArchiveWeeks(type, containerId) {
            const container = document.getElementById(containerId);
            container.innerHTML = '<div style="text-align:center; padding:30px; color:#999;">Загрузка...</div>';

            const today = getTodayMSK();
            // Фильтр завершённых недель перенесён из клиента в запрос (T7): неделя архивна, когда с даты
            // активации прошло 6 дней. Это тот же критерий, что и в клиентском фильтре ниже
            // (addDaysToDate(wl, 6) < today  ⟺  wl < addDaysToDate(today, -6)), но теперь Supabase не тянет
            // текущие/будущие недели — на архивных данных ответ не упирается в молчаливый предел 1000 строк.
            const archiveCutoff = addDaysToDate(today, -6);
            const { data, error } = await db.from('assignments')
                .select('id, week_label, type, day_of_week, title, content_url, teacher_comment, scheduled_date, assigned_group')
                .eq('type', type)
                .lt('week_label', archiveCutoff)
                .order('week_label', { ascending: false });

            if (error) { container.innerHTML = `<div style="color:red; padding:20px;">${error.message}</div>`; return; }

            const archivedLabels = new Set(
                [...new Set((data || []).map(a => a.week_label))].filter(wl => addDaysToDate(wl, 6) < today)
            );
            const filtered = (data || []).filter(a => archivedLabels.has(a.week_label));
            // Архив показывает фактические строки завершённых недель — и legacy, и материализованные
            // из планов: обе группируются по week_label + assigned_group одинаково.
            container.innerHTML = assignmentWeeksHtml(filtered, {})
                || '<div style="text-align:center; padding:40px; color:#999;">Архив пуст</div>';
        }

        // Разметка одной карточки слота — общая для планов (черновик/текущая) и для строк
        // assignments (архив, legacy-недели без плана).
        function weekSlotCardHtml(opts) {
            return `
                <div class="submission-card" style="cursor:default;">
                    <div class="card-header">
                        <span class="student-name">${opts.label}</span>
                        <span style="font-size:12px; color:#999;">${esc(opts.countText)}</span>
                    </div>
                    <div class="card-meta">${esc(opts.title || 'Без названия')}</div>
                    ${opts.url ? `<a href="${normalizeUrl(opts.url)}" target="_blank" class="card-link">🔗 Ссылка</a>` : ''}
                    ${opts.buttons || ''}
                </div>
            `;
        }

        // Разметка блока недели: заголовок, строка аудитории и карточки слотов.
        function weekBlockHtml(opts) {
            return `<div style="margin-bottom:20px;">
                <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:2px;">
                    <h4 style="margin:0;">Неделя от ${esc(opts.weekLabel)}</h4>
                    ${opts.headerButton || ''}
                </div>
                <div style="font-size:13px; color:#666; margin-bottom:10px;">${opts.groupLine}</div>
                ${opts.itemsHtml}
            </div>`;
        }

        function planSlotOrder(item) {
            return item.type === 'weekly' ? 8 : item.day_of_week;
        }

        // Склонение слова «задача» по числу (1 задача / 2 задачи / 5 задач) — только в этом файле,
        // как pluralShields/pluralDays в index.html (см. шапку shared.js).
        function pluralTasks(n) {
            const abs = Math.abs(n);
            const mod10 = abs % 10, mod100 = abs % 100;
            if (mod10 === 1 && mod100 !== 11) return 'задача';
            if (mod10 >= 2 && mod10 <= 4 && (mod100 < 10 || mod100 >= 20)) return 'задачи';
            return 'задач';
        }

        // Черновик и текущая неделя показывают ПЛАН — одну карточку на аудиторию (W01), а не тысячи
        // персональных строк учеников. Правка и отмена идут только через серверные RPC.
        let planItemRegistry = [];
        let planWeekRegistry = [];

        function planWeeksHtml(plans, sizes, opts) {
            if (!plans || plans.length === 0) return '';

            return plans.map(plan => {
                const groupLabel = plan.group_name || 'Все ученики';
                const items = (plan.weekly_plan_items || [])
                    .filter(i => i.active)
                    .sort((a, b) => planSlotOrder(a) - planSlotOrder(b));

                const itemsHtml = items.map(item => {
                    const slotDate = item.type === 'weekly'
                        ? plan.week_start
                        : addDaysToDate(plan.week_start, item.day_of_week - 1);
                    // Наступивший день заморожен (SPEC §5.5) — RPC отвергнет правку, кнопок не показываем.
                    const canEdit = item.type === 'weekly' || slotDate > opts.today;

                    let buttons = '';
                    if (canEdit) {
                        const idx = planItemRegistry.length;
                        planItemRegistry.push({
                            planId: plan.id, weekStart: plan.week_start, audienceType: plan.audience_type,
                            groupName: plan.group_name, type: item.type, dayOfWeek: item.day_of_week || null,
                            title: item.title, url: item.content_url, comment: item.teacher_comment,
                            taskCount: item.task_count
                        });
                        buttons = `<button class="btn-secondary" style="margin-top:8px;" onclick="openEditGroup(${idx})">✏️ Редактировать</button>`;
                        if (opts.deletable) {
                            buttons += `<button class="btn-danger" style="margin-top:8px; padding:8px;" onclick="deletePlanItem(${idx}, this)">🗑️ Удалить</button>`;
                        }
                    }

                    return weekSlotCardHtml({
                        label: item.type === 'weekly' ? '🔥 Еженедельное' : `📅 ${DAY_NAMES[item.day_of_week]}`,
                        countText: `${item.task_count} ${pluralTasks(item.task_count)}`,
                        title: item.title,
                        url: item.content_url,
                        buttons
                    });
                }).join('') || '<div style="color:#999; font-size:13px; padding:5px 0 10px;">В плане не осталось заданий.</div>';

                let headerButton = '';
                if (opts.deletable) {
                    const wIdx = planWeekRegistry.length;
                    planWeekRegistry.push({ planId: plan.id, weekStart: plan.week_start, groupLabel });
                    headerButton = `<button class="btn-danger" style="width:auto; padding:6px 14px; font-size:12px; margin:0;" onclick="cancelPlanWeek(${wIdx}, this)">🗑️ Отменить неделю</button>`;
                }

                const size = plan.audience_type === 'all' ? sizes.all : (sizes.byGroup[plan.group_name] || 0);
                return weekBlockHtml({
                    weekLabel: plan.week_start,
                    groupLine: `👥 ${esc(groupLabel)} · ${size} уч.`,
                    headerButton,
                    itemsHtml
                });
            }).join('');
        }

        // Строки assignments, сгруппированные по неделе и снимку аудитории: контент одинаков для всех
        // учеников этой недели, поэтому слот показывается одной карточкой со счётчиком получателей.
        // Ключ недели — week_label + assigned_group: на одну дату активации могут существовать разные
        // недели для разных групп, и без учёта группы они сливались бы в одну.
        function assignmentWeeksHtml(rows, opts) {
            opts = opts || {};
            if (!rows || rows.length === 0) return '';

            const weeks = {};
            rows.forEach(r => {
                const wKey = r.week_label + '||' + (r.assigned_group || '');
                if (!weeks[wKey]) weeks[wKey] = { weekLabel: r.week_label, assignedGroup: r.assigned_group || null, items: {} };
                const key = r.type === 'daily' ? `daily-${r.day_of_week}` : 'weekly';
                if (!weeks[wKey].items[key]) weeks[wKey].items[key] = { ...r, count: 0 };
                weeks[wKey].items[key].count++;
            });

            return Object.keys(weeks).sort().map(wKey => {
                const week = weeks[wKey];
                const items = week.items;
                const itemKeys = Object.keys(items).sort((a, b) => {
                    if (a === 'weekly') return 1;
                    if (b === 'weekly') return -1;
                    return parseInt(a.split('-')[1]) - parseInt(b.split('-')[1]);
                });

                const itemsHtml = itemKeys.map(key => {
                    const item = items[key];
                    return weekSlotCardHtml({
                        label: key === 'weekly' ? '🔥 Еженедельное' : `📅 ${DAY_NAMES[item.day_of_week]}`,
                        countText: `${item.count} уч.`,
                        title: item.title,
                        url: item.content_url
                    });
                }).join('');

                const groupLabel = week.assignedGroup || 'Группа не указана';
                // Legacy-неделя (без weekly_plan) — только просмотр: редактировать, удалять и
                // переиздавать её нельзя, ученикам она продолжает работать как раньше.
                // Управление такими неделями появится при cutover (W09).
                const legacyMark = opts.legacy ? ' · без плана (старая неделя)' : '';
                return weekBlockHtml({
                    weekLabel: week.weekLabel,
                    groupLine: `👥 ${esc(groupLabel)}${legacyMark}`,
                    itemsHtml
                });
            }).join('');
        }

        // Собирает вкладку из плановых карточек и legacy-недель без плана. Если на ту же неделю и
        // аудиторию есть план, показывается только он — legacy-карточка не дублируется.
        function renderWeekViews(container, plans, legacy, sizes, opts) {
            const error = plans.error || legacy.error;
            if (error || !sizes) {
                container.innerHTML = `<div style="color:red; padding:20px;">${esc(error ? error.message : 'Не удалось загрузить учеников')}</div>`;
                return;
            }

            planItemRegistry = [];
            planWeekRegistry = [];

            const planKeys = new Set((plans.data || []).map(p => p.week_start + '||' + (p.group_name || 'Все ученики')));
            const legacyOnly = (legacy.data || []).filter(r => !planKeys.has(r.week_label + '||' + (r.assigned_group || '')));

            const html = planWeeksHtml(plans.data, sizes, opts) + assignmentWeeksHtml(legacyOnly, { legacy: true });
            container.innerHTML = html || `<div style="text-align:center; padding:40px; color:#999;">${opts.emptyText}</div>`;
        }

        let currentEditGroup = null;

        function openEditGroup(idx) {
            currentEditGroup = planItemRegistry[idx];
            document.getElementById('edit-group-title').value = currentEditGroup.title || '';
            document.getElementById('edit-group-url').value = currentEditGroup.url || '';
            document.getElementById('edit-group-count').value = currentEditGroup.taskCount != null ? currentEditGroup.taskCount : '';
            document.getElementById('edit-group-comment').value = currentEditGroup.comment || '';
            document.getElementById('edit-group-modal').classList.add('active');
        }

        function closeGroupEdit() {
            document.getElementById('edit-group-modal').classList.remove('active');
            currentEditGroup = null;
        }

        // publish_weekly_plan — upsert всего плана: слоты, не переданные в p_items, деактивируются.
        // Поэтому правка или удаление одного слота отправляет ВСЕ активные слоты плана, взятые
        // заново из БД: остальные приходят без изменений и попадают в идемпотентную ветку RPC.
        async function planItemsForPublish(planId) {
            const { data, error } = await db.from('weekly_plan_items')
                .select('type, day_of_week, title, content_url, teacher_comment, task_count')
                .eq('plan_id', planId)
                .eq('active', true);
            if (error) throw new Error(error.message);
            return data;
        }

        function isSameSlot(a, b) {
            return a.type === b.type && (a.day_of_week || null) === (b.day_of_week || null);
        }

        async function republishPlanWithout(g, extraItem) {
            const slot = { type: g.type, day_of_week: g.dayOfWeek || null };
            const items = (await planItemsForPublish(g.planId)).filter(i => !isSameSlot(i, slot));
            if (extraItem) items.push(extraItem);

            return db.rpc('publish_weekly_plan', {
                p_week_start: g.weekStart,
                p_audience_type: g.audienceType,
                p_group_name: g.groupName,
                p_items: items
            });
        }

        function reloadCurrentPlanView() {
            if (currentPlanSubTab === 'draft') loadDrafts();
            else if (currentPlanSubTab === 'current') loadCurrentWeek();
        }

        async function saveGroupEdit() {
            const g = currentEditGroup;
            if (!g) return;

            const title = document.getElementById('edit-group-title').value.trim();
            const url = document.getElementById('edit-group-url').value.trim();
            const comment = document.getElementById('edit-group-comment').value.trim();
            if (!title) return alert('Укажите название!');
            if (!url) return alert('Укажите ссылку!');

            let taskCount;
            try { taskCount = parseTaskCount(document.getElementById('edit-group-count').value, 'Задание'); }
            catch(e) { return alert(e.message); }

            const btn = document.getElementById('btn-save-group-edit');
            btn.disabled = true;
            try {
                const { error } = await republishPlanWithout(g, {
                    type: g.type, day_of_week: g.dayOfWeek || null, title,
                    content_url: url, teacher_comment: comment, task_count: taskCount
                });
                // Модалка остаётся открытой — введённая правка не теряется.
                if (error) return alert('Ошибка: ' + error.message);

                alert('Изменения сохранены. Начатые работы учеников не затронуты.');
                closeGroupEdit();
                reloadCurrentPlanView();
            } catch(e) { alert('Ошибка: ' + e.message); }
            finally { btn.disabled = false; }
        }

        // Убрать один слот из плана (только из Черновика — неделя ещё не началась)
        async function deletePlanItem(idx, btn) {
            const g = planItemRegistry[idx];
            if (!g) return;
            if (!confirm('Убрать это задание из плана недели? Начатые работы учеников сохранятся, неначатые будут сняты.')) return;

            btn.disabled = true;
            try {
                const { error } = await republishPlanWithout(g, null);
                if (error) return alert('Ошибка: ' + error.message);
                alert('Задание убрано из плана.');
                reloadCurrentPlanView();
            } catch(e) { alert('Ошибка: ' + e.message); }
            finally { btn.disabled = false; }
        }

        // Отмена недели целиком (только из Черновика). История не удаляется: план помечается
        // cancelled, у учеников снимаются лишь неначатые строки.
        async function cancelPlanWeek(idx, btn) {
            const w = planWeekRegistry[idx];
            if (!w) return;
            if (!confirm(`Отменить неделю от ${w.weekStart} (${w.groupLabel})? Начатые работы учеников сохранятся, неначатые будут сняты.`)) return;

            btn.disabled = true;
            try {
                const { error } = await db.rpc('cancel_weekly_plan', { p_plan_id: w.planId });
                if (error) return alert('Ошибка: ' + error.message);
                alert('Неделя отменена.');
                reloadCurrentPlanView();
            } catch(e) { alert('Ошибка: ' + e.message); }
            finally { btn.disabled = false; }
        }

        // --- АРХИВ ИНДИВИДУАЛЬНЫХ ЗАДАНИЙ ---
        async function loadArchiveIndividual(view) {
            const container = document.getElementById('archive-individual-list');
            container.innerHTML = '<div style="text-align:center; padding:30px; color:#999;">Загрузка...</div>';

            let query = db.from('assignments').select('*, students(name)').eq('type', 'individual').order('created_at', { ascending: false }).limit(200);
            query = view === 'active' ? query.eq('status', 'assigned') : query.in('status', ['submitted', 'checked']);

            const { data, error } = await query;
            if (error) { container.innerHTML = `<div style="color:red; padding:20px;">${error.message}</div>`; return; }

            if (!data.length) {
                container.innerHTML = `<div style="text-align:center; padding:40px; color:#999;">${view === 'active' ? 'Нет активных индивидуальных заданий' : 'Архив пуст'}</div>`;
                return;
            }

            container.innerHTML = data.map(a => `
                <div class="submission-card" style="cursor:default;">
                    <div class="card-header">
                        <span class="student-name">${esc(a.students?.name || 'Unknown')}</span>
                        <span class="badge badge-individual">Индивидуальное</span>
                    </div>
                    <div class="card-meta">${esc(a.title || 'Без названия')}${a.task_count != null ? ` • ${a.task_count} ${pluralTasks(a.task_count)}` : ''} • ${new Date(a.created_at).toLocaleString('ru')}</div>
                    ${a.content_url ? `<a href="${normalizeUrl(a.content_url)}" target="_blank" class="card-link">🔗 Исходник</a>` : ''}
                    ${view === 'active' ? `<button class="btn-danger" style="margin-top:8px; padding:8px;" onclick="deleteIndividualAssignment('${a.id}')">🗑️ Удалить</button>` : ''}
                </div>
            `).join('');
        }

        async function deleteIndividualAssignment(id) {
            if (!confirm('Удалить это индивидуальное задание? Отменить будет нельзя.')) return;
            try {
                await db.from('assignments').delete().eq('id', id);
                alert('Удалено.');
                loadArchiveIndividual('active');
            } catch(e) { alert('Ошибка: ' + e.message); }
        }
