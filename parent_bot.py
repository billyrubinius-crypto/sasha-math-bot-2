import asyncio
import html
import io
import logging
import os
import sys
from datetime import datetime, timedelta, timezone

import httpx
from dotenv import load_dotenv

sys.stdout.reconfigure(encoding='utf-8')
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

from aiogram import Bot, Dispatcher, F, types
from aiogram.filters import Command

load_dotenv()

# Токен бота для родителей (отдельный от основного бота учеников) — берётся из .env, не хранится в коде
API_TOKEN = os.environ['PARENT_BOT_TOKEN']

# Bot 2.0 dev-проект (sasha-math-bot-2-dev), НЕ прод. См. bot2/BOT2_CONTEXT.md.
SUPABASE_URL = 'https://ewwmsoecabfdldccrjfc.supabase.co'
SUPABASE_KEY = 'sb_publishable_LB2cXXcEvYODJMzOa6rJ-A_8dhmGE4b'
SUPABASE_HEADERS = {
    'apikey': SUPABASE_KEY,
    'Authorization': f'Bearer {SUPABASE_KEY}',
    'Content-Type': 'application/json'
}

TYPE_LABELS = {'daily': '📅 Ежедневные', 'weekly': '🔥 Еженедельные', 'individual': '🎯 Индивидуальные'}

NETWORK_ERROR_TEXT = "⚠️ Сервер временно недоступен. Попробуйте ещё раз чуть позже."

logging.basicConfig(level=logging.INFO)

bot = Bot(token=API_TOKEN)
dp = Dispatcher()

# Общий асинхронный HTTP-клиент на весь процесс бота — не блокирует event loop на каждом запросе
# к Supabase, в отличие от синхронного requests. Переиспользуется между вызовами (пул соединений),
# закрывается при остановке бота (см. main()).
http_client = httpx.AsyncClient(timeout=10.0)


async def get_student(student_id: int):
    resp = await http_client.get(
        f'{SUPABASE_URL}/rest/v1/students',
        headers=SUPABASE_HEADERS,
        params={'telegram_id': f'eq.{student_id}', 'select': 'telegram_id,name,group_name'}
    )
    resp.raise_for_status()
    rows = resp.json()
    return rows[0] if rows else None


async def link_parent(parent_id: int, student_id: int):
    headers = {**SUPABASE_HEADERS, 'Prefer': 'resolution=ignore-duplicates'}
    resp = await http_client.post(
        f'{SUPABASE_URL}/rest/v1/parent_links',
        headers=headers,
        params={'on_conflict': 'parent_telegram_id,student_id'},
        json={'parent_telegram_id': parent_id, 'student_id': student_id}
    )
    resp.raise_for_status()


async def get_linked_students(parent_id: int):
    resp = await http_client.get(
        f'{SUPABASE_URL}/rest/v1/parent_links',
        headers=SUPABASE_HEADERS,
        params={'parent_telegram_id': f'eq.{parent_id}', 'select': 'student_id,students(name,group_name)'}
    )
    resp.raise_for_status()
    return resp.json()


async def get_progress(student_id: int):
    resp = await http_client.post(
        f'{SUPABASE_URL}/rest/v1/rpc/get_student_progress',
        headers=SUPABASE_HEADERS,
        json={'p_student_id': student_id}
    )
    resp.raise_for_status()
    return resp.json()


async def get_mock_exams(student_id: int):
    resp = await http_client.get(
        f'{SUPABASE_URL}/rest/v1/mock_exam_results',
        headers=SUPABASE_HEADERS,
        params={'student_id': f'eq.{student_id}', 'select': 'exam_name,score,exam_date,created_at', 'order': 'created_at.asc'}
    )
    resp.raise_for_status()
    return resp.json()


# --- Текущая неделя (W07 correction): единый read-only контракт живёт в Supabase.
# Бот только получает готовые N/A/S/E, статусы дней и weekly и форматирует их для Telegram.
async def get_current_week(student_id: int) -> dict:
    resp = await http_client.post(
        f'{SUPABASE_URL}/rest/v1/rpc/get_student_current_week',
        headers=SUPABASE_HEADERS,
        json={'p_student_id': student_id}
    )
    resp.raise_for_status()
    return resp.json()


