# COSMIC ACADEMY — план реализации редизайна ученического Mini App

Документ создан **2026-07-25** вместе с [`COSMIC_ACADEMY_AUDIT.md`](./COSMIC_ACADEMY_AUDIT.md).
Все ссылки вида «§N» ниже — на разделы аудита.

**Реализация по этому плану не начиналась.**

---

## 0. Предусловия, общие ограничения и порядок работ

### 0.1. Обязательное действие ДО этапа 1 (за пользователем)

Локальная копия `D:\Sashamath_bot_2` находится на `main = fb68ea8` и **отстаёт от `origin/main`
(`e5f675b`) на 19 коммитов** — именно там лежат актуальные `index.html`, `styles/student.css`,
редизайн профиля и магазина (§0.2 аудита). Работа от устаревшего кода бессмысленна.

```bash
git -C D:/Sashamath_bot_2 pull --ff-only origin main
```

Неотслеживаемое в рабочих деревьях (**не изменять и не включать в коммиты**):

- `D:\Sashamath_bot_2` — `.claude/`, `tools/`;
- `D:\sashamath` — `.worktrees/` (внутри отдельный клон Bot 2.0 на ветке
  `codex/fix-student-registration-username`).

Рекомендуется вести редизайн в отдельной ветке от актуального `origin/main`:

```bash
git -C D:/Sashamath_bot_2 switch -c feat/cosmic-academy origin/main
```

### 0.2. Глобальные запреты на все 9 этапов

1. **Не переводить `js/student-*.js` и `shared.js` в `type="module"`**, не оборачивать в IIFE,
   не бандлить, не переименовывать глобальные функции. Ломает все inline-обработчики (§5, R1).
2. **Не менять порядок `<script>`** в конце `index.html` и не переносить `shared.js` из `<head>`.
3. **Не менять порядок пяти кнопок `.nav-btn`** и не вставлять новые `.tab-btn` выше табов
   домашки — обе выборки идут по индексу (§4, R2).
4. **Не трогать backend, SQL, миграции, Supabase, RPC, Edge Functions, Telegram-аутентификацию**
   (`js/student-auth.js`, `supabase/`, `database/`).
5. **Не менять ветвление `studentSecurePathActive()`** ни в одном месте (§14.1, R10).
6. **Не переводить DOM-путь (`createElement` + `textContent`) на строковый `innerHTML`** —
   магазин, лидерборд, коллекции, витрина, история построены на DOM-пути осознанно (§14.4, R8).
   Обратное направление (строка → DOM) допустимо и приветствуется, но только с сохранением `esc()`
   там, где строки остаются.
7. **Не переносить `const`-объявления между student-файлами** — коллизия имён даёт `SyntaxError`
   и белый экран (§15.1, R12).
8. **Не менять бизнес-константы**: `SHIELD_MAX`, `SHIELD_PRICE`, дедлайны (`23:61` — не опечатка),
   `isAssignmentAvailable`, `LEAGUE_LADDER`, коды `ACHIEVEMENTS_META`, лимиты титула 3–24.
9. **Не удалять существующий код** (конституция проекта). Помеченные как неиспользуемые
   `lastResultSummary`, `formatPlainDate`, `.week-neutral-note` — оставить.
10. Один этап = один коммит. Этапы не смешивать.

### 0.3. Инструментальная база

`node`, `npx`, `rg`, `deno`, `supabase` **в PATH отсутствуют**; есть `git`, `python 3.13.7`,
Git Bash (`grep`, `sed`, `sort`, `comm`), локальный `tools/supabase.exe`.
Поэтому проверки ниже построены на `grep`/`git`/`python -m http.server`, без npm-скриптов.

### 0.4. Единый контрактный чек (используется на всех этапах)

Предлагается один раз добавить на этапе 1 скрипт `scripts/check_ui_contract.py`, который
проверяет три инварианта и завершается ненулевым кодом при нарушении:

1. каждый `getElementById('x')` из `js/student-*.js` имеет `id="x"` в `index.html`
   (единственное разрешённое исключение — динамический `exam-info-box`, §3.1);
2. каждая функция из inline-обработчика `index.html` объявлена в `js/student-*.js` или `shared.js`;
3. каждый динамический CSS-класс из списка §6 аудита имеет правило в `styles/student.css`.

До появления скрипта те же три проверки выполняются командами Git Bash, приведёнными в
каждом этапе.

### 0.5. Локальный визуальный прогон

```bash
python -m http.server 8080
```

затем открыть `http://localhost:8080/index.html`. Вне Telegram авторизация и Supabase не работают
(ожидаемо: `#user-name` покажет «Ошибка доступа» или «Откройте приложение заново») — но этого
достаточно, чтобы поймать `SyntaxError`, ошибки CSS, раскладку и переключение вкладок.
Полноценная проверка данных — только в Telegram на dev-боте.

---

## Этап 1. Design tokens, тема Telegram, глобальный фон, AppShell

### Цель
Ввести систему токенов Cosmic Academy, привязать её к Telegram Theme Params, добавить глобальный
фон и каркас AppShell — **без изменения структуры экранов и без единой правки JS-логики**.

### Изменяемые файлы
- `styles/student.css` — основной объём;
- `index.html` — **только** `<head>` (мета/подключения) и, если выбран вариант Б, одна обёртка;
- `js/student-app.js` — **опционально**, только вызовы Telegram-темы (`setHeaderColor`,
  `setBackgroundColor`, `setBottomBarColor`, подписка на `themeChanged`), больше ничего.

### Что делать
1. Расширить блок `:root`: к существующим 7 `--tg-*` и 5 `--text-*` добавить
   `--ca-*` токены: палитра (акцент, успех, ошибка, предупреждение, «на проверке», «щит»),
   радиусы (14/16/20 → `--radius-sm/md/lg`), тени (`--elev-1` = `0 3px 12px rgba(0,0,0,.07)`,
   `--elev-2` = `0 4px 15px rgba(0,0,0,.1)`, `--elev-modal`), отступы, размеры иконок.
2. Перевести на токены ~30 хардкод-цветов и десятки `rgba(128,128,128,…)` / `rgba(36,129,204,…)`
   (§8.3). `rgba(36,129,204,…)` — это «замороженный» `--tg-link`, заменить на
   `color-mix(in srgb, var(--tg-link) X%, transparent)` либо на отдельный токен.
3. Ввести светлый/тёмный варианты токенов через `@media (prefers-color-scheme: dark)` **и**
   через Telegram-переменные, чтобы приложение выглядело корректно и вне Telegram.
4. Глобальный фон — **вариант А (рекомендуется)**: слой на `body::before`
   (`position: fixed; inset: 0; z-index: -1; pointer-events: none`), `body` при этом сохраняет
   `display: flex; flex-direction: column; min-height: 100vh`.
   **Вариант Б** (обёртка `<div class="ca-shell">` вокруг пяти экранов) требует переноса
   `min-height: 100vh` и `padding-bottom` на обёртку и перепроверки §13.4 — выбирать только если
   вариант А визуально не даёт нужного результата.
5. **Купленные фоны профиля**: перенести `background-image` из `#screen-profile.bg-*` на
   `#screen-profile.bg-*::before` (`position:absolute; inset:0; pointer-events:none; z-index:0`),
   чтобы космический фон приложения и платный фон профиля накладывались, а не конкурировали
   (§10.3, R3). Классы `bg-grid/bg-space/bg-aurora/bg-draft` и селектор `#screen-profile` —
   **сохранить дословно**.
6. Заменить `body { padding-bottom: 75px }` на
   `calc(var(--ca-nav-h) + env(safe-area-inset-bottom, 0px) + 10px)`.
7. Добавить `@media (prefers-reduced-motion: reduce)` — отключение `fadeIn`, `framePulse`,
   `frameSpin` (§16).
