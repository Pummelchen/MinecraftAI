#!/usr/bin/env python3
"""Create, validate, activate, and roll back immutable Pummelchen pack releases."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Iterable, Sequence

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from minecraft_metrics_exporter import rcon_command, rcon_settings
from moddb import connect, init_db, utc_now
from pummelchen_utils import MRPACK_NAME, sha256_file, write_json_atomic


DEFAULT_DB = Path("/var/minecraft_mods/data/minecraft_mods.sqlite")
DEFAULT_SERVER_DIR = Path("/var/minecraft_26.1.2")
DEFAULT_RELEASE_ROOT = Path("/var/minecraft_mods/releases")
DEFAULT_PUBLIC_DOWNLOADS = Path("/var/minecraft_mods/site/public/downloads")
DEFAULT_PROJECT_ROOT = Path("/var/minecraft_mods")
DEFAULT_CLIENT_UPLOADS = Path("/var/minecraft_mods/client_log_uploads")
DEFAULT_SERVER_KEY = "minecraft_26_1_2"
CLIENT_ZIP_NAME = "minecraft_26.1.2_client_macos_apple_silicon.zip"
DMG_NAME = "Pummelchen-Client-Installer.dmg"
LEGACY_SERVER_BACKUP = Path("/var/minecraft")
DEFAULT_RELEASE_SERVICE = "pummelchen-minecraft.service"
DEFAULT_RCON_HOST = "127.0.0.1"
DEFAULT_RCON_PORT = 25575
DEFAULT_RCON_TIMEOUT = 2.5
DEFAULT_PLAYER_WAIT_TIMEOUT = 120
DEFAULT_PLAYER_CHECK_INTERVAL = 15.0
DEFAULT_PLAYER_WARNING_INTERVAL = 60.0
SERVICE_STOP_TIMEOUT = 45
SERVICE_FORCE_TIMEOUT = 15
SERVICE_START_TIMEOUT = 120

RELEASE_PLAYERS_RE = re.compile(r"there are\s+(\d+)\s+of a max of", re.IGNORECASE)


def record_release_event(
    conn: sqlite3.Connection,
    rel_id: str,
    event_type: str,
    status: str,
    actor: str,
    notes: str = "",
) -> None:
    conn.execute(
        "INSERT INTO release_events(release_id, event_at, event_type, status, actor, notes) VALUES (?, ?, ?, ?, ?, ?)",
        (rel_id, utc_now(), event_type, status, actor, notes),
    )


def _rcon_settings(args: argparse.Namespace) -> tuple[str, int, str] | None:
    settings = rcon_settings(args.server_dir, args.rcon_password_file, args.rcon_port)
    if not settings:
        return None
    return args.rcon_host, settings[0], settings[1]


def _rcon_send_command(host: str, port: int, password: str, command: str, timeout: float) -> bool:
    rcon_command(host, port, password, command, timeout)
    return True


def _extract_player_count(text: str) -> int | None:
    for line in text.splitlines():
        match = RELEASE_PLAYERS_RE.search(line.strip())
        if match:
            return int(match.group(1))
    lowered = text.lower()
    if "no players are currently online" in lowered or "there are 0 of a max of" in lowered:
        return 0
    return None


def _query_players(host: str, port: int, password: str, timeout: float) -> int | None:
    response = rcon_command(host, port, "list", timeout)
    return _extract_player_count(response)


def _broadcast_update_message(host: str, port: int, password: str, message: str, timeout: float) -> bool:
    return _rcon_send_command(host, port, password, f"say {message}", timeout)


def _save_world_state(host: str, port: int, password: str, timeout: float) -> None:
    try:
        _rcon_send_command(host, port, password, "save-all flush", timeout)
    except Exception:
        _rcon_send_command(host, port, password, "save-all", timeout)


def _systemctl_supported_for_env() -> bool:
    return (
        shutil.which("systemctl") is not None
        and os.name == "posix"
        and Path("/run/systemd/system").is_dir()
    )


def _service_is_running(service: str) -> bool:
    return (
        subprocess.run(
            ["systemctl", "is-active", "--quiet", service],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        ).returncode
        == 0
    )


def _wait_for_service_state(service: str, target_running: bool, timeout_seconds: int) -> bool:
    end_at = time.time() + timeout_seconds
    while time.time() < end_at:
        if _service_is_running(service) == target_running:
            return True
        time.sleep(1)
    return _service_is_running(service) == target_running


def _stop_service(service: str, dry_run: bool) -> bool:
    if dry_run:
        print(f"DRY-RUN systemctl stop {service}")
        return True
    try:
        subprocess.run(["systemctl", "stop", service], check=False, timeout=SERVICE_STOP_TIMEOUT)
    except subprocess.TimeoutExpired:
        pass
    if _wait_for_service_state(service, False, SERVICE_STOP_TIMEOUT):
        return True
    subprocess.run(
        ["systemctl", "kill", "--kill-whom=main", "--signal=SIGKILL", service],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    if _wait_for_service_state(service, False, SERVICE_FORCE_TIMEOUT):
        return True
    subprocess.run(
        ["systemctl", "kill", "--kill-whom=all", "--signal=SIGKILL", service],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    if _wait_for_service_state(service, False, SERVICE_FORCE_TIMEOUT):
        return True
    return False


def _start_service(service: str, dry_run: bool) -> bool:
    if dry_run:
        print(f"DRY-RUN systemctl start {service}")
        return True
    try:
        subprocess.run(["systemctl", "start", service], check=False, timeout=SERVICE_START_TIMEOUT)
    except subprocess.TimeoutExpired:
        return False
    return _wait_for_service_state(service, True, SERVICE_START_TIMEOUT)


def _send_restart_notice(
    conn: sqlite3.Connection,
    rel_id: str,
    actor: str,
    status: str,
    notes: str,
) -> None:
    record_release_event(conn, rel_id, "restart", status, actor, notes)
    if status == "ok":
        print(f"release_restart={status}\trelease={rel_id}\tnotes={notes}")
    elif status == "warn":
        print(f"release_restart={status}\trelease={rel_id}\twarning={notes}")
    else:
        print(f"release_restart={status}\trelease={rel_id}\t{notes}")


def coordinate_release_restart(conn: sqlite3.Connection, rel_id: str, args: argparse.Namespace, payload: dict[str, Any]) -> bool:
    actor = getattr(args, "actor", "release_manager")
    service = args.service
    dry_run = getattr(args, "dry_run", False)
    if not _systemctl_supported_for_env():
        record_release_event(
            conn,
            rel_id,
            "restart",
            "warn",
            actor,
            "systemctl unavailable (non-systemd environment); release published without restart",
        )
        _send_restart_notice(
            conn,
            rel_id,
            actor,
            "warn",
            f"systemctl unavailable; skipping restart for service={service}",
        )
        return True
    timeout = float(args.rcon_timeout)
    settings = _rcon_settings(args)
    host: str | None = None
    port: int | None = None
    password: str | None = None

    if settings:
        host, port, password = settings
    if host and port and password:
        try:
            release_id = payload.get("release_id", rel_id)
            wait_seconds = int(args.player_wait_timeout)
            message = (
                f"Update required now: {release_id}. "
                f"Server will restart in {wait_seconds}s for all clients to get the latest pack."
            )
            _broadcast_update_message(host, port, password, message, timeout)
            players = _query_players(host, port, password, timeout)
            record_release_event(
                conn,
                rel_id,
                "announce",
                "ok",
                actor,
                f"players_at_start={players or 0}; waiting_fixed_window={wait_seconds}s for release {release_id}",
            )
            until = time.time() + wait_seconds
            next_warning = 0.0
            while time.time() < until:
                remaining = int(until - time.time())
                if time.time() >= next_warning:
                    warning = (
                        f"Update required now: server restart in {remaining}s for release {release_id}. "
                        "Please exit now so this update can complete."
                    )
                    _broadcast_update_message(host, port, password, warning, timeout)
                    next_warning = time.time() + max(1.0, args.player_warning_interval)
                time.sleep(max(1.0, args.player_check_interval))
                players = _query_players(host, port, password, timeout)
            if players is not None:
                record_release_event(
                    conn,
                    rel_id,
                    "announce",
                    "warn" if players > 0 else "ok",
                    actor,
                    f"players_at_restart={players}" if players is not None else "players_unknown",
                )
            _save_world_state(host, port, password, timeout)
            if _stop_service(service, dry_run):
                if _start_service(service, dry_run):
                    _send_restart_notice(
                        conn,
                        rel_id,
                        actor,
                        "ok",
                        f"service_restart_complete service={service} release={release_id}",
                    )
                    return True
                _send_restart_notice(
                    conn,
                    rel_id,
                    actor,
                    "failed",
                    f"service_start_failed service={service} release={release_id}",
                )
                return False
            _send_restart_notice(
                conn,
                rel_id,
                actor,
                "failed",
                f"service_stop_failed service={service} release={release_id}",
            )
            return False
        except Exception as exc:
            record_release_event(
                conn,
                rel_id,
                "announce",
                "warn",
                actor,
                f"rcon_path_failed release={payload.get('release_id', rel_id)} error={exc}",
            )
            host = None
            port = None
            password = None
    if not (host and port and password):
        return _coordinate_release_restart_without_rcon(conn, rel_id, args, payload)


def _coordinate_release_restart_without_rcon(
    conn: sqlite3.Connection, rel_id: str, args: argparse.Namespace, payload: dict[str, Any]
) -> bool:
    release_id = payload.get("release_id", rel_id)
    actor = getattr(args, "actor", "release_manager")
    service = args.service
    dry_run = getattr(args, "dry_run", False)
    record_release_event(
        conn,
        rel_id,
        "announce",
        "warn",
        actor,
        "rcon_unavailable; applying update without player drain notification",
    )
    if _stop_service(service, dry_run):
        if _start_service(service, dry_run):
            _send_restart_notice(
                conn,
                rel_id,
                actor,
                "ok",
                f"service_restart_complete service={service} release={release_id}",
            )
            return True
    _send_restart_notice(
        conn,
        rel_id,
        actor,
        "failed",
        f"service_restart_failed service={service} release={release_id}",
    )
    return False

def path_size(path: Path) -> int:
    if not path.exists() and not path.is_symlink():
        return 0
    if path.is_file() or path.is_symlink():
        try:
            return path.lstat().st_size
        except OSError:
            return 0
    total = 0
    for root, dirs, files in os.walk(path, followlinks=False):
        for name in dirs:
            candidate = Path(root) / name
            if candidate.is_symlink():
                try:
                    total += candidate.lstat().st_size
                except OSError:
                    pass
        for name in files:
            candidate = Path(root) / name
            try:
                total += candidate.lstat().st_size
            except OSError:
                pass
    return total


def ensure_path_inside(path: Path, root: Path, label: str) -> None:
    """Safely check if path is inside root without following symlinks."""
    root_resolved = root.resolve()
    try:
        path_resolved = path.resolve(strict=False)
    except OSError:
        path_resolved = path.parent.resolve() / path.name
    try:
        path_resolved.relative_to(root_resolved)
    except ValueError as exc:
        raise SystemExit(f"refusing to clean {label} outside {root}: {path}") from exc


def is_older_than(path: Path, age_hours: float, now: float | None = None) -> bool:
    if age_hours <= 0:
        return True
    now = now or time.time()
    try:
        return now - path.lstat().st_mtime >= age_hours * 3600
    except OSError:
        return False


def remove_path(path: Path, *, dry_run: bool, reason: str) -> int:
    if not path.exists() and not path.is_symlink():
        return 0
    bytes_count = path_size(path)
    print(f"cleanup_removed={path}\tbytes={bytes_count}\treason={reason}")
    if dry_run:
        return bytes_count
    if path.is_dir() and not path.is_symlink():
        shutil.rmtree(path)
    else:
        path.unlink()
    return bytes_count


def hardlink_or_copy(src: Path, dst: Path) -> None:
    dst.parent.mkdir(parents=True, exist_ok=True)
    if dst.exists() or dst.is_symlink():
        dst.unlink()
    try:
        os.link(src, dst)
    except OSError:
        shutil.copy2(src, dst)


def copy_tree_with_links(src: Path, dst: Path) -> None:
    if dst.exists():
        shutil.rmtree(dst)
    dst.mkdir(parents=True, exist_ok=True)
    if not src.exists():
        return
    for path in sorted(src.rglob("*")):
        rel = path.relative_to(src)
        target = dst / rel
        if path.is_dir():
            target.mkdir(parents=True, exist_ok=True)
        elif path.is_file():
            hardlink_or_copy(path, target)


def normalize_public_permissions(root: Path) -> None:
    if not root.exists():
        return
    root.chmod(0o755)
    for path in sorted(root.rglob("*")):
        if path.is_dir():
            path.chmod(0o755)
        elif path.is_file():
            path.chmod(0o644)


VERSIONED_RELEASE_ID_RE = re.compile(r"^release_(\d{8})_V(\d+)(?:_.+)?$", re.IGNORECASE)


def clean_release_suffix(label: str | None = None) -> str:
    if label:
        clean = re.sub(r"[^A-Za-z0-9_.-]+", "-", label).strip("-")
        if clean:
            return clean[:40]
    return ""


def next_versioned_release_id(release_root: Path, db_path: Path, server_key: str, label: str | None = None) -> str:
    today = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%d")
    highest = 0
    candidates: set[str] = set()
    if release_root.exists():
        candidates.update(path.name for path in release_root.iterdir() if path.is_dir())
    try:
        with connect(db_path) as conn:
            init_db(conn)
            candidates.update(
                str(row["release_id"])
                for row in conn.execute(
                    "SELECT release_id FROM pack_releases WHERE server_key = ? AND release_id LIKE ?",
                    (server_key, f"release_{today}_V%"),
                )
            )
    except sqlite3.Error:
        pass
    for candidate in candidates:
        match = VERSIONED_RELEASE_ID_RE.fullmatch(candidate)
        if match and match.group(1) == today:
            highest = max(highest, int(match.group(2)))
    base = f"release_{today}_V{highest + 1}"
    suffix = clean_release_suffix(label)
    return f"{base}_{suffix}" if suffix else base


def git_commit() -> str:
    try:
        return subprocess.check_output(["git", "rev-parse", "HEAD"], text=True, stderr=subprocess.DEVNULL, timeout=5).strip()
    except Exception:
        return ""


def detect_neoforge(server_dir: Path) -> str:
    root = server_dir / "libraries" / "net" / "neoforged" / "neoforge"
    if not root.exists():
        return ""
    versions = sorted(path.name for path in root.iterdir() if path.is_dir())
    return versions[-1] if versions else ""


def infer_minecraft(loader_version: str) -> str:
    parts = loader_version.split(".")
    if len(parts) >= 3:
        return ".".join(parts[:3])
    return "26.1.2"


def iter_files(folder: Path, patterns: Sequence[str]) -> list[Path]:
    if not folder.exists():
        return []
    files: list[Path] = []
    for pattern in patterns:
        files.extend(path for path in folder.glob(pattern) if path.is_file())
    return sorted(set(files), key=lambda path: path.name.lower())


def write_manifest(rows: Iterable[tuple[str, Path, Path]], output: Path) -> str:
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", encoding="utf-8") as handle:
        handle.write("role\trelative_path\tsize_bytes\tsha256\n")
        for role, root, path in rows:
            rel = path.relative_to(root)
            handle.write(f"{role}\t{rel.as_posix()}\t{path.stat().st_size}\tsha256:{sha256_file(path)}\n")
    return sha256_file(output)


def backup_sqlite(db_path: Path, output: Path) -> str:
    output.parent.mkdir(parents=True, exist_ok=True)
    source = sqlite3.connect(db_path)
    try:
        target = sqlite3.connect(output)
        try:
            source.backup(target)
        finally:
            target.close()
    finally:
        source.close()
    return sha256_file(output)


def current_release(conn: sqlite3.Connection, server_key: str) -> sqlite3.Row | None:
    return conn.execute(
        "SELECT * FROM pack_releases WHERE server_key = ? AND active = 1 ORDER BY activated_at DESC LIMIT 1",
        (server_key,),
    ).fetchone()


def release_row(conn: sqlite3.Connection, rel_id: str) -> sqlite3.Row:
    row = conn.execute("SELECT * FROM pack_releases WHERE release_id = ?", (rel_id,)).fetchone()
    if not row:
        raise SystemExit(f"release not found: {rel_id}")
    return row


def insert_artifact(
    conn: sqlite3.Connection,
    rel_id: str,
    role: str,
    release_dir: Path,
    path: Path,
    source_path: Path | None = None,
) -> None:
    rel = path.relative_to(release_dir).as_posix()
    conn.execute(
        """
        INSERT INTO release_artifacts(
            release_id, artifact_role, relative_path, source_path, size_bytes,
            sha256, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(release_id, artifact_role, relative_path) DO UPDATE SET
            source_path = excluded.source_path,
            size_bytes = excluded.size_bytes,
            sha256 = excluded.sha256,
            created_at = excluded.created_at
        """,
        (
            rel_id,
            role,
            rel,
            str(source_path or ""),
            path.stat().st_size,
            sha256_file(path),
            utc_now(),
        ),
    )


def ensure_release_schema(db_path: Path) -> None:
    with connect(db_path) as conn:
        init_db(conn)


def build_public_release(release_dir: Path, release_id_value: str) -> None:
    client_package = release_dir / "client-package"
    public = release_dir / "public"
    client_files = public / "client-files"
    if public.exists():
        shutil.rmtree(public)
    public.mkdir(parents=True, exist_ok=True)
    rows = ["# Pummelchen release client sync manifest v1", "# section\tname\tsize\tsha256\turl_path"]
    for section in ("mods", "resourcepacks", "shaderpacks", "tools"):
        source_dir = client_package / section
        if not source_dir.exists():
            continue
        for src in sorted(source_dir.iterdir(), key=lambda path: path.name.lower()):
            if not src.is_file() or src.name == "upload-token.txt":
                continue
            if section == "tools" and src.name in {"upload-token.txt", "upload-token.txt.example"}:
                continue
            target = client_files / section / src.name
            hardlink_or_copy(src, target)
            file_hash = sha256_file(src)
            url_path = f"downloads/releases/{release_id_value}/client-files/{section}/{src.name}"
            rows.append(f"{section}\t{src.name}\t{src.stat().st_size}\tsha256:{file_hash}\t{url_path}")
    (public / "client-sync-manifest.tsv").write_text("\n".join(rows) + "\n", encoding="utf-8")
    for src_name, public_name in (
        (CLIENT_ZIP_NAME, CLIENT_ZIP_NAME),
        (f"{CLIENT_ZIP_NAME}.sha256", f"{CLIENT_ZIP_NAME}.sha256"),
        (MRPACK_NAME, MRPACK_NAME),
        (DMG_NAME, DMG_NAME),
        (f"{DMG_NAME}.sha256", f"{DMG_NAME}.sha256"),
    ):
        src = release_dir / "artifacts" / src_name
        if src.exists():
            hardlink_or_copy(src, public / public_name)
    normalize_public_permissions(public)


def publish_release(
    conn: sqlite3.Connection,
    rel_id: str,
    *,
    public_downloads: Path,
) -> dict[str, Any]:
    row = release_row(conn, rel_id)
    release_dir = Path(row["release_dir"])
    build_public_release(release_dir, rel_id)
    releases_dir = public_downloads / "releases"
    releases_dir.mkdir(parents=True, exist_ok=True)
    public_downloads.chmod(0o755)
    releases_dir.chmod(0o755)
    public_link = releases_dir / rel_id
    if public_link.exists() or public_link.is_symlink():
        if public_link.is_dir() and not public_link.is_symlink():
            shutil.rmtree(public_link)
        else:
            public_link.unlink()
    try:
        public_link.symlink_to(release_dir / "public", target_is_directory=True)
    except OSError:
        shutil.copytree(release_dir / "public", public_link)
        normalize_public_permissions(public_link)

    payload = {
        "release_id": rel_id,
        "created_at": row["created_at"],
        "activated_at": row["activated_at"],
        "status": row["status"],
        "minecraft_version": row["minecraft_version"],
        "loader_version": row["loader_version"],
        "server_key": row["server_key"],
        "manifest_url": f"/downloads/releases/{rel_id}/client-sync-manifest.tsv",
        "client_zip_url": f"/downloads/releases/{rel_id}/{CLIENT_ZIP_NAME}",
        "client_zip_sha256": row["client_zip_sha256"],
        "mrpack_url": f"/downloads/releases/{rel_id}/{MRPACK_NAME}",
        "mrpack_sha256": row["mrpack_sha256"],
        "notes": row["notes"] or "",
    }
    write_json_atomic(public_downloads / "current-release.json", payload)
    (public_downloads / "current-release.txt").write_text(rel_id + "\n", encoding="utf-8")
    (public_downloads / "current-release.json").chmod(0o644)
    (public_downloads / "current-release.txt").chmod(0o644)
    return payload


def create_release(args: argparse.Namespace) -> int:
    ensure_release_schema(args.db)
    rel_id = args.release_id or next_versioned_release_id(args.release_root, args.db, args.server_key, args.label)
    if not re.fullmatch(r"[A-Za-z0-9._-]+", rel_id):
        raise SystemExit(f"invalid release id (only alphanumeric, dot, dash, underscore allowed): {rel_id!r}")
    release_dir = args.release_root / rel_id
    ensure_path_inside(release_dir, args.release_root, "release directory")
    if release_dir.exists():
        raise SystemExit(f"release directory already exists: {release_dir}")
    release_dir.mkdir(parents=True)

    loader_version = detect_neoforge(args.server_dir)
    minecraft_version = args.minecraft_version or infer_minecraft(loader_version)
    changelog = args.changelog or f"# {rel_id}\n\nStatus: {args.status}\n\n{args.notes or 'No changelog notes provided.'}\n"
    (release_dir / "CHANGELOG.md").write_text(changelog.rstrip() + "\n", encoding="utf-8")

    copy_tree_with_links(args.server_dir / "mods", release_dir / "server-files" / "mods")
    copy_tree_with_links(args.server_dir / "server-datapacks", release_dir / "server-files" / "server-datapacks")
    copy_tree_with_links(args.server_dir / "client-package", release_dir / "client-package")

    server_manifest_rows: list[tuple[str, Path, Path]] = []
    for role, root, patterns in (
        ("server_mod", release_dir / "server-files" / "mods", ("*.jar", "*.zip")),
        ("server_datapack", release_dir / "server-files" / "server-datapacks", ("*.jar", "*.zip")),
    ):
        for path in iter_files(root, patterns):
            server_manifest_rows.append((role, root, path))
    server_manifest_sha = write_manifest(server_manifest_rows, release_dir / "manifests" / "server-files.tsv")

    client_manifest_rows: list[tuple[str, Path, Path]] = []
    for section in ("mods", "resourcepacks", "shaderpacks", "tools"):
        root = release_dir / "client-package" / section
        patterns = ("*",) if section == "tools" else ("*.jar", "*.zip")
        for path in iter_files(root, patterns):
            client_manifest_rows.append((f"client_{section}", root, path))
    client_manifest_sha = write_manifest(client_manifest_rows, release_dir / "manifests" / "client-package.tsv")

    artifacts = release_dir / "artifacts"
    artifacts.mkdir(exist_ok=True)
    artifact_sources = [
        (args.server_dir / CLIENT_ZIP_NAME, CLIENT_ZIP_NAME),
        (args.server_dir / f"{CLIENT_ZIP_NAME}.sha256", f"{CLIENT_ZIP_NAME}.sha256"),
        (args.server_dir / MRPACK_NAME, MRPACK_NAME),
        (args.server_dir / DMG_NAME, DMG_NAME),
        (args.server_dir / f"{DMG_NAME}.sha256", f"{DMG_NAME}.sha256"),
    ]
    for src, name in artifact_sources:
        if src.exists():
            hardlink_or_copy(src, artifacts / name)

    client_zip_sha = sha256_file(artifacts / CLIENT_ZIP_NAME) if (artifacts / CLIENT_ZIP_NAME).exists() else ""
    mrpack_sha = sha256_file(artifacts / MRPACK_NAME) if (artifacts / MRPACK_NAME).exists() else ""
    db_sha = ""

    with connect(args.db) as conn:
        init_db(conn)
        previous = current_release(conn, args.server_key)
        conn.execute(
            """
            INSERT INTO pack_releases(
                release_id, created_at, server_key, minecraft_version,
                loader_version, server_dir, release_dir, status, active,
                previous_release_id, git_commit, server_manifest_sha256,
                client_manifest_sha256, db_snapshot_sha256, client_zip_sha256,
                mrpack_sha256, changelog_path, notes
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                rel_id,
                utc_now(),
                args.server_key,
                minecraft_version,
                loader_version,
                str(args.server_dir),
                str(release_dir),
                args.status,
                previous["release_id"] if previous else None,
                git_commit(),
                server_manifest_sha,
                client_manifest_sha,
                db_sha,
                client_zip_sha,
                mrpack_sha,
                str(release_dir / "CHANGELOG.md"),
                args.notes or "",
            ),
        )
        for path in [
            release_dir / "CHANGELOG.md",
            release_dir / "metadata.json",
            release_dir / "manifests" / "server-files.tsv",
            release_dir / "manifests" / "client-package.tsv",
            *(path for path in artifacts.iterdir() if path.is_file()),
        ]:
            if path.exists() and path.name != "metadata.json":
                insert_artifact(conn, rel_id, "release_file", release_dir, path)
        conn.execute(
            "INSERT INTO release_events(release_id, event_at, event_type, status, actor, notes) VALUES (?, ?, 'create', ?, ?, ?)",
            (rel_id, utc_now(), args.status, args.actor, args.notes or ""),
        )
        conn.commit()

        db_sha = backup_sqlite(args.db, release_dir / "db" / "minecraft_mods.sqlite")
        conn.execute(
            "UPDATE pack_releases SET db_snapshot_sha256 = ? WHERE release_id = ?",
            (db_sha, rel_id),
        )
        insert_artifact(conn, rel_id, "release_file", release_dir, release_dir / "db" / "minecraft_mods.sqlite")
        conn.commit()

    metadata = {
        "release_id": rel_id,
        "created_at": utc_now(),
        "server_key": args.server_key,
        "minecraft_version": minecraft_version,
        "loader_version": loader_version,
        "status": args.status,
        "server_manifest_sha256": server_manifest_sha,
        "client_manifest_sha256": client_manifest_sha,
        "db_snapshot_sha256": db_sha,
        "client_zip_sha256": client_zip_sha,
        "mrpack_sha256": mrpack_sha,
        "notes": args.notes or "",
    }
    write_json_atomic(release_dir / "metadata.json", metadata)
    with connect(args.db) as conn:
        init_db(conn)
        insert_artifact(conn, rel_id, "release_file", release_dir, release_dir / "metadata.json")
        conn.commit()
    build_public_release(release_dir, rel_id)

    if args.activate:
        activate_release(args, rel_id)
    print(f"release_id={rel_id}")
    print(f"release_dir={release_dir}")
    return 0


