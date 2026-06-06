#!/usr/bin/env python3
"""Process queued Minecraft mod URLs from SQLite.

For each queued URL batch item, this script resolves current CurseForge
metadata, selects the newest compatible NeoForge 26.1.x file, downloads it,
tests server-side mods one at a time, and writes the result back to SQLite.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import re
import shutil
import sqlite3
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Iterable, Sequence

from moddb import HEADERS, connect, row_hash, slugify, source_kind, status_rank, utc_now


API_BASE = "https://api.curse.tools/v1/cf"
MODRINTH_API_BASE = "https://api.modrinth.com/v2"
USER_AGENT = "Mozilla/5.0 Codex Minecraft Mod Tracker"
TARGET_MC = "26.1.2"
COMPATIBLE_GAME_VERSIONS = ("26.1.2", "26.1.1", "26.1")
SERVER_DIR = Path("/var/minecraft_26.1.2")
RUN_PREFIX = "url_batch"
DOWNLOAD_DIR = SERVER_DIR / "codex-downloads" / RUN_PREFIX
CLIENT_MODS_DIR = SERVER_DIR / "client-package" / "mods"
KNOWN_IGNORED_ERROR_PATTERNS = (
    "com/cozary/tintedcampfires/campfire",
    "com.cozary.tintedcampfires.campfire",
    "io/github/mortuusars/sootychimneys/block/ChimneyBlock",
    "io.github.mortuusars.sootychimneys.block.ChimneyBlock",
    "net/minecraft/client/renderer/entity/state/AxolotlRenderState",
    "net.minecraft.client.renderer.entity.state.AxolotlRenderState",
    "MTSERROR",
    "Couldn't parse data file 'mts:",
    "Couldn't parse data file 'mtsofficialpack:",
    "com.google.gson.JsonSyntaxException: com.google.gson.stream.MalformedJsonException",
    "Caused by: com.google.gson.stream.MalformedJsonException",
    "com.google.gson.JsonSyntaxException: java.io.EOFException",
    "Caused by: java.io.EOFException",
    "Multi-version packs cannot support minimum version of less than 15",
    "Pack declares support for version newer than 81, but is missing mandatory fields min_format and max_format",
    "Error reading pack metadata, attempting fallback type",
    "Error reading optional pack metadata for mod/",
    "ResourceMetadata$2.getSection",
    "ResourcePackLoader.readMeta",
    "ResourcePackLoader.readWithOptionalMeta",
    "ResourcePackLoader.packFinder",
    "ResourcePackLoader.lambda$buildPackFinder",
    "PackRepository.discoverAvailable",
    "Couldn't parse data file 'stoneholm:",
    "Couldn't parse data file 'berezka_api:",
    "[Berezka API]",
    'java.lang.NullPointerException: Cannot invoke "java.util.Map.get(Object)" because "promos" is null',
    "Couldn't load tag forge:cherry_logs",
    "Couldn't load tag forge:saplings",
    "Couldn't parse data file 'forge:global_loot_modifiers'",
    "Couldn't parse data file 'neoforge:global_loot_modifiers'",
    "Couldn't parse data file 'maple:",
    "Couldn't parse data file 'electronic_device_mod:",
    "Couldn't parse data file 'bloom:",
    "Couldn't parse data file 'pv:",
    "Couldn't parse data file 'minecraft:chests/mineral'",
    "Error reading optional pack metadata for mod/mr_mots_structures",
    "Pack declares support for format 81",
    "com.mojang.serialization.DataResult$Error.getOrThrow",
    "Couldn't parse data file 'mot_structures:",
    "No starting jigsaw minecraft:start found in start pool mot_structures:well/",
    "Block-attached entity at invalid position",
    "[minecraft/BlockAttachedEntity]",
    "Exception caught in connection",
    "java.net.SocketException: Connection reset",
)
CLIENT_ONLY_HINTS = (
    "animation",
    "animations",
    "dynamiclights",
    "effects",
    "environment",
    "lambdynamiclights",
    "subtle-effects",
)


def today() -> str:
    return dt.datetime.now(dt.UTC).date().isoformat()


def safe_run_name(value: str) -> str:
    return re.sub(r"[^A-Za-z0-9]+", "_", value).strip("_") or "url_batch"


def api_json(url: str) -> dict[str, Any]:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=45) as response:
        return json.load(response)


def api_json_list(url: str) -> list[dict[str, Any]]:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=45) as response:
        return json.load(response)


def search_project(slug: str) -> dict[str, Any] | None:
    url = f"{API_BASE}/mods/search?gameId=432&slug={urllib.parse.quote(slug)}"
    data = api_json(url)
    projects = data.get("data", [])
    exact_mods = [p for p in projects if p.get("slug") == slug and p.get("classId") == 6]
    if exact_mods:
        return exact_mods[0]
    exact = [p for p in projects if p.get("slug") == slug]
    if exact:
        return exact[0]
    return projects[0] if projects else None


def get_project(mod_id: int) -> dict[str, Any]:
    return api_json(f"{API_BASE}/mods/{mod_id}")["data"]


def get_files(mod_id: int) -> list[dict[str, Any]]:
    return api_json(f"{API_BASE}/mods/{mod_id}/files?pageSize=200").get("data", [])


def release_channel(file_info: dict[str, Any]) -> str:
    if file_info.get("_source") == "modrinth":
        return str(file_info.get("versionType") or "unknown")
    return {1: "stable", 2: "beta", 3: "alpha"}.get(file_info.get("releaseType"), "unknown")


def compatible_file(file_info: dict[str, Any]) -> bool:
    versions = set(file_info.get("gameVersions") or [])
    return (
        bool(file_info.get("isAvailable", True))
        and file_info.get("fileStatus", 4) == 4
        and "NeoForge" in versions
        and any(version in versions for version in COMPATIBLE_GAME_VERSIONS)
    )


def loader_score(file_info: dict[str, Any]) -> int:
    name = (file_info.get("fileName") or "").lower()
    if "neoforge" in name or "neo_forge" in name or "-nf" in name or name.endswith("nf.jar"):
        return 0
    if "fabric" in name or "quilt" in name:
        return 2
    return 1


def side(file_info: dict[str, Any], slug: str) -> str:
    if file_info.get("_side"):
        return str(file_info["_side"])
    versions = set(file_info.get("gameVersions") or [])
    if "Server" in versions:
        return "server"
    if "Client" in versions:
        return "client"
    lower = slug.lower()
    if any(hint in lower for hint in CLIENT_ONLY_HINTS):
        return "client"
    return "unknown"


def choose_file(files: Iterable[dict[str, Any]]) -> dict[str, Any] | None:
    candidates = [file_info for file_info in files if compatible_file(file_info)]
    for release_type in (1, 2, 3):
        group = [file_info for file_info in candidates if file_info.get("releaseType") == release_type]
        if group:
            best_loader_score = min(loader_score(file_info) for file_info in group)
            loader_matches = [file_info for file_info in group if loader_score(file_info) == best_loader_score]
            return sorted(
                loader_matches,
                key=lambda file_info: (file_info.get("fileDate", ""), int(file_info.get("id", 0))),
                reverse=True,
            )[0]
    return None


def stable_project_url(project: dict[str, Any]) -> str:
    if project.get("_source") == "modrinth":
        project_type = project.get("project_type") or "mod"
        return f"https://modrinth.com/{project_type}/{project.get('slug')}"
    links = project.get("links") or {}
    website = links.get("websiteUrl")
    if website:
        return website
    return f"https://www.curseforge.com/minecraft/mc-mods/{project.get('slug')}"


def project_name(project: dict[str, Any]) -> str:
    return str(project.get("name") or project.get("title") or project.get("slug") or "Imported Mod")


def project_slug(project: dict[str, Any]) -> str:
    return str(project.get("slug") or project.get("name") or project.get("title") or "")


def modrinth_json(path: str) -> dict[str, Any]:
    return api_json(f"{MODRINTH_API_BASE}{path}")


def get_modrinth_project(slug_or_id: str) -> dict[str, Any]:
    project = modrinth_json(f"/project/{urllib.parse.quote(slug_or_id)}")
    project["_source"] = "modrinth"
    return project


def modrinth_versions(slug_or_id: str) -> list[dict[str, Any]]:
    params = urllib.parse.urlencode(
        {
            "loaders": json.dumps(["neoforge"]),
            "game_versions": json.dumps(list(COMPATIBLE_GAME_VERSIONS)),
        }
    )
    return api_json_list(f"{MODRINTH_API_BASE}/project/{urllib.parse.quote(slug_or_id)}/version?{params}")


def modrinth_project_side(project: dict[str, Any]) -> str:
    server_side = project.get("server_side")
    client_side = project.get("client_side")
    if server_side == "unsupported" and client_side in {"required", "optional"}:
        return "client"
    if server_side in {"required", "optional"}:
        return "server"
    return "unknown"


def choose_modrinth_file(project: dict[str, Any]) -> dict[str, Any] | None:
    versions = modrinth_versions(str(project.get("slug") or project.get("id")))
    release_order = {"release": 0, "beta": 1, "alpha": 2}
    candidates: list[dict[str, Any]] = []
    for version in versions:
        if "neoforge" not in set(version.get("loaders") or []):
            continue
        if not (set(version.get("game_versions") or []) & set(COMPATIBLE_GAME_VERSIONS)):
            continue
        files = version.get("files") or []
        primary = [file_info for file_info in files if file_info.get("primary")]
        selected = (primary or files or [None])[0]
        if not selected:
            continue
        candidates.append(
            {
                "_source": "modrinth",
                "_side": modrinth_project_side(project),
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
    if not candidates:
        return None
    return sorted(
        candidates,
        key=lambda file_info: (
            -release_order.get(str(file_info.get("versionType")), 9),
            str(file_info.get("datePublished") or ""),
            str(file_info.get("id") or ""),
        ),
        reverse=True,
    )[0]


def download_file(file_info: dict[str, Any], dest_dir: Path) -> Path:
    dest_dir.mkdir(parents=True, exist_ok=True)
    filename = file_info["fileName"]
    target = dest_dir / filename
    expected = int(file_info.get("fileLength") or 0)
    if target.exists() and (not expected or target.stat().st_size == expected):
        return target
    url = file_info.get("downloadUrl")
    if not url:
        file_id = int(file_info["id"])
        mod_id = int(file_info["modId"])
        url = f"https://www.curseforge.com/api/v1/mods/{mod_id}/files/{file_id}/download"
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=120) as response, target.open("wb") as handle:
        shutil.copyfileobj(response, handle)
    if expected and target.stat().st_size != expected:
        raise RuntimeError(f"downloaded size mismatch for {filename}")
    return target


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def existing_ok_mod(conn: sqlite3.Connection, slug: str) -> sqlite3.Row | None:
    return conn.execute(
        """
        SELECT m.*
        FROM mods m
        WHERE m.duplicate_of_id IS NULL
          AND m.canonical_key = ?
          AND m.active_status = 'ok'
        ORDER BY m.status_rank DESC, m.id ASC
        LIMIT 1
        """,
        (slugify(slug),),
    ).fetchone()


def ensure_dependency_mod(conn: sqlite3.Connection, project: dict[str, Any], now: str) -> int:
    slug = slugify(project_slug(project) or f"project-{project['id']}")
    existing = conn.execute(
        """
        SELECT id FROM mods
        WHERE duplicate_of_id IS NULL AND canonical_key = ?
        ORDER BY id LIMIT 1
        """,
        (slug,),
    ).fetchone()
    if existing:
        return int(existing["id"])

    import_id = ensure_import(conn, "process-url-batch-dependencies", now)
    name = project_name(project)
    url = stable_project_url(project)
    migration_note = "Auto-added as required dependency while processing SQLite URL batch."
    fingerprint = state_hash(
        name=name,
        installation="Server + client",
        entry_type="Dependency",
        tested="Pending",
        url=url,
        target_mc=TARGET_MC,
        server_status="Pending: dependency URL imported",
        server_file="",
        client_package="Pending",
        last_tested="",
        resolved_source="",
        migration_notes=migration_note,
    )
    next_row = conn.execute(
        "SELECT COALESCE(MAX(original_sheet_row), 0) + 1 AS row_number FROM mods"
    ).fetchone()["row_number"]
    cur = conn.execute(
        """
        INSERT INTO mods(
            import_id, original_sheet_row, category, name, canonical_key,
            installation, entry_type, tested, target_mc, server_status,
            client_package, last_tested, active_status, status_rank, primary_url,
            is_duplicate, duplicate_of_id, row_hash, created_at, updated_at
        ) VALUES (?, ?, 'Dependency', ?, ?, 'Server + client', 'Dependency',
            'Pending', ?, 'Pending: dependency URL imported', 'Pending', '',
            'pending', 10, ?, 0, NULL, ?, ?, ?)
        """,
        (import_id, next_row, name, slug, TARGET_MC, url, fingerprint, now, now),
    )
    mod_id = int(cur.lastrowid)
    conn.execute(
        "INSERT INTO mod_notes(mod_id, notes_1, notes_2, migration_notes) VALUES (?, '', '', ?)",
        (mod_id, migration_note),
    )
    kind, host, source_project_slug = source_kind(url)
    conn.execute(
        """
        INSERT INTO source_urls(
            mod_id, source_kind, url, host, project_slug, resolved_source,
            file_id, release_channel, is_primary
        ) VALUES (?, ?, ?, ?, ?, '', '', '', 1)
        """,
        (mod_id, kind, url, host, source_project_slug),
    )
    return mod_id


def ensure_import(conn: sqlite3.Connection, source_range: str, now: str) -> int:
    cur = conn.execute(
        """
        INSERT INTO imports(
            imported_at, source_file, spreadsheet_id, sheet_name, source_range, row_count
        ) VALUES (?, ?, NULL, ?, ?, 0)
        """,
        (now, "process_url_batch.py", "SQLite URL Batch", source_range),
    )
    return int(cur.lastrowid)


def append_note(conn: sqlite3.Connection, mod_id: int, addition: str) -> None:
    row = conn.execute(
        "SELECT notes_1, notes_2, migration_notes FROM mod_notes WHERE mod_id = ?",
        (mod_id,),
    ).fetchone()
    notes_1 = row["notes_1"] if row else ""
    notes_2 = row["notes_2"] if row else ""
    existing = (row["migration_notes"] if row else "") or ""
    merged = existing if addition in existing else f"{existing} {addition}".strip()
    conn.execute(
        """
        INSERT INTO mod_notes(mod_id, notes_1, notes_2, migration_notes)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(mod_id) DO UPDATE SET
            notes_1 = excluded.notes_1,
            notes_2 = excluded.notes_2,
            migration_notes = excluded.migration_notes
        """,
        (mod_id, notes_1 or "", notes_2 or "", merged),
    )


def state_hash(
    *,
    name: str,
    installation: str,
    entry_type: str,
    tested: str,
    url: str,
    target_mc: str,
    server_status: str,
    server_file: str,
    client_package: str,
    last_tested: str,
    resolved_source: str,
    migration_notes: str,
) -> str:
    cells = [
        name,
        installation,
        entry_type,
        tested,
        "",
        "",
        url,
        target_mc,
        server_status,
        server_file,
        client_package,
        last_tested,
        resolved_source,
        migration_notes,
    ]
    if len(cells) != len(HEADERS):
        raise ValueError("row shape drifted")
    return row_hash(cells)


def set_mod_state(
    conn: sqlite3.Connection,
    *,
    mod_id: int,
    project: dict[str, Any] | None,
    file_info: dict[str, Any] | None,
    status: str,
    server_status: str,
    client_package: str,
    installed_server: bool,
    included_client: bool,
    files: Sequence[str],
    note: str,
    entry_type: str | None = None,
    installation: str | None = None,
    file_role: str = "server_file",
    path_hint: str | None = None,
) -> None:
    row = conn.execute("SELECT * FROM mods WHERE id = ?", (mod_id,)).fetchone()
    if not row:
        raise RuntimeError(f"missing mod row {mod_id}")
    name = project_name(project) if project else row["name"]
    url = stable_project_url(project) if project else row["primary_url"]
    resolved_source = ""
    file_id = ""
    channel = ""
    if file_info:
        file_id = str(file_info["id"])
        channel = release_channel(file_info)
        source_name = "Modrinth" if file_info.get("_source") == "modrinth" else "CurseForge"
        resolved_source = f"{source_name} {channel} release file {file_id}"
    active_status, rank = status_rank(status, server_status, client_package)
    last_tested = today()
    server_file = "; ".join(files)
    migration_notes = note
    fingerprint = state_hash(
        name=name,
        installation=installation or row["installation"] or "Server + client",
        entry_type=entry_type or row["entry_type"] or "Mod",
        tested=status,
        url=url,
        target_mc=TARGET_MC,
        server_status=server_status,
        server_file=server_file,
        client_package=client_package,
        last_tested=last_tested,
        resolved_source=resolved_source,
        migration_notes=migration_notes,
    )
    now = utc_now()
    conn.execute(
        """
        UPDATE mods
        SET name = ?, installation = ?, entry_type = ?, tested = ?,
            target_mc = ?, server_status = ?, client_package = ?,
            last_tested = ?, active_status = ?, status_rank = ?, primary_url = ?,
            row_hash = ?, updated_at = ?
        WHERE id = ?
        """,
        (
            name,
            installation or row["installation"] or "Server + client",
            entry_type or row["entry_type"] or "Mod",
            status,
            TARGET_MC,
            server_status,
            client_package,
            last_tested,
            active_status,
            rank,
            url,
            fingerprint,
            now,
            mod_id,
        ),
    )
    append_note(conn, mod_id, note)
    kind, host, slug = source_kind(url)
    conn.execute("DELETE FROM source_urls WHERE mod_id = ?", (mod_id,))
    conn.execute(
        """
        INSERT INTO source_urls(
            mod_id, source_kind, url, host, project_slug, resolved_source,
            file_id, release_channel, is_primary
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1)
        """,
        (mod_id, kind, url, host, slug, resolved_source, file_id, channel),
    )
    conn.execute("DELETE FROM mod_files WHERE mod_id = ?", (mod_id,))
    stored_path_hint = path_hint or str(SERVER_DIR / "mods" if installed_server else SERVER_DIR / "mods.failed")
    for filename in files:
        conn.execute(
            """
            INSERT INTO mod_files(
                mod_id, role, file_name, path_hint, installed_on_server,
                included_in_client, status
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            (
                mod_id,
                file_role,
                filename,
                stored_path_hint,
                int(installed_server),
                int(included_client),
                server_status,
            ),
        )


