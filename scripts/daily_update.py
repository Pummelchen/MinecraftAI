#!/usr/bin/env python3
"""Daily safe update pipeline for the Pummelchen Minecraft pack."""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import hashlib
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import time
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path
from typing import Any, Sequence

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import process_url_batch as processor
import release_manager
import server_ops
import sanitize_resource_pack_metadata
from moddb import UPDATE_SCAN_ACTIVE_STATUSES, connect, init_db, slugify, source_kind, utc_now


DEFAULT_DB = Path("/var/minecraft_mods/data/minecraft_mods.sqlite")
DEFAULT_SERVER_DIR = Path("/var/minecraft_26.1.2")
DEFAULT_SERVER_KEY = "minecraft_26_1_2"
DEFAULT_PUBLIC_URL = "http://91.99.176.243:7788"
DEFAULT_RELEASE_ROOT = Path("/var/minecraft_mods/releases")
DEFAULT_PUBLIC_DOWNLOADS = Path("/var/minecraft_mods/site/public/downloads")
CLIENT_ZIP_NAME = "minecraft_26.1.2_client_macos_apple_silicon.zip"
MRPACK_NAME = "pummelchen-server-26.1.2.mrpack"
SERVER_DISABLED_FILE_MARKERS = {
    "animalgarden_commonraven": "server watchdog crash from Common Raven flying AI chunk loads",
    "automated_harvest": "server watchdog crash in automated_harvest HarvestTicker",
    "automotives": "missing mandatory Create 6.0.0+ dependency",
    "better_snowy_biome": "server watchdog crash from scheduled fillbiome functions",
    "dynamictrees": "dedicated-server tick crash loading a client renderer class",
    "guns++": "server watchdog crash from startup/load forceload function",
    "incendium": "server watchdog crash from startup/load forceload function",
    "mine_treasure": "server watchdog crash from startup/load forceload function",
    "ruins_26": "server watchdog crash in RuinsMod.inspectChunk during chunk entry",
}
CLIENT_EXCLUDED_FILE_MARKERS = {
    "animalgarden_commonraven": "server watchdog crash from Common Raven flying AI chunk loads",
    "automated_harvest": "server watchdog crash in automated_harvest HarvestTicker",
    "automotives": "missing mandatory Create 6.0.0+ dependency",
    "better_snowy_biome": "server watchdog crash from scheduled fillbiome functions",
    "dynamictrees": "dedicated-server tick crash loading a client renderer class",
    "guns++": "server watchdog crash from startup/load forceload function",
    "incendium": "server watchdog crash from startup/load forceload function",
    "mine_treasure": "server watchdog crash from startup/load forceload function",
    "ruins_26": "server watchdog crash in RuinsMod.inspectChunk during chunk entry",
    "structory_towers": "server-side structure pack with client-incompatible overlay metadata",
}
COMPATIBLE_GAME_VERSIONS = ("26.1.2", "26.1.1", "26.1")
USER_AGENT = "Codex Pummelchen Update Pipeline"


def now_label(prefix: str) -> str:
    return f"{prefix}_{dt.datetime.now(dt.UTC).strftime('%Y%m%d_%H%M%S')}"


def api_json(url: str) -> dict[str, Any]:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.load(response)


def api_json_list(url: str) -> list[dict[str, Any]]:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.load(response)


def release_channel(file_info: dict[str, Any]) -> str:
    if file_info.get("_source") == "modrinth":
        return str(file_info.get("versionType") or "unknown")
    return {1: "stable", 2: "beta", 3: "alpha"}.get(file_info.get("releaseType"), "unknown")


def stable_first(files: list[dict[str, Any]]) -> dict[str, Any] | None:
    if not files:
        return None
    release_order = {"stable": 0, "release": 0, "beta": 1, "alpha": 2, "unknown": 3}
    for channel, _rank in sorted(release_order.items(), key=lambda item: item[1]):
        matching = [info for info in files if release_channel(info) == channel]
        if matching:
            return sorted(
                matching,
                key=lambda info: (
                    str(info.get("fileDate") or info.get("datePublished") or ""),
                    str(info.get("id") or ""),
                ),
            )[-1]
    return sorted(
        files,
        key=lambda info: (
            str(info.get("fileDate") or info.get("datePublished") or ""),
            str(info.get("id") or ""),
        ),
    )[-1]


def compatible_versions(versions: Sequence[str]) -> bool:
    return bool(set(versions) & set(COMPATIBLE_GAME_VERSIONS))


def curseforge_project(slug: str) -> dict[str, Any] | None:
    return processor.search_project(slug)


def curseforge_files(mod_id: int) -> list[dict[str, Any]]:
    return processor.get_files(mod_id)