8. **Устранить мёртвые правила из §13.6 без изменения поведения:**
   добавить `display: grid` в `.profile-meta-row` и `display: flex` в `.profile-title-card`
   (инлайновые присвоения в JS при этом **оставить как есть** — они станут дублирующими, но
   безопасными). Правила `.week-weekly-row`, `.week-totals`, `.week-forecast` **не удалять** —
   они будут задействованы на этапе 3, когда элементам добавят классы.

### Функции, которые нельзя менять
`applyProfileCosmetics`, `applyAvatarFrame`, `applyNickColor`, `renderNick`, `buildEquipMap`,
`equipmentQuery`, `titleText`, `equippedTitleText`, `setupAvatar`, `switchTab`, `switchHwTab`,
`initStudentSession`, `studentSecurePathActive`, `studentAccessToken`.
Из `student-app.js` — весь существующий порядок вызовов (`tg.ready/expand` →
`initStudentSession` → `checkAndActivateAssignments` → `loadProfile` → `loadActiveAssignments`
→ `loadTodayQuests`); можно только **дописать** вызовы темы после `tg.expand()`.

### DOM ID, которые требуется сохранить
Все 5 экранов (`screen-profile`, `screen-homework`, `screen-leaderboard`, `screen-shop`,
`screen-more`) и `custom-title-modal`. На этом этапе структура ID не меняется вообще.

### Динамические классы, которые надо оформить
`bg-grid`, `bg-space`, `bg-aurora`, `bg-draft` (перенос на псевдоэлемент),
9 классов `FRAME_CLASSES` (проверить, что кольца `box-shadow` читаются на новом фоне),
`nick-gold`, `nick-status`, `nick-crown`, `avatar-img`, `avatar-placeholder`.

### Критерии готовности
- [ ] В `styles/student.css` нет ни одного шестнадцатеричного цвета вне блока `:root`
      (исключение — `#screen-profile.bg-*` градиенты и `frame-*`, если решено оставить их
      «фирменными»; тогда это явно закомментировано).
- [ ] Приложение корректно выглядит в светлой и тёмной теме Telegram и в обычном браузере.
- [ ] Купленный фон профиля виден **поверх** глобального фона на всех четырёх вариантах.
- [ ] Золотой ник (`nick-gold`) и все 9 рамок отображаются как до правки.
- [ ] Нижняя панель не заходит под `safe-area` (проверить в Telegram на iOS или эмуляцией
      `env()` через DevTools).
- [ ] `git diff` не затрагивает `js/student-core.js`, `-assignments`, `-week`, `-progress`,
      `-shop`, `-quests`, `-auth`, `shared.js`, `supabase/`, `database/`.

### Команды проверки
```bash
git -C D:/Sashamath_bot_2 --no-pager diff --stat
```
```bash
git -C D:/Sashamath_bot_2 --no-pager diff --name-only | grep -E '^(js/student-(core|assignments|week|progress|shop|quests|auth)\.js|shared\.js|supabase/|database/)' && echo "STOP: затронуты запрещённые файлы" || echo "OK: запрещённые файлы не тронуты"
```
```bash
grep -n -E '#[0-9a-fA-F]{6}' styles/student.css | grep -v -E '^\s*[0-9]+:\s*--' | head -50
```
```bash
python -m http.server 8080
```

### Риски
- **R3** — фон профиля vs глобальный фон (ID-специфичность). Смягчение: псевдоэлемент, п. 5.
- **R4** — новое правило `color` на потомках `#user-name` убьёт золотой ник. Смягчение: не
  задавать `color`/`-webkit-text-fill-color` глубже `#user-name` / `.lb-name-line`.
- **R6** — не удалять инлайновые `style.display` из JS; вместо этого продублировать в CSS.
- Вариант Б (обёртка AppShell) ломает `body { display:flex; min-height:100vh }` — §13.4.
- `setBackgroundColor`/`setHeaderColor` доступны не во всех версиях Telegram — оборачивать в
  `tg.isVersionAtLeast('6.1')` и `try/catch`, иначе старый клиент упадёт на старте.

### Рекомендуемый коммит
```
feat(ui): design tokens, Telegram theme and global background (Cosmic Academy stage 1)
```

---

## Этап 2. SVG-иконки и нижняя навигация

### Цель
Заменить эмодзи, выступающие иконками интерфейса, на SVG-спрайт и перерисовать `.bottom-nav`,
сохранив её контракт (индексы, `onclick`, классы).

### Изменяемые файлы
- `index.html` — блок `<svg style="display:none">` со `<symbol>`-ами в начале `<body>`;
  разметка `.bottom-nav`; статические эмодзи-иконки заголовков и табов (§12.1);
- `styles/student.css` — стили `.ca-icon`, `.bottom-nav`, `.nav-btn`, `.nav-icon`;
- **точечно** `js/student-progress.js` — **только** добавление поля `svg` в `ACHIEVEMENTS_META`
  (поле `icon` не удалять);
- **точечно** `js/student-week.js` — **только** если решено заменить `WEEK_DAY_MARKS`; по
  умолчанию **не менять**, маркеры дня остаются символами.

### Что делать
1. Инлайновый SVG-спрайт (`<symbol id="ca-i-profile" viewBox="0 0 24 24">…`), использование через
   `<svg class="ca-icon"><use href="#ca-i-profile"/></svg>`. Внешние файлы/CDN не подключать —
   Mini App должен работать одним HTTP-корнем.
2. Навигация: `.nav-icon` перестаёт быть эмодзи-текстом, но **остаётся элементом внутри
   `.nav-btn`**, а подпись — прямым текстовым узлом или `<span class="nav-label">`.
   `onclick="switchTab('…')"`, класс `.nav-btn`, класс `.active` и **порядок пяти кнопок** —
   без изменений.
3. Добавить `role="tablist"` на `.bottom-nav`, `role="tab"` + `aria-selected` на `.nav-btn`
   (JS `switchTab` не трогать — `aria-selected` можно выразить через CSS `[aria-selected]`… либо
   отложить до этапа 8, если требуется правка `switchTab`; **правка `switchTab` на этом этапе
   запрещена**).
4. Убрать бесполезный `backdrop-filter` либо сделать фон панели полупрозрачным (§9.4).
5. Заменить статические эмодзи-иконки §12.1: `.nav-icon` ×5, табы домашки, табы лидеров,
   `h2` экранов, `.chart-title`, `.showcase-title`, `.achievements-title`, `.collections-title`,
   `.history-title` ×2 (заодно починить отсутствующую иконку у «История изменений»),
   `.profile-title-icon`, `.upload-icon`, `#detail-link`, `.faq-title`, `.more-link-btn` ×2.
6. **Оставить эмодзи** там, где это контент, а не иконка (§12.3): 🥯 как валюту в текстах,
   `WEEK_DAY_MARKS`, `reasonMap`, эмодзи-статусы ника, эмодзи-чипы магазина, 🥇🥈🥉 медали,
   иконки достижений (там добавляется поле `svg`, а `icon` остаётся).

### Функции, которые нельзя менять
`switchTab`, `switchHwTab`, `switchLbMode`, `renderWeekStrip`, `renderQuestStreak`,
`loadAchievements`, `loadShowcase`, `openShowcasePicker`, `renderShopItem`, `shopPreview`.
`ACHIEVEMENTS_META` — **только дополнение поля**, коды и `name` не трогать (R11).

### DOM ID, которые требуется сохранить
`screen-profile`, `screen-homework`, `screen-leaderboard`, `screen-shop`, `screen-more`,
`lb-tab-league`, `lb-tab-global`, `file-input`, `upload-area`, `detail-link`.

### Динамические классы, которые надо оформить
`nav-btn`/`active` (не динамический, но переключается из JS), `ach-icon`, `showcase-icon`,
`now-icon`, `quest-row-icon`, `shop-preview` — все они должны корректно вмещать как эмодзи, так
и `<svg class="ca-icon">`.

