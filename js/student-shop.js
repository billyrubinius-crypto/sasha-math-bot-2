// student-shop.js — магазин, коллекции, витрина/showcase, щиты, персональный титул (R01)
        // Показываются ВСЕ сезоны, у которых есть бандл — и закрытые, и текущий открытый: не
        // купленные предметы текущего сезона тоже стоит видеть силуэтами, это подталкивает купить.
        //
        // Проверка «коллекция закрыта» — здесь, при загрузке альбома, а не в buyShopItem (S2):
        // не дублирует группировку «бандл → сезон» во втором месте и не трогает файл S2. Цена —
        // бонус приходит не в момент покупки последнего предмета, а при следующем открытии
        // профиля; это осознанный компромисс простоты, не баг.
        async function loadCollections() {
            const section = document.getElementById('collections-section');
            const wrap = document.getElementById('collections-list');
            try {
                const { data: bundles, error } = await db
                    .from('season_bundles')
                    .select('season_id, bundle')
                    .order('season_id', { ascending: false });
                if (error) throw error;
                if (!bundles || !bundles.length) { section.style.display = 'none'; return; }

                const [{ data: rotationItems }, { data: owned }] = await Promise.all([
                    db.from('shop_items').select('item_code,name,rotation_bundle,slot,item_kind,render_payload').eq('availability', 'rotation'),
                    db.from('student_items').select('item_code').eq('student_id', currentUser.id)
                ]);
                const ownedSet = new Set((owned || []).map(r => r.item_code));
                const itemsByBundle = {};
                (rotationItems || []).forEach(i => { (itemsByBundle[i.rotation_bundle] = itemsByBundle[i.rotation_bundle] || []).push(i); });

                wrap.innerHTML = '';
                for (const b of bundles) {
                    const items = itemsByBundle[b.bundle] || [];
                    if (!items.length) continue; // бандл без товаров — не показываем (риск карточки)

                    const block = document.createElement('div');
                    block.className = 'collection-block';
                    const title = document.createElement('div');
                    title.className = 'collection-season-title';
                    title.textContent = `Сезон №${b.season_id}`;
                    block.appendChild(title);

                    const grid = document.createElement('div');
                    grid.className = 'coll-grid';
                    items.forEach(item => {
                        const has = ownedSet.has(item.item_code);
                        const tile = document.createElement('div');
                        tile.className = `coll-tile ${has ? '' : 'locked'}`;
                        tile.appendChild(shopPreview(item));
                        const name = document.createElement('div');
                        name.className = 'coll-name';
                        name.textContent = item.name;
                        tile.appendChild(name);
                        grid.appendChild(tile);
                    });
                    block.appendChild(grid);
                    wrap.appendChild(block);

                    if (items.every(i => ownedSet.has(i.item_code))) {
                        await grantCollectionBonus(b.season_id);
                    }
                }
                section.style.display = '';

            } catch (e) {
                section.style.display = 'none';
                log('❌ Ошибка коллекций: ' + e.message);
            }
        }

        // Идемпотентная выдача бонуса за закрытую коллекцию сезона.
        // secure path (JWT активен) — через claim_collection_bonus_self (T10-06D): сервер САМ
        // проверяет полноту коллекции (анти-фарм) и идемпотентно начисляет достижение + 50; клиент
        // не делает прямых writes и не передаёт student_id. Legacy fallback (shadow без JWT) —
        // прежний прямой insert + add_huikons: награда только если строка реально вставилась,
        // конфликт unique(student_id, achievement_code) = уже выдано, no-op.
        async function grantCollectionBonus(seasonId) {
            if (studentSecurePathActive()) {
                const { error } = await db.rpc('claim_collection_bonus_self', { p_season_id: seasonId });
                if (error) throw error;
                return;
            }

            const code = `collection_season_${seasonId}`;
            const { data, error } = await db.from('student_achievements')
                .insert({ student_id: currentUser.id, achievement_code: code })
                .select();
            if (error) {
                if (error.code === '23505') return;
                throw error;
            }
            if (!data || !data.length) return;

            const { error: rpcError } = await db.rpc('add_huikons', {
                p_student_id: currentUser.id, p_amount: 50, p_reason: `achievement_${code}`
            });
            if (rpcError) throw rpcError;
        }

        // Витрина профиля (S7, GAME_DESIGN.md §13): 3 слота, каждый — предмет ИЗ КУПЛЕННОГО
        // или достижение ИЗ ПОЛУЧЕННОГО (student_showcase, миграция 009 — отдельная таблица,
        // не student_equipment: там item_code жёстко ссылается на shop_items, а сюда нужны ещё
        // и achievement_code из другого пространства кодов). Известное ограничение (осознанно,
        // SPEC_STAGE2 раздел 5): чужие профили не открываются, витрину видит только владелец.
        let showcaseOpenPosition = null;

        async function loadShowcase() {
            const section = document.getElementById('showcase-section');
            const grid = document.getElementById('showcase-grid');
            document.getElementById('showcase-picker').style.display = 'none';
            showcaseOpenPosition = null;
            try {
                const { data: slots, error } = await db.from('student_showcase')
                    .select('position,kind,ref_code').eq('student_id', currentUser.id);
                if (error) throw error;
                const bySlot = new Map((slots || []).map(s => [s.position, s]));

                const itemCodes = (slots || []).filter(s => s.kind === 'item').map(s => s.ref_code);
                let itemsByCode = {};
                if (itemCodes.length) {
                    const { data: items } = await db.from('shop_items')
                        .select('item_code,name,slot,item_kind,render_payload').in('item_code', itemCodes);
                    (items || []).forEach(i => { itemsByCode[i.item_code] = i; });
                }

                grid.innerHTML = '';
                for (let pos = 1; pos <= 3; pos++) {
                    const slot = bySlot.get(pos);
                    const tile = document.createElement('div');
                    tile.onclick = () => openShowcasePicker(pos);

                    if (!slot) {
                        tile.className = 'showcase-tile empty';
                        tile.innerHTML = '<div class="showcase-icon">+</div>';
                    } else if (slot.kind === 'achievement') {
                        const meta = ACHIEVEMENTS_META.find(a => a.code === slot.ref_code);
                        tile.className = 'showcase-tile';
                        const icon = document.createElement('div');
                        icon.className = 'showcase-icon';
                        icon.textContent = meta ? meta.icon : '🏆';
                        const name = document.createElement('div');
                        name.className = 'showcase-name';
                        name.textContent = meta ? meta.name : slot.ref_code;
                        tile.appendChild(icon);
                        tile.appendChild(name);
                    } else {
                        const item = itemsByCode[slot.ref_code];
                        tile.className = 'showcase-tile';
                        if (item) {
                            tile.appendChild(shopPreview(item));
                            const name = document.createElement('div');
                            name.className = 'showcase-name';
                            name.textContent = item.name;
                            tile.appendChild(name);
                        }
                    }
                    grid.appendChild(tile);
                }
                section.style.display = '';

            } catch (e) {
                section.style.display = 'none';
                log('❌ Ошибка витрины: ' + e.message);
            }
        }

        // Пикер под сеткой: купленные предметы + полученные достижения как список кнопок,
        // плюс «Убрать», если слот уже занят. Один открытый пикер за раз (повторный клик по
        // тому же слоту закрывает панель).
        async function openShowcasePicker(position) {
            const panel = document.getElementById('showcase-picker');
            if (showcaseOpenPosition === position) {
                panel.style.display = 'none';
                showcaseOpenPosition = null;
                return;
            }
            showcaseOpenPosition = position;
            panel.style.display = '';
            panel.innerHTML = '<div class="showcase-picker-empty">Загрузка...</div>';

            // student_items.item_code без FK на shop_items (таблица старше магазина, G3 до S1) —
            // PostgREST embed здесь не сработает, имена подтягиваем отдельным запросом и мапом.
            const [{ data: owned }, { data: earned }] = await Promise.all([
                db.from('student_items').select('item_code').eq('student_id', currentUser.id),
                db.from('student_achievements').select('achievement_code').eq('student_id', currentUser.id)
            ]);
            let ownedNames = {};
            if (owned && owned.length) {
                const { data: catalogRows } = await db.from('shop_items').select('item_code,name').in('item_code', owned.map(o => o.item_code));
                (catalogRows || []).forEach(r => { ownedNames[r.item_code] = r.name; });
            }

            panel.innerHTML = '';
            const title = document.createElement('div');
            title.className = 'showcase-picker-title';
            title.textContent = `Слот ${position}: выбери предмет или достижение`;
            panel.appendChild(title);

            const clearBtn = document.createElement('button');
            clearBtn.className = 'showcase-chip showcase-chip-clear';
            clearBtn.textContent = '✕ Убрать из витрины';
            clearBtn.onclick = () => setShowcase(position, null, null);
            panel.appendChild(clearBtn);

            if ((!owned || !owned.length) && (!earned || !earned.length)) {
                const empty = document.createElement('div');
                empty.className = 'showcase-picker-empty';
                empty.textContent = 'Пока нечего выставить — купи что-нибудь в магазине или получи достижение';
                panel.appendChild(empty);
                return;
            }

            (owned || []).forEach(o => {
                const chip = document.createElement('button');
                chip.className = 'showcase-chip';
                chip.textContent = `🥯 ${ownedNames[o.item_code] || o.item_code}`;
                chip.onclick = () => setShowcase(position, 'item', o.item_code);
                panel.appendChild(chip);
            });
            (earned || []).forEach(a => {
                const meta = ACHIEVEMENTS_META.find(m => m.code === a.achievement_code);
                const chip = document.createElement('button');
                chip.className = 'showcase-chip';
                chip.textContent = `${meta ? meta.icon : '🏆'} ${meta ? meta.name : a.achievement_code}`;
                chip.onclick = () => setShowcase(position, 'achievement', a.achievement_code);
                panel.appendChild(chip);
            });
        }

        async function setShowcase(position, kind, refCode) {
            try {
                // secure path (JWT активен) — через claim-based gateway set_showcase_self без
                // p_student_id (identity из claim; T10-04B). Legacy fallback — прежний RPC.
                const { error } = studentSecurePathActive()
                    ? await db.rpc('set_showcase_self', {
                        p_position: position, p_kind: kind, p_ref_code: refCode
                    })
                    : await db.rpc('set_showcase', {
                        p_student_id: currentUser.id, p_position: position, p_kind: kind, p_ref_code: refCode
                    });
                if (error) throw error;
                await loadShowcase();
            } catch (e) {
                alert('Не удалось: ' + (e.message || e));
            }
        }

        // Щит (G9): счётчик в запасе + кнопка покупки. Лимит 7 щитов, цена 90 бубликов —
        // проверка и списание атомарны в RPC buy_streak_shield (teacher-логика та же таблица
        // student_items). Кнопка блокируется при лимите; сама покупка защищена RPC от гонки.
        // Цена/лимит подняты миграцией 012 (W04) — значения ниже обязаны совпадать с RPC.
        const SHIELD_MAX = 7, SHIELD_PRICE = 90;

        function pluralShields(n) {
            const mod10 = n % 10, mod100 = n % 100;
            if (mod10 === 1 && mod100 !== 11) return 'щит';
            if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) return 'щита';
            return 'щитов';
        }

        async function loadShields() {
            const widget = document.getElementById('shield-widget');
            const countEl = document.getElementById('shield-count');
            const btn = document.getElementById('btn-buy-shield');
            try {
                const { data, error } = await db
                    .from('student_items')
                    .select('quantity')
                    .eq('student_id', currentUser.id)
                    .eq('item_code', 'streak_shield')
                    .maybeSingle();
                if (error) throw error;

                const qty = data ? data.quantity : 0;
                countEl.innerText = `🛡 ${qty} ${pluralShields(qty)}`;
                btn.disabled = qty >= SHIELD_MAX;
                btn.innerText = qty >= SHIELD_MAX
                    ? `Лимит ${SHIELD_MAX} ${pluralShields(SHIELD_MAX)}`
                    : `Купить — ${SHIELD_PRICE} 🥯`;
                widget.style.display = '';

            } catch (e) {
                widget.style.display = 'none';
                log('❌ Ошибка щитов: ' + e.message);
            }
        }

        async function buyStreakShield() {
            const btn = document.getElementById('btn-buy-shield');
            btn.disabled = true;
            try {
                // secure path — gateway buy_streak_shield_self без p_student_id (T10-04B);
                // legacy fallback — прежний RPC. Лимит/цена/списание — в базовой функции.
                const { data, error } = studentSecurePathActive()
                    ? await db.rpc('buy_streak_shield_self')
                    : await db.rpc('buy_streak_shield', { p_student_id: currentUser.id });
                if (error) throw error;
                // Обновляем баланс и счётчик щитов по факту покупки
                document.getElementById('val-huikons').innerText = data.balance;
                await loadShields();
                loadBalanceHistory();
            } catch (e) {
                alert('Не удалось купить щит: ' + (e.message || e));
                btn.disabled = false;
            }
        }

        // --- МАГАЗИН «БУБЛИЧНАЯ» (S2) ---
        // Витрина строится из каталога shop_items (не хардкод). Ротационные товары показываются
        // только для бандла текущего сезона (ensure_season_rotation, S1). Покупка — через RPC
        // buy_item (щит делегируется в buy_streak_shield внутри RPC, здесь один путь).
        // Динамика строится через DOM (textContent), а не innerHTML-строками — payload и названия
        // товаров не могут исполниться как разметка.

        // Склонение «день/дня/дней» для плашки «уйдёт через N дней» (S4)
        function pluralDays(n) {
            const abs = Math.abs(n);
            const mod10 = abs % 10, mod100 = abs % 100;
            if (mod10 === 1 && mod100 !== 11) return 'день';
            if (mod10 >= 2 && mod10 <= 4 && (mod100 < 10 || mod100 >= 20)) return 'дня';
            return 'дней';
        }

        // Сезон = 2 недели (SPEC_STAGE1.md раздел 3). Оценочный отсчёт от start_date по МСК —
        // информационная плашка, не гарантия: реальное закрытие сезона — ручное нажатие кнопки
        // учителем (close_season, G8), может случиться позже расчётных 14 дней. Клампим нулём,
        // чтобы просроченный, но ещё не закрытый сезон не показывал отрицательные дни.
        function daysLeftInSeason(startDate) {
            const [sy, sm, sd] = startDate.split('-').map(Number);
            const [ty, tm, td] = getTodayMSK().split('-').map(Number);
            const elapsed = Math.round((Date.UTC(ty, tm - 1, td) - Date.UTC(sy, sm - 1, sd)) / 86400000);
            return Math.max(0, 14 - elapsed);
        }

        async function loadShop() {
            const content = document.getElementById('shop-content');
            const balanceEl = document.getElementById('shop-balance');
            content.innerHTML = '<div style="text-align:center; padding:30px; opacity:0.5;">Загрузка...</div>';
            try {
                const [itemsRes, bundleRes, ownedRes, achRes, stRes, eqRes, seasonRes, customTitleRes] = await Promise.all([
                    db.from('shop_items')
                        .select('item_code,name,item_kind,slot,price,availability,rotation_bundle,condition_achievement,render_payload')
                        .eq('active', true).order('sort_order'),
                    db.rpc('ensure_season_rotation'),
                    db.from('student_items').select('item_code,quantity').eq('student_id', currentUser.id),
                    db.from('student_achievements').select('achievement_code').eq('student_id', currentUser.id),
                    db.from('students').select('huikons').eq('telegram_id', currentUser.id).single(),
                    db.from('student_equipment').select('slot,item_code').eq('student_id', currentUser.id),
                    // Только для плашки «уйдёт через N дней» (S4) — не создаёт сезон, ensure_season_rotation
                    // и getCurrentSeasonId (лидерборд) уже отвечают за ленивое создание.
                    db.from('seasons').select('start_date').is('end_date', null).order('id', { ascending: false }).limit(1).maybeSingle(),
                    db.from('student_custom_titles')
                        .select('title_text,status,teacher_comment')
                        .eq('student_id', currentUser.id).maybeSingle()
                ]);
                if (itemsRes.error) throw itemsRes.error;
                if (customTitleRes.error) throw customTitleRes.error;

                const items = itemsRes.data || [];
                const currentBundle = bundleRes.data;              // null, если сезона/пула нет
                const owned = new Map((ownedRes.data || []).map(r => [r.item_code, r.quantity]));
                const earned = new Set((achRes.data || []).map(r => r.achievement_code));
                const balance = stRes.data ? stRes.data.huikons : 0;
                // slot → item_code надетого предмета (для кнопок Надеть/Снять на купленном)
                const equippedBySlot = new Map((eqRes.data || []).map(r => [r.slot, r.item_code]));
                const daysLeft = seasonRes.data ? daysLeftInSeason(seasonRes.data.start_date) : null;
                const customTitle = customTitleRes.data || null;
                balanceEl.innerText = `Баланс: ${balance} ${pluralBubliks(balance)} 🥯`;

                const rotation = items.filter(i => i.availability === 'rotation' && i.rotation_bundle === currentBundle);
                const always = items.filter(i => i.availability === 'always');

                content.innerHTML = '';
                if (rotation.length) {
                    content.appendChild(shopSectionTitle('✨ Витрина сезона',
                        'Сезонные товары уходят с витрины в конце сезона — потом их не купить'));
                    rotation.forEach(i => content.appendChild(renderShopItem(i, owned, earned, balance, equippedBySlot, daysLeft, customTitle)));
                } else {
                    // Пул ротации исчерпан (все бандлы уже были на витрине в прошлых сезонах) —
                    // явное сообщение вместо молчаливого исчезновения секции (риск из карточки S4).
                    content.appendChild(shopSectionTitle('✨ Витрина сезона', 'Сезонных товаров сейчас нет — загляните в следующем сезоне'));
                }
                content.appendChild(shopSectionTitle('🥯 Всегда в магазине', ''));
                always.forEach(i => content.appendChild(renderShopItem(i, owned, earned, balance, equippedBySlot, null, customTitle)));

            } catch (e) {
                content.innerHTML = '<div style="text-align:center; padding:30px; color:#f44336;">Ошибка загрузки магазина</div>';
                log('❌ Магазин: ' + (e.message || e));
            }
        }

        function shopSectionTitle(title, note) {
            const wrap = document.createElement('div');
            const t = document.createElement('div');
            t.className = 'shop-section-title';
            t.textContent = title;
            wrap.appendChild(t);
            if (note) {
                const n = document.createElement('div');
                n.className = 'shop-section-note';
                n.textContent = note;
                wrap.appendChild(n);
            }
            return wrap;
        }

        function shopPreview(item) {
            const p = document.createElement('div');
            p.className = 'shop-preview';
            p.classList.add(`shop-preview-${item.slot || item.item_kind || 'item'}`);
            p.dataset.itemCode = item.item_code || '';
            if (item.slot === 'name_color') {
                if (item.render_payload === 'gold') {
                    p.style.background = 'linear-gradient(135deg,#f9d423,#e6a817)';
                } else if (/^#[0-9a-fA-F]{6}$/.test(item.render_payload || '')) {
                    p.style.background = item.render_payload;   // валидный hex — иначе не трогаем
                }
                p.style.color = '#fff';
                p.textContent = 'Aa';
            } else if (item.slot === 'background') {
                const backgrounds = {
                    bg_grid: 'linear-gradient(135deg,#202b4d 25%,#32456d 25%,#32456d 50%,#202b4d 50%,#202b4d 75%,#32456d 75%)',
                    bg_space: 'radial-gradient(circle at 30% 25%,#fff 0 1px,transparent 2px), linear-gradient(135deg,#17152f,#35255c)',
                    bg_aurora: 'linear-gradient(135deg,#174b52,#4f2e6c 55%,#d07b48)',
                    bg_draft: 'linear-gradient(135deg,#e7e2d6,#b8c5cc)'
                };
                p.style.background = backgrounds[item.item_code] || 'linear-gradient(135deg,#475569,#94a3b8)';
                p.innerHTML = '<span class="shop-preview-avatar">●</span>';
            } else if (item.slot === 'frame') {
                p.innerHTML = '<span class="shop-preview-avatar shop-preview-frame">🙂</span>';
            } else if (item.slot === 'crown') {
                p.innerHTML = '<span class="shop-preview-crown">♛</span><span class="shop-preview-avatar">🙂</span>';
            } else if (item.slot === 'title') {
                p.innerHTML = '<span class="shop-preview-title-mark">Aa</span><span class="shop-preview-title-line"></span>';
            } else if (item.slot === 'status_emoji') {
                p.textContent = (item.render_payload || '').split(/\s+/).filter(Boolean)[0] || '🙂';
            } else {
                const icons = { crown: '👑', title: '🏷️', frame: '🖼️', background: '🎨', status_emoji: '😀' };
                p.textContent = item.item_kind === 'shield' ? '🛡️' : (icons[item.slot] || '🥯');
            }
            return p;
        }

        function shopBuyButton(item, balance, variant) {
            const btn = document.createElement('button');
            btn.className = 'shop-buy-btn';
            if (balance < item.price) {
                btn.disabled = true;
                btn.textContent = 'Не хватает';
            } else {
                btn.textContent = 'Купить';
                btn.onclick = () => buyShopItem(item.item_code, variant || null, btn);
            }
            return btn;
        }

        function renderShopItem(item, owned, earned, balance, equippedBySlot, daysLeft, customTitle) {
            const row = document.createElement('div');
            row.className = 'shop-item';
            row.appendChild(shopPreview(item));

            const body = document.createElement('div');
            body.className = 'shop-body';
            const name = document.createElement('div');
            name.className = 'shop-name';
            name.textContent = item.name;
            body.appendChild(name);
            const desc = document.createElement('div');
            desc.className = 'shop-desc';
            desc.textContent = `${item.price} ${pluralBubliks(item.price)} 🥯`;
            body.appendChild(desc);
            if (item.availability === 'rotation' && daysLeft != null) {
                const leaving = document.createElement('div');
                leaving.className = 'shop-desc shop-leaving';
                leaving.textContent = daysLeft > 0 ? `Уйдёт с витрины через ${daysLeft} ${pluralDays(daysLeft)}` : 'Уходит с витрины со дня на день';
                body.appendChild(leaving);
            }
            row.appendChild(body);

            const action = document.createElement('div');
            action.className = 'shop-action';

            if (item.item_code === 'title_custom' && customTitle && customTitle.status !== 'approved') {
                const entered = document.createElement('div');
                entered.className = 'custom-title-text';
                entered.textContent = `«${customTitle.title_text}»`;
                body.appendChild(entered);

                if (customTitle.status === 'pending') {
                    const state = document.createElement('span');
                    state.className = 'shop-state locked';
                    state.textContent = 'На модерации';
                    action.appendChild(state);
                } else {
                    const reason = document.createElement('div');
                    reason.className = 'custom-title-reason';
                    reason.textContent = `Причина: ${customTitle.teacher_comment || 'нужно исправить текст'}`;
                    body.appendChild(reason);
                    const btn = document.createElement('button');
                    btn.className = 'shop-buy-btn';
                    btn.textContent = 'Исправить';
                    btn.onclick = () => openCustomTitleModal(customTitle.title_text, true);
                    action.appendChild(btn);
                }
            } else if (item.item_code === 'title_custom' && !customTitle) {
                const btn = document.createElement('button');
                btn.className = 'shop-buy-btn';
                btn.disabled = balance < item.price;
                btn.textContent = balance < item.price ? 'Не хватает' : 'Создать';
                if (!btn.disabled) btn.onclick = () => openCustomTitleModal('', false);
                action.appendChild(btn);
            } else if (item.item_kind === 'service') {
                // Смена эмодзи-статуса: выбор варианта = покупка (30 🥯 за смену)
                const chips = document.createElement('div');
                chips.className = 'shop-emoji-chips';
                (item.render_payload || '').split(/\s+/).filter(Boolean).forEach(em => {
                    const chip = document.createElement('button');
                    chip.className = 'shop-emoji-chip';
                    chip.textContent = em;
                    chip.disabled = balance < item.price;
                    chip.onclick = () => buyShopItem(item.item_code, em, chip);
                    chips.appendChild(chip);
                });
                body.appendChild(chips);
            } else if (item.item_kind === 'shield') {
                const qty = owned.get('streak_shield') || 0;
                if (qty >= SHIELD_MAX) {
                    const s = document.createElement('span');
                    s.className = 'shop-state owned';
                    s.textContent = `🛡 ${qty}/${SHIELD_MAX}`;
                    action.appendChild(s);
                } else {
                    const label = document.createElement('div');
                    label.className = 'shop-desc';
                    label.style.marginBottom = '4px';
                    label.textContent = `в запасе: ${qty}/${SHIELD_MAX}`;
                    action.appendChild(label);
                    action.appendChild(shopBuyButton(item, balance));
                }
            } else {
                // Косметика
                if (owned.has(item.item_code)) {
                    // Куплено: показываем «Надето»/«Снять» или «Надеть» (переключение бесплатно, S3)
                    const isEquipped = equippedBySlot && equippedBySlot.get(item.slot) === item.item_code;
                    if (isEquipped) {
                        const s = document.createElement('span');
                        s.className = 'shop-equipped';
                        s.textContent = '✓ Надето';
                        action.appendChild(s);
                        const btn = document.createElement('button');
                        btn.className = 'shop-equip-btn';
                        btn.textContent = 'Снять';
                        btn.onclick = () => equipShopItem(item.slot, null, btn);
                        action.appendChild(btn);
                    } else {
                        const s = document.createElement('span');
                        s.className = 'shop-state owned';
                        s.textContent = '✓ Куплено';
                        s.style.display = 'block';
                        s.style.marginBottom = '4px';
                        action.appendChild(s);
                        const btn = document.createElement('button');
                        btn.className = 'shop-equip-btn';
                        btn.textContent = 'Надеть';
                        btn.onclick = () => equipShopItem(item.slot, item.item_code, btn);
                        action.appendChild(btn);
                    }
                } else if (item.condition_achievement && !earned.has(item.condition_achievement)) {
                    // Условный товар (S5): замок с названием нужного достижения, не голое «Условие» —
                    // проверка владения/условия здесь только косметическая, реальный gate — в buy_item (S1).
                    const meta = ACHIEVEMENTS_META.find(a => a.code === item.condition_achievement);
                    const s = document.createElement('span');
                    s.className = 'shop-state locked';
                    s.textContent = `🔒 Нужно: ${meta ? meta.name : item.condition_achievement}`;
                    action.appendChild(s);
                } else {
                    action.appendChild(shopBuyButton(item, balance));
                }
            }
            row.appendChild(action);
            return row;
        }

        async function buyShopItem(itemCode, variant, btn) {
            if (btn) btn.disabled = true;
            try {
                // secure path — gateway buy_item_self без p_student_id (T10-04B); legacy fallback —
                // прежний RPC. Цена/бандл/pay-once/списание — в базовой buy_item.
                const { data, error } = studentSecurePathActive()
                    ? await db.rpc('buy_item_self', { p_item_code: itemCode, p_variant: variant })
                    : await db.rpc('buy_item', {
                        p_student_id: currentUser.id, p_item_code: itemCode, p_variant: variant
                    });
                if (error) throw error;
                // Синхронизируем баланс на профиле, если он уже отрисован
                const vh = document.getElementById('val-huikons');
                if (vh && data && data.balance != null) vh.innerText = data.balance;
                await loadShop();              // перерисовка витрины с новым балансом/владением
                loadBalanceHistory();
            } catch (e) {
                alert('Не удалось купить: ' + (e.message || e));
                if (btn) btn.disabled = false;
            }
        }

        let customTitleIsRetry = false;

        function customTitleValue() {
            return document.getElementById('custom-title-input').value.trim().replace(/\s+/g, ' ');
        }

        function openCustomTitleModal(value, isRetry) {
            customTitleIsRetry = !!isRetry;
            const input = document.getElementById('custom-title-input');
            input.value = value || '';
            document.getElementById('custom-title-help').textContent = customTitleIsRetry
                ? 'Исправление после отказа бесплатно. Новый текст снова проверит учитель.'
                : 'После отправки спишется 2000 бубликов. Учитель проверит текст до публикации.';
            document.getElementById('custom-title-submit').textContent = customTitleIsRetry
                ? 'Отправить повторно'
                : 'Отправить — 2000 🥯';
            document.getElementById('custom-title-error').textContent = '';
            document.getElementById('custom-title-modal').classList.add('active');
            updateCustomTitleForm();
            input.focus();
        }

        function closeCustomTitleModal() {
            document.getElementById('custom-title-modal').classList.remove('active');
        }

        function updateCustomTitleForm() {
            const value = customTitleValue();
            const length = [...value].length;
            document.getElementById('custom-title-count').textContent = `${length}/24`;
            document.getElementById('custom-title-preview').textContent = value ? `«${value}»` : '';
            document.getElementById('custom-title-submit').disabled = length < 3 || length > 24;
            document.getElementById('custom-title-error').textContent = length > 24 ? 'Сократи титул до 24 символов' : '';
        }

        async function submitCustomTitle() {
            const title = customTitleValue();
            const length = [...title].length;
            if (length < 3 || length > 24) return updateCustomTitleForm();

            const btn = document.getElementById('custom-title-submit');
            btn.disabled = true;
            document.getElementById('custom-title-error').textContent = '';
            try {
                // secure path — gateway submit_custom_title_self без p_student_id (T10-04B);
                // legacy fallback — прежний RPC. Валидация/цена/pay-once — в базовой функции.
                const { data, error } = studentSecurePathActive()
                    ? await db.rpc('submit_custom_title_self', { p_title_text: title })
                    : await db.rpc('submit_custom_title', {
                        p_student_id: currentUser.id,
                        p_title_text: title
                    });
                if (error) throw error;
                const balance = document.getElementById('val-huikons');
                if (balance && data && data.balance != null) balance.innerText = data.balance;
                closeCustomTitleModal();
                await loadShop();
                if (!customTitleIsRetry) loadBalanceHistory();
            } catch (e) {
                document.getElementById('custom-title-error').textContent = e.message || String(e);
                btn.disabled = false;
            }
        }

        // Надеть/снять купленный предмет (S3). itemCode=null → снять слот. Переключение бесплатно,
        // проверка владения — внутри RPC equip_item (S1). После — перерисовка витрины; профиль
        // подхватит новую экипировку при следующем открытии вкладки.
        async function equipShopItem(slot, itemCode, btn) {
            if (btn) btn.disabled = true;
            try {
                // secure path — gateway equip_item_self без p_student_id (T10-04B); legacy fallback —
                // прежний RPC. Проверка владения — в базовой equip_item.
                const { error } = studentSecurePathActive()
                    ? await db.rpc('equip_item_self', { p_slot: slot, p_item_code: itemCode })
                    : await db.rpc('equip_item', {
                        p_student_id: currentUser.id, p_slot: slot, p_item_code: itemCode
                    });
                if (error) throw error;
                await loadShop();
            } catch (e) {
                alert('Не удалось: ' + (e.message || e));
                if (btn) btn.disabled = false;
            }
        }

