// student-assignments.js — задания: активация, actionable, активные/загрузка/архив (R01)
        // --- АКТИВАЦИЯ ЗАДАНИЙ (АВТОПИЛОТ) ---
        async function checkAndActivateAssignments() {
            const todayMSK = getTodayMSK();
            
            // Ищем запланированные задания для текущего пользователя, срок которых настал
            const { data: toActivate, error } = await db
                .from('assignments')
                .select('id')
                .eq('student_id', currentUser.id)
                .eq('activation_status', 'scheduled')
                .lte('scheduled_date', todayMSK);

            if (error) { log('Ошибка активации: ' + error.message); return; }

            if (toActivate && toActivate.length > 0) {
                // Массово меняем статус на active
                const ids = toActivate.map(a => a.id);
                await db.from('assignments')
                    .update({ activation_status: 'active' })
                    .in('id', ids);
                log(`✅ Активировано ${ids.length} заданий.`);
            }
        }

        // --- ДЕЙСТВИЯ, КОТОРЫЕ МОЖНО ВЫПОЛНИТЬ ПРЯМО СЕЙЧАС ---
        async function getActionableAssignments() {
            const { data, error } = await db
                .from('assignments')
                .select('id, title, type, task_count, content_url, teacher_feedback, scheduled_date, status, approval_status, revision_deadline_at, created_at')
                .eq('student_id', currentUser.id)
                .eq('activation_status', 'active')
                .or('status.eq.assigned,and(status.eq.checked,approval_status.eq.rejected)')
                .order('created_at', { ascending: true });
            if (error) throw error;

            const todayMSK = getTodayMSK();
            const nowInstant = new Date();
            const typeOrder = { daily: 0, weekly: 1, individual: 2 };
            return (data || [])
                .filter(a => isAssignmentAvailable(a, nowInstant, todayMSK))
                .sort((a, b) => {
                    const aRevision = a.status === 'checked' && a.approval_status === 'rejected';
                    const bRevision = b.status === 'checked' && b.approval_status === 'rejected';
                    if (aRevision !== bRevision) return aRevision ? -1 : 1;
                    return (typeOrder[a.type] ?? 9) - (typeOrder[b.type] ?? 9)
                        || String(a.created_at).localeCompare(String(b.created_at));
                });
        }

        async function loadAssignmentsSummary() {
            const list = document.getElementById('now-list');
            const count = document.getElementById('now-count');
            try {
                const relevant = await getActionableAssignments();
                count.textContent = relevant.length;

                if (relevant.length === 0) {
                    list.innerHTML = '<div class="summary-empty">На сейчас всё сделано</div>';
                    return;
                }

                const typeLabels = { daily: 'Ежедневное', weekly: 'Еженедельное', individual: 'Индивидуальное' };
                const typeIcons = { daily: '📅', weekly: '🔥', individual: '🎯' };
                list.innerHTML = relevant.map(a => {
                    const revision = a.status === 'checked' && a.approval_status === 'rejected';
                    const deadline = revision && a.revision_deadline_at
                        ? ` · до ${new Date(a.revision_deadline_at).toLocaleString('ru-RU', { timeZone: 'Europe/Moscow' })}`
                        : '';
                    const tasks = a.task_count != null ? ` · ${a.task_count} ${pluralTasks(a.task_count)}` : '';
                    return `
                        <button class="now-item" type="button" data-assignment-id="${esc(String(a.id))}">
                            <span class="now-icon">${revision ? '✏️' : typeIcons[a.type]}</span>
                            <span class="now-main">
                                <span class="now-item-title">${esc(a.title || 'Без названия')}</span>
                                <span class="now-item-meta">${revision ? 'Исправить' : typeLabels[a.type]}${tasks}${deadline}</span>
                            </span>
                            <span class="now-arrow">›</span>
                        </button>
                    `;
                }).join('');

                list.querySelectorAll('.now-item').forEach(btn => {
                    btn.addEventListener('click', () => openNowAssignment(btn.dataset.assignmentId));
                });
            } catch (e) {
                count.textContent = '—';
                list.innerHTML = '<div class="summary-empty" style="color:#f44336;">Ошибка загрузки заданий</div>';
                log(e.message);
            }
        }

        async function openNowAssignment(assignmentId) {
            await switchTab('homework');
            await switchHwTab('upload');
            const select = document.getElementById('assignment-select');
            select.value = String(assignmentId);
            showAssignmentDetails();
        }

        // Склонение «задача» по числу — только в этом файле (как pluralShields/pluralDays; см. shared.js).
        function pluralTasks(n) {
            const mod10 = n % 10, mod100 = n % 100;
            if (mod10 === 1 && mod100 !== 11) return 'задача';
            if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) return 'задачи';
            return 'задач';
        }

        // Доступно ли задание для отправки прямо сейчас (W03). Возвращённая ежедневка
        // (checked+rejected) остаётся доступной, пока действует серверное окно исправления
        // revision_deadline_at (W04) — её НЕ отсекает scheduled_date !== today. Назначенная
        // ежедневка доступна только в свой день по МСК. weekly/individual — как раньше.
        // Признак берётся из серверных полей, новое право в JS не вычисляется (SPEC §6).
        function isAssignmentAvailable(a, nowInstant, todayMSK) {
            if (a.type !== 'daily') return true;
            if (a.status === 'checked' && a.approval_status === 'rejected') {
                return a.revision_deadline_at != null && new Date(a.revision_deadline_at) > nowInstant;
            }
            return a.scheduled_date === todayMSK;
        }

        // --- ЗАГРУЗКА АКТИВНЫХ ЗАДАНИЙ (ИСПРАВЛЕНО) ---
        async function loadActiveAssignments() {
            const select = document.getElementById('assignment-select');
            select.innerHTML = '<option value="">Выбери задание из списка...</option>';
            
            try {
                // Тот же источник и порядок, что в «Сделать сейчас»: исправления первыми,
                // будущие ежедневки не попадают в очередь действий.
                activeAssignments = await getActionableAssignments();

                if (activeAssignments.length === 0) {
                    select.innerHTML = '<option value="">Нет активных заданий 🕊️</option>';
                    select.disabled = true;
                    return;
                }

                select.disabled = false;
                activeAssignments.forEach(asn => {
                    const option = document.createElement('option');
                    option.value = asn.id;

                    const typeLabel = asn.type === 'daily' ? '📅' : asn.type === 'weekly' ? '🔥' : '👤';
                    const retryLabel = asn.status === 'checked' ? ' (переделать)' : '';
                    option.innerText = `${typeLabel} ${asn.title || 'Без названия'}${retryLabel}`;
                    select.appendChild(option);
                });
                
            } catch (e) {
                log('Ошибка загрузки заданий: ' + e.message);
            }
        }

        // Показывает ссылку и название выбранного задания
        function showAssignmentDetails() {
            const select = document.getElementById('assignment-select');
            const detailsDiv = document.getElementById('assignment-details');
            const btn = document.getElementById('btn-upload-dz');
            const assignmentId = select.value;
            
            if (!assignmentId) {
                detailsDiv.style.display = 'none';
                btn.disabled = true;
                return;
            }
            
            const assignment = activeAssignments.find(a => a.id === assignmentId);
            if (assignment) {
                document.getElementById('detail-title').innerText = assignment.title || 'Без названия';

                // Число задач показываем только для новых заданий; legacy (task_count = null)
                // не рендерим как «0 задач» (W03/P01A).
                const countEl = document.getElementById('detail-count');
                if (assignment.task_count != null) {
                    countEl.innerText = `📝 ${assignment.task_count} ${pluralTasks(assignment.task_count)}`;
                    countEl.style.display = 'block';
                } else {
                    countEl.style.display = 'none';
                }

                const linkEl = document.getElementById('detail-link');
                if (assignment.content_url) {
                    linkEl.href = normalizeUrl(assignment.content_url);
                    linkEl.style.display = 'inline-block';
                } else {
                    linkEl.style.display = 'none';
                }

                const feedbackEl = document.getElementById('detail-feedback');
                if (assignment.status === 'checked' && assignment.teacher_feedback) {
                    feedbackEl.innerText = `❌ Комментарий учителя: ${assignment.teacher_feedback}`;
                    feedbackEl.style.display = 'block';
                } else {
                    feedbackEl.style.display = 'none';
                }

                detailsDiv.style.display = 'block';
                btn.disabled = false;
            }
        }

        // --- ЗАГРУЗКА ФОТО И ДЗ (ИСПРАВЛЕННАЯ ЛОГИКА ДЕДЛАЙНОВ) ---
        function handleFileSelect(event) {
            const files = Array.from(event.target.files);
            if (files.length === 0) return;
            
            selectedFiles = files;
            const area = document.getElementById('upload-area');
            const fileListDiv = document.getElementById('file-list');
            const btn = document.getElementById('btn-upload-dz');
            
            fileListDiv.innerHTML = '';
            files.forEach((file, index) => {
                const div = document.createElement('div');
                div.className = 'file-item';
                div.innerHTML = `<span>${index + 1}. ${esc(file.name)}</span>`;
                fileListDiv.appendChild(div);
            });
            
            area.classList.add('has-file');
            area.querySelector('.upload-text').innerText = `Выбрано файлов: ${files.length}`;
            area.querySelector('.upload-icon').style.display = 'none';
            
            btn.disabled = false;
        }

        async function uploadToCloudinary(file) {
            const formData = new FormData();
            formData.append('file', file);
            formData.append('upload_preset', CLOUDINARY_UPLOAD_PRESET);
            formData.append('folder', 'sasha-math-dz');
            
            const res = await fetch(`https://api.cloudinary.com/v1_1/${CLOUDINARY_CLOUD_NAME}/image/upload`, {
                method: 'POST',
                body: formData
            });
            
            if (!res.ok) throw new Error('Ошибка загрузки в Cloudinary');
            const data = await res.json();
            return data.secure_url;
        }

        async function uploadDZ() {
            const btn = document.getElementById('btn-upload-dz');
            const select = document.getElementById('assignment-select');
            const status = document.getElementById('dz-status');
            const assignmentId = select.value;

            if (!assignmentId) { status.innerText = "⚠️ Выбери задание из списка!"; status.style.color = "#ff9800"; return; }
            if (selectedFiles.length === 0) { status.innerText = "⚠️ Выберите фото!"; status.style.color = "#ff9800"; return; }
            
            // === ЛОГИКА ДЕДЛАЙНОВ И НАГРАД ===
            const assignment = activeAssignments.find(a => a.id === assignmentId);
            if (!assignment) return;

            const nowInstant = new Date();
            const todayMSK = getTodayMSK();

            // Единый признак доступности с dropdown: просроченная ежедневка или возвращённая
            // ежедневка с истёкшим/отсутствующим окном исправления к отправке не принимается (W03).
            if (!isAssignmentAvailable(assignment, nowInstant, todayMSK)) {
                status.innerText = "⏰ Время вышло — работа больше не принимается";
                status.style.color = "#f44336";
                return;
            }

            let deadlineMSK = null;

            // Определяем дедлайн в зависимости от типа (награда за загрузку убрана — G11,
            // бублики теперь начисляются только за принятую работу учителем, см. G4/G6)
            if (assignment.type === 'individual') {
                deadlineMSK = null; // Без дедлайна
            } else if (assignment.type === 'weekly') {
                const [ty, tm, td] = todayMSK.split('-').map(Number);
                const currentDay = new Date(Date.UTC(ty, tm - 1, td)).getUTCDay();
                let daysUntilMonday = (1 - currentDay + 7) % 7;
                if (daysUntilMonday === 0) daysUntilMonday = 7;
                const monday = new Date(Date.UTC(ty, tm - 1, td + daysUntilMonday));
                deadlineMSK = moscowDateTimeToInstant(monday.getUTCFullYear(), monday.getUTCMonth() + 1, monday.getUTCDate(), 0, 0);
            } else if (assignment.status === 'checked' && assignment.approval_status === 'rejected') {
                // Возвращённая ежедневка: дедлайн — серверное окно исправления (W04),
                // а не 23:59 её исходного дня (isAssignmentAvailable выше уже проверил, что окно живо).
                deadlineMSK = assignment.revision_deadline_at ? new Date(assignment.revision_deadline_at) : null;
            } else {
                // Первая сдача ежедневки — 23:59 МСК её дня
                let dateStr = assignment.scheduled_date;
                if (!dateStr) {
                     status.innerText = "⚠️ Ошибка даты задания"; return;
                }
                if (dateStr instanceof Date) dateStr = dateStr.toISOString().split('T')[0];
                else if (typeof dateStr === 'string' && dateStr.includes('T')) dateStr = dateStr.split('T')[0];

                const [year, month, day] = dateStr.split('-').map(Number);
                deadlineMSK = moscowDateTimeToInstant(year, month, day, 23, 61); // 23:59 МСК + 2 минуты буфера
            }

            // Проверка дедлайна (только если он установлен)
            if (deadlineMSK && nowInstant > deadlineMSK) {
                status.innerText = `⏰ Время вышло! Дедлайн: ${deadlineMSK.toLocaleString('ru-RU', { timeZone: 'Europe/Moscow' })} МСК`;
                status.style.color = "#f44336";
                return;
            }
            // ==============================

            btn.disabled = true;
            status.innerText = `📤 Загрузка фото...`; 
            status.style.color = "var(--tg-text)";

            try {
                // 1. Загружаем все фото в Cloudinary
                const photoUrls = [];
                for (let i = 0; i < selectedFiles.length; i++) {
                    status.innerText = ` Загрузка фото (${i + 1}/${selectedFiles.length})...`;
                    const url = await uploadToCloudinary(selectedFiles[i]);
                    photoUrls.push(url);
                }
                
                status.innerText = "💾 Сохранение в базу...";
                
                // 2. Обновляем запись в assignments
                const { error: dbError } = await db.from('assignments').update({
                    photo_url: JSON.stringify(photoUrls),
                    status: 'submitted',
                    submitted_at: new Date().toISOString()
                }).eq('id', assignmentId);
                
                if (dbError) throw dbError;

                // Награда за загрузку убрана (G11) — бублики теперь только за принятую работу,
                // учитель как quality gate (SPEC_STAGE1.md, раздел 7). isResubmission оставлен
                // только для текста статуса — отличаем пересдачу от первой сдачи.
                const isResubmission = assignment.status === 'checked';

                status.innerText = isResubmission ? '✅ Работа пересдана на проверку!' : '✅ ДЗ загружено, ждёт проверки';
                status.style.color = "#4caf50";
                
                // Сброс формы
                selectedFiles = [];
                document.getElementById('file-list').innerHTML = '';
                document.getElementById('upload-area').classList.remove('has-file');
                document.getElementById('upload-area').querySelector('.upload-text').innerText = 'Нажми, чтобы выбрать фото (можно несколько)';
                document.getElementById('upload-area').querySelector('.upload-icon').style.display = 'block';
                select.value = "";
                showAssignmentDetails();
                
                await loadProfile();
                loadMyHomework();
                loadActiveAssignments();

            } catch (e) {
                status.innerText = " Ошибка: " + e.message;
                status.style.color = "#f44336";
                log(e.message);
            } finally {
                btn.disabled = false;
            }
        }

        // --- МОИ РАБОТЫ (АРХИВ) ---
        async function loadMyHomework() {
            const list = document.getElementById('my-hw-list');
            try {
                const { data, error } = await db
                    .from('assignments')
                    .select('*')
                    .eq('student_id', currentUser.id)
                    .neq('status', 'assigned')
                    .order('submitted_at', { ascending: false })
                    .limit(100);
                
                if (error) throw error;
                
                if (!data || data.length === 0) {
                    list.innerHTML = '<li style="text-align:center; padding:20px; opacity:0.5;">Ты еще не сдавал ДЗ</li>';
                    return;
                }
                
                list.innerHTML = '';
                data.forEach(hw => {
                    const li = document.createElement('li');
                    li.className = `my-hw-item status-${hw.status}`;
                    
                    const date = hw.submitted_at ? new Date(hw.submitted_at).toLocaleDateString('ru-RU') : '-';
                    const statusText = hw.status === 'submitted' ? 'На проверке' : 
                                     hw.approval_status === 'approved' ? 'Принято' : 'Возврат';
                    const badgeClass = hw.status === 'submitted' ? 'badge-pending' : 
                                     hw.approval_status === 'approved' ? 'badge-approved' : 'badge-rejected';
                    
                    let pagesCount = 1;
                    try {
                        const photos = JSON.parse(hw.photo_url);
                        pagesCount = Array.isArray(photos) ? photos.length : 1;
                    } catch(e) {}
                    
                    let commentHtml = '';
                    if (hw.teacher_feedback) {
                        const isRejected = hw.approval_status === 'rejected';
                        commentHtml = `<div class="hw-comment ${isRejected ? 'rejected' : ''}">
                             ${esc(hw.teacher_feedback)}
                        </div>`;
                    }

                    // Число задач — только для новых заданий; legacy null не показываем (W03/P01A)
                    const countHtml = hw.task_count != null
                        ? ` <span class="hw-pages">📝 ${hw.task_count} ${pluralTasks(hw.task_count)}</span>` : '';

                    li.innerHTML = `
                        <div class="hw-header">
                            <div>
                                <div class="hw-variant">${esc(hw.title || 'ДЗ')} <span class="hw-pages">📄 x${pagesCount}</span>${countHtml}</div>
                                <div class="hw-date">${date}</div>
                            </div>
                            <span class="hw-badge ${badgeClass}">${statusText}</span>
                        </div>
                        ${commentHtml}
                    `;
                    list.appendChild(li);
                });
                
            } catch (e) {
                list.innerHTML = '<li style="text-align:center; color:red; padding:20px;">Ошибка загрузки</li>';
                log(e.message);
            }
        }

