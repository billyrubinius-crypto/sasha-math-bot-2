// student-quests.js — блок «Сегодня»: два life-квеста + combo (T10-12C)
        // Все состояния, общий лимит замен, серия и выплаты приходят готовыми из
        // daily_quest_state. Клиент только отображает серверную read-модель.

        let questActionBusy = false; // синхронная защита от двойного клика

        const QUEST_LIFE_META_UNAVAILABLE = 'Испытание дня пока недоступно';

        async function loadTodayQuests() {
            const content = document.getElementById('today-quests-content');
            try {
                const { data, error } = studentSecurePathActive()
                    ? await db.rpc('get_daily_quests_self')
                    : await db.rpc('get_daily_quests', { p_student_id: currentUser.id });
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
                buildLifeRow(state, 1) +
                buildLifeRow(state, 2) +
                buildComboRow(state);
            renderQuestStreak(state.streak_current);
        }

        function buildLifeRow(state, slot) {
            const life = state[`life_${slot}`];
            const paid = !!state[`life_${slot}_paid`];
            const canReplace = !!state[`can_replace_${slot}`];

            if (!life) {
                return `
                    <div class="quest-row">
                        <div class="quest-row-icon">🎲</div>
                        <div class="quest-row-main">
                            <span class="quest-row-title">Челлендж ${slot}</span>
                            <span class="quest-row-meta">${esc(QUEST_LIFE_META_UNAVAILABLE)}</span>
                        </div>
                        <div class="quest-row-trailing"></div>
                    </div>
                `;
            }

            if (paid) {
                return `
                    <div class="quest-row">
                        <div class="quest-row-icon">🎲</div>
                        <div class="quest-row-main">
                            <span class="quest-row-title">${esc(life.name)}</span>
                            ${life.description ? `<span class="quest-row-meta">${esc(life.description)}</span>` : ''}
                        </div>
                        <div class="quest-row-trailing"><span class="quest-badge quest-badge-paid">+3 🥯</span></div>
                    </div>
                `;
            }

            const claimDisabled = !state.generation_active;
            const replaceDisabled = !canReplace;
            const pausedNote = !state.generation_active
                ? '<span class="quest-row-note">Действия временно недоступны</span>'
                : '';

            return `
                <div class="quest-row">
                    <div class="quest-row-icon">🎲</div>
                    <div class="quest-row-main">
                        <span class="quest-row-title">${esc(life.name)}</span>
                        ${life.description ? `<span class="quest-row-meta">${esc(life.description)}</span>` : ''}
                        ${pausedNote}
                    </div>
                    <div class="quest-row-trailing life-row-trailing">
                        <button class="quest-claim-btn" onclick="claimTodayLife(${slot})"
                            ${claimDisabled ? 'disabled' : ''}>Выполнил честно</button>
                        <button class="quest-replace-btn" onclick="replaceTodayLife(${slot})"
                            title="Осталось замен на сегодня: ${state.replacements_left}"
                            ${replaceDisabled ? 'disabled' : ''}>🔁</button>
                    </div>
                </div>
            `;
        }

        function buildComboRow(state) {
            const completed = state.combo_status === 'completed';
            return `
                <div class="quest-row">
                    <div class="quest-row-icon">🎁</div>
                    <div class="quest-row-main">
                        <span class="quest-row-title">Бонус за оба</span>
                        <span class="quest-row-meta">${completed ? 'Начислено' : 'Открывается после двух квестов'}</span>
                    </div>
                    <div class="quest-row-trailing">
                        <span class="quest-badge ${completed ? 'quest-badge-paid' : 'quest-badge-locked'}">+2 🥯</span>
                    </div>
                </div>
            `;
        }

        function renderQuestStreak(streakValue) {
            const streak = Number(streakValue) || 0;
            const streakEl = document.getElementById('streak-display');
            document.getElementById('streak-progress').style.display = 'none';
            if (streak > 0) {
                streakEl.style.display = 'inline-block';
                streakEl.innerText = `🔥 ${streak} дней подряд`;
            } else {
                streakEl.style.display = 'none';
            }
        }

        function setLifeControlsDisabled(disabled) {
            document.querySelectorAll('.life-row-trailing button')
                .forEach(button => { button.disabled = disabled; });
        }

        async function claimTodayLife(slot) {
            if (questActionBusy) return;
            questActionBusy = true;
            setLifeControlsDisabled(true);
            try {
                const { data, error } = studentSecurePathActive()
                    ? await db.rpc('claim_life_quest_self', { p_slot: slot })
                    : await db.rpc('claim_life_quest', {
                        p_student_id: currentUser.id,
                        p_slot: slot
                });
                if (error) throw error;
                await loadProfile();
                renderTodayQuests(data);
            } catch (e) {
                alert('Не удалось подтвердить выполнение: ' + (e.message || e));
                setLifeControlsDisabled(false);
            } finally {
                questActionBusy = false;
            }
        }

        async function replaceTodayLife(slot) {
            if (questActionBusy) return;
            questActionBusy = true;
            setLifeControlsDisabled(true);
            try {
                const { data, error } = studentSecurePathActive()
                    ? await db.rpc('replace_life_quest_self', { p_slot: slot })
                    : await db.rpc('replace_life_quest', {
                        p_student_id: currentUser.id,
                        p_slot: slot
                    });
                if (error) throw error;
                renderTodayQuests(data);
            } catch (e) {
                alert('Не удалось заменить: ' + (e.message || e));
                setLifeControlsDisabled(false);
            } finally {
                questActionBusy = false;
            }
        }
