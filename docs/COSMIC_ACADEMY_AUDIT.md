# COSMIC ACADEMY — подготовительный технический аудит ученического Mini App

Документ создан **2026-07-25**. Это подготовительный аудит **перед** редизайном «Cosmic Academy».
Ни один файл интерфейса, backend, SQL, Telegram-аутентификации, Supabase или RPC в рамках этого
аудита **не изменялся**.

---

## 0. Источник данных аудита и состояние git

### 0.1. Что именно проаудировано

Актуальные файлы Mini App лежат в репозитории **`sasha-math-bot-2`** (GitHub:
`billyrubinius-crypto/sasha-math-bot-2`). Локальные рабочие копии устарели, поэтому аудит
выполнен по **`origin/main` = `e5f675b` «fix(auth): capture username at student registration»**
(содержимое извлечено через `git show origin/main:<путь>`, рабочее дерево не трогалось).

Проаудированные файлы и их размер в `origin/main`:

| Файл | Байт |
|---|---|
| `index.html` | 23 314 |
| `styles/student.css` | 33 358 |
| `shared.js` | 5 678 |
| `js/student-core.js` | 5 516 |
| `js/student-assignments.js` | 24 349 |
| `js/student-week.js` | 10 941 |
| `js/student-progress.js` | 53 443 |
| `js/student-shop.js` | 39 535 |
| `js/student-quests.js` | 7 589 |
| `js/student-auth.js` | 5 104 |
| `js/student-app.js` | 2 717 |
| `database/schema.sql` | 282 203 (прочитан выборочно, в объёме UI) |

### 0.2. Состояние git на момент аудита

**Репозиторий Mini App — `D:\Sashamath_bot_2` (`sasha-math-bot-2`):**

- текущая ветка `main` = `fb68ea8` «feat(auth): game RLS for shop/weeks/leagues/quests (T10-08B)»;
- **`main` отстаёт от `origin/main` на 19 коммитов** (`origin/main` = `e5f675b`);
- изменённых отслеживаемых файлов **нет**;
- **неотслеживаемые каталоги в рабочем дереве (не трогались, в коммит не включать):**
  - `.claude/`
  - `tools/` (внутри: `supabase.exe`, `supabase-go.exe`, `supabase-cli`, `supabase_windows_amd64.tar.gz`).

**Рабочий каталог сессии — `D:\sashamath` (`sasha-math-bot`, публичный prod-репозиторий):**

- ветка `main` = `origin/main` = `7246081`, чисто;
- **неотслеживаемый каталог `.worktrees/` (не трогался, в коммит не включать).**
  Внутри — `.worktrees/bot2-auth-fix`: отдельный клон `sasha-math-bot-2` на ветке
  `codex/fix-student-registration-username` (`e5f675b`), рабочее дерево чистое.

> **Действие перед стартом реализации (за пользователем):** синхронизировать
> `D:\Sashamath_bot_2` с `origin/main` (`git pull --ff-only`), иначе работа пойдёт от кода,
> который на 19 коммитов старше проаудированного, и как минимум разъедутся `index.html`,
> `styles/student.css`, магазин и профиль (коммиты `e2cb91b`, `33411e1`, `bb89030`, `a26a98a`,
> `31c9e09`).

### 0.3. Доступный инструментарий на машине

`git` — есть. `python 3.13.7` — есть. **`node`, `npx`, `rg`, `deno`, `supabase`, `psql` в PATH
отсутствуют** (есть локальный `tools/supabase.exe`). Это учтено в разделе «команды проверки»
плана реализации: там нет `node --check` и `npm`-скриптов.

---

## 1. Структура пяти ученических экранов

Приложение — одностраничное, **все пять экранов одновременно присутствуют в DOM**, переключение
идёт классом `.active` (CSS: `.screen { display: none } .screen.active { display: block }`).
Отдельного router нет.

| # | DOM ID экрана | Заголовок в UI | Кнопка нижней навигации | Загрузчик |
|---|---|---|---|---|
| 1 | `#screen-profile` | (без `<h2>`, начинается с шапки профиля) | «👤 Профиль» (индекс 0) | `loadProfile()` |
| 2 | `#screen-homework` | (без `<h2>`, начинается с табов) | «📚 Домашка» (индекс 1) | `loadMyHomework()` + `loadActiveAssignments()` |
| 3 | `#screen-leaderboard` | «🏆 Лиги» | «🏆 Лидеры» (индекс 2) | `loadLeaderboard()` |
| 4 | `#screen-shop` | «🥯 Бубличная» | «🥯 Магазин» (индекс 3) | `loadShop()` |
| 5 | `#screen-more` | «⚙️ Ещё» | «⚙️ Ещё» (индекс 4) | — (полностью статический) |

Плюс два элемента вне экранов:

- `#custom-title-modal` — модальное окно персонального титула (`position: fixed; inset: 0; z-index: 2000`);
- `.bottom-nav` — нижняя навигация (`position: fixed; bottom: 0; height: 65px; z-index: 100`).

По умолчанию активен `#screen-profile` (класс `active` прямо в разметке).

### 1.1. Внутренние подрежимы экранов

- **Домашка:** два вида `.hw-view` — `#hw-upload` (активен по умолчанию) и `#hw-archive`,
  переключение `switchHwTab()` по классу `.active`; табы — `.tab-btn` внутри `.tabs-hw`,
  выбираются **по индексу** `document.querySelectorAll('.tab-btn')[0|1]`.
- **Лидеры:** два режима `.lb-mode` — `#lb-mode-league` (активен) и `#lb-mode-global`,
  переключение `switchLbMode()`; табы `#lb-tab-league` / `#lb-tab-global` (у них есть ID,
  но класс `.tab-btn` тот же, что у табов домашки).

---

## 2. Статическая разметка каждого экрана

### 2.1. `#screen-profile`

```
#screen-profile.screen.active
├── .profile-header
│   ├── .avatar-container#user-avatar-container          (пусто; заполняет setupAvatar)
│   └── .profile-identity
│       ├── h2.user-name#user-name                       («Загрузка...»)
│       └── .profile-meta-list
│           ├── .profile-meta-row#profile-group-row      [style="display:none"]
│           │   ├── span.profile-meta-label «Группа»
│           │   └── span.group-badge.profile-meta-value#group-badge
│           └── .profile-meta-row#profile-rank-row       [style="display:none"]
│               ├── span.profile-meta-label «Звание»
│               └── span.rank-badge.profile-meta-value#rank-badge
├── .rank-progress#rank-progress                         [style="display:none"]
├── .profile-title-card#profile-title-row                [style="display:none"]
│   ├── span.profile-title-icon 🏷️
│   └── .profile-title-copy
│       ├── .profile-title-label «Титул профиля»
│       └── .profile-title#profile-title
├── .study-stats.stats-grid
│   ├── .stat-card > .stat-val#val-rating + .stat-label «Рейтинг»
│   └── .stat-card > .stat-val#val-huikons + .stat-label «🥯 Бублики»
├── .week-block#week-block
│   ├── .week-block-head
│   │   ├── div > .week-block-title «Эта неделя» + .week-block-sub#week-block-sub
│   │   └── .week-progress#week-progress «—/7»
│   ├── .week-days-strip#week-days-strip                 (пусто; renderWeekStrip)
│   ├── .week-day-detail#week-day-detail                 (пусто; renderWeekDayDetail)
│   ├── div#week-weekly-row                              ⚠ БЕЗ класса
│   ├── div#week-totals                                  ⚠ БЕЗ класса
│   ├── div#week-forecast                                ⚠ БЕЗ класса
│   └── .now-section
│       ├── .now-head > .now-title «Сделать сейчас» + .now-count#now-count
│       └── .now-list#now-list > .summary-empty «Загрузка...»
├── .today-block#today-block
│   ├── .today-block-head > .today-block-title «Сегодня»
│   └── div#today-quests-content > .summary-empty «Загрузка...»
├── .mock-chart-section#mock-chart-section
│   ├── .chart-title «📊 Результаты пробников»
│   └── div#mock-chart-container > .chart-empty «Загрузка...»
├── .study-tools
│   ├── .streak-badge#streak-display        [display:none]  «🔥 0 дней»
│   ├── .streak-progress#streak-progress    [display:none; margin-bottom:20px]
│   └── .shield-widget#shield-widget        [display:none]
│       ├── .shield-info > span#shield-count «🛡 0 щитов» + span.shield-hint
│       └── button.shield-buy-btn#btn-buy-shield  onclick="buyStreakShield()"
├── .showcase-section#showcase-section      [display:none]
│   ├── .showcase-title «🌟 Витрина»
│   ├── .showcase-grid#showcase-grid
│   └── .showcase-picker#showcase-picker    [display:none]
├── .achievements-section#achievements-section [display:none]
│   ├── .achievements-title «🏆 Достижения»
│   └── .ach-grid#ach-grid
├── .collections-section#collections-section   [display:none]
│   ├── .collections-title «📦 Коллекции»
│   └── div#collections-list
├── .history-section#season-history-section    [display:none]
│   ├── .history-title «🏅 История сезонов»
│   └── ul.history-list#season-history-list
└── .history-section
    ├── .history-title « История изменений»            ⚠ ведущий пробел вместо эмодзи
    └── ul.history-list#balance-history-list > li[inline style] «Загрузка...»
```

### 2.2. `#screen-homework`

```
#screen-homework.screen
├── .tabs-hw
│   ├── button.tab-btn.active  onclick="switchHwTab('upload')"   «✏️ Решить домашку»
│   └── button.tab-btn         onclick="switchHwTab('archive')"  «🤓 Мои работы»
├── #hw-upload.hw-view.active
│   ├── .dz-section
│   │   ├── .dz-title [style="margin-bottom:10px"] «✏️ Решить домашку»
│   │   ├── p[inline style: text-align/font-size/color/margin/line-height]  инструкция
│   │   ├── .input-group
│   │   │   ├── label[inline style: font-weight/color/margin]
│   │   │   └── select#assignment-select onchange="showAssignmentDetails()"
│   │   ├── #assignment-details [inline style: display:none; background; radius:12px; padding:15px; margin-bottom:15px; border]
│   │   │   ├── div#detail-title    [inline: font-weight:700; margin-bottom:8px]
│   │   │   ├── div#detail-count    [inline: display:none; …]
│   │   │   ├── a#detail-link       [inline: color/text-decoration/word-break] «🔗 Открыть условие задачи»
│   │   │   └── div#detail-feedback [inline: display:none; фон rgba(220,53,69,.1); color:#721c24]
│   │   ├── .file-upload-area#upload-area  onclick="document.getElementById('file-input').click()"
│   │   │   ├── .upload-icon 📷
│   │   │   ├── .upload-text
│   │   │   └── .file-list#file-list
│   │   ├── input[type=file]#file-input onchange="handleFileSelect(event)"  (CSS: display:none)
│   │   ├── button.primary#btn-upload-dz [disabled][style="padding:16px"] onclick="uploadDZ()"
│   │   └── .dz-status#dz-status
│   └── div[inline: margin-top:20px; text-align:center; opacity:.6]  пояснение про награды
└── #hw-archive.hw-view
    └── ul.my-hw-list#my-hw-list > li[inline style] «Загрузка истории...»
```

### 2.3. `#screen-leaderboard`

