-- =============================================================================
-- 021_stage4_quest_foundation.sql — Dormant-фундамент данных ежедневных квестов
-- (Bot 2.0, Stage 4, карточка U02A; SPEC_STAGE4.md §§2–5, 8)
--
-- Зачем: Stage 4 добавляет два персональных ежедневных квеста (математика + жизненный
-- челлендж) с выплатами 3/3 и бонусом 2. U02A кладёт ТОЛЬКО спящую схему: редактируемый
-- каталог, сохранённый дневной набор, историю показанных шаблонов и pay-once ledger.
-- Здесь НЕТ генерации, random, замен, выплат, RPC, teacher CRUD, достижений, cutover и UI —
-- всё это отдельные карточки U02B/U02C/U03+.
--
-- Спящее состояние: economy_config.stage4_generation_enabled=false и stage4_started_at=NULL.
-- Существующие таблицы, цены shop_items, балансы, add_huikons и недельная экономика не
-- изменяются. Цены не пересчитываются (это делает U07 атомарно с cutover).
--
-- RLS: как во всём проекте Bot 2.0 — row level security выключен; production-привязка
-- student_id к Telegram identity и боевой доступ откладываются на T10 (см. §5, §8). Внутри
-- этой карточки T10 не проектируется.
--
-- Целостность (Definition of Done U02A):
--   * повторный seed не дублирует шаблоны (on conflict do nothing);
--   * невозможно создать два дневных набора одного ученика на дату (unique student_id+date);
--   * невозможно показать два одинаковых ordinal или один шаблон дважды в дне (unique);
--   * невозможно выплатить один reward_kind дважды за дату (unique student+date+kind);
--   * суммы (3/3/2) и лимит замен (0..2) защищены check-constraint'ами БД;
--   * использованный шаблон нельзя удалить (FK); его выключают через active=false.
-- =============================================================================

-- --- 1. Спящие флаги cutover в economy_config --------------------------------
-- stage4_started_at — неизменяемое время старта генерации (заполнит U07 при cutover).
-- stage4_generation_enabled — включена ли выдача новых дневных наборов. Пока false.
alter table public.economy_config
  add column if not exists stage4_started_at         timestamptz,
  add column if not exists stage4_generation_enabled boolean not null default false;