def update_batch_item(conn: sqlite3.Connection, item_id: int, process_status: str, note: str) -> None:
    conn.execute(
        """
        UPDATE url_batch_items
        SET process_status = ?, note = ?, updated_at = ?
        WHERE id = ?
        """,
        (process_status, note, utc_now(), item_id),
    )


def insert_test_run(
    conn: sqlite3.Connection,
    mod_id: int,
    label: str,
    status: str,
    error_count: int,
    log_path: str,
    notes: str,
) -> None:
    conn.execute(
        """
        INSERT INTO test_runs(mod_id, tested_at, test_label, status, error_count, log_path, notes)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """,
        (mod_id, utc_now(), label, status, error_count, log_path, notes),
    )


def install_to(path: Path, dest_dir: Path) -> Path:
    dest_dir.mkdir(parents=True, exist_ok=True)
    target = dest_dir / path.name
    if target.exists() and target.stat().st_size == path.stat().st_size:
        return target
    shutil.copy2(path, target)
    return target


def move_to_failed(path: Path, label: str) -> Path:
    failed_dir = SERVER_DIR / "mods.failed" / label
    failed_dir.mkdir(parents=True, exist_ok=True)
    target = failed_dir / path.name
    if path.exists():
        shutil.move(str(path), str(target))
    return target