```
#screen-leaderboard.screen
├── h2[inline: text-align:center; margin-bottom:12px] «🏆 Лиги»
├── .tabs-hw
│   ├── button.tab-btn.active#lb-tab-league  onclick="switchLbMode('league')"  «🏅 Моя лига»
│   └── button.tab-btn#lb-tab-global         onclick="switchLbMode('global')"  «🌍 Общий топ»
├── #lb-mode-league.lb-mode.active
│   └── #league-content > div[inline style] «Загрузка...»
└── #lb-mode-global.lb-mode
    ├── #lb-season-label [inline: text-align/opacity/font-size/margin-bottom:16px]
    └── ul.leaderboard-list#lb-list > li[inline style] «Загрузка...»
```

### 2.4. `#screen-shop`

```
#screen-shop.screen
├── h2[inline: text-align:center; margin-bottom:4px] «🥯 Бубличная»
├── .shop-balance#shop-balance
└── #shop-content > div[inline style] «Загрузка...»
```

### 2.5. `#screen-more`

Полностью статичен, JS его не трогает вообще.

```
#screen-more.screen
├── h2[inline: text-align:center; margin-bottom:20px] «⚙️ Ещё»
├── .faq-section
│   ├── .faq-title «❓ Частые вопросы»
│   └── details.faq-item × 14  (summary + .faq-answer)
├── button.more-link-btn [inline: width:100%; border:none; cursor:pointer; margin-bottom:12px]
│                        onclick="inviteParent()"  «👪 Пригласить родителя»
└── a.more-link-btn[href="https://t.me/tomhardy10" target=_blank]  «💬 Связаться с учителем»
```

### 2.6. `#custom-title-modal`

```
#custom-title-modal  onclick="if (event.target === this) closeCustomTitleModal()"
└── .custom-title-dialog
    ├── div[inline: font-size:var(--text-section); font-weight:800] «Персональный титул»
    ├── #custom-title-help [inline style]
    ├── input.custom-title-input#custom-title-input  oninput="updateCustomTitleForm()"
    ├── .custom-title-meta > span «От 3 до 24 символов…» + span#custom-title-count
    ├── .custom-title-preview#custom-title-preview
    ├── .custom-title-error#custom-title-error
    └── .custom-title-actions
        ├── button.custom-title-cancel  onclick="closeCustomTitleModal()"
        └── button.custom-title-submit#custom-title-submit  onclick="submitCustomTitle()"
```

---

## 3. Динамическая разметка, создаваемая JavaScript

Ниже — все точки, где JS формирует DOM. Помечено, **как именно** (innerHTML-строка vs
`createElement` + `textContent`), потому что это напрямую влияет на XSS-контур: строковые
шаблоны обязаны идти через `esc()`, DOM-путь безопасен по построению.

| Контейнер | Функция (файл) | Способ | Что создаётся |
|---|---|---|---|
| `#user-avatar-container` | `setupAvatar` (core) | innerHTML | `<img class="avatar-img">` **или** `.avatar-placeholder` (буква, через `esc`) |
| `#user-name` | `renderNick` (progress) | createElement | `span.nick-status?` + `span`(имя) + `span.nick-crown?` |
| `#week-days-strip` | `renderWeekStrip` (week) | innerHTML | 7 × `button.week-day-chip.wd-<status>[.today][.selected]` → `span.week-day-name` + `span.week-day-mark`, `onclick="selectWeekDay(i)"` |
| `#week-day-detail` | `renderWeekDayDetail` (week) | innerHTML | `.week-day-detail-main` (`.week-day-detail-title`, `.week-day-detail-note`) + опционально `button.week-shield-btn.apply|remove[data-action]`; обработчик навешивается `addEventListener` |
| `#week-weekly-row` | `loadWeekBlock` (week) | innerHTML | текст «🔥 Еженедельное: …» с `<b>` |
| `#week-totals` | `loadWeekBlock` (week) | innerHTML | «Назначено/Принято/Эффективно» с `<b>` |
| `#week-forecast` | `loadWeekBlock` (week) | textContent | прогноз недели |
| `#now-list` | `loadAssignmentsSummary` (assignments) | innerHTML | N × `button.now-item[data-assignment-id]` → `.now-icon` + `.now-main`(`.now-item-title`,`.now-item-meta`) + `.now-arrow`; либо `.summary-empty` |
| `#today-quests-content` | `renderTodayQuests` (quests) | innerHTML | 2 × life-`.quest-row` + combo-`.quest-row` |
| `#mock-chart-container` | `renderMockChart` (progress) | innerHTML | inline `<svg viewBox="0 0 320 140">` (grid-`line`+`text`, `polyline`, `circle onclick="showExamInfo(i)"`, подписи `text`) + **`div#exam-info-box.exam-info-box`** + `.chart-disclaimer` |
| `#streak-progress` | `renderStreakProgress` (progress) | innerHTML | `.streak-dots` × 3 `.streak-dot[.filled]` + `.streak-note` |
| `#balance-history-list` | `loadBalanceHistory` (progress) | createElement + innerHTML на `li` | `li.history-item` → `.hist-info`(`.hist-reason`,`.hist-date`) + `.hist-amount.hist-positive|hist-negative` |
| `#season-history-list` | `loadSeasonHistory` (progress) | createElement + innerHTML | `li.history-item` → `.hist-info > .hist-reason` + `.hist-amount` |
| `#ach-grid` | `loadAchievements` (progress) | createElement + innerHTML | `div.ach-tile[.locked]` → `.ach-icon` + `.ach-name` |
| `#collections-list` | `loadCollections` (shop) | createElement | `.collection-block` → `.collection-season-title` + `.coll-grid` → `.coll-tile[.locked]`(`shopPreview()` + `.coll-name`) |
| `#showcase-grid` | `loadShowcase` (shop) | createElement (+ innerHTML для пустого) | 3 × `.showcase-tile[.empty]`, внутри `.showcase-icon`/`shopPreview()` + `.showcase-name`; `tile.onclick = openShowcasePicker(pos)` |
| `#showcase-picker` | `openShowcasePicker` (shop) | createElement | `.showcase-picker-title` + `button.showcase-chip.showcase-chip-clear` + N × `button.showcase-chip`; либо `.showcase-picker-empty` |
| `#shop-content` | `loadShop` / `renderShopItem` (shop) | createElement | `.shop-section-title` + `.shop-section-note` + N × `.shop-item`(`shopPreview()` + `.shop-body` + `.shop-action`) |
| `#assignment-select` | `loadActiveAssignments` (assignments) | createElement `option` | `option` c эмодзи-префиксом типа |
| `#file-list` | `handleFileSelect` (assignments) | createElement + innerHTML | `div.file-item > span` (имя файла через `esc`) |
| `#my-hw-list` | `loadMyHomework` (assignments) | createElement + innerHTML | `li.my-hw-item.status-<status>` → `.hw-header`(`.hw-variant`,`.hw-pages`,`.hw-date`,`.hw-badge.badge-*`) + `.hw-comment[.rejected]` |
| `#league-content` | `loadLeague` (progress) | innerHTML (шапка) + createElement (список) | `.league-badge`, `.league-note` ×N, `.league-standing`, `ul.leaderboard-list` → `li.lb-item[.lb-me][.lb-promote][.lb-demote]` → `.lb-rank` + `.lb-avatar` + `.lb-name-wrap`(`.lb-name-line`,`.lb-title`) + `.lb-score`; в конце `div > ul.league-ladder > li.ladder-step[.current|.achieved]` |
| `#lb-list` | `loadGlobalTop` (progress) | createElement | `li.lb-item[.lb-me]` → `.lb-rank` + `.lb-avatar` + `.lb-name-wrap` + `.lb-score` |
| `#shop-balance` | `loadShop` (shop) | innerText | «Баланс: N бубликов 🥯» |

### 3.1. Единственный DOM ID, создаваемый динамически

**`#exam-info-box`** — рождается внутри `renderMockChart()` строкой innerHTML и затем читается в
`showExamInfo(index)`. Это единственный ID, которого нет в `index.html`. При редизайне графика
пробников его **нельзя потерять или переименовать**, иначе клик по точке молча перестанет
работать (`showExamInfo` делает `if (!p || !box) return;` — без ошибки в консоли).

---

## 4. Полный перечень DOM ID, используемых из JavaScript

72 идентификатора, читаемых через `document.getElementById(...)`:

```
ach-grid                achievements-section     assignment-details      assignment-select
balance-history-list    btn-buy-shield           btn-upload-dz           collections-list
collections-section     custom-title-count       custom-title-error      custom-title-help
custom-title-input      custom-title-modal       custom-title-preview    custom-title-submit
detail-count            detail-feedback          detail-link             detail-title
dz-status               exam-info-box*           file-list               group-badge
hw-archive              hw-upload                lb-list                 lb-mode-global
lb-mode-league          lb-season-label          lb-tab-global           lb-tab-league
league-content          mock-chart-container     my-hw-list              now-count
now-list                profile-group-row        profile-rank-row        profile-title
profile-title-row       rank-badge               rank-progress           screen-homework
screen-leaderboard      screen-more              screen-profile          screen-shop
season-history-list     season-history-section   shield-count            shield-widget
shop-balance            shop-content             showcase-grid           showcase-picker
showcase-section        streak-display           streak-progress         today-quests-content
upload-area             user-avatar-container    user-name               val-huikons
val-rating              week-block               week-block-sub          week-day-detail
week-days-strip         week-forecast            week-progress           week-totals
week-weekly-row
```
`*` — `exam-info-box` создаётся динамически (см. 3.1).

**ID, которые есть в разметке, но JS их не читает** (можно перестраивать свободнее, но они
несут CSS/структуру):

- `#file-input` — используется только из inline-обработчика `#upload-area`
  (`document.getElementById('file-input').click()`), CSS-правило `#file-input { display: none }`;
- `#today-block` — только контейнер/CSS;
- `#mock-chart-section` — только контейнер/CSS.

**Выборки не по ID, критичные для навигации** (ломаются при изменении порядка или классов):

| Селектор | Где | Чувствительность |
|---|---|---|
| `document.querySelectorAll('.screen')` | `switchTab` | все 5 экранов должны иметь класс `.screen` |
| `document.querySelectorAll('.nav-btn')[0..4]` | `switchTab` | **порядок кнопок нижней навигации жёстко зашит индексами 0–4** |
| `document.querySelectorAll('.hw-view')` | `switchHwTab` | оба вида домашки |
| `document.querySelectorAll('.tab-btn')[0..1]` | `switchHwTab` | **берёт первые два `.tab-btn` в документе**; сейчас это табы домашки только потому, что `#screen-homework` идёт в разметке раньше `#screen-leaderboard` |
| `detail.querySelector('[data-action]')` | `renderWeekDayDetail` | кнопка щита дня |
| `list.querySelectorAll('.now-item')` | `loadAssignmentsSummary` | навешивание кликов |
| `document.querySelectorAll('.life-row-trailing button')` | `setLifeControlsDisabled` | блокировка кнопок квестов |
| `area.querySelector('.upload-text')`, `area.querySelector('.upload-icon')` | `handleFileSelect`, `uploadDZ` | внутренности зоны загрузки |

> **Критично:** `switchHwTab` берёт `.tab-btn` **по глобальному индексу**, а такой же класс
> используется в табах лидерборда. Любая перестановка экранов местами в `index.html` или
> добавление нового `.tab-btn` выше — молча переключит не тот таб.

---

## 5. Глобальные функции, вызываемые из inline-обработчиков

### 5.1. Из статической разметки `index.html`

