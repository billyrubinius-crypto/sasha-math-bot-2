// teacher-core.js — состояние, helpers, auth/tab-навигация, Supabase bootstrap-глобал (R02, механический вынос)
        // SUPABASE_URL/KEY и CLOUDINARY_* вынесены в shared.js (F4). Здесь только teacher-специфичное.
        const PASS = 'sasha2024';

        // Загружает PDF в Cloudinary и подставляет получившуюся ссылку в указанное поле
        async function handlePdfUpload(event, targetInputId) {
            const file = event.target.files[0];
            if (!file) return;

            const label = event.target.closest('.pdf-upload-btn');
            const targetInput = document.getElementById(targetInputId);

            label.classList.add('uploading');
            try {
                const url = await uploadPdfToCloudinary(file);
                targetInput.value = url;
            } catch (e) {
                alert('Ошибка загрузки PDF: ' + e.message);
            } finally {
                label.classList.remove('uploading');
                event.target.value = '';
            }
        }

        async function uploadPdfToCloudinary(file) {
            const formData = new FormData();
            formData.append('file', file);
            formData.append('upload_preset', CLOUDINARY_UPLOAD_PRESET);
            formData.append('folder', 'sasha-math-tasks');

            const res = await fetch(`https://api.cloudinary.com/v1_1/${CLOUDINARY_CLOUD_NAME}/auto/upload`, {
                method: 'POST',
                body: formData
            });

            if (!res.ok) throw new Error('Ошибка загрузки в Cloudinary');
            const data = await res.json();
            return data.secure_url;
        }

        let db, currentSubmissionId = null, selectedPenalty = -20, studentsList = [];
        let currentCheckView = 'pending';
        let currentCustomTitleStudentId = null;

        // getTodayMSK(), normalizeUrl(), esc(), pluralBubliks() — в shared.js (F4).

        // Переменные для навигации по фото внутри модального окна
        let reviewPhotos = [];
        let reviewPhotoIndex = 0;

        // Переменные для зума и перетаскивания lightbox
        let lbScale = 1;
        let lbPanX = 0;
        let lbPanY = 0;
        let initialDist = 0;
        let initialScale = 1;
        let isPinching = false;
        let isDragging = false;
        let dragStartX = 0;
        let dragStartY = 0;
        let panStartX = 0;
        let panStartY = 0;
        let didDrag = false;

        // Дни недели по номеру day_of_week (1–7), как в weekly_plan_items и assignments.
        const DAY_NAMES = ['', 'Понедельник', 'Вторник', 'Среда', 'Четверг', 'Пятница', 'Суббота', 'Воскресенье'];

        function checkPass() {
            if (document.getElementById('pass').value === PASS) {
                sessionStorage.setItem('auth', '1');
                showApp();
            } else document.getElementById('err').style.display = 'block';
        }

        async function showApp() {
            document.getElementById('login-screen').style.display = 'none';
            await loadStudents();
            loadSubmissions();
            updateCustomTitleCount();
        }

        function switchTab(tab, el) {
            document.querySelectorAll('.tab-btn').forEach(b => b.classList.remove('active'));
            document.querySelectorAll('.content-area').forEach(c => c.classList.remove('active'));
            el.classList.add('active');
            document.getElementById(`tab-${tab}`).classList.add('active');
            
            document.getElementById('sub-tabs-container').style.display = tab === 'check' ? 'flex' : 'none';
            
            if (tab === 'check') loadSubmissions();
            if (tab === 'titles') loadCustomTitleRequests();
        }

        function switchSubTab(view, el) {
            currentCheckView = view;
            document.querySelectorAll('#sub-tabs-container .sub-tab').forEach(b => b.classList.remove('active'));
            el.classList.add('active');
            loadSubmissions();
        }

        function addDaysToDate(dateStr, days) {
            const [y, m, d] = dateStr.split('-').map(Number);
            const result = new Date(Date.UTC(y, m - 1, d + days));
            const yy = result.getUTCFullYear();
            const mm = String(result.getUTCMonth() + 1).padStart(2, '0');
            const dd = String(result.getUTCDate()).padStart(2, '0');
            return `${yy}-${mm}-${dd}`;
        }

        // Календарных дней между двумя датами YYYY-MM-DD (b - a) — Bot 2.0, G10
        function daysBetweenDates(a, b) {
            const [ay, am, ad] = a.split('-').map(Number);
            const [by, bm, bd] = b.split('-').map(Number);
            return Math.round((Date.UTC(by, bm - 1, bd) - Date.UTC(ay, am - 1, ad)) / 86400000);
        }

        // Неделя плана всегда начинается с понедельника (SPEC_STAGE2_5.md §3) — RPC отвергает
        // остальные даты, но понятнее сказать это учителю до отправки.
        function isMonday(dateStr) {
            const [y, m, d] = dateStr.split('-').map(Number);
            return new Date(Date.UTC(y, m - 1, d)).getUTCDay() === 1;
        }

        // Количество задач учитель указывает сам: из названия или PDF его угадывать нельзя.
        // Обязательно для каждого нового слота плана, целое 1–200.
        function parseTaskCount(value, slotLabel) {
            const raw = (value || '').trim();
            if (!raw) throw new Error(`${slotLabel}: укажите количество задач (1–200)`);
            const n = Number(raw);
            if (!Number.isInteger(n) || n < 1 || n > 200) {
                throw new Error(`${slotLabel}: количество задач — целое число от 1 до 200`);
            }
            return n;
        }

