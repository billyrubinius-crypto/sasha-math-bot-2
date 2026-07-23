# database/releases — ручные release-артефакты

Здесь лежат скрипты, которые **не являются миграциями** и **не применяются** обычным прогоном
`database/migrations/`. Это отдельные осознанные шаги запуска, выполняемые вручную оператором.

## Ключевой принцип

**Применение миграций ≠ firing.** Полная цепочка миграций `021 → 031` заканчивается в
**dormant**-состоянии: `stage4_generation_enabled=false`, `stage4_started_at=NULL`, каталог по
pre-cutover ценам, `frame_fire100.active=true`. Это гарантирует `031` (bootstrap-neutralizer),
который нейтрализует исполняемый firing внутри исторической миграции `030`. Поэтому раскатка схемы
на новом окружении никого не «запускает».

Реальный запуск Stage 4 (approved цены + генерация) — **только** через
[`stage4_cutover.sql`](stage4_cutover.sql), отдельным шагом.

T10-11 имеет отдельный, более ранний ручной gate:
[`t10_anon_closure.sql`](t10_anon_closure.sql) атомарно закрывает browser grants и переводит
`private.security_runtime_config.auth_mode` из `legacy` в `enforced`. Он не запускает Stage 4,
не импортирует реальные данные и не применяется к production до T10-12.

## Порядок T10-11 на dev

1. Применить migration `047_t10_direct_rpc_hardening.sql`.
2. Выполнить `t10_anon_closure.sql` целиком одним запуском. Скрипт дважды проверяет inventory
   (до и после singleton-lock), затем меняет grants, default privileges и runtime mode одной
   транзакцией. Любой drift откатывает всё.
3. Выполнить `database/tests/b2_t11_security_matrix.sql`; ожидается
   `PASS B2-T11 (20/20)`. Тест заканчивается `ROLLBACK`, synthetic rows и ACL probes не остаются.
4. Пройти живой student/teacher/API/media smoke из карточки T10-11.
5. При первом regression без попытки «дочинить на месте» выполнить
   `t10_anon_closure_rollback.sql`. Он возвращает фактический DB mode `legacy`, но сохраняет
   RLS, hardening 032–047, закрытые service-only RPC и безопасные default privileges.

Все три SQL запускаются владельцем вручную в dev. В них не подставляются URL, ключи, токены или
другие секреты.

## Порядок релиза Stage 4

1. **Maintenance** — окно обслуживания / пауза клиентских ботов при необходимости.
2. **Миграции по 031 включительно** — раскатать `database/migrations/` до `031`. Состояние
   остаётся dormant. `031` откажется сбрасывать, если Stage 4 уже имеет реальные данные
   (`student_daily_quests` / `daily_quest_reward_log`) — это защита от случайной нейтрализации
   запущенной Stage 4.
3. **Deploy T10 / server / client** — привязка identity (T10), серверный и клиентский код.
4. **Preflight** — убедиться, что `stage4_started_at IS NULL`, `generation=false`, цены = pre-cutover,
   `frame_fire100.active=true`, нет строк квестов, `economy_config` содержит ровно одну singleton-
   строку. Сам `stage4_cutover.sql` повторяет эти проверки и аварийно останавливается при любом
   несоответствии (частичный firing невозможен).
5. **Firing** — выполнить [`stage4_cutover.sql`](stage4_cutover.sql) **отдельно**, предпочтительно в
   **понедельник**. Одна guarded транзакция: old→approved цены + `stage4_started_at=now()` (только из
   NULL) + `generation=true`; финальный `UPDATE economy_config` проверяется на `ROW_COUNT=1`.
6. **Post-check** — approved цены на витрине, `generation=true`, `started_at` зафиксирован; первая
   отправка раньше `started_at` не оплачивается задним числом (U02D-гейт).

## Откат

- **До firing** (bootstrap): состояние уже dormant; ничего откатывать не нужно. Повторная раскатка
  `031` идемпотентно подтверждает dormant.
- **После firing** (product-rollback): использовать закомментированную секцию PRODUCT-ROLLBACK в конце
  [`stage4_cutover.sql`](stage4_cutover.sql). Она возвращает цены и выключает генерацию, но
  **сохраняет** `stage4_started_at`, дневные строки, ledger, балансы и inventory — settlement уже
  созданных math/combo продолжается. Это НЕ то же самое, что bootstrap-neutralizer `031`
  (тот сбрасывает `started_at` в NULL и разрешён только при пустой Stage 4).

## Файлы

| Файл | Назначение | Когда |
|---|---|---|
| `dev_game_reset.sql` | DEV-only очистка тестовой экономики/квестов + немедленный недельный cutover | Только в dev перед повторным `stage4_cutover.sql`; никогда не в production |
| `stage4_cutover.sql` | Guarded firing Stage 4 + (в комментарии) product-rollback | Вручную, отдельным шагом после T10 |
| `t10_anon_closure.sql` | Atomic `legacy` → `enforced`, browser allowlists и default-deny | Dev T10-11; production только внутри T10-12 |
| `t10_anon_closure_rollback.sql` | Идемпотентный rollback T10-11 в DB mode `legacy` | При первом regression после anon closure |