| Обработчик | Функция | Файл-владелец |
|---|---|---|
| `onclick` × 5 (`.nav-btn`) | `switchTab('profile'\|'homework'\|'leaderboard'\|'shop'\|'more')` | `student-core.js` |
| `onclick` × 2 (`.tab-btn`) | `switchHwTab('upload'\|'archive')` | `student-core.js` |
| `onclick` × 2 (`#lb-tab-*`) | `switchLbMode('league'\|'global')` | `student-progress.js` |
| `onclick` `#btn-buy-shield` | `buyStreakShield()` | `student-shop.js` |
| `onchange` `#assignment-select` | `showAssignmentDetails()` | `student-assignments.js` |
| `onclick` `#upload-area` | inline: `document.getElementById('file-input').click()` | — (в разметке) |
| `onchange` `#file-input` | `handleFileSelect(event)` | `student-assignments.js` |
| `onclick` `#btn-upload-dz` | `uploadDZ()` | `student-assignments.js` |
| `onclick` `.more-link-btn` | `inviteParent()` | `student-core.js` |
| `onclick` `#custom-title-modal` | inline: `if (event.target === this) closeCustomTitleModal()` | — (в разметке) |
| `onclick` `.custom-title-cancel` | `closeCustomTitleModal()` | `student-shop.js` |
| `oninput` `#custom-title-input` | `updateCustomTitleForm()` | `student-shop.js` |
| `onclick` `#custom-title-submit` | `submitCustomTitle()` | `student-shop.js` |

### 5.2. Из динамически генерируемого HTML (тоже inline, тоже глобальные)

| Обработчик | Функция | Где генерируется |
|---|---|---|
| `onclick="selectWeekDay(${index})"` | `selectWeekDay` | `renderWeekStrip` (`student-week.js`) |
| `onclick="showExamInfo(${i})"` на `<circle>` в SVG | `showExamInfo` | `renderMockChart` (`student-progress.js`) |
| `onclick="claimTodayLife(${slot})"` | `claimTodayLife` | `buildLifeRow` (`student-quests.js`) |
| `onclick="replaceTodayLife(${slot})"` | `replaceTodayLife` | `buildLifeRow` (`student-quests.js`) |

### 5.3. Обработчики, навешиваемые программно (не inline, но такие же точки отказа)

- `applyWeekShield(assignmentId, btn)` / `removeWeekShield(assignmentId, btn)` — `addEventListener` на `[data-action]`;
- `openNowAssignment(id)` — `addEventListener` на `.now-item` по `data-assignment-id`;
- `openShowcasePicker(pos)` — `tile.onclick`;
- `setShowcase(pos, kind, refCode)` — `chip.onclick`;
- `buyShopItem(code, variant, btn)` — `btn.onclick` / `chip.onclick`;
- `equipShopItem(slot, itemCode, btn)` — `btn.onclick`;
- `openCustomTitleModal(value, isRetry)` — `btn.onclick` в карточке `title_custom`;
- `document.addEventListener('DOMContentLoaded', …)` — единственная точка старта (`student-app.js`).

> Все перечисленные функции — **глобальные объявления верхнего уровня в classic-скриптах**.
> Перевод любого из файлов в `type="module"`, оборачивание в IIFE или бандлинг **сломает все
> inline-обработчики разом**. Это главный архитектурный ограничитель редизайна.

---

## 6. CSS-классы, создаваемые динамически

Полный список классов, которые появляются только в рантайме. Их обязательно нужно оформить в
новой дизайн-системе — иначе элемент отрисуется, но без стилей.

**Неделя (`student-week.js`)**
`week-day-chip`, `wd-not_assigned`, `wd-assigned`, `wd-submitted`, `wd-revision`, `wd-approved`,
`wd-missed`, `wd-shielded`, `today`, `selected`, `week-day-name`, `week-day-mark`,
`week-day-detail-main`, `week-day-detail-title`, `week-day-detail-note`, `week-shield-btn`,
`apply`, `remove`, `open` (модификатор на `#week-day-detail`).

**«Сделать сейчас» (`student-assignments.js`)**
`now-item`, `now-icon`, `now-main`, `now-item-title`, `now-item-meta`, `now-arrow`, `summary-empty`.

**Квесты (`student-quests.js`)**
`quest-row`, `quest-row-icon`, `quest-row-main`, `quest-row-title`, `quest-row-meta`,
`quest-row-note`, `quest-row-trailing`, **`life-row-trailing`** (используется как селектор в
`setLifeControlsDisabled` — это не только стиль, но и «хук»), `quest-badge`, `quest-badge-paid`,
`quest-badge-wait`, `quest-badge-locked`, `quest-claim-btn`, `quest-replace-btn`.

**Стрик / пробники (`student-progress.js`)**
`streak-dots`, `streak-dot`, `filled`, `streak-note`, `exam-info-box`, `chart-disclaimer`,
`chart-empty`.

**История (`student-progress.js`)**
`history-item`, `hist-info`, `hist-reason`, `hist-date`, `hist-amount`, `hist-positive`,
`hist-negative`.

**Достижения (`student-progress.js`)**
`ach-tile`, `locked`, `ach-icon`, `ach-name`.

**Коллекции / витрина (`student-shop.js`)**
`collection-block`, `collection-season-title`, `coll-grid`, `coll-tile`, `locked`, `coll-name`,
`showcase-tile`, `empty`, `showcase-icon`, `showcase-name`, `showcase-picker-title`,
`showcase-chip`, `showcase-chip-clear`, `showcase-picker-empty`.

**Магазин (`student-shop.js`)**
`shop-section-title`, `shop-section-note`, `shop-item`, `shop-preview`, `shop-body`, `shop-name`,
`shop-desc`, `shop-leaving`, `shop-action`, `shop-buy-btn`, `shop-state`, `owned`, `locked`,
`shop-equip-btn`, `shop-equipped`, `shop-emoji-chips`, `shop-emoji-chip`, `custom-title-text`,
`custom-title-reason`.

**Архив домашки (`student-assignments.js`)**
`my-hw-item`, **`status-submitted` / `status-checked`** (см. 12.1 — сейчас в CSS их нет),
`hw-header`, `hw-variant`, `hw-pages`, `hw-date`, `hw-badge`, `badge-pending`, `badge-approved`,
`badge-rejected`, `hw-comment`, `rejected`, `file-item`, `has-file` (на `#upload-area`).

**Лидерборд и лиги (`student-progress.js`)**
`leaderboard-list`, `lb-item`, `lb-me`, `lb-promote`, `lb-demote`, `lb-rank`, `lb-avatar`,
`lb-name-wrap`, `lb-name-line`, `lb-title`, `lb-score`, `league-badge`, `league-note`,
`league-standing`, `league-ladder`, `ladder-step`, `achieved`, `current`.

**Косметика (`student-progress.js`, whitelisted)**
`nick-gold`, `nick-status`, `nick-crown`, `avatar-img`, `avatar-placeholder`, `frame` (только
снимается, см. 12.2), и два белых списка:

```js
FRAME_CLASSES = frame-notebook, frame-winter, frame-fire100,
                frame-legend-1, frame-legend-2, frame-legend-3, frame-legend-4,
                frame-pulsar, frame-orbit
BG_CLASSES    = bg-grid, bg-space, bg-aurora, bg-draft
```

**Служебные модификаторы, переключаемые из JS**
`active` — на `.screen`, `.nav-btn`, `.tab-btn`, `.hw-view`, `.lb-mode`, `#custom-title-modal`
(шесть разных смыслов одного имени).

---

## 7. Существующие компоненты и повторяющиеся UI-паттерны

Кандидаты на унификацию в дизайн-системе Cosmic Academy — сейчас каждый описан своим набором
правил, хотя это одна и та же вещь:

### 7.1. «Карточка-панель» — 6 почти одинаковых определений

| Класс | background | radius | padding | shadow |
|---|---|---|---|---|
| `.week-block` | `--tg-secondary` | 16px | 15px | `0 3px 12px rgba(0,0,0,.07)` |
| `.today-block` | `--tg-secondary` | 16px | 15px | `0 3px 12px rgba(0,0,0,.07)` |
| `.mock-chart-section` | `--tg-secondary` | 16px | 15px | `0 3px 12px rgba(0,0,0,.07)` |
| `.stat-card` | `--tg-secondary` | 16px | 13px 10px | `0 3px 12px rgba(0,0,0,.07)` |
| `.faq-section` | `--tg-secondary` | 16px | 18px | `0 4px 15px rgba(0,0,0,.1)` |
| `.history-list` | `--tg-secondary` | 16px | 0 | `0 4px 15px rgba(0,0,0,.1)` |
| `.shop-item` | `--tg-secondary` | 16px | 11px | `0 3px 12px rgba(0,0,0,.07)` + border |
| `.dz-section` | `--tg-secondary` | **20px** | **25px** | нет |
| `.shield-widget` | `--tg-secondary` | **14px** | 12px 14px | `0 4px 15px rgba(0,0,0,.1)` |
| `.ach-tile` / `.showcase-tile` | `--tg-secondary` | **14px** | 12px 6px / 9px 5px | оба варианта тени |
| `.custom-title-dialog` | `--tg-secondary` | **14px** | 18px | `0 12px 35px rgba(0,0,0,.28)` |

→ **Токены `--radius-*`, `--pad-*`, `--elev-*` покроют весь этот разнобой (14/16/20 px радиусов,
две тени, четыре паддинга).**

### 7.2. «Заголовок секции» — 7 копий одного правила

`.week-block-title`, `.now-title`, `.today-block-title`, `.chart-title`, `.achievements-title`,
`.collections-title`, `.showcase-title`, `.history-title`, `.shop-section-title` — все
`font-size: var(--text-section); font-weight: 800`.

### 7.3. «Строка списка с иконкой» — 3 копии

`.now-item` (`.now-icon` 30×30, `.now-main`, `.now-arrow`), `.quest-row` (`.quest-row-icon` 30×30,
`.quest-row-main`, `.quest-row-trailing`), `.showcase-chip` — одна и та же структура
«иконка + двухстрочный текст + трейлинг».

### 7.4. «Строка ученика с косметикой» — 2 копии

`loadLeague()` и `loadGlobalTop()` создают **байт-в-байт одинаковую** структуру
`li.lb-item > .lb-rank + .lb-avatar + .lb-name-wrap(.lb-name-line + .lb-title) + .lb-score`.
Отличаются только источник данных и модификаторы `.lb-promote/.lb-demote`. Это готовый
единственный компонент.

### 7.5. «Список истории» — 2 копии

`loadBalanceHistory()` и `loadSeasonHistory()` создают `li.history-item > .hist-info(.hist-reason
[+ .hist-date]) + .hist-amount`.

### 7.6. «Кнопка покупки»

`.shop-buy-btn`, `.shield-buy-btn`, `.custom-title-submit` — все `background: #ff9800; color: white;
border: none; border-radius: 10px; font-weight: 700/800`. Плюс `.shop-equip-btn` (outline-вариант)
и `.quest-claim-btn` (использует `--tg-btn`).

### 7.7. «Пустое / загрузочное состояние» — 5 разных реализаций

- `.summary-empty` (класс, now-list и today-quests);
- `.chart-empty` (класс, график);
- `.showcase-picker-empty` (класс, пикер);
- `div[style="text-align:center; padding:30px; opacity:0.5"]` — инлайн, в `#league-content`,
  `#shop-content`, `#lb-list`;
- `li[style="text-align:center; padding:20px; opacity:0.5"]` — инлайн, в `#my-hw-list`,
  `#balance-history-list`.

Ошибочные состояния — так же вразнобой: `style="color:#f44336"` инлайном в шести местах.

### 7.8. Склонения — 4 отдельные функции

