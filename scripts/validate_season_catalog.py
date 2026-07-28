#!/usr/bin/env python3
"""Strict offline validator for the 2026–2027 Cosmic Academy catalog."""

from __future__ import annotations

import json
import re
import sys
from collections import Counter, defaultdict
from datetime import datetime
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
CATALOG_PATH = ROOT / "data" / "season_presets_2026_2027.json"
AVATAR_DIR = ROOT / "assets" / "season-avatars"
CSS_PATH = ROOT / "styles" / "season-cosmetics-preview.css"
PREVIEW_PATH = ROOT / "dev" / "season-catalog-preview.html"
CONTENT_DOC_PATH = ROOT / "docs" / "SEASON_V2_CONTENT_CATALOG.md"
VISUAL_DOC_PATH = ROOT / "docs" / "SEASON_V2_VISUAL_GUIDE.md"

ROOT_FIELDS = {
    "catalog_version",
    "academic_year",
    "timezone",
    "generated_at",
    "currency",
    "cadence",
    "price_profile",
    "rarity_rotation",
    "collections",
    "presets",
}
CADENCE_FIELDS = {"regular_days", "summer_interseason_months"}
PRICE_PROFILE_FIELDS = {"currency", "regular", "summer_provisional", "collection_bonus"}
PRICE_TIER_FIELDS = {"common", "rare", "epic", "legendary"}
ROTATION_FIELDS = {"cycle_length", "by_sequence_mod_4"}
COLLECTION_FIELDS = {
    "sequence",
    "preset_id",
    "bundle_id",
    "collection_id",
    "completion_bonus",
}
PRESET_FIELDS = {
    "preset_id",
    "sequence",
    "bundle_id",
    "collection_id",
    "name",
    "description",
    "theme_key",
    "schedule_type",
    "recommended_duration",
    "pricing_status",
    "badge_key",
    "avatar_key",
    "palette",
    "flagship_item_code",
    "collection_total_target",
    "items",
}
ITEM_REQUIRED_FIELDS = {
    "item_code",
    "slot",
    "item_kind",
    "name",
    "description",
    "rarity",
    "price",
    "currency",
    "availability",
    "asset_key",
    "render_payload",
    "sort_order",
    "is_active",
}
ITEM_OPTIONAL_FIELDS = {"title_visual_tier", "title_icon_hint"}

SLOTS = ("avatar", "frame", "title", "background")
RARITIES = ("common", "rare", "epic", "legendary")
SNAKE_RE = re.compile(r"^[a-z][a-z0-9]*(?:_[a-z0-9]+)*$")
HEX_RE = re.compile(r"^#[0-9A-F]{6}$")
YEAR_RE = re.compile(r"^\d{4}-\d{4}$")


class Validation:
    def __init__(self) -> None:
        self.errors: list[str] = []

    def require(self, condition: bool, message: str) -> None:
        if not condition:
            self.errors.append(message)

    def exact_keys(self, value: Any, expected: set[str], path: str) -> None:
        if not isinstance(value, dict):
            self.errors.append(f"{path}: ожидался объект")
            return
        actual = set(value)
        unknown = actual - expected
        missing = expected - actual
        if unknown:
            self.errors.append(f"{path}: неизвестные поля: {', '.join(sorted(unknown))}")
        if missing:
            self.errors.append(f"{path}: отсутствуют поля: {', '.join(sorted(missing))}")

    def snake(self, value: Any, path: str) -> None:
        self.require(
            isinstance(value, str) and bool(SNAKE_RE.fullmatch(value)),
            f"{path}: нужен ASCII snake_case",
        )


def load_catalog(check: Validation) -> dict[str, Any]:
    try:
        raw = CATALOG_PATH.read_text(encoding="utf-8")
    except OSError as exc:
        check.errors.append(f"catalog: не удалось прочитать {CATALOG_PATH}: {exc}")
        return {}
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError as exc:
        check.errors.append(f"catalog: некорректный JSON: {exc}")
        return {}
    if not isinstance(parsed, dict):
        check.errors.append("catalog: корень JSON должен быть объектом")
        return {}
    return parsed