def filtered_error_lines(errors_path: Path) -> list[str]:
    if not errors_path.exists():
        return []
    severe: list[str] = []
    for line in errors_path.read_text(encoding="utf-8", errors="replace").splitlines():
        if any(pattern in line for pattern in KNOWN_IGNORED_ERROR_PATTERNS):
            continue
        severe.append(line)
    return severe


def run_server_test(label: str, timeout: int) -> tuple[bool, str, int, list[str], str]:
    DOWNLOAD_DIR.mkdir(parents=True, exist_ok=True)
    output_path = DOWNLOAD_DIR / f"{label}.test-output.txt"
    proc = subprocess.run(
        [str(SERVER_DIR / "codex-test-server.sh"), label, str(timeout)],
        cwd=SERVER_DIR,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=timeout + 90,
        check=False,
    )
    output_path.write_text(proc.stdout, encoding="utf-8")
    status_match = re.search(r"^STATUS=(.+)$", proc.stdout, re.MULTILINE)
    error_match = re.search(r"^ERROR_LINES=(\d+)$", proc.stdout, re.MULTILINE)
    log_match = re.search(r"^LOG=(.+)$", proc.stdout, re.MULTILINE)
    errors_match = re.search(r"^ERRORS=(.+)$", proc.stdout, re.MULTILINE)
    status = status_match.group(1).strip() if status_match else "unknown"
    error_count = int(error_match.group(1)) if error_match else 999
    log_path = log_match.group(1).strip() if log_match else str(SERVER_DIR / "server-test-results" / f"{label}.log")
    errors_path = Path(errors_match.group(1).strip()) if errors_match else SERVER_DIR / "server-test-results" / f"{label}.errors"
    severe = filtered_error_lines(errors_path)
    ok = status == "started" and not severe
    return ok, status, error_count, severe, log_path


