import asyncio
import logging
import os
from datetime import datetime, timedelta, timezone

import requests
from aiogram import Bot, Dispatcher, types
from aiogram.filters import Command
from dotenv import load_dotenv

load_dotenv()

# Токен бота — берётся из .env (см. .env.example), не хранится в коде
API_TOKEN = os.environ['STUDENT_BOT_TOKEN']

# Ссылка на мини-апп (GitHub Pages) — Bot 2.0 dev-форк, не прод
WEBAPP_URL = "https://billyrubinius-crypto.github.io/sasha-math-bot-2/"

# Supabase — Bot 2.0 dev-проект (sasha-math-bot-2-dev), НЕ прод. См. bot2/BOT2_CONTEXT.md.
# Тот же публичный REST-доступ, что и у parent_bot.py; рассылка только читает assignments, ничего не пишет
SUPABASE_URL = 'https://ewwmsoecabfdldccrjfc.supabase.co'
SUPABASE_KEY = 'sb_publishable_LB2cXXcEvYODJMzOa6rJ-A_8dhmGE4b'
SUPABASE_HEADERS = {
    'apikey': SUPABASE_KEY,
    'Authorization': f'Bearer {SUPABASE_KEY}',
    'Content-Type': 'application/json'
}

# МСК = UTC+3 круглый год — тот же приём, что и getTodayMSK() в index.html/teacher.html
MSK = timezone(timedelta(hours=3))
MORNING_DIGEST_TIME_MSK = (9, 0)    # (час, минута) — сколько заданий доступно сегодня
EVENING_REMINDER_TIME_MSK = (19, 0)  # (час, минута) — напоминание о несданном

TYPE_LABELS = {'daily': '📅 Ежедневные', 'weekly': '🔥 Еженедельное', 'individual': '🎯 Индивидуальные'}

# Настройка логирования
logging.basicConfig(level=logging.INFO)

# Инициализация бота и диспетчера
bot = Bot(token=API_TOKEN)
dp = Dispatcher()


def today_msk_str() -> str:
    return datetime.now(MSK).strftime('%Y-%m-%d')


def fetch_active_assignments() -> list:
    """Строки assignments, которые уже активны либо ждут клиентской активации — общее сырьё для обеих
    рассылок, только чтение. 'scheduled' включены намеренно: активация происходит на стороне Mini App
    при заходе ученика (checkAndActivateAssignments()), а не сама по себе — is_effectively_active()
    ниже досчитывает то же правило, не дожидаясь, пока ученик откроет приложение.
    week_label и revision_deadline_at добавлены в W08: нужны, чтобы отличить возвращённую daily с
    открытым окном исправления (SPEC §11) и weekly текущей недели от прочих строк, без второго запроса."""
    resp = requests.get(
        f'{SUPABASE_URL}/rest/v1/assignments',
        headers=SUPABASE_HEADERS,
        params={
            'activation_status': 'in.(active,scheduled)',
            'select': 'student_id,type,scheduled_date,week_label,status,approval_status,'
                      'activation_status,revision_deadline_at'
        }
    )
    resp.raise_for_status()
    return resp.json()


def is_effectively_active(row: dict, today: str) -> bool:
    """Совпадает по смыслу с checkAndActivateAssignments() в index.html (scheduled_date <= сегодня):
    задание уже наступило, даже если ученик ещё не открывал Mini App и activation_status ещё не успел
    переключиться на 'active'. Без этого рассылка не доходила бы как раз до тех, кто сам не заходит
    в приложение — то есть до тех, кому она нужнее всего."""
    if row['activation_status'] == 'active':
        return True
    return row['activation_status'] == 'scheduled' and bool(row.get('scheduled_date')) and row['scheduled_date'] <= today


def group_counts_by_student(rows: list, today: str) -> dict:
    """{student_id: {'daily': n, 'weekly': n, 'individual': n}}; ежедневные считаются только на сегодняшнюю дату — как в index.html."""
    counts = {}
    for row in rows:
        if row['type'] == 'daily' and row.get('scheduled_date') != today:
            continue
        student_counts = counts.setdefault(row['student_id'], {'daily': 0, 'weekly': 0, 'individual': 0})
        if row['type'] in student_counts:
            student_counts[row['type']] += 1
    return counts


def format_counts_message(header: str, counts: dict, footer: str = '') -> str:
    lines = [f"<b>{header}</b>", '']
    for key, label in TYPE_LABELS.items():
        n = counts.get(key, 0)
        if n:
            lines.append(f"{label}: {n}")
    if footer:
        lines.append('')
        lines.append(footer)
    return '\n'.join(lines)


async def send_safely(student_id: int, text: str):
    """Ошибка отправки одному ученику (например, заблокировал бота) не должна прерывать рассылку остальным."""
    try:
        await bot.send_message(student_id, text, parse_mode="HTML")
    except Exception as e:
        logging.warning(f"Не удалось отправить уведомление {student_id}: {e}")