# U05B — единственный источник траектории пробников: get_mock_exam_trajectory (U05A), читает
# только weekly_mock_exams. avg/range/trend/delta считает сервер; здесь их не пересчитываем
# (SPEC_STAGE4 §7). Legacy mock_exam_results (до P02A, get_mock_exams ниже) этой RPC не задета.
async def get_mock_exam_trajectory(student_id: int) -> dict:
    resp = await http_client.post(
        f'{SUPABASE_URL}/rest/v1/rpc/get_mock_exam_trajectory',
        headers=SUPABASE_HEADERS,
        json={'p_student_id': student_id}
    )
    resp.raise_for_status()
    return resp.json()


def format_date_ru(value: str | None) -> str:
    try:
        return datetime.strptime(value, '%Y-%m-%d').strftime('%d.%m')
    except (ValueError, TypeError):
        return '—'


def format_msk_timestamp(value: str | None) -> str:
    try:
        parsed = datetime.fromisoformat(value.replace('Z', '+00:00'))
        return parsed.astimezone(timezone(timedelta(hours=3))).strftime('%d.%m %H:%M')
    except (ValueError, TypeError, AttributeError):
        return '—'


WEEKLY_ITEM_LABELS = {
    'assigned': 'назначено', 'submitted': 'отправлено',
    'approved': 'принято', 'rejected': 'возвращено', 'unknown': 'неизвестно'
}


def format_week_block(week: dict) -> str:
    n = int(week.get('n') or 0)
    a = int(week.get('a') or 0)
    s = int(week.get('s') or 0)
    e = int(week.get('e') or 0)
    start = format_date_ru(week.get('week_start'))
    end = format_date_ru(week.get('week_end'))

    lines = [f"\n🗓️ <b>Текущая неделя</b> ({start}–{end}):"]
    lines.append(f"Ежедневные: {a} из {n} принято" + (f", 🛡 щитов: {s}" if s else "")
                 + f" → эффективно {e}")

    weekly = week.get('weekly')
    if weekly:
        weekly_label = WEEKLY_ITEM_LABELS.get(weekly.get('status'), 'неизвестно')
        title = html.escape(weekly.get('title') or 'Без названия')
        lines.append(f"🔥 Еженедельное: {weekly_label} — «{title}»")
    else:
        lines.append("🔥 Еженедельное: не назначено")

    revisions = [day for day in (week.get('days') or []) if day.get('status') == 'revision']
    if revisions:
        lines.append("✏️ Открытые исправления:")
        for day in revisions:
            title = html.escape(day.get('title') or 'Без названия')
            deadline = format_msk_timestamp(day.get('revision_deadline_at'))
            lines.append(f"  • «{title}» — до {deadline} МСК")

    status_text = {
        'pending': "⏳ Итог недели пока уточняется: есть работа на проверке у учителя или "
                   "открытое окно для исправления.",
        'successful': "✅ Неделя засчитывается как успешная.",
        'weak': "Выполнено меньше половины назначенного на неделю — неделя слабая, без награды.",
        'neutral': "➖ На этой неделе назначено меньше 4 ежедневных заданий — неделя нейтральная, "
                   "не засчитывается ни в плюс, ни в минус.",
    }
    lines.append(status_text.get(week.get('classification'), status_text['neutral']))
    return "\n".join(lines)


def format_sync_date(created_at: str) -> str:
    """Дата синхронизации Apps Script (created_at) — используется как запасной вариант, если exam_date ещё не заполнена."""
    try:
        return datetime.fromisoformat(created_at.replace('Z', '+00:00')).strftime('%d.%m.%Y')
    except (ValueError, TypeError, AttributeError):
        return '—'


def format_exam_date(exam: dict) -> str:
    """Настоящая дата пробника (exam_date, YYYY-MM-DD без времени — парсим вручную, без часовых поясов),
    если помощник её ещё не вписал в таблицу — используем дату синхронизации, как раньше."""
    exam_date = exam.get('exam_date')
    if exam_date:
        try:
            y, m, d = exam_date.split('-')
            return f'{d}.{m}.{y}'
        except (ValueError, AttributeError):
            pass
    return format_sync_date(exam.get('created_at'))


