// Teacher journal: independent roster and historical assignments, never the bot's current slot.
const JOURNAL_STATUSES = {
    approved: ['✓ Принято', 'success'], approved_late: ['× Принято с опозданием', 'danger'],
    submitted: ['↑ На проверке', 'pending'], missed: ['× Пропущено', 'danger'],
    revision: ['! На исправлении', 'danger'], assigned: ['• Назначено', 'neutral'],
    planned: ['◷ Запланировано', 'neutral']
};
const JOURNAL_TYPES = { daily: 'Ежедневное', weekly: 'Еженедельное', individual: 'Индивидуальное' };
let journalStudents = [], journalDetail = null, journalStudentId = null;
let journalRequest = 0, journalDetailRequest = 0, journalSaving = false;

function journalNode(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
}
function journalButton(text, action, className = 'btn-secondary') {
    const button = journalNode('button', className, text);
    button.type = 'button'; button.onclick = action;
    return button;
}
function journalNumber(stats, key) { return Number(stats?.[key]) || 0; }
function journalIssues(student) {
    return ['missed', 'revision', 'late'].reduce((n, key) => n + journalNumber(student.stats, key), 0);
}
function journalDate(value) {
    if (!value) return '—';
    return value.slice(0, 10).split('-').reverse().join('.');
}
function journalUrl(value) {
    if (typeof value !== 'string' || !value.trim()) return null;
    try {
        const url = new URL(normalizeUrl(value));
        return ['https:', 'http:'].includes(url.protocol) ? url.href : null;
    } catch { return null; }
}
function journalPhotos(value) {
    if (!value) return [];
    let photos;
    try { photos = JSON.parse(value); } catch { photos = value; }
    return (Array.isArray(photos) ? photos : [photos]).map(journalUrl).filter(Boolean);
}
function journalError(error) {
    const raw = String(error?.message || error || '');
    if (raw.includes('journal_conflict')) return 'Работу уже изменили или ученик отправил решение. Обновите журнал и откройте исправление заново.';
    if (raw.includes('invalid_correct_task_count')) return 'Проверьте число правильно решённых задач.';
    if (raw.includes('reason_required')) return 'Укажите причину длиной от 3 до 1000 символов.';
    if (raw.includes('future_assignment')) return 'Будущее задание пока нельзя исправить.';
    if (raw.includes('forbidden')) return 'Сессия учителя недействительна. Войдите снова.';
    if (raw.includes('get_teacher_journal_self') || raw.includes('correct_journal_assignment_self') || error?.code === 'PGRST202') {
        return 'Журнал ещё не подключён к базе. Нужно применить миграции 072 и 073.';
    }
    return 'Не удалось выполнить запрос. Проверьте соединение и попробуйте снова.';
}
function journalPeriod() {
    const fromInput = document.getElementById('journal-from');
    const toInput = document.getElementById('journal-to');
    if (!fromInput.value && !toInput.value) {
        toInput.value = getTodayMSK(); fromInput.value = addDaysToDate(toInput.value, -29);
    }
    const from = fromInput.value, to = toInput.value;
    if (!from || !to || to < from || daysBetweenDates(from, to) > 92) {
        throw new Error('Выберите обе даты: период должен составлять от 1 до 93 дней.');
    }
    return { p_from: from, p_to: to };
}
async function loadJournal() {
    if (!db) return;
    const request = ++journalRequest;
    ++journalDetailRequest;
    journalStudents = []; journalDetail = null;
    document.getElementById('journal-list').replaceChildren();
    document.getElementById('journal-summary').replaceChildren();
    document.getElementById('journal-detail').hidden = true;
    const message = document.getElementById('journal-message');
    message.textContent = 'Загрузка журнала…';
    let period;
    try { period = journalPeriod(); }
    catch (e) { message.textContent = e.message; return; }
    try {
        const { data, error } = await db.rpc('get_teacher_journal_self', period);
        if (request !== journalRequest) return;
        if (error) throw error;
        journalStudents = data?.students || [];
        const group = document.getElementById('journal-group');
        const previous = group.value;
        group.replaceChildren(new Option('Все группы', ''));
        const groups = [...new Set(journalStudents.map(s => s.group_name || ''))].sort((a, b) => a.localeCompare(b, 'ru'));
        groups.forEach(name => group.add(new Option(name || 'Без группы', name || '__ungrouped__')));
        if ([...group.options].some(o => o.value === previous)) group.value = previous;
        message.textContent = '';
        renderJournal(true);
        if (journalStudentId && journalStudents.some(s => s.telegram_id === journalStudentId)) {
            await openJournalStudent(journalStudentId, false);
        } else journalStudentId = null;
    } catch (e) {
        if (request === journalRequest) message.textContent = journalError(e);
    }
}
function journalFilteredStudents() {
    const group = document.getElementById('journal-group').value;
    const search = document.getElementById('journal-search').value.trim().toLocaleLowerCase('ru');
    const attention = document.getElementById('journal-attention').checked;
    return journalStudents.filter(s => (!group || (group === '__ungrouped__' ? !s.group_name : s.group_name === group))
        && (!search || `${s.name || ''} ${s.telegram_username || ''}`.toLocaleLowerCase('ru').includes(search))
        && (!attention || journalIssues(s) > 0));
}
function renderJournal(preserveDetail = false) {
    const students = journalFilteredStudents();
    const summary = document.getElementById('journal-summary'); summary.replaceChildren();
    const totals = students.reduce((t, s) => {
        for (const key of ['approved', 'submitted', 'missed', 'revision', 'late', 'solved', 'excused']) t[key] += journalNumber(s.stats, key);
        return t;
    }, { approved: 0, submitted: 0, missed: 0, revision: 0, late: 0, solved: 0, excused: 0 });
    for (const [label, value] of [['Ученики', students.length], ['Принятые работы', totals.approved],
        ['Правильные задачи', totals.solved], ['На проверке', totals.submitted],
        ['Пропуски / возвраты', totals.missed + totals.revision + totals.late], ['Исключения', totals.excused]]) {
        const card = journalNode('div', 'journal-stat');
        card.append(journalNode('strong', '', String(value)), journalNode('span', '', label)); summary.append(card);
    }
    const list = document.getElementById('journal-list'); list.replaceChildren();
    if (!students.length) list.append(journalNode('p', 'journal-empty', 'Ученики по этим фильтрам не найдены.'));
    const groups = new Map();
    students.forEach(s => { const key = s.group_name || 'Без группы'; if (!groups.has(key)) groups.set(key, []); groups.get(key).push(s); });
    for (const [name, rows] of groups) {
        const section = journalNode('section', 'journal-group');
        section.append(journalNode('h3', '', `${name} · ${rows.length}`));
        const wrap = journalNode('div', 'journal-table-wrap'), table = journalNode('table', 'journal-table');
        const thead = journalNode('thead'), header = journalNode('tr');
        ['Ученик', 'Принято / задано', 'Правильно задач', 'На проверке', 'Пропуски / возвраты', 'Последняя загрузка'].forEach(label => {
            const th = journalNode('th', '', label); th.scope = 'col'; header.append(th);
        }); thead.append(header); table.append(thead);
        const tbody = journalNode('tbody');
        rows.forEach(student => {
            const row = journalNode('tr', student.telegram_id === journalStudentId ? 'selected' : '');
            const nameCell = journalNode('td');
            nameCell.append(journalButton(student.name || 'Без имени', () => openJournalStudent(student.telegram_id), 'journal-student-button'));
            if (student.telegram_username) nameCell.append(journalNode('small', 'journal-username', `@${student.telegram_username}`));
            row.append(nameCell);
            const stats = student.stats;
            for (const text of [`${journalNumber(stats, 'approved')} / ${journalNumber(stats, 'total')}`,
                `${journalNumber(stats, 'solved')} / ${journalNumber(stats, 'task_total')}`, String(journalNumber(stats, 'submitted')),
                String(journalIssues(student)), stats?.last_upload ? formatMsk(stats.last_upload) : '—']) row.append(journalNode('td', '', text));
            tbody.append(row);
        }); table.append(tbody); wrap.append(table); section.append(wrap); list.append(section);
    }
    if (!preserveDetail && journalStudentId && !students.some(s => s.telegram_id === journalStudentId)) closeJournalStudent();
}
function closeJournalStudent() {
    ++journalDetailRequest; journalStudentId = null; journalDetail = null;
    const box = document.getElementById('journal-detail'); box.hidden = true; box.replaceChildren();
}
async function openJournalStudent(studentId, scroll = true) {
    const request = ++journalDetailRequest;
    journalStudentId = String(studentId); journalDetail = null;
    renderJournal(true);
    const box = document.getElementById('journal-detail'); box.hidden = false;
    box.replaceChildren(journalNode('p', '', 'Загрузка карточки ученика…'));
    if (scroll) box.scrollIntoView({ behavior: 'smooth', block: 'start' });
    try {
        const { data, error } = await db.rpc('get_teacher_journal_self', { ...journalPeriod(), p_student_id: journalStudentId });
        if (request !== journalDetailRequest) return;
        if (error) throw error;
        journalDetail = data; renderJournalDetail();
    } catch (e) {
        if (request === journalDetailRequest) box.replaceChildren(journalNode('p', 'journal-error', journalError(e)),
            journalButton('Повторить', () => openJournalStudent(studentId)));
    }
}
function renderJournalDetail() {
    const box = document.getElementById('journal-detail'); box.replaceChildren(); box.hidden = false;
    const student = journalDetail.students[0];
    const head = journalNode('div', 'journal-heading');
    const title = journalNode('div'); title.append(journalNode('h2', '', student.name || 'Без имени'),
        journalNode('p', '', `${student.group_name || 'Без группы'} · ${journalDate(document.getElementById('journal-from').value)} — ${journalDate(document.getElementById('journal-to').value)}`));
    head.append(title, journalButton('Закрыть карточку', closeJournalStudent)); box.append(head);
    const filters = journalNode('div', 'journal-detail-filters');
    const type = journalNode('select'), status = journalNode('select');
    type.setAttribute('aria-label', 'Тип заданий'); status.setAttribute('aria-label', 'Статус заданий');
    type.add(new Option('Все типы заданий', '')); Object.entries(JOURNAL_TYPES).forEach(([k, label]) => type.add(new Option(label, k)));
    status.add(new Option('Все статусы', '')); Object.entries(JOURNAL_STATUSES).forEach(([k, [label]]) => status.add(new Option(label, k)));
    filters.append(type, status); box.append(filters);
    const tasks = journalNode('div', 'journal-tasks'); box.append(tasks);
    const renderTasks = () => {
        tasks.replaceChildren();
        const rows = journalDetail.assignments.filter(a => (!type.value || type.value === a.type) && (!status.value || status.value === a.journal_status));
        if (!rows.length) tasks.append(journalNode('p', 'journal-empty', 'За этот период нет заданий с выбранными фильтрами.'));
        rows.forEach(a => tasks.append(journalAssignmentCard(a, student)));
    }; type.onchange = renderTasks; status.onchange = renderTasks; renderTasks();
    if (journalDetail.exams.length) {
        box.append(journalNode('h3', '', 'Пробники'));
        journalDetail.exams.forEach(exam => box.append(journalNode('p', '', `${journalDate(exam.exam_date || exam.created_at)} · ${exam.exam_name}: ${exam.score || '—'}`)));
    }
    const history = journalNode('details', 'journal-history');
    history.append(journalNode('summary', '', `История исправлений · ${journalDetail.changes.length}`));
    journalDetail.changes.forEach(change => {
        const a = journalDetail.assignments.find(task => task.id === change.assignment_id);
        const line = journalNode('div', 'journal-history-entry');
        const state = snapshot => ({ approved: 'Принято', rejected: 'На исправлении', assigned: 'Не сдано',
            submitted: 'На проверке', checked: 'Проверено' }[snapshot.approval_status || snapshot.status] || '—');
        line.append(journalNode('strong', '', `${formatMsk(change.created_at)} · ${a?.title || 'Задание'}`),
            journalNode('p', '', `${state(change.before_state)} → ${state(change.after_state)}; правильно задач: ${change.before_state.correct_task_count ?? '—'} → ${change.after_state.correct_task_count ?? '—'}; исключение: ${change.before_state.teacher_excused_at ? 'да' : 'нет'} → ${change.after_state.teacher_excused_at ? 'да' : 'нет'}`),
            journalNode('p', '', change.reason)); history.append(line);
    }); box.append(history);
}
function journalAssignmentCard(a, student) {
    const card = journalNode('article', 'journal-task');
    const head = journalNode('div', 'journal-task-head');
    const [label, tone] = JOURNAL_STATUSES[a.journal_status] || ['Неизвестный статус', 'neutral'];
    head.append(journalNode('strong', '', a.title || 'Без названия'), journalNode('span', `journal-status journal-status--${tone}`, label)); card.append(head);
    card.append(journalNode('p', 'journal-meta', `${journalDate(a.journal_date)} · ${JOURNAL_TYPES[a.type] || a.type} · Правильно: ${a.correct_task_count ?? '—'} из ${a.task_count ?? 'неизвестно'}`));
    if (a.teacher_excused_at && a.approval_status === 'approved') card.append(journalNode('p', 'journal-excused', '✓ Зачтено учителем как исключение. День сохраняет серию.'));
    if (a.submitted_at) card.append(journalNode('p', 'journal-meta', `Загружено: ${formatMsk(a.submitted_at)}${a.checked_at ? ' · Проверено: ' + formatMsk(a.checked_at) : ''}`));
    if (a.teacher_comment) card.append(journalNode('p', '', `Условие / комментарий: ${a.teacher_comment}`));
    if (a.teacher_feedback) card.append(journalNode('p', '', `Обратная связь: ${a.teacher_feedback}`));
    const url = journalUrl(a.content_url);
    if (url) { const link = journalNode('a', 'card-link', 'Открыть исходное задание'); link.href = url; link.target = '_blank'; link.rel = 'noopener noreferrer'; card.append(link); }
    const photos = journalPhotos(a.photo_url);
    if (photos.length) {
        const details = journalNode('details', 'journal-photos'); details.append(journalNode('summary', '', `Решение ученика · ${photos.length} фото`));
        const grid = journalNode('div', 'journal-photo-grid');
        photos.forEach((photo, index) => {
            const link = journalNode('a'); link.href = photo; link.target = '_blank'; link.rel = 'noopener noreferrer';
            const img = journalNode('img'); img.src = photo; img.alt = `Решение, страница ${index + 1}`; img.loading = 'lazy';
            img.onerror = () => link.replaceChildren(journalNode('span', 'journal-hint', 'Фото недоступно: срок хранения мог истечь.'));
            link.append(img); grid.append(link);
        }); details.append(grid); card.append(details);
    } else card.append(journalNode('p', 'journal-hint', a.journal_status === 'planned'
        ? 'Фото решения не загружены.' : 'Фото решения не загружены. Прошедший день можно зачесть вручную как исключение.'));
    if (a.journal_status !== 'planned') {
        const actions = journalNode('div', 'journal-task-actions');
        if (photos.length && ['submitted', 'checked'].includes(a.status)) actions.append(journalButton('Проверить работу', () => openReview({ ...a, students: student })));
        actions.append(journalButton('Исправить отчёт / зачесть исключение', () => renderJournalEditor(a, card)));
        card.append(actions);
    } return card;
}
function renderJournalEditor(a, card) {
    card.querySelector('.journal-editor')?.remove();
    const form = journalNode('form', 'journal-editor');
    form.append(journalNode('h4', '', 'Исправление отчёта'));
    const status = journalNode('select');
    [['approved', 'Принято'], ['rejected', 'На исправлении'], ['assigned', 'Не сдано']].forEach(([key, label]) => status.add(new Option(label, key)));
    status.value = a.approval_status || (a.status === 'assigned' ? 'assigned' : 'approved');
    const statusLabel = journalNode('label', '', 'Результат'); statusLabel.append(status); form.append(statusLabel);
    const count = journalNode('input'); count.type = 'number'; count.min = '0'; count.max = String(a.task_count ?? 200); count.step = '1';
    count.value = a.correct_task_count === null || a.correct_task_count === undefined ? '' : String(a.correct_task_count);
    const countLabel = journalNode('label', '', `Правильно решено (из ${a.task_count ?? 'неизвестного количества'})`); countLabel.append(count); form.append(countLabel);
    const excuse = journalNode('input'); excuse.type = 'checkbox'; excuse.checked = !!a.teacher_excused_at;
    const excuseLabel = journalNode('label', 'journal-exception-control'); excuseLabel.append(excuse, document.createTextNode('Зачесть день вовремя как исключение: заменить крестик на галочку и сохранить серию'));
    form.append(excuseLabel);
    const reason = journalNode('textarea'); reason.required = true; reason.minLength = 3; reason.maxLength = 1000;
    reason.placeholder = 'Например: работу решил вовремя, не успел отправить. Проверено на занятии.';
    const reasonLabel = journalNode('label', '', 'Причина исправления (будет видна ученику)'); reasonLabel.append(reason); form.append(reasonLabel);
    form.append(journalNode('p', 'journal-hint', 'Без исключения поздняя работа остаётся пропуском. Время загрузки сохраняется. Серии и достижения пересчитываются; недостающая награда за достижение выдаётся один раз. Выплаченные награды за работы и недели не переигрываются.'));
    const error = journalNode('p', 'journal-error'); error.setAttribute('role', 'alert'); form.append(error);
    const save = journalNode('button', 'btn-primary', 'Сохранить исправление'); save.type = 'submit';
    const cancel = journalButton('Отмена', () => form.remove()); form.append(save, cancel);
    const update = () => {
        count.disabled = status.value !== 'approved'; count.required = !count.disabled;
        excuse.disabled = status.value !== 'approved' || a.type !== 'daily' || !a.scheduled_date;
        if (excuse.disabled) excuse.checked = false;
    }; status.onchange = update; update();
    form.onsubmit = async event => {
        event.preventDefault(); if (journalSaving) return;
        const correct = status.value === 'approved' && /^\d+$/.test(count.value.trim()) ? Number(count.value) : null;
        if (status.value === 'approved' && (correct === null || !Number.isSafeInteger(correct) || correct > Number(count.max))) {
            error.textContent = `Укажите целое число от 0 до ${count.max}.`; return;
        }
        if (reason.value.trim().length < 3) { error.textContent = 'Укажите причину (не менее 3 символов).'; return; }
        const params = { p_assignment_id: a.id, p_status: status.value, p_correct_task_count: correct,
            p_excuse: excuse.checked, p_reason: reason.value.trim(), p_expected_version: a.journal_version };
        journalSaving = true; save.disabled = true; cancel.disabled = true; error.textContent = '';
        try {
            const { data: correction, error: rpcError } = await db.rpc('correct_journal_assignment_self', params);
            if (rpcError) throw rpcError;
            await loadJournal();
            const awarded = Number(correction?.achievements_awarded) || 0;
            document.getElementById('journal-message').textContent = 'Исправление сохранено. Отчёт ученика обновлён.' +
                (awarded > 0 ? ` Выдано новых достижений: ${awarded}.` : '');
            updatePendingCount();
        } catch (e) { error.textContent = journalError(e); }
        finally { journalSaving = false; save.disabled = false; cancel.disabled = false; }
    };
    card.append(form); reason.focus();
}

function clearTeacherJournal() {
    ++journalRequest; closeJournalStudent(); journalStudents = [];
    document.getElementById('journal-list').replaceChildren();
    document.getElementById('journal-summary').replaceChildren();
    document.getElementById('journal-message').textContent = '';
}
