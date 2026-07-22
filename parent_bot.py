import asyncio
import html
import io
import logging
import os
import re
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

# T10-10B: прямой Data API/publishable key убран. Вся связь с Supabase идёт через узкий
# server-to-server Edge Function parent-bot-api: у него свой секрет (не общий с ботом учеников),
# он проверяет parent_links на каждом чтении прогресса и отдаёт только родительские поля.
PARENT_BOT_API_URL = os.environ['PARENT_BOT_API_URL']
PARENT_BOT_API_SECRET = os.environ['PARENT_BOT_API_SECRET']

TYPE_LABELS = {'daily': '📅 Ежедневные', 'weekly': '🔥 Еженедельные', 'individual': '🎯 Индивидуальные'}

NETWORK_ERROR_TEXT = "⚠️ Сервер временно недоступен. Попробуйте ещё раз чуть позже."

# T10-10B: одна формулировка на ВСЕ неуспешные приглашения (нет такого, просрочено, уже
# использовано, подделано, битый формат) — текст не должен подсказывать, что именно не так.
INVALID_INVITE_TEXT = ("⚠️ Ссылка недействительна или уже использована. "
                       "Попроси ребёнка прислать новую ссылку из приложения.")

# Формат одноразового токена (migration 044): Telegram start-payload — [A-Za-z0-9_-] до 64 символов.
INVITE_TOKEN_RE = re.compile(r'^[A-Za-z0-9_-]{20,64}$')

logging.basicConfig(level=logging.INFO)

bot = Bot(token=API_TOKEN)
dp = Dispatcher()

# Общий асинхронный HTTP-клиент на весь процесс бота — не блокирует event loop на каждом запросе
# к Supabase, в отличие от синхронного requests. Переиспользуется между вызовами (пул соединений),
# закрывается при остановке бота (см. main()).
http_client = httpx.AsyncClient(timeout=10.0)


async def call_parent_api(action: str, **kwargs) -> dict:
    """Единая точка входа в parent-bot-api (T10-10B). Секрет уходит только в заголовок
    X-Parent-Bot-Secret — не в query/URL, не в лог. Сетевые ошибки и отказы сервера всплывают
    через raise_for_status() как httpx.HTTPError — то есть обрабатываются теми же except-ветками,
    что и раньше (NETWORK_ERROR_TEXT), поведение при недоступности сервера не меняется."""
    resp = await http_client.post(
        PARENT_BOT_API_URL,
        headers={'Content-Type': 'application/json', 'X-Parent-Bot-Secret': PARENT_BOT_API_SECRET},
        json={'action': action, **kwargs}
    )
    resp.raise_for_status()
    return resp.json().get('data', {})


async def link_parent(parent_id: int, token: str) -> dict:
    """Поглощение одноразового приглашения — единственная запись во всём боте (T10-10B).
    Принимает ТОЛЬКО токен из ссылки: telegram_id ученика в неё больше не входит, поэтому знание
    ID ребёнка доступа не даёт. Токен нигде не логируется. Повтор той же ссылки ТЕМ ЖЕ родителем
    идемпотентен; чужой, просроченный, уже использованный и битый токен неотличимы по ответу.
    Возвращает {'linked': bool, 'name': str|None}."""
    return await call_parent_api('link', parent_id=parent_id, token=token)


async def get_linked_students(parent_id: int):
    """Подключённые дети этого родителя: [{'student_id': int, 'name': str|None}].
    T10-10B: сервер отдаёт плоский список (раньше был embedded-join students(name,group_name);
    group_name нигде не отображалась и больше не запрашивается)."""
    return (await call_parent_api('linked_students', parent_id=parent_id)).get('students', [])


async def get_student_report(parent_id: int, student_id: int) -> dict:
    """Прогресс + траектория пробников (U05A/U05B) + недельный блок (W07) одним вызовом.

    T10-10B: сервер проверяет parent_links ДО чтения — родитель не может получить чужого ребёнка,
    даже подделав student_id (раньше callback_data уходил в RPC без проверки связки). Отказ —
    HTTP 403, он же httpx.HTTPError у вызывающего кода. week приходит null, если недельный блок
    недоступен: прежнее правило «сбой недели не ломает /progress» теперь держит сервер."""
    return await call_parent_api('progress', parent_id=parent_id, student_id=student_id)


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


