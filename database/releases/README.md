# database/releases — release-артефакты Stage 4

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

## Порядок релиза Stage 4

1. **Maintenance** — окно обслуживания / пауза клиентских ботов при необходимости.
2. **Миграции по 031 включительно** — раскатать `database/migrations/` до `031`. Состояние
   остаётся dormant. `031` откажется сбрасывать, если Stage 4 уже имеет реальные данные
   (`student_daily_quests` / `daily_quest_reward_log`) — это защита от случайной нейтрализации
   запущенной Stage 4.
3. **Deploy T10 / server / client** — привязка identity (T10), серверный и клиентский код.
5. **Preflight** — убедиться, что `stage4_started_at IS NULL`, `generation=false`, цены = pre-cutover,
   `frame_fire100.active=true`, нет строк квестов. Сам `stage4_cutover.sql` повторяет эти проверки и
   аварийно останавливается при любом несоответствии (частичный firing невозможен).
6. **Firing** — выполнить [`stage4_cutover.sql`](stage4_cutover.sql) **отдельно**, предпочтительно в
   **понедельник**. Одна guarded транзакция: old→approved цены + `stage4_started_at=now()` (только из
   NULL) + `generation=true`.
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
| `stage4_cutover.sql` | Guarded firing Stage 4 + (в комментарии) product-rollback | Вручную, отдельным шагом после T10 |