def choose_curseforge_file(project: dict[str, Any], source_url: str) -> dict[str, Any] | None:
    files = curseforge_files(int(project["id"]))
    source_path = urllib.parse.urlparse(source_url).path
    is_mod = "/mc-mods/" in source_path
    is_shader = "/shaders/" in source_path
    candidates: list[dict[str, Any]] = []
    for file_info in files:
        versions = set(file_info.get("gameVersions") or [])
        if not file_info.get("isAvailable", True) or file_info.get("fileStatus", 4) != 4:
            continue
        if is_mod:
            if "NeoForge" not in versions or not compatible_versions(list(versions)):
                continue
        elif is_shader:
            if "Iris" not in versions and not compatible_versions(list(versions)):
                continue
        elif not compatible_versions(list(versions)):
            continue
        candidates.append(file_info)
    return stable_first(candidates)


def modrinth_project(slug: str) -> dict[str, Any]:
    return processor.get_modrinth_project(slug)


def choose_modrinth_file(project: dict[str, Any]) -> dict[str, Any] | None:
    slug = str(project.get("slug") or project.get("id"))
    versions = api_json_list(f"https://api.modrinth.com/v2/project/{urllib.parse.quote(slug)}/version")
    project_type = project.get("project_type") or "mod"
    loader_allow = {
        "mod": {"neoforge"},
        "resourcepack": {"minecraft"},
        "shader": {"iris", "minecraft"},
        "datapack": {"minecraft", "datapack"},
    }.get(str(project_type), {"neoforge", "minecraft", "iris"})
    candidates: list[dict[str, Any]] = []
    for version in versions:
        if not compatible_versions(version.get("game_versions") or []):
            continue
        if not (set(version.get("loaders") or []) & loader_allow):
            continue
        files = version.get("files") or []
        selected = ([file_info for file_info in files if file_info.get("primary")] or files or [None])[0]
        if not selected:
            continue
        candidates.append(
            {
                "_source": "modrinth",
                "_side": processor.modrinth_project_side(project),
                "id": version.get("id"),
                "modId": project.get("id"),
                "fileName": selected.get("filename"),
                "downloadUrl": selected.get("url"),
                "fileLength": selected.get("size") or 0,
                "versionType": version.get("version_type") or "unknown",
                "gameVersions": version.get("game_versions") or [],
                "dependencies": version.get("dependencies") or [],
                "datePublished": version.get("date_published") or "",
            }
        )
    return stable_first(candidates)


def selected_file_names(conn: sqlite3.Connection, mod_id: int) -> list[str]:
    return [
        str(row["file_name"])
        for row in conn.execute(
            "SELECT file_name FROM mod_files WHERE mod_id = ? ORDER BY installed_on_server DESC, included_in_client DESC, id",
            (mod_id,),
        )
    ]


def primary_source(conn: sqlite3.Connection, mod_id: int) -> sqlite3.Row | None:
    return conn.execute(
        """
        SELECT *
        FROM source_urls
        WHERE mod_id = ?
        ORDER BY is_primary DESC, id
        LIMIT 1
        """,
        (mod_id,),
    ).fetchone()


def resolve_candidate(conn: sqlite3.Connection, mod: sqlite3.Row) -> tuple[dict[str, Any], dict[str, Any]] | None:
    source = primary_source(conn, int(mod["id"]))
    if not source:
        return None
    slug = source["project_slug"] or mod["canonical_key"]
    try:
        if source["source_kind"] == "modrinth":
            project = modrinth_project(slug)
            file_info = choose_modrinth_file(project)
        elif source["source_kind"] == "curseforge":
            project = curseforge_project(slug)
            if not project:
                return None
            file_info = choose_curseforge_file(project, source["url"])
        else:
            return None
    except Exception:
        return None
    if not file_info:
        return None
    return project, file_info


def download_file(file_info: dict[str, Any], dest_dir: Path) -> Path:
    return processor.download_file(file_info, dest_dir)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_manifest(root: Path, output_path: Path) -> None:
    sections = [
        ("mods", root / "mods", ("*.jar", "*.zip")),
        ("resourcepacks", root / "resourcepacks", ("*.zip", "*.jar")),
        ("shaderpacks", root / "shaderpacks", ("*.zip", "*.jar")),
    ]
    with output_path.open("w", encoding="utf-8") as handle:
        for section, folder, patterns in sections:
            handle.write(f"[{section}]\n")
            files: list[Path] = []
            if folder.exists():
                for pattern in patterns:
                    files.extend(folder.glob(pattern))
            for path in sorted(set(files), key=lambda p: p.name.lower()):
                handle.write(f"{path.name}\t{path.stat().st_size}\tsha256:{sha256_file(path)}\n")
            handle.write("\n")


def client_exclusion_reason(file_name: str) -> str | None:
    normalized = file_name.lower().replace("-", "_")
    for marker, reason in CLIENT_EXCLUDED_FILE_MARKERS.items():
        if marker in normalized:
            return reason
    return None