### Критерии готовности
- [ ] `document.querySelectorAll('.nav-btn').length === 5`, порядок Профиль → Домашка → Лидеры →
      Магазин → Ещё сохранён.
- [ ] Переключение всех пяти вкладок и обоих табов домашки/лидеров работает.
- [ ] Иконки читаются в светлой и тёмной теме (`fill: currentColor`).
- [ ] `ACHIEVEMENTS_META[i].icon` и `.code` не изменились ни у одного из 24 элементов.
- [ ] Нет запросов к внешним доменам за иконками (проверить вкладку Network).

### Команды проверки
```bash
grep -c 'class="nav-btn' index.html
```
```bash
grep -o -E "switchTab\('[a-z]+'\)" index.html
```
```bash
git -C D:/Sashamath_bot_2 --no-pager diff -- js/student-progress.js | grep -E '^[-+].*code:' | head -60
```
```bash
for fn in switchTab switchHwTab switchLbMode buyStreakShield showAssignmentDetails handleFileSelect uploadDZ inviteParent closeCustomTitleModal updateCustomTitleForm submitCustomTitle; do grep -qs "function $fn" js/student-*.js || echo "MISSING: $fn"; done; echo "check done"
```

### Риски
- **R2** — перестановка `.nav-btn` или добавление `.tab-btn` выше домашки ломает индексную
  выборку. Смягчение: не менять порядок, проверить `grep` выше.
- **R11** — удаление `icon` из `ACHIEVEMENTS_META` молча ломает витрину, пикер и «🔒 Нужно: …».
- `<use href>` без `xlink:href` не поддерживается очень старыми WebView — на практике для
  Telegram актуальных версий безопасно, но стоит проверить на реальном Android-клиенте.
- SVG внутри `.nav-icon` меняет базовую линию flex-колонки → возможен «прыжок» подписи.

### Рекомендуемый коммит
```
feat(ui): SVG icon sprite and redesigned bottom navigation (Cosmic Academy stage 2)
```

---

## Этап 3. Профиль, неделя и «Сделать сейчас»

### Цель
Перерисовать шапку профиля, карточки статистики, блок недели и список «Сделать сейчас».

### Изменяемые файлы
- `index.html` — секции `.profile-header`, `.rank-progress`, `.profile-title-card`,
  `.study-stats`, `.week-block` (включая `#week-weekly-row`, `#week-totals`, `#week-forecast`);
- `styles/student.css`;
- `js/student-week.js` — **только разметочные строки** внутри `renderWeekStrip`,
  `renderWeekDayDetail` и трёх `innerHTML`/`textContent` в `loadWeekBlock`;
- `js/student-assignments.js` — **только разметочная строка** внутри `loadAssignmentsSummary`.

### Что делать
1. **Починить §13.6-2**: добавить классы в разметку —
   `<div id="week-weekly-row" class="week-weekly-row">`, `<div id="week-totals" class="week-totals">`,
   `<div id="week-forecast" class="week-forecast">`. ID сохранить.
2. Шапка профиля: аватар, имя, «Группа»/«Звание», прогресс звания, карточка титула.
   Убрать магические `52px` из `.profile-meta-row` и `.rank-progress` — перейти на
   `--ca-avatar-size` + `--ca-gap` (`margin-left: calc(var(--ca-avatar-size) + var(--ca-gap))`).
3. `.stats-grid` (Рейтинг / Бублики) — на токены карточек этапа 1.
4. Полоса недели: 7 колонок должны выдерживать 360 px (сейчас ≈37 px на день, §17). Пересмотреть
   `height: 54px`, `gap: 5px`, `.week-day-mark 20×20`.
5. `.week-day-detail` — раскрытие остаётся на классе `.open`, кнопка щита — на
   `[data-action]` c классами `week-shield-btn apply|remove`.
6. `.now-item` — `data-assignment-id` и класс `.now-item` **обязаны сохраниться**, к ним
   привязывается `addEventListener` в конце `loadAssignmentsSummary`.

### Функции, которые нельзя менять
**Логику целиком**: `loadWeekBlock` (запросы, `classification`, расчёт `deadline`),
`selectWeekDay`, `applyWeekShield`, `removeWeekShield` (включая `weekShieldBusy`),
`shortDateRu`, `addDaysToDateStr`, `getActionableAssignments`, `isAssignmentAvailable`,
`openNowAssignment`, `pluralTasks`, `loadProfile` (весь оркестратор и retry по `PGRST116`),
`loadRankTitle`, `renderStreakProgress`, `applyProfileCosmetics`.
Словари `WEEK_DAY_NAMES`, `WEEK_DAY_FULL_NAMES`, `WEEK_DAY_LABELS`, `WEEK_DAY_MARKS` — ключи
не трогать (контракт с `get_student_current_week`, §18.3).
Вызовы `esc(...)` во всех шаблонах — сохранить (R8).

### DOM ID, которые требуется сохранить
`user-avatar-container`, `user-name`, `profile-group-row`, `group-badge`, `profile-rank-row`,
`rank-badge`, `rank-progress`, `profile-title-row`, `profile-title`, `val-rating`, `val-huikons`,
`week-block`, `week-block-sub`, `week-progress`, `week-days-strip`, `week-day-detail`,
`week-weekly-row`, `week-totals`, `week-forecast`, `now-count`, `now-list`.

### Динамические классы, которые надо оформить
`week-day-chip`, `wd-not_assigned`, `wd-assigned`, `wd-submitted`, `wd-revision`, `wd-approved`,
`wd-missed`, `wd-shielded`, `today`, `selected`, `week-day-name`, `week-day-mark`, `open`,
`week-day-detail-main`, `week-day-detail-title`, `week-day-detail-note`, `week-shield-btn`,
`apply`, `remove`, `week-weekly-row`, `week-totals`, `week-forecast`,
`now-item`, `now-icon`, `now-main`, `now-item-title`, `now-item-meta`, `now-arrow`,
`summary-empty`, `avatar-img`, `avatar-placeholder`, `nick-gold`, `nick-status`, `nick-crown`,
`group-badge.assigned`, `frame-*` (9).

### Критерии готовности
- [ ] Все 7 состояний дня недели визуально различимы и подписаны (`aria-label` сохранён).
- [ ] Клик по дню раскрывает/скрывает деталь; кнопка «Прикрыть щитом»/«Отменить щит» работает и
      не срабатывает дважды при быстром двойном клике.
- [ ] Клик по элементу «Сделать сейчас» открывает вкладку «Домашка» с предвыбранным заданием.
- [ ] Три строки под полосой недели (еженедельное / итоги / прогноз) теперь стилизованы.
- [ ] На 360 px полоса из 7 дней не переносится и не обрезается.
- [ ] Косметика (золотой ник, рамка, фон, титул) отображается как до правки.

### Команды проверки
```bash
grep -o -E "getElementById\('[^']*'\)" js/student-week.js js/student-assignments.js js/student-progress.js | sed "s/.*getElementById('//;s/')//" | sort -u > /tmp/ids_used.txt; grep -o -E 'id="[^"]*"' index.html | sed 's/id="//;s/"$//' | sort -u > /tmp/ids_have.txt; comm -23 /tmp/ids_used.txt /tmp/ids_have.txt
```
> Ожидаемый вывод: только `exam-info-box`.
```bash
for c in week-day-chip wd-approved wd-shielded wd-missed wd-revision wd-submitted wd-assigned wd-not_assigned week-day-mark week-day-name week-shield-btn week-weekly-row week-totals week-forecast now-item now-icon now-main now-item-title now-item-meta now-arrow summary-empty; do grep -q "\.$c" styles/student.css || echo "NO CSS: $c"; done; echo "check done"
```
```bash
grep -n 'data-assignment-id' js/student-assignments.js
```
```bash
grep -c 'esc(' js/student-week.js js/student-assignments.js
```

