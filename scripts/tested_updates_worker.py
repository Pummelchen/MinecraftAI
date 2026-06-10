#!/usr/bin/env python3
"""
Tested Updates Worker - builds a comprehensive Tested Updates feed every 15 minutes.

Sources:
- update_events (visible_on_site=1, status in applied/ok)
- test_runs (boot tests that reached Done)
- mod_acceptance_blocks (passed blocks from pyramid acceptance)
- headless_client_runs (successful client joins)
- pack_releases (newly activated releases)

Output: JSON file at /var/minecraft_mods/site/public/tested-updates.json
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import sqlite3
import sys
from pathlib import Path
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from moddb import connect, source_kind
from pummelchen_utils import table_exists
from process_url_batch import get_modrinth_project, project_name as process_project_name, search_project


DEFAULT_DB = Path("/var/minecraft_mods/data/minecraft_mods.sqlite")
DEFAULT_OUTPUT = Path("/var/minecraft_mods/site/public/tested-updates.json")
UPDATE_LOG_DAYS = 30


_MOD_NAME_CACHE: dict[int, str] = {}
_SOURCE_URL_NAME_CACHE: dict[str, str] = {}


def looks_like_file_name(name: str) -> bool:
    """Return true when the string looks like an artifact filename rather than a mod title."""
    if not name:
        return False
    lowered = name.lower()
    if re.search(r"\.(jar|zip)(?:\.disabled)?$", lowered):
        return True
    if lowered.endswith(".jar.disabled") or lowered.endswith(".zip.disabled"):
        return True
    return bool(re.search(r"\.[a-z0-9]+$", lowered)) and " " not in lowered


def looks_like_version_token(token: str) -> bool:
    token = token.strip().lower()
    if not token:
        return False
    if token in {"mod", "jar", "client", "server", "neoforge", "neo", "forge", "fabric", "quilt", "modrinth"}:
        return True
    if re.fullmatch(r"\d+(?:\.\d+)*(?:[-+.]?[a-z0-9._]+)?", token):
        return True
    if re.fullmatch(r"v?\d+\.\d+(?:\.\d+)*(?:\.\w+)?", token):
        return True
    if token.startswith("build.") or token.startswith("build-") or token == "1.21":
        return True
    return False


def readable_title_from_file_name(file_name: str) -> str:
    base = file_name.strip()
    if not base:
        return "Pack update"
    base = re.sub(r"\.[a-z0-9]+(?:\.[a-z0-9-]+)?$", "", base, flags=re.IGNORECASE)
    base = base.replace("_", "-")
    parts = [part for part in base.split("-") if part]
    while parts and looks_like_version_token(parts[-1]):
        parts.pop()
    if not parts:
        parts = [base]
    readable = " ".join(part.replace(".", " ").strip() for part in parts if part)
    if not readable:
        return base
    return readable.replace("  ", " ").strip().title()


def slug_from_file_name(file_name: str) -> str:
    base = file_name.strip()
    if not base:
        return ""
    base = re.sub(r"\.[a-z0-9]+(?:\.[a-z0-9-]+)?$", "", base, flags=re.IGNORECASE)
    base = base.replace("_", "-")
    parts = [part for part in base.split("-") if part]
    while parts and looks_like_version_token(parts[-1]):
        parts.pop()
    return "-".join(parts).lower()


def resolve_name_from_source_url(conn: sqlite3.Connection, mod_id: int | None, fallback_url: str | None = None) -> str:
    if not mod_id and not fallback_url:
        return ""
    if mod_id:
        cached = _MOD_NAME_CACHE.get(int(mod_id))
        if cached:
            return cached

    source_url = None
    if mod_id:
        row = conn.execute(
            "SELECT COALESCE(NULLIF(su.url, ''), m.primary_url) AS url "
            "FROM mods m "
            "LEFT JOIN source_urls su ON su.mod_id = m.id AND su.is_primary = 1 "
            "WHERE m.id = ?",
            (mod_id,),
        ).fetchone()
        if row and row["url"]:
            source_url = str(row["url"])
    if not source_url:
        source_url = fallback_url
    if not source_url:
        return ""

    if not source_url:
        return ""
    cached = _SOURCE_URL_NAME_CACHE.get(str(source_url))
    if cached:
        return cached
    try:
        _, _, slug = source_kind(str(source_url))
        resolved = ""
        if slug:
            if "modrinth" in str(source_url):
                project = get_modrinth_project(slug)
                if project:
                    resolved = process_project_name(project)
            elif "curseforge" in str(source_url):
                project = search_project(slug)
                if project:
                    resolved = process_project_name(project)
    except Exception:
        resolved = ""

    if not resolved:
        return ""
    _SOURCE_URL_NAME_CACHE[str(source_url)] = resolved
    if mod_id:
        _MOD_NAME_CACHE[int(mod_id)] = resolved
    return resolved


def fetch_mod_name(conn: sqlite3.Connection, mod_id: int | None, fallback_name: str = "") -> str:
    if not mod_id:
        return clean_title(fallback_name) or "Pack update"
    row = conn.execute("SELECT name, primary_url FROM mods WHERE id = ?", (mod_id,)).fetchone()
    if not row:
        return f"Mod #{mod_id}"

    db_name = str(row["name"])
    title = clean_title(fallback_name or db_name)
    if not looks_like_file_name(title):
        return title

    fallback_url = str(row["primary_url"]) if row["primary_url"] else None
    resolved = resolve_name_from_source_url(conn, int(mod_id), fallback_url)
    return clean_title(resolved) if resolved else title


def fetch_mod_name_from_file(conn: sqlite3.Connection, file_name: str) -> str:
    row = conn.execute(
        """
        SELECT m.id AS mod_id, m.name AS mod_name
        FROM mod_files f
        JOIN mods m ON m.id = f.mod_id
        WHERE f.file_name = ?
        ORDER BY f.id DESC
        LIMIT 1
        """,
        (file_name,),
    ).fetchone()
    if row:
        return fetch_mod_name(conn, int(row["mod_id"]), str(row["mod_name"]))
    slug = slug_from_file_name(file_name)
    try:
        if slug and slug != file_name.lower():
            project = search_project(slug)
            if project:
                return clean_title(process_project_name(project))
    except Exception:
        pass
    return readable_title_from_file_name(file_name)


def fetch_mod_url_from_file(conn: sqlite3.Connection, file_name: str) -> str:
    row = conn.execute(
        """
        SELECT COALESCE(NULLIF(su.url, ''), m.primary_url) AS url
        FROM mod_files f
        JOIN mods m ON m.id = f.mod_id
        LEFT JOIN source_urls su ON su.mod_id = m.id AND su.is_primary = 1
        WHERE f.file_name = ?
        ORDER BY f.id DESC
        LIMIT 1
        """,
        (file_name,),
    ).fetchone()
    if row and row["url"]:
        return str(row["url"])
    return ""


def fetch_mod_url(conn: sqlite3.Connection, mod_id: int | None, fallback_url: str | None = None) -> str:
    if not mod_id:
        return fallback_url or ""
    row = conn.execute(
        "SELECT COALESCE(NULLIF(su.url, ''), m.primary_url) AS url "
        "FROM source_urls su JOIN mods m ON m.id = su.mod_id "
        "WHERE su.mod_id = ? AND su.is_primary = 1 "
        "UNION SELECT primary_url FROM mods WHERE id = ?",
        (mod_id, mod_id),
    ).fetchone()
    if row and row["url"]:
        return str(row["url"])
    return fallback_url or ""


def clean_title(title: str) -> str:
    if not title:
        return "Pack update"
    platform_tag = re.compile(
        r"\s*(?:"
        r"\[[^\]]*(?:server|client|fabric|forge|neoforge|quilt|modloader)[^\]]*\]"
        r"|"
        r"\([^)]*(?:server|client|fabric|forge|neoforge|quilt|modloader)[^)]*\)"
        r")\s*",
        re.IGNORECASE,
    )
    cleaned = platform_tag.sub(" ", title)
    cleaned = re.sub(r"\s+", " ", cleaned).strip(" -:/|")
    return cleaned or title


def parse_iso(timestamp: str | None) -> dt.datetime | None:
    if not timestamp:
        return None
    try:
        if "T" in timestamp:
            return dt.datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
        return dt.datetime.fromisoformat(timestamp + "T00:00:00+00:00")
    except Exception:
        return None


def format_display_time(dt_obj: dt.datetime | None) -> str:
    if not dt_obj:
        return "Unknown"
    return dt_obj.strftime("%Y-%m-%d %H:%M UTC")


def build_from_update_events(conn: sqlite3.Connection, cutoff: dt.datetime) -> list[dict[str, Any]]:
    if not table_exists(conn, "update_events"):
        return []

    rows = conn.execute(
        """
        SELECT ue.*, m.name AS mod_name, m.canonical_key,
               COALESCE(NULLIF(ue.source_url, ''), su.url, m.primary_url) AS homepage_url
        FROM update_events ue
        LEFT JOIN mods m ON m.id = ue.mod_id
        LEFT JOIN source_urls su ON su.mod_id = ue.mod_id AND su.is_primary = 1
        WHERE ue.visible_on_site = 1
          AND ue.status IN ('applied', 'ok')
          AND ue.tested_at >= ?
        ORDER BY ue.tested_at DESC, ue.id DESC
        """,
        (cutoff.isoformat(timespec="seconds"),),
    ).fetchall()
    updates = []
    for row in rows:
        tested_at = parse_iso(row["tested_at"])
        mod_name = fetch_mod_name(conn, row["mod_id"], row["mod_name"])
        updates.append({
            "id": f"ue_{row['id']}",
            "source": "update_events",
            "title": clean_title(row["mod_name"] or mod_name),
            "event_type": row["event_type"],
            "status": row["status"],
            "tested_at": row["tested_at"],
            "tested_at_display": format_display_time(tested_at),
            "old_file": row["old_file_name"],
            "new_file": row["new_file_name"],
            "source_url": row["homepage_url"],
            "test_label": row["test_label"],
            "notes": row["notes"],
            "mod_id": row["mod_id"],
        })
    return updates


def build_from_test_runs(conn: sqlite3.Connection, cutoff: dt.datetime) -> list[dict[str, Any]]:
    if not table_exists(conn, "test_runs"):
        return []

    rows = conn.execute(
        """
        SELECT tr.*, m.name AS mod_name, m.canonical_key
        FROM test_runs tr
        LEFT JOIN mods m ON m.id = tr.mod_id
        WHERE tr.mod_id IS NOT NULL
          AND tr.notes NOT LIKE 'Skipped:%'
          AND tr.notes NOT LIKE 'Compatible:%'
          AND tr.tested_at >= ?
        ORDER BY tr.tested_at DESC, tr.id DESC
        """,
        (cutoff.isoformat(timespec="seconds"),),
    ).fetchall()
    updates = []
    for row in rows:
        tested_at = parse_iso(row["tested_at"])
        mod_name = row["mod_name"] or fetch_mod_name(conn, row["mod_id"], row["mod_name"])
        test_label = row["test_label"] or f"test_run_{row['id']}"
        url = fetch_mod_url(conn, row["mod_id"])
        updates.append({
            "id": f"tr_{row['id']}",
            "source": "test_runs",
            "title": clean_title(mod_name),
            "event_type": "server_boot_test",
            "status": "passed",
            "tested_at": row["tested_at"],
            "tested_at_display": format_display_time(tested_at),
            "old_file": None,
            "new_file": None,
            "source_url": url,
            "test_label": test_label,
            "notes": row["notes"],
            "mod_id": row["mod_id"],
        })
    return updates


def build_from_acceptance_blocks(conn: sqlite3.Connection, cutoff: dt.datetime) -> list[dict[str, Any]]:
    if not table_exists(conn, "mod_acceptance_blocks"):
        return []

    rows = conn.execute(
        """
        SELECT b.*, mar.release_key, mar.created_at AS release_created
        FROM mod_acceptance_blocks b
        JOIN mod_acceptance_releases mar ON mar.id = b.acceptance_release_id
        WHERE b.status = 'passed'
          AND b.created_at >= ?
        ORDER BY b.created_at DESC, b.level, b.ordinal
        """,
        (cutoff.isoformat(timespec="seconds"),),
    ).fetchall()
    updates = []
    for row in rows:
        created_at = parse_iso(row["created_at"])
        target_files = row["target_file_names"] or ""
        first_target_file = target_files.split("\n")[0].strip() if target_files else ""
        title = first_target_file if first_target_file else f"Block {row['block_key']}"
        title = fetch_mod_name_from_file(conn, title) if looks_like_file_name(title) else title
        source_url = fetch_mod_url_from_file(conn, first_target_file) if first_target_file else ""
        updates.append({
            "id": f"ab_{row['id']}",
            "source": "mod_acceptance_blocks",
            "title": clean_title(title),
            "event_type": f"acceptance_pyramid_L{row['level']}",
            "status": "passed",
            "tested_at": row["created_at"],
            "tested_at_display": format_display_time(created_at),
            "old_file": None,
            "new_file": target_files,
            "source_url": source_url,
            "test_label": row["block_key"],
            "notes": row["notes"] or f"Level {row['level']} block {row['ordinal']} passed ({row['included_file_names'] or 'N/A'})",
            "mod_id": None,
        })
    return updates


def build_from_headless_client(conn: sqlite3.Connection, cutoff: dt.datetime) -> list[dict[str, Any]]:
    if not table_exists(conn, "headless_client_runs"):
        return []

    rows = conn.execute(
        """
        SELECT *
        FROM headless_client_runs
        WHERE status = 'passed'
          AND started_at >= ?
        ORDER BY started_at DESC
        """,
        (cutoff.isoformat(timespec="seconds"),),
    ).fetchall()
    updates = []
    for row in rows:
        started_at = parse_iso(row["started_at"])
        updates.append({
            "id": f"hc_{row['id']}",
            "source": "headless_client",
            "title": f"Headless client join (release {row['release_id']})",
            "event_type": "headless_client_join",
            "status": "passed",
            "tested_at": row["started_at"],
            "tested_at_display": format_display_time(started_at),
            "old_file": None,
            "new_file": None,
            "source_url": "",
            "test_label": f"hc_{row['id']}",
            "notes": f"Renderer: {row['renderer_summary'] or 'unknown'}; Duration: {row['duration_seconds']}s; Crashes: {row['crash_count']}; Fatal: {row['fatal_log_count']}",
            "mod_id": None,
        })
    return updates


def build_from_pack_releases(conn: sqlite3.Connection, cutoff: dt.datetime) -> list[dict[str, Any]]:
    if not table_exists(conn, "pack_releases"):
        return []

    rows = conn.execute(
        """
        SELECT *
        FROM pack_releases
        WHERE active = 1
          AND created_at >= ?
        ORDER BY created_at DESC
        """,
        (cutoff.isoformat(timespec="seconds"),),
    ).fetchall()
    updates = []
    for row in rows:
        created_at = parse_iso(row["created_at"])
        updates.append({
            "id": f"pr_{row['release_id']}",
            "source": "pack_releases",
            "title": f"Release promoted: {row['release_id']}",
            "event_type": "release_promotion",
            "status": "active",
            "tested_at": row["created_at"],
            "tested_at_display": format_display_time(created_at),
            "old_file": None,
            "new_file": None,
            "source_url": "",
            "test_label": row["release_id"],
            "notes": row["notes"] or "New immutable release activated",
            "mod_id": None,
        })
    return updates


def build_from_mod_acceptance_releases(conn: sqlite3.Connection, cutoff: dt.datetime) -> list[dict[str, Any]]:
    """Include completed acceptance releases as updates."""
    if not table_exists(conn, "mod_acceptance_releases"):
        return []

    rows = conn.execute(
        """
        SELECT *
        FROM mod_acceptance_releases
        WHERE status = 'passed'
          AND completed_at >= ?
        ORDER BY completed_at DESC
        """,
        (cutoff.isoformat(timespec="seconds"),),
    ).fetchall()
    updates = []
    for row in rows:
        completed_at = parse_iso(row["completed_at"])
        updates.append({
            "id": f"mar_{row['id']}",
            "source": "mod_acceptance_releases",
            "title": f"Mod acceptance: {row['release_key']} passed ({row['active_file_count']} files)",
            "event_type": "mod_acceptance",
            "status": "passed",
            "tested_at": row["completed_at"],
            "tested_at_display": format_display_time(completed_at),
            "old_file": None,
            "new_file": None,
            "source_url": "",
            "test_label": row["release_key"],
            "notes": row["notes"] or f"Bundle size: {row['bundle_size']}, Levels: {row['level_count']}",
            "mod_id": None,
        })
    return updates


def deduplicate_updates(updates: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Deduplicate by (mod_id, test_label) or similar, keep the most recent."""
    seen = set()
    deduped = []
    for u in updates:
        key = (u.get("mod_id"), u.get("test_label"), u["source"])
        if key in seen:
            continue
        seen.add(key)
        deduped.append(u)
    return deduped


