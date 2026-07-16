import asyncio
import html
import io
import logging
import os
import sys
from datetime import date, datetime, timedelta, timezone

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


# --- Текущая неделя (W07): дополняет lifetime-статистику отдельным блоком поверх контракта
# W04 (SPEC_STAGE2_5.md §10). Только чтение assignments/weekly_shield_uses — recalc_student_week
# не вызывается, потому что это RPC с записью (insert/update student_week_results), а карточка
# требует "только чтение Supabase, без начислений и обновлений". N/A/S/E и статус дня поэтому
# считаются здесь напрямую по тем же полям и по той же логике, что recalc_student_week (012,
# исправлено 014) — без кэша: работает и когда student_week_results для этой недели ещё нет
# (ученик не открывал Mini App, учитель ещё не проверял ничего на этой неделе).
MSK_OFFSET = timedelta(hours=3)  # МСК = UTC+3 круглый год (тот же принцип, что в index.html/teacher.html)

WEEK_DAY_NAMES_RU = ['понедельник', 'вторник', 'среда', 'четверг', 'пятница', 'суббота', 'воскресенье']


def now_msk() -> datetime:
    return datetime.now(timezone.utc) + MSK_OFFSET


def parse_ts(ts: str | None) -> datetime | None:
    if not ts:
        return None
    try:
        return datetime.fromisoformat(ts.replace('Z', '+00:00'))
    except (ValueError, AttributeError):
        return None


def msk_date_of(ts: str | None) -> date | None:
    dt = parse_ts(ts)
    if dt is None:
        return None
    return (dt.astimezone(timezone.utc) + MSK_OFFSET).date()


def week_start_of(d: date) -> date:
    return d - timedelta(days=d.isoweekday() - 1)


def is_on_time(a: dict) -> bool:
    """Первая отправка строго в свой scheduled_date по МСК — та же строгая проверка, что
    is_first_submission_on_time в БД после корректирующей миграции 014 (было <=, стало =)."""
    ts = a.get('first_submitted_at') or a.get('submitted_at')
    d = msk_date_of(ts)
    scheduled = a.get('scheduled_date')
    return d is not None and scheduled is not None and d.isoformat() == scheduled


def counts_toward_a(a: dict) -> bool:
    """Тот же составной критерий, что recalc_student_week использует и для A, и для pending
    (014): вовремя отправлена, и если была пересдача — текущая попытка попала в действовавшее
    окно исправления."""
    if not is_on_time(a):
        return False
    if not (a.get('revision_count') or 0):
        return True
    deadline = parse_ts(a.get('revision_deadline_at'))
    submitted = parse_ts(a.get('submitted_at'))
    return deadline is not None and submitted is not None and submitted <= deadline


def daily_day_status(a: dict | None, shielded: bool, today: date, now: datetime) -> str:
    """Статус дня — производная уже существующих полей, тот же принцип, что isAssignmentAvailable
    в index.html (W03) и просрочка в teacher.html (W05): щит показывается отдельно от реальной
    сдачи (SPEC §10), новое право не изобретается."""
    if shielded:
        return 'shielded'
    if not a:
        return 'none'
    status, approval = a.get('status'), a.get('approval_status')
    if status == 'checked' and approval == 'approved':
        return 'approved'
    if status == 'checked' and approval == 'rejected':
        deadline = parse_ts(a.get('revision_deadline_at'))
        return 'revision' if (deadline and deadline > now) else 'missed'
    if status == 'submitted':
        return 'submitted'
    if status == 'assigned':
        scheduled = a.get('scheduled_date')
        return 'missed' if (scheduled and scheduled < today.isoformat()) else 'assigned'
    return 'none'


def classify_week(n: int, e: int, pending: bool, awaiting: bool) -> str:
    """Термины SPEC §3: успешная (N>=4 и E>=4), слабая (N>=4 и E<=3), нейтральная (N<4).
    Pending/awaiting — отдельное состояние поверх классификации, т.к. итог ещё не окончательный."""
    if pending or awaiting:
        return 'pending'
    if n < 4:
        return 'neutral'
    return 'successful' if e >= 4 else 'weak'


async def get_week_daily(student_id: int, week_start: date, week_end: date) -> list[dict]:
    resp = await http_client.get(
        f'{SUPABASE_URL}/rest/v1/assignments',
        headers=SUPABASE_HEADERS,
        params={
            'student_id': f'eq.{student_id}', 'type': 'eq.daily',
            'scheduled_date': [f'gte.{week_start.isoformat()}', f'lte.{week_end.isoformat()}'],
            'select': 'id,title,scheduled_date,status,approval_status,revision_deadline_at,'
                      'first_submitted_at,submitted_at,revision_count',
            'order': 'scheduled_date.asc'
        }
    )
    resp.raise_for_status()
    return resp.json()


async def get_week_shields(student_id: int, week_start: date) -> list[dict]:
    resp = await http_client.get(
        f'{SUPABASE_URL}/rest/v1/weekly_shield_uses',
        headers=SUPABASE_HEADERS,
        params={
            'student_id': f'eq.{student_id}', 'week_start': f'eq.{week_start.isoformat()}',
            'status': 'in.(requested,consumed)', 'select': 'assignment_id,status'
        }
    )
    resp.raise_for_status()
    return resp.json()


async def get_week_weekly_item(student_id: int, week_start: date) -> dict | None:
    resp = await http_client.get(
        f'{SUPABASE_URL}/rest/v1/assignments',
        headers=SUPABASE_HEADERS,
        params={
            'student_id': f'eq.{student_id}', 'type': 'eq.weekly',
            'week_label': f'eq.{week_start.isoformat()}',
            'select': 'title,status,approval_status'
        }
    )
    resp.raise_for_status()
    rows = resp.json()
    return rows[0] if rows else None