def server_disable_reason(file_name: str) -> str | None:
    normalized = file_name.lower().replace("-", "_")
    for marker, reason in SERVER_DISABLED_FILE_MARKERS.items():
        if marker in normalized:
            return reason
    return None


def enforce_server_disables(server_dir: Path) -> list[tuple[Path, str]]:
    disabled_dir = server_dir / "mods.failed" / "pummelchen-server-disabled"
    removed: list[tuple[Path, str]] = []
    for section in ("mods", "server-datapacks"):
        section_dir = server_dir / section
        if not section_dir.exists():
            continue
        for path in sorted(section_dir.iterdir(), key=lambda item: item.name.lower()):
            if not path.is_file():
                continue
            reason = server_disable_reason(path.name)
            if not reason:
                continue
            target = disabled_dir / section / path.name
            target.parent.mkdir(parents=True, exist_ok=True)
            if target.exists():
                target.unlink()
            shutil.move(str(path), str(target))
            removed.append((target, reason))
    return removed


def enforce_client_exclusions(server_dir: Path) -> list[tuple[Path, str]]:
    package_dir = server_dir / "client-package"
    disabled_dir = package_dir / "pummelchen-server-disabled"
    removed: list[tuple[Path, str]] = []
    for section in ("mods", "resourcepacks", "shaderpacks"):
        section_dir = package_dir / section
        if not section_dir.exists():
            continue
        for path in sorted(section_dir.iterdir(), key=lambda item: item.name.lower()):
            if not path.is_file():
                continue
            reason = client_exclusion_reason(path.name)
            if not reason:
                continue
            target = disabled_dir / section / path.name
            target.parent.mkdir(parents=True, exist_ok=True)
            if target.exists():
                target.unlink()
            shutil.move(str(path), str(target))
            removed.append((target, reason))
    return removed