async def send_student_progress(message: types.Message, parent_id: int, student_id: int,
                                student_name: str | None = None) -> str:
    """T10-10B: parent_id обязателен — сервер проверяет по нему связку parent_links.
    student_name необязателен: сервер возвращает имя сам (после проверки доступа).

    Возвращает статус: 'ok' | 'forbidden' (нет связки/чужой ученик) | 'network'. Сообщения об
    ошибке отправляет вызывающий — у /progress и у выбора кнопкой они разные (как и раньше)."""
    try:
        report = await get_student_report(parent_id, student_id)
    except httpx.HTTPStatusError as e:
        if e.response.status_code == 403:
            return 'forbidden'
        logging.warning(f"Не удалось загрузить прогресс {student_id}: {e}")
        return 'network'
    except httpx.HTTPError as e:
        logging.warning(f"Не удалось загрузить прогресс {student_id}: {e}")
        return 'network'

    trajectory = report.get('trajectory') or {}
    name = student_name or report.get('name') or 'Ученик'
    text = format_progress_message(name, report.get('progress') or [], trajectory)

    # Блок текущей недели (W07) — необязательное дополнение: его недоступность не должна
    # ломать старый /progress (карточка требует "старый /progress работает"). Сервер в этом
    # случае присылает week = null.
    week = report.get('week')
    if week:
        text += "\n" + format_week_block(week)

    await message.answer(text, parse_mode="HTML")

    chart = render_mock_chart(trajectory)
    if chart:
        photo = types.BufferedInputFile(chart.read(), filename="progress.png")
        await message.answer_photo(photo)

    return 'ok'


@dp.message(Command("start"))
async def cmd_start(message: types.Message):
    """Обработчик /start — обычный запуск либо переход по одноразовой ссылке-приглашению
    (/start <token>). Прежний формат /start <telegram_id ученика> больше НЕ поддерживается."""

    args = message.text.split(maxsplit=1)
    payload = args[1].strip() if len(args) > 1 else None

    if payload:
        # Битый формат (в том числе старая ссылка ?start=<telegram_id>) даёт ТОТ ЖЕ отказ, что и
        # чужой/просроченный/использованный токен — по ответу их различить нельзя.
        if not INVITE_TOKEN_RE.match(payload):
            await message.answer(INVALID_INVITE_TEXT)
            return

        try:
            result = await link_parent(message.from_user.id, payload)
        except httpx.HTTPError as e:
            # Токен в лог не попадает — только ID родителя из update.
            logging.warning(f"Не удалось обработать приглашение для родителя {message.from_user.id}: {e}")
            await message.answer(NETWORK_ERROR_TEXT)
            return

        if not result.get('linked'):
            await message.answer(INVALID_INVITE_TEXT)
            return

        await message.answer(
            f"✅ Вы успешно подключены к результатам ученика <b>{result.get('name')}</b>!\n\n"
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
        status = await send_student_progress(message, message.from_user.id, entry['student_id'],
                                             entry.get('name') or 'Ученик')
        if status != 'ok':
            await message.answer(NETWORK_ERROR_TEXT)
        return

    buttons = [
        [types.InlineKeyboardButton(
            text=e.get('name') or f"Ученик {e['student_id']}",
            callback_data=f"progress_{e['student_id']}"
        )]
        for e in linked
    ]
    kb = types.InlineKeyboardMarkup(inline_keyboard=buttons)
    await message.answer("У вас подключено несколько учеников — выберите:", reply_markup=kb)


@dp.callback_query(F.data.startswith("progress_"))
async def on_progress_pick(callback: types.CallbackQuery):
    # T10-10B: student_id из callback_data больше не даёт доступа сам по себе — сервер сверяет его
    # с parent_links по ID нажавшего родителя (callback.from_user.id, из Telegram-update).
    # Подделанный/чужой ID => 403 => та же ветка, что и «ученик не найден».
    student_id = int(callback.data.split("_", 1)[1])
    status = await send_student_progress(callback.message, callback.from_user.id, student_id)

    if status == 'forbidden':
        await callback.answer("Ученик не найден", show_alert=True)
        return
    if status == 'network':
        await callback.answer("Сервер временно недоступен, попробуйте ещё раз", show_alert=True)
        return

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