def format_score_delta(exams: list) -> str | None:
    """Изменение последнего результата к предыдущему пробнику (P02B) — простая разница двух
    чисел, не прогноз (карточка запрещает медицинские/гарантирующие формулировки). None, если
    пробник один или встретился нечисловой legacy score."""
    if len(exams) < 2:
        return None
    try:
        last = int(exams[-1]['score'])
        prev = int(exams[-2]['score'])
    except (ValueError, TypeError):
        return None
    delta = last - prev
    sign = '+' if delta > 0 else ''
    return f"Изменение к предыдущему: {sign}{delta}"


def format_plain_date(date_str: str | None) -> str:
    """week_start — чистая дата (YYYY-MM-DD, без времени), парсим вручную, без часовых поясов
    (как format_exam_date выше)."""
    if not date_str:
        return '—'
    try:
        y, m, d = date_str.split('-')
        return f'{d}.{m}.{y}'
    except (ValueError, AttributeError):
        return '—'


def format_trajectory_summary(trajectory: dict) -> str:
    """Сводка по готовым серверным полям get_mock_exam_trajectory (U05A) — delta/avg/range/trend
    здесь не пересчитываются, только форматируются (SPEC_STAGE4 §7)."""
    parts = [f"Последний результат: {trajectory.get('last_score')}"]
    delta = trajectory.get('delta_last')
    if delta is not None:
        sign = '+' if delta > 0 else ''
        parts.append(f"({sign}{delta})")
    avg = trajectory.get('avg_last_3')
    if avg is not None:
        parts.append(f"· среднее по 3: {avg} ({trajectory.get('min_last_3')}–{trajectory.get('max_last_3')})")
    trend = trajectory.get('trend')
    trend_labels = {'up': 'растёт 📈', 'flat': 'стабильно ➖', 'down': 'снижается 📉'}
    if trend:
        parts.append(f"· {trend_labels.get(trend, trend)}")
    return " ".join(parts) + "\nДиапазон последних пробников — не гарантия балла ЕГЭ."


def format_progress_message(student_name: str, progress_rows: list, trajectory: dict) -> str:
    progress_by_type = {row['type']: row for row in progress_rows}
    lines = [f"📊 Результаты ученика <b>{student_name}</b>:\n"]
    for key, label in TYPE_LABELS.items():
        row = progress_by_type.get(key, {'issued': 0, 'completed': 0})
        lines.append(f"{label}: {row['completed']} из {row['issued']} выполнено")

    points = (trajectory or {}).get('points') or []
    if points:
        lines.append("\n🧮 Пробники:")
        for i, point in enumerate(points, 1):
            date_str = format_plain_date(point.get('week_start'))
            lines.append(f"№{i} — {point['score']} баллов ({date_str})")
        lines.append(format_trajectory_summary(trajectory))
    else:
        lines.append("\n🧮 Пробников пока нет.")

    return "\n".join(lines)


def render_mock_chart(trajectory: dict):
    """Рисует график траектории пробников в PNG — так же, как график на экране профиля в Mini App:
    ось X — порядковый номер («№1», «№2»...), дата уходит в текст сообщения. Источник — points из
    get_mock_exam_trajectory (U05A/U05B), не legacy mock_exam_results."""
    points = (trajectory or {}).get('points') or []
    if not points:
        return None

    labels = [f'№{i + 1}' for i in range(len(points))]
    scores = [float(p['score']) for p in points]

    fig, ax = plt.subplots(figsize=(6, 3.6), dpi=150)
    ax.plot(labels, scores, marker='o', color='#2481cc', linewidth=2)
    ax.set_ylim(bottom=max(0, min(scores) - 10), top=max(scores) + 10)
    ax.set_title('Результаты пробников')
    ax.set_ylabel('Баллы')
    ax.grid(True, alpha=0.3)
    ax.set_xticks(range(len(labels)))
    ax.set_xticklabels(labels, fontsize=9)

    for i, score in enumerate(scores):
        label = str(int(score)) if score == int(score) else str(score)
        ax.annotate(label, (i, score), textcoords="offset points", xytext=(0, 8), ha='center', fontsize=8)

    buf = io.BytesIO()
    fig.tight_layout()
    fig.savefig(buf, format='png')
    plt.close(fig)
    buf.seek(0)
    return buf