def css_class_from_payload(payload: str) -> str:
    if payload.startswith("season_frame_"):
        prefix = "season-frame-"
        tail = payload.removeprefix("season_frame_")
    elif payload.startswith("season_bg_"):
        prefix = "season-bg-"
        tail = payload.removeprefix("season_bg_")
    else:
        return ""
    return prefix + tail.replace("_", "-")


def validate_structure(catalog: dict[str, Any], check: Validation) -> None:
    check.exact_keys(catalog, ROOT_FIELDS, "catalog")
    if check.errors and not catalog:
        return

    check.require(catalog.get("catalog_version") == "2.0.0", "catalog.catalog_version: ожидалось 2.0.0")
    check.require(
        isinstance(catalog.get("academic_year"), str)
        and bool(YEAR_RE.fullmatch(catalog["academic_year"])),
        "catalog.academic_year: ожидался формат YYYY-YYYY",
    )
    check.require(catalog.get("timezone") == "Europe/Moscow", "catalog.timezone: ожидалось Europe/Moscow")
    check.require(catalog.get("currency") == "gears", "catalog.currency: ожидалось gears")
    try:
        datetime.fromisoformat(str(catalog.get("generated_at")))
    except ValueError:
        check.errors.append("catalog.generated_at: нужна ISO-8601 дата")

    cadence = catalog.get("cadence")
    check.exact_keys(cadence, CADENCE_FIELDS, "catalog.cadence")
    if isinstance(cadence, dict):
        check.require(cadence.get("regular_days") == 14, "catalog.cadence.regular_days: ожидалось 14")
        check.require(
            cadence.get("summer_interseason_months") == ["july", "august"],
            "catalog.cadence.summer_interseason_months: ожидались july, august",
        )

    price_profile = catalog.get("price_profile")
    check.exact_keys(price_profile, PRICE_PROFILE_FIELDS, "catalog.price_profile")
    if isinstance(price_profile, dict):
        check.require(price_profile.get("currency") == "gears", "price_profile.currency: ожидалось gears")
        check.require(price_profile.get("collection_bonus") == 50, "price_profile.collection_bonus: ожидалось 50")
        for key, expected in (
            ("regular", {"common": 100, "rare": 140, "epic": 180, "legendary": 320}),
            ("summer_provisional", {"common": 90, "rare": 130, "epic": 170, "legendary": 300}),
        ):
            tiers = price_profile.get(key)
            check.exact_keys(tiers, PRICE_TIER_FIELDS, f"price_profile.{key}")
            check.require(tiers == expected, f"price_profile.{key}: профиль цен изменён")

    rotation = catalog.get("rarity_rotation")
    check.exact_keys(rotation, ROTATION_FIELDS, "catalog.rarity_rotation")
    expected_rotation = {
        "1": {"avatar": "legendary", "frame": "rare", "title": "common", "background": "epic"},
        "2": {"avatar": "rare", "frame": "common", "title": "epic", "background": "legendary"},
        "3": {"avatar": "common", "frame": "epic", "title": "legendary", "background": "rare"},
        "0": {"avatar": "epic", "frame": "legendary", "title": "rare", "background": "common"},
    }
    if isinstance(rotation, dict):
        check.require(rotation.get("cycle_length") == 4, "rarity_rotation.cycle_length: ожидалось 4")
        check.require(
            rotation.get("by_sequence_mod_4") == expected_rotation,
            "rarity_rotation.by_sequence_mod_4: схема ротации изменена",
        )


