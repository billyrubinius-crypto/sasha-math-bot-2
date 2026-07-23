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
            // Teacher read gateway (T10-06A/07): assignment/студент читаются сервером, не напрямую
            // из таблицы под publishable key.
            const { data, error } = await db.rpc('get_review_queue_self', { p_view: 'pending' });
            const count = !error && data ? data.pending_count : 0;

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

            // get_review_queue_self (T10-06A) уже воспроизводит прежний контракт: тот же порядок
            // (submitted_at desc), тот же лимит 200 для архива (T7), та же форма students{name,
            // group_name}.
            const { data, error } = await db.rpc('get_review_queue_self', { p_view: currentCheckView });
            if (error) return list.innerHTML = `<div style="color:red; padding:20px">${error.message}</div>`;

            const items = data.items || [];
            if (!items.length) {
                const msg = currentCheckView === 'pending' ? 'Нет работ на проверку 🎉' : 'Архив пуст';
                return list.innerHTML = `<div style="text-align:center; padding:40px; color:#999">${msg}</div>`;
            }

            renderGroupedSubmissions(list, items);
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

            // Двойной клик/повтор не должен начислить награду дважды (W05): проверка и установка
            // disabled должны быть СИНХРОННЫМИ (до первого await), иначе второй вызов проскочит
            // проверку раньше, чем первый успеет выставить disabled.
            const approveBtn = document.querySelector('#review-modal .btn-success');
            const rejectBtn = document.querySelector('#review-modal .btn-danger');
            if (approveBtn.disabled || rejectBtn.disabled) return; // запрос уже выполняется
            approveBtn.disabled = true;
            rejectBtn.disabled = true;

            const feedback = document.getElementById('rev-feedback').value.trim();

            try {
                // review_assignment_self (T10-06A/07): status-переход + recalc недели + серверный
                // reward-гейт (cutover/Stage 4) — одной транзакцией. Owner/тип/scheduled_date и
                // cutover/stage4-флаги теперь читает и проверяет сервер, не клиент; двойной approve
                // не даёт второй серверной награды (идемпотентность внутри
                // record_approved_assignment; с T10-12C daily math не является отдельным квестом).
                const { error } = await db.rpc('review_assignment_self', {
                    p_assignment_id: currentSubmissionId,
                    p_status: status,
                    p_feedback: feedback
                });
                if (error) throw error;

                // Награду (в т.ч. legacy pre-cutover streak-контур) теперь целиком платит сервер
                // внутри review_assignment_self одной транзакцией (T10-06C): при reward_path='legacy'
                // и свежей приёмке gateway сам вызывает settle_legacy_approval. Клиент больше не
                // считает стрик/бонусы/достижения и не делает прямых writes.

                alert(status === 'approved' ? 'Работа принята!' : 'Работа возвращена!');
                closeReview();
                loadSubmissions();
            } catch(e) { alert('Ошибка: ' + e.message); }
            finally { approveBtn.disabled = false; rejectBtn.disabled = false; }
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

            try {
                // apply_penalty_self (T10-06A/07): student выводится сервером из assignment,
                // клиент не передаёт student_id как "доказательство". Кламп нулём и запись
                // фактически списанной суммы — по-прежнему внутри add_huikons (не переписано).
                const { data: result, error: rpcError } = await db.rpc('apply_penalty_self', {
                    p_assignment_id: currentSubmissionId,
                    p_amount: selectedPenalty,
                    p_reason: reason
                });
                if (rpcError) throw rpcError;

                alert(`Списано ${Math.abs(result.actual_change)} ${pluralBubliks(result.actual_change)}. Новый баланс: ${result.new_balance} 🥯`);
                closePenalty();
                closeReview();
            } catch(e) { alert('Ошибка: ' + e.message); }
        }