def validate_release(args: argparse.Namespace, rel_id: str | None = None) -> int:
    rel_id = rel_id or args.release_id
    with connect(args.db) as conn:
        init_db(conn)
        row = release_row(conn, rel_id)
        problems: list[str] = []
        release_dir = Path(row["release_dir"])
        if not release_dir.exists():
            problems.append(f"missing release_dir: {release_dir}")
        for column, rel_path in (
            ("server_manifest_sha256", "manifests/server-files.tsv"),
            ("client_manifest_sha256", "manifests/client-package.tsv"),
            ("db_snapshot_sha256", "db/minecraft_mods.sqlite"),
        ):
            path = release_dir / rel_path
            if not path.exists():
                problems.append(f"missing {rel_path}")
            elif row[column] and sha256_file(path) != row[column]:
                problems.append(f"checksum mismatch: {rel_path}")
        for artifact_name, column in ((CLIENT_ZIP_NAME, "client_zip_sha256"), (MRPACK_NAME, "mrpack_sha256")):
            expected = row[column] or ""
            path = release_dir / "artifacts" / artifact_name
            if expected and (not path.exists() or sha256_file(path) != expected):
                problems.append(f"artifact checksum mismatch: {artifact_name}")
        for artifact in conn.execute("SELECT relative_path, sha256 FROM release_artifacts WHERE release_id = ?", (rel_id,)):
            path = release_dir / artifact["relative_path"]
            if not path.exists():
                problems.append(f"missing artifact: {artifact['relative_path']}")
            elif artifact["sha256"] and sha256_file(path) != artifact["sha256"]:
                problems.append(f"artifact drift: {artifact['relative_path']}")
    if problems:
        for problem in problems:
            print(f"ERROR {problem}")
        return 1
    print(f"release_valid={rel_id}")
    return 0


