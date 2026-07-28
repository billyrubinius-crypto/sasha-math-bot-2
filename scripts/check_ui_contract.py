#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Контрактный чек ученического Mini App (Cosmic Academy, этап 1, исправляющий проход).

Проверяет четыре инварианта связки index.html <-> js/student-*.js <-> styles/student.css,
которые в этом проекте ломаются молча (без ошибки в консоли):

  1. каждый статический getElementById('x') из js/student-*.js имеет id="x" в index.html
     (единственное разрешённое исключение — динамический exam-info-box, он создаётся
     строкой innerHTML в renderMockChart);
  2. каждая функция, вызываемая из inline-обработчика (on...="..."), объявлена в
     js/student-*.js или shared.js (все student-скрипты — classic scripts с общей
     глобальной областью, поэтому inline-обработчики зависят от объявлений верхнего уровня).
     Проверяются как статичные обработчики в index.html, так и обработчики, которые
     js/student-*.js генерирует строками (renderWeekStrip, buildLifeRow, renderMockChart и
     т.п.) — двойные и одинарные кавычки. Программные присваивания вида
     `btn.onclick = () => …` этим механизмом не распознаются и не проверяются (это не
     inline-обработчик в смысле HTML-атрибута, а обычное свойство DOM-элемента);
  3. критичные динамические CSS-классы (создаются только в рантайме) имеют правила в
     styles/student.css;
  4. составные модификаторы вида `.base.modifier` (§6 аудита) имеют правило именно в этом
     составном виде — самого базового класса недостаточно, если модификатор нигде не
     оформлен как `.base.modifier`.

Это не универсальный парсер HTML/JS, а небольшой устойчивый чек под текущий проект:
только стандартная библиотека Python 3, файлы не изменяются.

Коды выхода: 0 — все проверки прошли, 1 — есть нарушения, 2 — не найдены нужные файлы.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

INDEX = ROOT / "index.html"
CSS = ROOT / "styles" / "student.css"
SHARED = ROOT / "shared.js"
JS_DIR = ROOT / "js"

# exam-info-box рождается внутри renderMockChart (innerHTML) и читается в showExamInfo —
# в разметке его нет и быть не должно.
DYNAMIC_IDS = {"exam-info-box"}

# Имена, которые встречаются в inline-обработчиках, но функциями страницы не являются
# (ключевые слова языка и встроенные объекты браузера).
INLINE_IGNORED = {
    "if", "for", "while", "switch", "return", "typeof", "new", "delete", "void",
    "catch", "function", "alert", "confirm", "prompt", "parseInt", "parseFloat",
    "String", "Number", "Boolean", "Array", "Object", "JSON", "Math", "Date",
}

