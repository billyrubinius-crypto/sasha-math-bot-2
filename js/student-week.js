// student-week.js — компактная неделя: полоса дней, раскрытие дня, недельные щиты (R01)
        // --- КОМПАКТНАЯ НЕДЕЛЯ: сервер возвращает готовые N/A/S/E и статусы дней ---
        const WEEK_DAY_NAMES = ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс'];
        const WEEK_DAY_FULL_NAMES = ['Понедельник', 'Вторник', 'Среда', 'Четверг', 'Пятница', 'Суббота', 'Воскресенье'];
        const WEEK_DAY_LABELS = {
            not_assigned: 'не назначено', assigned: 'назначено', submitted: 'отправлено',
            revision: 'на исправлении', approved: 'принято', missed: 'пропущено',
            shielded: 'закрыто щитом'
        };
        const WEEK_DAY_MARKS = {
            not_assigned: '–', assigned: '•', submitted: '↑', revision: '!', approved: '✓',
            missed: '×', shielded: '🛡'
        };

        let weekShieldBusy = false;
        let currentWeekView = null;
        let currentWeekAvailableShields = 0;
        let selectedWeekDayIndex = null;

        function shortDateRu(value) {
            if (!value) return '—';
            const [, month, day] = value.split('-');
            return `${day}.${month}`;
        }

        function addDaysToDateStr(dateStr, days) {
            const [year, month, day] = dateStr.split('-').map(Number);
            const result = new Date(Date.UTC(year, month - 1, day + days));
            return `${result.getUTCFullYear()}-${String(result.getUTCMonth() + 1).padStart(2, '0')}-${String(result.getUTCDate()).padStart(2, '0')}`;
        }

        function renderWeekStrip() {
            const strip = document.getElementById('week-days-strip');
            strip.innerHTML = (currentWeekView.days || []).map((day, index) => {
                const status = WEEK_DAY_LABELS[day.status] ? day.status : 'not_assigned';
                const selected = selectedWeekDayIndex === index ? ' selected' : '';
                const today = day.date === getTodayMSK() ? ' today' : '';
                const label = `${WEEK_DAY_FULL_NAMES[index]}: ${WEEK_DAY_LABELS[status]}`;
                return `
                    <button class="week-day-chip wd-${status}${today}${selected}" type="button"
                            aria-label="${esc(label)}" onclick="selectWeekDay(${index})">
                        <span class="week-day-name">${WEEK_DAY_NAMES[index]}</span>
                        <span class="week-day-mark">${WEEK_DAY_MARKS[status]}</span>
                    </button>
                `;
            }).join('');
        }

        function selectWeekDay(index) {
            const detail = document.getElementById('week-day-detail');
            if (selectedWeekDayIndex === index && detail.classList.contains('open')) {
                detail.classList.remove('open');
                selectedWeekDayIndex = null;
                renderWeekStrip();
                return;
            }
            selectedWeekDayIndex = index;
            renderWeekStrip();
            renderWeekDayDetail();
        }

        function renderWeekDayDetail() {
            const detail = document.getElementById('week-day-detail');
            const day = currentWeekView?.days?.[selectedWeekDayIndex];
            if (!day) {
                detail.classList.remove('open');
                detail.innerHTML = '';
                return;
            }

            const status = WEEK_DAY_LABELS[day.status] ? day.status : 'not_assigned';
            let note = WEEK_DAY_LABELS[status];
            if (status === 'revision' && day.revision_deadline_at) {
                note += ` · до ${new Date(day.revision_deadline_at).toLocaleString('ru-RU', { timeZone: 'Europe/Moscow' })} МСК`;
            }
            let action = '';
            if (day.shield_status === 'requested') {
                action = '<button class="week-shield-btn remove" type="button" data-action="remove">Отменить щит</button>';
            } else if (status === 'missed' && day.assignment_id && currentWeekAvailableShields > 0) {
                action = '<button class="week-shield-btn apply" type="button" data-action="apply">Прикрыть щитом</button>';
            }

            detail.innerHTML = `
                <div class="week-day-detail-main">
                    <div class="week-day-detail-title">${WEEK_DAY_FULL_NAMES[selectedWeekDayIndex]} · ${shortDateRu(day.date)}${day.title ? ` · ${esc(day.title)}` : ''}</div>
                    <div class="week-day-detail-note">${note}</div>
                </div>
                ${action}
            `;
            detail.classList.add('open');

            const btn = detail.querySelector('[data-action]');
            if (btn) {
                btn.addEventListener('click', () => {
                    if (btn.dataset.action === 'remove') removeWeekShield(day.assignment_id, btn);
                    else applyWeekShield(day.assignment_id, btn);
                });
            }
        }

        async function loadWeekBlock() {
            const block = document.getElementById('week-block');
            try {
                const [weekRes, availRes] = await Promise.all([
                    db.rpc('get_student_current_week', { p_student_id: currentUser.id }),
                    db.rpc('available_shield_quantity', { p_student_id: currentUser.id })
                ]);
                if (weekRes.error) throw weekRes.error;

                currentWeekView = Array.isArray(weekRes.data) ? weekRes.data[0] : weekRes.data;
                currentWeekAvailableShields = availRes.error ? 0 : (availRes.data || 0);
                if (selectedWeekDayIndex != null && !currentWeekView.days?.[selectedWeekDayIndex]) {
                    selectedWeekDayIndex = null;
                }

                document.getElementById('week-block-sub').textContent =
                    `${shortDateRu(currentWeekView.week_start)} — ${shortDateRu(currentWeekView.week_end)}`;
                document.getElementById('week-progress').textContent = `${currentWeekView.a || 0}/7`;
                renderWeekStrip();
                renderWeekDayDetail();

                const weekly = currentWeekView.weekly;
                const weeklyLabels = {
                    assigned: 'назначено', submitted: 'отправлено', approved: 'принято',
                    rejected: 'возвращено', unknown: 'неизвестно'
                };
                document.getElementById('week-weekly-row').innerHTML = weekly
                    ? `🔥 Еженедельное: <b>${weeklyLabels[weekly.status] || 'неизвестно'}</b> · ${esc(weekly.title || 'Без названия')}`
                    : '🔥 Еженедельное: не назначено';

                document.getElementById('week-totals').innerHTML =
                    `Назначено: <b>${currentWeekView.n || 0}</b> · Принято: <b>${currentWeekView.a || 0}</b>`
                    + (currentWeekView.s ? ` + 🛡 ${currentWeekView.s}` : '')
                    + ` · Эффективно: <b>${currentWeekView.e || 0}/7</b>`;

                const deadline = shortDateRu(addDaysToDateStr(currentWeekView.week_end, 1));
                const forecast = document.getElementById('week-forecast');
                if (currentWeekView.classification === 'pending') {
                    forecast.textContent = `Итог уточняется: есть работа на проверке или открытое исправление. Закрытие ${deadline} в 00:00 МСК.`;
                } else if (currentWeekView.classification === 'neutral') {
                    forecast.textContent = `Назначено меньше 4 ежедневных: неделя нейтральная. Закрытие ${deadline} в 00:00 МСК.`;
                } else {
                    forecast.textContent = `При текущем итоге: ${currentWeekView.reward_forecast || 0} 🥯. Закрытие ${deadline} в 00:00 МСК.`;
                }
                block.style.display = 'block';
            } catch (e) {
                document.getElementById('week-block-sub').textContent = 'Не удалось загрузить неделю';
                document.getElementById('week-progress').textContent = '—/7';
                document.getElementById('week-days-strip').innerHTML = '';
                document.getElementById('week-day-detail').classList.remove('open');
                log('❌ Ошибка недельного блока: ' + e.message);
            }
        }

        async function applyWeekShield(assignmentId, btn) {
            if (weekShieldBusy || btn.disabled) return; // синхронная защита от двойного клика (урок W05)
            weekShieldBusy = true;
            btn.disabled = true;
            try {
                const { error } = await db.rpc('request_weekly_shield', {
                    p_student_id: currentUser.id, p_assignment_id: assignmentId
                });
                if (error) throw error;
                await loadWeekBlock();
            } catch (e) {
                alert('Не удалось применить щит: ' + (e.message || e));
                btn.disabled = false;
            } finally { weekShieldBusy = false; }
        }

        async function removeWeekShield(assignmentId, btn) {
            if (weekShieldBusy || btn.disabled) return;
            weekShieldBusy = true;
            btn.disabled = true;
            try {
                const { error } = await db.rpc('cancel_weekly_shield', {
                    p_student_id: currentUser.id, p_assignment_id: assignmentId
                });
                if (error) throw error;
                await loadWeekBlock();
            } catch (e) {
                alert('Не удалось отменить щит: ' + (e.message || e));
                btn.disabled = false;
            } finally { weekShieldBusy = false; }
        }

