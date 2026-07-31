// Утверждённый runtime-renderer Season V4.
// Из БД принимаются только перечисленные render_payload; произвольные CSS-классы запрещены.
(function () {
    'use strict';

    const AVATARS = new Set([
        'capybara', 'hamster', 'alien', 'schedule_cat', 'raccoon', 'frog', 'pigeon', 'moth',
        'snow_blob', 'clock', 'gift', 'frozen_alien', 'ink_blob', 'octopus', 'beetle',
        'sprout', 'balance_cat', 'space_tourist', 'duck', 'cloud', 'bell', 'brain', 'backpack'
    ]);
    const FRAMES = new Set([
        'sun_route', 'paper_trace', 'wrong_turn', 'autumn_orbit', 'axis', 'rainline',
        'dead_letter', 'last_light', 'cold_static', 'countdown', 'new_year_lights',
        'weak_signal', 'margin_error', 'multitask', 'retry', 'chlorophyll', 'balance',
        'alpha_route', 'ripple', 'weather_loop', 'afterbell', 'loading', 'summer_exit'
    ]);
    const BACKGROUNDS = new Set([
        'field_notes', 'packing_floor', 'wrong_corridor', 'schedule_desk', 'autumn_crosswalk',
        'rain_shelter', 'courtyard_radio', 'night_window', 'snow_yard', 'countdown_room',
        'archive_room', 'frosted_stop', 'paper_space', 'tab_overload', 'notebook_slope',
        'spring_workshop', 'leaning_library', 'orbital', 'puddle_city', 'weather_room',
        'empty_class', 'exam_terminal', 'summer_train'
    ]);
    const TITLE_VISUALS = new Set(['plain', 'pulse', 'signal', 'mono', 'glitch']);
    const RARITIES = new Set(['common', 'rare', 'epic', 'legendary']);
    const LEGACY_FRAMES = new Set([
        'frame-notebook', 'frame-winter', 'frame-fire100', 'frame-legend-1',
        'frame-legend-2', 'frame-legend-3', 'frame-legend-4', 'frame-pulsar',
        'frame-orbit'
    ]);
    const LEGACY_BACKGROUNDS = new Set(['bg-grid', 'bg-space', 'bg-aurora', 'bg-draft']);
    const SECRET_ITEMS = new Set([
        'ca26_03_title_route_author',
        'ca26_08_frame_lamp_light',
        'ca26_13_avatar_clean_page',
        'ca26_18_background_academy_launch'
    ]);

    const hyphenate = (value) => String(value || '').replaceAll('_', '-');
    const rarity = (item) => RARITIES.has(item && item.rarity) ? item.rarity : 'common';

    function visualFromPayload(slot, payload) {
        const raw = String(payload || '');
        let value = '';
        if (slot === 'avatar' && raw.startsWith('avatar_v4_')) {
            value = raw.slice('avatar_v4_'.length);
            return AVATARS.has(value) ? value : null;
        }
        if (slot === 'frame' && raw.startsWith('frame_v4_')) {
            value = raw.slice('frame_v4_'.length);
            return FRAMES.has(value) ? value : null;
        }
        if (slot === 'background' && raw.startsWith('scene_v4_')) {
            value = raw.slice('scene_v4_'.length);
            return BACKGROUNDS.has(value) ? value : null;
        }
        if (slot === 'title') {
            const match = raw.match(/^title_v4_\d{2}_(plain|pulse|signal|mono|glitch)$/);
            return match && TITLE_VISUALS.has(match[1]) ? match[1] : null;
        }
        return null;
    }

    function frameClass(item) {
        const visual = visualFromPayload('frame', item && item.payload);
        return visual ? `frame-v4-${hyphenate(visual)}` : '';
    }

    function legacyFrameClass(item) {
        const payload = String(item && item.payload || '');
        return LEGACY_FRAMES.has(payload) ? payload : '';
    }

    function sceneClass(item) {
        const visual = visualFromPayload('background', item && item.payload);
        if (!visual) return '';
        const exceptions = {
            snow_yard: 'snow-yard-v4',
            leaning_library: 'leaning-library-v4',
            empty_class: 'empty-class-v4'
        };
        return `scene-${exceptions[visual] || hyphenate(visual)}`;
    }

    function legacySceneClass(item) {
        const payload = String(item && item.payload || '');
        return LEGACY_BACKGROUNDS.has(payload) ? payload : '';
    }

    function titleVisual(item) {
        return visualFromPayload('title', item && item.payload) || 'plain';
    }

    function hasSecretCombo(eq) {
        const equipped = new Set(['avatar', 'frame', 'title', 'background']
            .map((slot) => eq && eq[slot] && eq[slot].item_code)
            .filter(Boolean));
        return SECRET_ITEMS.size === equipped.size &&
            [...SECRET_ITEMS].every((itemCode) => equipped.has(itemCode));
    }

    function span(className) {
        const el = document.createElement('span');
        if (className) el.className = className;
        return el;
    }

    function createAvatar(eq, size, mode, fallbackText) {
        const avatarItem = eq && eq.avatar;
        const avatarVisual = visualFromPayload('avatar', avatarItem && avatarItem.payload);
        const root = span(
            `v4-avatar v4-avatar--${mode || 'compact'} ` +
            `avatar-rarity-${rarity(avatarItem)} frame-rarity-${rarity(eq && eq.frame)}` +
            (hasSecretCombo(eq) ? ' has-secret-combo' : '')
        );
        root.style.setProperty('--display-size', `${size}px`);

        const stack = span('v3-avatar-stack');
        stack.style.setProperty('--avatar-size', 'calc(var(--display-size) - var(--ring-space))');
        const visual = avatarVisual ? hyphenate(avatarVisual) : '';
        const clip = span(
            avatarVisual
                ? `v3-avatar-clip avatar-visual-${visual}`
                : 'v3-avatar-clip season-avatar-basic'
        );

        if (avatarVisual) {
            clip.appendChild(span('v4-avatar-backdrop'));
            const character = span(`v3-character char-${visual}`);
            [
                'char-antenna char-antenna-left',
                'char-antenna char-antenna-right',
                'char-ear char-ear-left',
                'char-ear char-ear-right'
            ].forEach((className) => character.appendChild(span(className)));

            const body = span('char-body');
            [
                'char-mask',
                'char-eyes',
                'char-cheek char-cheek-left',
                'char-cheek char-cheek-right',
                'char-mouth'
            ].forEach((className) => body.appendChild(span(className)));
            character.appendChild(body);
            character.appendChild(span('char-prop'));
            character.appendChild(span('char-extra'));
            clip.appendChild(character);
            clip.appendChild(span('v4-avatar-foreground'));
        } else if (fallbackText && typeof fallbackText === 'object' && fallbackText.imageUrl) {
            const img = document.createElement('img');
            img.className = 'season-avatar-image';
            img.src = fallbackText.imageUrl;
            img.alt = fallbackText.alt || '';
            clip.appendChild(img);
        } else {
            const fallback = span('season-avatar-fallback');
            fallback.textContent = typeof fallbackText === 'string' ? fallbackText : '?';
            clip.appendChild(fallback);
        }
        stack.appendChild(clip);

        const approvedFrame = frameClass(eq && eq.frame);
        if (approvedFrame) {
            const frame = span(`v3-frame ${approvedFrame}`);
            frame.setAttribute('aria-hidden', 'true');
            frame.appendChild(span('v4-frame-strand v4-frame-strand-a'));
            frame.appendChild(span('v4-frame-strand v4-frame-strand-b'));
            stack.appendChild(frame);
        }
        root.appendChild(stack);
        return root;
    }

    function createScene(backgroundItem, extraClass) {
        const approvedScene = sceneClass(backgroundItem);
        const legacyScene = legacySceneClass(backgroundItem);
        if (legacyScene) {
            const scene = span(
                `${extraClass || 'season-equipped-scene'} legacy-equipped-scene ${legacyScene}`
            );
            scene.setAttribute('aria-hidden', 'true');
            return scene;
        }
        if (!approvedScene) return null;
        const scene = span(
            `${extraClass || 'season-equipped-scene'} v4-scene-host ${approvedScene} ` +
            `background-rarity-${rarity(backgroundItem)}`
        );
        scene.setAttribute('aria-hidden', 'true');
        const viewport = span(`v4-scene-viewport ${approvedScene}`);
        viewport.appendChild(span('v4-scene-layer v4-scene-layer-a'));
        viewport.appendChild(span('v4-scene-layer v4-scene-layer-b'));
        scene.appendChild(viewport);
        return scene;
    }

    function replaceAvatar(container, eq, size, mode, fallbackText) {
        if (!container) return;
        LEGACY_FRAMES.forEach((className) => container.classList.remove(className));
        const legacyFrame = legacyFrameClass(eq && eq.frame);
        if (legacyFrame) container.classList.add(legacyFrame);
        container.classList.toggle('has-legacy-frame', !!legacyFrame);
        container.replaceChildren(createAvatar(eq || {}, size, mode, fallbackText));
        container.classList.add('season-avatar-host');
    }

    window.SeasonCosmetics = Object.freeze({
        createAvatar,
        createScene,
        frameClass,
        hasSecretCombo,
        legacyFrameClass,
        legacySceneClass,
        replaceAvatar,
        sceneClass,
        titleVisual,
        visualFromPayload
    });
}());