-- --- 2. Каталог жизненных челленджей (SPEC §3) -------------------------------
-- Справочник в Supabase, а не в JS. Удаление использованного шаблона запрещено (FK ниже):
-- его выключают через active=false, чтобы история и уже показанные наборы читались.
create table if not exists public.life_quest_templates (
  template_code text        primary key,               -- стабильный ASCII-код, не меняется
  name          text        not null,                  -- текст челленджа (редактируется учителем)
  description   text,                                   -- необязательное пояснение
  category      text        not null,                  -- отображаемая категория
  active        boolean     not null default true,
  weight        integer     not null default 1 check (weight > 0),  -- вес случайного выбора
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
-- Активный каталог для взвешенного случайного выбора (U02B).
create index if not exists idx_life_quest_templates_active
  on public.life_quest_templates (template_code) where active;
alter table public.life_quest_templates disable row level security;

-- --- 3. Дневной набор ученика (SPEC §2, §4, §5) ------------------------------
-- Один сохранённый набор на (ученик, календарная дата MSK). daily_assignment_id nullable:
-- при математико-only дне (settlement без life) или пока сегодняшняя daily не появилась он
-- остаётся null. life_template_code nullable: если life задним числом недоступен, его нет.
-- replacements_used 0..2 — не более двух замен за дату.
create table if not exists public.student_daily_quests (
  id                  uuid        primary key default gen_random_uuid(),
  student_id          bigint      not null references public.students (telegram_id),
  quest_date          date        not null,            -- календарная дата Europe/Moscow
  daily_assignment_id uuid        references public.assignments (id) on delete set null,
  life_template_code  text        references public.life_quest_templates (template_code),
  replacements_used   integer     not null default 0 check (replacements_used between 0 and 2),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  unique (student_id, quest_date)                       -- покрывает student+date; второй набор невозможен
);
-- FK life_template_code -> life_quest_templates по умолчанию NO ACTION: используемый в текущем
-- дне шаблон нельзя удалить. Отдельный индекс student+date не нужен: его даёт unique выше.

-- --- 4. История показанных life-шаблонов (SPEC §4) --------------------------
-- Каждый реально показанный за день шаблон + его ordinal 0..2. Нужна для корректной замены
-- («другой ещё не показанный шаблон») и аудита. Уникальность ordinal и шаблона в пределах дня.
create table if not exists public.student_daily_quest_options (
  id             uuid        primary key default gen_random_uuid(),
  daily_quest_id uuid        not null references public.student_daily_quests (id) on delete cascade,
  template_code  text        not null references public.life_quest_templates (template_code),
  ordinal        integer     not null check (ordinal between 0 and 2),
  shown_at       timestamptz not null default now(),
  unique (daily_quest_id, ordinal),                     -- два одинаковых ordinal невозможны
  unique (daily_quest_id, template_code)                -- один шаблон дважды за день невозможен
);
-- FK template_code -> life_quest_templates (NO ACTION): показанный (использованный) шаблон
-- истории нельзя удалить. Запросы по daily_quest_id покрывает unique(daily_quest_id, ordinal).
alter table public.student_daily_quest_options disable row level security;

-- --- 5. Pay-once ledger выплат (SPEC §2, §5) ---------------------------------
-- reward_kind: math=3, life=3, combo=2 (дневной максимум 8). Уникальность
-- (student_id, quest_date, reward_kind) => reload/retry/двойной клик не платят повторно.
-- Composite FK (student_id, quest_date) -> student_daily_quests гарантирует: выплата
-- возможна только когда дневной набор ученика уже создан (settlement создаёт его первым).
create table if not exists public.daily_quest_reward_log (
  id          uuid        primary key default gen_random_uuid(),
  student_id  bigint      not null references public.students (telegram_id),
  quest_date  date        not null,
  reward_kind text        not null check (reward_kind in ('math', 'life', 'combo')),
  bubliks     integer     not null check (bubliks > 0),
  paid_at     timestamptz not null default now(),
  unique (student_id, quest_date, reward_kind),
  -- Сумма жёстко привязана к виду выплаты (защита от неверной эмиссии из будущих RPC).
  check (
    (reward_kind = 'math'  and bubliks = 3) or
    (reward_kind = 'life'  and bubliks = 3) or
    (reward_kind = 'combo' and bubliks = 2)
  ),
  foreign key (student_id, quest_date)
    references public.student_daily_quests (student_id, quest_date)
);
-- Ledger-индекс (student+date+kind) даёт unique выше; отдельный не нужен.
alter table public.daily_quest_reward_log disable row level security;

-- --- 6. Идемпотентный seed стартового каталога (SPEC §3) ---------------------
-- Тексты дословно из SPEC §3; стабильные ASCII template_code. weight=1 у всех (равный шанс).
-- on conflict do nothing => повторное применение не дублирует и не перетирает правки учителя.
insert into public.life_quest_templates (template_code, name, category, weight) values
  ('read_fiction_30m', 'Читать художественную литературу не менее 30 минут',                                    'Чтение',      1),
  ('walk_30m',         'Гулять не менее 30 минут',                                                               'Движение',    1),
  ('squats_50',        'Сделать 50 приседаний в течение дня',                                                    'Движение',    1),
  ('pushups_30',       'Сделать 30 отжиманий в течение дня; допустим подходящий вариант с колен или от опоры',   'Движение',    1),
  ('warmup_full',      'Сделать полноценную разминку',                                                           'Движение',    1),
  ('no_phone_45m',     'Провести 45 минут без телефона',                                                         'Внимание',    1),
  ('tidy_workspace',   'Привести в порядок рабочее место и учебные материалы',                                   'Организация', 1),
  ('plan_next_day',    'Подготовить план занятий на следующий день',                                             'Организация', 1)
on conflict (template_code) do nothing;

-- =============================================================================
-- ROLLBACK (действителен, пока схема спящая — генерации/выплат ещё нет, данных
-- учеников в этих таблицах нет; балансы и history не затрагиваются):
--
--   drop table if exists public.daily_quest_reward_log;
--   drop table if exists public.student_daily_quest_options;
--   drop table if exists public.student_daily_quests;
--   drop table if exists public.life_quest_templates;
--   alter table public.economy_config
--     drop column if exists stage4_generation_enabled,
--     drop column if exists stage4_started_at;
-- =============================================================================