WEEKLY_ITEM_LABELS = {
    'none': 'не назначено', 'assigned': 'назначено', 'submitted': 'отправлено',
    'approved': 'принято', 'rejected': 'возвращено'
}


def weekly_item_status(row: dict | None) -> str:
    if not row:
        return 'none'
    status = row.get('status')
    if status == 'assigned':
        return 'assigned'
    if status == 'submitted':
        return 'submitted'
    if status == 'checked':
        return 'approved' if row.get('approval_status') == 'approved' else 'rejected'
    return 'none'


def format_week_block(daily_rows: list[dict], shield_rows: list[dict], weekly_row: dict | None,
                       week_start: date, week_end: date) -> str:
    now = now_msk()
    today = now.date()
    shielded_ids = {s['assignment_id'] for s in shield_rows}

    n = len(daily_rows)
    a = sum(1 for r in daily_rows if r.get('status') == 'checked'
            and r.get('approval_status') == 'approved' and counts_toward_a(r))
    pending = any(r.get('status') == 'submitted' and counts_toward_a(r) for r in daily_rows)
    awaiting = any(
        r.get('status') == 'checked' and r.get('approval_status') == 'rejected'
        and (dl := parse_ts(r.get('revision_deadline_at'))) is not None and dl > now
        for r in daily_rows
    )
    s = len(shield_rows)
    e = min(n, a + s, 7)
    status = classify_week(n, e, pending, awaiting)

    lines = [f"\n🗓️ <b>Текущая неделя</b> ({week_start.strftime('%d.%m')}–{week_end.strftime('%d.%m')}):"]
    lines.append(f"Ежедневные: {a} из {n} принято" + (f", 🛡 щитов: {s}" if s else "")
                 + f" → эффективно {e}")

    weekly_status = weekly_item_status(weekly_row)
    weekly_label = WEEKLY_ITEM_LABELS[weekly_status]
    if weekly_row and weekly_row.get('title'):
        lines.append(f"🔥 Еженедельное: {weekly_label} — «{html.escape(weekly_row['title'])}»")
    else:
        lines.append(f"🔥 Еженедельное: {weekly_label}")

    revisions = [
        r for r in daily_rows
        if daily_day_status(r, r['id'] in shielded_ids, today, now) == 'revision'
    ]
    if revisions:
        lines.append("✏️ Открытые исправления:")
        for r in revisions:
            dl = parse_ts(r['revision_deadline_at'])
            dl_text = (dl + MSK_OFFSET).strftime('%d.%m %H:%M') if dl else '—'
            title = html.escape(r.get('title') or 'Без названия')
            lines.append(f"  • «{title}» — до {dl_text} МСК")

    # Pending/awaiting — нейтральная формулировка без обвинения ученика (карточка W07).
    status_text = {
        'pending': "⏳ Итог недели пока уточняется: есть работа на проверке у учителя или "
                   "открытое окно для исправления.",
        'successful': "✅ Неделя засчитывается как успешная.",
        'weak': "Выполнено меньше половины назначенного на неделю — неделя слабая, без награды.",
        'neutral': "➖ На этой неделе назначено меньше 4 ежедневных заданий — неделя нейтральная, "
                   "не засчитывается ни в плюс, ни в минус.",
    }[status]
    lines.append(status_text)

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


def format_progress_message(student_name: str, progress_rows: list, exams: list) -> str:
    progress_by_type = {row['type']: row for row in progress_rows}
    lines = [f"📊 Результаты ученика <b>{student_name}</b>:\n"]
    for key, label in TYPE_LABELS.items():
        row = progress_by_type.get(key, {'issued': 0, 'completed': 0})
        lines.append(f"{label}: {row['completed']} из {row['issued']} выполнено")

    if exams:
        lines.append("\n🧮 Пробники:")
        for i, exam in enumerate(exams, 1):
            date_str = format_exam_date(exam)
            lines.append(f"№{i} «{exam['exam_name']}» — {exam['score']} баллов ({date_str})")
    else:
        lines.append("\n🧮 Пробников пока нет.")

    return "\n".join(lines)


def render_mock_chart(exams: list):
    """Рисует график результатов пробников в PNG — так же, как график на экране профиля в Mini App:
    ось X — порядковый номер («№1», «№2»...), название пробника и дата синхронизации уходят в текст сообщения."""
    if not exams:
        return None

    labels = [f'№{i + 1}' for i in range(len(exams))]
    scores = [float(e['score']) for e in exams]

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
        exams = await get_mock_exams(student_id)
    except httpx.HTTPError as e:
        logging.warning(f"Не удалось загрузить прогресс {student_id}: {e}")
        await message.answer(NETWORK_ERROR_TEXT)
        return

    text = format_progress_message(student_name, progress, exams)

    # Блок текущей недели (W07) — необязательное дополнение: сбой её загрузки не должен
    # ломать старый /progress (карточка требует "старый /progress работает").
    try:
        week_start = week_start_of(now_msk().date())
        week_end = week_start + timedelta(days=6)
        daily_rows, shield_rows, weekly_row = await asyncio.gather(
            get_week_daily(student_id, week_start, week_end),
            get_week_shields(student_id, week_start),
            get_week_weekly_item(student_id, week_start)
        )
        text += "\n" + format_week_block(daily_rows, shield_rows, weekly_row, week_start, week_end)
    except httpx.HTTPError as e:
        logging.warning(f"Не удалось загрузить недельный блок {student_id}: {e}")

    await message.answer(text, parse_mode="HTML")

    chart = render_mock_chart(exams)
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
