#!/usr/bin/env python3
"""Apply the 2026-06-03 next-batch Minecraft mod tracker updates."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import re
import sqlite3
from urllib.parse import urlparse


SPREADSHEET_ID = "1OIJFcikV6d6qKxFDnT34eEFCFOVFXUqRCIcWHMDq1Wo"
TODAY = "2026-06-03"
HEADERS = [
    "Mod",
    "Installation",
    "Type",
    "Tested",
    "Notes 1",
    "Notes 2",
    "URL",
    "Target MC",
    "Server Status",
    "Server File",
    "Client Package",
    "Last Tested",
    "Resolved Source",
    "Migration Notes",
]


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()


def row_hash(values: list[str]) -> str:
    return hashlib.sha256("\x1f".join(values).encode("utf-8")).hexdigest()


def append_note(existing: str | None, addition: str) -> str:
    existing = (existing or "").strip()
    if not existing:
        return addition
    if addition in existing:
        return existing
    return f"{existing} {addition}"


def source_parts(url: str) -> tuple[str, str, str]:
    parsed = urlparse(url)
    host = parsed.netloc.lower()
    path = parsed.path
    kind = "curseforge" if "curseforge.com" in host else "other"
    match = re.search(
        r"/minecraft/(?:mc-mods|texture-packs|data-packs|shaders)/([^/]+)",
        path,
    )
    return kind, host, match.group(1) if match else ""


def hash_for(mod: dict[str, object]) -> str:
    file_text = " + ".join(mod.get("files", []))  # type: ignore[arg-type]
    values = [
        str(mod["name"]),
        str(mod.get("installation", "")),
        str(mod.get("entry_type", "")),
        str(mod.get("tested", "")),
        str(mod.get("notes_1", "")),
        str(mod.get("notes_2", "")),
        str(mod.get("primary_url", "")),
        str(mod.get("target_mc", "")),
        str(mod.get("server_status", "")),
        file_text,
        str(mod.get("client_package", "")),
        str(mod.get("last_tested", "")),
        str(mod.get("resolved_source", "")),
        str(mod.get("migration_notes", "")),
    ]
    if len(values) != len(HEADERS):
        raise ValueError("row hash value shape drifted")
    return row_hash(values)


ACCEPTED_NOTE = (
    "Final active-set boot test 20260603_next_final_active_set reached Done; "
    "filtered error count 0. Only known optional tintedcampfires/sootychimneys "
    "warnings remain."
)


ACCEPTED = [
    {
        "key": "puzzles-lib",
        "name": "Puzzles Lib",
        "category": "Dependency",
        "installation": "Server + client",
        "entry_type": "Dependency",
        "tested": "OK",
        "target_mc": "NeoForge 26.1.x / server 26.1.2",
        "server_status": "OK",
        "client_package": "Included",
        "primary_url": "https://www.curseforge.com/minecraft/mc-mods/puzzles-lib",
        "files": ["PuzzlesLib-v26.1.9-mc26.1.x-NeoForge.jar"],
        "file_id": "8168213",
        "release_channel": "stable",
        "resolved_source": "CurseForge stable release file 8168213",
        "test_label": "20260603_next_01_puzzles_lib",
        "error_count": 17,
        "notes": f"Required dependency for Leaves Be Gone. {ACCEPTED_NOTE}",
    },
    {
        "key": "goblin-traders",
        "name": "Goblin Traders",
        "category": "Requested 2026-06-03",
        "installation": "Server + client",
        "entry_type": "Mod",
        "tested": "OK",
        "target_mc": "NeoForge 26.1.2",
        "server_status": "OK",
        "client_package": "Included",
        "primary_url": "https://www.curseforge.com/minecraft/mc-mods/goblin-traders",
        "files": ["goblintraders-neoforge-26.1.2-1.12.0.jar"],
        "file_id": "7943154",
        "release_channel": "stable",
        "resolved_source": "CurseForge stable release file 7943154",
        "test_label": "20260603_next_02_goblin_traders",
        "error_count": 17,
        "notes": f"Framework dependency was already active. {ACCEPTED_NOTE}",
    },
    {
        "key": "terralith",
        "name": "Terralith",
        "category": "Requested 2026-06-03",
        "installation": "Server + client",
        "entry_type": "Mod",
        "tested": "OK",
        "target_mc": "NeoForge 26.1 / server 26.1.2",
        "server_status": "OK",
        "client_package": "Included",
        "primary_url": "https://www.curseforge.com/minecraft/mc-mods/terralith",
        "files": ["Terralith_26.1_v2.6.1_Neoforge.jar"],
        "file_id": "7841479",
        "release_channel": "stable",
        "resolved_source": "CurseForge stable release file 7841479",
        "test_label": "20260603_next_03_terralith",
        "error_count": 17,
        "notes": f"Lithostitched dependency was already active. {ACCEPTED_NOTE}",
    },
    {
        "key": "villager-names",
        "name": "Villager Names",
        "category": "Requested 2026-06-03",
        "installation": "Server + client",
        "entry_type": "Mod",
        "tested": "OK",
        "target_mc": "26.1.2",
        "server_status": "OK",
        "client_package": "Included",
        "primary_url": "https://www.curseforge.com/minecraft/mc-mods/villager-names",
        "files": ["villagernames-26.1.2-8.4.jar"],
        "file_id": "8021608",
        "release_channel": "stable",
        "resolved_source": "CurseForge stable release file 8021608",
        "test_label": "20260603_next_04_villager_names",
        "error_count": 17,
        "notes": f"Collective dependency was already active. {ACCEPTED_NOTE}",
    },
    {
        "key": "leaves-be-gone",
        "name": "Leaves Be Gone",
        "category": "Requested 2026-06-03",
        "installation": "Server + client",
        "entry_type": "Mod",
        "tested": "OK",
        "target_mc": "NeoForge 26.1.x / server 26.1.2",
        "server_status": "OK",
        "client_package": "Included",
        "primary_url": "https://www.curseforge.com/minecraft/mc-mods/leaves-be-gone",
        "files": ["LeavesBeGone-v26.1.0-mc26.1.x-NeoForge.jar"],
        "file_id": "8036435",
        "release_channel": "stable",
        "resolved_source": "CurseForge stable release file 8036435",
        "test_label": "20260603_next_05_leaves_be_gone",
        "error_count": 17,
        "notes": f"Required Puzzles Lib dependency tested first and accepted. {ACCEPTED_NOTE}",
    },
    {
        "key": "geophilic",
        "name": "Geophilic",
        "category": "Requested 2026-06-03",
        "installation": "Server + client",
        "entry_type": "Mod",
        "tested": "OK",
        "target_mc": "NeoForge 26.1.x / server 26.1.2",
        "server_status": "OK",
        "client_package": "Included",
        "primary_url": "https://www.curseforge.com/minecraft/mc-mods/geophilic",
        "files": ["Geophilic v3.5.mod.jar"],
        "file_id": "8074028",
        "release_channel": "stable",
        "resolved_source": "CurseForge stable mc-mod release file 8074028",
        "test_label": "20260603_next_06_geophilic",
        "error_count": 17,
        "notes": f"Used mc-mods project, not datapack project with same slug. {ACCEPTED_NOTE}",
    },
    {
        "key": "double-doors",
        "name": "Double Doors",
        "category": "Requested 2026-06-03",
        "installation": "Server + client",
        "entry_type": "Mod",
        "tested": "OK",
        "target_mc": "26.1.2",
        "server_status": "OK",
        "client_package": "Included",
        "primary_url": "https://www.curseforge.com/minecraft/mc-mods/double-doors",
        "files": ["doubledoors-26.1.2-7.2.jar"],
        "file_id": "7902248",
        "release_channel": "stable",
        "resolved_source": "CurseForge stable release file 7902248",
        "test_label": "20260603_next_07_double_doors",
        "error_count": 17,
        "notes": f"Collective dependency was already active. {ACCEPTED_NOTE}",
    },
    {
        "key": "clean-swing-through-grass",
        "name": "Clean Swing Through Grass",
        "category": "Requested 2026-06-03",
        "installation": "Server + client",
        "entry_type": "Mod",
        "tested": "OK",
        "target_mc": "NeoForge 26.1.x / server 26.1.2",
        "server_status": "OK",
        "client_package": "Included",
        "primary_url": "https://www.curseforge.com/minecraft/mc-mods/clean-swing-through-grass",
        "files": ["cleanswing-1.9-26.1.jar"],
        "file_id": "7934502",
        "release_channel": "stable",
        "resolved_source": "CurseForge stable release file 7934502",
        "test_label": "20260603_next_08_clean_swing",
        "error_count": 17,
        "notes": ACCEPTED_NOTE,
    },
    {
        "key": "dungeon-crawl",
        "name": "Dungeon Crawl",
        "category": "Requested 2026-06-03",
        "installation": "Server + client",
        "entry_type": "Mod",
        "tested": "OK",
        "target_mc": "NeoForge 26.1.x / server 26.1.2",
        "server_status": "OK",
        "client_package": "Included",
        "primary_url": "https://www.curseforge.com/minecraft/mc-mods/dungeon-crawl",
        "files": ["DungeonCrawl-NeoForge-26.1-2.3.17.jar"],
        "file_id": "7887378",
        "release_channel": "beta",
        "resolved_source": "CurseForge beta release file 7887378 from actual mc-mods project 324973",
        "test_label": "20260603_next_09_dungeon_crawl",
        "error_count": 17,
        "notes": (
            "Recovered by selecting the mc-mods project instead of the same-slug "
            f"modpack; beta accepted under relaxed policy. {ACCEPTED_NOTE}"
        ),
    },
    {
        "key": "explorify",
        "name": "Explorify - Dungeons & Structures",
        "category": "Requested 2026-06-03",
        "installation": "Server + client",
        "entry_type": "Mod",
        "tested": "OK",
        "target_mc": "NeoForge 26.1.x / server 26.1.2",
        "server_status": "OK",
        "client_package": "Included",
        "primary_url": "https://www.curseforge.com/minecraft/mc-mods/explorify",
        "files": ["Explorify v1.6.5.mod.jar"],
        "file_id": "8082824",
        "release_channel": "stable",
        "resolved_source": "CurseForge stable release file 8082824 from actual mc-mods project 698309",
        "test_label": "20260603_next_10_explorify",
        "error_count": 17,
        "notes": (
            "Recovered by selecting the mc-mods project instead of the same-slug "
            f"modpack. {ACCEPTED_NOTE}"
        ),
    },
]


REJECTED = {
    "key": "ecologics",
    "name": "Ecologics",
    "category": "Requested 2026-06-03",
    "installation": "Server + client",
    "entry_type": "Mod",
    "tested": "Failed",
    "target_mc": "NeoForge 26.1.2",
    "server_status": "Rejected: global loot modifier parse error",
    "client_package": "Not included",
    "primary_url": "https://www.curseforge.com/minecraft/mc-mods/ecologics",
    "files": ["Ecologics-NeoFab-26.1.2-2.5.0.jar"],
    "file_id": "8111342",
    "release_channel": "stable",
    "resolved_source": "CurseForge stable release file 8111342",
    "test_label": "20260603_next_11_ecologics_retest",
    "error_count": 18,
    "notes": (
        "Retested latest compatible release. Rejected again: log contains ERROR "
        "parsing neoforge:loot_modifiers/global_loot_modifiers.json for "
        "ecologics:music_disc_buried_treasure. Jar quarantined under "
        "/var/minecraft_26.1.2/mods.failed/20260603_next_11_ecologics_retest."
    ),
}


DUPLICATE_KEYS = [
    "towns-and-towers",
    "guard-villagers",
    "macaws-furniture",
    "macaws-lights-and-lamps",
    "falling-tree",
    "moogs-voyager-structures",
    "croptopia",
    "large-ore-deposits",
    "dynamictrees",
    "structory-towers",
]
DUPLICATE_NOTE = (
    "Requested again in 2026-06-03 next batch; already active and current "
    "compatible candidate confirmed, no reinstall needed."
)


def ensure_import(cur: sqlite3.Cursor, now: str) -> int:
    cur.execute(
        """
        INSERT INTO imports(
            imported_at, source_file, spreadsheet_id, sheet_name, source_range, row_count
        ) VALUES (?, ?, ?, ?, ?, ?)
        """,
        (
            now,
            "manual-url-batch-2026-06-03-next",
            SPREADSHEET_ID,
            "Minecraft",
            "manual URLs",
            21,
        ),
    )
    return int(cur.lastrowid)


def upsert_mod(
    cur: sqlite3.Cursor,
    import_id: int,
    mod: dict[str, object],
    active_status: str,
    status_rank: int,
    installed: int,
    included: int,
    file_status: str,
    now: str,
) -> None:
    mod["last_tested"] = TODAY
    mod["migration_notes"] = str(mod["notes"])
    key = str(mod["key"])
    existing = cur.execute(
        """
        SELECT id, original_sheet_row, category
        FROM mods
        WHERE canonical_key = ? AND duplicate_of_id IS NULL
        ORDER BY id
        LIMIT 1
        """,
        (key,),
    ).fetchone()
    if existing:
        mod_id, _, old_category = existing
        category = old_category or str(mod.get("category", ""))
    else:
        mod_id = None
        category = str(mod.get("category", ""))

    fingerprint = hash_for(mod)
    if mod_id is None:
        next_row = cur.execute(
            "SELECT COALESCE(MAX(original_sheet_row), 0) + 1 FROM mods"
        ).fetchone()[0]
        cur.execute(
            """
            INSERT INTO mods(
                import_id, original_sheet_row, category, name, canonical_key,
                installation, entry_type, tested, target_mc, server_status,
                client_package, last_tested, active_status, status_rank,
                primary_url, is_duplicate, duplicate_of_id, row_hash, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, NULL, ?, ?, ?)
            """,
            (
                import_id,
                next_row,
                category,
                str(mod["name"]),
                key,
                str(mod["installation"]),
                str(mod["entry_type"]),
                str(mod["tested"]),
                str(mod["target_mc"]),
                str(mod["server_status"]),
                str(mod["client_package"]),
                TODAY,
                active_status,
                status_rank,
                str(mod["primary_url"]),
                fingerprint,
                now,
                now,
            ),
        )
        mod_id = int(cur.lastrowid)
        cur.execute(
            """
            INSERT INTO sheet_rows(mod_id, spreadsheet_id, sheet_name, row_number, row_hash)
            VALUES (?, ?, ?, ?, ?)
            """,
            (mod_id, SPREADSHEET_ID, "Minecraft", next_row, fingerprint),
        )
        existing_notes = ("", "", "")
    else:
        cur.execute(
            """
            UPDATE mods
            SET category = ?, name = ?, installation = ?, entry_type = ?, tested = ?,
                target_mc = ?, server_status = ?, client_package = ?, last_tested = ?,
                active_status = ?, status_rank = ?, primary_url = ?, row_hash = ?,
                updated_at = ?
            WHERE id = ?
            """,
            (
                category,
                str(mod["name"]),
                str(mod["installation"]),
                str(mod["entry_type"]),
                str(mod["tested"]),
                str(mod["target_mc"]),
                str(mod["server_status"]),
                str(mod["client_package"]),
                TODAY,
                active_status,
                status_rank,
                str(mod["primary_url"]),
                fingerprint,
                now,
                mod_id,
            ),
        )
        existing_notes = cur.execute(
            "SELECT notes_1, notes_2, migration_notes FROM mod_notes WHERE mod_id = ?",
            (mod_id,),
        ).fetchone() or ("", "", "")

    merged_note = append_note(existing_notes[2], str(mod["migration_notes"]))
    cur.execute(
        """
        INSERT INTO mod_notes(mod_id, notes_1, notes_2, migration_notes)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(mod_id) DO UPDATE SET
            notes_1 = excluded.notes_1,
            notes_2 = excluded.notes_2,
            migration_notes = excluded.migration_notes
        """,
        (mod_id, existing_notes[0] or "", existing_notes[1] or "", merged_note),
    )

    cur.execute("DELETE FROM source_urls WHERE mod_id = ?", (mod_id,))
    kind, host, slug = source_parts(str(mod["primary_url"]))
    cur.execute(
        """
        INSERT INTO source_urls(
            mod_id, source_kind, url, host, project_slug, resolved_source,
            file_id, release_channel, is_primary
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1)
        """,
        (
            mod_id,
            kind,
            str(mod["primary_url"]),
            host,
            slug,
            str(mod["resolved_source"]),
            str(mod["file_id"]),
            str(mod["release_channel"]),
        ),
    )

    cur.execute("DELETE FROM mod_files WHERE mod_id = ?", (mod_id,))
    for filename in mod["files"]:  # type: ignore[union-attr]
        cur.execute(
            """
            INSERT INTO mod_files(
                mod_id, role, file_name, path_hint, installed_on_server,
                included_in_client, status
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            (
                mod_id,
                "server_file",
                filename,
                "/var/minecraft_26.1.2/mods"
                if installed
                else "/var/minecraft_26.1.2/mods.failed",
                installed,
                included,
                file_status,
            ),
        )

    cur.execute(
        """
        INSERT INTO test_runs(mod_id, tested_at, test_label, status, error_count, log_path, notes)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """,
        (
            mod_id,
            now,
            str(mod["test_label"]),
            "started",
            int(mod["error_count"]),
            f"/var/minecraft_26.1.2/server-test-results/{mod['test_label']}.log",
            str(mod["notes"]),
        ),
    )


