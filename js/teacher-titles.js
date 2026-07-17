// teacher-titles.js — модерация персональных титулов (R02)
        async function updateCustomTitleCount() {
            const badge = document.getElementById('custom-title-count-badge');
            if (!badge) return;
            const { count, error } = await db
                .from('student_custom_titles')
                .select('student_id', { count: 'exact', head: true })
                .eq('status', 'pending');

            if (error || !count) {
                badge.style.display = 'none';
                badge.textContent = '';
                return;
            }
            badge.textContent = count;
            badge.style.display = 'inline-block';
        }

        async function loadCustomTitleRequests() {
            const list = document.getElementById('custom-title-list');
            list.textContent = '';
            const loading = document.createElement('div');
            loading.style.cssText = 'text-align:center; padding:40px; color:#999;';
            loading.textContent = 'Загрузка заявок...';
            list.appendChild(loading);

            const { data, error } = await db
                .from('student_custom_titles')
                .select('student_id,title_text,submitted_at,students(name,group_name)')
                .eq('status', 'pending')
                .order('submitted_at', { ascending: true });

            list.textContent = '';
            updateCustomTitleCount();
            if (error) {
                const message = document.createElement('div');
                message.style.cssText = 'color:#dc3545; padding:20px; text-align:center;';
                message.textContent = 'Ошибка загрузки: ' + error.message;
                list.appendChild(message);
                return;
            }
            if (!data || !data.length) {
                const empty = document.createElement('div');
                empty.style.cssText = 'text-align:center; padding:40px; color:#999;';
                empty.textContent = 'Нет титулов на модерации';
                list.appendChild(empty);
                return;
            }

            data.forEach(request => list.appendChild(buildCustomTitleCard(request)));
        }

        function buildCustomTitleCard(request) {
            const card = document.createElement('div');
            card.className = 'submission-card custom-title-card';

            const header = document.createElement('div');
            header.className = 'card-header';
            const student = document.createElement('span');
            student.className = 'student-name';
            student.textContent = request.students?.name || 'Ученик';
            const group = document.createElement('span');
            group.className = 'badge';
            group.textContent = request.students?.group_name || 'Без группы';
            header.appendChild(student);
            header.appendChild(group);
            card.appendChild(header);

            const submitted = document.createElement('div');
            submitted.className = 'card-meta';
            submitted.textContent = new Date(request.submitted_at).toLocaleString('ru');
            card.appendChild(submitted);

            const title = document.createElement('div');
            title.className = 'custom-title-value';
            title.textContent = `«${request.title_text}»`;
            card.appendChild(title);

            const actions = document.createElement('div');
            actions.className = 'custom-title-card-actions';
            const approve = document.createElement('button');
            approve.className = 'btn-success';
            approve.textContent = 'Одобрить';
            approve.onclick = () => reviewCustomTitle(request.student_id, 'approved', null, approve);
            const reject = document.createElement('button');
            reject.className = 'btn-danger';
            reject.textContent = 'Отклонить';
            reject.onclick = () => openCustomTitleReject(request.student_id);
            actions.appendChild(approve);
            actions.appendChild(reject);
            card.appendChild(actions);
            return card;
        }

        async function reviewCustomTitle(studentId, decision, comment, btn) {
            if (btn) btn.disabled = true;
            try {
                const { error } = await db.rpc('review_custom_title', {
                    p_student_id: studentId,
                    p_decision: decision,
                    p_teacher_comment: comment
                });
                if (error) throw error;
                closeCustomTitleReject();
                await loadCustomTitleRequests();
                return null;
            } catch (e) {
                if (btn) btn.disabled = false;
                if (decision === 'approved') alert('Не удалось одобрить титул: ' + (e.message || e));
                return e;
            }
        }

        function openCustomTitleReject(studentId) {
            currentCustomTitleStudentId = studentId;
            document.getElementById('custom-title-reject-reason').value = '';
            document.getElementById('custom-title-reject-error').textContent = '';
            document.getElementById('custom-title-reject-submit').disabled = false;
            document.getElementById('custom-title-reject-modal').classList.add('active');
            document.getElementById('custom-title-reject-reason').focus();
        }

        function closeCustomTitleReject() {
            document.getElementById('custom-title-reject-modal').classList.remove('active');
            currentCustomTitleStudentId = null;
        }

        async function submitCustomTitleRejection() {
            if (currentCustomTitleStudentId == null) return;
            const reason = document.getElementById('custom-title-reject-reason').value.trim().replace(/\s+/g, ' ');
            const length = [...reason].length;
            const error = document.getElementById('custom-title-reject-error');
            if (length < 3 || length > 200) {
                error.textContent = 'Причина должна быть от 3 до 200 символов';
                return;
            }

            const studentId = currentCustomTitleStudentId;
            const btn = document.getElementById('custom-title-reject-submit');
            btn.disabled = true;
            error.textContent = '';
            const failure = await reviewCustomTitle(studentId, 'rejected', reason, btn);
            if (failure) {
                error.textContent = failure.message || String(failure);
                btn.disabled = false;
                currentCustomTitleStudentId = studentId;
            }
        }