`pluralBubliks` (`shared.js`), `pluralTasks` (`student-assignments.js`),
`pluralShields` / `pluralDays` (`student-shop.js`). Дублирование намеренное и **зафиксировано
комментариями в коде** — трогать не нужно.

---

## 8. Текущие Telegram Theme Params

### 8.1. Что используется

`styles/student.css`, блок `:root` (единственное место связи с темой Telegram):

```css
--tg-bg        : var(--tg-theme-bg-color,            #fff)
--tg-text      : var(--tg-theme-text-color,          #000)
--tg-hint      : var(--tg-theme-hint-color,          #999)
--tg-link      : var(--tg-theme-link-color,          #2481cc)
--tg-btn       : var(--tg-theme-button-color,        #2481cc)
--tg-btn-text  : var(--tg-theme-button-text-color,   #fff)
--tg-secondary : var(--tg-theme-secondary-bg-color,  #f0f0f0)
```

Плюс собственные токены типографики:
`--font-ui`, `--text-small: 12px`, `--text-body: 14px`, `--text-section: 16px`,
`--text-screen: 20px`, `--text-metric: 24px`.

### 8.2. Что НЕ используется (доступно, но проигнорировано)

Theme params: `--tg-theme-header-bg-color`, `--tg-theme-accent-text-color`,
`--tg-theme-section-bg-color`, `--tg-theme-section-header-text-color`,
`--tg-theme-section-separator-color`, `--tg-theme-subtitle-text-color`,
`--tg-theme-destructive-text-color`, `--tg-theme-bottom-bar-bg-color`.

WebApp API: `setHeaderColor`, `setBackgroundColor`, `setBottomBarColor`, `colorScheme`,
событие `themeChanged`, `BackButton`, `MainButton`, `SettingsButton`, `HapticFeedback`,
`viewportStableHeight`, `isVersionAtLeast`, `disableVerticalSwipes`, `enableClosingConfirmation`.

Из WebApp SDK используется **только**: `tg.ready()`, `tg.expand()`, `tg.initData`,
`tg.initDataUnsafe?.user`, `tg.openTelegramLink(...)` (в `inviteParent`).

### 8.3. Следствия для редизайна

1. **Хардкод цветов вне темы.** Помимо `--tg-*` в CSS используются ~30 жёстких значений:
   `#ff9800` (оранжевый акцент: щиты, стрик, кнопки покупки, `.custom-title-submit`),
   `#28a745`/`#43a047`/`#4caf50` (успех), `#dc3545`/`#f44336` (ошибка/понижение),
   `#ffc107` (исправление), `#2196f3` (отправлено), `#3b2d00`, `#721c24`, `#856404`, `#155724`,
   `#fff3cd`, `#d4edda`, `#f8d7da`, `#1e88e5`, `#4fc3f7`, `#ff7043`, `#e6a817`, `#f9d423`,
   `#7e57c2`, `#b388ff`, `#00bcd4`, `#3f51b5`, `#9e9e9e`, `#e67e22`, а также десятки
   `rgba(128,128,128,…)` и `rgba(36,129,204,…)` (последний — «захардкоженный» вариант
   `--tg-link`, который **не** следует за темой). **Ни одно из этих значений не адаптируется к
   светлой/тёмной теме Telegram.** Это ядро задачи «design tokens» этапа 1.
2. **Нет подписки на `themeChanged`.** CSS-переменные `--tg-theme-*` Telegram обновляет сам, и
   чисто CSS-часть за темой следует. Но всё, что JS проставляет инлайном
   (`el.style.color = payload` в `applyNickColor`, `p.style.background` в `shopPreview`,
   `status.style.color = "#f44336"` в `uploadDZ`), после смены темы остаётся прежним.
3. **Нет `prefers-color-scheme`** — единственный источник темы это Telegram; вне Telegram
   (обычный браузер) приложение всегда светлое по fallback-значениям.
4. **Нет управления цветом шапки/фона Telegram** — при глобальном «космическом» фоне шапка и
   нижняя панель Telegram останутся дефолтными, если не вызвать `setHeaderColor` /
   `setBackgroundColor` / `setBottomBarColor`.

---

## 9. Устройство нижней навигации

```html
<div class="bottom-nav">
  <button class="nav-btn active" onclick="switchTab('profile')">
    <span class="nav-icon">👤</span> Профиль
  </button>
  …ещё 4 такие же…
</div>
```

```css
.bottom-nav {
  position: fixed; bottom: 0; left: 0; right: 0; height: 65px;
  background: var(--tg-bg); display: flex;
  border-top: 1px solid rgba(128,128,128,0.15);
  z-index: 100; backdrop-filter: blur(10px); -webkit-backdrop-filter: blur(10px);
}
.nav-btn  { flex: 1; display: flex; flex-direction: column; align-items: center;
            justify-content: center; border: none; background: transparent;
            color: var(--tg-hint); font-size: 11px; cursor: pointer;
            transition: color .2s; padding: 8px 0; }
.nav-btn.active { color: var(--tg-link); }
.nav-icon { font-size: 22px; margin-bottom: 3px; }
body { padding-bottom: 75px; }   /* компенсация высоты панели */
```

Особенности и проблемы:

1. **Активное состояние выставляется по индексу**: `switchTab` делает
   `document.querySelectorAll('.nav-btn')[N].classList.add('active')`, где `N` = 0…4 жёстко.
   Порядок кнопок в разметке — часть контракта.
2. **Иконки — эмодзи-текст** внутри `.nav-icon`. Замена на SVG (этап 2) требует, чтобы
   `.nav-btn` продолжал содержать «иконка + подпись» и чтобы кнопка оставалась
   `<button class="nav-btn">` с тем же `onclick`.
3. **Текст подписи — прямой текстовый узел кнопки**, не обёрнут в элемент. Любая обёртка меняет
   вертикальную метрику flex-колонки.
4. **`backdrop-filter: blur(10px)` бесполезен**: фон `var(--tg-bg)` непрозрачен. Либо убрать,
   либо сделать фон полупрозрачным.
5. **Нет `env(safe-area-inset-bottom)`.** На iPhone с индикатором «домой» панель заходит под него.
   Аналогично `body { padding-bottom: 75px }` — магическое число (65 + 10), а не
   `calc(65px + env(safe-area-inset-bottom))`.
6. **Нет `role="tablist"` / `aria-selected`** — семантики вкладок нет вообще.
7. **`z-index: 100`** — ниже модалки (`2000`), это корректно.

---

## 10. Применение косметики

### 10.1. Цвет ника

**Источник данных:** `student_equipment` (slot `name_color`) → embed `shop_items.render_payload`
→ `buildEquipMap()` → `eq.name_color.payload`.

**Функция:** `applyNickColor(el, payload)` — `student-progress.js`:

```js
el.classList.remove('nick-gold');
el.style.color = '';
if (payload === 'gold') el.classList.add('nick-gold');
else if (/^#[0-9a-fA-F]{6}$/.test(payload || '')) el.style.color = payload;
```

**Куда применяется:** внутри `renderNick(container, baseName, eq, meSuffix)` — на `<span>` с
именем. Контейнеры-вызовы:

- `#user-name` — профиль (`applyProfileCosmetics`);
- `.lb-name-line` — каждая строка «Моей лиги» (`loadLeague`);
- `.lb-name-line` — каждая строка «Общего топа» (`loadGlobalTop`).

**Структура ника:** `[span.nick-status?] [span(имя+суффикс)] [span.nick-crown?]`. Эмодзи-статус
берётся из `eq.status_emoji.variant`, корона — литерал `👑` (не из БД).

**CSS:**

```css
.nick-gold { background: linear-gradient(135deg,#f9d423 0%,#e6a817 50%,#f9d423 100%);
             -webkit-background-clip: text; background-clip: text;
             -webkit-text-fill-color: transparent; color: transparent; font-weight: 800; }
.nick-crown, .nick-status { margin: 0 3px; -webkit-text-fill-color: initial; }
```

**Риски редизайна:**

- `.nick-gold` работает через `background-clip: text` + прозрачную заливку. Любое новое правило,
  задающее `color` или `-webkit-text-fill-color` на потомков `#user-name` / `.lb-name-line`
  с большей специфичностью, **сделает золотой ник невидимым**.
- Обычные цвета ставятся **инлайн-стилем** — их не перебить ничем, кроме `!important`.
  Значит, в новой теме нельзя задавать цвет имени через CSS «сверху».
- Регулярка `/^#[0-9a-fA-F]{6}$/` — это защитный фильтр от произвольного CSS из БД. **Менять
  нельзя.**

### 10.2. Рамки аватара

**Источник:** `student_equipment` slot `frame` → `eq.frame.payload` (строка вида `frame-orbit`).

**Функция:** `applyAvatarFrame(container, eq)`:

```js
FRAME_CLASSES.forEach(c => container.classList.remove(c));
container.classList.remove('frame');
if (eq.frame && FRAME_CLASSES.has(eq.frame.payload)) container.classList.add(eq.frame.payload);
```

**Куда применяется:** `#user-avatar-container` (40×40, профиль) и `.lb-avatar` (32×32, обе
таблицы лидеров).

**CSS-механика (9 рамок):**

- база — «кольцо» из двух `box-shadow`: `0 0 0 2px var(--tg-bg), 0 0 0 4px <цвет>`;
- `frame-notebook` `#1e88e5`, `frame-winter` `#4fc3f7`;
- `frame-fire100` `#ff7043` + внешнее свечение;
- `frame-legend-1..4` — общий золотой `#e6a817` + свечение;
- `frame-pulsar` — `@keyframes framePulse` (1.6 s, меняет box-shadow);
- `frame-orbit` — **не box-shadow, а `background: conic-gradient(...)` + `padding: 3px` +
  `@keyframes frameSpin` (3.5 s), плюс встречное вращение потомков
  `.frame-orbit .avatar-img, .frame-orbit .avatar-placeholder`.**

**Риски редизайна:**

1. `frame-orbit` рассчитан на **круглый контейнер с потомком** `.avatar-img`/`.avatar-placeholder`.
   В лидерборде `.lb-avatar` содержит **текстовый узел** (первую букву имени), а не эти элементы,
   поэтому `padding: 3px` сжимает букву, а встречное вращение не применяется. Это существующий
   визуальный дефект.
2. Кольца зависят от `border-radius: 50%` и от `var(--tg-bg)` во внутреннем слое. Смена фона
   контейнера аватара на «космический» градиент оставит светлое/тёмное кольцо-«шов».
3. `FRAME_CLASSES` — **whitelist безопасности**, список менять нельзя без синхронной правки
   каталога `shop_items.render_payload`.
4. `overflow: hidden` на `.avatar-container` обрезает вращающийся conic-gradient — работает
   только потому, что градиент рисуется фоном самого контейнера.

### 10.3. Фон профиля

**Источник:** `student_equipment` slot `background` → `eq.background.payload`
(`bg-grid` | `bg-space` | `bg-aurora` | `bg-draft`).

**Применение** (`applyProfileCosmetics`):

```js
const scr = document.getElementById('screen-profile');
BG_CLASSES.forEach(c => scr.classList.remove(c));
if (eq.background && BG_CLASSES.has(eq.background.payload)) scr.classList.add(eq.background.payload);
```

**CSS — селекторы с ID, специфичность (1,1,0):**

```css
#screen-profile.bg-grid   { background-image: две linear-gradient сетки, background-size: 22px 22px; }
#screen-profile.bg-space  { background-image: два radial-gradient (индиго + пурпур); }
#screen-profile.bg-aurora { background-image: два linear-gradient (бирюза + фиолет); }
#screen-profile.bg-draft  { background-image: repeating-linear-gradient «линейка» 20px/21px; }
```

