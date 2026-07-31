#!/usr/bin/env python3
"""Offline contract checks for the Season V2 production integration."""

from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parents[1]


def read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


def main() -> int:
    errors: list[str] = []

    def require(condition: bool, message: str) -> None:
        if not condition:
            errors.append(message)

    foundation = read("database/migrations/057_season_v2_foundation.sql")
    seed = read("database/migrations/058_season_v2_catalog_seed.sql")
    student_html = read("index.html")
    teacher_html = read("teacher.html")
    progress = read("js/student-progress.js")
    shop = read("js/student-shop.js")
    teacher = read("js/teacher-students.js")
    renderer = read("js/season-cosmetics.js")

    require("where status = 'scheduled'" in foundation, "schedule only starts published rows")
    require("status = 'active'" in foundation, "runtime has an explicit active state")
    require("create or replace function public.ensure_season_rotation()" in foundation,
            "shop must tick the Season V2 schedule")
    require("catalog_only_period" in foundation, "catalog-only period must be server-protected")
    require("admin_save_season_v2_self" in foundation, "teacher save gateway missing")
    require("private.current_app_role() is distinct from 'teacher'" in foundation,
            "teacher gateway role guard missing")
    require("position('<'" in foundation and "markup_not_allowed" in foundation,
            "teacher text markup validation missing")

    require("2026-08-01 00:00:00 Europe/Moscow" in seed, "first MSK launch timestamp changed")
    require(re.search(r"sequence_no,\s*competition_season_no", seed) is not None,
            "seed preset columns missing")
    require("where p.sequence_no >= 2" in seed and "'scheduled'" in seed,
            "seed must publish sequences 2–23")
    require("2602" in seed and "2623" in seed, "fixed bundle range missing")

    for html, label in ((student_html, "student"), (teacher_html, "teacher")):
        require("styles/season-v3-preview.css" in html, f"{label} approved base CSS missing")
        require("styles/season-cosmetics-preview.css" in html, f"{label} approved cosmetics CSS missing")
        require("js/season-cosmetics.js" in html, f"{label} safe renderer missing")

    require('id="season-profile-overlay"' in student_html, "expanded profile card missing")
    require("SeasonCosmetics.replaceAvatar" in progress, "student avatar renderer not wired")
    require("SeasonCosmetics.createScene" in progress, "leaderboard background renderer not wired")
    require("history.pushState({ seasonProfileCard: true }" in progress,
            "expanded card browser-back behavior missing")
    require("item.slot === 'avatar'" in shop, "avatar shop preview missing")
    require("shop-rarity--" in shop, "shop rarity label missing")

    require('id="season-v2-modal"' in teacher_html, "teacher editor modal missing")
    require("admin_list_season_v2_self" in teacher, "teacher read-model not wired")
    require("admin_save_season_v2_self" in teacher, "teacher save gateway not wired")
    require("seasonPreviewCard" in teacher, "teacher live preview missing")

    for token in ("AVATARS", "FRAMES", "BACKGROUNDS", "TITLE_VISUALS"):
        require(f"const {token} = new Set" in renderer, f"renderer allowlist {token} missing")
    require("hasSecretCombo" in renderer, "secret legendary combo missing")

    if errors:
        print(f"FAILED: {len(errors)} integration error(s)", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print("OK: Season V2 production integration contract")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