# Динамические классы, критичные для рантайма: элемент отрисуется и без правила, но без
# стилей. Список ведётся вручную (§6 аудита) и пополняется по этапам редизайна.
CRITICAL_CLASSES = [
    # неделя
    "week-day-chip", "wd-not_assigned", "wd-assigned", "wd-submitted", "wd-revision",
    "wd-approved", "wd-missed", "wd-shielded", "week-day-name", "week-day-mark",
    "week-day-detail-main", "week-day-detail-title", "week-day-detail-note",
    "week-shield-btn", "week-weekly-row", "week-totals", "week-forecast",
    # «сделать сейчас»
    "now-item", "now-icon", "now-main", "now-item-title", "now-item-meta", "now-arrow",
    "summary-empty", "ca-state", "ca-state--loading", "ca-state--empty", "ca-state--error",
    # квесты
    "quest-row", "quest-row-icon", "quest-row-main", "quest-row-title", "quest-row-meta",
    "quest-row-note", "quest-row-trailing", "quest-badge", "quest-badge-paid",
    "quest-badge-wait", "quest-badge-locked", "quest-claim-btn", "quest-replace-btn",
    # стрик и пробники
    "streak-dots", "streak-dot", "streak-note", "exam-info-box", "chart-disclaimer",
    "chart-empty",
    # истории и достижения
    "history-item", "hist-info", "hist-reason", "hist-date", "hist-amount",
    "hist-positive", "hist-negative", "ach-tile", "ach-icon", "ach-name",
    # коллекции и витрина
    "collection-block", "collection-season-title", "coll-grid", "coll-tile", "coll-tile-main",
    "coll-name", "collection-item-menu", "collection-item-action", "collection-item-state",
    "showcase-tile", "showcase-icon", "showcase-name", "showcase-picker-title",
    "showcase-chip", "showcase-chip-clear", "showcase-picker-empty",
    # магазин
    "shop-section-title", "shop-section-note", "shop-item", "shop-preview", "shop-body",
    "shop-name", "shop-desc", "shop-leaving", "shop-action", "shop-buy-btn", "shop-state",
    "shop-equip-btn", "shop-equipped", "shop-emoji-chips", "shop-emoji-chip",
    "shop-preview-name-sample", "shop-preview-avatar-demo", "shop-preview-title-demo",
    "shop-preview-title-demo-icon", "shop-preview-title-demo-bar",
    "custom-title-text", "custom-title-reason",
    # архив домашки
    "my-hw-item", "hw-header", "hw-variant", "hw-pages", "hw-date", "hw-badge",
    "badge-pending", "badge-approved", "badge-rejected", "hw-comment", "file-item",
    "has-file",
    # лидерборд и лиги
    "leaderboard-list", "lb-item", "lb-me", "lb-promote", "lb-demote", "lb-rank",
    "lb-avatar", "lb-name-wrap", "lb-name-line", "lb-title", "lb-score", "league-badge",
    "league-note", "league-standing", "league-ladder", "ladder-step",
    # заголовок когорты в полном списке лиги (создаётся только когда групп больше одной)
    "league-group-title",
    # косметика
    "nick-gold", "nick-status", "nick-crown", "avatar-img", "avatar-placeholder",
    "bg-grid", "bg-space", "bg-aurora", "bg-draft",
    "frame-notebook", "frame-winter", "frame-fire100", "frame-legend-1", "frame-legend-2",
    "frame-legend-3", "frame-legend-4", "frame-pulsar", "frame-orbit",
]

# Составные модификаторы (§6 аудита): элемент отрисуется с базовым классом, но нужного
# состояния (сегодня/выбран/раскрыт/заблокирован/…) не будет видно без правила именно в
# составном виде `.base.modifier`. Проверяются отдельно от CRITICAL_CLASSES, потому что
# наличие правила на голый `.base` не гарантирует наличие правила на `.base.modifier`.
COMPOSITE_CLASSES = [
    ("week-day-chip", "today"),
    ("week-day-chip", "selected"),
    ("week-day-detail", "open"),
    ("week-shield-btn", "apply"),
    ("week-shield-btn", "remove"),
    ("streak-dot", "filled"),
    ("ach-tile", "locked"),
    ("coll-tile", "locked"),
    ("showcase-tile", "empty"),
    ("shop-state", "owned"),
    ("shop-state", "locked"),
    ("shop-preview", "shop-preview-frame"),
    ("shop-preview", "bg-grid"),
    ("shop-preview", "bg-space"),
    ("shop-preview", "bg-aurora"),
    ("shop-preview", "bg-draft"),
    ("summary-empty", "is-error"),
    ("chart-empty", "is-error"),
    ("my-hw-item", "status-submitted"),
    ("my-hw-item", "status-checked"),
    ("ladder-step", "achieved"),
    ("ladder-step", "current"),
    ("hw-comment", "rejected"),
]

# Классы-хуки: JS использует их как селектор для поведения (querySelector/querySelectorAll),
# а не как визуальный модификатор, поэтому отдельное CSS-правило для них не обязательно и
# его отсутствие — не долг и не нарушение. Ведём список явно, чтобы это было решением, а не
# забытой проверкой.
HOOK_CLASSES_NO_CSS = {
    "life-row-trailing": "JS-хук для setLifeControlsDisabled "
                          "(querySelectorAll('.life-row-trailing button')); "
                          "визуальный класс не обязателен",
}