def validate_collections(catalog: dict[str, Any], check: Validation) -> dict[int, dict[str, Any]]:
    rows = catalog.get("collections")
    check.require(isinstance(rows, list), "catalog.collections: ожидался массив")
    if not isinstance(rows, list):
        return {}
    check.require(len(rows) == 23, f"catalog.collections: ожидалось 23, получено {len(rows)}")
    by_sequence: dict[int, dict[str, Any]] = {}
    ids: list[str] = []
    for index, row in enumerate(rows):
        path = f"collections[{index}]"
        check.exact_keys(row, COLLECTION_FIELDS, path)
        if not isinstance(row, dict):
            continue
        sequence = row.get("sequence")
        check.require(isinstance(sequence, int), f"{path}.sequence: ожидалось целое число")
        if isinstance(sequence, int):
            check.require(sequence not in by_sequence, f"{path}.sequence: дубль {sequence}")
            by_sequence[sequence] = row
        for key in ("preset_id", "bundle_id", "collection_id"):
            check.snake(row.get(key), f"{path}.{key}")
        if isinstance(row.get("collection_id"), str):
            ids.append(row["collection_id"])
        check.require(row.get("completion_bonus") == 50, f"{path}.completion_bonus: ожидалось 50")
    check.require(set(by_sequence) == set(range(1, 24)), "collections.sequence: нужна непрерывная последовательность 1..23")
    check.require(len(ids) == len(set(ids)), "collections.collection_id: найдены дубли")
    return by_sequence