**Риск — прямой конфликт с этапом 1 редизайна.** «Глобальный космический фон» будет задаваться
на `body` или на новом `AppShell`-контейнере. Но фон профиля прибит к `#screen-profile` селектором
с ID: он **перекроет** любое классовое правило на том же элементе и **не будет перекрыт** ничем
классовым. Кроме того, эти фоны — платный товар магазина: их нельзя ни отключить, ни
«перекрасить», иначе купленный предмет визуально исчезнет.

**Рекомендация (реализовать на этапе 1, но решение — за пользователем):** оставить
`#screen-profile.bg-*` как отдельный **слой поверх** глобального фона (например, перенести
`background-image` на псевдоэлемент `#screen-profile::before` с `pointer-events: none`), чтобы
космический фон приложения и купленный фон профиля складывались, а не конкурировали.

### 10.4. Титул профиля

Отдельная сущность от «звания» (`#rank-badge`). `equippedTitleText(title)`: для `title_custom`
берётся `variant` (одобренный учителем текст), для остальных — `titleText(name)`, вытаскивающий
текст из «Титул «Ященко»» регуляркой `/«([^»]+)»/`. Рендерится в `#profile-title` внутри
`#profile-title-row` (`.profile-title-card`), в лидербордах — в `.lb-title`.

---

## 11. Работа `shopPreview`

`shopPreview(item)` — `student-shop.js`, единственная фабрика превью косметики. Возвращает
`HTMLDivElement`:

```js
function shopPreview(item) {
    const p = document.createElement('div');
    p.className = 'shop-preview';
    if (item.slot === 'name_color') {
        if (item.render_payload === 'gold')      p.style.background = 'linear-gradient(135deg,#f9d423,#e6a817)';
        else if (/^#[0-9a-fA-F]{6}$/.test(item.render_payload || '')) p.style.background = item.render_payload;
        p.style.color = '#fff';
        p.textContent = 'Aa';
    } else {
        const icons = { crown: '👑', title: '🏷️', frame: '🖼️', background: '🎨', status_emoji: '😀' };
        p.textContent = item.item_kind === 'shield' ? '🛡️' : (icons[item.slot] || '🥯');
    }
    return p;
}
```

**Три места использования — три разных размерных контекста:**

| Вызывающий | Контейнер | Фактический бокс |
|---|---|---|
| `renderShopItem()` | `.shop-item` (grid `58px / 1fr / auto`) | 56×56, ≤380 px → 48×48 |
| `loadCollections()` | `.coll-tile` в `.coll-grid` (4 колонки, ≤380 px → 3) | 56×56 **без адаптации**; при 360 px колонка ≈ 66 px, а с учётом `.screen` padding — впритык |
| `loadShowcase()` | `.showcase-tile` (3 колонки, `min-height: 64px`) | 56×56 внутри 64 px плитки — почти вплотную |

**CSS:**

```css
.shop-preview { width: 56px; height: 56px; border-radius: 14px; flex-shrink: 0;
                display: flex; align-items: center; justify-content: center; font-size: 24px;
                background: var(--tg-bg); overflow: hidden;
                border: 1px solid rgba(128,128,128,0.12); position: relative; }
.coll-tile.locked .shop-preview { opacity: .42; filter: grayscale(1); }
@media (max-width: 380px) { .shop-preview { width: 48px; height: 48px; } }
```

**Наблюдения:**

1. Превью **не показывает сам предмет** — для рамок это не рамка, а эмодзи 🖼️, для фонов не фон,
   а 🎨. Реально «превьюшный» только `name_color`.
2. **Медиазапрос `max-width: 380px` уменьшает превью глобально**, включая коллекции и витрину,
   где сетка уже сжалась до 3 колонок — двойное сжатие.
3. `background: var(--tg-bg)` — на «космическом» фоне превью станет светлым/тёмным прямоугольником,
   выбивающимся из темы.
4. **История коммитов:** попытка нарисовать превью иначе уже была и была откачена —
   `bb89030 style(shop): redraw cosmetic previews` → `a26a98a revert(shop): restore emoji previews`.
   Причина отката в самом репозитории не зафиксирована. **Прежде чем менять `shopPreview` на
   этапе 7, нужно спросить пользователя, что именно тогда не устроило** — иначе высок риск
   повторить откаченное решение.

---

## 12. Все места, где эмодзи используются как UI-иконки

Задача этапа 2 — заменить эмодзи-иконки на SVG. Ниже — исчерпывающая карта. Разделено на
«иконки интерфейса» (кандидаты на SVG) и «контентные эмодзи» (часть текста/данных, менять нельзя
или опасно).

### 12.1. Иконки интерфейса — `index.html` (статические)

| Место | Эмодзи |
|---|---|
| `.nav-icon` × 5 | 👤 📚 🏆 🥯 ⚙️ |
| табы домашки | ✏️ 🤓 |
| табы лидеров | 🏅 🌍 |
| `h2` экранов | 🏆 (Лиги), 🥯 (Бубличная), ⚙️ (Ещё) |
| `.stat-label` | 🥯 (Бублики) |
| `.chart-title` | 📊 |
| `.showcase-title` / `.achievements-title` / `.collections-title` | 🌟 🏆 📦 |
| `.history-title` (сезоны) | 🏅 |
| `.history-title` (изменения) | **отсутствует** — строка начинается с пробела (`« История изменений»`) |
| `.profile-title-icon` | 🏷️ |
| `#streak-display` (плейсхолдер) | 🔥 |
| `#shield-count` (плейсхолдер) | 🛡 |
| `#btn-buy-shield` | 🥯 |
| `.upload-icon` | 📷 |
| `#detail-link` | 🔗 |
| `#btn-upload-dz` | 📤 |
| `.faq-title` | ❓ |
| `.more-link-btn` × 2 | 👪 💬 |
| `.faq-item summary::before` | `▸` / `▾` (CSS `content`, не эмодзи) |

### 12.2. Иконки интерфейса — JavaScript

| Файл / функция | Эмодзи и символы |
|---|---|
| `student-week.js` `WEEK_DAY_MARKS` | `–` `•` `↑` `!` `✓` `×` **🛡** — 7 маркеров статуса дня |
| `student-week.js` `loadWeekBlock` | 🔥 (строка «Еженедельное») |
| `student-assignments.js` `loadAssignmentsSummary` | 📅 🔥 🎯 ✏️, стрелка `›` (`.now-arrow`) |
| `student-assignments.js` `loadActiveAssignments` | 📅 🔥 👤 (префиксы `<option>`), 🕊️ («Нет активных заданий») |
| `student-assignments.js` `showAssignmentDetails` | 📝 (число задач), ❌ (комментарий учителя) |
| `student-assignments.js` `uploadDZ` | ⚠️ ⏰ 📤 💾 ✅ (статусные сообщения `#dz-status`) |
| `student-assignments.js` `loadMyHomework` | 📄 (число страниц), 📝 (число задач) |
| `student-quests.js` | 🎲 (life-квест), 🎁 (combo), 🔁 (замена), 🥯 (награды в бейджах) |
| `student-progress.js` `renderQuestStreak` / `loadProfile` | 🔥 |
| `student-progress.js` `renderStreakProgress` | 🔥 |
| `student-progress.js` `loadMockExamChart` | 🧮 (пусто) |
| `student-progress.js` `trajectorySummary` | 📈 ➖ 📉 |
| `student-progress.js` `loadBalanceHistory` | 📭 (пусто), ✅ 🔥 🥯 🏆 ⚠️ внутри `reasonMap` |
| `student-progress.js` `loadSeasonHistory` | 🥇 🥈 🥉, ⭐ |
| `student-progress.js` `ACHIEVEMENTS_META` | **24 иконки достижений**: 🌱 📗 🌟 📅 🗓 🏅 🎓 💪 ✨ 🕊 🎯 🌿 🏃 🧗 🏆 🎨 🌈 🔥 📆 💯 ⚡ 👑 🌙 🪶 + 🔒 для `locked` |
| `student-progress.js` `renderLeagueLadder` | 📍 ✓ 🔒 |
| `student-progress.js` `loadLeague` | 🏅 👑, ↑ ↓ (`.lb-score`), ⭐ |
| `student-progress.js` `loadGlobalTop` | 🥇 🥈 🥉, ⭐ |
| `student-progress.js` `renderNick` | 👑 (корона, литерал) |
| `student-shop.js` `shopPreview` | 👑 🏷️ 🖼️ 🎨 😀 🛡️ 🥯 |
| `student-shop.js` `loadShop` | ✨ (Витрина сезона), 🥯 (Всегда в магазине) |
| `student-shop.js` `renderShopItem` | 🔒 (условие), ✓ (Куплено/Надето), 🛡 (счётчик щитов) |
| `student-shop.js` `loadShields` | 🛡, 🥯 |
| `student-shop.js` `openShowcasePicker` | 🥯 (префикс чипа предмета), 🏆 (fallback достижения), ✕ (убрать), `+` (пустой слот) |
| `student-shop.js` `openCustomTitleModal` | 🥯 |
| Тексты ошибок/алертов | ❌ (в `log(...)`, в консоль) |

### 12.3. Что трогать нельзя

- **`ACHIEVEMENTS_META`** — это не только иконки: `code` используется в `loadAchievements`,
  `loadShowcase` (`meta.icon`, `meta.name`), `openShowcasePicker`, `renderShopItem`
  (`condition_achievement` → название нужного достижения). Заменять иконки на SVG можно, но
  **только добавив поле** (напр. `svg`), не убирая `icon`, иначе три места отвалятся молча.
- **`WEEK_DAY_MARKS`** — значения попадают в `innerHTML` кнопок дня и завязаны на `WEEK_DAY_LABELS`
  (`aria-label`). Ключи (`not_assigned` … `shielded`) — контракт с серверным
  `get_student_current_week`.
- **`reasonMap` в `loadBalanceHistory`** — эмодзи внутри пользовательских строк, это контент.
- **Эмодзи-статус ника** (`eq.status_emoji.variant`) и эмодзи-чипы магазина
  (`item.render_payload.split(/\s+/)`) — **данные из БД**, не иконки. SVG-замена здесь невозможна.
- **🥯 «бублик»** — это валюта продукта, не декоративная иконка; замена меняет продуктовый язык.

---

## 13. Потенциальные CSS-конфликты

### 13.1. Перегруженные имена классов (одно имя — много смыслов)

| Класс | Сколько разных смыслов | Где |
|---|---|---|
| `.active` | **6** | `.screen`, `.nav-btn`, `.tab-btn`, `.hw-view`, `.lb-mode`, `#custom-title-modal` |
| `.locked` | **3** | `.ach-tile.locked` (grayscale), `.coll-tile.locked` (через `.shop-preview`), `.shop-state.locked` (цвет текста) |
| `.empty` | 1 (но имя предельно общее) | `.showcase-tile.empty` |
| `.rejected` | 2 | `.hw-comment.rejected`, часть `badge-rejected` |
| `.current` / `.achieved` | 1 каждый, но имена общие | `.ladder-step` |
| `.filled` | 1, имя общее | `.streak-dot` |
| `.today` / `.selected` | 1 каждый, имена общие | `.week-day-chip` |
| `.owned` | 1 | `.shop-state.owned` |
| `.apply` / `.remove` | 1 каждый | `.week-shield-btn` |
| `.open` | 1 | `#week-day-detail` |
| `.has-file` | 1 | `.file-upload-area` |
| `.assigned` | 1 | `.group-badge` |