def run_isolated_acceptance_test(label: str, files: Sequence[Path], db_path: Path, timeout: int) -> tuple[bool, str, list[str], str]:
    DOWNLOAD_DIR.mkdir(parents=True, exist_ok=True)
    output_path = DOWNLOAD_DIR / f"{label}.isolated-output.txt"
    command = [
        sys.executable,
        str(Path(__file__).resolve().parent / "mod_acceptance_lab.py"),
        "--db",
        str(db_path),
        "--server-dir",
        str(SERVER_DIR),
        "run-files",
        "--run-label",
        f"{label}_isolated",
        "--boot-timeout",
        str(timeout),
        "--idle-seconds",
        "45",
        "--include-active-deps",
        "--candidate-group-size",
        "10",
        "--random-seed",
        label,
        *[str(path) for path in files],
    ]
    proc = subprocess.run(
        command,
        cwd=Path(__file__).resolve().parent.parent,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=timeout + 180,
        check=False,
    )
    output_path.write_text(proc.stdout, encoding="utf-8")
    status_match = re.search(r"^status=(.+)$", proc.stdout, re.MULTILINE)
    log_match = re.search(r"^log_path=(.+)$", proc.stdout, re.MULTILINE)
    status = status_match.group(1).strip() if status_match else f"exit_{proc.returncode}"
    log_path = log_match.group(1).strip() if log_match else str(output_path)
    severe: list[str] = []
    if "--- severe errors ---" in proc.stdout:
        severe = [
            line
            for line in proc.stdout.split("--- severe errors ---", 1)[1].splitlines()
            if line.strip()
        ][:20]
    ok = proc.returncode == 0 and status == "passed"
    return ok, status, severe, log_path


