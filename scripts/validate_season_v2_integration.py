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
    safe_teacher = read("database/migrations/059_teacher_safe_season_metadata.sql")
    editable_labels = read("database/migrations/060_teacher_edit_all_scheduled_season_labels.sql")
    student_html = read("index.html")
    teacher_html = read("teacher.html")
    progress = read("js/student-progress.js")
    shop = read("js/student-shop.js")
    teacher = read("js/teacher-students.js")
    teacher_core = read("js/teacher-core.js")
    renderer = read("js/season-cosmetics.js")
    student_css = read("styles/student.css")

    require("where status = 'scheduled'" in foundation, "schedule only starts published rows")
    require("status = 'active'" in foundation, "runtime has an explicit active state")
    require("create or replace function public.ensure_season_rotation()" in foundation,
            "shop must tick the Season V2 schedule")
    require("catalog_only_period" in foundation, "catalog-only period must be server-protected")
    require("admin_save_season_v2_self" in foundation, "initial teacher save gateway missing")
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
    require("admin_update_scheduled_season_meta_self" in safe_teacher,
            "safe scheduled-season metadata gateway missing")
    require("display_number" in safe_teacher, "editable display number missing")
    require("revoke all on function public.admin_save_season_v2_self" in safe_teacher,
            "full teacher season mutation must be disabled")
    require("revoke all on function public.close_season_self()" in safe_teacher,
            "manual season closure must be disabled")
    require("drop index if exists public.idx_seasons_v2_display_number" in editable_labels,
            "public season number is still incorrectly unique")
    require("'display_number', coalesce(s.display_number, p.sequence_no)" in editable_labels,
            "all season rows do not receive public display numbers")
    require("interseason_has_no_number" not in editable_labels,
            "technical interseason type still blocks public label editing")

    for html, label in ((student_html, "student"), (teacher_html, "teacher")):
        require("styles/season-v3-preview.css" in html, f"{label} approved base CSS missing")
        require("styles/season-cosmetics-preview.css" in html, f"{label} approved cosmetics CSS missing")
        require("js/season-cosmetics.js" in html, f"{label} safe renderer missing")

    require('id="season-profile-overlay"' in student_html, "expanded profile card missing")
    require('id="season-profile-equipment"' in student_html,
            "expanded profile equipment summary missing")
    require("SeasonCosmetics.replaceAvatar" in progress, "student avatar renderer not wired")
    require("SeasonCosmetics.createScene" in progress, "leaderboard background renderer not wired")
    require("history.pushState({ seasonProfileCard: true }" in progress,
            "expanded card browser-back behavior missing")
    require("item.slot === 'avatar'" in shop, "avatar shop preview missing")
    require("shop-rarity--" in shop, "shop rarity label missing")
    require("display_number" in shop and "display_number" in progress,
            "student season labels still depend only on internal database ids")
    require(".in('rotation_bundle', visibleBundleIds)" in shop,
            "future collection items are still loaded")
    require("openOwnSeasonProfileCard" in progress and "openOwnSeasonProfileCard(this)" in student_html,
            "stable own mini-profile trigger missing")
    require("renderSeasonProfileEquipment" in progress
            and "SEASON_PROFILE_EQUIPMENT_SLOTS" in progress
            and "SEASON_PROFILE_RARITY_LABELS" in progress
            and "seasonEquipmentCatalogMark" in progress,
            "expanded profile does not list equipped cosmetics")

    require('id="season-v2-modal"' in teacher_html, "teacher goods preview modal missing")
    require("admin_list_season_v2_self" in teacher, "teacher read-model not wired")
    require("admin_update_scheduled_season_meta_self" in teacher,
            "safe teacher metadata gateway not wired")
    require("season-v2-inline-editor" in teacher,
            "scheduled-season metadata editor must stay inside its season card")
    require("text: 'Запланирован'" in teacher,
            "scheduled season status is not translated")
    require("Межсезонье" not in teacher and "период" not in teacher
            and "период" not in teacher_html,
            "technical season type leaks into teacher labels")
    require('id="season-v2-save-meta"' not in teacher_html,
            "full-screen season metadata save action returned")
    require("closeSeasonV2Preview" in teacher_core,
            "season preview can leak into another teacher tab")
    require("admin_save_season_v2_self" not in teacher,
            "teacher client still exposes full season mutation")
    require("structuredClone(" not in teacher,
            "teacher preview depends on unsupported WebView structuredClone")
    require('id="btn-close-season"' not in teacher_html, "manual close button still present")
    require("closeSeason()" not in teacher_html, "manual close handler still present")
    require('id="season-v2-items"' in teacher_html, "teacher goods viewer missing")
    require("seasonPreviewCard" in teacher, "teacher live preview missing")

    for token in ("AVATARS", "FRAMES", "BACKGROUNDS", "TITLE_VISUALS"):
        require(f"const {token} = new Set" in renderer, f"renderer allowlist {token} missing")
    require("hasSecretCombo" in renderer, "secret legendary combo missing")
    require("const LEGACY_FRAMES = new Set" in renderer and "legacyFrameClass" in renderer,
            "legacy equipped frames are not supported by the V4 runtime")
    require("const LEGACY_BACKGROUNDS = new Set" in renderer and "legacySceneClass" in renderer,
            "legacy equipped backgrounds are not supported by the V4 runtime")
    require("LEGACY_FRAMES.forEach" in renderer and "has-legacy-frame" in renderer,
            "legacy frame classes are not restored on avatar hosts")
    require(".legacy-equipped-scene.bg-grid" in student_css
            and ".season-avatar-host.has-legacy-frame" in student_css,
            "legacy cosmetics runtime CSS missing")

    if errors:
        print(f"FAILED: {len(errors)} integration error(s)", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print("OK: Season V2 production integration contract")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