### Риски
- **R6** — если убрать `style.display='grid'` из `loadProfile`/`loadRankTitle`, а `display: grid`
  в CSS не добавили на этапе 1, шапка развалится.
- **R4** — новые правила цвета в шапке убьют `nick-gold`.
- Потеря `data-assignment-id` или класса `.now-item` → клики по «Сделать сейчас» молча пропадают.
- Изменение ключей `WEEK_DAY_LABELS` → все дни рендерятся как `not_assigned` (fallback в коде).
- Уменьшение `.week-day-chip` ниже ~34 px делает `.week-day-mark` нечитаемым.

### Рекомендуемый коммит
```
feat(ui): redesign profile header, week strip and "do now" list (Cosmic Academy stage 3)
```

---

## Этап 4. Квесты, пробники, щиты, витрина, достижения и истории

### Цель
Перерисовать остальную часть экрана профиля: блок «Сегодня», график пробников, виджет щитов,
витрину, достижения, коллекции и два списка истории.

### Изменяемые файлы
- `index.html` — `.today-block`, `.mock-chart-section`, `.study-tools`, `.showcase-section`,
  `.achievements-section`, `.collections-section`, обе `.history-section`;
- `styles/student.css`;
- `js/student-quests.js` — только шаблоны `buildLifeRow`, `buildComboRow`, `renderQuestStreak`;
- `js/student-progress.js` — только разметка `renderMockChart`, `trajectorySummary`,
  `showExamInfo`, `renderStreakProgress`, `loadBalanceHistory`, `loadSeasonHistory`,
  `loadAchievements`;
- `js/student-shop.js` — только разметка `loadShields`, `loadShowcase`, `openShowcasePicker`,
  `loadCollections`.

### Что делать
1. **`#exam-info-box` сохранить дословно** — он создаётся строкой в `renderMockChart` и читается
   в `showExamInfo` (§3.1, R5). Если график переписывается, ID переносится вместе с ним.
2. График: `viewBox 320×140` можно менять, но `xFor/yFor`, `minScore/maxScore` и
   `onclick="showExamInfo(i)"` на `<circle>` — оставить. Подписи `font-size="9"` увеличить
   (§17): на 360 px они читаются как ~8 px.
3. Квесты: `.life-row-trailing` — **не просто класс, а хук** для
   `setLifeControlsDisabled` (`document.querySelectorAll('.life-row-trailing button')`).
   Кнопки `claimTodayLife(slot)` / `replaceTodayLife(slot)` остаются inline-обработчиками.
4. Достижения: сетка 4 → 3 колонки на ≤380 px; `.ach-tile.locked` (grayscale) и 🔒 сохранить.
5. Витрина: три плитки, `tile.onclick = openShowcasePicker(pos)` — назначение обработчика в JS
   оставить; `showcaseOpenPosition` и повторный клик-закрытие не менять.
6. Коллекции: **`loadCollections` содержит побочный эффект `grantCollectionBonus`** (§14.9, R7).
   Трогать можно только формирование `.coll-tile`/`.coll-name`; блок
   `if (items.every(...)) await grantCollectionBonus(...)` не выносить и не переписывать.
7. Две истории (`#balance-history-list`, `#season-history-list`) объединить в один визуальный
   компонент `.history-item`, но `reasonMap` в `loadBalanceHistory` не менять.
8. Щиты: `#shield-count`, `#btn-buy-shield`, `SHIELD_MAX`, `SHIELD_PRICE`, `pluralShields` —
   без изменений; меняется только оформление `.shield-widget`.

### Функции, которые нельзя менять
`loadTodayQuests`, `claimTodayLife`, `replaceTodayLife` (+ `questActionBusy`),
`setLifeControlsDisabled`, `loadMockExamChart`, `loadShields`, `buyStreakShield`,
`grantCollectionBonus`, `setShowcase`, `loadShowcase` (запросы), `loadAchievements` (запрос),
`loadBalanceHistory` (`reasonMap` и вся логика подстановки причин),
`loadSeasonHistory`, `ACHIEVEMENTS_META`, `lastResultSummary`, `formatPlainDate`.

### DOM ID, которые требуется сохранить
`today-quests-content`, `mock-chart-container`, **`exam-info-box`**, `streak-display`,
`streak-progress`, `shield-widget`, `shield-count`, `btn-buy-shield`, `showcase-section`,
`showcase-grid`, `showcase-picker`, `achievements-section`, `ach-grid`, `collections-section`,
`collections-list`, `season-history-section`, `season-history-list`, `balance-history-list`.

### Динамические классы, которые надо оформить
`quest-row`, `quest-row-icon`, `quest-row-main`, `quest-row-title`, `quest-row-meta`,
`quest-row-note`, `quest-row-trailing`, `life-row-trailing`, `quest-badge`, `quest-badge-paid`,
`quest-badge-wait`, `quest-badge-locked`, `quest-claim-btn`, `quest-replace-btn`,
`streak-dots`, `streak-dot`, `filled`, `streak-note`, `exam-info-box`, `chart-disclaimer`,
`chart-empty`, `history-item`, `hist-info`, `hist-reason`, `hist-date`, `hist-amount`,
`hist-positive`, `hist-negative`, `ach-tile`, `locked`, `ach-icon`, `ach-name`,
`collection-block`, `collection-season-title`, `coll-grid`, `coll-tile`, `coll-name`,
`showcase-tile`, `empty`, `showcase-icon`, `showcase-name`, `showcase-picker-title`,
`showcase-chip`, `showcase-chip-clear`, `showcase-picker-empty`, `summary-empty`.

### Критерии готовности
- [ ] Клик по точке графика меняет текст в `#exam-info-box`.
- [ ] «Выполнил честно» и 🔁 работают, повторный быстрый клик не проходит.
- [ ] После `claimTodayLife` профиль обновляется (баланс), строка получает `quest-badge-paid`.
- [ ] Витрина: клик по плитке открывает пикер, повторный клик по той же — закрывает.
- [ ] «Убрать из витрины» очищает слот.
- [ ] Достижения: полученные цветные, неполученные — 🔒 + grayscale; legacy-достижения видны
      только владельцам.
- [ ] Полная коллекция по-прежнему приводит к начислению бонуса (проверять только на dev-данных).

### Команды проверки
```bash
grep -n "exam-info-box" js/student-progress.js index.html
```
```bash
grep -n "life-row-trailing" js/student-quests.js styles/student.css
```
```bash
git -C D:/Sashamath_bot_2 --no-pager diff -- js/student-shop.js | grep -n -E '^[-+].*(grantCollectionBonus|SHIELD_MAX|SHIELD_PRICE|studentSecurePathActive)'
```
> Ожидаемый вывод: пусто.
```bash
for c in quest-row quest-badge-paid quest-badge-wait quest-badge-locked quest-claim-btn quest-replace-btn life-row-trailing streak-dot filled streak-note exam-info-box chart-disclaimer history-item hist-positive hist-negative ach-tile ach-icon ach-name coll-grid coll-tile coll-name showcase-tile showcase-icon showcase-name showcase-chip showcase-chip-clear showcase-picker-empty; do grep -q "\.$c" styles/student.css || echo "NO CSS: $c"; done; echo "check done"
```

### Риски
- **R5** — потеря `#exam-info-box`: клик по точке молча перестаёт работать (в коде тихий `return`).
- **R7** — переписывание `loadCollections` без побочного эффекта = потеря реальных бубликов.
- **R9** — новые кнопки квестов без `questActionBusy`/`disabled` → двойное начисление.
- Потеря `.life-row-trailing` → кнопки не блокируются во время запроса.
- Изменение `ACHIEVEMENTS_META` → падает витрина и подписи условий в магазине (**этап 7**).

