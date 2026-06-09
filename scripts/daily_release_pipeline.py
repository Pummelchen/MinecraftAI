#!/usr/bin/env python3
"""Daily update, acceptance, release, distribution, and backup pipeline."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import re
import shutil
import sqlite3
import subprocess
import sys
from pathlib import Path
from typing import Sequence


DEFAULT_DB = Path("/var/minecraft_mods/data/minecraft_mods.sqlite")
DEFAULT_SERVER_DIR = Path("/var/minecraft_26.1.2")
DEFAULT_RELEASE_ROOT = Path("/var/minecraft_mods/releases")
DEFAULT_PUBLIC_DOWNLOADS = Path("/var/minecraft_mods/site/public/downloads")
DEFAULT_RELEASE_BACKUPS = Path("/var/minecraft_mods/release_backups")
DEFAULT_PUBLIC_URL = "http://91.99.176.243:7788"
DEFAULT_SERVER_KEY = "minecraft_26_1_2"
DEFAULT_MINECRAFT_VERSION = "26.1.2"
DEFAULT_NEOFORGE_VERSION = "26.1.2.71"
DEFAULT_STAGING_ROOT = Path("/var/minecraft_mods/.pipeline_staging")

SCRIPT_DIR = Path(__file__).resolve().parent


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")


def release_id_from_key(release_key: str) -> str:
    match = re.fullmatch(r"(\d{4})-(\d{2})-(\d{2})_(V\d+)", release_key, re.IGNORECASE)
    if not match:
        raise SystemExit(f"release key does not map to release id style: {release_key}")
    year, month, day, version = match.groups()
    return f"release_{year}{month}{day}_{version.upper()}_daily"


def run(cmd: Sequence[str], *, dry_run: bool) -> subprocess.CompletedProcess[str]:
    print("pipeline_cmd=" + " ".join(str(part) for part in cmd), flush=True)
    if dry_run:
        return subprocess.CompletedProcess(list(cmd), 0, "", "")
    return subprocess.run(list(cmd), check=True, text=True)


def run_capture(cmd: Sequence[str], *, dry_run: bool) -> subprocess.CompletedProcess[str]:
    print("pipeline_cmd=" + " ".join(str(part) for part in cmd), flush=True)
    if dry_run:
        return subprocess.CompletedProcess(list(cmd), 0, "", "")
    return subprocess.run(list(cmd), check=True, text=True, capture_output=True)


def default_pipeline_server_key(server_key: str) -> str:
    return f"{server_key}_pipeline"


def safe_stage_name(value: str) -> str:
    return re.sub(r"[^A-Za-z0-9._-]+", "_", value).strip("_")


def prepare_staging_server(source_server: Path, stage_root: Path, release_key: str, started_at: str, *, dry_run: bool) -> Path:
    stage_dir = stage_root / f"daily_{safe_stage_name(release_key)}_{safe_stage_name(started_at)}"
    if dry_run:
        print(f"pipeline_stage_server={stage_dir}")
        return stage_dir

    if not source_server.exists():
        raise SystemExit(f"source server directory missing for staging: {source_server}")

    if stage_dir.exists():
        shutil.rmtree(stage_dir)
    stage_dir.mkdir(parents=True, exist_ok=True)
    excluded = {
        "data",
        "logs",
        "crash-reports",
        "mods.failed",
        "mods.rollback",
        "mods.profiled-out",
        "mods.backup",
        "mods.disabled",
        "mods.quarantine",
        "client-package.rollback",
        "client-package.failed",
        "server-test-results",
        "server-datapacks.rollback",
        "server-datapacks.failed",
        "world",
        "world_nether",
        "world_the_end",
        "mods.test",
        "mod_acceptance_lab",
        "headless_client_lab",
        "modpack_backups",
        "codex-downloads",
        "client_log_uploads",
        "release_backups",
        "tmp",
        "tmpfs",
    }

    for item in sorted(source_server.iterdir()):
        if item.name in excluded:
            continue
        destination = stage_dir / item.name
        if item.is_dir() and not item.is_symlink():
            shutil.copytree(item, destination, symlinks=True, dirs_exist_ok=True)
        elif item.is_file():
            if destination.exists():
                destination.unlink()
            shutil.copy2(item, destination)

    # Ensure required runtime directories are available for isolated tests and packaging.
    for name in ("mods", "server-datapacks", "client-package", "libraries", "config", "defaultconfigs"):
        source = source_server / name
        target = stage_dir / name
        if source.exists() and not target.exists():
            if source.is_dir() and not source.is_symlink():
                shutil.copytree(source, target, symlinks=True, dirs_exist_ok=True)
            elif source.is_file():
                shutil.copy2(source, target)

    print(f"pipeline_stage_server={stage_dir}")
    return stage_dir


def parse_metric(output: str, metric: str, default: int = 0) -> int:
    match = re.search(rf"^{re.escape(metric)}=(\d+)", output, flags=re.MULTILINE)
    return int(match.group(1)) if match else default


def sqlite_row(db: Path, query: str, params: Sequence[object] = ()) -> sqlite3.Row | None:
    conn = sqlite3.connect(db, timeout=30.0)
    conn.row_factory = sqlite3.Row
    try:
        return conn.execute(query, params).fetchone()
    finally:
        conn.close()


def active_release_id(db: Path, server_key: str) -> str:
    row = sqlite_row(
        db,
        """
        SELECT release_id
        FROM pack_releases
        WHERE server_key = ? AND active = 1
        ORDER BY activated_at DESC, created_at DESC
        LIMIT 1
        """,
        (server_key,),
    )
    return str(row["release_id"]) if row else ""


def next_release_key(db: Path) -> str:
    today = dt.datetime.now(dt.timezone.utc)
    dashed = today.strftime("%Y-%m-%d")
    compact = today.strftime("%Y%m%d")
    highest = 0
    conn = sqlite3.connect(db)
    try:
        for (value,) in conn.execute(
            "SELECT release_key FROM mod_acceptance_releases WHERE release_key LIKE ?",
            (f"{dashed}_V%",),
        ):
            match = re.fullmatch(rf"{re.escape(dashed)}_V(\d+)", str(value), re.IGNORECASE)
            if match:
                highest = max(highest, int(match.group(1)))
        for (value,) in conn.execute(
            "SELECT release_id FROM pack_releases WHERE release_id LIKE ?",
            (f"release_{compact}_V%",),
        ):
            match = re.fullmatch(rf"release_{compact}_V(\d+)(?:_.+)?", str(value), re.IGNORECASE)
            if match:
                highest = max(highest, int(match.group(1)))
    except sqlite3.Error:
        pass
    finally:
        conn.close()
    return f"{dashed}_V{highest + 1}"


def latest_update_run(db: Path, *, started_at: str, trigger: str) -> sqlite3.Row | None:
    return sqlite_row(
        db,
        """
        SELECT *
        FROM update_runs
        WHERE trigger_type = ? AND started_at >= ?
        ORDER BY started_at DESC, id DESC
        LIMIT 1
        """,
        (trigger, started_at),
    )


def latest_acceptance(db: Path, release_key: str) -> sqlite3.Row:
    row = sqlite_row(
        db,
        """
        SELECT *
        FROM mod_acceptance_releases
        WHERE release_key = ?
        ORDER BY created_at DESC, id DESC
        LIMIT 1
        """,
        (release_key,),
    )
    if not row:
        raise SystemExit(f"acceptance release not found: {release_key}")
    return row


def rollback_to_release(args: argparse.Namespace, release_id: str, reason: str) -> None:
    if not release_id:
        print(f"rollback_skipped=1\treason=no_active_release\tfailure={reason}", flush=True)
        return
    print(f"rollback_to={release_id}\treason={reason}", flush=True)
    run(
        [
            sys.executable,
            str(SCRIPT_DIR / "release_manager.py"),
            "--db",
            str(args.db),
            "--server-dir",
            str(args.server_dir),
            "--server-key",
            args.server_key,
            "--release-root",
            str(args.release_root),
            "--public-downloads",
            str(args.public_downloads),
            "--actor",
            "daily_release_pipeline",
            "rollback",
            "--release-id",
            release_id,
            "--restore-db",
            "--notes",
            f"Daily pipeline rollback after {reason}.",
        ],
        dry_run=args.dry_run,
    )


def create_release(
    args: argparse.Namespace,
    release_key: str,
    update_run: sqlite3.Row | None,
    *,
    source_server_dir: Path,
    local_mods_changed: int = 0,
) -> str:
    release_id = release_id_from_key(release_key)
    applied = int(update_run["applied"] or 0) if update_run else 0
    failed = int(update_run["failed"] or 0) if update_run else 0
    skipped = int(update_run["skipped"] or 0) if update_run else 0
    notes = (
        f"Daily full pipeline release {release_key}: {applied} update(s) applied, "
        f"{failed} failed candidate(s), {skipped} skipped; server pyramid and top client block passed."
    )
    if local_mods_changed:
        notes += f" {local_mods_changed} project-local mod(s) synced from Pummelchen_Mods."
    run(
        [
            sys.executable,
            str(SCRIPT_DIR / "release_manager.py"),
            "--db",
            str(args.db),
            "--server-dir",
            str(source_server_dir),
            "--server-key",
            args.server_key,
            "--release-root",
            str(args.release_root),
            "--public-downloads",
            str(args.public_downloads),
            "--actor",
            "daily_release_pipeline",
            "create",
            "--release-id",
            release_id,
            "--status",
            "tested",
            "--notes",
            notes,
        ],
        dry_run=args.dry_run,
    )
    return release_id


def run_pipeline(args: argparse.Namespace) -> int:
    started_at = utc_now()
    original_release = active_release_id(args.db, args.server_key) if not args.dry_run else ""
    release_key = args.release_key or (next_release_key(args.db) if not args.dry_run else dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d_V1"))
    pipeline_server_key = args.pipeline_server_key or default_pipeline_server_key(args.server_key)
    stage_server_dir = prepare_staging_server(
        source_server=args.server_dir,
        stage_root=args.pipeline_stage_root,
        release_key=release_key,
        started_at=started_at,
        dry_run=args.dry_run,
    )
    print(f"pipeline_started_at={started_at}", flush=True)
    print(f"pipeline_release_key={release_key}", flush=True)
    print(f"pipeline_stage_server={stage_server_dir}", flush=True)
    print(f"pipeline_server_key={pipeline_server_key}", flush=True)
    if original_release:
        print(f"pipeline_original_release={original_release}", flush=True)

    deployed = False
    try:
        run(
            [
                sys.executable,
                str(SCRIPT_DIR / "daily_update.py"),
                "--db",
                str(args.db),
                "--server-dir",
                str(stage_server_dir),
                "--server-key",
                pipeline_server_key,
                "--timeout",
                str(args.update_timeout),
                "scan-apply",
                "--trigger",
                args.trigger,
                "--limit",
                str(args.scan_limit),
                "--apply-limit",
                str(args.apply_limit),
                "--release-root",
                str(args.release_root),
                "--public-downloads",
                str(args.public_downloads),
                "--no-create-release",
            ],
            dry_run=args.dry_run,
        )

        update_run = None
        applied = 1 if args.dry_run and args.simulate_applied else 0
        if not args.dry_run:
            update_run = latest_update_run(args.db, started_at=started_at, trigger=args.trigger)
            if not update_run:
                raise SystemExit("daily update run was not recorded")
            applied = int(update_run["applied"] or 0)
            print(
                "update_result="
                + json.dumps(
                    {
                        "run_label": update_run["run_label"],
                        "status": update_run["status"],
                        "scanned": update_run["scanned_mods"],
                        "candidates": update_run["candidates"],
                        "applied": update_run["applied"],
                        "failed": update_run["failed"],
                        "skipped": update_run["skipped"],
                    },
                    sort_keys=True,
                ),
                flush=True,
            )

        sync_output = run_capture(
            [
                sys.executable,
                str(SCRIPT_DIR / "sync_pummelchen_mods.py"),
                "--db",
                str(args.db),
                "--project-dir",
                str(args.project_root),
                "--server-dir",
                str(stage_server_dir),
                "--mods-dir",
                str(args.pummelchen_mods_dir),
            ],
            dry_run=args.dry_run,
        )
        local_mods_changed = parse_metric(sync_output.stdout or "", "pummelchen_mods_changed")

        if applied <= 0 and local_mods_changed <= 0:
            run(
                [
                    sys.executable,
                    str(SCRIPT_DIR / "release_manager.py"),
                    "--db",
                    str(args.db),
                    "--server-key",
                    args.server_key,
                    "--public-downloads",
                    str(args.public_downloads),
                    "current-json",
                ],
                dry_run=args.dry_run,
            )
            print("pipeline_status=no_updates", flush=True)
            return 0

        run(
            [
                sys.executable,
                str(SCRIPT_DIR / "mod_acceptance_lab.py"),
                "--db",
                str(args.db),
                "--server-dir",
                str(stage_server_dir),
                "--server-key",
                pipeline_server_key,
                "--lab-root",
                str(args.lab_root),
                "--bundle-size",
                str(args.bundle_size),
                "run-pyramid",
                "--release-key",
                release_key,
                "--boot-timeout",
                str(args.pyramid_boot_timeout),
                "--idle-seconds",
                str(args.pyramid_idle_seconds),
                "--heap-mb",
                str(args.pyramid_heap_mb),
                "--exercise-radius",
                str(args.exercise_radius),
            ],
            dry_run=args.dry_run,
        )

        top_level = 0
        if not args.dry_run:
            acceptance = latest_acceptance(args.db, release_key)
            if acceptance["status"] != "passed":
                raise SystemExit(f"pyramid acceptance did not pass: {acceptance['status']}")
            top_level = max(int(acceptance["level_count"] or 1) - 1, 0)
            print(f"pyramid_passed=1\ttop_level={top_level}", flush=True)

        run(
            [
                sys.executable,
                str(SCRIPT_DIR / "mod_acceptance_lab.py"),
                "--db",
                str(args.db),
                "--server-dir",
                str(stage_server_dir),
                "--server-key",
                pipeline_server_key,
                "--lab-root",
                str(args.lab_root),
                "--bundle-size",
                str(args.bundle_size),
                "run-block-clients",
                "--release-key",
                release_key,
                "--level",
                str(top_level),
                "--client-duration",
                str(args.client_duration),
                "--client-ingame-timeout",
                str(args.client_ingame_timeout),
                "--server-heap-mb",
                str(args.client_server_heap_mb),
                "--client-heap-gb",
                str(args.client_heap_gb),
            ],
            dry_run=args.dry_run,
        )

        run(
            [
                sys.executable,
                str(SCRIPT_DIR / "daily_update.py"),
                "--server-dir",
                str(stage_server_dir),
                "rebuild-client",
            ],
            dry_run=args.dry_run,
        )
        run(
            [
                sys.executable,
                str(SCRIPT_DIR / "check_client_manifest.py"),
                str(stage_server_dir / "client-package"),
                "--strict",
            ],
            dry_run=args.dry_run,
        )
        run(
            [
                sys.executable,
                str(SCRIPT_DIR / "check_client_mod_dependencies.py"),
                str(stage_server_dir / "client-package"),
                "--minecraft-version",
                args.minecraft_version,
                "--neoforge-version",
                args.neoforge_version,
            ],
            dry_run=args.dry_run,
        )

        release_id = create_release(
            args,
            release_key,
            update_run,
            source_server_dir=stage_server_dir,
            local_mods_changed=local_mods_changed,
        )

        run(
            [
                sys.executable,
                str(SCRIPT_DIR / "release_manager.py"),
                "--db",
                str(args.db),
                "--server-dir",
                str(args.server_dir),
                "--server-key",
                args.server_key,
                "--release-root",
                str(args.release_root),
                "--public-downloads",
                str(args.public_downloads),
                "deploy",
                release_id,
                "--notes",
                f"Daily pipeline deployed {release_id}.",
            ],
            dry_run=args.dry_run,
        )
        deployed = True

        run(
            [
                sys.executable,
                str(SCRIPT_DIR / "generate_status_site.py"),
                "--db",
                str(args.db),
                "--server-dir",
                str(args.server_dir),
                "--output-dir",
                str(args.site_output),
                "--public-url",
                args.public_url,
            ],
            dry_run=args.dry_run,
        )
        run(
            [
                sys.executable,
                str(SCRIPT_DIR / "release_manager.py"),
                "--db",
                str(args.db),
                "--server-dir",
                str(args.server_dir),
                "--server-key",
                args.server_key,
                "--release-root",
                str(args.release_root),
                "--public-downloads",
                str(args.public_downloads),
                "--actor",
                "daily_release_pipeline",
                "cleanup",
                "--project-root",
                str(args.project_root),
                "--keep-releases",
                str(args.keep_releases),
                "--include-headless-cache",
            ],
            dry_run=args.dry_run,
        )
        run(
            [
                sys.executable,
                str(SCRIPT_DIR / "backup_releases_local.py"),
                "--release-root",
                str(args.release_root),
                "--output-dir",
                str(args.release_backup_dir),
                "--release-id",
                release_id,
            ],
            dry_run=args.dry_run,
        )
        print(f"pipeline_status=released\trelease_id={release_id}", flush=True)
        return 0
    except Exception as exc:
        print(f"pipeline_status=failed\treason={type(exc).__name__}: {exc}", flush=True)
        if not args.dry_run:
            if deployed:
                rollback_to_release(args, original_release, type(exc).__name__)
        return 1
    finally:
        if not args.dry_run and stage_server_dir.exists():
            shutil.rmtree(stage_server_dir)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", type=Path, default=DEFAULT_DB)
    parser.add_argument("--server-dir", type=Path, default=DEFAULT_SERVER_DIR)
    parser.add_argument("--server-key", default=DEFAULT_SERVER_KEY)
    parser.add_argument("--project-root", type=Path, default=Path("/var/minecraft_mods"))
    parser.add_argument("--release-root", type=Path, default=DEFAULT_RELEASE_ROOT)
    parser.add_argument("--public-downloads", type=Path, default=DEFAULT_PUBLIC_DOWNLOADS)
    parser.add_argument("--site-output", type=Path, default=Path("/var/minecraft_mods/site/public"))
    parser.add_argument("--pipeline-stage-root", type=Path, default=DEFAULT_STAGING_ROOT)
    parser.add_argument("--pipeline-server-key", default="")
    parser.add_argument("--release-backup-dir", type=Path, default=DEFAULT_RELEASE_BACKUPS)
    parser.add_argument("--lab-root", type=Path, default=Path("/var/minecraft_mods/mod_acceptance_lab"))
    parser.add_argument("--pummelchen-mods-dir", type=Path, default=Path("/var/minecraft_mods/Pummelchen_Mods"))
    parser.add_argument("--public-url", default=DEFAULT_PUBLIC_URL)
    parser.add_argument("--minecraft-version", default=DEFAULT_MINECRAFT_VERSION)
    parser.add_argument("--neoforge-version", default=DEFAULT_NEOFORGE_VERSION)
    parser.add_argument("--trigger", default="cron")
    parser.add_argument("--scan-limit", type=int, default=200)
    parser.add_argument("--apply-limit", type=int, default=5)
    parser.add_argument("--update-timeout", type=int, default=900)
    parser.add_argument("--bundle-size", type=int, default=10)
    parser.add_argument("--pyramid-boot-timeout", type=int, default=420)
    parser.add_argument("--pyramid-idle-seconds", type=int, default=60)
    parser.add_argument("--pyramid-heap-mb", type=int, default=2048)
    parser.add_argument("--exercise-radius", type=int, default=2)
    parser.add_argument("--client-duration", type=int, default=360)
    parser.add_argument("--client-ingame-timeout", type=int, default=420)
    parser.add_argument("--client-server-heap-mb", type=int, default=2048)
    parser.add_argument("--client-heap-gb", type=int, default=2)
    parser.add_argument("--keep-releases", type=int, default=1)
    parser.add_argument("--release-key", default="")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--simulate-applied", action="store_true", help="Dry-run the full post-update path.")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    return run_pipeline(build_parser().parse_args(argv))


if __name__ == "__main__":
    raise SystemExit(main())
