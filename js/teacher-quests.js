// teacher-quests.js — каталог жизненных челленджей Stage 4 (U03)
        // Только справочник life_quest_templates: добавить/изменить текст-категорию-вес,
        // включить/выключить. Никаких имён учеников, completion-счётчиков или life history —
        // это структурно недоступно: RPC этой вкладки трогают только life_quest_templates
        // (SPEC_STAGE4 §9).

        async function loadQuestTemplates() {
            const list = document.getElementById('quest-list');
            list.textContent = '';
            const loading = document.createElement('div');
            loading.style.cssText = 'text-align:center; padding:40px; color:#999;';
            loading.textContent = 'Загрузка каталога...';
            list.appendChild(loading);

            const { data, error } = await db.rpc('admin_list_life_quest_templates');

            list.textContent = '';
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
                empty.textContent = 'Каталог пуст — добавьте первый челлендж';
                list.appendChild(empty);
                return;
            }

            data.forEach(row => list.appendChild(buildQuestCard(row)));
        }

        function buildQuestCard(row) {
            const card = document.createElement('div');
            card.className = 'submission-card quest-card';
            if (!row.active) card.classList.add('quest-card-inactive');

            const header = document.createElement('div');
            header.className = 'card-header';
            const category = document.createElement('span');
            category.className = 'badge quest-category-badge';
            category.textContent = row.category;
            const weight = document.createElement('span');
            weight.className = 'quest-weight';
            weight.textContent = 'вес ' + row.weight;
            header.appendChild(category);
            header.appendChild(weight);
            card.appendChild(header);

            const name = document.createElement('div');
            name.className = 'quest-name';
            name.textContent = row.name;
            card.appendChild(name);

            if (row.description) {
                const desc = document.createElement('div');
                desc.className = 'card-meta quest-description';
                desc.textContent = row.description;
                card.appendChild(desc);
            }

            const code = document.createElement('div');
            code.className = 'quest-code';
            code.textContent = row.template_code;
            card.appendChild(code);

            const actions = document.createElement('div');
            actions.className = 'quest-card-actions';

            const toggleLabel = document.createElement('label');
            toggleLabel.className = 'quest-toggle';
            const toggleInput = document.createElement('input');
            toggleInput.type = 'checkbox';
            toggleInput.checked = !!row.active;
            toggleInput.onchange = () => toggleQuestActive(row.template_code, toggleInput.checked, toggleInput);
            const toggleSlider = document.createElement('span');
            toggleSlider.className = 'quest-toggle-slider';
            toggleLabel.appendChild(toggleInput);
            toggleLabel.appendChild(toggleSlider);
            const toggleText = document.createElement('span');
            toggleText.className = 'quest-toggle-text';
            toggleText.textContent = row.active ? 'Активен' : 'Выключен';
            toggleInput.addEventListener('change', () => {
                toggleText.textContent = toggleInput.checked ? 'Активен' : 'Выключен';
                card.classList.toggle('quest-card-inactive', !toggleInput.checked);
            });

            const edit = document.createElement('button');
            edit.className = 'btn-secondary quest-edit-btn';
            edit.textContent = '✏️ Изменить';
            edit.onclick = () => openQuestModal(row);

            actions.appendChild(toggleLabel);
            actions.appendChild(toggleText);
            actions.appendChild(edit);
            card.appendChild(actions);

            return card;
        }

        // Двойной клик/повтор переключателя не должен вызвать гонку встречных запросов —
        // блокируем сам чекбокс на время запроса, как approve/reject в review-модалке.
        async function toggleQuestActive(code, nextActive, checkboxEl) {
            checkboxEl.disabled = true;
            const { error } = await db.rpc('admin_set_life_quest_template_active_self', {
                p_template_code: code,
                p_active: nextActive
            });
            if (error) {
                alert('Не удалось изменить статус: ' + error.message);
                // Один визуальный откат напрямую, БЕЗ dispatchEvent('change'): иначе повторно
                // сработал бы onchange -> второй admin RPC. Возвращаем checked, подпись и
                // inactive-class руками (U08A: ровно один RPC на действие).
                checkboxEl.checked = !nextActive;
                const card = checkboxEl.closest('.quest-card');
                if (card) {
                    card.classList.toggle('quest-card-inactive', !checkboxEl.checked);
                    const label = card.querySelector('.quest-toggle-text');
                    if (label) label.textContent = checkboxEl.checked ? 'Активен' : 'Выключен';
                }
            }
            checkboxEl.disabled = false;
        }

        function openQuestModal(row) {
            currentQuestCode = row ? row.template_code : null;
            document.getElementById('quest-modal-title').textContent = row ? 'Изменить челлендж' : 'Добавить челлендж';
            document.getElementById('quest-modal-error').style.display = 'none';
            document.getElementById('quest-modal-error').textContent = '';

            const codeInput = document.getElementById('quest-code');
            codeInput.value = row ? row.template_code : '';
            codeInput.disabled = !!row; // код неизменяем после создания (U03)

            document.getElementById('quest-name').value = row ? row.name : '';
            document.getElementById('quest-description').value = row ? (row.description || '') : '';
            document.getElementById('quest-category').value = row ? row.category : '';
            document.getElementById('quest-weight').value = row ? row.weight : 1;

            document.getElementById('quest-modal').classList.add('active');
        }

        function closeQuestModal() {
            document.getElementById('quest-modal').classList.remove('active');
            currentQuestCode = null;
        }

        async function saveQuestTemplate() {
            const errorEl = document.getElementById('quest-modal-error');
            errorEl.style.display = 'none';
            errorEl.textContent = '';

            const code = document.getElementById('quest-code').value.trim();
            const name = document.getElementById('quest-name').value.trim();
            const description = document.getElementById('quest-description').value.trim();
            const category = document.getElementById('quest-category').value.trim();
            const weightRaw = document.getElementById('quest-weight').value;
            const weight = Number(weightRaw);

            if (!code || !name || !category || !Number.isInteger(weight)) {
                errorEl.textContent = 'Заполните обязательные поля: код, текст, категория, целый вес';
                errorEl.style.display = 'block';
                return;
            }

            const btn = document.getElementById('btn-save-quest');
            btn.disabled = true;
            try {
                const { error } = await db.rpc('admin_upsert_life_quest_template_self', {
                    p_template_code: code,
                    p_name: name,
                    p_description: description,
                    p_category: category,
                    p_weight: weight
                });
                if (error) throw error;
                closeQuestModal();
                await loadQuestTemplates();
            } catch (e) {
                errorEl.textContent = e.message || String(e);
                errorEl.style.display = 'block';
            } finally {
                btn.disabled = false;
            }
        }