### Рекомендуемый коммит
```
feat(ui): redesign quests, mock exam chart, shields, showcase and history (Cosmic Academy stage 4)
```

---

## Этап 5. Домашка и архив работ

### Цель
Перерисовать экран `#screen-homework`: форму сдачи и архив «Мои работы».

### Изменяемые файлы
- `index.html` — весь `#screen-homework` (вычистить ~10 инлайновых `style`, §17);
- `styles/student.css`;
- `js/student-assignments.js` — **только** разметка `handleFileSelect`, `showAssignmentDetails`,
  `loadMyHomework` и текстовые статусы в `uploadDZ`.

### Что делать
1. Все инлайновые стили `#screen-homework` перевести в классы (`.dz-hint`, `.dz-label`,
   `.assignment-details`, `.detail-title`, `.detail-count`, `.detail-feedback`, `.dz-footnote`).
   **ID сохранить** — JS обращается к `#detail-title`, `#detail-count`, `#detail-link`,
   `#detail-feedback`, `#assignment-details` и переключает им `style.display`.
2. `select#assignment-select` — глобальное правило `select {…}` (§13.2) заменить на классовое,
   но так, чтобы поведение не изменилось; `onchange="showAssignmentDetails()"` сохранить.
3. `#file-input` обязан остаться скрытым и с этим ID — на него ссылается inline-обработчик
   `#upload-area`.
4. `.upload-text` и `.upload-icon` — **обязательные потомки `#upload-area`**: `handleFileSelect`
   и `uploadDZ` делают `area.querySelector('.upload-text')` / `.upload-icon` и правят
   `innerText` / `style.display`.
5. **Решить с пользователем §13.6-1 (R15).** Сейчас `loadMyHomework` ставит
   `status-${hw.status}`, то есть `status-submitted` / `status-checked`, а в CSS есть только
   `status-pending/approved/rejected` — цветная полоска статуса **не работает вообще**.
   Варианты: (а) добавить в CSS `.status-submitted` / `.status-checked` (минимальная правка,
   поведение «как задумано изначально» — но это визуальное изменение существующего экрана);
   (б) оставить как есть и не показывать полоску. **Выбор — за пользователем; по умолчанию
   вариант (б), т.к. любое «исправление» меняет то, что ученики видят сегодня.**
   Классы `badge-pending/approved/rejected` работают корректно и остаются.

### Функции, которые нельзя менять
`uploadDZ` (весь расчёт дедлайнов, `moscowDateTimeToInstant`, `23:61`, ветка
`studentSecurePathActive`, сброс формы, порядок `loadProfile`/`loadMyHomework`/
`loadActiveAssignments`), `uploadToCloudinary`, `uploadSignedToCloudinary` (`shared.js`),
`checkAndActivateAssignments`, `getActionableAssignments`, `isAssignmentAvailable`,
`loadActiveAssignments` (формирование `<option>` и `option.value = asn.id`),
`switchHwTab`, `handleFileSelect` (запись в `selectedFiles`), парсинг `photo_url` в
`loadMyHomework`, `esc()` во всех вставках.

### DOM ID, которые требуется сохранить
`hw-upload`, `hw-archive`, `assignment-select`, `assignment-details`, `detail-title`,
`detail-count`, `detail-link`, `detail-feedback`, `upload-area`, `file-input`, `file-list`,
`btn-upload-dz`, `dz-status`, `my-hw-list`.

### Динамические классы, которые надо оформить
`file-item`, `has-file`, `my-hw-item`, `status-submitted`/`status-checked` (см. п. 5),
`hw-header`, `hw-variant`, `hw-pages`, `hw-date`, `hw-badge`, `badge-pending`, `badge-approved`,
`badge-rejected`, `hw-comment`, `rejected`. Плюс обязательные потомки `upload-text`, `upload-icon`.

### Критерии готовности
- [ ] Выбор задания показывает название, число задач, ссылку и комментарий учителя.
- [ ] Выбор файлов меняет текст зоны загрузки, прячет иконку, добавляет `.has-file`, включает
      кнопку.
- [ ] Успешная отправка сбрасывает форму (текст зоны, иконка, `select.value=""`, `#file-list`).
- [ ] Просроченное задание даёт сообщение «⏰ Время вышло…» и не отправляется.
- [ ] Архив: бейджи «На проверке / Принято / Возврат» и комментарий учителя отображаются.
- [ ] Ни одного инлайнового `style` внутри `#screen-homework`, кроме служебных `display:none`
      на элементах, которыми управляет JS.

### Команды проверки
```bash
git -C D:/Sashamath_bot_2 --no-pager diff -- js/student-assignments.js | grep -n -E '^[-+].*(moscowDateTimeToInstant|isAssignmentAvailable|studentSecurePathActive|submit_assignment_self|23, 61|selectedFiles)'
```
> Ожидаемый вывод: пусто.
```bash
grep -n -E "querySelector\('\.(upload-text|upload-icon)'\)" js/student-assignments.js
```
```bash
grep -o -E 'style="[^"]*"' index.html | wc -l
```
> Значение должно уменьшиться относительно предыдущего коммита.
```bash
for c in file-item has-file my-hw-item hw-header hw-variant hw-pages hw-date hw-badge badge-pending badge-approved badge-rejected hw-comment; do grep -q "\.$c" styles/student.css || echo "NO CSS: $c"; done; echo "check done"
```

### Риски
- Потеря `#file-input` или `#upload-area` → зона загрузки перестаёт открывать выбор файла
  (inline-обработчик).
- Потеря `.upload-text` / `.upload-icon` → `TypeError` в `handleFileSelect` при выборе файла.
- Замена `<select>` на кастомный компонент → ломается `select.value = String(assignmentId)`
  в `openNowAssignment` и весь путь «Сделать сейчас» → «Домашка». **Кастомный дропдаун на этом
  этапе не делать.**
- **R15** — «починка» `.status-*` меняет существующее поведение архива.

### Рекомендуемый коммит
```
feat(ui): redesign homework submission and archive (Cosmic Academy stage 5)
```

---

## Этап 6. Лиги и общий топ

### Цель
Перерисовать `#screen-leaderboard`: карточку лиги, лестницу из 7 лиг, строки участников и общий
сезонный топ.

### Изменяемые файлы
- `index.html` — весь `#screen-leaderboard`;
- `styles/student.css`;
- `js/student-progress.js` — **только** разметка `renderLeagueLadder`, шапки `loadLeague`
  и построение `li.lb-item` в `loadLeague` / `loadGlobalTop`.

### Что делать
1. Вынести повторяющуюся сборку строки участника (§7.4) в одну функцию-хелпер внутри
   `student-progress.js` (например `buildLeaderboardRow(...)`) и использовать её в обеих
   функциях — это единственная разрешённая на этом этапе структурная правка JS.
   **Новый `const`/`function` объявлять только в `student-progress.js`** (R12).
2. Строка участника строится через `createElement` + `textContent` — **сохранить DOM-путь**
   (R8): имена учеников и титулы приходят из БД.
3. `renderNick(line, name, eq, isMe ? ' (Вы)' : '')` и `applyAvatarFrame(avatar, eq)` —
   вызовы сохранить дословно.
4. **Известный дефект `frame-orbit` на `.lb-avatar`** (§10.2): контейнер содержит текстовую букву,
   а не `.avatar-img`/`.avatar-placeholder`, поэтому `padding: 3px` сжимает букву и встречное
   вращение не применяется. Здесь его можно устранить **чисто через CSS**, добавив
   `.lb-avatar.frame-orbit` правило, — без правки JS.
5. `.lb-rank` (35 px) и `.lb-avatar` (32 px + 10 px) пересмотреть под 360 px (§17).
6. Лестница лиг: `.ladder-step.current` / `.achieved` и 📍/✓/🔒 сохранить как состояния.

