// student-quests.js — блок «Сегодня»: math + life квесты Stage 4 (U04)
        // Все состояния (math_status/combo_status/life_paid/can_replace/generation_active)
        // приходят готовыми из daily_quest_state (сервер, миграция 027). Клиент их только
        // отображает: не читает assignments напрямую, не считает eligibility/random/деньги.

        let questActionBusy = false; // синхронная защита от двойного клика (как weekShieldBusy)

        const QUEST_LIFE_META_UNAVAILABLE = 'Испытание дня пока недоступно';

        async function loadTodayQuests() {
            const content = document.getElementById('today-quests-content');
            try {
                const { data, error } = await db.rpc('get_daily_quests', { p_student_id: currentUser.id });
                if (error) throw error;
                renderTodayQuests(data);
            } catch (e) {
                content.innerHTML = '<div class="summary-empty">Не удалось загрузить сегодняшние квесты</div>';
                log('❌ Ошибка квестов дня: ' + (e.message || e));
            }
        }

        function renderTodayQuests(state) {
            const content = document.getElementById('today-quests-content');
            content.innerHTML =
                buildMathRow(state) +
                buildLifeRow(state) +
                buildComboRow(state);
        }

        function buildMathRow(state) {
            const metaByStatus = {
                unavailable:    'Сегодня недоступно',
                active:         'Ждёт решения — открой «Домашку»',
                waiting_review: 'Отправлено, ждёт проверки учителя',
                completed:      'Выполнено'
            };
            const meta = metaByStatus[state.math_status] || metaByStatus.unavailable;
            const badge = state.math_status === 'completed'
                ? '<span class="quest-badge quest-badge-paid">+3 🥯</span>'
                : '';
            return `
                <div class="quest-row">
                    <div class="quest-row-icon">🧮</div>
                    <div class="quest-row-main">
                        <span class="quest-row-title">Математика</span>
                        <span class="quest-row-meta">${esc(meta)}</span>
                    </div>
                    <div class="quest-row-trailing">${badge}</div>
                </div>
            `;
        }

        function buildLifeRow(state) {
            if (!state.life) {
                return `
                    <div class="quest-row">
                        <div class="quest-row-icon">🎲</div>
                        <div class="quest-row-main">
                            <span class="quest-row-title">Челлендж дня</span>
                            <span class="quest-row-meta">${esc(QUEST_LIFE_META_UNAVAILABLE)}</span>
                        </div>
                        <div class="quest-row-trailing"></div>
                    </div>
                `;
            }

            if (state.life_paid) {
                return `
                    <div class="quest-row">
                        <div class="quest-row-icon">🎲</div>
                        <div class="quest-row-main">
                            <span class="quest-row-title">${esc(state.life.name)}</span>
                            ${state.life.description ? `<span class="quest-row-meta">${esc(state.life.description)}</span>` : ''}
                        </div>
                        <div class="quest-row-trailing"><span class="quest-badge quest-badge-paid">+3 🥯</span></div>
                    </div>
                `;
            }

            const claimDisabled = !state.generation_active;
            const replaceDisabled = !state.can_replace;
            const pausedNote = !state.generation_active
                ? '<span class="quest-row-note">Действия временно недоступны</span>'
                : '';

            return `
                <div class="quest-row">
                    <div class="quest-row-icon">🎲</div>
                    <div class="quest-row-main">
                        <span class="quest-row-title">${esc(state.life.name)}</span>
                        ${state.life.description ? `<span class="quest-row-meta">${esc(state.life.description)}</span>` : ''}
                        ${pausedNote}
                    </div>
                    <div class="quest-row-trailing" id="life-row-trailing">
                        <button class="quest-claim-btn" onclick="claimTodayLife()" ${claimDisabled ? 'disabled' : ''}>Выполнил честно</button>
                        <button class="quest-replace-btn" onclick="replaceTodayLife()"
                            title="Осталось замен: ${state.replacements_left}" ${replaceDisabled ? 'disabled' : ''}>🔁</button>
                    </div>
                </div>
            `;
        }

        function buildComboRow(state) {
            const metaByStatus = {
                locked:         'Открывается после обоих квестов',
                waiting_review: 'Челлендж выполнен — бонус ждёт проверки задания',
                completed:      'Начислено'
            };
            const badgeClassByStatus = {
                locked: 'quest-badge-locked',
                waiting_review: 'quest-badge-wait',
                completed: 'quest-badge-paid'
            };
            const status = state.combo_status || 'locked';
            const meta = metaByStatus[status] || metaByStatus.locked;
            const badgeClass = badgeClassByStatus[status] || badgeClassByStatus.locked;
            return `
                <div class="quest-row">
                    <div class="quest-row-icon">🎁</div>
                    <div class="quest-row-main">
                        <span class="quest-row-title">Бонус за оба</span>
                        <span class="quest-row-meta">${esc(meta)}</span>
                    </div>
                    <div class="quest-row-trailing"><span class="quest-badge ${badgeClass}">+2 🥯</span></div>
                </div>
            `;
        }

        function setLifeControlsDisabled(disabled) {
            const trailing = document.getElementById('life-row-trailing');
            if (!trailing) return;
            trailing.querySelectorAll('button').forEach(b => { b.disabled = disabled; });
        }

        async function claimTodayLife() {
            if (questActionBusy) return; // синхронная защита от двойного клика
            questActionBusy = true;
            setLifeControlsDisabled(true);
            try {
                const { data, error } = await db.rpc('claim_life_quest', { p_student_id: currentUser.id });
                if (error) throw error;
                renderTodayQuests(data);
            } catch (e) {
                alert('Не удалось подтвердить выполнение: ' + (e.message || e));
                setLifeControlsDisabled(false);
            } finally {
                questActionBusy = false;
            }
        }

        async function replaceTodayLife() {
            if (questActionBusy) return;
            questActionBusy = true;
            setLifeControlsDisabled(true);
            try {
                const { data, error } = await db.rpc('replace_life_quest', { p_student_id: currentUser.id });
                if (error) throw error;
                renderTodayQuests(data);
            } catch (e) {
                alert('Не удалось заменить: ' + (e.message || e));
                setLifeControlsDisabled(false);
            } finally {
                questActionBusy = false;
            }
        }