def activate_release(args: argparse.Namespace, rel_id: str | None = None) -> int:
    rel_id = rel_id or args.release_id
    if validate_release(args, rel_id) != 0:
        return 1
    actor = getattr(args, "actor", "release_manager")
    with connect(args.db) as conn:
        init_db(conn)
        row = release_row(conn, rel_id)
        conn.execute("UPDATE pack_releases SET active = 0 WHERE server_key = ?", (row["server_key"],))
        conn.execute(
            "UPDATE pack_releases SET active = 1, activated_at = ? WHERE release_id = ?",
            (utc_now(), rel_id),
        )
        conn.execute(
            "INSERT INTO release_events(release_id, event_at, event_type, status, actor, notes) VALUES (?, ?, 'activate', 'ok', ?, ?)",
            (rel_id, utc_now(), actor, getattr(args, "notes", "") or ""),
        )
        conn.commit()
        payload = publish_release(conn, rel_id, public_downloads=args.public_downloads)
        if getattr(args, "no_restart", False):
            record_release_event(
                conn,
                rel_id,
                "restart",
                "skipped",
                actor,
                "skip requested via --no-restart",
            )
        else:
            if not coordinate_release_restart(conn, rel_id, args, payload):
                conn.commit()
                return 1
        conn.commit()
    print(json.dumps(payload, sort_keys=True))
    return 0


