// teacher-review.js — проверка работ: modal/photo/lightbox, approve/reject/penalty (R02)
        function applyZoom(factor) {
            lbScale *= factor;
            lbScale = Math.min(Math.max(lbScale, 1), 4);
            if (lbScale <= 1) {
                lbPanX = 0;
                lbPanY = 0;
            } else {
                constrainPan();
            }
            updateLightboxTransform();
        }

        function resetZoom() {
            lbScale = 1;
            lbPanX = 0;
            lbPanY = 0;
            didDrag = false;
            updateLightboxTransform();
        }

        function constrainPan() {
            if (lbScale <= 1) {
                lbPanX = 0;
                lbPanY = 0;
                return;
            }
            const wrapper = document.getElementById('lightbox');
            const img = document.getElementById('lb-img');
            if (!wrapper || !img || !img.naturalWidth) return;

            const vw = wrapper.clientWidth;
            const vh = wrapper.clientHeight;
            const ratio = Math.min(vw / img.naturalWidth, vh / img.naturalHeight);
            const baseW = img.naturalWidth * ratio;
            const baseH = img.naturalHeight * ratio;
            const maxX = Math.max(0, (baseW * lbScale - vw) / 2);
            const maxY = Math.max(0, (baseH * lbScale - vh) / 2);

            lbPanX = Math.min(maxX, Math.max(-maxX, lbPanX));
            lbPanY = Math.min(maxY, Math.max(-maxY, lbPanY));
        }

        function updateLightboxTransform() {
            const img = document.getElementById('lb-img');
            if (img) {
                img.style.transform = `translate(${lbPanX}px, ${lbPanY}px) scale(${lbScale})`;
                img.classList.toggle('can-pan', lbScale > 1);
                if (!isPinching && !isDragging) {
                    img.style.transition = 'transform 0.3s cubic-bezier(0.25, 0.46, 0.45, 0.94)';
                }
            }
        }

        async function updatePendingCount() {
            const badge = document.getElementById('pending-count-badge');
            if (!badge) return;
            const { count, error } = await db
                .from('assignments')
                .select('id', { count: 'exact', head: true })
                .eq('status', 'submitted');

            if (error || !count) {
                badge.style.display = 'none';
                badge.innerText = '';
                return;
            }
            badge.innerText = count;
            badge.style.display = 'inline-block';
        }

        async function loadSubmissions() {
            const list = document.getElementById('submissions-list');
            list.innerHTML = '<div style="text-align:center; padding:40px;">Загрузка...</div>';
            updatePendingCount();

            let query = db.from('assignments').select('*, students(name, group_name)').order('submitted_at', { ascending: false });

            if (currentCheckView === 'pending') {
                query = query.eq('status', 'submitted');
            } else {
                // Архив принятых/возвращённых работ растёт неограниченно — без лимита Supabase молча
                // режет ответ на 1000 строк, и часть архива беззвучно пропадает (T7)
                query = query.eq('status', 'checked').limit(200);
            }

            const { data, error } = await query;
            if (error) return list.innerHTML = `<div style="color:red; padding:20px">${error.message}</div>`;

            if (!data.length) {
                const msg = currentCheckView === 'pending' ? 'Нет работ на проверку 🎉' : 'Архив пуст';
                return list.innerHTML = `<div style="text-align:center; padding:40px; color:#999">${msg}</div>`;
            }

            renderGroupedSubmissions(list, data);
        }

        // Группирует сданные работы по группе ученика, внутри группы — по типу задания
        const submissionTypeOrder = [
            { key: 'daily', label: '📅 Ежедневные' },
            { key: 'weekly', label: '🔥 Еженедельные' },
            { key: 'individual', label: '🎯 Индивидуальные' }
        ];

        function renderGroupedSubmissions(list, data) {
            list.innerHTML = '';

            const groups = {};
            data.forEach(sub => {
                const groupName = sub.students?.group_name || 'Без группы';
                if (!groups[groupName]) groups[groupName] = {};
                if (!groups[groupName][sub.type]) groups[groupName][sub.type] = [];
                groups[groupName][sub.type].push(sub);
            });

            const groupNames = Object.keys(groups).sort((a, b) => {
                if (a === 'Без группы') return 1;
                if (b === 'Без группы') return -1;
                return a.localeCompare(b);
            });

            groupNames.forEach(groupName => {
                const groupHeader = document.createElement('h3');
                groupHeader.style.margin = '20px 0 10px';
                groupHeader.innerText = `👥 ${groupName}`;
                list.appendChild(groupHeader);

                submissionTypeOrder.forEach(({ key, label }) => {
                    const subs = groups[groupName][key];
                    if (!subs || !subs.length) return;

                    const typeHeader = document.createElement('div');
                    typeHeader.style.cssText = 'font-size:13px; font-weight:600; color:#666; margin:10px 0 6px;';
                    typeHeader.innerText = `${label} (${subs.length})`;
                    list.appendChild(typeHeader);

                    subs.forEach(sub => list.appendChild(buildSubmissionCard(sub)));
                });
            });
        }

        function buildSubmissionCard(sub) {
            const card = document.createElement('div');
            card.className = 'submission-card';
            card.onclick = () => openReview(sub);

            const typeLabels = { daily: 'Ежедневное', weekly: 'Еженедельное', individual: 'Индивидуальное' };
            const badgeClass = `badge-${sub.type}`;
            const statusBadge = sub.approval_status === 'approved' ? 'badge-approved' : 'badge-rejected';
            const statusText = sub.approval_status === 'approved' ? 'Принято' : 'Возврат';

            card.innerHTML = `
                <div class="card-header">
                    <span class="student-name">${esc(sub.students?.name || 'Unknown')}</span>
                    <span class="badge ${badgeClass}">${typeLabels[sub.type]}</span>
                </div>
                <div class="card-meta">${esc(sub.title || 'Без названия')} • ${new Date(sub.submitted_at || sub.created_at).toLocaleString('ru')}</div>
                ${currentCheckView === 'archive' ? `<span class="badge ${statusBadge}" style="margin-top:5px;">${statusText}</span>` : ''}
                ${sub.content_url ? `<a href="${normalizeUrl(sub.content_url)}" target="_blank" class="card-link">🔗 Исходник</a>` : ''}
            `;
            return card;
        }

        function openReview(sub) {
            currentSubmissionId = sub.id;
            document.getElementById('rev-student').innerText = sub.students?.name || 'Unknown';

            const typeLabels = { daily: 'Ежедневное', weekly: 'Еженедельное', individual: 'Индивидуальное' };
            const badge = document.getElementById('rev-type');
            badge.innerText = typeLabels[sub.type];
            badge.className = `badge badge-${sub.type}`;

            document.getElementById('rev-comment-teacher').innerText = sub.teacher_comment || 'Нет комментария от учителя';
            document.getElementById('rev-link').href = sub.content_url ? normalizeUrl(sub.content_url) : '#';
            document.getElementById('rev-link').style.display = sub.content_url ? 'inline-block' : 'none';
            document.getElementById('rev-feedback').value = sub.teacher_feedback || '';

            try {
                reviewPhotos = JSON.parse(sub.photo_url);
                if (!Array.isArray(reviewPhotos)) reviewPhotos = [reviewPhotos];
            } catch { reviewPhotos = [sub.photo_url]; }

            reviewPhotoIndex = 0;
            updateReviewPhotoDisplay();

            document.getElementById('review-modal').classList.add('active');
            renderReviewDeadlineInfo(sub);
        }

        // Исходный срок, срок исправления и просрочка — только для daily (SPEC §6, W05).
        // «Просрочено» определяет сервер (is_first_submission_on_time — та же RPC, что считает
        // A в recalc_student_week), а не новое клиентское право; срок исправления — уже
        // готовое серверное поле revision_deadline_at, сравнение с now() — только для показа.
        async function renderReviewDeadlineInfo(sub) {
            const el = document.getElementById('rev-deadline-info');
            if (sub.type !== 'daily' || !sub.scheduled_date) { el.style.display = 'none'; return; }

            const lines = [`📅 Исходный срок: ${sub.scheduled_date} 23:59 МСК`];
            let overdue = false;

            if (sub.revision_deadline_at) {
                const dl = new Date(sub.revision_deadline_at);
                const windowClosed = dl <= new Date();
                lines.push(`✏️ Срок исправления: ${dl.toLocaleString('ru-RU', { timeZone: 'Europe/Moscow' })} МСК${windowClosed ? ' — истёк' : ''}`);

                // Пересдача засчитывается в A, только если сама попала в это окно — то же
                // условие, что в recalc_student_week (014): сравнение уже существующих
                // timestamp полей, не новое клиентское право.
                if ((sub.revision_count || 0) > 0 && sub.submitted_at && new Date(sub.submitted_at) > dl) {
                    overdue = true;
                }
            }

            el.innerText = lines.join('\n');
            el.style.display = 'block';

            try {
                // Авторитетная проверка «сама первая сдача была вовремя» — та же RPC, что
                // считает A в recalc_student_week, не переизобретаем сравнение дат в JS.
                const { data: onTime, error } = await db.rpc('is_first_submission_on_time', {
                    p_first_submitted_at: sub.first_submitted_at,
                    p_submitted_at: sub.submitted_at,
                    p_scheduled_date: sub.scheduled_date
                });
                if (error) throw error;
                if (onTime === false) overdue = true;
            } catch (e) { /* информационный блок необязателен для самой проверки — не блокируем модалку */ }

            if (overdue) {
                lines.push('⏰ Просрочено — эта сдача не засчитается в выполненные дни недели');
                el.innerText = lines.join('\n');
            }
        }

        function closeReview() {
            document.getElementById('review-modal').classList.remove('active');
            currentSubmissionId = null;
        }

        function updateReviewPhotoDisplay() {
            const img = document.getElementById('rev-photo');
            const prevBtn = document.getElementById('prev-photo-btn');
            const nextBtn = document.getElementById('next-photo-btn');
            const counter = document.getElementById('photo-counter');
            
            if (!img || !reviewPhotos.length) return;
            
            img.src = reviewPhotos[reviewPhotoIndex];
            
            if (reviewPhotos.length > 1) {
                prevBtn.style.display = 'block';
                nextBtn.style.display = 'block';
                counter.style.display = 'block';
                counter.innerText = `${reviewPhotoIndex + 1} / ${reviewPhotos.length}`;
                
                prevBtn.disabled = reviewPhotoIndex === 0;
                nextBtn.disabled = reviewPhotoIndex === reviewPhotos.length - 1;
                prevBtn.style.opacity = reviewPhotoIndex === 0 ? '0.3' : '1';
                nextBtn.style.opacity = reviewPhotoIndex === reviewPhotos.length - 1 ? '0.3' : '1';
            } else {
                prevBtn.style.display = 'none';
                nextBtn.style.display = 'none';
                counter.style.display = 'none';
            }
        }

        function changeReviewPhoto(dir) {
            reviewPhotoIndex += dir;
            if (reviewPhotoIndex < 0) reviewPhotoIndex = 0;
            if (reviewPhotoIndex >= reviewPhotos.length) reviewPhotoIndex = reviewPhotos.length - 1;
            updateReviewPhotoDisplay();
        }

        function openLightbox() {
            if (reviewPhotos.length > 0) {
                document.getElementById('lb-img').src = reviewPhotos[reviewPhotoIndex];
                resetZoom();
                document.getElementById('lightbox').classList.add('active');
            }
        }

        function closeLightbox() {
            if (didDrag || isDragging) return;
            document.getElementById('lightbox').classList.remove('active');
            resetZoom();
        }

        async function submitReview(status) {
            if (!currentSubmissionId) return;

            // Двойной клик/повтор не должен начислить награду дважды (W05): SELECT alreadyApproved
            // читается ДО update, поэтому без синхронной защиты два почти одновременных вызова
            // могли бы оба увидеть alreadyApproved=false и оба выдать streak/сезонные очки.
            // Проверка и установка disabled должны быть СИНХРОННЫМИ (до первого await): иначе
            // второй вызов проскочит проверку раньше, чем первый успеет выставить disabled.
            const approveBtn = document.querySelector('#review-modal .btn-success');
            const rejectBtn = document.querySelector('#review-modal .btn-danger');
            if (approveBtn.disabled || rejectBtn.disabled) return; // запрос уже выполняется
            approveBtn.disabled = true;
            rejectBtn.disabled = true;

            const feedback = document.getElementById('rev-feedback').value.trim();

            try {
                // Состояние читаем до обновления: повторное «Принять» уже принятой работы (открытой из Архива) не должно начислять бонус ещё раз
                const { data: sub, error: subErr } = await db.from('assignments').select('student_id, type, status, approval_status, scheduled_date').eq('id', currentSubmissionId).single();
                if (subErr) throw subErr;
                const alreadyApproved = sub.status === 'checked' && sub.approval_status === 'approved';

                // W11 — cutover-флаг читаем ДО изменения задания. Ошибка чтения не должна молча
                // включить legacy-награды: при сбое чтения прерываем операцию, ничего не меняя.
                // cutover_at — глобальный флаг economy_config (W09); NULL или будущая дата = ещё старая
                // модель; после cutover награды идут через серверные RPC, старый streak-путь не выполняется.
                const { data: cfg, error: cfgErr } = await db.from('economy_config').select('cutover_at').maybeSingle();
                if (cfgErr) throw cfgErr;
                const cutoverActive = !!(cfg && cfg.cutover_at) && Date.now() >= Date.parse(cfg.cutover_at);

                const { error: updErr } = await db.from('assignments').update({
                    status: 'checked',
                    approval_status: status,
                    teacher_feedback: feedback,
                    checked_at: new Date().toISOString()
                }).eq('id', currentSubmissionId);
                if (updErr) throw updErr;

                // Недельный результат пересчитывается сразу (W04/W05); награда за неделю на клиенте
                // не выдаётся — её платит finalize_student_week после cutover (W09).
                if (sub.type === 'daily' && sub.scheduled_date) {
                    try {
                        const { data: weekStart, error: wsErr } = await db.rpc('week_start_of', { p_date: sub.scheduled_date });
                        if (wsErr) throw wsErr;
                        if (weekStart) {
                            const { error: recalcErr } = await db.rpc('recalc_student_week', {
                                p_student_id: sub.student_id, p_week_start: weekStart
                            });
                            if (recalcErr) throw recalcErr;
                        }
                    } catch (e) { console.error('Не удалось пересчитать неделю: ' + e.message); }
                }

                if (status === 'approved') {
                    if (cutoverActive) {
                        // Идемпотентно на ЛЮБОЕ «Принять», включая уже принятую работу: восстанавливает
                        // награду после сетевого сбоя между update и RPC (W11). Внутри RPC атомарно и
                        // идемпотентно: season points 10/40/30, first_step, clean_10 и бублики 20/15 за
                        // weekly/individual. Per-day streak-награда/бонус возвращения/старые достижения
                        // после cutover не выдаются; недельные бублики за ежедневки — при финализации.
                        const { error: recErr } = await db.rpc('record_approved_assignment', { p_assignment_id: currentSubmissionId });
                        if (recErr) throw recErr;
                    } else if (!alreadyApproved) {
                        // Старая модель (до cutover) — только при реальном переходе в approved.
                        if (sub.type === 'daily') {
                            await processStreak(sub.student_id, sub.scheduled_date);
                        } else {
                            await awardApprovalBonus(sub.student_id, sub.type);
                        }
                        // Достижение «Первый шаг» (G5): первая принятая работа любого типа.
                        // Идемпотентно — на второй и далее принятой работе grantAchievement вернёт no-op.
                        await grantAchievement(sub.student_id, 'first_step');
                    }
                }

                alert(status === 'approved' ? 'Работа принята!' : 'Работа возвращена!');
                closeReview();
                loadSubmissions();
            } catch(e) { alert('Ошибка: ' + e.message); }
            finally { approveBtn.disabled = false; rejectBtn.disabled = false; }
        }

        // Стрик считается пересчётом цепочки подряд идущих scheduled_date с принятыми ежедневками,
        // а не датой, когда учитель нажал «Принять» — так пачка проверки, пропущенный день проверки
        // и приём из архива не в хронологическом порядке не портят счёт, а старые залипшие стрики
        // сами исправляются при следующем принятии. thisScheduledDate — дата именно той ежедневки,
        // которую только что приняли (её награда считается по её месту в цепочке, не по сегодняшней дате).
        async function processStreak(studentId, thisScheduledDate) {
            const { data: rows, error } = await db
                .from('assignments')
                .select('scheduled_date')
                .eq('student_id', studentId)
                .eq('type', 'daily')
                .eq('status', 'checked')
                .eq('approval_status', 'approved')
                .order('scheduled_date', { ascending: false })
                .limit(400);
            if (error) throw error;

            const dates = [...new Set((rows || []).map(r => r.scheduled_date))].sort();

            // Щит стрика (G9): дни, покрытые щитом, персистятся в streak_shield_uses и
            // участвуют в цепочке наравне с принятыми ежедневками. Читаем до пересчёта позиций.
            const { data: shieldRows, error: shieldError } = await db
                .from('streak_shield_uses')
                .select('bridged_date')
                .eq('student_id', studentId);
            if (shieldError) throw shieldError;
            const bridged = new Set((shieldRows || []).map(r => r.bridged_date));

            // Разрыв ровно в 1 день перед только что принятой ежедневкой: если он ещё не
            // покрыт и у ученика есть щит — списываем щит и покрываем пропущенный день, чтобы
            // цепочка не рвалась. Только 1 день (два пропущенных подряд один щит не закрывает).
            // Списание в момент пересчёта, а не кроном — рекомендация карточки G9.
            // consume_streak_shield идемпотентна: повторный пересчёт того же разрыва щит не тратит.
            const prevApproved = [...dates].reverse().find(d => d < thisScheduledDate);
            if (prevApproved && daysBetweenDates(prevApproved, thisScheduledDate) === 2) {
                const missingDay = addDaysToDate(prevApproved, 1);
                if (!bridged.has(missingDay)) {
                    const { data: consumed, error: consumeError } = await db.rpc('consume_streak_shield', {
                        p_student_id: studentId,
                        p_bridged_date: missingDay
                    });
                    if (consumeError) throw consumeError;
                    if (consumed === true) bridged.add(missingDay);
                }
            }

            // Эффективная цепочка = принятые ежедневки ∪ покрытые щитом дни.
            const effectiveDates = [...new Set([...dates, ...bridged])].sort();

            const positionByDate = {};
            let position = 0;
            let prevDate = null;
            for (const d of effectiveDates) {
                position = (prevDate && addDaysToDate(prevDate, 1) === d) ? position + 1 : 1;
                positionByDate[d] = position;
                prevDate = d;
            }

            // lastDate — последняя ПРИНЯТАЯ ежедневка (покрытый щитом день не является сдачей),
            // но её позиция берётся из эффективной цепочки (с учётом сшитых дней).
            const lastDate = dates[dates.length - 1];
            const currentStreak = lastDate ? positionByDate[lastDate] : 0;
            const thisPosition = positionByDate[thisScheduledDate] || 1;
            // Тиры стрика 2.0 (SPEC_STAGE1.md, раздел 4): 1→5, 2→10, 3-6→15, 7-29→20, 30+→25.
            const reward = thisPosition >= 30 ? 25 : thisPosition >= 7 ? 20 : thisPosition >= 3 ? 15 : thisPosition === 2 ? 10 : 5;

            await db.from('students').update({
                current_streak: currentStreak,
                last_submission_date_msk: lastDate
            }).eq('telegram_id', studentId);

            const { error: rpcError } = await db.rpc('add_huikons', {
                p_student_id: studentId,
                p_amount: reward,
                p_reason: `streak_day_${thisPosition}`
            });
            if (rpcError) throw rpcError;

            // Очки сезона (SPEC_STAGE1.md, раздел 3): «принятая ежедневка» (10) + «каждый день
            // стрика в сезоне» (2) — одно и то же событие приёма ежедневки, начисляются вместе.
            const { error: seasonError } = await db.rpc('add_season_points', {
                p_student_id: studentId,
                p_amount: 12
            });
            if (seasonError) throw seasonError;

            // Бонус возвращения (SPEC_STAGE1.md, раздел 5): разрыв ≥7 дней перед этой ежедневкой
            // в цепочке ВСЕХ когда-либо принятых ежедневок (не только текущей серии) — отдельным
            // начислением поверх обычной награды. Первая когда-либо принятая ежедневка (thisIndex=0,
            // предыдущей просто нет) бонус не даёт — возвращаться не из чего.
            const thisIndex = dates.indexOf(thisScheduledDate);
            if (thisIndex > 0 && daysBetweenDates(dates[thisIndex - 1], thisScheduledDate) >= 7) {
                const { error: bonusError } = await db.rpc('add_huikons', {
                    p_student_id: studentId,
                    p_amount: 20,
                    p_reason: 'bonus_return'
                });
                if (bonusError) throw bonusError;
            }

            // --- Достижения дисциплины (G5) ---
            // Вехи стрика = дисциплинарные достижения: SPEC_STAGE1.md раздел 6 — одно событие,
            // одно начисление (веха И достижение это одна строка student_achievements, не две).
            // maxStreak — самая длинная непрерывная серия в окне; выдаём все вехи, чей порог
            // достигнут (grantAchievement идемпотентен, уже выданные — no-op). Именно maxStreak,
            // а не thisPosition: приём ежедневки из архива, достраивающей старую цепочку, может
            // дать максимум выше позиции именно этой ежедневки.
            const positions = Object.values(positionByDate);
            const maxStreak = positions.length ? Math.max(...positions) : 0;
            for (const m of [7, 30, 100, 200, 365]) {
                if (maxStreak >= m) await grantAchievement(studentId, `streak_${m}`);
            }

            // «Возрождение» (SPEC раздел 6): стрик ≥30 → реальный срыв → снова ≥30. Позиция
            // сбрасывается в 1 на каждом разрыве цепочки, поэтому position===30 встречается ровно
            // один раз в каждой непрерывной серии, дошедшей до 30. Две такие серии = серия
            // оборвалась и была отстроена заново. Отдельное поле не нужно — факт «был высокий
            // стрик, потом упал» выводится из самой цепочки scheduled_date.
            const runsReaching30 = positions.filter(p => p === 30).length;
            if (runsReaching30 >= 2) await grantAchievement(studentId, 'rebirth');

            await checkPerfectMonth(studentId, thisScheduledDate);
        }

        // Награды достижений (SPEC_STAGE1.md раздел 6 + вехи раздела 4). Веха и одноимённое
        // «дисциплинарное» достижение — один код, одно начисление.
        const ACHIEVEMENT_REWARDS = {
            first_step: 10,
            streak_7: 25, streak_30: 100, streak_100: 300, streak_200: 500, streak_365: 1000,
            perfect_month: 150,
            rebirth: 200
        };

        // Идемпотентная выдача достижения. Строка student_achievements уникальна по
        // (student_id, achievement_code) — повторная выдача при повторном пересчёте цепочки не
        // создаёт вторую запись и не начисляет награду дважды. Гарантия на уровне БД (уникальный
        // constraint), а не только JS-проверки: награда идёт ТОЛЬКО если строка реально вставилась.
        // Известный компромисс: между успешной вставкой и add_huikons есть узкое окно — если
        // вкладка учителя умрёт ровно между ними, достижение зафиксируется без начисления (повтор
        // получит конфликт и награду уже не выдаст). Вероятность крайне мала, последствие —
        // недоданные бублики за одну веху; полная атомарность потребовала бы RPC-обёртки (как
        // close_season в G8), чего карточка G5 не предусматривает.
        async function grantAchievement(studentId, code) {
            const reward = ACHIEVEMENT_REWARDS[code];
            if (reward === undefined) return false;

            const { data, error } = await db.from('student_achievements')
                .insert({ student_id: studentId, achievement_code: code })
                .select();
            if (error) {
                if (error.code === '23505') return false; // уже выдано — идемпотентно
                throw error;
            }
            if (!data || !data.length) return false;

            const { error: rpcError } = await db.rpc('add_huikons', {
                p_student_id: studentId,
                p_amount: reward,
                p_reason: `achievement_${code}`
            });
            if (rpcError) throw rpcError;
            return true;
        }

        // «Идеальный месяц» (SPEC раздел 6): все ежедневки календарного месяца принятой ежедневки
        // приняты (нет ни одной несданной/возвращённой/ждущей в этом месяце). Проверяем месяц
        // именно thisScheduledDate — месяц «закрывается» в момент приёма его последней ежедневки,
        // даже если это поздняя проверка. Код 'perfect_month' без месяца → достижение одно за всё
        // время (модель «альбом уникальных достижений», а не ежемесячная награда) — продуктовое
        // решение, при желании легко сделать помесячным (код вида perfect_month_YYYY_MM).
        async function checkPerfectMonth(studentId, scheduledDate) {
            const [y, m] = scheduledDate.split('-').map(Number);
            const monthStart = `${y}-${String(m).padStart(2, '0')}-01`;
            const nextMonth = m === 12 ? `${y + 1}-01-01` : `${y}-${String(m + 1).padStart(2, '0')}-01`;

            const { data, error } = await db.from('assignments')
                .select('status, approval_status')
                .eq('student_id', studentId)
                .eq('type', 'daily')
                .gte('scheduled_date', monthStart)
                .lt('scheduled_date', nextMonth);
            if (error) throw error;
            if (!data || !data.length) return;

            const allApproved = data.every(a => a.status === 'checked' && a.approval_status === 'approved');
            if (allApproved) await grantAchievement(studentId, 'perfect_month');
        }

        // Флат-бонус за приём еженедельного/индивидуального задания (не связан со стриком — тот только для ежедневных)
        async function awardApprovalBonus(studentId, type) {
            const bonuses = { weekly: 20, individual: 15 };
            const reward = bonuses[type];
            if (!reward) return;

            const { error: rpcError } = await db.rpc('add_huikons', {
                p_student_id: studentId,
                p_amount: reward,
                p_reason: `${type}_approved`
            });
            if (rpcError) throw rpcError;

            // Очки сезона (SPEC_STAGE1.md, раздел 3): недельное +40, индивидуальное +30.
            const seasonPoints = { weekly: 40, individual: 30 };
            const { error: seasonError } = await db.rpc('add_season_points', {
                p_student_id: studentId,
                p_amount: seasonPoints[type]
            });
            if (seasonError) throw seasonError;
        }

        async function showPenaltyModal() {
            document.getElementById('penalty-modal').classList.add('active');
            selectedPenalty = -20;
            updatePenaltyButtons();

            const balanceEl = document.getElementById('pen-balance');
            balanceEl.innerText = '...';
            if (!currentSubmissionId) return;

            const { data: sub } = await db.from('assignments').select('student_id').eq('id', currentSubmissionId).single();
            if (!sub) return;
            const { data: student } = await db.from('students').select('huikons').eq('telegram_id', sub.student_id).single();
            balanceEl.innerText = student ? (student.huikons || 0) : '?';
        }

        function closePenalty() {
            document.getElementById('penalty-modal').classList.remove('active');
        }

        function selectPenalty(amount) {
            selectedPenalty = amount;
            updatePenaltyButtons();
        }

        function updatePenaltyButtons() {
            document.querySelectorAll('.penalty-btn').forEach(btn => {
                btn.classList.toggle('selected', parseInt(btn.innerText) === selectedPenalty);
            });
        }

        async function applyPenalty() {
            const reason = document.getElementById('pen-reason').value.trim();
            if (!reason) return alert('Укажите причину штрафа!');

            const { data: sub } = await db.from('assignments').select('student_id').eq('id', currentSubmissionId).single();

            try {
                // Кламп нулём и фактически списанная сумма в историю теперь считаются атомарно внутри RPC
                const { data: result, error: rpcError } = await db.rpc('add_huikons', {
                    p_student_id: sub.student_id,
                    p_amount: selectedPenalty,
                    p_reason: `penalty: ${reason}`
                }).single();
                if (rpcError) throw rpcError;

                alert(`Списано ${Math.abs(result.actual_change)} ${pluralBubliks(result.actual_change)}. Новый баланс: ${result.new_balance} 🥯`);
                closePenalty();
                closeReview();
            } catch(e) { alert('Ошибка: ' + e.message); }
        }