def main():
    parser = argparse.ArgumentParser(description="Tested Updates Worker")
    parser.add_argument("--db", type=Path, default=DEFAULT_DB, help="SQLite database path")
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT, help="Output JSON path")
    parser.add_argument("--days", type=int, default=UPDATE_LOG_DAYS, help="Days of history to include")
    parser.add_argument("--dry-run", action="store_true", help="Print to stdout instead of writing file")
    args = parser.parse_args()

    cutoff = dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=args.days)

    conn = connect(args.db)

    all_updates = []
    all_updates.extend(build_from_update_events(conn, cutoff))
    all_updates.extend(build_from_test_runs(conn, cutoff))
    all_updates.extend(build_from_acceptance_blocks(conn, cutoff))
    all_updates.extend(build_from_headless_client(conn, cutoff))
    all_updates.extend(build_from_pack_releases(conn, cutoff))
    all_updates.extend(build_from_mod_acceptance_releases(conn, cutoff))

    all_updates = deduplicate_updates(all_updates)
    all_updates.sort(key=lambda u: u.get("tested_at", ""), reverse=True)

    output_data = {
        "generated_at": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
        "cutoff_days": args.days,
        "total_entries": len(all_updates),
        "updates": all_updates[:100],
    }

    if args.dry_run:
        json.dump(output_data, sys.stdout, indent=2)
        print()
    else:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(output_data, indent=2), encoding="utf-8")
        print(f"Wrote {len(all_updates[:100])} updates to {args.output}", file=sys.stderr)


if __name__ == "__main__":
    main()