def sync_directory_from_release(src: Path, dst: Path, patterns: Sequence[str]) -> None:
    dst.mkdir(parents=True, exist_ok=True)
    wanted = {path.name for path in iter_files(src, patterns)}
    for existing in iter_files(dst, patterns):
        if existing.name not in wanted:
            existing.unlink()
    for source in iter_files(src, patterns):
        hardlink_or_copy(source, dst / source.name)


def rollback_release(args: argparse.Namespace) -> int:
    with connect(args.db) as conn:
        init_db(conn)
        if args.release_id:
            target = release_row(conn, args.release_id)
        else:
            active = current_release(conn, args.server_key)
            if not active or not active["previous_release_id"]:
                raise SystemExit("no previous release recorded")
            target = release_row(conn, active["previous_release_id"])
    rel_id = target["release_id"]
    if validate_release(args, rel_id) != 0:
        return 1
    release_dir = Path(target["release_dir"])
    sync_directory_from_release(release_dir / "server-files" / "mods", args.server_dir / "mods", ("*.jar", "*.zip"))
    sync_directory_from_release(
        release_dir / "server-files" / "server-datapacks",
        args.server_dir / "server-datapacks",
        ("*.jar", "*.zip"),
    )
    if (args.server_dir / "client-package").exists():
        shutil.rmtree(args.server_dir / "client-package")
    copy_tree_with_links(release_dir / "client-package", args.server_dir / "client-package")
    for name in (CLIENT_ZIP_NAME, f"{CLIENT_ZIP_NAME}.sha256", MRPACK_NAME, DMG_NAME, f"{DMG_NAME}.sha256"):
        src = release_dir / "artifacts" / name
        if src.exists():
            hardlink_or_copy(src, args.server_dir / name)
    if args.restore_db:
        backup = args.db.with_suffix(args.db.suffix + f".rollback-backup-{dt.datetime.now(dt.timezone.utc).strftime('%Y%m%d%H%M%S')}")
        shutil.copy2(args.db, backup)
        shutil.copy2(release_dir / "db" / "minecraft_mods.sqlite", args.db)
        print(f"db_backup={backup}")
    result = activate_release(args, rel_id)
    print(f"rolled_back_to={rel_id}")
    return result