def required_dependency_ids(file_info: dict[str, Any]) -> list[int]:
    return [
        int(dep["modId"])
        for dep in file_info.get("dependencies") or []
        if int(dep.get("relationType", 0)) == 3
    ]


def required_dependency_refs(file_info: dict[str, Any]) -> list[tuple[str, str]]:
    if file_info.get("_source") == "modrinth":
        return [
            ("modrinth", str(dep["project_id"]))
            for dep in file_info.get("dependencies") or []
            if dep.get("dependency_type") == "required" and dep.get("project_id")
        ]
    return [("curseforge", str(dep_id)) for dep_id in required_dependency_ids(file_info)]


def resolve_required_dependencies(
    conn: sqlite3.Connection,
    file_info: dict[str, Any],
    now: str,
) -> tuple[list[tuple[int, dict[str, Any], dict[str, Any], Path]], list[str]]:
    candidates: list[tuple[dict[str, Any], dict[str, Any]]] = []
    resolved: list[tuple[int, dict[str, Any], dict[str, Any], Path]] = []
    problems: list[str] = []
    for source, dep_ref in required_dependency_refs(file_info):
        if source == "modrinth":
            dep_project = get_modrinth_project(dep_ref)
            dep_file = choose_modrinth_file(dep_project)
        else:
            dep_project = get_project(int(dep_ref))
            dep_file = choose_file(get_files(int(dep_ref)))
        dep_slug = project_slug(dep_project) or dep_ref
        existing = existing_ok_mod(conn, dep_slug)
        if existing:
            continue
        if not dep_file:
            problems.append(f"required dependency {project_name(dep_project)} has no compatible NeoForge 26.1.x file")
            continue
        dep_side = side(dep_file, dep_slug)
        if dep_side == "client":
            problems.append(f"required dependency {project_name(dep_project)} resolved as client-only")
            continue
        candidates.append((dep_project, dep_file))
    if problems:
        return [], problems
    for dep_project, dep_file in candidates:
        dep_mod_id = ensure_dependency_mod(conn, dep_project, now)
        dep_path = download_file(dep_file, DOWNLOAD_DIR)
        resolved.append((dep_mod_id, dep_project, dep_file, dep_path))
    return resolved, problems