### Функции, которые нельзя менять
`loadLeaderboard`, `switchLbMode`, `getCurrentSeasonId` (вызывает `ensure_current_season` —
ленивое создание сезона, §14.10), запросы и вся логика мест/переходов в `loadLeague`
(`snap`, `preview`, `cohort`, `active < 5`, `is_late_entry`, `inactive_seasons`),
`loadGlobalTop` (запрос, batch-загрузка экипировки — **не превращать в N+1**),
`equipmentQuery`, `buildEquipMap`, `renderNick`, `applyAvatarFrame`, `equippedTitleText`,
`LEAGUE_LADDER`.

### DOM ID, которые требуется сохранить
`screen-leaderboard`, `lb-tab-league`, `lb-tab-global`, `lb-mode-league`, `lb-mode-global`,
`league-content`, `lb-season-label`, `lb-list`.

### Динамические классы, которые надо оформить
`leaderboard-list`, `lb-item`, `lb-me`, `lb-promote`, `lb-demote`, `lb-rank`, `lb-avatar`,
`lb-name-wrap`, `lb-name-line`, `lb-title`, `lb-score`, `league-badge`, `league-note`,
`league-standing`, `league-ladder`, `ladder-step`, `achieved`, `current`,
`nick-gold`, `nick-status`, `nick-crown`, `frame-*` (9, в контексте `.lb-avatar`).

### Критерии готовности
- [ ] Оба таба переключаются, `#lb-tab-*` получают `.active`.
- [ ] Своя строка подсвечена (`lb-me`), суффикс « (Вы)» на месте.
- [ ] `lb-promote` / `lb-demote` визуально различимы, стрелки ↑/↓ в `.lb-score` сохранены.
- [ ] Лестница из 7 лиг: текущая подсвечена, ниже — пройденные, выше — закрытые.
- [ ] Косметика участников (цвет ника, корона, эмодзи-статус, рамка, титул) отображается.
- [ ] `frame-orbit` в лидерборде больше не «съедает» букву.
- [ ] На 360 px строка не переносится: ранг + аватар + имя + очки помещаются.
- [ ] В Network при открытии «Общего топа» — **один** запрос к `student_equipment`, не 10.

### Команды проверки
```bash
git -C D:/Sashamath_bot_2 --no-pager diff -- js/student-progress.js | grep -n -E '^[-+].*(get_student_league_snapshot_self|preview_league_close_self|ensure_current_season|equipmentQuery|\.in\()'
```
> Ожидаемый вывод: только перемещения строк, без изменения самих вызовов.
```bash
grep -n -E 'equipmentQuery\((ids|currentUser)' js/student-progress.js
```
```bash
for c in lb-item lb-me lb-promote lb-demote lb-rank lb-avatar lb-name-wrap lb-name-line lb-title lb-score league-badge league-note league-standing league-ladder ladder-step achieved current; do grep -q "\.$c" styles/student.css || echo "NO CSS: $c"; done; echo "check done"
```
```bash
grep -c 'innerHTML' js/student-progress.js
```
> Значение не должно вырасти.

### Риски
- **R8** — соблазн собрать строку участника шаблонной строкой: имена и титулы из БД → XSS.
- **R12** — новая функция-хелпер с именем, уже занятым в другом student-файле → `SyntaxError`.
- Разбиение batch-запроса экипировки на per-строку → N+1 и заметное замедление (в коде явно
  помечено «не N+1»).
- **R4** — цвет ника: любые новые правила `color` внутри `.lb-name-line`.

### Рекомендуемый коммит
```
feat(ui): redesign leagues and global leaderboard (Cosmic Academy stage 6)
```

---

## Этап 7. Магазин, cosmetics и custom title modal

### Цель
Перерисовать `#screen-shop`, превью косметики и модальное окно персонального титула.

### Изменяемые файлы
- `index.html` — `#screen-shop`, `#custom-title-modal`;
- `styles/student.css`;
- `js/student-shop.js` — только разметка `shopSectionTitle`, `shopPreview`, `shopBuyButton`,
  `renderShopItem`, `openCustomTitleModal`, `updateCustomTitleForm`.

### Что делать
1. **Перед изменением `shopPreview` — обязательный вопрос пользователю (R13).**
   В истории уже есть `bb89030 style(shop): redraw cosmetic previews`, откаченный коммитом
   `a26a98a revert(shop): restore emoji previews`. Причина отката в репозитории не зафиксирована.
   Не приступать к переработке превью, пока пользователь не скажет, что тогда не устроило.
   Пока ответа нет — ограничиться размерами/фоном/рамкой `.shop-preview`, оставив эмодзи.
2. `.shop-item` — grid `58px / 1fr / auto`, на ≤380 px схлопывается в 2 колонки с переносом
   `.shop-action` (§13, §17). Пересмотреть под единый гибкий шаблон без второго breakpoint.
3. `.shop-preview` используется в трёх контекстах (§11) — ввести модификаторы размера
   (`.shop-preview--sm` для коллекций/витрины) вместо глобального медиазапроса.
4. Модалка: `#custom-title-modal.active` — механика показа через класс `.active` и inline
   `onclick="if (event.target === this) closeCustomTitleModal()"` сохраняются. Добавить
   `role="dialog"`, `aria-modal="true"`, блокировку прокрутки фона.
5. `.shop-emoji-chip` — **это данные из БД** (`render_payload.split(/\s+/)`), эмодзи не заменять.
6. `.custom-title-preview`, `.custom-title-error`, `.custom-title-count` — минимальные высоты
   оставить (защита от «прыжка» формы), но перевести на токены.

### Функции, которые нельзя менять
`loadShop` (все 8 параллельных запросов, `ensure_season_rotation`, фильтрация rotation/always),
`buyShopItem`, `equipShopItem`, `buyStreakShield`, `submitCustomTitle`, `customTitleValue`,
`closeCustomTitleModal`, `daysLeftInSeason`, `pluralDays`, `pluralShields`, `pluralBubliks`,
`SHIELD_MAX`, `SHIELD_PRICE`, вся ветвистая логика `renderShopItem` (title_custom pending/rejected,
service, shield, cosmetic owned/equipped/condition), проверка
`/^#[0-9a-fA-F]{6}$/` в `shopPreview`, валидация длины 3–24 в `updateCustomTitleForm`.

### DOM ID, которые требуется сохранить
`screen-shop`, `shop-balance`, `shop-content`, `custom-title-modal`, `custom-title-help`,
`custom-title-input`, `custom-title-count`, `custom-title-preview`, `custom-title-error`,
`custom-title-submit`. Плюс `val-huikons` — `buyShopItem`/`buyStreakShield`/`submitCustomTitle`
обновляют баланс на экране профиля напрямую по этому ID.

### Динамические классы, которые надо оформить
`shop-section-title`, `shop-section-note`, `shop-item`, `shop-preview`, `shop-body`, `shop-name`,
`shop-desc`, `shop-leaving`, `shop-action`, `shop-buy-btn`, `shop-state`, `owned`, `locked`,
`shop-equip-btn`, `shop-equipped`, `shop-emoji-chips`, `shop-emoji-chip`, `custom-title-text`,
`custom-title-reason`, `custom-title-input`, `custom-title-meta`, `custom-title-preview`,
`custom-title-error`, `custom-title-actions`, `custom-title-cancel`, `custom-title-submit`,
`active` (на `#custom-title-modal`).

### Критерии готовности
- [ ] Разделы «✨ Витрина сезона» и «🥯 Всегда в магазине» отображаются, включая случай пустой
      ротации («Сезонных товаров сейчас нет…»).