def deploy_release(args: argparse.Namespace) -> int:
    rel_id = args.release_id
    if validate_release(args, rel_id) != 0:
        return 1
    with connect(args.db) as conn:
        init_db(conn)
        row = release_row(conn, rel_id)
        release_dir = Path(row["release_dir"])
        if not release_dir.exists():
            raise SystemExit(f"release directory missing for deploy: {release_dir}")

        sync_directory_from_release(
            release_dir / "server-files" / "mods",
            args.server_dir / "mods",
            ("*.jar", "*.zip"),
        )
        sync_directory_from_release(
            release_dir / "server-files" / "server-datapacks",
            args.server_dir / "server-datapacks",
            ("*.jar", "*.zip"),
        )
        if (args.server_dir / "client-package").exists():
            shutil.rmtree(args.server_dir / "client-package")
        copy_tree_with_links(release_dir / "client-package", args.server_dir / "client-package")

        for name in (CLIENT_ZIP_NAME, f"{CLIENT_ZIP_NAME}.sha256", MRPACK_NAME, DMG_NAME, f"{DMG_NAME}.sha256"):
            source = release_dir / "artifacts" / name
            if source.exists():
                hardlink_or_copy(source, args.server_dir / name)

        return_code = activate_release(args, rel_id)
        if return_code != 0:
            return return_code
        print(f"deploy_released={rel_id}")
        return 0


