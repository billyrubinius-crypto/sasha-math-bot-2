#!/usr/bin/env python3
"""Strict offline validator for the calendar-based 2026–2027 season catalog."""

from __future__ import annotations

import json
import re
import sys
from collections import Counter, defaultdict
from datetime import date
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
CATALOG_PATH = ROOT / "data" / "season_presets_2026_2027.json"
AVATAR_DIR = ROOT / "assets" / "season-avatars"
CSS_PATH = ROOT / "styles" / "season-cosmetics-preview.css"
BASE_CSS_PATH = ROOT / "styles" / "season-v3-preview.css"
PREVIEW_PATH = ROOT / "dev" / "season-catalog-preview.html"
CONTENT_DOC_PATH = ROOT / "docs" / "SEASON_V2_CONTENT_CATALOG.md"
VISUAL_DOC_PATH = ROOT / "docs" / "SEASON_V2_VISUAL_GUIDE.md"
INTEGRATION_DOC_PATH = ROOT / "docs" / "SEASON_V2_INTEGRATION_CONTRACT.md"

ROOT_FIELDS = {
    "schema_version",
    "catalog_revision",
    "catalog_code",
    "academic_year",
    "timezone",
    "calendar_policy",
    "launch_policy",
    "visual_contract",
    "regular_season_duration_days",
    "currency",
    "price_profiles",
    "rarity_rotation",
    "secret_combo",
    "presets",
}
LAUNCH_POLICY_FIELDS = {
    "activation_mode",
    "first_automatic_sequence_no",
    "first_automatic_start_date",
    "sequence_1_activation",
    "manual_activation_before_first_start",
}
VISUAL_CONTRACT_FIELDS = {
    "profile_avatar_px",
    "leaderboard_avatar_px",
    "expanded_avatar_px",
    "catalog_avatar_px",
    "frame_outset_ratio",
    "compact_motion",
    "reduced_motion",
}
SECRET_COMBO_FIELDS = {
    "combo_code",
    "reveal_after_sequence_no",
    "required_item_codes",
    "effect_key",
    "public_hint",
}
PRICE_PROFILE_FIELDS = {"regular", "summer", "collection_completion_bonus"}
PRICE_TIER_FIELDS = {"common", "rare", "epic", "legendary"}
ROTATION_FIELDS = {"cycle_length", "by_sequence_mod_4"}
PRESET_FIELDS = {
    "preset_code",
    "sequence_no",
    "competition_season_no",
    "bundle_code",
    "collection_code",
    "season_type",
    "start_date",
    "end_date",
    "duration_days",
    "suggested_name",
    "short_description",
    "theme_key",
    "economy_profile",
    "pricing_status",
    "palette",
    "primary_motif",
    "secondary_motif",
    "badge_key",
    "avatar_key",
    "flagship_slot",
    "flagship_item_code",
    "collection_total_target",
    "collection_bonus",
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
ITEM_VISUAL_FIELDS = {"visual_key", "motion_policy"}
ITEM_TITLE_FIELDS = {"title_visual_tier", "title_icon_hint"}
ITEM_OPTIONAL_FIELDS = ITEM_VISUAL_FIELDS | ITEM_TITLE_FIELDS

SLOTS = ("avatar", "frame", "title", "background")
RARITIES = ("common", "rare", "epic", "legendary")
SNAKE_RE = re.compile(r"^[a-z][a-z0-9]*(?:_[a-z0-9]+)*$")
HEX_RE = re.compile(r"^#[0-9A-F]{6}$")
EXTERNAL_URL_RE = re.compile(r"""(?:href|src)\s*=\s*["'](?:https?:)?//""", re.IGNORECASE)

REGULAR_PRICES = {"common": 60, "rare": 90, "epic": 120, "legendary": 190}
SUMMER_PRICES = {"common": 55, "rare": 80, "epic": 110, "legendary": 170}
RARITY_ROTATION = {
    "1": {"avatar": "legendary", "frame": "rare", "title": "common", "background": "epic"},
    "2": {"avatar": "rare", "frame": "common", "title": "epic", "background": "legendary"},
    "3": {"avatar": "common", "frame": "epic", "title": "legendary", "background": "rare"},
    "0": {"avatar": "epic", "frame": "legendary", "title": "rare", "background": "common"},
}
TITLE_TIER_BY_RARITY = {
    "common": "plain",
    "rare": "outlined",
    "epic": "accent",
    "legendary": "radiant",
}
CALENDAR = (
    (1, None, "interseason", "2026-07-28", "2026-08-01", 4, "Режим энергосбережения"),
    (2, None, "interseason", "2026-08-01", "2026-09-03", 33, "Нулевой заряд"),
    (3, 1, "regular", "2026-09-03", "2026-09-17", 14, "Неверный поворот"),
    (4, 2, "regular", "2026-09-17", "2026-10-01", 14, "Вне расписания"),
    (5, 3, "regular", "2026-10-01", "2026-10-15", 14, "Протокол симметрии"),
    (6, 4, "regular", "2026-10-15", "2026-10-29", 14, "Дедлайн 23:59"),
    (7, 5, "regular", "2026-10-29", "2026-11-12", 14, "Сообщение доставлено"),
    (8, 6, "regular", "2026-11-12", "2026-11-26", 14, "Ночная смена"),
    (9, 7, "regular", "2026-11-26", "2026-12-10", 14, "Холодный статик"),
    (10, 8, "regular", "2026-12-10", "2026-12-24", 14, "Ещё пять минут"),
    (11, 9, "regular", "2026-12-24", "2027-01-07", 14, "Гирлянда 00:00"),
    (12, 10, "regular", "2027-01-07", "2027-01-21", 14, "Слабая частота"),
    (13, 11, "regular", "2027-01-21", "2027-02-04", 14, "Ошибка на полях"),
    (14, 12, "regular", "2027-02-04", "2027-02-18", 14, "Восемь вкладок"),
    (15, 13, "regular", "2027-02-18", "2027-03-04", 14, "Ещё попытка"),
    (16, 14, "regular", "2027-03-04", "2027-03-18", 14, "Новый рост"),
    (17, 15, "regular", "2027-03-18", "2027-04-01", 14, "Точка равновесия"),
    (18, 16, "regular", "2027-04-01", "2027-04-15", 14, "Турист с Альфы-7"),
    (19, 17, "regular", "2027-04-15", "2027-04-29", 14, "Метод тыка"),
    (20, 18, "regular", "2027-04-29", "2027-05-13", 14, "Локальный дождь"),
    (21, 19, "regular", "2027-05-13", "2027-05-27", 14, "Вышел первым"),
    (22, 20, "regular", "2027-05-27", "2027-06-10", 14, "Загрузка 2%"),
    (23, 21, "regular", "2027-06-10", "2027-06-24", 14, "Официально свободен"),
)


class Validation:
    def __init__(self) -> None:
        self.errors: list[str] = []

    def require(self, condition: bool, message: str) -> None:
        if not condition:
            self.errors.append(message)

    def exact_keys(self, value: Any, expected: set[str], path: str) -> None:
        if not isinstance(value, dict):
            self.errors.append(f"{path}: expected object")
            return
        actual = set(value)
        if actual - expected:
            self.errors.append(f"{path}: unknown fields: {', '.join(sorted(actual - expected))}")
        if expected - actual:
            self.errors.append(f"{path}: missing fields: {', '.join(sorted(expected - actual))}")

    def snake(self, value: Any, path: str) -> None:
        self.require(
            isinstance(value, str) and bool(SNAKE_RE.fullmatch(value)),
            f"{path}: expected ASCII snake_case",
        )


def load_catalog(check: Validation) -> dict[str, Any]:
    try:
        parsed = json.loads(CATALOG_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        check.errors.append(f"catalog: cannot load valid JSON: {exc}")
        return {}
    if not isinstance(parsed, dict):
        check.errors.append("catalog: root must be an object")
        return {}
    return parsed


def approved_visual_token(item: dict[str, Any]) -> str:
    visual = str(item.get("visual_key", "")).replace("_", "-")
    slot = item.get("slot")
    if slot == "frame":
        return f"v4-{visual}"
    if slot == "background" and visual in {"snow-yard", "leaning-library", "empty-class"}:
        return f"{visual}-v4"
    return visual


def approved_css_class(item: dict[str, Any]) -> str:
    token = approved_visual_token(item)
    if item.get("slot") == "title" and token in {"plain", "pulse"}:
        return "v4-catalog-title-preview"
    return {
        "avatar": f"char-{token}",
        "frame": f"frame-{token}",
        "title": f"title-visual-{token}",
        "background": f"scene-{token}",
    }.get(str(item.get("slot")), "")


def validate_root(catalog: dict[str, Any], check: Validation) -> None:
    check.exact_keys(catalog, ROOT_FIELDS, "catalog")
    check.require(catalog.get("schema_version") == 2, "catalog.schema_version: expected 2")
    check.require(catalog.get("catalog_revision") == 5, "catalog.catalog_revision: expected approved revision 5")
    check.require(
        catalog.get("catalog_code") == "cosmic_academy_2026_2027_v2",
        "catalog.catalog_code: unexpected value",
    )
    check.require(catalog.get("academic_year") == "2026-2027", "catalog.academic_year: expected 2026-2027")
    check.require(catalog.get("timezone") == "Europe/Moscow", "catalog.timezone: expected Europe/Moscow")
    check.require(catalog.get("calendar_policy") == "fixed_2026_2027", "catalog.calendar_policy: unexpected value")
    check.require(catalog.get("regular_season_duration_days") == 14, "catalog.regular_season_duration_days: expected 14")
    check.require(catalog.get("currency") == "gears", "catalog.currency: expected gears")

    launch_policy = catalog.get("launch_policy")
    check.exact_keys(launch_policy, LAUNCH_POLICY_FIELDS, "catalog.launch_policy")
    if isinstance(launch_policy, dict):
        check.require(launch_policy.get("activation_mode") == "scheduled", "launch_policy.activation_mode: expected scheduled")
        check.require(
            launch_policy.get("first_automatic_sequence_no") == 2,
            "launch_policy.first_automatic_sequence_no: expected 2",
        )
        check.require(
            launch_policy.get("first_automatic_start_date") == "2026-08-01",
            "launch_policy.first_automatic_start_date: expected 2026-08-01",
        )
        check.require(
            launch_policy.get("sequence_1_activation") == "catalog_only",
            "launch_policy.sequence_1_activation: expected catalog_only",
        )
        check.require(
            launch_policy.get("manual_activation_before_first_start") is False,
            "launch_policy.manual_activation_before_first_start: expected false",
        )

    visual_contract = catalog.get("visual_contract")
    check.exact_keys(visual_contract, VISUAL_CONTRACT_FIELDS, "catalog.visual_contract")
    if isinstance(visual_contract, dict):
        expected_visual_contract = {
            "profile_avatar_px": 48,
            "leaderboard_avatar_px": 32,
            "expanded_avatar_px": 160,
            "catalog_avatar_px": 112,
            "frame_outset_ratio": 0.035,
            "compact_motion": "static",
            "reduced_motion": "static",
        }
        check.require(visual_contract == expected_visual_contract, "catalog.visual_contract: unexpected value")

    secret_combo = catalog.get("secret_combo")
    check.exact_keys(secret_combo, SECRET_COMBO_FIELDS, "catalog.secret_combo")
    if isinstance(secret_combo, dict):
        check.snake(secret_combo.get("combo_code"), "catalog.secret_combo.combo_code")
        check.snake(secret_combo.get("effect_key"), "catalog.secret_combo.effect_key")
        check.require(
            secret_combo.get("reveal_after_sequence_no") == 18,
            "catalog.secret_combo.reveal_after_sequence_no: expected 18",
        )
        required_codes = secret_combo.get("required_item_codes")
        check.require(
            isinstance(required_codes, list) and len(required_codes) == 4 and len(set(required_codes)) == 4,
            "catalog.secret_combo.required_item_codes: expected four unique codes",
        )
        if isinstance(required_codes, list):
            for index, item_code in enumerate(required_codes):
                check.snake(item_code, f"catalog.secret_combo.required_item_codes[{index}]")
        check.require(secret_combo.get("public_hint") is False, "catalog.secret_combo.public_hint: expected false")

    prices = catalog.get("price_profiles")
    check.exact_keys(prices, PRICE_PROFILE_FIELDS, "catalog.price_profiles")
    if isinstance(prices, dict):
        check.exact_keys(prices.get("regular"), PRICE_TIER_FIELDS, "catalog.price_profiles.regular")
        check.exact_keys(prices.get("summer"), PRICE_TIER_FIELDS, "catalog.price_profiles.summer")
        check.require(prices.get("regular") == REGULAR_PRICES, "regular price profile changed")
        check.require(prices.get("summer") == SUMMER_PRICES, "summer price profile changed")
        check.require(prices.get("collection_completion_bonus") == 50, "collection completion bonus must be 50")

    rotation = catalog.get("rarity_rotation")
    check.exact_keys(rotation, ROTATION_FIELDS, "catalog.rarity_rotation")
    if isinstance(rotation, dict):
        check.require(rotation.get("cycle_length") == 4, "rarity rotation cycle must be 4")
        check.require(rotation.get("by_sequence_mod_4") == RARITY_ROTATION, "rarity rotation map changed")


def validate_calendar(presets: list[dict[str, Any]], check: Validation) -> None:
    check.require(len(presets) == len(CALENDAR), f"presets: expected 23, got {len(presets)}")
    parsed_ranges: list[tuple[date, date]] = []
    for index, expected in enumerate(CALENDAR):
        if index >= len(presets) or not isinstance(presets[index], dict):
            continue
        sequence, competition, kind, start, end, duration, name = expected
        preset = presets[index]
        path = f"presets[{index}]"
        for key, expected_value in (
            ("sequence_no", sequence),
            ("competition_season_no", competition),
            ("season_type", kind),
            ("start_date", start),
            ("end_date", end),
            ("duration_days", duration),
            ("suggested_name", name),
        ):
            check.require(preset.get(key) == expected_value, f"{path}.{key}: expected {expected_value!r}")
        try:
            start_date = date.fromisoformat(str(preset.get("start_date")))
            end_date = date.fromisoformat(str(preset.get("end_date")))
        except ValueError:
            check.errors.append(f"{path}: invalid ISO calendar date")
            continue
        check.require((end_date - start_date).days == duration, f"{path}: date range is not {duration} days")
        if kind == "regular":
            check.require(start_date.weekday() == 3, f"{path}.start_date: regular boundary must be Thursday")
            check.require(end_date.weekday() == 3, f"{path}.end_date: regular boundary must be Thursday")
        parsed_ranges.append((start_date, end_date))

    for index in range(len(parsed_ranges) - 1):
        check.require(
            parsed_ranges[index][1] == parsed_ranges[index + 1][0],
            f"calendar: gap or overlap between sequences {index + 1} and {index + 2}",
        )
    if len(parsed_ranges) == 23:
        check.require(parsed_ranges[2][0].isoformat() == "2026-09-03", "regular calendar must start on 2026-09-03")
        check.require(parsed_ranges[-1][1].isoformat() == "2027-06-24", "regular calendar must end on 2027-06-24")


def validate_presets(catalog: dict[str, Any], check: Validation) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    presets = catalog.get("presets")
    check.require(isinstance(presets, list), "catalog.presets: expected array")
    if not isinstance(presets, list):
        return [], []
    validate_calendar(presets, check)

    prices = catalog.get("price_profiles", {})
    all_items: list[dict[str, Any]] = []
    unique_values: defaultdict[str, list[str]] = defaultdict(list)
    type_counts: Counter[str] = Counter()

    for index, preset in enumerate(presets):
        path = f"presets[{index}]"
        check.exact_keys(preset, PRESET_FIELDS, path)
        if not isinstance(preset, dict):
            continue
        sequence = preset.get("sequence_no")
        kind = preset.get("season_type")
        is_summer = kind == "interseason"
        type_counts[str(kind)] += 1

        for key in (
            "preset_code",
            "bundle_code",
            "collection_code",
            "theme_key",
            "economy_profile",
            "badge_key",
            "avatar_key",
            "flagship_slot",
            "flagship_item_code",
            "primary_motif",
            "secondary_motif",
        ):
            check.snake(preset.get(key), f"{path}.{key}")
            if key in {"preset_code", "bundle_code", "collection_code", "theme_key", "badge_key"}:
                if isinstance(preset.get(key), str):
                    unique_values[key].append(preset[key])

        for key in ("suggested_name", "short_description"):
            check.require(
                isinstance(preset.get(key), str) and bool(preset[key].strip()),
                f"{path}.{key}: expected non-empty string",
            )
        check.require(kind in {"regular", "interseason"}, f"{path}.season_type: unexpected value")
        check.require(
            preset.get("economy_profile") == ("summer" if is_summer else "regular"),
            f"{path}.economy_profile: does not match season type",
        )
        check.require(
            preset.get("pricing_status") == ("provisional" if is_summer else "recommended"),
            f"{path}.pricing_status: does not match season type",
        )
        expected_total = 415 if is_summer else 460
        check.require(preset.get("collection_total_target") == expected_total, f"{path}: collection total must be {expected_total}")
        check.require(preset.get("collection_bonus") == 50, f"{path}.collection_bonus: expected 50")
        check.require(preset.get("flagship_slot") in SLOTS, f"{path}.flagship_slot: unexpected value")

        palette = preset.get("palette")
        check.require(isinstance(palette, list) and len(palette) == 5, f"{path}.palette: expected 5 colors")
        if isinstance(palette, list):
            check.require(len(palette) == len(set(palette)), f"{path}.palette: colors must be unique")
            for color_index, color in enumerate(palette):
                check.require(
                    isinstance(color, str) and bool(HEX_RE.fullmatch(color)),
                    f"{path}.palette[{color_index}]: expected uppercase #RRGGBB",
                )

        items = preset.get("items")
        check.require(isinstance(items, list), f"{path}.items: expected array")
        if not isinstance(items, list):
            continue
        check.require(len(items) == 4, f"{path}.items: expected 4")
        check.require(
            Counter(item.get("slot") for item in items if isinstance(item, dict))
            == Counter({slot: 1 for slot in SLOTS}),
            f"{path}.items: expected each slot exactly once",
        )
        check.require(
            Counter(item.get("rarity") for item in items if isinstance(item, dict))
            == Counter({rarity: 1 for rarity in RARITIES}),
            f"{path}.items: expected each rarity exactly once",
        )

        rotation_key = str(sequence % 4) if isinstance(sequence, int) else ""
        expected_rarities = RARITY_ROTATION.get(rotation_key, {})
        expected_prices = prices.get("summer" if is_summer else "regular", {}) if isinstance(prices, dict) else {}
        total = 0
        flagship_matches = 0

        for item_index, item in enumerate(items):
            item_path = f"{path}.items[{item_index}]"
            if not isinstance(item, dict):
                check.errors.append(f"{item_path}: expected object")
                continue
            actual_fields = set(item)
            unknown = actual_fields - ITEM_REQUIRED_FIELDS - ITEM_OPTIONAL_FIELDS
            missing = ITEM_REQUIRED_FIELDS - actual_fields
            if unknown:
                check.errors.append(f"{item_path}: unknown fields: {', '.join(sorted(unknown))}")
            if missing:
                check.errors.append(f"{item_path}: missing fields: {', '.join(sorted(missing))}")

            for key in ("item_code", "asset_key", "render_payload"):
                check.snake(item.get(key), f"{item_path}.{key}")
                if isinstance(item.get(key), str):
                    unique_values[key].append(item[key])
            check.require(
                ITEM_VISUAL_FIELDS <= actual_fields,
                f"{item_path}: visual_key and motion_policy are required",
            )
            check.snake(item.get("visual_key"), f"{item_path}.visual_key")
            for key in ("name", "description"):
                check.require(
                    isinstance(item.get(key), str) and bool(item[key].strip()),
                    f"{item_path}.{key}: expected non-empty string",
                )

            slot = item.get("slot")
            rarity = item.get("rarity")
            check.require(slot in SLOTS, f"{item_path}.slot: unexpected value")
            check.require(rarity in RARITIES, f"{item_path}.rarity: unexpected value")
            if slot in SLOTS:
                check.require(rarity == expected_rarities.get(slot), f"{item_path}.rarity: rotation mismatch")
            check.require(item.get("item_kind") == "cosmetic", f"{item_path}.item_kind: expected cosmetic")
            check.require(item.get("currency") == "gears", f"{item_path}.currency: expected gears")
            check.require(item.get("availability") == "rotation", f"{item_path}.availability: expected rotation")
            check.require(item.get("is_active") is True, f"{item_path}.is_active: expected true")
            expected_motion = "static" if rarity in {"common", "rare"} else ("subtle" if rarity == "epic" else "expressive")
            check.require(item.get("motion_policy") == expected_motion, f"{item_path}.motion_policy: rarity policy mismatch")
            check.require(item.get("sort_order") == (item_index + 1) * 10, f"{item_path}.sort_order: unexpected value")
            if rarity in expected_prices:
                check.require(item.get("price") == expected_prices[rarity], f"{item_path}.price: profile mismatch")
            if isinstance(item.get("price"), int):
                total += item["price"]

            if slot == "title":
                check.require(ITEM_TITLE_FIELDS <= actual_fields, f"{item_path}: title fields are required")
                check.require(
                    item.get("title_visual_tier") == TITLE_TIER_BY_RARITY.get(rarity),
                    f"{item_path}.title_visual_tier: rarity tier mismatch",
                )
                check.snake(item.get("title_icon_hint"), f"{item_path}.title_icon_hint")
            else:
                check.require(not actual_fields & ITEM_TITLE_FIELDS, f"{item_path}: title fields only belong to title slot")

            if item.get("item_code") == preset.get("flagship_item_code"):
                flagship_matches += 1
                check.require(item.get("slot") == preset.get("flagship_slot"), f"{item_path}: flagship slot mismatch")
                check.require(rarity == "legendary", f"{item_path}: flagship item must be legendary")
            all_items.append(item)

        check.require(total == expected_total, f"{path}.items: total {total}, expected {expected_total}")
        check.require(flagship_matches == 1, f"{path}.flagship_item_code: expected one matching item")
        avatars = [item for item in items if isinstance(item, dict) and item.get("slot") == "avatar"]
        if avatars:
            check.require(preset.get("avatar_key") == avatars[0].get("asset_key"), f"{path}.avatar_key: avatar asset mismatch")

    check.require(type_counts == Counter({"regular": 21, "interseason": 2}), "presets: expected 21 regular and 2 interseason")
    for key, values in unique_values.items():
        duplicates = sorted(value for value, count in Counter(values).items() if count > 1)
        check.require(not duplicates, f"{key}: duplicates: {', '.join(duplicates)}")
    return presets, all_items


def validate_counts(presets: list[dict[str, Any]], items: list[dict[str, Any]], check: Validation) -> None:
    check.require(len(items) == 92, f"items: expected 92, got {len(items)}")
    slot_counts = Counter(item.get("slot") for item in items)
    check.require(slot_counts == Counter({slot: 23 for slot in SLOTS}), f"items: bad slot totals {dict(slot_counts)}")
    rarity_counts = Counter(item.get("rarity") for item in items)
    check.require(
        rarity_counts == Counter({rarity: 23 for rarity in RARITIES}),
        f"items: bad rarity totals {dict(rarity_counts)}",
    )

    matrix = {slot: Counter() for slot in SLOTS}
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
        check.require(dict(matrix[slot]) == expected, f"rarity matrix {slot}: got {dict(matrix[slot])}")
    check.require(len({preset.get("theme_key") for preset in presets}) == 23, "presets.theme_key: expected 23 unique values")


def validate_cross_contracts(catalog: dict[str, Any], items: list[dict[str, Any]], check: Validation) -> None:
    item_by_code = {
        item.get("item_code"): item
        for item in items
        if isinstance(item.get("item_code"), str)
    }
    combo = catalog.get("secret_combo")
    if isinstance(combo, dict) and isinstance(combo.get("required_item_codes"), list):
        combo_items = [item_by_code.get(code) for code in combo["required_item_codes"]]
        check.require(all(combo_items), "secret_combo: every required item code must exist")
        if all(combo_items):
            check.require(
                {item.get("slot") for item in combo_items if isinstance(item, dict)} == set(SLOTS),
                "secret_combo: required items must cover all four slots",
            )
            check.require(
                all(item.get("rarity") == "legendary" for item in combo_items if isinstance(item, dict)),
                "secret_combo: every required item must be legendary",
            )

    visual_keys_by_slot: defaultdict[str, list[str]] = defaultdict(list)
    for item in items:
        if item.get("slot") in {"avatar", "frame", "background"} and isinstance(item.get("visual_key"), str):
            visual_keys_by_slot[str(item["slot"])].append(item["visual_key"])
    for slot, keys in visual_keys_by_slot.items():
        duplicates = sorted(key for key, count in Counter(keys).items() if count > 1)
        check.require(not duplicates, f"visual_key {slot}: duplicates: {', '.join(duplicates)}")


def validate_assets_and_preview(items: list[dict[str, Any]], check: Validation) -> None:
    avatar_items = [item for item in items if item.get("slot") == "avatar"]
    expected_files = {f"{item.get('asset_key')}.svg" for item in avatar_items}
    actual_files = {path.name for path in AVATAR_DIR.glob("*.svg")} if AVATAR_DIR.exists() else set()
    check.require(actual_files == expected_files, "assets/season-avatars: SVG set does not match the 23 avatar keys")
    for filename in sorted(expected_files & actual_files):
        path = AVATAR_DIR / filename
        try:
            svg = path.read_text(encoding="utf-8")
        except OSError as exc:
            check.errors.append(f"{path}: cannot read SVG: {exc}")
            continue
        lowered = svg.lower()
        check.require("<svg" in lowered and 'viewbox="0 0 512 512"' in lowered, f"{path}: expected viewBox 0 0 512 512")
        check.require("<title>" in lowered and "<desc>" in lowered, f"{path}: expected accessible title and desc")
        check.require("<script" not in lowered, f"{path}: scripts are forbidden")
        check.require(not EXTERNAL_URL_RE.search(svg), f"{path}: external href/src is forbidden")

    css_parts: list[str] = []
    for path in (BASE_CSS_PATH, CSS_PATH):
        try:
            css_parts.append(path.read_text(encoding="utf-8"))
        except OSError as exc:
            check.errors.append(f"styles: cannot read {path}: {exc}")
    css = "\n".join(css_parts)
    check.require(not re.search(r"url\(\s*['\"]?https?://", css, re.IGNORECASE), "styles: external CSS URLs are forbidden")
    for item in items:
        class_name = approved_css_class(item)
        check.require(bool(class_name) and f".{class_name}" in css, f"styles: missing approved .{class_name}")

    try:
        preview = PREVIEW_PATH.read_text(encoding="utf-8")
    except OSError as exc:
        check.errors.append(f"preview: cannot read {PREVIEW_PATH}: {exc}")
        preview = ""
    for marker in (
        "../styles/student.css",
        "../styles/season-v3-preview.css",
        "../styles/season-cosmetics-preview.css",
        'data-v3-theme="dark"',
        "avatarCatalog",
        "frameCatalog",
        "titleCatalog",
        "backgroundCatalog",
        "catalogGrid",
        "profileOverlay",
        "avatarMarkup(user, 32",
        "avatarMarkup(users[0], 48",
        "avatarMarkup(user, 160",
        'avatarMarkup(previewUser, 112',
    ):
        check.require(marker in preview, f"preview: missing required marker {marker}")
    for item in items:
        token = approved_visual_token(item)
        check.require(f'"{token}"' in preview, f"preview: missing approved {item.get('slot')} visual {token}")
        check.require(f'"{item.get("name")}"' in preview, f"preview: missing approved item name {item.get('name')}")

    try:
        content_doc = CONTENT_DOC_PATH.read_text(encoding="utf-8")
    except OSError as exc:
        check.errors.append(f"docs: cannot read {CONTENT_DOC_PATH}: {exc}")
        content_doc = ""
    try:
        visual_doc = VISUAL_DOC_PATH.read_text(encoding="utf-8")
    except OSError as exc:
        check.errors.append(f"docs: cannot read {VISUAL_DOC_PATH}: {exc}")
        visual_doc = ""
    try:
        integration_doc = INTEGRATION_DOC_PATH.read_text(encoding="utf-8")
    except OSError as exc:
        check.errors.append(f"docs: cannot read {INTEGRATION_DOC_PATH}: {exc}")
        integration_doc = ""
    check.require("## Версия 2: календарно-сезонная концепция" in content_doc, "content doc: missing V2 heading")
    check.require("50% реальный сезон" in visual_doc, "visual doc: missing 50/30/20 formula")
    check.require("1 августа 2026" in integration_doc, "integration doc: missing first automatic launch date")
    check.require("Учительское планирование" in integration_doc, "integration doc: missing teacher planning contract")
    check.require("предпросмотр" in integration_doc.lower(), "integration doc: missing preview contract")


def print_summary(presets: list[dict[str, Any]], items: list[dict[str, Any]]) -> None:
    slot_counts = Counter(item.get("slot") for item in items)
    type_counts = Counter(preset.get("season_type") for preset in presets)
    matrix = {slot: Counter() for slot in SLOTS}
    for item in items:
        if item.get("slot") in matrix:
            matrix[item["slot"]][item.get("rarity")] += 1
    print(f"OK: schema=2, presets={len(presets)}, items={len(items)}")
    print("Calendar: 2026-07-28 .. 2027-06-24 (end exclusive), timezone=Europe/Moscow")
    print(f"Periods: interseason={type_counts['interseason']}, regular={type_counts['regular']}")
    print("Slots: " + ", ".join(f"{slot}={slot_counts[slot]}" for slot in SLOTS))
    print("slot        common  rare  epic  legendary")
    for slot in SLOTS:
        print(
            f"{slot:<10}{matrix[slot]['common']:>7}{matrix[slot]['rare']:>6}"
            f"{matrix[slot]['epic']:>6}{matrix[slot]['legendary']:>11}"
        )


def main() -> int:
    check = Validation()
    catalog = load_catalog(check)
    if catalog:
        validate_root(catalog, check)
        presets, items = validate_presets(catalog, check)
        validate_counts(presets, items, check)
        validate_cross_contracts(catalog, items, check)
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