async def send_morning_digest():
    """09:00 МСК — сколько заданий доступно сегодня, по типам (как сводка на экране профиля Mini App)."""
    today = today_msk_str()
    rows = [r for r in fetch_active_assignments() if r['status'] == 'assigned' and is_effectively_active(r, today)]
    counts = group_counts_by_student(rows, today)

    for student_id, student_counts in counts.items():
        if sum(student_counts.values()) == 0:
            continue
        text = format_counts_message(
            '☀️ Доброе утро! Сегодня доступно:', student_counts,
            'Открой приложение, чтобы начать 🚀'
        )
        await send_safely(student_id, text)


def week_start_of(d) -> str:
    """Понедельник недели, содержащей дату d — тот же приём, что week_start_of в БД (W04) и
    week_start_of в parent_bot.py (W07): свой read-only Python-хелпер на файл, без общей утилиты."""
    return (d - timedelta(days=d.isoweekday() - 1)).isoformat()


def has_open_revision_window(row: dict, now: datetime) -> bool:
    """revision_deadline_at пишет только сервер (триггер W04) — здесь только сравнение с текущим
    временем для показа, новое право не изобретается (тот же принцип, что в index.html/teacher.html)."""
    dl = row.get('revision_deadline_at')
    if not dl:
        return False
    try:
        deadline = datetime.fromisoformat(dl.replace('Z', '+00:00'))
    except (ValueError, AttributeError):
        return False
    return deadline > now


def classify_evening_row(row: dict, today: str, current_week_label: str, now: datetime) -> str | None:
    """Одна строка assignments -> ровно одна категория ('new'/'revision') или None (не напоминать).
    Однозначная классификация одной строкой гарантирует отсутствие дубля в одном запуске (W08).

    daily: сегодняшняя несданная -> 'new'; возвращённая с ещё живым окном исправления
    (revision_deadline_at > now), в т.ч. прошлой даты, -> 'revision'; pending review ('submitted')
    и просроченное исправление ни в одну категорию не попадают — не напоминаются (SPEC §11).
    weekly: только текущей недели (week_label == понедельник этой недели); возвращённая weekly
    напоминается как 'new' — у weekly нет окна исправления (W04: только у daily).
    individual: как раньше, без даты и различения категорий."""
    rtype, status, approval = row['type'], row['status'], row.get('approval_status')

    if rtype == 'daily':
        if status == 'assigned':
            return 'new' if row.get('scheduled_date') == today else None
        if status == 'checked' and approval == 'rejected':
            return 'revision' if has_open_revision_window(row, now) else None
        return None

    if rtype == 'weekly' and row.get('week_label') != current_week_label:
        return None

    if status == 'assigned' or (status == 'checked' and approval == 'rejected'):
        return 'new'
    return None


def group_evening_by_student(rows: list, today: str, current_week_label: str, now: datetime) -> dict:
    """{student_id: {'new': {'daily':n,'weekly':n,'individual':n}, 'revision_daily': n}}"""
    counts = {}
    for row in rows:
        category = classify_evening_row(row, today, current_week_label, now)
        if category is None:
            continue
        student = counts.setdefault(
            row['student_id'], {'new': {'daily': 0, 'weekly': 0, 'individual': 0}, 'revision_daily': 0}
        )
        if category == 'revision':
            student['revision_daily'] += 1
        else:
            student['new'][row['type']] += 1
    return counts


def plural_ru(n: int, one: str, few: str, many: str) -> str:
    """1 работа / 2 работы / 5 работ — тот же mod10/mod100 приём, что pluralShields/pluralTasks
    в JS-файлах проекта, здесь для main.py."""
    mod10, mod100 = n % 10, n % 100
    if mod10 == 1 and mod100 != 11:
        return one
    if 2 <= mod10 <= 4 and not (10 <= mod100 <= 20):
        return few
    return many


def format_evening_message(new_counts: dict, revision_daily: int) -> str:
    """Новое задание и исправление показаны раздельно (карточка W08: 'явно различать')."""
    lines = ['<b>🌙 Не забудь про домашку!</b>', '']

    if any(new_counts.values()):
        lines.append('Ещё не сдано:')
        for key, label in TYPE_LABELS.items():
            n = new_counts.get(key, 0)
            if n:
                lines.append(f"{label}: {n}")
        lines.append('')

    if revision_daily:
        word = plural_ru(revision_daily, 'работу', 'работы', 'работ')
        lines.append(f"✏️ Учитель вернул на исправление: {revision_daily} {word} — ещё есть время сдать заново")
        lines.append('')

    footer = []
    if new_counts.get('daily', 0) > 0:
        footer.append('⏰ Ежедневное нужно сдать сегодня до 23:59 МСК!')
    if revision_daily:
        footer.append('✏️ Не забудь уложиться в срок исправления.')
    footer.append('Открой приложение, чтобы сдать 🚀')
    lines.extend(footer)

    return '\n'.join(lines)