# Классы, которые JS создаёт уже сейчас, но стилей для них ещё нет — по плану редизайна.
# Держим их в отдельном списке, чтобы чек не падал и одновременно не забывал о долге.
# Скрипт сам проверяет, не появилось ли правило в CSS раньше срока (см. check_known_debt) —
# тогда запись помечается как устранённую, а не остаётся ложным «неисправленным долгом».
KNOWN_MISSING_CLASSES = {}


try:  # чтобы русский текст отчёта не падал на консолях с не-UTF-8 кодировкой
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:  # pragma: no cover - старые интерпретаторы/перенаправленный вывод
    pass


def read(path):
    return path.read_text(encoding="utf-8")


def rel(path):
    """Путь для отчёта: относительный к корню репозитория, если это возможно."""
    try:
        return path.resolve().relative_to(ROOT).as_posix()
    except ValueError:
        return path.as_posix()


def student_js_files():
    return sorted(JS_DIR.glob("student-*.js"))


def strip_css_comments(text):
    return re.sub(r"/\*.*?\*/", " ", text, flags=re.S)


def check_ids(index_html, js_files):
    """1. getElementById(...) -> id="..." в разметке."""
    have = set(re.findall(r"""\bid\s*=\s*["']([^"']+)["']""", index_html))
    violations = []
    for path in js_files:
        text = read(path)
        for match in re.finditer(r"""getElementById\(\s*["']([^"']+)["']\s*\)""", text):
            used = match.group(1)
            if used in have or used in DYNAMIC_IDS:
                continue
            line = text.count("\n", 0, match.start()) + 1
            violations.append(
                "{}:{}: getElementById('{}') — такого id нет в index.html".format(
                    rel(path), line, used
                )
            )
    return violations


INLINE_HANDLER_RE = re.compile(r"""\bon([a-z]+)\s*=\s*(["'])((?:(?!\2)[\s\S])*)\2""")
CALL_RE = re.compile(r"(?<![.\w$])([A-Za-z_$][\w$]*)\s*\(")


def _inline_handler_violations(label, text, declared):
    """Находит on...="..."/on...='...' в тексте (HTML или JS-шаблон) и проверяет вызовы.

    Одна и та же логика применяется и к index.html, и к строкам, которые js/student-*.js
    генерирует для renderWeekStrip/buildLifeRow/renderMockChart и т.п. — там inline-обработчики
    (onclick="selectWeekDay(${index})" и подобные) лежат внутри JS-шаблонных строк, а не в
    разметке, но ломаются молча точно так же. Присваивания вида `btn.onclick = () => …` не
    совпадают с этим паттерном (после `=` нет кавычки) и потому не считаются inline-обработчиком —
    это осознанное ограничение простого чека (§5.1: не пытаемся отличить их надёжнее регексом).
    """
    violations = []
    for match in INLINE_HANDLER_RE.finditer(text):
        event, quote, code = match.group(1), match.group(2), match.group(3)
        line = text.count("\n", 0, match.start()) + 1
        for call in CALL_RE.finditer(code):
            name = call.group(1)
            if name in INLINE_IGNORED or name in declared:
                continue
            violations.append(
                "{}:{}: on{}={}...{} вызывает {}() — функция не объявлена "
                "в js/student-*.js или shared.js".format(label, line, event, quote, quote, name)
            )
    return violations


def check_inline_handlers(index_html, js_files):
    """2. функции из inline-обработчиков (index.html и JS-шаблоны) объявлены в
    student-скриптах или shared.js."""
    declared = set()
    for path in list(js_files) + [SHARED]:
        text = read(path)
        declared.update(re.findall(r"\bfunction\s+([A-Za-z_$][\w$]*)\s*\(", text))
        # объявления вида `const foo = (...) => {}` тоже считаются
        declared.update(
            re.findall(r"\b(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*(?:async\s*)?(?:function|\()", text)
        )

    violations = list(_inline_handler_violations("index.html", index_html, declared))
    for path in js_files:
        violations.extend(_inline_handler_violations(rel(path), read(path), declared))
    return violations