def create_mrpack(server_dir: Path) -> Path:
    package_dir = server_dir / "client-package"
    mrpack_path = server_dir / MRPACK_NAME
    index = {
        "formatVersion": 1,
        "game": "minecraft",
        "versionId": "26.1.2",
        "name": "Pummelchen Server",
        "summary": "Pummelchen Server NeoForge 26.1.2 client package",
        "files": [],
        "dependencies": {
            "minecraft": "26.1.2",
            "neoforge": "26.1.2.71",
        },
    }
    if mrpack_path.exists():
        mrpack_path.unlink()
    with zipfile.ZipFile(mrpack_path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("modrinth.index.json", json.dumps(index, indent=2, sort_keys=True))
        for folder_name in ("mods", "resourcepacks", "shaderpacks"):
            folder = package_dir / folder_name
            if not folder.exists():
                continue
            for path in sorted(folder.iterdir(), key=lambda p: p.name.lower()):
                if path.is_file():
                    archive.write(path, f"overrides/{folder_name}/{path.name}")
    return mrpack_path


def should_publish_client_file(relative_path: Path) -> bool:
    parts = relative_path.parts
    if not parts:
        return False
    blocked_parts = {
        "__MACOSX",
        ".git",
        ".DS_Store",
        "manifest-snapshots",
        "pummelchen-server-disabled",
    }
    if any(part in blocked_parts for part in parts):
        return False
    if any(part.endswith(".rollback") for part in parts):
        return False
    if relative_path.name in {".DS_Store", "upload-token.txt"}:
        return False
    if parts[0] in {"mods", "resourcepacks", "shaderpacks"}:
        return len(parts) == 2 and bool(relative_path.suffix)
    if parts[0] == "tools":
        return len(parts) == 2 and relative_path.name in {
            "AddPummelchenServer.java",
            "pummelchen-auto-update.sh",
            "pummelchen-client-doctor.sh",
            "upload-token.txt.example",
        }
    return len(parts) == 1 and relative_path.name in {
        "Install Mods.command",
        "README.txt",
        "manifest.txt",
    }


def create_client_zip(package_dir: Path, zip_path: Path) -> None:
    with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(package_dir.rglob("*"), key=lambda item: item.relative_to(package_dir).as_posix().lower()):
            if not path.is_file():
                continue
            relative_path = path.relative_to(package_dir)
            if not should_publish_client_file(relative_path):
                continue
            archive.write(path, f"client-package/{relative_path.as_posix()}")


def rebuild_client_package(server_dir: Path) -> tuple[Path, str]:
    package_dir = server_dir / "client-package"
    enforce_client_exclusions(server_dir)
    sanitize_resource_pack_metadata.sanitize_path(package_dir, write=True, target="client")
    write_manifest(package_dir, package_dir / "manifest.txt")
    create_mrpack(server_dir)
    zip_path = server_dir / CLIENT_ZIP_NAME
    sha_path = server_dir / f"{CLIENT_ZIP_NAME}.sha256"
    if zip_path.exists():
        zip_path.unlink()
    if sha_path.exists():
        sha_path.unlink()
    create_client_zip(package_dir, zip_path)
    digest = sha256_file(zip_path)
    sha_path.write_text(f"{digest}  {CLIENT_ZIP_NAME}\n", encoding="utf-8")
    return zip_path, digest


def snapshot_client_package(server_dir: Path, label: str) -> Path:
    package_dir = server_dir / "client-package"
    backup_dir = server_dir / "client-package.rollback" / label
    if backup_dir.exists():
        shutil.rmtree(backup_dir)
    if package_dir.exists():
        shutil.copytree(package_dir, backup_dir)
    return backup_dir


def restore_client_package(server_dir: Path, backup_dir: Path) -> None:
    package_dir = server_dir / "client-package"
    if not backup_dir.exists():
        return
    if package_dir.exists():
        shutil.rmtree(package_dir)
    shutil.copytree(backup_dir, package_dir)


def list_files(folder: Path) -> list[str]:
    if not folder.exists():
        return []
    return [path.name for path in sorted(folder.iterdir(), key=lambda p: p.name.lower()) if path.is_file()]


def db_file_path(conn: sqlite3.Connection) -> Path:
    row = conn.execute("PRAGMA database_list").fetchone()
    return Path(row["file"] if isinstance(row, sqlite3.Row) else row[2])


def create_backup_snapshot(
    conn: sqlite3.Connection,
    server_instance_id: int,
    server_dir: Path,
    label: str,
    backup_root: Path,
) -> int:
    backup_dir = backup_root / label
    backup_dir.mkdir(parents=True, exist_ok=True)
    db_backup = backup_dir / "minecraft_mods.sqlite"
    shutil.copy2(db_file_path(conn), db_backup)
    server_manifest = backup_dir / "server_mods.csv"
    client_manifest = backup_dir / "client_package.csv"
    with server_manifest.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        writer.writerow(["file_name", "sha256", "size_bytes"])
        for name in list_files(server_dir / "mods"):
            path = server_dir / "mods" / name
            writer.writerow([name, sha256_file(path), path.stat().st_size])
    with client_manifest.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        writer.writerow(["section", "file_name", "sha256", "size_bytes"])
        for section in ("mods", "resourcepacks", "shaderpacks"):
            for name in list_files(server_dir / "client-package" / section):
                path = server_dir / "client-package" / section / name
                writer.writerow([section, name, sha256_file(path), path.stat().st_size])
    zip_path = server_dir / CLIENT_ZIP_NAME
    zip_sha = sha256_file(zip_path) if zip_path.exists() else ""
    cur = conn.execute(
        """
        INSERT INTO backup_snapshots(
            server_instance_id, label, created_at, db_backup_path,
            server_manifest_path, client_manifest_path, client_zip_path,
            client_zip_sha256, server_dir, notes
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            server_instance_id,
            label,
            utc_now(),
            str(db_backup),
            str(server_manifest),
            str(client_manifest),
            str(zip_path),
            zip_sha,
            str(server_dir),
            "Automatic pre-update snapshot",
        ),
    )
    conn.commit()
    return int(cur.lastrowid)


def start_update_run(conn: sqlite3.Connection, server_instance_id: int, label: str, trigger: str, backup_id: int) -> int:
    cur = conn.execute(
        """
        INSERT INTO update_runs(server_instance_id, run_label, started_at, status, trigger_type, backup_snapshot_id)
        VALUES (?, ?, ?, 'running', ?, ?)
        """,
        (server_instance_id, label, utc_now(), trigger, backup_id),
    )
    conn.commit()
    return int(cur.lastrowid)


def finish_update_run(conn: sqlite3.Connection, run_id: int, status: str, stats: dict[str, int], notes: str = "") -> None:
    conn.execute(
        """
        UPDATE update_runs
        SET completed_at = ?, status = ?, scanned_mods = ?, candidates = ?,
            applied = ?, failed = ?, skipped = ?, notes = ?
        WHERE id = ?
        """,
        (
            utc_now(),
            status,
            stats.get("scanned", 0),
            stats.get("candidates", 0),
            stats.get("applied", 0),
            stats.get("failed", 0),
            stats.get("skipped", 0),
            notes,
            run_id,
        ),
    )
    conn.commit()


def log_event(
    conn: sqlite3.Connection,
    run_id: int,
    mod_id: int,
    *,
    event_type: str,
    status: str,
    old_file: str = "",
    new_file: str = "",
    old_file_id: str = "",
    new_file_id: str = "",
    source_kind: str = "",
    source_url: str = "",
    release: str = "",
    test_label: str = "",
    log_path: str = "",
    package_sha: str = "",
    visible: bool = False,
    notes: str = "",
) -> None:
    conn.execute(
        """
        INSERT INTO update_events(
            update_run_id, mod_id, event_type, status, old_file_name, new_file_name,
            old_file_id, new_file_id, source_kind, source_url, release_channel,
            tested_at, test_label, log_path, client_package_sha256, visible_on_site, notes
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            run_id,
            mod_id,
            event_type,
            status,
            old_file,
            new_file,
            old_file_id,
            new_file_id,
            source_kind,
            source_url,
            release,
            utc_now(),
            test_label,
            log_path,
            package_sha,
            int(visible),
            notes,
        ),
    )
    conn.commit()


def client_section_for(file_name: str, role: str) -> str:
    lower = file_name.lower()
    if role == "shaderpack":
        return "shaderpacks"
    if lower.endswith(".zip"):
        return "resourcepacks"
    return "mods"


def is_datapack_candidate(mod: sqlite3.Row, project: dict[str, Any], file_info: dict[str, Any]) -> bool:
    file_name = str(file_info.get("fileName") or "").lower()
    source_url = str(mod["primary_url"] or processor.stable_project_url(project) or "").lower()
    entry_type = str(mod["entry_type"] or "").lower().replace(" ", "")
    project_type = str(project.get("project_type") or "").lower()
    if project_type == "datapack" or "datapack" in entry_type:
        return True
    if "/data-packs/" in source_url or "/datapack/" in source_url:
        return True
    return file_name.endswith(".zip") and "datapack" in file_name


def server_section_for(mod: sqlite3.Row, project: dict[str, Any], file_info: dict[str, Any]) -> str:
    if is_datapack_candidate(mod, project, file_info):
        return "server-datapacks"
    return "mods"


def remove_client_file(server_dir: Path, file_name: str) -> None:
    for section in ("mods", "resourcepacks", "shaderpacks"):
        path = server_dir / "client-package" / section / file_name
        if path.exists():
            path.unlink()


def move_existing_server_files(server_dir: Path, file_names: Sequence[str], rollback_dir: Path) -> list[tuple[Path, Path]]:
    moved: list[tuple[Path, Path]] = []
    for name in file_names:
        for section in ("mods", "server-datapacks"):
            path = server_dir / section / name
            if path.exists():
                dst = rollback_dir / section / name
                dst.parent.mkdir(parents=True, exist_ok=True)
                shutil.move(str(path), str(dst))
                moved.append((dst, path))
    return moved


def apply_client_only(
    conn: sqlite3.Connection,
    run_id: int,
    mod: sqlite3.Row,
    project: dict[str, Any],
    file_info: dict[str, Any],
    downloaded: Path,
    server_dir: Path,
) -> bool:
    mod_id = int(mod["id"])
    old_files = selected_file_names(conn, mod_id)
    role = "shaderpack" if str(file_info["fileName"]).lower().endswith(".zip") and "shader" in str(mod["name"]).lower() else "server_file"
    section = client_section_for(str(file_info["fileName"]), role)
    target_dir = server_dir / "client-package" / section
    target_dir.mkdir(parents=True, exist_ok=True)
    label = f"client_only_{mod['canonical_key']}_{dt.datetime.now(dt.UTC).strftime('%Y%m%d_%H%M%S')}"
    client_backup = snapshot_client_package(server_dir, label)
    try:
        for name in old_files:
            remove_client_file(server_dir, name)
        target = target_dir / downloaded.name
        shutil.copy2(downloaded, target)
        package_path, digest = rebuild_client_package(server_dir)
    except Exception as exc:
        restore_client_package(server_dir, client_backup)
        log_event(
            conn,
            run_id,
            mod_id,
            event_type="client_update",
            status="failed",
            old_file="; ".join(old_files),
            new_file=downloaded.name,
            new_file_id=str(file_info.get("id") or ""),
            source_kind="modrinth" if file_info.get("_source") == "modrinth" else "curseforge",
            source_url=processor.stable_project_url(project),
            release=release_channel(file_info),
            visible=False,
            notes=f"Rolled back client package change after {type(exc).__name__}: {exc}",
        )
        return False
    processor.set_mod_state(
        conn,
        mod_id=mod_id,
        project=project,
        file_info=file_info,
        status="OK",
        server_status="Client-only: included",
        client_package="Included",
        installed_server=False,
        included_client=True,
        files=[target.name],
        note=f"Daily updater accepted client-only file {target.name}; package rebuilt and checksum verified.",
        installation="Client only",
    )
    conn.commit()
    log_event(
        conn,
        run_id,
        mod_id,
        event_type="client_update",
        status="applied",
        old_file="; ".join(old_files),
        new_file=target.name,
        new_file_id=str(file_info.get("id") or ""),
        source_kind="modrinth" if file_info.get("_source") == "modrinth" else "curseforge",
        source_url=processor.stable_project_url(project),
        release=release_channel(file_info),
        package_sha=digest,
        visible=True,
        notes=f"Client package updated: {package_path.name}",
    )
    return True


def apply_server_update(
    conn: sqlite3.Connection,
    run_id: int,
    mod: sqlite3.Row,
    project: dict[str, Any],
    file_info: dict[str, Any],
    downloaded: Path,
    server_dir: Path,
    db_path: Path,
    timeout: int,
) -> bool:
    mod_id = int(mod["id"])
    old_files = selected_file_names(conn, mod_id)
    label = f"daily_update_{mod['canonical_key']}_{dt.datetime.now(dt.UTC).strftime('%Y%m%d_%H%M%S')}"
    server_section = server_section_for(mod, project, file_info)
    server_datapack = server_section == "server-datapacks"
    if not server_datapack:
        try:
            isolated_ok, isolated_status, isolated_severe, isolated_log_path = processor.run_isolated_acceptance_test(
                label,
                [downloaded],
                db_path,
                timeout,
            )
        except Exception as exc:
            isolated_ok = False
            isolated_status = "exception"
            isolated_severe = [f"{type(exc).__name__}: {exc}"]
            isolated_log_path = ""
        if not isolated_ok:
            log_event(
                conn,
                run_id,
                mod_id,
                event_type="server_update",
                status="failed",
                old_file="; ".join(old_files),
                new_file=downloaded.name,
                new_file_id=str(file_info.get("id") or ""),
                source_kind="modrinth" if file_info.get("_source") == "modrinth" else "curseforge",
                source_url=processor.stable_project_url(project),
                release=release_channel(file_info),
                test_label=f"{label}_isolated",
                log_path=isolated_log_path,
                visible=False,
                notes="Rejected before live install by isolated acceptance lab: "
                + (" | ".join(isolated_severe[:3]) if isolated_severe else f"status={isolated_status}"),
            )
            processor.insert_test_run(
                conn,
                mod_id,
                f"{label}_isolated",
                isolated_status,
                len(isolated_severe),
                isolated_log_path,
                "Rejected before live install by isolated acceptance lab.",
            )
            return False
    rollback_dir = server_dir / "mods.rollback" / label
    rollback_dir.mkdir(parents=True, exist_ok=True)
    moved = move_existing_server_files(server_dir, old_files, rollback_dir)
    target = server_dir / server_section / downloaded.name
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(downloaded, target)
    sanitize_resource_pack_metadata.sanitize_path(target, write=True, target="server")
    try:
        ok, test_status, error_count, severe, log_path = processor.run_server_test(label, timeout)
    except Exception as exc:
        ok = False
        test_status = "exception"
        error_count = 999
        severe = [f"{type(exc).__name__}: {exc}"]
        log_path = ""
    if not ok:
        if target.exists():
            failed_dir = server_dir / "mods.failed" / label
            failed_dir.mkdir(parents=True, exist_ok=True)
            shutil.move(str(target), str(failed_dir / target.name))
        for src, dst in moved:
            if src.exists():
                shutil.move(str(src), str(dst))
        log_event(
            conn,
            run_id,
            mod_id,
            event_type="server_update",
            status="failed",
            old_file="; ".join(old_files),
            new_file=downloaded.name,
            new_file_id=str(file_info.get("id") or ""),
            source_kind="modrinth" if file_info.get("_source") == "modrinth" else "curseforge",
            source_url=processor.stable_project_url(project),
            release=release_channel(file_info),
            test_label=label,
            log_path=log_path,
            visible=False,
            notes="Rejected by boot test: " + (" | ".join(severe[:3]) if severe else f"status={test_status}"),
        )
        return False
    client_backup = snapshot_client_package(server_dir, label)
    client_exclusion = client_exclusion_reason(target.name)
    try:
        for name in old_files:
            remove_client_file(server_dir, name)
        if not server_datapack and not client_exclusion:
            client_target = server_dir / "client-package" / "mods" / target.name
            client_target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(target, client_target)
        package_path, digest = rebuild_client_package(server_dir)
    except Exception as exc:
        restore_client_package(server_dir, client_backup)
        if target.exists():
            failed_dir = server_dir / "mods.failed" / label
            failed_dir.mkdir(parents=True, exist_ok=True)
            shutil.move(str(target), str(failed_dir / target.name))
        for src, dst in moved:
            if src.exists():
                shutil.move(str(src), str(dst))
        log_event(
            conn,
            run_id,
            mod_id,
            event_type="server_update",
            status="failed",
            old_file="; ".join(old_files),
            new_file=downloaded.name,
            new_file_id=str(file_info.get("id") or ""),
            source_kind="modrinth" if file_info.get("_source") == "modrinth" else "curseforge",
            source_url=processor.stable_project_url(project),
            release=release_channel(file_info),
            test_label=label,
            log_path=log_path,
            visible=False,
            notes=f"Boot test passed but package rebuild failed; rolled back after {type(exc).__name__}: {exc}",
        )
        return False
    processor.set_mod_state(
        conn,
        mod_id=mod_id,
        project=project,
        file_info=file_info,
        status="OK",
        server_status="OK",
        client_package="Not included" if server_datapack or client_exclusion else "Included",
        installed_server=True,
        included_client=not server_datapack and not client_exclusion,
        files=[target.name],
        note=(
            f"Daily updater accepted server datapack {target.name}; boot test {label} reached Done with no severe filtered errors."
            if server_datapack
            else f"Daily updater accepted {target.name}; boot test {label} reached Done, but client package excluded it: {client_exclusion}."
            if client_exclusion
            else f"Daily updater accepted {target.name}; boot test {label} reached Done with no severe filtered errors."
        ),
        entry_type="Datapack" if server_datapack else None,
        installation="Server only" if server_datapack or client_exclusion else None,
        file_role="server_datapack" if server_datapack else "server_file",
        path_hint=str(server_dir / server_section),
    )
    processor.insert_test_run(conn, mod_id, label, test_status, error_count, log_path, "Accepted by daily updater.")
    conn.commit()
    log_event(
        conn,
        run_id,
        mod_id,
        event_type="server_update",
        status="applied",
        old_file="; ".join(old_files),
        new_file=target.name,
        new_file_id=str(file_info.get("id") or ""),
        source_kind="modrinth" if file_info.get("_source") == "modrinth" else "curseforge",
        source_url=processor.stable_project_url(project),
        release=release_channel(file_info),
        test_label=label,
        log_path=log_path,
        package_sha=digest,
        visible=True,
        notes=(
            f"Server datapack boot test passed; client package rebuilt without datapack: {package_path.name}"
            if server_datapack
            else f"Server boot test passed; client package rebuilt without client-excluded file ({client_exclusion}): {package_path.name}"
            if client_exclusion
            else f"Server boot test passed and client package rebuilt: {package_path.name}"
        ),
    )
    return True


def sync_globals(server_dir: Path) -> None:
    processor.SERVER_DIR = server_dir
    processor.DOWNLOAD_DIR = server_dir / "codex-downloads" / "daily_update"
    processor.CLIENT_MODS_DIR = server_dir / "client-package" / "mods"
    processor.DOWNLOAD_DIR.mkdir(parents=True, exist_ok=True)


def scan_and_apply(args: argparse.Namespace) -> int:
    sync_globals(args.server_dir)
    label = ""
    stats = {"scanned": 0, "candidates": 0, "applied": 0, "failed": 0, "skipped": 0}
    with connect(args.db) as conn:
        init_db(conn)
        server_id = server_ops.ensure_server_instance(
            conn,
            server_key=args.server_key,
            display_name="Pummelchen Server",
            server_dir=args.server_dir,
        )
        server_ops.backfill_metadata(conn)
        server_ops.sync_instance_files(conn, server_id, args.server_dir)
        server_ops.score_risks(conn, server_id)
        label = now_label("daily_update")
        backup_root = args.backup_dir or (args.db.parent.parent / "backups")
        backup_id = create_backup_snapshot(conn, server_id, args.server_dir, label, backup_root)
        run_id = start_update_run(conn, server_id, label, args.trigger, backup_id)
        scan_statuses = tuple(UPDATE_SCAN_ACTIVE_STATUSES)
        placeholders = ",".join("?" for _ in scan_statuses)
        rows = conn.execute(
            f"""
            SELECT m.*
            FROM mods m
            WHERE m.duplicate_of_id IS NULL
              AND m.active_status IN ({placeholders})
            ORDER BY
                CASE
                    WHEN m.active_status IN ('awaiting_compatible_release', 'blocked_by_dependency', 'skipped') THEN 0
                    ELSE 1
                END,
                lower(m.name)
            """,
            scan_statuses,
        ).fetchall()
        limit = args.limit or len(rows)
        try:
            for mod in rows[:limit]:
                stats["scanned"] += 1
                candidate = resolve_candidate(conn, mod)
                if not candidate:
                    stats["skipped"] += 1
                    continue
                project, file_info = candidate
                new_name = str(file_info.get("fileName") or "")
                old_files = selected_file_names(conn, int(mod["id"]))
                active_status = str(mod["active_status"] or "")
                if new_name in old_files and active_status == "ok":
                    stats["skipped"] += 1
                    continue
                if args.dry_run:
                    stats["candidates"] += 1
                    log_event(
                        conn,
                        run_id,
                        int(mod["id"]),
                        event_type="candidate",
                        status="dry_run",
                        old_file="; ".join(old_files),
                        new_file=new_name,
                        new_file_id=str(file_info.get("id") or ""),
                        source_kind="modrinth" if file_info.get("_source") == "modrinth" else "curseforge",
                        source_url=processor.stable_project_url(project),
                        release=release_channel(file_info),
                        notes="Candidate only; dry run did not install or test.",
                    )
                    continue
                stats["candidates"] += 1
                downloaded = download_file(file_info, processor.DOWNLOAD_DIR)
                server_side = any(
                    int(row["installed_on_server"] or 0) == 1
                    for row in conn.execute("SELECT installed_on_server FROM mod_files WHERE mod_id = ?", (int(mod["id"]),))
                ) or active_status in {"awaiting_compatible_release", "blocked_by_dependency", "skipped"}
                if server_side:
                    ok = apply_server_update(
                        conn,
                        run_id,
                        mod,
                        project,
                        file_info,
                        downloaded,
                        args.server_dir,
                        args.db,
                        args.timeout,
                    )
                else:
                    ok = apply_client_only(conn, run_id, mod, project, file_info, downloaded, args.server_dir)
                if ok:
                    stats["applied"] += 1
                    server_ops.backfill_metadata(conn)
                    server_ops.sync_instance_files(conn, server_id, args.server_dir)
                    server_ops.score_risks(conn, server_id)
                else:
                    stats["failed"] += 1
                if args.apply_limit and stats["applied"] >= args.apply_limit:
                    break
            finish_update_run(conn, run_id, "complete", stats)
        except Exception as exc:
            finish_update_run(conn, run_id, "error", stats, f"{type(exc).__name__}: {exc}")
            raise
    if stats["applied"] > 0 and not args.dry_run and not args.no_create_release:
        create_tested_release(args, label, stats)
    return 0


def create_tested_release(args: argparse.Namespace, label: str, stats: dict[str, int]) -> None:
    release_args = argparse.Namespace(
        db=args.db,
        server_dir=args.server_dir,
        server_key=args.server_key,
        release_root=args.release_root,
        public_downloads=args.public_downloads,
        actor="daily_update",
        command="create",
        release_id=None,
        label=label,
        status="tested",
        minecraft_version=None,
        notes=(
            f"Daily updater release after {stats['applied']} applied update(s), "
            f"{stats['failed']} failed candidate(s), {stats['skipped']} skipped."
        ),
        changelog=None,
        activate=True,
    )
    release_manager.create_release(release_args)
    prune_args = argparse.Namespace(
        db=args.db,
        server_key=args.server_key,
        release_root=args.release_root,
        public_downloads=args.public_downloads,
        actor="daily_update",
        keep=2,
        dry_run=False,
        command="prune",
    )
    release_manager.prune_releases(prune_args)


def rebuild(args: argparse.Namespace) -> int:
    package_path, digest = rebuild_client_package(args.server_dir)
    mrpack = create_mrpack(args.server_dir)
    print(f"client_zip={package_path}")
    print(f"client_zip_sha256={digest}")
    print(f"mrpack={mrpack}")
    return 0


def enforce_safety(args: argparse.Namespace) -> int:
    server_removed = enforce_server_disables(args.server_dir)
    client_removed = enforce_client_exclusions(args.server_dir)
    print(f"server_removed={len(server_removed)}")
    for path, reason in server_removed:
        print(f"server_disabled={path.name}\treason={reason}")
    print(f"client_removed={len(client_removed)}")
    for path, reason in client_removed:
        print(f"client_disabled={path.name}\treason={reason}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", type=Path, default=DEFAULT_DB)
    parser.add_argument("--server-dir", type=Path, default=DEFAULT_SERVER_DIR)
    parser.add_argument("--server-key", default="minecraft_26_1_2")
    parser.add_argument("--timeout", type=int, default=900)
    parser.add_argument("--backup-dir", type=Path)
    sub = parser.add_subparsers(dest="command", required=True)

    scan = sub.add_parser("scan-apply", help="Scan for compatible updates and apply only tested-successful changes")
    scan.add_argument("--trigger", default="manual")
    scan.add_argument("--dry-run", action="store_true")
    scan.add_argument("--limit", type=int, default=0, help="Max mods to scan")
    scan.add_argument("--apply-limit", type=int, default=0, help="Max updates to apply")
    scan.add_argument("--release-root", type=Path, default=DEFAULT_RELEASE_ROOT)
    scan.add_argument("--public-downloads", type=Path, default=DEFAULT_PUBLIC_DOWNLOADS)
    scan.add_argument("--no-create-release", action="store_true")

    sub.add_parser("rebuild-client", help="Rebuild zip, sha256, and mrpack from current client-package")
    sub.add_parser("enforce-safety", help="Quarantine known bad server files and client-excluded files")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.command == "scan-apply":
        return scan_and_apply(args)
    if args.command == "rebuild-client":
        return rebuild(args)
    if args.command == "enforce-safety":
        return enforce_safety(args)
    raise SystemExit(f"unknown command: {args.command}")


if __name__ == "__main__":
    raise SystemExit(main())