def list_releases(args: argparse.Namespace) -> int:
    with connect(args.db) as conn:
        init_db(conn)
        rows = conn.execute(
            """
            SELECT release_id, created_at, activated_at, status, active,
                   client_zip_sha256, notes
            FROM pack_releases
            WHERE server_key = ?
            ORDER BY created_at DESC
            LIMIT ?
            """,
            (args.server_key, args.limit),
        ).fetchall()
    for row in rows:
        active = "*" if row["active"] else " "
        print(f"{active} {row['release_id']} {row['status']} created={row['created_at']} activated={row['activated_at'] or '-'} zip={row['client_zip_sha256'][:12]}")
    return 0


def show_release(args: argparse.Namespace) -> int:
    with connect(args.db) as conn:
        init_db(conn)
        row = release_row(conn, args.release_id)
        print(json.dumps(dict(row), indent=2, sort_keys=True))
    return 0


def current_json(args: argparse.Namespace) -> int:
    with connect(args.db) as conn:
        init_db(conn)
        row = current_release(conn, args.server_key)
        if not row:
            return 1
        payload = publish_release(conn, row["release_id"], public_downloads=args.public_downloads)
    print(json.dumps(payload, indent=2, sort_keys=True))
    return 0


def safe_remove_release_dir(path: Path, release_root: Path, *, dry_run: bool) -> bool:
    if not path.exists():
        return False
    release_root_resolved = release_root.resolve()
    try:
        path_resolved = path.resolve(strict=False)
    except OSError:
        path_resolved = path.parent.resolve() / path.name
    try:
        path_resolved.relative_to(release_root_resolved)
    except ValueError as exc:
        raise SystemExit(f"refusing to prune release outside release root: {path}") from exc
    if path.name.startswith("release_") or path.name.startswith("qa_release_"):
        if not dry_run:
            shutil.rmtree(path)
        return True
    raise SystemExit(f"refusing unexpected release directory name: {path}")


def remove_public_release_link(public_downloads: Path, rel_id: str, *, dry_run: bool) -> bool:
    public_path = public_downloads / "releases" / rel_id
    if not public_path.exists() and not public_path.is_symlink():
        return False
    if dry_run:
        return True
    if public_path.is_dir() and not public_path.is_symlink():
        shutil.rmtree(public_path)
    else:
        public_path.unlink()
    return True


def retained_release_ids(conn: sqlite3.Connection, server_key: str, keep: int) -> set[str]:
    active = current_release(conn, server_key)
    if not active:
        return set()
    retained = {active["release_id"]}
    previous_id = active["previous_release_id"]
    while previous_id and len(retained) - 1 < keep:
        row = conn.execute(
            "SELECT release_id, previous_release_id FROM pack_releases WHERE release_id = ?",
            (previous_id,),
        ).fetchone()
        if not row or row["release_id"] in retained:
            break
        retained.add(row["release_id"])
        previous_id = row["previous_release_id"]

    if len(retained) - 1 < keep:
        rows = conn.execute(
            """
            SELECT release_id
            FROM pack_releases
            WHERE server_key = ? AND active = 0 AND status != 'pruned'
            ORDER BY created_at DESC
            """,
            (server_key,),
        ).fetchall()
        for row in rows:
            if len(retained) - 1 >= keep:
                break
            retained.add(row["release_id"])
    return retained


def prune_releases(args: argparse.Namespace) -> int:
    if args.keep < 0:
        raise SystemExit("--keep must be >= 0")
    with connect(args.db) as conn:
        init_db(conn)
        keep_ids = retained_release_ids(conn, args.server_key, args.keep)
        rows = conn.execute(
            """
            SELECT release_id, release_dir, status, active
            FROM pack_releases
            WHERE server_key = ?
            ORDER BY created_at ASC
            """,
            (args.server_key,),
        ).fetchall()
        pruned = 0
        for row in rows:
            rel_id = row["release_id"]
            if row["active"] or rel_id in keep_ids:
                continue
            release_removed = safe_remove_release_dir(Path(row["release_dir"]), args.release_root, dry_run=args.dry_run)
            public_removed = remove_public_release_link(args.public_downloads, rel_id, dry_run=args.dry_run)
            if release_removed or public_removed or row["status"] != "pruned":
                pruned += 1
                print(
                    f"pruned_release={rel_id}\t"
                    f"release_dir_removed={int(release_removed)}\t"
                    f"public_removed={int(public_removed)}"
                )
                if not args.dry_run:
                    conn.execute(
                        "UPDATE pack_releases SET status = 'pruned' WHERE release_id = ?",
                        (rel_id,),
                    )
                    conn.execute(
                        """
                        INSERT INTO release_events(release_id, event_at, event_type, status, actor, notes)
                        VALUES (?, ?, 'prune', 'ok', ?, ?)
                        """,
                        (
                            rel_id,
                            utc_now(),
                            getattr(args, "actor", "release_manager"),
                            f"Pruned by retention policy; kept active plus {args.keep} rollback release(s).",
                        ),
                    )
        if not args.dry_run:
            conn.commit()
    print(f"pruned_count={pruned}")
    print(f"retained_count={len(keep_ids)}")
    return 0


def cleanup_public_release_links(args: argparse.Namespace) -> tuple[int, int]:
    releases_dir = args.public_downloads / "releases"
    if not releases_dir.exists():
        return 0, 0
    with connect(args.db) as conn:
        init_db(conn)
        known_public_ids = {
            row["release_id"]
            for row in conn.execute(
                """
                SELECT release_id
                FROM pack_releases
                WHERE server_key = ? AND status != 'pruned'
                """,
                (args.server_key,),
            )
        }
    removed = 0
    bytes_removed = 0
    for path in sorted(releases_dir.iterdir(), key=lambda item: item.name.lower()):
        if not (path.name.startswith("release_") or path.name.startswith("qa_release_")):
            continue
        missing_target = path.is_symlink() and not path.exists()
        if path.name not in known_public_ids or missing_target:
            bytes_removed += remove_path(path, dry_run=args.dry_run, reason="stale public release link")
            removed += 1
    return removed, bytes_removed