def class_has_rule(cls, css):
    return bool(re.search(r"\." + re.escape(cls) + r"(?![-\w])", css))


def check_dynamic_classes(css_text):
    """3. критичные динамические классы имеют правила в styles/student.css."""
    css = strip_css_comments(css_text)
    violations = []
    for cls in CRITICAL_CLASSES:
        if not class_has_rule(cls, css):
            violations.append(
                "styles/student.css: нет правила для динамического класса .{}".format(cls)
            )
    return violations


def check_composite_classes(css_text):
    """4. составные модификаторы `.base.modifier` (§6 аудита) — правило на голом `.base`
    не гарантирует, что состояние `.base.modifier` тоже стилизовано."""
    css = strip_css_comments(css_text)
    violations = []
    for base, modifier in COMPOSITE_CLASSES:
        selector = ".{}.{}".format(base, modifier)
        if selector not in css:
            violations.append(
                "styles/student.css: нет составного правила {}".format(selector)
            )
    return violations


def check_known_debt(css_text):
    """Технический долг (KNOWN_MISSING_CLASSES), устранённый раньше срока: если правило уже
    появилось в CSS, запись должна быть убрана из словаря, а не молча продолжать числиться
    «неисправленной» — возвращаем список таких кодов для отчёта."""
    css = strip_css_comments(css_text)
    return [cls for cls in sorted(KNOWN_MISSING_CLASSES) if class_has_rule(cls, css)]


def main():
    missing_files = [p for p in [INDEX, CSS, SHARED] if not p.is_file()]
    if missing_files or not JS_DIR.is_dir():
        for p in missing_files:
            print("НЕ НАЙДЕН ФАЙЛ: {}".format(p))
        if not JS_DIR.is_dir():
            print("НЕ НАЙДЕН КАТАЛОГ: {}".format(JS_DIR))
        return 2

    js_files = student_js_files()
    if not js_files:
        print("НЕ НАЙДЕНЫ js/student-*.js")
        return 2

    index_html = read(INDEX)
    css_text = read(CSS)

    checks = [
        ("1. DOM ID из getElementById", check_ids(index_html, js_files)),
        ("2. функции inline-обработчиков (index.html + JS-шаблоны)",
         check_inline_handlers(index_html, js_files)),
        ("3. динамические CSS-классы", check_dynamic_classes(css_text)),
        ("4. составные CSS-модификаторы (.base.modifier)", check_composite_classes(css_text)),
    ]

    total = 0
    for title, violations in checks:
        if violations:
            total += len(violations)
            print("[FAIL] {} — нарушений: {}".format(title, len(violations)))
            for v in violations:
                print("       - {}".format(v))
        else:
            print("[OK]   {}".format(title))

    if HOOK_CLASSES_NO_CSS:
        print("[NOTE] классы-хуки без обязательного CSS (JS-селектор, не визуальный модификатор):")
        for cls, why in sorted(HOOK_CLASSES_NO_CSS.items()):
            print("       - .{}: {}".format(cls, why))

    resolved_debt = check_known_debt(css_text)
    if resolved_debt:
        print("[NOTE] технический долг устранён раньше срока — уберите запись из "
              "KNOWN_MISSING_CLASSES в scripts/check_ui_contract.py:")
        for cls in resolved_debt:
            print("       - .{}: {}".format(cls, KNOWN_MISSING_CLASSES[cls]))

    remaining_debt = {c: w for c, w in KNOWN_MISSING_CLASSES.items() if c not in resolved_debt}
    if remaining_debt:
        print("[NOTE] известный технический долг (не считается нарушением):")
        for cls, why in sorted(remaining_debt.items()):
            print("       - .{}: {}".format(cls, why))

    if total:
        print("\nИТОГ: нарушений {} — контракт UI не выполнен.".format(total))
        return 1

    print("\nИТОГ: контракт UI выполнен, нарушений нет.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