def validate_presets(
    catalog: dict[str, Any],
    collection_by_sequence: dict[int, dict[str, Any]],
    check: Validation,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    presets = catalog.get("presets")
    check.require(isinstance(presets, list), "catalog.presets: ожидался массив")
    if not isinstance(presets, list):
        return [], []
    check.require(len(presets) == 23, f"catalog.presets: ожидалось 23, получено {len(presets)}")

    all_items: list[dict[str, Any]] = []
    ids: defaultdict[str, list[str]] = defaultdict(list)
    schedule_counts: Counter[str] = Counter()
    price_profile = catalog.get("price_profile", {})
    rarity_rotation = catalog.get("rarity_rotation", {}).get("by_sequence_mod_4", {})

    for index, preset in enumerate(presets):
        path = f"presets[{index}]"
        check.exact_keys(preset, PRESET_FIELDS, path)
        if not isinstance(preset, dict):
            continue
        sequence = preset.get("sequence")
        check.require(sequence == index + 1, f"{path}.sequence: ожидалось {index + 1}")
        for key in ("preset_id", "bundle_id", "collection_id", "theme_key", "badge_key", "avatar_key", "flagship_item_code"):
            check.snake(preset.get(key), f"{path}.{key}")
            if isinstance(preset.get(key), str):
                ids[key].append(preset[key])

        for key in ("name", "description"):
            check.require(
                isinstance(preset.get(key), str) and bool(preset[key].strip()),
                f"{path}.{key}: требуется непустая строка",
            )

        schedule_type = preset.get("schedule_type")
        schedule_counts[str(schedule_type)] += 1
        is_summer = schedule_type == "summer_interseason"
        check.require(schedule_type in {"regular", "summer_interseason"}, f"{path}.schedule_type: неизвестное значение")
        check.require(
            preset.get("recommended_duration") == (31 if is_summer else 14),
            f"{path}.recommended_duration: неверная длительность",
        )
        check.require(
            preset.get("pricing_status") == ("provisional" if is_summer else "recommended"),
            f"{path}.pricing_status: неверный статус",
        )
        expected_total = 690 if is_summer else 740
        check.require(
            preset.get("collection_total_target") == expected_total,
            f"{path}.collection_total_target: ожидалось {expected_total}",
        )

        palette = preset.get("palette")
        check.require(isinstance(palette, list) and len(palette) >= 5, f"{path}.palette: нужно не меньше 5 цветов")
        if isinstance(palette, list):
            check.require(len(palette) == len(set(palette)), f"{path}.palette: цвета должны различаться")
            for color_index, color in enumerate(palette):
                check.require(
                    isinstance(color, str) and bool(HEX_RE.fullmatch(color)),
                    f"{path}.palette[{color_index}]: нужен HEX #RRGGBB в верхнем регистре",
                )

        collection_row = collection_by_sequence.get(sequence) if isinstance(sequence, int) else None
        if collection_row:
            for key in ("preset_id", "bundle_id", "collection_id"):
                check.require(
                    preset.get(key) == collection_row.get(key),
                    f"{path}.{key}: не совпадает с collections[{sequence}]",
                )

        items = preset.get("items")
        check.require(isinstance(items, list), f"{path}.items: ожидался массив")
        if not isinstance(items, list):
            continue
        check.require(len(items) == 4, f"{path}.items: ожидалось 4, получено {len(items)}")
        slot_counter = Counter(item.get("slot") for item in items if isinstance(item, dict))
        check.require(
            slot_counter == Counter({slot: 1 for slot in SLOTS}),
            f"{path}.items: нужен ровно один предмет каждого слота",
        )
        rarity_counter = Counter(item.get("rarity") for item in items if isinstance(item, dict))
        check.require(
            rarity_counter == Counter({rarity: 1 for rarity in RARITIES}),
            f"{path}.items: нужны четыре разные редкости",
        )

        expected_rarities = rarity_rotation.get(str(sequence % 4)) if isinstance(sequence, int) else None
        price_key = "summer_provisional" if is_summer else "regular"
        expected_prices = price_profile.get(price_key, {}) if isinstance(price_profile, dict) else {}
        total = 0
        flagship_count = 0

        for item_index, item in enumerate(items):
            item_path = f"{path}.items[{item_index}]"
            if not isinstance(item, dict):
                check.errors.append(f"{item_path}: ожидался объект")
                continue
            actual_fields = set(item)
            unknown = actual_fields - ITEM_REQUIRED_FIELDS - ITEM_OPTIONAL_FIELDS
            missing = ITEM_REQUIRED_FIELDS - actual_fields
            if unknown:
                check.errors.append(f"{item_path}: неизвестные поля: {', '.join(sorted(unknown))}")
            if missing:
                check.errors.append(f"{item_path}: отсутствуют поля: {', '.join(sorted(missing))}")

            for key in ("item_code", "asset_key", "render_payload"):
                check.snake(item.get(key), f"{item_path}.{key}")
                if isinstance(item.get(key), str):
                    ids[key].append(item[key])
            for key in ("name", "description"):
                check.require(
                    isinstance(item.get(key), str) and bool(item[key].strip()),
                    f"{item_path}.{key}: требуется непустая строка",
                )
                if key == "name" and isinstance(item.get(key), str):
                    ids["item_name"].append(item[key])

            slot = item.get("slot")
            rarity = item.get("rarity")
            check.require(slot in SLOTS, f"{item_path}.slot: неизвестный слот")
            check.require(rarity in RARITIES, f"{item_path}.rarity: неизвестная редкость")
            if isinstance(expected_rarities, dict) and slot in SLOTS:
                check.require(
                    rarity == expected_rarities.get(slot),
                    f"{item_path}.rarity: нарушена ротация для sequence={sequence}, slot={slot}",
                )
            check.require(item.get("item_kind") == "cosmetic", f"{item_path}.item_kind: ожидалось cosmetic")
            check.require(item.get("currency") == "gears", f"{item_path}.currency: ожидалось gears")
            check.require(item.get("availability") == "rotation", f"{item_path}.availability: ожидалось rotation")
            check.require(item.get("is_active") is True, f"{item_path}.is_active: ожидалось true")
            check.require(item.get("sort_order") == (item_index + 1) * 10, f"{item_path}.sort_order: неверный порядок")
            if rarity in expected_prices:
                check.require(
                    item.get("price") == expected_prices[rarity],
                    f"{item_path}.price: для {rarity} ожидалось {expected_prices[rarity]}",
                )
            if isinstance(item.get("price"), int):
                total += item["price"]

            if slot == "title":
                check.require(
                    ITEM_OPTIONAL_FIELDS <= actual_fields,
                    f"{item_path}: у title нужны title_visual_tier и title_icon_hint",
                )
                check.snake(item.get("title_visual_tier"), f"{item_path}.title_visual_tier")
                check.snake(item.get("title_icon_hint"), f"{item_path}.title_icon_hint")
            else:
                check.require(
                    not (actual_fields & ITEM_OPTIONAL_FIELDS),
                    f"{item_path}: title-поля разрешены только слоту title",
                )

            if item.get("item_code") == preset.get("flagship_item_code"):
                flagship_count += 1
                check.require(rarity == "legendary", f"{item_path}: flagship должен быть legendary")

            all_items.append(item)

        check.require(total == expected_total, f"{path}.items: сумма цен {total}, ожидалось {expected_total}")
        check.require(flagship_count == 1, f"{path}.flagship_item_code: должен указывать ровно на один предмет")
        avatar_items = [item for item in items if isinstance(item, dict) and item.get("slot") == "avatar"]
        if avatar_items:
            check.require(
                preset.get("avatar_key") == avatar_items[0].get("asset_key"),
                f"{path}.avatar_key: не совпадает с avatar asset_key",
            )

    check.require(
        [preset.get("sequence") for preset in presets if isinstance(preset, dict)] == list(range(1, 24)),
        "presets.sequence: нужна непрерывная последовательность 1..23",
    )
    check.require(schedule_counts == Counter({"regular": 21, "summer_interseason": 2}), "presets: нужно 21 regular и 2 summer_interseason")
    if len(presets) >= 23:
        check.require(presets[21].get("name") == "Летнее межсезонье I — июль", "preset 22: неверное рабочее название")
        check.require(presets[22].get("name") == "Летнее межсезонье II — август", "preset 23: неверное рабочее название")

    for key, values in ids.items():
        duplicates = sorted(name for name, count in Counter(values).items() if count > 1)
        check.require(not duplicates, f"{key}: найдены дубли: {', '.join(duplicates)}")
    return presets, all_items


def validate_counts(presets: list[dict[str, Any]], items: list[dict[str, Any]], check: Validation) -> None:
    slot_counts = Counter(item.get("slot") for item in items)
    rarity_counts = Counter(item.get("rarity") for item in items)
    check.require(len(items) == 92, f"items: ожидалось 92, получено {len(items)}")
    check.require(
        slot_counts == Counter({slot: 23 for slot in SLOTS}),
        f"items: распределение слотов неверно: {dict(slot_counts)}",
    )
    expected_rarity_totals = {"common": 23, "rare": 23, "epic": 23, "legendary": 23}
    check.require(dict(rarity_counts) == expected_rarity_totals, f"items: распределение редкостей неверно: {dict(rarity_counts)}")

    matrix: dict[str, Counter[str]] = {slot: Counter() for slot in SLOTS}
    for item in items:
        if item.get("slot") in matrix:
            matrix[item["slot"]][item.get("rarity")] += 1
    expected_matrix = {
        "avatar": {"common": 6, "rare": 6, "epic": 5, "legendary": 6},
        "frame": {"common": 6, "rare": 6, "epic": 6, "legendary": 5},
        "title": {"common": 6, "rare": 5, "epic": 6, "legendary": 6},
        "background": {"common": 5, "rare": 6, "epic": 6, "legendary": 6},
    }
    for slot, expected in expected_matrix.items():
        check.require(dict(matrix[slot]) == expected, f"rarity matrix {slot}: {dict(matrix[slot])}, ожидалось {expected}")

    unique_theme_keys = {preset.get("theme_key") for preset in presets}
    check.require(len(unique_theme_keys) == 23, "presets.theme_key: ожидалось 23 уникальных значения")


def validate_assets_and_preview(items: list[dict[str, Any]], check: Validation) -> None:
    avatar_items = [item for item in items if item.get("slot") == "avatar"]
    expected_avatar_files = {f"{item.get('asset_key')}.svg" for item in avatar_items}
    actual_avatar_files = {path.name for path in AVATAR_DIR.glob("*.svg")} if AVATAR_DIR.exists() else set()
    check.require(
        actual_avatar_files == expected_avatar_files,
        "assets/season-avatars: набор SVG не совпадает с 23 avatar asset_key",
    )
    for filename in sorted(expected_avatar_files & actual_avatar_files):
        path = AVATAR_DIR / filename
        try:
            svg = path.read_text(encoding="utf-8")
        except OSError as exc:
            check.errors.append(f"{path}: не удалось прочитать SVG: {exc}")
            continue
        check.require("<svg" in svg and 'viewBox="0 0 512 512"' in svg, f"{path}: нужен SVG viewBox 0 0 512 512")
        check.require("<title>" in svg and "<desc>" in svg, f"{path}: нужны доступные title и desc")

    try:
        css = CSS_PATH.read_text(encoding="utf-8")
    except OSError as exc:
        check.errors.append(f"styles: не удалось прочитать {CSS_PATH}: {exc}")
        css = ""
    for item in items:
        slot = item.get("slot")
        if slot not in {"frame", "background"}:
            continue
        payload = item.get("render_payload")
        if not isinstance(payload, str):
            continue
        class_name = css_class_from_payload(payload)
        check.require(
            bool(class_name) and f".{class_name}" in css,
            f"styles: нет selector .{class_name} для {item.get('item_code')}",
        )
        if slot == "background":
            check.require(
                f'html[data-ca-theme="light"] .{class_name}' in css,
                f"styles: нет light selector для .{class_name}",
            )
            check.require(
                f'html[data-ca-theme="dark"] .{class_name}' in css,
                f"styles: нет dark selector для .{class_name}",
            )

    try:
        preview = PREVIEW_PATH.read_text(encoding="utf-8")
    except OSError as exc:
        check.errors.append(f"preview: не удалось прочитать {PREVIEW_PATH}: {exc}")
        preview = ""
    for marker in (
        "../styles/student.css",
        "../styles/season-cosmetics-preview.css",
        "../data/season_presets_2026_2027.json",
        "themeToggle",
        "seasonFilter",
        "rarityFilter",
        "previewModal",
    ):
        check.require(marker in preview, f"preview: отсутствует обязательный marker {marker}")

    for doc_path in (CONTENT_DOC_PATH, VISUAL_DOC_PATH):
        check.require(doc_path.is_file(), f"docs: отсутствует {doc_path.name}")


def print_summary(presets: list[dict[str, Any]], items: list[dict[str, Any]]) -> None:
    slot_counts = Counter(item.get("slot") for item in items)
    schedule_counts = Counter(preset.get("schedule_type") for preset in presets)
    matrix: dict[str, Counter[str]] = {slot: Counter() for slot in SLOTS}
    for item in items:
        slot = item.get("slot")
        rarity = item.get("rarity")
        if slot in matrix:
            matrix[slot][rarity] += 1

    print(f"OK: presets={len(presets)}, collections={len(presets)}, items={len(items)}")
    print(
        "Schedules: "
        f"regular={schedule_counts['regular']}, "
        f"summer_interseason={schedule_counts['summer_interseason']}"
    )
    print("Slots: " + ", ".join(f"{slot}={slot_counts[slot]}" for slot in SLOTS))
    print("Rarity distribution by slot:")
    print("slot        common  rare  epic  legendary")
    for slot in SLOTS:
        print(
            f"{slot:<10}"
            f"{matrix[slot]['common']:>7}"
            f"{matrix[slot]['rare']:>6}"
            f"{matrix[slot]['epic']:>6}"
            f"{matrix[slot]['legendary']:>11}"
        )


def main() -> int:
    check = Validation()
    catalog = load_catalog(check)
    if catalog:
        validate_structure(catalog, check)
        collection_by_sequence = validate_collections(catalog, check)
        presets, items = validate_presets(catalog, collection_by_sequence, check)
        validate_counts(presets, items, check)
        validate_assets_and_preview(items, check)
    else:
        presets, items = [], []

    if check.errors:
        print(f"FAILED: {len(check.errors)} error(s)", file=sys.stderr)
        for error in check.errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    print_summary(presets, items)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