Любой новый компонент Cosmic Academy, использующий эти имена без префикса, немедленно наложится
на существующий. **Рекомендуется префикс (`ca-`) для всей новой системы.**

### 13.2. Селекторы по элементу (глобальный охват)

```css
body        { display: flex; flex-direction: column; min-height: 100vh; padding-bottom: 75px; }
button, input, select, textarea { font-family: inherit; line-height: 1.25; }
select      { padding:14px; border-radius:12px; border:1px solid …; background:var(--tg-bg); width:100%; }
button.primary { width:100%; padding:14px; … }
button:disabled { opacity: .5; cursor: not-allowed; }
.screen > h2   { font-size: var(--text-screen); line-height: 1.2; }
```

`select` без класса стилизуется глобально: **любой новый `<select>` в редизайне автоматически
получит 14 px паддинга и `width: 100%`**. Аналогично `button:disabled` перекроет любые новые
disabled-состояния (`.shop-buy-btn:disabled`, `.quest-claim-btn:disabled` и т. п. заданы отдельно
и дублируют это правило).

### 13.3. Специфичность ID

- `#screen-profile.bg-*` (4 правила) — (1,1,0), перебивает всё классовое (см. 10.3);
- `#custom-title-modal`, `#custom-title-modal.active`, `#file-input` — (1,0,0)+.

### 13.4. Каскад `body { display: flex }`

`body` — flex-колонка с `min-height: 100vh`, а `.screen` — `display:block/none`. Введение
AppShell-обёртки между `body` и экранами изменит контекст форматирования: `min-height: 100vh` на
`body` перестанет растягивать экран, `padding-bottom: 75px` окажется не там, где ожидается.

### 13.5. Дублирующиеся правила

- `.coll-grid { grid-template-columns: repeat(3, …) }` в медиазапросе **объявлено дважды** —
  строка 185 и строка 275 `styles/student.css` (оба `@media (max-width: 380px)`).
- Две отдельные `@media (max-width: 380px)` секции вместо одной (строки 174 и 274).
- `.shop-preview` стилизуется один раз, но используется в трёх размерных контекстах (см. 11).

### 13.6. Мёртвые / неработающие правила (найдено 5)

1. **`.my-hw-item.status-pending` / `.status-approved` / `.status-rejected` — не применяются
   никогда.** JS ставит `status-${hw.status}`, а `hw.status` после фильтра `.neq('status','assigned')`
   принимает значения `submitted` и `checked`. То есть реально генерируются классы
   **`status-submitted` и `status-checked`**, для которых стилей нет: цветная левая полоска
   статуса в архиве работ не отображается. Реальный статус приёмки лежит в `approval_status`,
   а не в `status`.
2. **`.week-weekly-row`, `.week-totals`, `.week-forecast` — не применяются никогда.** В разметке
   элементы объявлены как `<div id="week-weekly-row">` без класса, и JS класс не добавляет.
   Заданные `font-size: 12px/11px` и `color: var(--tg-hint)` не действуют — три строки блока
   недели рендерятся базовым 14 px основным цветом.
3. **`.week-neutral-note`** — класс объявлен в CSS, не используется нигде.
4. **`.frame`** (базовое кольцо) — `applyAvatarFrame` его только снимает, никогда не добавляет.
5. **`.profile-meta-row` без `display: grid`** — `grid-template-columns: 52px minmax(0,1fr)`
   работает только потому, что JS проставляет `style.display = 'grid'` инлайном
   (`loadProfile`, `loadRankTitle`). Та же схема у `.profile-title-card`: `align-items: center`
   без `display: flex`, флекс включается инлайном из `applyProfileCosmetics`.
   **Если редизайн уберёт эти инлайн-присвоения из JS — вёрстка развалится; если уберёт
   `grid-template-columns` из CSS — развалится тоже.**

Плюс не мёртвое, но бесполезное: `backdrop-filter` на непрозрачной `.bottom-nav` (см. 9.4),
и `lastResultSummary()` / `formatPlainDate()` в `student-progress.js` — функции, помеченные
комментарием как неиспользуемые, оставленные намеренно («не удалять существующий код»).

---

## 14. Места с высоким риском сломать бизнес-логику

Перечисленное ниже **нельзя менять в ходе редизайна интерфейса**. Для каждого пункта указано,
что именно ломается.

### 14.1. Двухконтурная авторизация (secure path / legacy fallback)

`studentSecurePathActive()` (`student-auth.js`) ветвит **каждую** запись:

| Действие | secure (JWT) | legacy fallback |
|---|---|---|
| создание профиля | `ensure_student_self` | прямой `insert` в `students` |
| активация заданий | `activate_due_assignments_self` | `select` + `update` `assignments` |
| сдача работы | `submit_assignment_self` | `update assignments` |
| щит недели | `request_weekly_shield_self` / `cancel_weekly_shield_self` | `request_weekly_shield` / `cancel_weekly_shield` |
| покупка щита | `buy_streak_shield_self` | `buy_streak_shield` |
| покупка предмета | `buy_item_self` | `buy_item` |
| экипировка | `equip_item_self` | `equip_item` |
| витрина | `set_showcase_self` | `set_showcase` |
| персональный титул | `submit_custom_title_self` | `submit_custom_title` |
| квесты | `claim_life_quest_self` / `replace_life_quest_self` | `claim_life_quest` / `replace_life_quest` |
| бонус коллекции | `claim_collection_bonus_self` | `insert` + `add_huikons` |
| квесты (чтение) | `get_daily_quests_self` | `get_daily_quests` |

**Ни одну из этих веток нельзя «упростить» при рефакторинге UI.** `_studentToken` живёт только в
памяти модуля (не в `localStorage`), обновляется таймером каждые 55 мин.

### 14.2. Расчёт дедлайнов сдачи (`uploadDZ`, `student-assignments.js`)

- `moscowDateTimeToInstant(y, m, d, hh, mm)` — МСК = UTC+3 круглый год;
- ежедневка: `moscowDateTimeToInstant(y, m, d, 23, 61)` — **`61` минута намеренно**, это 23:59 + 2
  минуты буфера. Выглядит как опечатка, ею не является;
- еженедельное: вычисление ближайшего понедельника 00:00 МСК;
- возвращённая ежедневка: дедлайн = серверный `revision_deadline_at`;
- индивидуальное: без дедлайна.

### 14.3. `isAssignmentAvailable(a, nowInstant, todayMSK)`

Единый признак доступности для выпадающего списка, «Сделать сейчас» и самой отправки. Расхождение
этих трёх мест = ученик видит задание, но не может его сдать (или наоборот).

### 14.4. Whitelist-фильтры против XSS

- `FRAME_CLASSES`, `BG_CLASSES` — только известные классы из каталога попадают в `classList`;
- `/^#[0-9a-fA-F]{6}$/` в `applyNickColor` и `shopPreview`;
- `esc()` перед **каждой** вставкой пользовательских строк в `innerHTML` (имена, названия
  заданий, комментарии учителя, названия товаров/достижений);
- `uploadSignedToCloudinary` проверяет, что `secure_url` начинается с
  `https://res.cloudinary.com/<cloud_name>/`.

**Перевод любого DOM-пути (`createElement` + `textContent`) на строковые шаблоны без `esc()`
откроет XSS.** Магазин и лидерборд сейчас намеренно построены на DOM-пути — это зафиксировано
комментарием в коде.

### 14.5. Защита от двойного клика

`weekShieldBusy` (`student-week.js`), `questActionBusy` (`student-quests.js`),
`btn.disabled = true` до `await` в `buyShopItem`, `equipShopItem`, `buyStreakShield`,
`submitCustomTitle`. Комментарий в коде прямо ссылается на «урок W05». Замена кнопок на новые
компоненты обязана сохранить и флаг, и `disabled`.

### 14.6. Однократный повтор в `loadProfile`

`loadProfile(isRetryAfterInsert)`: при `PGRST116` (строки нет) создаёт профиль и вызывает себя
**ровно один раз**. Убрать флаг — получить бесконечный цикл `select → insert → select`.

### 14.7. Константы, обязанные совпадать с сервером

- `SHIELD_MAX = 7`, `SHIELD_PRICE = 90` (`student-shop.js`) — дублируют значения в RPC
  `buy_streak_shield` (миграция 012);
- лимит замен квестов `2` и суммы `+3/+2 🥯` захардкожены в разметке `student-quests.js`, но
  реально считаются сервером (`daily_quest_state.replacements_left`, `can_replace_1/2`);
- цена персонального титула `2000 🥯` — в тексте `openCustomTitleModal`, проверка на сервере;
- длина титула 3–24 символа — в `updateCustomTitleForm`/`submitCustomTitle` и в CHECK-констрейнте
  таблицы `student_custom_titles`;
- `LEAGUE_LADDER` (7 названий) — снимок `league_tiers` (миграция 019);
- `ACHIEVEMENTS_META` коды — совпадают с `achievement_code` из `teacher.html` и серверных
  `grant_weekly_achievements` / `record_approved_assignment`.

### 14.8. Порядок вызовов в `loadProfile`

`loadProfile()` — единственный «оркестратор» экрана профиля: он последовательно запускает
`loadBalanceHistory`, `loadAssignmentsSummary`, `loadWeekBlock`, `loadMockExamChart`,
`loadSeasonHistory`, `loadAchievements`, `loadShields`, `loadCollections`, `loadShowcase`,
`loadRankTitle` (все — без `await`, «выстрелил и забыл»). Блок «Сегодня» (`loadTodayQuests`)
**намеренно** сюда не входит: он загружается ровно один раз при старте (`student-app.js`), это
зафиксировано комментарием («как и было решено в карточке»). Добавление его в `loadProfile`
изменит поведение квестов.

### 14.9. Побочный эффект: бонус за коллекцию

`loadCollections()` (визуальная функция!) при полной коллекции вызывает `grantCollectionBonus()` —
**денежное начисление**. Переписывание секции «Коллекции» как чисто презентационного компонента
уберёт выдачу бонуса. В коде это отмечено как «осознанный компромисс», не баг.

### 14.10. Ленивое создание сущностей из UI

- `getCurrentSeasonId()` → `ensure_current_season()` — создаёт сезон при первом открытии
  «Общего топа»;
- `loadShop()` → `ensure_season_rotation()` — назначает бандл ротации сезону;
- `loadProfile()` → `ensure_student_self` — создаёт запись ученика.

Удаление или отложенная загрузка этих экранов меняет момент создания серверных сущностей.

---

## 15. Порядок подключения скриптов и зависимости между student-файлами

### 15.1. Порядок в `index.html`

```
<head>
  1. https://telegram.org/js/telegram-web-app.js          (внешний CDN, блокирующий)
  2. https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2 (внешний CDN, блокирующий)
  3. shared.js                                            (без defer/async)
  4. <link rel="stylesheet" href="styles/student.css">
</head>
<body>
  … вся разметка …
  5. js/student-core.js
  6. js/student-assignments.js
  7. js/student-week.js
  8. js/student-progress.js
  9. js/student-shop.js
 10. js/student-quests.js
 11. js/student-auth.js
 12. js/student-app.js
</body>
```

Все восемь — **classic scripts без `type="module"` и без `defer`**, общая глобальная область
видимости. Объявления `const`/`let` верхнего уровня создают лексические глобали: **два файла не
могут объявить одно и то же имя** — это будет `SyntaxError` на загрузке страницы, а не тихая
перезапись.