def process_item(
    conn: sqlite3.Connection,
    item: sqlite3.Row,
    *,
    db_path: Path,
    timeout: int,
    test_enabled: bool,
) -> str:
    mod_id = int(item["mod_id"])
    slug = item["canonical_key"]
    source = item["source_kind"]
    project_ref = item["project_slug"] or slug
    now = utc_now()
    try:
        if source == "modrinth":
            project = get_modrinth_project(project_ref)
        else:
            project = search_project(slug)
        if not project:
            source_name = "Modrinth" if source == "modrinth" else "CurseForge"
            note = f"Skipped: project was not found through the {source_name} metadata API."
            set_mod_state(
                conn,
                mod_id=mod_id,
                project=None,
                file_info=None,
                status="Skipped",
                server_status="Skipped: project not found",
                client_package="Not included",
                installed_server=False,
                included_client=False,
                files=[],
                note=note,
            )
            update_batch_item(conn, int(item["batch_item_id"]), "skipped", note)
            return f"skipped {slug}: project not found"

        if source == "modrinth":
            file_info = choose_modrinth_file(project)
        else:
            files = get_files(int(project["id"]))
            file_info = choose_file(files)
        if not file_info:
            source_name = "Modrinth" if source == "modrinth" else "CurseForge"
            note = f"Skipped: no compatible NeoForge 26.1.x release found via current {source_name} metadata."
            set_mod_state(
                conn,
                mod_id=mod_id,
                project=project,
                file_info=None,
                status="Skipped",
                server_status="Skipped: no compatible release",
                client_package="Not included",
                installed_server=False,
                included_client=False,
                files=[],
                note=note,
            )
            update_batch_item(conn, int(item["batch_item_id"]), "skipped", note)
            return f"skipped {slug}: no compatible file"

        selected_side = side(file_info, slug)
        file_path = download_file(file_info, DOWNLOAD_DIR)
        channel = release_channel(file_info)
        source_name = "Modrinth" if file_info.get("_source") == "modrinth" else "CurseForge"
        file_note = (
            f"Selected {source_name} {channel} file {file_info['id']} "
            f"({file_info['fileName']}) for NeoForge 26.1.x."
        )

        if selected_side == "client":
            client_path = install_to(file_path, CLIENT_MODS_DIR)
            note = f"{file_note} Client-only file added to client package as {client_path.name}; not installed on server."
            set_mod_state(
                conn,
                mod_id=mod_id,
                project=project,
                file_info=file_info,
                status="OK",
                server_status="Client-only: included",
                client_package="Included",
                installed_server=False,
                included_client=True,
                files=[client_path.name],
                note=note,
                installation="Client only",
            )
            update_batch_item(conn, int(item["batch_item_id"]), "ok", note)
            return f"ok-client {slug}: {client_path.name}"

        dependencies, dependency_problems = resolve_required_dependencies(conn, file_info, now)
        if dependency_problems:
            note = f"{file_note} Skipped: " + "; ".join(dependency_problems) + "."
            set_mod_state(
                conn,
                mod_id=mod_id,
                project=project,
                file_info=file_info,
                status="Skipped",
                server_status="Skipped: missing compatible dependency",
                client_package="Not included",
                installed_server=False,
                included_client=False,
                files=[],
                note=note,
            )
            update_batch_item(conn, int(item["batch_item_id"]), "skipped", note)
            return f"skipped {slug}: dependency problem"

        if not test_enabled:
            note = f"{file_note} Compatible server candidate found; server test deferred."
            append_note(conn, mod_id, note)
            update_batch_item(conn, int(item["batch_item_id"]), "candidate", note)
            return f"candidate {slug}: {file_info['fileName']}"

        label = f"{RUN_PREFIX}_{int(item['ordinal']):03d}_{slugify(slug)}"
        isolated_files = [dep_path for *_rest, dep_path in dependencies] + [file_path]
        isolated_ok, isolated_status, isolated_severe, isolated_log_path = run_isolated_acceptance_test(
            label,
            isolated_files,
            db_path,
            timeout,
        )
        if not isolated_ok:
            severe_summary = " | ".join(isolated_severe[:3]) if isolated_severe else f"status={isolated_status}"
            note = f"{file_note} Rejected before live install by isolated acceptance lab {label}_isolated: {severe_summary}"
            set_mod_state(
                conn,
                mod_id=mod_id,
                project=project,
                file_info=file_info,
                status="Failed",
                server_status="Rejected: isolated acceptance error",
                client_package="Not included",
                installed_server=False,
                included_client=False,
                files=[file_path.name],
                note=note,
            )
            insert_test_run(conn, mod_id, f"{label}_isolated", isolated_status, len(isolated_severe), isolated_log_path, note)
            update_batch_item(conn, int(item["batch_item_id"]), "failed", note)
            return f"failed {slug}: isolated acceptance {severe_summary}"

        installed_paths: list[Path] = []
        installed_infos: list[tuple[int, dict[str, Any], dict[str, Any], Path]] = []
        for dep_mod_id, dep_project, dep_file, dep_path in dependencies:
            dep_target_path = SERVER_DIR / "mods" / dep_path.name
            dep_existed = dep_target_path.exists()
            target = install_to(dep_path, SERVER_DIR / "mods")
            if not dep_existed:
                installed_paths.append(target)
            installed_infos.append((dep_mod_id, dep_project, dep_file, target))
        main_target_path = SERVER_DIR / "mods" / file_path.name
        main_existed = main_target_path.exists()
        main_target = install_to(file_path, SERVER_DIR / "mods")
        if not main_existed:
            installed_paths.append(main_target)

        ok, test_status, error_count, severe, log_path = run_server_test(label, timeout)
        if ok:
            for dep_mod_id, dep_project, dep_file, dep_target in installed_infos:
                install_to(dep_target, CLIENT_MODS_DIR)
                dep_note = f"Accepted as required dependency during {label}; server reached Done with no severe filtered errors."
                set_mod_state(
                    conn,
                    mod_id=dep_mod_id,
                    project=dep_project,
                    file_info=dep_file,
                    status="OK",
                    server_status="OK",
                    client_package="Included",
                    installed_server=True,
                    included_client=True,
                    files=[dep_target.name],
                    note=dep_note,
                    entry_type="Dependency",
                )
                insert_test_run(conn, dep_mod_id, label, test_status, error_count, log_path, dep_note)
            client_path = install_to(main_target, CLIENT_MODS_DIR)
            note = f"{file_note} Isolated acceptance lab passed, then boot test {label} reached Done with no severe filtered errors."
            set_mod_state(
                conn,
                mod_id=mod_id,
                project=project,
                file_info=file_info,
                status="OK",
                server_status="OK",
                client_package="Included",
                installed_server=True,
                included_client=True,
                files=[main_target.name],
                note=note,
            )
            insert_test_run(conn, mod_id, label, test_status, error_count, log_path, note)
            update_batch_item(conn, int(item["batch_item_id"]), "ok", note)
            return f"ok-server {slug}: {client_path.name}"

        failed_paths = [move_to_failed(path, label) for path in installed_paths]
        severe_summary = " | ".join(severe[:3]) if severe else f"status={test_status}"
        note = f"{file_note} Isolated acceptance lab passed, but rejected after full-pack boot test {label}: {severe_summary}"
        set_mod_state(
            conn,
            mod_id=mod_id,
            project=project,
            file_info=file_info,
            status="Failed",
            server_status="Rejected: boot test error",
            client_package="Not included",
            installed_server=False,
            included_client=False,
            files=[path.name for path in failed_paths],
            note=note,
        )
        insert_test_run(conn, mod_id, label, test_status, error_count, log_path, note)
        update_batch_item(conn, int(item["batch_item_id"]), "failed", note)
        return f"failed {slug}: {severe_summary}"
    except (urllib.error.URLError, TimeoutError, RuntimeError, subprocess.TimeoutExpired) as exc:
        note = f"Processing error: {type(exc).__name__}: {exc}"
        append_note(conn, mod_id, note)
        update_batch_item(conn, int(item["batch_item_id"]), "error", note)
        return f"error {slug}: {type(exc).__name__}"