- [ ] Покупка обновляет `#shop-balance`, `#val-huikons`, перерисовывает витрину и историю.
- [ ] «Надеть»/«Снять» переключают экипировку и отражаются на профиле при возврате на вкладку.
- [ ] Условный товар показывает «🔒 Нужно: <название достижения>» (зависит от `ACHIEVEMENTS_META`).
- [ ] Плашка «Уйдёт с витрины через N дней» на ротационных товарах.
- [ ] Модалка титула: счётчик символов, превью ««…»», блокировка кнопки при <3 и >24, отмена по
      клику на фон, платный/бесплатный (retry) режим текста.
- [ ] На 360 px карточка товара не ломается: превью + название + цена + кнопка.

### Команды проверки
```bash
git -C D:/Sashamath_bot_2 --no-pager diff -- js/student-shop.js | grep -n -E '^[-+].*(buy_item_self|buy_item|equip_item|set_showcase|submit_custom_title|SHIELD_MAX|SHIELD_PRICE|studentSecurePathActive|grantCollectionBonus|0-9a-fA-F)'
```
> Ожидаемый вывод: пусто.
```bash
grep -n -E "getElementById\('(val-huikons|shop-balance|custom-title-[a-z]+)'\)" js/student-shop.js
```
```bash
for c in shop-section-title shop-section-note shop-item shop-preview shop-body shop-name shop-desc shop-leaving shop-action shop-buy-btn shop-state owned locked shop-equip-btn shop-equipped shop-emoji-chips shop-emoji-chip custom-title-text custom-title-reason custom-title-input custom-title-meta custom-title-preview custom-title-error custom-title-actions custom-title-cancel custom-title-submit; do grep -q "\.$c" styles/student.css || echo "NO CSS: $c"; done; echo "check done"
```
```bash
grep -n '#custom-title-modal' styles/student.css
```

### Риски
- **R13** — повтор откаченного решения по превью косметики. **Блокирующий вопрос пользователю.**
- **R9** — кнопки покупки без `btn.disabled = true` до `await` → двойные списания.
- **R11** — `renderShopItem` читает `ACHIEVEMENTS_META` для подписи условия; изменение метаданных
  на этапе 2/4 отражается здесь.
- Потеря `#val-huikons` → баланс на профиле не обновляется после покупки (молча).
- Замена `.shop-emoji-chip` на SVG невозможна — там данные из БД.

### Рекомендуемый коммит
```
feat(ui): redesign shop, cosmetic previews and custom title modal (Cosmic Academy stage 7)
```

---

## Этап 8. FAQ, состояния загрузки и финальная адаптивность

### Цель
Перерисовать `#screen-more`, унифицировать состояния загрузки/пустоты/ошибки и довести
адаптивность до корректных 360 px без магических чисел.

### Изменяемые файлы
- `index.html` — `#screen-more`, все инлайновые заглушки загрузки (§7.7, §17);
- `styles/student.css` — финальная чистка;
- все `js/student-*.js` — **только строки-заглушки** («Загрузка…», «Ошибка …», пустые состояния).

### Что делать
1. `#screen-more`: 14 `details.faq-item` — на новую типографику; `summary::before` (`▸`/`▾`)
   заменить на SVG-шеврон или оставить; кнопка «👪 Пригласить родителя» (`onclick="inviteParent()"`)
   и ссылка «💬 Связаться с учителем» — контракт сохранить, инлайновые `style` убрать.
2. Ввести **единые** компоненты состояний вместо пяти нынешних (§7.7):
   `.ca-state`, `.ca-state--loading`, `.ca-state--empty`, `.ca-state--error`.
   Существующие `.summary-empty`, `.chart-empty`, `.showcase-picker-empty` — **не удалять**,
   а привести к общему виду (они приходят из JS).
   Инлайновые `style="text-align:center; padding:20|30px; opacity:0.5"` в
   `#league-content`, `#shop-content`, `#lb-list`, `#my-hw-list`, `#balance-history-list` —
   заменить на класс. Аналогично `style="color:#f44336"` в шести местах.
3. Убрать оба дублирующихся `@media (max-width: 380px)` и `.coll-grid`-дубль (§13.5); свести
   всё к одному согласованному набору правил.
4. Проверить и устранить все магические размеры из таблицы §17, кроме тех, что уже переведены
   на токены на этапах 1–7.
5. Добавить `@media (min-width: 480px)` с `max-width` контейнера — сейчас в Telegram Desktop
   всё растягивается на полную ширину окна.
6. Пересмотреть `<meta name="viewport" … maximum-scale=1.0, user-scalable=no>` — блокировка
   масштабирования вредит доступности. **Изменение поведения зума нужно согласовать с
   пользователем**, по умолчанию оставить как есть.

### Функции, которые нельзя менять
`inviteParent` (создание одноразового токена `create_parent_invite_self`, формирование ссылки,
`openTelegramLink`), все `load*`-функции по логике, тексты, несущие продуктовый смысл (FAQ,
сообщения о дедлайнах, суммы наград).
**Тексты FAQ не переписывать** — они описывают действующие правила экономики (Stage 2.5/4).

### DOM ID, которые требуется сохранить
`screen-more`; и, поскольку меняются заглушки во всех файлах — весь список §4 аудита целиком.

### Динамические классы, которые надо оформить
`summary-empty`, `chart-empty`, `showcase-picker-empty` + новые `.ca-state*`.
Плюс проверить, что после чистки медиазапросов остались работоспособными:
`ach-grid`, `coll-grid`, `showcase-grid`, `shop-item`, `shop-preview`, `week-days-strip`.

### Критерии готовности
- [ ] Ни одного `style="…"` в `index.html`, кроме `display:none` на элементах, которыми
      управляет JS.
- [ ] Один `@media (max-width: …)` блок вместо трёх; дублей нет.
- [ ] Все состояния «загрузка / пусто / ошибка» выглядят одинаково на всех пяти экранах.
- [ ] При ширине 320/360/390/430 px горизонтальной прокрутки нет ни на одном экране.
- [ ] В Telegram Desktop (широкое окно) контент не растягивается на всю ширину.
- [ ] `prefers-reduced-motion` отключает все анимации.
- [ ] FAQ-тексты не изменены ни на символ (проверяется diff).

### Команды проверки
```bash
git -C D:/Sashamath_bot_2 --no-pager diff -- index.html | grep -E '^[-+]' | grep -i -E 'бублик|очк|щит|дедлайн|23:59|титул' | head -40
```
> Ожидаемый вывод: пусто (продуктовые тексты не менялись).
```bash
grep -c -o -E 'style="[^"]*"' index.html
```
```bash
grep -n '@media' styles/student.css
```
```bash
grep -n -E 'padding:\s*(20|25|30)px|75px|52px|65px' styles/student.css
```
```bash
python -m http.server 8080
```
> Проверить на ширинах 320 / 360 / 390 / 430 и в тёмной теме.

### Риски
- Изменение FAQ-текстов = изменение продуктовых правил, которые ученики читают как инструкцию.
- Удаление `.summary-empty` / `.chart-empty` / `.showcase-picker-empty` вместо их переоформления
  → пустые состояния теряют стили (эти классы приходят из JS).
- Снятие `user-scalable=no` меняет поведение жестов в Telegram WebView — согласовать.
- Ужимание `.screen { padding: 20px }` затрагивает **все пять экранов сразу**.

### Рекомендуемый коммит
```
feat(ui): unify FAQ, loading states and responsive layout (Cosmic Academy stage 8)
```

---

## Этап 9. Регрессионная проверка

### Цель
Подтвердить, что после восьми этапов ни один контракт UI ↔ JS ↔ сервер не нарушен, и
зафиксировать результат.

### Изменяемые файлы
- `scripts/check_ui_contract.py` (создаётся здесь, если не создан на этапе 1);
- `docs/COSMIC_ACADEMY_AUDIT.md` — добавить раздел «Состояние после редизайна»;
- при обнаружении дефектов — точечные правки в уже изменённых файлах.
**Новой функциональности на этом этапе не добавлять.**

### Автоматические проверки (все три должны пройти)