### 15.2. Что где объявлено (карта владения)

| Файл | Глобальное состояние | Ключевые функции |
|---|---|---|
| `shared.js` | `SUPABASE_URL`, `SUPABASE_KEY`, `SIGN_UPLOAD_URL` | `uploadSignedToCloudinary`, `esc`, `getTodayMSK`, `normalizeUrl`, `pluralBubliks` |
| `student-core.js` | `PARENT_BOT_USERNAME`, **`currentUser`**, **`db`**, `selectedFiles`, `activeAssignments` | `log`, `moscowDateTimeToInstant`, `inviteParent`, `setupAvatar`, `switchTab`, `switchHwTab` |
| `student-assignments.js` | — | `checkAndActivateAssignments`, `getActionableAssignments`, `loadAssignmentsSummary`, `openNowAssignment`, `pluralTasks`, `isAssignmentAvailable`, `loadActiveAssignments`, `showAssignmentDetails`, `handleFileSelect`, `uploadToCloudinary`, `uploadDZ`, `loadMyHomework` |
| `student-week.js` | `WEEK_DAY_NAMES`, `WEEK_DAY_FULL_NAMES`, `WEEK_DAY_LABELS`, `WEEK_DAY_MARKS`, `weekShieldBusy`, `currentWeekView`, `currentWeekAvailableShields`, `selectedWeekDayIndex` | `shortDateRu`, `addDaysToDateStr`, `renderWeekStrip`, `selectWeekDay`, `renderWeekDayDetail`, `loadWeekBlock`, `applyWeekShield`, `removeWeekShield` |
| `student-progress.js` | `FRAME_CLASSES`, `BG_CLASSES`, `mockExamPoints`, **`ACHIEVEMENTS_META`**, `LEAGUE_LADDER` | `equipmentQuery`, `buildEquipMap`, `titleText`, `equippedTitleText`, `applyNickColor`, `renderNick`, `applyAvatarFrame`, `applyProfileCosmetics`, **`loadProfile`**, `loadRankTitle`, `renderStreakProgress`, `loadMockExamChart`, `renderMockChart`, `trajectorySummary`, `showExamInfo`, `lastResultSummary`*, `formatPlainDate`*, `loadBalanceHistory`, `loadSeasonHistory`, `loadAchievements`, `getCurrentSeasonId`, `loadLeaderboard`, `switchLbMode`, `renderLeagueLadder`, `loadLeague`, `loadGlobalTop` |
| `student-shop.js` | `showcaseOpenPosition`, `SHIELD_MAX`, `SHIELD_PRICE`, `customTitleIsRetry` | `loadCollections`, `grantCollectionBonus`, `loadShowcase`, `openShowcasePicker`, `setShowcase`, `pluralShields`, `loadShields`, `buyStreakShield`, `pluralDays`, `daysLeftInSeason`, `loadShop`, `shopSectionTitle`, **`shopPreview`**, `shopBuyButton`, `renderShopItem`, `buyShopItem`, `customTitleValue`, `openCustomTitleModal`, `closeCustomTitleModal`, `updateCustomTitleForm`, `submitCustomTitle`, `equipShopItem` |
| `student-quests.js` | `questActionBusy`, `QUEST_LIFE_META_UNAVAILABLE` | `loadTodayQuests`, `renderTodayQuests`, `buildLifeRow`, `buildComboRow`, `renderQuestStreak`, `setLifeControlsDisabled`, `claimTodayLife`, `replaceTodayLife` |
| `student-auth.js` | `STUDENT_AUTH_MODE='shadow'`, `STUDENT_AUTH_SHADOW_FALLBACK=true`, `STUDENT_AUTH_URL`, `STUDENT_JWT_REFRESH_DELAY_MS`, `_studentToken`, `_refreshTimer`, `_secureActive` | `studentSecurePathActive`, `studentAccessToken`, `_decodeJwtPayload`, `_requestStudentToken`, `_scheduleStudentTokenRefresh`, `initStudentSession` |
| `student-app.js` | — | обработчик `DOMContentLoaded` |

`*` — помеченные в коде как неиспользуемые, оставлены намеренно.

### 15.3. Граф зависимостей (вызовы во время выполнения)

```
student-app  ──> student-auth   (initStudentSession)
             ──> student-core   (log, setupAvatar, db, currentUser)
             ──> student-assignments (checkAndActivateAssignments, loadActiveAssignments)
             ──> student-progress    (loadProfile)
             ──> student-quests      (loadTodayQuests)

student-core (switchTab / switchHwTab)
             ──> student-progress    (loadProfile, loadLeaderboard)
             ──> student-assignments (loadMyHomework, loadActiveAssignments)
             ──> student-shop        (loadShop)
             ──> shared              (esc)

student-progress (loadProfile — оркестратор профиля)
             ──> student-assignments (loadAssignmentsSummary)
             ──> student-week        (loadWeekBlock)
             ──> student-shop        (loadShields, loadCollections, loadShowcase)
             ──> сам себя            (loadBalanceHistory, loadMockExamChart,
                                      loadSeasonHistory, loadAchievements, loadRankTitle)
             ──> student-core        (db, currentUser, log)

student-shop ──> student-progress    (ACHIEVEMENTS_META — в 3 местах!)
             ──> shared              (pluralBubliks, getTodayMSK, esc)
             ──> student-auth        (studentSecurePathActive)
             ──> student-progress    (loadBalanceHistory после покупки)

student-week ──> shared              (esc, getTodayMSK)
             ──> student-auth        (studentSecurePathActive)

student-quests ──> student-progress  (loadProfile после claim)
               ──> student-auth      (studentSecurePathActive)
               ──> shared            (esc)

student-assignments ──> shared       (uploadSignedToCloudinary, esc, getTodayMSK, normalizeUrl)
                    ──> student-auth (studentAccessToken, studentSecurePathActive)
                    ──> student-core (switchTab, switchHwTab, moscowDateTimeToInstant, db, currentUser)
                    ──> student-progress (loadProfile после сдачи)
```

**Важные наблюдения:**

1. **Циклические зависимости между файлами есть** (`progress ⇄ shop`, `progress ⇄ assignments`,
   `progress ⇄ quests`). Они работают только благодаря общей глобальной области и позднему
   связыванию. **Любая модуляризация потребует разрыва циклов — это отдельная задача, не часть
   редизайна.**
2. `student-auth.js` подключён **7-м**, то есть **после** файлов, которые вызывают
   `studentSecurePathActive()`. Работает, потому что вызовы происходят только после
   `DOMContentLoaded`. Перенос любого вызова на верхний уровень модуля даст `ReferenceError` (TDZ
   для `const _secureActive`).
3. `ACHIEVEMENTS_META` объявлена в `student-progress.js`, а используется в `student-shop.js`
   (`loadShowcase`, `openShowcasePicker`, `renderShopItem`). При разделении файлов это первое,
   что сломается.
4. `db` и `currentUser` — `let` в `student-core.js`, присваиваются в `student-app.js`. Все
   остальные файлы читают их напрямую как глобали.

---

## 16. Перечень существующих responsive-правил

**Единственный breakpoint во всём приложении — `@media (max-width: 380px)`, объявленный дважды.**

```css
/* styles/student.css:174 */
@media (max-width: 380px) { .ach-grid { grid-template-columns: repeat(3, 1fr); } }

/* styles/student.css:185 */
@media (max-width: 380px) { .coll-grid { grid-template-columns: repeat(3, 1fr); } }

/* styles/student.css:274–279 */
@media (max-width: 380px) {
    .coll-grid   { grid-template-columns: repeat(3, minmax(0, 1fr)); }  /* дубль */
    .shop-item   { grid-template-columns: 50px minmax(0, 1fr); }
    .shop-preview{ width: 48px; height: 48px; }
    .shop-action { grid-column: 2; text-align: left; }
}
```

Больше медиазапросов нет. Нет:

- `@media (prefers-color-scheme: …)`;
- `@media (prefers-reduced-motion: …)` — при том что есть три бесконечные анимации
  (`framePulse`, `frameSpin` ×2) и `fadeIn` на каждом переключении экрана;
- `@supports`;
- `env(safe-area-inset-*)`;
- ландшафтной ориентации;
- `@media (min-width: …)` для планшетов/десктопа (Mini App открывается и в Telegram Desktop, где
  окно шире 400 px — там всё растягивается на полную ширину без max-width контейнера).

Что «резиновое» уже сейчас (сохранить при редизайне):

- `.week-days-strip` — `repeat(7, minmax(0, 1fr))`;
- `.showcase-grid`, `.coll-grid` — `minmax(0, 1fr)`;
- `.shop-item`, `.profile-meta-row` — `minmax(0, 1fr)` во второй колонке;
- `overflow-wrap: anywhere` на `.user-name`, `.profile-meta-value`, `.week-day-detail-title`,
  `.week-weekly-row`, `.now-item-title`, `.now-item-meta`, `.quest-row-*`, `.showcase-name`,
  `.coll-name`, `.shop-name`, `.profile-title`;
- SVG графика — `viewBox` + `width: 100%; height: auto`;
- `min-width: 0` на flex/grid-детях (`.profile-identity`, `.now-main`, `.shop-body`,
  `.lb-name-wrap`, `.quest-row-main`).

---

## 17. Магические отступы и фиксированные размеры, мешающие ширине 360 px

Полезная ширина при 360 px: `360 − 2×20 (padding .screen) = 320 px`.
Внутри `.week-block`/`.today-block`: `320 − 2×15 = 290 px`.
Внутри `.dz-section`: `320 − 2×25 = 270 px`.

| Значение | Где | Чем мешает на 360 px |
|---|---|---|
| `padding: 20px` | `.screen` | съедает 40 px ширины на всех пяти экранах |
| `padding-bottom: 75px` | `body` | магическое `65 + 10`, не учитывает `safe-area-inset-bottom` |
| `height: 65px` | `.bottom-nav` | фиксированная высота панели; при 5 подписях по 11 px впритык |
| `padding: 25px` | `.dz-section` | самый «жирный» контейнер, оставляет 270 px под `<select>` и кнопку |
| `52px` | `.profile-meta-row { grid-template-columns: 52px minmax(0,1fr) }` | магическая колонка подписи; при длинном «Звание» текст не влезает |
| `margin: 0 0 10px 52px` | `.rank-progress` | **тот же магический 52 = 40 (аватар) + 12 (gap)**; при смене размера аватара выравнивание разъедется |
| `40×40` | `.avatar-container` | завязано на `52px` выше |
| `32×32 + margin-right: 10px` | `.lb-avatar` | вместе с `.lb-rank { width: 35px }` фиксирует 77 px под ранг+аватар |
| `width: 35px` | `.lb-rank` | при `#10` и эмодзи-медали впритык |
| `height: 54px`, `gap: 5px` | `.week-day-chip`, `.week-days-strip` | 7 колонок: `(290 − 6×5)/7 ≈ 37 px` на день — предел |
| `20×20` | `.week-day-mark` | в 37 px колонке остаётся 8 px по бокам |
| `26px` | `.now-count { min-width: 26px; height: 26px }` | ок, но фиксировано |
| `30×30` | `.now-icon`, `.quest-row-icon` | фиксировано |
| `32×32` | `.quest-replace-btn` | вместе с `.quest-claim-btn` («Выполнил честно», ~140 px) трейлинг занимает ~180 px из 290 → на текст квеста остаётся ~100 px |
| `58px / 48px` | `.shop-item` grid col 1 | ≤380 px переключается на 2 колонки, `.shop-action` уезжает под текст |
| `56×56 → 48×48` | `.shop-preview` | в `.coll-grid` (3 колонки при ≤380) плитка ≈ 100 px — ок, но в `.showcase-tile` (`min-height: 64px`) 56 px превью почти во всю плитку |
| `min-height: 64px` | `.showcase-tile` | 3 колонки × (320 − 2×8)/3 ≈ 101 px |
| `max-height: 240px` | `.showcase-picker` | фиксированная высота скролл-панели |
| `min-height: 27px` | `.coll-name` | резерв под 2 строки, при длинном имени обрезается визуально |
| `max-width: 380px` + `padding: 20px` | `.custom-title-dialog` / `#custom-title-modal` | на 360 px диалог = `360 − 40 = 320 px`, до max-width не доходит — ок, но паддинг модалки магический |
| `min-height: 18px / 20px / 17px` | `.exam-info-box`, `.custom-title-preview`, `.custom-title-error` | резерв «чтобы не прыгало», подобран под 13 px шрифт |
| `viewBox="0 0 320 140"`, `padL:32 padR:12 padT:10 padB:26`, `font-size="9"` | `renderMockChart` | SVG масштабируется, **но подписи 9 px после масштаба на 290 px становятся ~8 px** |
| `repeat(4, 1fr)` | `.ach-grid` | до 380 px — 4 колонки по ~72 px под иконку 28 px + 2 строки текста 11 px |
| `font-size: 40px` | `.upload-icon` | крупно, но фиксировано |
| `font-size: 22px` | `.nav-icon` | размер эмодзи-иконки навигации |
| `font-size: 26px` | `.league-badge` | длинное «Легенда 👑» на 320 px впритык |
| `padding: 14px 16px` | `.lb-item`, `.history-item` | 32 px по горизонтали от 320 → контент 288 px |