def rebuild_client_package(db_path: Path) -> None:
    rebuild_script = Path(__file__).resolve().parent / "daily_update.py"
    subprocess.run(
        [
            sys.executable,
            str(rebuild_script),
            "--db",
            str(db_path),
            "--server-dir",
            str(SERVER_DIR),
            "rebuild-client",
        ],
        check=True,
    )


def load_items(conn: sqlite3.Connection, batch_name: str, statuses: Sequence[str], limit: int) -> list[sqlite3.Row]:
    placeholders = ",".join("?" for _ in statuses)
    params: list[Any] = [batch_name, *statuses]
    sql = f"""
        SELECT ubi.id AS batch_item_id, ubi.ordinal, ubi.canonical_key, ubi.mod_id,
               ubi.source_kind, ubi.project_slug,
               m.name, m.primary_url, m.active_status
        FROM url_batch_items ubi
        JOIN mods m ON m.id = ubi.mod_id
        WHERE ubi.batch_id = (SELECT id FROM url_batches WHERE batch_name = ?)
          AND ubi.process_status IN ({placeholders})
        ORDER BY ubi.ordinal
    """
    if limit:
        sql += " LIMIT ?"
        params.append(limit)
    return conn.execute(sql, params).fetchall()


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", type=Path, default=Path("data/minecraft_mods.sqlite"))
    parser.add_argument("--batch-name", required=True)
    parser.add_argument("--limit", type=int, default=0, help="Maximum queued items to process; 0 means all")
    parser.add_argument("--timeout", type=int, default=300, help="Per server boot-test timeout in seconds")
    parser.add_argument("--metadata-only", action="store_true", help="Resolve metadata but do not install/test server files")
    parser.add_argument(
        "--statuses",
        default="queued",
        help="Comma-separated url_batch_items.process_status values to process",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    global RUN_PREFIX, DOWNLOAD_DIR
    RUN_PREFIX = safe_run_name(args.batch_name)
    DOWNLOAD_DIR = SERVER_DIR / "codex-downloads" / RUN_PREFIX
    DOWNLOAD_DIR.mkdir(parents=True, exist_ok=True)
    statuses = [status.strip() for status in args.statuses.split(",") if status.strip()]
    with connect(args.db) as conn:
        items = load_items(conn, args.batch_name, statuses, args.limit)
        print(f"items={len(items)}")
        package_changed = False
        for index, item in enumerate(items, start=1):
            result = process_item(
                conn,
                item,
                db_path=args.db,
                timeout=args.timeout,
                test_enabled=not args.metadata_only,
            )
            conn.commit()
            print(f"{index}/{len(items)} {result}", flush=True)
            if result.startswith("ok-"):
                package_changed = True
            time.sleep(0.2)
    if package_changed and not args.metadata_only:
        rebuild_client_package(args.db)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