```bash
grep -o -E "getElementById\('[^']*'\)" js/student-*.js | sed "s/.*getElementById('//;s/')//" | sort -u > /tmp/ids_used.txt; grep -o -E 'id="[^"]*"' index.html | sed 's/id="//;s/"$//' | sort -u > /tmp/ids_have.txt; comm -23 /tmp/ids_used.txt /tmp/ids_have.txt
```
> Ожидаемый вывод: ровно одна строка — `exam-info-box`.

```bash
for fn in switchTab switchHwTab switchLbMode buyStreakShield showAssignmentDetails handleFileSelect uploadDZ inviteParent closeCustomTitleModal updateCustomTitleForm submitCustomTitle selectWeekDay showExamInfo claimTodayLife replaceTodayLife openNowAssignment openShowcasePicker setShowcase buyShopItem equipShopItem openCustomTitleModal applyWeekShield removeWeekShield; do grep -qs "function $fn" js/student-*.js || echo "MISSING FUNCTION: $fn"; done; echo "functions check done"
```
> Ожидаемый вывод: `functions check done` без строк `MISSING`.

```bash
git -C D:/Sashamath_bot_2 --no-pager diff --name-only origin/main | grep -E '^(supabase/|database/|main\.py|parent_bot\.py|js/student-auth\.js|js/teacher-|styles/teacher\.css|teacher\.html)' && echo "STOP: затронут запретный контур" || echo "OK: backend/teacher/auth не тронуты"
```
> Ожидаемый вывод: `OK: backend/teacher/auth не тронуты`.

```bash
git -C D:/Sashamath_bot_2 --no-pager diff --stat origin/main
```

```bash
git -C D:/Sashamath_bot_2 status --porcelain
```
> Убедиться, что `.claude/` и `tools/` по-прежнему только `??` и не попали ни в один коммит.

### Ручной регрессионный чек-лист (в Telegram, dev-бот)

**Профиль**
- [ ] Имя, аватар, группа, звание, прогресс звания, титул.
- [ ] Рейтинг и бублики совпадают с БД.
- [ ] Неделя: 7 дней, статусы, раскрытие дня, «Прикрыть щитом» / «Отменить щит».
- [ ] Строки «Еженедельное», «Назначено/Принято/Эффективно», прогноз награды.
- [ ] «Сделать сейчас»: счётчик, переход на «Домашку» с предвыбором.
- [ ] «Сегодня»: два квеста, «Выполнил честно», 🔁 замена, бонус за оба, серия.
- [ ] График пробников: точки кликабельны, `#exam-info-box` меняется.
- [ ] Щиты: счётчик, покупка, лимит 7.
- [ ] Витрина: 3 слота, пикер, «Убрать».
- [ ] Достижения: полученные/закрытые, legacy только у владельцев.
- [ ] Коллекции: сезонные наборы, силуэты, бонус при полной коллекции.
- [ ] История изменений и история сезонов.

**Домашка**
- [ ] Список активных заданий, детали, ссылка, комментарий учителя.
- [ ] Множественный выбор фото, отправка, сброс формы.
- [ ] Отказ при истёкшем дедлайне.
- [ ] Архив: бейджи и комментарии.

**Лидеры**
- [ ] Моя лига: бейдж, пояснения, места, ↑/↓, лестница из 7.
- [ ] Общий топ: медали, «(Вы)», номер сезона.
- [ ] Косметика участников в обеих таблицах.

**Магазин**
- [ ] Ротация и «Всегда в магазине», баланс, покупка, Надеть/Снять.
- [ ] Условные товары, персональный титул (создать / на модерации / исправить).

**Ещё**
- [ ] 14 вопросов FAQ раскрываются, тексты не изменены.
- [ ] «Пригласить родителя» открывает шаринг ссылки.

**Кросс-проверки**
- [ ] Светлая и тёмная тема Telegram.
- [ ] Ширина 320 / 360 / 390 / 430 px — без горизонтальной прокрутки.
- [ ] iOS: нижняя панель не под индикатором «домой».
- [ ] Консоль без ошибок на всех пяти экранах.
- [ ] Двойные быстрые клики по «Купить», «Выполнил честно», «Прикрыть щитом» не дают двойного
      эффекта.

### Функции, которые нельзя менять
На этом этапе — **все**. Допустимы только исправления найденных регрессий, каждое из которых
относится к своему этапу и оформляется отдельным `fix(ui): …`.

### Риски
- Регрессия обнаруживается только на реальных данных (пустой профиль, ученик без группы,
  ученик вне сезона, коллекция без бандла, пустая ротация) — тестировать на нескольких профилях.
- Проверки `grep` не ловят синтаксические ошибки JS: без `node` единственный надёжный способ —
  открыть страницу и посмотреть консоль (`python -m http.server`, затем Telegram).

### Рекомендуемый коммит
```
test(ui): Cosmic Academy regression pass and UI contract checks (stage 9)
```

---

## Приложение А. Сводная таблица этапов

| Этап | Файлы | JS-логика | Ключевой риск | Коммит |
|---|---|---|---|---|
| 1. Токены, тема, фон, AppShell | CSS, head, (app.js) | нет | R3 фон профиля, R4 золотой ник | `feat(ui): design tokens…` |
| 2. SVG-иконки и навигация | HTML, CSS, +поле в META | нет | R2 порядок кнопок, R11 META | `feat(ui): SVG icon sprite…` |
| 3. Профиль, неделя, «Сделать сейчас» | HTML, CSS, week.js, assignments.js | только шаблоны | R6 display, потеря `data-assignment-id` | `feat(ui): redesign profile header…` |
| 4. Квесты, пробники, витрина, истории | HTML, CSS, quests.js, progress.js, shop.js | только шаблоны | R5 `exam-info-box`, R7 бонус коллекции | `feat(ui): redesign quests…` |
| 5. Домашка и архив | HTML, CSS, assignments.js | только шаблоны | select→кастом ломает `openNowAssignment`, R15 | `feat(ui): redesign homework…` |
| 6. Лиги и общий топ | HTML, CSS, progress.js | 1 хелпер | R8 XSS, N+1, R12 имена | `feat(ui): redesign leagues…` |
| 7. Магазин и модалка титула | HTML, CSS, shop.js | только шаблоны | **R13 — блокирующий вопрос** | `feat(ui): redesign shop…` |
| 8. FAQ, состояния, адаптивность | HTML, CSS, все student-*.js (заглушки) | нет | изменение продуктовых текстов | `feat(ui): unify FAQ…` |
| 9. Регрессия | scripts/, docs/ | нет | регрессии на краевых данных | `test(ui): Cosmic Academy regression…` |

## Приложение Б. Открытые вопросы к пользователю

Эти вопросы **не блокируют этапы 1–6**, но должны быть решены до соответствующих этапов:

1. **(до этапа 7, блокирующий)** Что именно не устроило в откаченном редизайне превью косметики
   (`bb89030` → `a26a98a`)? Без ответа `shopPreview` не переделывать.
2. **(до этапа 5)** `.my-hw-item.status-*` не работает с момента написания (§13.6-1). Чинить
   (добавить `status-submitted`/`status-checked`) или оставить как есть?
3. **(до этапа 1)** Вариант глобального фона: A — слой `body::before` (рекомендуется) или
   B — обёртка `.ca-shell` вокруг экранов?
4. **(до этапа 8)** Снимать ли `maximum-scale=1.0, user-scalable=no` из viewport?
5. **(до этапа 2)** Заменять ли `WEEK_DAY_MARKS` (символы состояний дня) на SVG? По умолчанию —
   нет, оставляем символы.
6. **(до этапа 1)** Оставить ли `frame-*` и `#screen-profile.bg-*` с их фирменными хардкод-цветами
   вне системы токенов (они — платный контент магазина)?

---

*Конец плана. Реализация не начиналась.*