def note_duplicates(cur: sqlite3.Cursor, now: str) -> None:
    for key in DUPLICATE_KEYS:
        rows = cur.execute(
            """
            SELECT m.id, n.notes_1, n.notes_2, n.migration_notes
            FROM mods m
            LEFT JOIN mod_notes n ON n.mod_id = m.id
            WHERE m.canonical_key = ?
            """,
            (key,),
        ).fetchall()
        for mod_id, notes_1, notes_2, migration_notes in rows:
            cur.execute(
                """
                INSERT INTO mod_notes(mod_id, notes_1, notes_2, migration_notes)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(mod_id) DO UPDATE SET migration_notes = excluded.migration_notes
                """,
                (
                    mod_id,
                    notes_1 or "",
                    notes_2 or "",
                    append_note(migration_notes, DUPLICATE_NOTE),
                ),
            )
            cur.execute("UPDATE mods SET updated_at = ? WHERE id = ?", (now, mod_id))

        canonical = cur.execute(
            """
            SELECT id FROM mods
            WHERE canonical_key = ? AND duplicate_of_id IS NULL
            ORDER BY id
            LIMIT 1
            """,
            (key,),
        ).fetchone()
        if canonical:
            cur.execute(
                """
                INSERT INTO test_runs(
                    mod_id, tested_at, test_label, status, error_count, log_path, notes
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    canonical[0],
                    now,
                    "20260603_next_duplicate_current_check",
                    "not_retested",
                    0,
                    "",
                    "Current compatible candidate already installed; duplicate request noted.",
                ),
            )


def add_final_validation(cur: sqlite3.Cursor, now: str) -> None:
    for mod in ACCEPTED:
        row = cur.execute(
            """
            SELECT id FROM mods
            WHERE canonical_key = ? AND duplicate_of_id IS NULL
            ORDER BY id
            LIMIT 1
            """,
            (mod["key"],),
        ).fetchone()
        if not row:
            continue
        cur.execute(
            """
            INSERT INTO test_runs(mod_id, tested_at, test_label, status, error_count, log_path, notes)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            (
                row[0],
                now,
                "20260603_next_final_active_set",
                "started",
                17,
                "/var/minecraft_26.1.2/server-test-results/20260603_next_final_active_set.log",
                ACCEPTED_NOTE,
            ),
        )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--db", default="data/minecraft_mods.sqlite")
    args = parser.parse_args()

    now = utc_now()
    with sqlite3.connect(args.db) as con:
        con.execute("PRAGMA foreign_keys = ON")
        cur = con.cursor()
        import_id = ensure_import(cur, now)
        for mod in ACCEPTED:
            upsert_mod(cur, import_id, mod, "ok", 40, 1, 1, "OK", now)
        upsert_mod(
            cur,
            import_id,
            REJECTED,
            "failed",
            30,
            0,
            0,
            "Rejected: global loot modifier parse error",
            now,
        )
        note_duplicates(cur, now)
        add_final_validation(cur, now)
        con.commit()

    print(
        f"updated accepted={len(ACCEPTED)} rejected=1 duplicate_notes={len(DUPLICATE_KEYS)}"
    )


if __name__ == "__main__":
    main()
