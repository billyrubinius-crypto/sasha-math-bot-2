// teacher-app.js — финальная инициализация/оркестрация (R02)
        // Инициализация
        document.addEventListener('DOMContentLoaded', () => {
            // Серверная identity (T10-05/07): db создаётся ТОЛЬКО после успешного логина/резюме
            // сессии (teacher-auth.js), не здесь анонимно. Резюме — по refresh-токену из
            // sessionStorage (переживает reload вкладки); неудача молча остаётся на login-screen.
            tryResumeTeacherSession().then(resumed => { if (resumed) showApp(); });

            // Генерация полей для дней недели
            const container = document.getElementById('days-container');
            DAY_NAMES.slice(1).forEach((day, i) => {
                container.innerHTML += `
                    <div class="day-row">
                        <div class="day-label">${day}</div>
                        <div class="day-inputs">
                            <input type="text" id="day-title-${i}" placeholder="Название задания">
                            <div class="url-with-upload">
                                <input type="url" id="day-url-${i}" placeholder="Ссылка на РешуЕГЭ">
                                <label class="pdf-upload-btn">📎<input type="file" accept="application/pdf" onchange="handlePdfUpload(event, 'day-url-${i}')"></label>
                            </div>
                            <input type="number" id="day-count-${i}" min="1" max="200" step="1" placeholder="Сколько задач в задании (1–200)">
                            <textarea id="day-comment-${i}" placeholder="Комментарий ученику (необязательно)" style="padding:8px; border:1px solid #ddd; border-radius:6px; font-size:13px; width:100%; min-height:40px; resize:none;"></textarea>
                        </div>
                    </div>`;
            });

            // Установка даты активации по умолчанию (следующий понедельник по московскому времени)
            const todayMSKStr = getTodayMSK();
            const [ny, nm, nd] = todayMSKStr.split('-').map(Number);
            const todayWeekday = new Date(Date.UTC(ny, nm - 1, nd)).getUTCDay();
            const daysUntilNextMonday = (1 + 7 - todayWeekday) % 7 || 7;
            document.getElementById('activation-date').value = addDaysToDate(todayMSKStr, daysUntilNextMonday);

            // Понедельник ТЕКУЩЕЙ недели для формы пробника (P02B) — daysUntilNextMonday
            // above уже даёт следующий понедельник; текущий = на 7 дней раньше, если сегодня
            // не сам понедельник (daysUntilNextMonday=7 → сегодня понедельник → 0 назад).
            document.getElementById('mock-week').value =
                addDaysToDate(todayMSKStr, daysUntilNextMonday === 7 ? 0 : daysUntilNextMonday - 7);

            // === ЗУМ И ПЕРЕТАСКИВАНИЕ ДЛЯ LIGHTBOX ===
            const lbImg = document.getElementById('lb-img');
            const lbWrapper = document.getElementById('lightbox');

            // 1. Зум колесиком мыши (ПК)
            lbWrapper.addEventListener('wheel', (e) => {
                e.preventDefault();
                const delta = e.deltaY > 0 ? 0.9 : 1.1;
                applyZoom(delta);
            }, { passive: false });

            // 2. Перетаскивание мышью (ПК)
            lbImg.addEventListener('mousedown', (e) => {
                if (lbScale <= 1 || e.button !== 0) return;
                e.preventDefault();
                isDragging = true;
                didDrag = false;
                dragStartX = e.clientX;
                dragStartY = e.clientY;
                panStartX = lbPanX;
                panStartY = lbPanY;
                lbImg.classList.add('dragging');
                lbImg.style.transition = 'none';
            });

            window.addEventListener('mousemove', (e) => {
                if (!isDragging) return;
                e.preventDefault();
                const dx = e.clientX - dragStartX;
                const dy = e.clientY - dragStartY;
                if (Math.abs(dx) > 3 || Math.abs(dy) > 3) didDrag = true;
                lbPanX = panStartX + dx;
                lbPanY = panStartY + dy;
                constrainPan();
                updateLightboxTransform();
            });

            window.addEventListener('mouseup', () => {
                if (!isDragging) return;
                isDragging = false;
                lbImg.classList.remove('dragging');
                lbImg.style.transition = 'transform 0.3s cubic-bezier(0.25, 0.46, 0.45, 0.94)';
                if (didDrag) setTimeout(() => { didDrag = false; }, 150);
            });

            // 3. Тач: зум двумя пальцами и перетаскивание одним при зуме
            lbWrapper.addEventListener('touchstart', (e) => {
                if (e.touches.length === 2) {
                    e.preventDefault();
                    isPinching = true;
                    isDragging = false;
                    initialDist = Math.hypot(
                        e.touches[0].pageX - e.touches[1].pageX,
                        e.touches[0].pageY - e.touches[1].pageY
                    );
                    initialScale = lbScale;
                    lbImg.style.transition = 'none';
                } else if (e.touches.length === 1 && lbScale > 1) {
                    isDragging = true;
                    didDrag = false;
                    dragStartX = e.touches[0].clientX;
                    dragStartY = e.touches[0].clientY;
                    panStartX = lbPanX;
                    panStartY = lbPanY;
                    lbImg.style.transition = 'none';
                }
            }, { passive: false });

            lbWrapper.addEventListener('touchmove', (e) => {
                if (isPinching && e.touches.length === 2) {
                    e.preventDefault();
                    const dist = Math.hypot(
                        e.touches[0].pageX - e.touches[1].pageX,
                        e.touches[0].pageY - e.touches[1].pageY
                    );

                    lbScale = Math.min(Math.max(initialScale * (dist / initialDist), 1), 4);
                    if (lbScale <= 1) {
                        lbPanX = 0;
                        lbPanY = 0;
                    } else {
                        constrainPan();
                    }
                    updateLightboxTransform();
                } else if (isDragging && e.touches.length === 1 && lbScale > 1) {
                    e.preventDefault();
                    const dx = e.touches[0].clientX - dragStartX;
                    const dy = e.touches[0].clientY - dragStartY;
                    if (Math.abs(dx) > 3 || Math.abs(dy) > 3) didDrag = true;
                    lbPanX = panStartX + dx;
                    lbPanY = panStartY + dy;
                    constrainPan();
                    updateLightboxTransform();
                }
            }, { passive: false });

            lbWrapper.addEventListener('touchend', () => {
                if (isPinching) {
                    isPinching = false;
                    lbImg.style.transition = 'transform 0.3s cubic-bezier(0.25, 0.46, 0.45, 0.94)';
                    if (lbScale <= 1) resetZoom();
                    else constrainPan();
                }
                if (isDragging) {
                    isDragging = false;
                    lbImg.style.transition = 'transform 0.3s cubic-bezier(0.25, 0.46, 0.45, 0.94)';
                    if (didDrag) setTimeout(() => { didDrag = false; }, 150);
                }
            });
        });