def cleanup_children(
    root: Path,
    *,
    allowed_root: Path,
    age_hours: float,
    dry_run: bool,
    reason: str,
    name_prefixes: Sequence[str] | None = None,
) -> tuple[int, int]:
    if not root.exists():
        return 0, 0
    ensure_path_inside(root, allowed_root, reason)
    removed = 0
    bytes_removed = 0
    for child in sorted(root.iterdir(), key=lambda item: item.name.lower()):
        if name_prefixes and not any(child.name.startswith(prefix) for prefix in name_prefixes):
            continue
        if not is_older_than(child, age_hours):
            continue
        ensure_path_inside(child, allowed_root, reason)
        bytes_removed += remove_path(child, dry_run=dry_run, reason=reason)
        removed += 1
    return removed, bytes_removed


def cleanup_matching_files(
    root: Path,
    *,
    allowed_root: Path,
    patterns: Sequence[str],
    age_hours: float,
    dry_run: bool,
    reason: str,
) -> tuple[int, int]:
    if not root.exists():
        return 0, 0
    ensure_path_inside(root, allowed_root, reason)
    removed = 0
    bytes_removed = 0
    seen: set[Path] = set()
    for pattern in patterns:
        for path in sorted(root.rglob(pattern), key=lambda item: item.as_posix().lower()):
            resolved_path = path.resolve() if path.exists() else path
            if resolved_path in seen:
                continue
            seen.add(resolved_path)
            if not path.is_file() or not is_older_than(path, age_hours):
                continue
            ensure_path_inside(path, allowed_root, reason)
            bytes_removed += remove_path(path, dry_run=dry_run, reason=reason)
            removed += 1
    return removed, bytes_removed


def cleanup_headless_cache(project_root: Path, *, dry_run: bool) -> tuple[int, int]:
    base = project_root / "headless_client_lab"
    if not base.exists():
        return 0, 0
    removed = 0
    bytes_removed = 0
    for rel in (
        "game/mods",
        "game/resourcepacks",
        "game/shaderpacks",
        "game/crash-reports",
        "game/logs",
        "game/screenshots",
        "run",
    ):
        path = base / rel
        if not path.exists():
            continue
        ensure_path_inside(path, project_root, "recreatable headless client cache")
        bytes_removed += remove_path(path, dry_run=dry_run, reason="recreatable headless client cache")
        removed += 1
    return removed, bytes_removed


def cleanup_empty_dirs(root: Path, *, allowed_root: Path, dry_run: bool, reason: str) -> int:
    if not root.exists():
        return 0
    ensure_path_inside(root, allowed_root, reason)
    removed = 0
    for path in sorted((item for item in root.rglob("*") if item.is_dir()), key=lambda item: len(item.parts), reverse=True):
        ensure_path_inside(path, allowed_root, reason)
        try:
            next(path.iterdir())
        except StopIteration:
            print(f"cleanup_removed={path}\tbytes=0\treason={reason}")
            if not dry_run:
                path.rmdir()
            removed += 1
        except OSError:
            continue
    return removed