async def send_student_progress(message: types.Message, student_id: int, student_name: str):
    try:
        progress = await get_progress(student_id)
        trajectory = await get_mock_exam_trajectory(student_id)
    except httpx.HTTPError as e:
        logging.warning(f"Не удалось загрузить прогресс {student_id}: {e}")
        await message.answer(NETWORK_ERROR_TEXT)
        return

    text = format_progress_message(student_name, progress, trajectory)

    # Блок текущей недели (W07) — необязательное дополнение: сбой её загрузки не должен
    # ломать старый /progress (карточка требует "старый /progress работает").
    try:
        week = await get_current_week(student_id)
        text += "\n" + format_week_block(week)
    except httpx.HTTPError as e:
        logging.warning(f"Не удалось загрузить недельный блок {student_id}: {e}")

    await message.answer(text, parse_mode="HTML")

    chart = render_mock_chart(trajectory)
    if chart:
        photo = types.BufferedInputFile(chart.read(), filename="progress.png")
        await message.answer_photo(photo)


@dp.message(Command("start"))
async def cmd_start(message: types.Message):
    """Обработчик /start — как обычный запуск, так и переход по ссылке-приглашению (/start <telegram_id ученика>)"""

    args = message.text.split(maxsplit=1)
    payload = args[1].strip() if len(args) > 1 else None

    if payload and payload.isdigit():
        student_id = int(payload)
        try:
            student = await get_student(student_id)
        except httpx.HTTPError as e:
            logging.warning(f"Не удалось проверить ученика {student_id}: {e}")
            await message.answer(NETWORK_ERROR_TEXT)
            return

        if not student:
            await message.answer("⚠️ Ученик с такой ссылкой не найден. Попроси прислать актуальную ссылку из приложения.")
            return

        try:
            await link_parent(message.from_user.id, student_id)
        except httpx.HTTPError as e:
            logging.warning(f"Не удалось привязать родителя {message.from_user.id} к ученику {student_id}: {e}")
            await message.answer(NETWORK_ERROR_TEXT)
            return

        await message.answer(
            f"✅ Вы успешно подключены к результатам ученика <b>{student['name']}</b>!\n\n"
            "Команда /progress — посмотреть текущие результаты.",
            parse_mode="HTML"
        )
        return

    welcome_text = (
        "👋 Привет! Я бот для родителей учеников <b>Sasha Math</b>.\n\n"
        "Чтобы подключиться к результатам ребёнка, попроси его прислать тебе "
        "пригласительную ссылку из раздела «Ещё» в приложении.\n\n"
        "Уже подключены? Команда /progress — посмотреть результаты."
    )
    await message.answer(welcome_text, parse_mode="HTML")


@dp.message(Command("progress"))
async def cmd_progress(message: types.Message):
    try:
        linked = await get_linked_students(message.from_user.id)
    except httpx.HTTPError as e:
        logging.warning(f"Не удалось получить список подключённых учеников для {message.from_user.id}: {e}")
        await message.answer(NETWORK_ERROR_TEXT)
        return

    if not linked:
        await message.answer("Вы пока не подключены ни к одному ученику. Попросите ребёнка прислать пригласительную ссылку из раздела «Ещё».")
        return

    if len(linked) == 1:
        entry = linked[0]
        student_name = entry['students']['name'] if entry.get('students') else 'Ученик'
        await send_student_progress(message, entry['student_id'], student_name)
        return

    buttons = [
        [types.InlineKeyboardButton(
            text=e['students']['name'] if e.get('students') else f"Ученик {e['student_id']}",
            callback_data=f"progress_{e['student_id']}"
        )]
        for e in linked
    ]
    kb = types.InlineKeyboardMarkup(inline_keyboard=buttons)
    await message.answer("У вас подключено несколько учеников — выберите:", reply_markup=kb)


@dp.callback_query(F.data.startswith("progress_"))
async def on_progress_pick(callback: types.CallbackQuery):
    student_id = int(callback.data.split("_", 1)[1])
    try:
        student = await get_student(student_id)
    except httpx.HTTPError as e:
        logging.warning(f"Не удалось получить ученика {student_id}: {e}")
        await callback.answer("Сервер временно недоступен, попробуйте ещё раз", show_alert=True)
        return

    if not student:
        await callback.answer("Ученик не найден", show_alert=True)
        return

    await send_student_progress(callback.message, student_id, student['name'])
    await callback.answer()


async def main():
    print("✅ Бот для родителей запущен и готов к работе!")
    try:
        await dp.start_polling(bot)
    finally:
        await http_client.aclose()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\n🛑 Бот остановлен.")