**Инлайновые магические отступы прямо в `index.html`** (все они переживут любую правку CSS и
поэтому подлежат вычистке в дизайн-токены):

- `style="margin-bottom:12px"` (h2 лидеров), `margin-bottom:4px` (h2 магазина),
  `margin-bottom:20px` (h2 «Ещё»);
- `style="display:none; margin-bottom:20px"` — `#streak-progress`;
- `style="margin-bottom: 10px"` — `.dz-title`;
- `style="text-align:center; font-size:var(--text-small); color:var(--tg-hint); margin-bottom:20px; line-height:1.4"` — абзац инструкции;
- `style="font-weight:800; color:var(--tg-text); margin-bottom:5px"` — `label`;
- `style="…border-radius:12px; padding:15px; margin-bottom:15px; border:1px solid rgba(128,128,128,0.2)"` — `#assignment-details`;
- `style="font-weight:700; margin-bottom:8px; font-size:var(--text-body)"` — `#detail-title`;
- `style="…margin-bottom:8px"` — `#detail-count`;
- `style="margin-top:10px; padding:10px; background:rgba(220,53,69,0.1); border-radius:8px; …color:#721c24"` — `#detail-feedback`;
- `style="padding:16px"` — `#btn-upload-dz`;
- `style="margin-top: 20px; text-align: center; opacity: 0.6; font-size: var(--text-small)"` — пояснение под формой;
- `style="text-align:center; opacity:0.6; font-size:var(--text-small); margin-bottom:16px"` — `#lb-season-label`;
- `style="width:100%; border:none; cursor:pointer; margin-bottom:12px"` — кнопка «Пригласить родителя»;
- `style="text-align:center; padding:20px|30px; opacity:0.5"` — 5 заглушек загрузки.

**Инлайновые стили, проставляемые из JS** (тоже переживут CSS):
`label.style.marginBottom='4px'` и `s.style.display='block'; s.style.marginBottom='4px'`
в `renderShopItem`; `warn.style.color='#e67e22'` в `loadLeague`;
`status.style.color = …` (4 разных цвета) в `uploadDZ`.

---

## 18. Структура БД в объёме, необходимом для UI

Только то, что ученический Mini App реально читает/пишет.

### 18.1. Таблицы, читаемые напрямую из клиента

| Таблица | Поля, используемые в UI | Где |
|---|---|---|
| `students` | `rating`, `huikons`, `group_name`, `current_streak`, `name`, `telegram_id`, `telegram_username` | `loadProfile`, `loadGlobalTop`, `loadShop`, `loadLeague` |
| `assignments` | `id, title, type, task_count, content_url, teacher_feedback, scheduled_date, status, approval_status, revision_deadline_at, created_at, photo_url, submitted_at` | `getActionableAssignments`, `loadMyHomework`, `uploadDZ` |
| `balance_history` | `change_amount, reason, created_at` (limit 20) | `loadBalanceHistory` |
| `season_results` | `season_id, points, place` (limit 10) | `loadSeasonHistory` |
| `student_achievements` | `achievement_code` | `loadAchievements`, `loadShop`, `openShowcasePicker` |
| `student_items` | `item_code, quantity` | `loadShields`, `loadShop`, `loadCollections`, `openShowcasePicker` |
| `student_equipment` | `slot, item_code, variant` + embed `shop_items(render_payload, name)` | `equipmentQuery` → косметика |
| `student_showcase` | `position, kind, ref_code` | `loadShowcase` |
| `shop_items` | `item_code, name, item_kind, slot, price, availability, rotation_bundle, condition_achievement, render_payload, sort_order, active` | `loadShop`, `loadCollections`, `loadShowcase` |
| `season_bundles` | `season_id, bundle` | `loadCollections` |
| `seasons` | `start_date` (открытый сезон) | `loadShop` (плашка «уйдёт через N дней») |
| `student_custom_titles` | `title_text, status, teacher_comment` | `loadShop` |

### 18.2. RPC, читаемые UI (read-model — клиент ничего не пересчитывает)

| RPC | Возвращает | Потребитель в UI |
|---|---|---|
| `get_student_current_week(p_student_id)` | `jsonb`: `week_start`, `week_end`, `days[7]{date,status,title,assignment_id,shield_status,revision_deadline_at,task_count}`, `n`, `a`, `s`, `e`, `weekly{status,title}`, `classification` (`pending`/`neutral`/`successful`/`weak`), `reward_forecast` | `loadWeekBlock` |
| `available_shield_quantity(p_student_id)` | `integer` | `loadWeekBlock` |
| `get_daily_quests_self()` / `get_daily_quests(id)` | `json`: `life_1`, `life_2` (`{template_code,name,description,category}`), `life_1_paid`, `life_2_paid`, `combo_paid`, `combo_status`, `can_replace_1`, `can_replace_2`, `replacements_left`, `replacements_used`, `generation_active`, `streak_current`, `options[]` | `loadTodayQuests`, `renderTodayQuests` |
| `get_student_rank_title_self()` | `json`: `title`, `next_title`, `tasks_to_next`, `days_to_next`, `has_unknown_legacy` | `loadRankTitle` |
| `get_mock_exam_trajectory(p_student_id)` | `jsonb`: `count`, `points[]{week_start,score}`, `last_score`, `delta_last`, `avg_last_3`, `min_last_3`, `max_last_3`, `trend` (`up`/`flat`/`down`) | `loadMockExamChart` |
| `get_student_league_snapshot_self()` | `json`: `tier`, `tier_name`, `season_id`, `in_season`, `is_late_entry`, `place`, `cohort_size`, `active_in_cohort`, `has_crown`, `inactive_seasons` | `loadLeague` |
| `preview_league_close_self()` | таблица: `student_id, tier, tier_name, cohort_index, points, place, active_in_cohort, projected_movement, projected_tier` | `loadLeague` |
| `get_economy_flags()` | `json`: `cutover_at`, `stage4_started_at` | `loadProfile` (режим стрика) |
| `ensure_current_season()` | `bigint` (id сезона, создаёт при отсутствии) | `getCurrentSeasonId` |
| `ensure_season_rotation()` | `integer` (номер бандла) | `loadShop` |

### 18.3. Что из этого важно для UI-редизайна

1. **Статусы дня недели — фиксированный серверный словарь из 7 значений**
   (`not_assigned`, `assigned`, `submitted`, `revision`, `approved`, `missed`, `shielded`).
   Классы `wd-*`, метки `WEEK_DAY_MARKS` и подписи `WEEK_DAY_LABELS` обязаны покрывать ровно
   этот набор.
2. **`classification` недели — 4 значения** (`pending`, `neutral`, `successful`, `weak`); UI
   сейчас различает только первые два (третий/четвёртый идут в общую ветку «При текущем итоге»).
3. **Все суммы, места, серии и переходы считает сервер.** Клиент не имеет права пересчитывать
   `reward_forecast`, `place`, `streak_current`, `avg_last_3` — это зафиксировано комментариями
   в коде со ссылками на SPEC.
4. `students.rating` = очки **текущего сезона** (не общий рейтинг); поле не переименовывается.

---

## 19. Сводка критических рисков редизайна

| # | Риск | Последствие | Где |
|---|---|---|---|
| R1 | Модуляризация / бандлинг / IIFE | **Мгновенно ломаются все 19 inline-обработчиков** и вся навигация | §5 |
| R2 | Изменение порядка `.nav-btn` или `.tab-btn` | Подсветка и переключение вкладок уезжают на соседние | §4, §9 |
| R3 | Глобальный фон конфликтует с `#screen-profile.bg-*` | Купленные фоны профиля исчезают или перекрывают новый фон (ID-специфичность) | §10.3, §13.3 |
| R4 | Новые правила `color` на потомках `#user-name` / `.lb-name-line` | Золотой ник становится невидимым (`background-clip: text`) | §10.1 |
| R5 | Потеря динамического `#exam-info-box` | Клик по точке графика молча перестаёт работать | §3.1 |
| R6 | Удаление инлайновых `style.display='grid'/'flex'` из JS | `.profile-meta-row` и `.profile-title-card` теряют раскладку (в CSS нет `display`) | §13.6 |
| R7 | Переписывание `loadCollections` как «чисто визуальной» | Пропадает начисление бонуса за коллекцию (реальные бублики) | §14.9 |
| R8 | Перевод магазина/лидерборда с DOM-пути на innerHTML | Открывается XSS (сейчас защита — `createElement`+`textContent`) | §14.4 |
| R9 | Замена кнопок без сохранения `weekShieldBusy`/`questActionBusy`/`disabled` | Двойные клики → двойные списания/начисления | §14.5 |
| R10 | Утрата ветвления `studentSecurePathActive()` | Ломается либо secure-контур, либо legacy fallback (dev-диагностика) | §14.1 |
| R11 | `ACHIEVEMENTS_META` перемещена/переименована | Отваливаются достижения, витрина, пикер и «Нужно: …» в магазине | §15.3 |
| R12 | Дублирование имени `const` при переносе кода между student-файлами | `SyntaxError` на загрузке — **белый экран целиком** | §15.1 |
| R13 | Изменение `shopPreview` без выяснения причины отката `a26a98a` | Повторение уже откаченного пользователем решения | §11 |
| R14 | Работа от локального `main` (`fb68ea8`) вместо `origin/main` (`e5f675b`) | Редизайн ляжет на код 19-коммитной давности | §0.2 |
| R15 | `.my-hw-item.status-*` не работает уже сейчас | Если «починить» в лоб — изменится существующее (пусть и сломанное) визуальное поведение архива | §13.6 |

---

*Конец аудита. Реализация не начиналась; ни один файл интерфейса, backend, SQL, Supabase, RPC или
Telegram-аутентификации не изменялся.*
