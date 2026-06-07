#!/usr/bin/env python3
"""Sync selected mod install flags against the live server and client manifest."""

from __future__ import annotations

import argparse
import re
import sqlite3
import sys
from pathlib import Path
from typing import Sequence

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from moddb import ACTIVE_STATUS_RANKS, connect, init_db, utc_now


DEFAULT_DB = Path("/var/minecraft_mods/data/minecraft_mods.sqlite")
DEFAULT_SERVER_DIR = Path("/var/minecraft_26.1.2")
DEFAULT_REASON = (
    "Removed from current release: jar absent from live server mods and active client manifest"
)


def live_server_files(server_dir: Path) -> set[str]:
    mods_dir = server_dir / "mods"
    if not mods_dir.exists():
        return set()
    return {
        path.name
        for path in mods_dir.iterdir()
        if path.is_file() and path.suffix.lower() in {".jar", ".zip"}
    }


def manifest_files(path: Path, *, section_filter: set[str] | None = None) -> set[str]:
    if not path.exists():
        return set()
    files: set[str] = set()
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) < 2:
            continue
        section, name = parts[0].strip(), parts[1].strip()
        if section_filter and section not in section_filter:
            continue
        if name:
            files.add(name)
    return files


def client_package_files(server_dir: Path) -> set[str]:
    mods_dir = server_dir / "client-package" / "mods"
    if not mods_dir.exists():
        return set()
    return {
        path.name
        for path in mods_dir.iterdir()
        if path.is_file() and path.suffix.lower() in {".jar", ".zip"}
    }


def live_client_files(server_dir: Path, client_manifest: Path | None) -> set[str]:
    candidates = []
    if client_manifest:
        candidates.append(client_manifest)
    candidates.extend(
        [
            server_dir / "client-sync-manifest.tsv",
            server_dir / "client-package" / "client-sync-manifest.tsv",
        ]
    )
    for candidate in candidates:
        files = manifest_files(candidate, section_filter={"mods"})
        if files:
            return files
    return client_package_files(server_dir)


def selected_mods(conn: sqlite3.Connection, pattern: re.Pattern[str]) -> list[sqlite3.Row]:
    return conn.execute(
        """
        SELECT DISTINCT m.*
        FROM mods m
        LEFT JOIN mod_files f ON f.mod_id = m.id
        WHERE lower(m.name) REGEXP ?
           OR lower(m.canonical_key) REGEXP ?
           OR lower(COALESCE(f.file_name, '')) REGEXP ?
        ORDER BY m.name, m.id
        """,
        (pattern.pattern, pattern.pattern, pattern.pattern),
    ).fetchall()


def install_regexp(conn: sqlite3.Connection) -> None:
    conn.create_function(
        "REGEXP",
        2,
        lambda expr, item: 1 if item is not None and re.search(expr, str(item).lower()) else 0,
    )


def append_note(conn: sqlite3.Connection, mod_id: int, note: str) -> None:
    existing = conn.execute("SELECT migration_notes FROM mod_notes WHERE mod_id = ?", (mod_id,)).fetchone()
    notes = str(existing["migration_notes"] or "") if existing else ""
    if note not in notes:
        notes = (notes.rstrip() + "\n" + note).strip() if notes else note
    conn.execute(
        """
        INSERT INTO mod_notes(mod_id, migration_notes)
        VALUES (?, ?)
        ON CONFLICT(mod_id) DO UPDATE SET migration_notes = excluded.migration_notes
        """,
        (mod_id, notes),
    )


def sync_mod(
    conn: sqlite3.Connection,
    mod: sqlite3.Row,
    *,
    server_files: set[str],
    client_files: set[str],
    server_dir: Path,
    reason: str,
    dry_run: bool,
) -> tuple[int, int]:
    changed_files = 0
    changed_mods = 0
    mod_id = int(mod["id"])
    rows = conn.execute(
        """
        SELECT id, file_name, installed_on_server, included_in_client, path_hint
        FROM mod_files
        WHERE mod_id = ?
        ORDER BY id
        """,
        (mod_id,),
    ).fetchall()
    for row in rows:
        file_name = str(row["file_name"])
        expected_server = 1 if file_name in server_files else 0
        expected_client = 1 if file_name in client_files else 0
        current_server = int(row["installed_on_server"] or 0)
        current_client = int(row["included_in_client"] or 0)
        if expected_server == current_server and expected_client == current_client:
            continue
        changed_files += 1
        print(
            "file_sync"
            f"\tmod_id={mod_id}"
            f"\tname={mod['name']}"
            f"\tfile={file_name}"
            f"\tserver={current_server}->{expected_server}"
            f"\tclient={current_client}->{expected_client}"
        )
        if not dry_run:
            path_hint = str(server_dir / "mods") if expected_server else str(row["path_hint"] or "")
            conn.execute(
                """
                UPDATE mod_files
                SET installed_on_server = ?, included_in_client = ?, path_hint = ?
                WHERE id = ?
                """,
                (expected_server, expected_client, path_hint, int(row["id"])),
            )

    server_count = sum(1 for row in rows if str(row["file_name"]) in server_files)
    client_count = sum(1 for row in rows if str(row["file_name"]) in client_files)
    stale_active = str(mod["active_status"] or "") == "ok" or str(mod["client_package"] or "").lower() == "included"
    if server_count == 0 and client_count == 0 and stale_active:
        changed_mods = 1
        print(f"mod_status\tmod_id={mod_id}\tname={mod['name']}\tstatus={mod['active_status']}->failed")
        if not dry_run:
            now = utc_now()
            conn.execute(
                """
                UPDATE mods
                SET tested = 'Failed',
                    server_status = ?,
                    client_package = 'Not included',
                    active_status = 'failed',
                    status_rank = ?,
                    updated_at = ?
                WHERE id = ?
                """,
                (f"Rejected: {reason}", ACTIVE_STATUS_RANKS["failed"], now, mod_id),
            )
            append_note(conn, mod_id, f"{now}: {reason}. Synced by sync_mod_install_state.py.")
    return changed_files, changed_mods


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", type=Path, default=DEFAULT_DB)
    parser.add_argument("--server-dir", type=Path, default=DEFAULT_SERVER_DIR)
    parser.add_argument("--client-manifest", type=Path)
    parser.add_argument(
        "--filter-regex",
        required=True,
        help="Case-insensitive regex matched against mod name, canonical key, and file name.",
    )
    parser.add_argument("--reason", default=DEFAULT_REASON)
    parser.add_argument("--apply", action="store_true", help="Write changes. Default is dry-run.")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    pattern = re.compile(args.filter_regex.lower())
    server_files = live_server_files(args.server_dir)
    client_files = live_client_files(args.server_dir, args.client_manifest)
    dry_run = not args.apply
    with connect(args.db) as conn:
        init_db(conn)
        install_regexp(conn)
        mods = selected_mods(conn, pattern)
        file_changes = 0
        mod_changes = 0
        for mod in mods:
            changed_files, changed_mods = sync_mod(
                conn,
                mod,
                server_files=server_files,
                client_files=client_files,
                server_dir=args.server_dir,
                reason=args.reason,
                dry_run=dry_run,
            )
            file_changes += changed_files
            mod_changes += changed_mods
        if dry_run:
            conn.rollback()
        else:
            conn.commit()
    print(f"matched_mods={len(mods)}")
    print(f"file_changes={file_changes}")
    print(f"mod_status_changes={mod_changes}")
    print(f"dry_run={1 if dry_run else 0}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