async def send_evening_reminder():
    """19:00 МСК — напоминание о несданном (SPEC §11, W08): сегодняшняя daily + возвращённая daily
    с открытым окном исправления (даже прошлой даты) + weekly текущей недели + individual как раньше.
    pending review ('submitted') и просроченное исправление не напоминаются."""
    now = datetime.now(MSK)
    today = today_msk_str()
    current_week_label = week_start_of(now.date())

    rows = [r for r in fetch_active_assignments() if is_effectively_active(r, today)]
    counts = group_evening_by_student(rows, today, current_week_label, now)

    for student_id, c in counts.items():
        if sum(c['new'].values()) == 0 and c['revision_daily'] == 0:
            continue
        await send_safely(student_id, format_evening_message(c['new'], c['revision_daily']))


def fetch_last_sent(key: str):
    """Дата последней успешной отправки уведомления key, сохранённая в Supabase — переживает
    рестарт/передеплой процесса, в отличие от переменной в памяти (было причиной повторной
    отправки одной и той же рассылки при каждом передеплое после времени срабатывания)."""
    resp = requests.get(
        f'{SUPABASE_URL}/rest/v1/bot_notification_state',
        headers=SUPABASE_HEADERS,
        params={'notification_key': f'eq.{key}', 'select': 'last_sent_date'}
    )
    resp.raise_for_status()
    rows = resp.json()
    if not rows or not rows[0]['last_sent_date']:
        return None
    return datetime.strptime(rows[0]['last_sent_date'], '%Y-%m-%d').date()


def mark_sent(key: str, sent_date):
    headers = {**SUPABASE_HEADERS, 'Prefer': 'resolution=merge-duplicates'}
    resp = requests.post(
        f'{SUPABASE_URL}/rest/v1/bot_notification_state',
        headers=headers,
        params={'on_conflict': 'notification_key'},
        json={'notification_key': key, 'last_sent_date': sent_date.isoformat()}
    )
    resp.raise_for_status()


async def scheduler_loop():
    """Раз в сутки, в фиксированное время по МСК (проверка раз в минуту), без сторонних зависимостей
    вроде APScheduler. Срабатывает при «время уже наступило или прошло», а не по точному совпадению —
    устойчиво к дрейфу цикла и к тому, что fetch_active_assignments() ненадолго блокирует event loop.

    last_*_sent при старте загружается из Supabase (bot_notification_state), не только из памяти —
    переживает рестарт/передеплой процесса. Раньше при перезапуске уже ПОСЛЕ времени срабатывания
    в тот же день (например, при передеплое, вообще не связанном с main.py — см. историю бага
    2026-07-11) рассылка на сегодня уходила ПОВТОРНО при каждом таком перезапуске."""
    try:
        last_morning_sent = fetch_last_sent('morning_digest')
        last_evening_sent = fetch_last_sent('evening_reminder')
    except Exception as e:
        logging.error(f"Не удалось загрузить состояние рассылки, начинаем с нуля: {e}")
        last_morning_sent = None
        last_evening_sent = None

    while True:
        now = datetime.now(MSK)
        today = now.date()
        now_hm = (now.hour, now.minute)

        if now_hm >= MORNING_DIGEST_TIME_MSK and last_morning_sent != today:
            last_morning_sent = today
            try:
                await send_morning_digest()
            except Exception as e:
                logging.error(f"Ошибка утренней рассылки: {e}")
            else:
                try:
                    mark_sent('morning_digest', today)
                except Exception as e:
                    logging.error(f"Не удалось сохранить состояние утренней рассылки: {e}")
        elif now_hm >= EVENING_REMINDER_TIME_MSK and last_evening_sent != today:
            last_evening_sent = today
            try:
                await send_evening_reminder()
            except Exception as e:
                logging.error(f"Ошибка вечерней рассылки: {e}")
            else:
                try:
                    mark_sent('evening_reminder', today)
                except Exception as e:
                    logging.error(f"Не удалось сохранить состояние вечерней рассылки: {e}")

        await asyncio.sleep(60)

@dp.message(Command("start"))
async def cmd_start(message: types.Message):
    """Обработчик команды /start"""
    
    # Текст приветствия
    welcome_text = (
        f"👋 Привет, <b>{message.from_user.first_name}</b>!\n\n"
        "Я — твой помощник по математике Sasha Math. \n\n"
        "Здесь ты можешь:\n"
        "• 📊 Следить за своим рейтингом и бубликами\n"
        "• 📤 Загружать домашние задания на проверку\n"
        "•  Соревноваться с одноклассниками в лидерборде\n\n"
        " Нажми на кнопку <b>'Открыть профиль'</b> внизу слева, чтобы начать!"
    )
    
    # Отправляем сообщение без клавиатуры (используем Menu Button)
    await message.answer(
        text=welcome_text,
        parse_mode="HTML"
    )

async def main():
    """Запуск бота"""
    print("✅ Бот запущен и готов к работе!")
    asyncio.create_task(scheduler_loop())
    await dp.start_polling(bot)

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\n🛑 Бот остановлен.")