def cleanup_project(args: argparse.Namespace) -> int:
    if args.keep_releases < 0:
        raise SystemExit("--keep-releases must be >= 0")
    project_root = args.project_root or args.db.parent.parent
    if not project_root.exists():
        raise SystemExit(f"project root not found: {project_root}")
    total_removed = 0
    total_bytes = 0

    prune_args = argparse.Namespace(
        db=args.db,
        server_key=args.server_key,
        release_root=args.release_root,
        public_downloads=args.public_downloads,
        actor=getattr(args, "actor", "release_manager"),
        keep=args.keep_releases,
        dry_run=args.dry_run,
        command="prune",
    )
    prune_releases(prune_args)

    removed, bytes_removed = cleanup_public_release_links(args)
    total_removed += removed
    total_bytes += bytes_removed

    temp_age = args.temp_max_age_hours
    for root, allowed_root, reason in (
        (args.server_dir / "codex-downloads", args.server_dir, "server download cache"),
        (args.server_dir / "downloads", args.server_dir, "server scratch downloads"),
        (project_root / "downloads", project_root, "project download cache"),
        (project_root / "deploy-stage", project_root, "deploy staging cache"),
    ):
        removed, bytes_removed = cleanup_children(
            root,
            allowed_root=allowed_root,
            age_hours=temp_age,
            dry_run=args.dry_run,
            reason=reason,
        )
        total_removed += removed
        total_bytes += bytes_removed

    for root, reason in (
        (args.server_dir / "mods.rollback", "server mod rollback snapshot"),
        (args.server_dir / "client-package.rollback", "client package rollback snapshot"),
    ):
        removed, bytes_removed = cleanup_children(
            root,
            allowed_root=args.server_dir,
            age_hours=args.rollback_keep_days * 24,
            dry_run=args.dry_run,
            reason=reason,
        )
        total_removed += removed
        total_bytes += bytes_removed

    for root, prefixes, reason in (
        (project_root / "test_sources", ("minecraft_", "pyramid_"), "recreatable test source"),
        (project_root / "mod_acceptance_lab" / "work", None, "acceptance lab work cache"),
        (project_root / "mod_acceptance_lab" / "client-work", None, "acceptance client work cache"),
    ):
        removed, bytes_removed = cleanup_children(
            root,
            allowed_root=project_root,
            age_hours=args.lab_keep_days * 24,
            dry_run=args.dry_run,
            reason=reason,
            name_prefixes=prefixes,
        )
        total_removed += removed
        total_bytes += bytes_removed

    for root in (
        args.server_dir / "server-test-results",
        project_root / "mod_acceptance_lab" / "logs",
        project_root / "mod_acceptance_lab" / "client-logs",
    ):
        removed, bytes_removed = cleanup_matching_files(
            root,
            allowed_root=args.server_dir if root.is_relative_to(args.server_dir) else project_root,
            patterns=("*.log", "*.errors", "*.status", "*.txt"),
            age_hours=args.log_keep_days * 24,
            dry_run=args.dry_run,
            reason="old test log",
        )
        total_removed += removed
        total_bytes += bytes_removed

    removed, bytes_removed = cleanup_matching_files(
        args.server_dir / "logs",
        allowed_root=args.server_dir,
        patterns=("*.log.gz", "*.log.*"),
        age_hours=args.log_keep_days * 24,
        dry_run=args.dry_run,
        reason="old server log",
    )
    total_removed += removed
    total_bytes += bytes_removed

    removed, bytes_removed = cleanup_matching_files(
        args.server_dir / "crash-reports",
        allowed_root=args.server_dir,
        patterns=("crash-*.txt",),
        age_hours=args.crash_keep_days * 24,
        dry_run=args.dry_run,
        reason="old crash report",
    )
    total_removed += removed
    total_bytes += bytes_removed

    if args.include_headless_cache:
        removed, bytes_removed = cleanup_headless_cache(project_root, dry_run=args.dry_run)
        total_removed += removed
        total_bytes += bytes_removed

    removed, bytes_removed = cleanup_matching_files(
        args.client_uploads,
        allowed_root=project_root,
        patterns=("*.zip",),
        age_hours=args.client_upload_keep_days * 24,
        dry_run=args.dry_run,
        reason="old client diagnostic upload",
    )
    total_removed += removed
    total_bytes += bytes_removed

    removed, bytes_removed = cleanup_matching_files(
        args.client_uploads,
        allowed_root=project_root,
        patterns=(".upload-*",),
        age_hours=args.upload_temp_max_age_hours,
        dry_run=args.dry_run,
        reason="stale client upload temp file",
    )
    total_removed += removed
    total_bytes += bytes_removed
    total_removed += cleanup_empty_dirs(
        args.client_uploads,
        allowed_root=project_root,
        dry_run=args.dry_run,
        reason="empty client upload directory",
    )

    if args.delete_legacy_server_backup and LEGACY_SERVER_BACKUP.exists():
        active_server = args.server_dir.resolve()
        legacy_server = LEGACY_SERVER_BACKUP.resolve()
        if legacy_server == active_server:
            raise SystemExit("refusing to delete active server as legacy backup")
        total_bytes += remove_path(
            LEGACY_SERVER_BACKUP,
            dry_run=args.dry_run,
            reason="explicit legacy server backup cleanup",
        )
        total_removed += 1

    if not args.dry_run:
        with connect(args.db) as conn:
            init_db(conn)
            active = current_release(conn, args.server_key)
            conn.execute(
                """
                INSERT INTO release_events(release_id, event_at, event_type, status, actor, notes)
                VALUES (?, ?, 'cleanup', 'ok', ?, ?)
                """,
                (
                    active["release_id"] if active else None,
                    utc_now(),
                    getattr(args, "actor", "release_manager"),
                    f"Cleanup removed {total_removed} path(s), logical bytes={total_bytes}.",
                ),
            )
            conn.commit()
    print(f"cleanup_removed_count={total_removed}")
    print(f"cleanup_removed_logical_bytes={total_bytes}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", type=Path, default=DEFAULT_DB)
    parser.add_argument("--server-dir", type=Path, default=DEFAULT_SERVER_DIR)
    parser.add_argument("--server-key", default=DEFAULT_SERVER_KEY)
    parser.add_argument("--release-root", type=Path, default=DEFAULT_RELEASE_ROOT)
    parser.add_argument("--public-downloads", type=Path, default=DEFAULT_PUBLIC_DOWNLOADS)
    parser.add_argument("--actor", default="release_manager")
    parser.add_argument("--service", default=DEFAULT_RELEASE_SERVICE, help="systemd service to restart after activation")
    parser.add_argument("--no-restart", action="store_true", help="activate release only, skip server restart")
    parser.add_argument("--rcon-host", default=DEFAULT_RCON_HOST)
    parser.add_argument("--rcon-port", type=int, default=DEFAULT_RCON_PORT)
    parser.add_argument("--rcon-password-file", type=Path, default=None)
    parser.add_argument("--rcon-timeout", type=float, default=DEFAULT_RCON_TIMEOUT)
    parser.add_argument(
        "--player-wait-timeout",
        type=int,
        default=DEFAULT_PLAYER_WAIT_TIMEOUT,
        help="max seconds to wait for players before forced restart",
    )
    parser.add_argument(
        "--player-check-interval",
        type=float,
        default=DEFAULT_PLAYER_CHECK_INTERVAL,
        help="seconds between player count checks while waiting",
    )
    parser.add_argument(
        "--player-warning-interval",
        type=float,
        default=DEFAULT_PLAYER_WARNING_INTERVAL,
        help="seconds between in-game warning broadcasts while waiting",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("init")

    create = sub.add_parser("create")
    create.add_argument("--release-id")
    create.add_argument("--label")
    create.add_argument("--status", default="tested", choices=["draft", "tested", "failed", "rolled-back"])
    create.add_argument("--minecraft-version")
    create.add_argument("--notes", default="")
    create.add_argument("--changelog")
    create.add_argument("--activate", action="store_true")

    validate = sub.add_parser("validate")
    validate.add_argument("release_id")

    activate = sub.add_parser("activate")
    activate.add_argument("release_id")
    activate.add_argument("--notes", default="")

    rollback = sub.add_parser("rollback")
    rollback.add_argument("--release-id")
    rollback.add_argument("--restore-db", action="store_true")
    rollback.add_argument("--notes", default="")

    deploy = sub.add_parser("deploy")
    deploy.add_argument("release_id")
    deploy.add_argument("--notes", default="")

    list_parser = sub.add_parser("list")
    list_parser.add_argument("--limit", type=int, default=20)

    show = sub.add_parser("show")
    show.add_argument("release_id")

    sub.add_parser("current-json")

    prune = sub.add_parser("prune")
    prune.add_argument("--keep", type=int, default=2, help="Inactive rollback releases to retain in addition to active")
    prune.add_argument("--dry-run", action="store_true")

    cleanup = sub.add_parser("cleanup")
    cleanup.add_argument("--project-root", type=Path, default=DEFAULT_PROJECT_ROOT)
    cleanup.add_argument("--keep-releases", type=int, default=1, help="Inactive rollback releases to retain in addition to active")
    cleanup.add_argument("--temp-max-age-hours", type=float, default=0, help="Minimum age for scratch download caches")
    cleanup.add_argument("--rollback-keep-days", type=float, default=2)
    cleanup.add_argument("--lab-keep-days", type=float, default=2)
    cleanup.add_argument("--log-keep-days", type=float, default=14)
    cleanup.add_argument("--crash-keep-days", type=float, default=30)
    cleanup.add_argument("--client-uploads", type=Path, default=DEFAULT_CLIENT_UPLOADS)
    cleanup.add_argument("--client-upload-keep-days", type=float, default=30)
    cleanup.add_argument("--upload-temp-max-age-hours", type=float, default=1)
    cleanup.add_argument("--include-headless-cache", action="store_true", help="Remove recreatable HeadlessMC synced client files")
    cleanup.add_argument("--delete-legacy-server-backup", action="store_true", help="Remove /var/minecraft when it is not the active server")
    cleanup.add_argument("--dry-run", action="store_true")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.command == "init":
        ensure_release_schema(args.db)
        print("schema=ok")
        return 0
    if args.command == "create":
        return create_release(args)
    if args.command == "validate":
        return validate_release(args)
    if args.command == "activate":
        return activate_release(args)
    if args.command == "rollback":
        return rollback_release(args)
    if args.command == "deploy":
        return deploy_release(args)
    if args.command == "list":
        return list_releases(args)
    if args.command == "show":
        return show_release(args)
    if args.command == "current-json":
        return current_json(args)
    if args.command == "prune":
        return prune_releases(args)
    if args.command == "cleanup":
        return cleanup_project(args)
    raise SystemExit(f"unknown command {args.command}")


if __name__ == "__main__":
    raise SystemExit(main())
