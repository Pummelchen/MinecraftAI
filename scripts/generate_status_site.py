#!/usr/bin/env python3
"""Generate the static Pummelchen Server status site."""

from __future__ import annotations

import argparse
import datetime as dt
import html
import json
import os
import platform
import re
import shutil
import sqlite3
import subprocess
import sys
from pathlib import Path
from typing import Any
from urllib.parse import quote, urlparse

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from moddb import connect
from pummelchen_utils import MRPACK_NAME, SERVER_HOST, SERVER_MC_PORT, SERVER_PUBLIC_URL, display_release_version, human_bytes, table_exists


DEFAULT_DB = Path("/var/minecraft_mods/data/minecraft_mods.sqlite")
DEFAULT_OUTPUT = Path("/var/minecraft_mods/site/public")
DEFAULT_SERVER = Path("/var/minecraft_26.1.2")
DEFAULT_PUBLIC_URL = SERVER_PUBLIC_URL
CLIENT_ZIP_NAME = "minecraft_26.1.2_client_macos_apple_silicon.zip"
INSTALLER_NAME = "install-pummelchen.command"
CLIENT_DMG_NAME = "Pummelchen-Client-Installer.dmg"
CLIENT_SYNC_MANIFEST_NAME = "client-sync-manifest.tsv"
CLIENT_FILES_DIR_NAME = "client-files"
RELEASE_REPORT_FILE = "report.html"
UPDATE_LOG_DAYS = 7
HERO_IMAGE_NAME = "pummelchen-hero.png"
SEED_MAPPER_BASE_URL = "https://mcseedmap.net/1.21.5-Java"


GROUP_RULES: list[tuple[str, tuple[str, ...]]] = [
    ("Performance", ("sodium", "lithium", "ferrite", "modernfix", "ai-improvements", "alternate_current", "servercore", "connectivity", "dynamicviewdist")),
    ("Worldgen and Structures", ("structure", "structures", "dungeon", "village", "tower", "towers", "terralith", "biomes", "geophilic", "ecologics", "incendium", "ruins", "tomb", "castle", "city", "temple")),
    ("Building and Decor", ("macaw", "mcw-", "furniture", "roof", "door", "window", "bridge", "fence", "trapdoor", "stoneworks", "display", "painting", "decor", "modernarch", "bsl", "dramatic")),
    ("Mobs and Wildlife", ("animal", "alex", "mob", "mobs", "villager", "guard", "goblin", "duck", "rabbit", "cat", "fish", "aquaculture", "golem", "piglin", "illager")),
    ("Food and Farming", ("crop", "cooking", "food", "chili", "milk", "harvest", "watering", "tree", "leaves", "farm", "kitchen")),
    ("Tools and Utility", ("leash", "fishing", "backpack", "map", "torch", "magnum", "bucket", "helmet", "trading", "door", "config", "names")),
    ("Weapons and Gear", ("gun", "guns", "armor", "bow", "weapon", "shield", "artifact", "cannon")),
    ("Libraries and Dependencies", ("lib", "library", "api", "core", "framework", "balm", "collective", "gecko", "puzzles", "catalogue", "cloth", "cupboard", "resourceful", "prickle", "terrablender", "lithostitched", "monolib")),
    ("Client Visuals", ("iris", "shader", "resourcepack", "resource pack", "texture", "dynamiclights", "animation", "environment", "visual")),
]

GROUP_DESCRIPTIONS = {
    "Performance": "It focuses on reducing load, improving tick behavior, or making rendering and data handling smoother. These entries are included to keep a large mod set practical on the VPS and playable on Apple Silicon clients.",
    "Worldgen and Structures": "It changes exploration by adding terrain, buildings, ruins, dungeons, villages, or other generated landmarks. These mods make a fresh world feel more varied without needing a prebuilt map.",
    "Building and Decor": "It adds blocks, decorative options, props, furniture, visual packs, or building details. These entries are mostly about making bases, towns, and shared builds look better.",
    "Mobs and Wildlife": "It adds or adjusts creatures, villagers, animal behavior, encounters, or ambient life. These mods make the world feel more populated and give players more things to discover.",
    "Food and Farming": "It expands farming, cooking, food loops, crops, harvesting, or nature-adjacent tools. These entries support slower base-building and survival progression.",
    "Tools and Utility": "It adds quality-of-life behavior, small tools, convenience mechanics, or server-friendly utility features. These mods are meant to reduce repetitive friction without changing the whole game loop.",
    "Weapons and Gear": "It adds equipment, weapons, armor, combat tools, or loot-facing progression. These mods give players more choices in fights and exploration rewards.",
    "Libraries and Dependencies": "It mainly provides shared code, APIs, config plumbing, or compatibility layers used by other mods. It may not add visible gameplay by itself, but removing it can break dependent mods.",
    "Client Visuals": "It changes client-side presentation such as shaders, lighting, textures, animations, or resource-pack visuals. These entries are usually important for the Mac client package but not installed as server gameplay mods.",
    "Gameplay": "It changes or extends gameplay in a focused way. The tracker keeps it versioned with the Pummelchen NeoForge setup so updates can be tested cleanly.",
}


def run_text(cmd: list[str]) -> str:
    try:
        return subprocess.check_output(cmd, text=True, stderr=subprocess.STDOUT, timeout=10).strip()
    except Exception:
        return ""


def read_key_value_file(path: Path) -> dict[str, str]:
    data: dict[str, str] = {}
    if not path.exists():
        return data
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        data[key] = value.strip().strip('"')
    return data


def pct(used: float, total: float) -> str:
    if not total:
        return "0%"
    return f"{max(0.0, min(100.0, (used / total) * 100)):.1f}%"


def parse_meminfo() -> dict[str, int]:
    values: dict[str, int] = {}
    path = Path("/proc/meminfo")
    if not path.exists():
        return values
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        parts = line.split()
        if len(parts) >= 2:
            values[parts[0].rstrip(":")] = int(parts[1]) * 1024
    return values


def parse_cpuinfo() -> dict[str, str]:
    lscpu = run_text(["lscpu"])
    values: dict[str, str] = {}
    for line in lscpu.splitlines():
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        values[key.strip()] = value.strip()
    if not values and Path("/proc/cpuinfo").exists():
        for line in Path("/proc/cpuinfo").read_text(encoding="utf-8", errors="replace").splitlines():
            if line.startswith("model name"):
                values["Model name"] = line.split(":", 1)[1].strip()
                break
    return values


def uptime_text() -> str:
    try:
        seconds = float(Path("/proc/uptime").read_text().split()[0])
    except Exception:
        return "Unknown"
    days, rem = divmod(int(seconds), 86400)
    hours, rem = divmod(rem, 3600)
    minutes, _ = divmod(rem, 60)
    if days:
        return f"{days}d {hours}h {minutes}m"
    if hours:
        return f"{hours}h {minutes}m"
    return f"{minutes}m"


def detect_neoforge(server_dir: Path) -> str:
    nf_dir = server_dir / "libraries" / "net" / "neoforged" / "neoforge"
    if not nf_dir.exists():
        return "Unknown"
    versions = sorted([path.name for path in nf_dir.iterdir() if path.is_dir()])
    return versions[-1] if versions else "Unknown"


def detect_java(binary: str = "java") -> str:
    text = run_text([binary, "-version"])
    if not text:
        return "Unknown"
    first = text.splitlines()[0]
    return first.replace('"', "")


def detect_server_java_binary(server_dir: Path) -> str:
    run_script = server_dir / "run.sh"
    if not run_script.exists():
        return ""
    text = run_script.read_text(encoding="utf-8", errors="replace")
    match = re.search(r"exec\s+([^\s]+/java)\s", text)
    if match:
        return match.group(1)
    return ""


def detect_server_java(server_dir: Path) -> str:
    binary = detect_server_java_binary(server_dir)
    if binary:
        version = detect_java(binary)
        return version
    return detect_java()


def collect_stats(server_dir: Path) -> dict[str, str]:
    os_release = read_key_value_file(Path("/etc/os-release"))
    mem = parse_meminfo()
    total = mem.get("MemTotal", 0)
    available = mem.get("MemAvailable", 0)
    used = max(total - available, 0)
    cpu = parse_cpuinfo()
    server_disk = shutil.disk_usage(server_dir if server_dir.exists() else "/")
    zip_path = server_dir / CLIENT_ZIP_NAME
    sha_path = server_dir / f"{CLIENT_ZIP_NAME}.sha256"
    sha = ""
    if sha_path.exists():
        sha = sha_path.read_text(encoding="utf-8", errors="replace").split()[0]
    client_pack_generated = "Missing"
    client_pack_generated_iso = ""
    if zip_path.exists():
        mtime = dt.datetime.fromtimestamp(zip_path.stat().st_mtime, tz=dt.timezone.utc)
        client_pack_generated = mtime.strftime("%Y-%m-%d %H:%M UTC")
        client_pack_generated_iso = mtime.isoformat(timespec="seconds")
    server_props = read_key_value_file(server_dir / "server.properties")
    world_seed = server_props.get("level-seed", "")
    return {
        "Server OS": os_release.get("PRETTY_NAME", platform.platform()),
        "OS Kernel": platform.release(),
        "Uptime": uptime_text(),
        "CPU": cpu.get("Model name") or cpu.get("Model") or "Unknown",
        "CPU Cores": cpu.get("CPU(s)", str(os.cpu_count() or "Unknown")),
        "CPU usage": "Waiting for live feed",
        "RAM total": human_bytes(total),
        "RAM used": f"{human_bytes(used)} ({pct(used, total)})",
        "RAM available": human_bytes(available),
        "Disk used/free": (
            f"{human_bytes(server_disk.used)} / {human_bytes(server_disk.total)} "
            f"({pct(server_disk.used, server_disk.total)}); {human_bytes(server_disk.free)} free"
        ),
        "Server Java": detect_java(),
        "Minecraft Java": detect_server_java(server_dir),
        "Minecraft": "26.1.2",
        "NeoForge": detect_neoforge(server_dir),
        "Client Mod Pack": human_bytes(zip_path.stat().st_size) if zip_path.exists() else "Missing",
        "Client Mod Pack SHA256": sha or "Missing",
        "Client Mod Pack Generated": client_pack_generated,
        "Client Mod Pack Generated ISO": client_pack_generated_iso,
        "World Seed": world_seed,
    }


def fetch_mods(conn: sqlite3.Connection) -> list[dict[str, Any]]:
    rows = conn.execute(
        """
        SELECT
            m.id, m.name, m.canonical_key, m.category, m.entry_type,
            m.primary_url, m.server_status, m.client_package, m.target_mc,
            m.last_tested, n.notes_1, n.notes_2, n.migration_notes
        FROM mods m
        LEFT JOIN mod_notes n ON n.mod_id = m.id
        WHERE m.duplicate_of_id IS NULL
          AND m.active_status = 'ok'
        ORDER BY lower(m.name), m.id
        """
    ).fetchall()
    if not rows:
        return []
    ids = [int(row["id"]) for row in rows]
    placeholders = ",".join("?" for _ in ids)
    files: dict[int, list[dict[str, Any]]] = {mod_id: [] for mod_id in ids}
    for row in conn.execute(
        f"""
        SELECT mod_id, role, file_name, path_hint, installed_on_server,
               included_in_client, status
        FROM mod_files
        WHERE mod_id IN ({placeholders})
        ORDER BY installed_on_server DESC, included_in_client DESC, file_name
        """,
        ids,
    ):
        files[int(row["mod_id"])].append(dict(row))
    sources: dict[int, list[str]] = {mod_id: [] for mod_id in ids}
    for row in conn.execute(
        f"""
        SELECT mod_id, url
        FROM source_urls
        WHERE mod_id IN ({placeholders})
        ORDER BY is_primary DESC, id
        """,
        ids,
    ):
        sources[int(row["mod_id"])].append(str(row["url"]))
    metadata: dict[int, sqlite3.Row] = {}
    if table_exists(conn, "mod_metadata"):
        for row in conn.execute(
            f"""
            SELECT *
            FROM mod_metadata
            WHERE mod_id IN ({placeholders})
            """,
            ids,
        ):
            metadata[int(row["mod_id"])] = row
    performance: dict[int, sqlite3.Row] = {}
    if table_exists(conn, "mod_performance_profiles"):
        for row in conn.execute(
            f"""
            SELECT p.*, si.server_key
            FROM mod_performance_profiles p
            JOIN server_instances si ON si.id = p.server_instance_id
            WHERE p.mod_id IN ({placeholders})
            ORDER BY p.measured_at DESC
            """,
            ids,
        ):
            performance.setdefault(int(row["mod_id"]), row)
    mods: list[dict[str, Any]] = []
    for row in rows:
        mod = dict(row)
        mod["files"] = files[int(row["id"])]
        mod["sources"] = sources[int(row["id"])]
        meta = metadata.get(int(row["id"]))
        perf = performance.get(int(row["id"]))
        mod["group"] = (meta["group_tag"] if meta and meta["group_tag"] else "") or group_for_mod(mod)
        mod["version"] = version_text(mod["files"])
        mod["description"] = (meta["summary"] if meta and meta["summary"] else "") or description_for_mod(mod)
        mod["metadata_side"] = meta["side"] if meta and meta["side"] else ""
        mod["risk_flags"] = meta["risk_flags"] if meta and meta["risk_flags"] else ""
        mod["performance"] = dict(perf) if perf else None
        mods.append(mod)
    return mods


def fetch_updates(conn: sqlite3.Connection, limit: int = 20) -> list[dict[str, Any]]:
    if not table_exists(conn, "update_events"):
        return []
    cutoff = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=UPDATE_LOG_DAYS)).isoformat(timespec="seconds")
    return [
        dict(row)
        for row in conn.execute(
            """
            SELECT
                ue.*, m.name AS mod_name, m.canonical_key,
                COALESCE(NULLIF(ue.source_url, ''), su.url, m.primary_url) AS homepage_url
            FROM update_events ue
            LEFT JOIN mods m ON m.id = ue.mod_id
            LEFT JOIN source_urls su ON su.mod_id = ue.mod_id AND su.is_primary = 1
            WHERE ue.visible_on_site = 1
              AND ue.status IN ('applied', 'ok')
              AND ue.tested_at >= ?
            ORDER BY ue.tested_at DESC, ue.id DESC
            LIMIT ?
            """,
            (cutoff, limit),
        )
    ]


def fetch_update_checks(conn: sqlite3.Connection, limit: int = 3) -> list[dict[str, Any]]:
    if not table_exists(conn, "update_runs"):
        return []
    runs = [
        dict(row)
        for row in conn.execute(
            """
            SELECT *
            FROM update_runs
            ORDER BY id DESC
            LIMIT ?
            """,
            (limit,),
        )
    ]
    if not runs:
        return []
    run_ids = [run["id"] for run in runs]
    placeholders = ",".join("?" for _ in run_ids)
    events = [
        dict(row)
        for row in conn.execute(
            f"""
            SELECT
                ue.*, m.name AS mod_name,
                COALESCE(NULLIF(ue.source_url, ''), su.url, m.primary_url) AS homepage_url
            FROM update_events ue
            LEFT JOIN mods m ON m.id = ue.mod_id
            LEFT JOIN source_urls su ON su.mod_id = ue.mod_id AND su.is_primary = 1
            WHERE ue.update_run_id IN ({placeholders})
            ORDER BY ue.update_run_id DESC, ue.id ASC
            """,
            run_ids,
        )
    ]
    events_by_run: dict[int, list[dict[str, Any]]] = {}
    for event in events:
        events_by_run.setdefault(event["update_run_id"], []).append(event)
    for run in runs:
        run["events"] = events_by_run.get(run["id"], [])
    return runs


def fetch_active_release(conn: sqlite3.Connection) -> dict[str, Any]:
    if not table_exists(conn, "pack_releases"):
        return {}
    row = conn.execute(
        """
        SELECT release_id, status, minecraft_version, loader_version, activated_at
        FROM pack_releases
        WHERE active = 1
        ORDER BY activated_at DESC, created_at DESC
        LIMIT 1
        """
    ).fetchone()
    return dict(row) if row else {}


FAILED_MODS_PAGE = "failed-mods.html"


def fetch_failed_mods(conn: sqlite3.Connection) -> list[dict[str, Any]]:
    rows = conn.execute(
        """
        SELECT m.name, m.canonical_key, m.primary_url, m.server_status,
               COALESCE(n.notes_1, '') AS notes_1, COALESCE(n.notes_2, '') AS notes_2
        FROM mods m
        LEFT JOIN mod_notes n ON n.mod_id = m.id
        WHERE m.active_status = 'failed'
          AND m.duplicate_of_id IS NULL
        ORDER BY lower(m.name)
        """
    ).fetchall()
    return [dict(row) for row in rows]


def render_failed_mods_page(failed_mods: list[dict[str, Any]]) -> str:
    rows_html = []
    for mod in failed_mods:
        name = escape(mod["name"])
        url = escape(mod.get("primary_url") or "")
        reason = escape(mod.get("server_status") or "Unknown")
        notes = escape(mod.get("notes_1") or "")
        extra = escape(mod.get("notes_2") or "")
        detail_parts = [p for p in [reason, notes, extra] if p]
        detail = escape(" — ".join(detail_parts)) if detail_parts else "Unknown"
        link = f'<a href="{url}" target="_blank" rel="noreferrer">{name}</a>' if url else name
        rows_html.append(f"<tr><td>{link}</td><td>{detail}</td></tr>")
    table_rows = "\n        ".join(rows_html) if rows_html else "<tr><td colspan=\"2\">No failed mods</td></tr>"
    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Failed Mods — Pummelchen Server</title>
  <style>
    :root {{
      --bg: #000000; --ink: #f4f7f2; --muted: #a5afa6; --line: #273127;
      --panel: #0b0f0c; --green: #5fd286; --blue: #8fc7ff; --red: #f5b8b8;
      --shadow: rgba(0,0,0,0.62);
    }}
    * {{ box-sizing: border-box; }}
    body {{
      margin: 0; background: var(--bg); color: var(--ink);
      font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      line-height: 1.5;
    }}
    a {{ color: var(--blue); text-decoration: none; }}
    a:hover {{ color: #b8dcff; text-decoration: underline; }}
    .wrap {{ max-width: 1180px; margin: 0 auto; padding: 24px; }}
    header {{ border-bottom: 1px solid var(--line); padding: 28px 0 24px; }}
    h1 {{ margin: 0; font-size: 32px; }}
    .subtitle {{ margin: 8px 0 0; color: var(--muted); }}
    .back {{ display: inline-block; margin-bottom: 16px; color: var(--muted); font-size: 14px; }}
    .back:hover {{ color: var(--blue); }}
    table {{
      width: 100%; border-collapse: collapse; margin-top: 16px;
      background: var(--panel); border: 1px solid var(--line); border-radius: 8px;
      overflow: hidden;
    }}
    th {{
      text-align: left; padding: 12px 16px; background: #111711;
      color: var(--muted); font-size: 13px; font-weight: 600;
      text-transform: uppercase; letter-spacing: 0.5px;
      border-bottom: 1px solid var(--line);
    }}
    td {{
      padding: 10px 16px; border-bottom: 1px solid var(--line);
      font-size: 14px; vertical-align: top;
    }}
    tr:last-child td {{ border-bottom: none; }}
    tr:hover td {{ background: #0f150f; }}
    td:first-child {{ font-weight: 600; white-space: nowrap; }}
    td:last-child {{ color: var(--muted); }}
    .count {{ color: var(--red); font-weight: 700; }}
    footer {{ padding: 24px 0 42px; color: var(--muted); font-size: 13px; }}
    @media (max-width: 640px) {{
      .wrap {{ padding: 16px; }}
      h1 {{ font-size: 26px; }}
      td:first-child {{ white-space: normal; }}
    }}
  </style>
</head>
<body>
  <div class="wrap">
    <a class="back" href="index.html">&larr; Back to status page</a>
    <header>
      <h1>Failed Mods</h1>
      <p class="subtitle"><span class="count">{len(failed_mods)}</span> mods that failed acceptance testing or server boot and were not installed.</p>
    </header>
    <table>
      <thead><tr><th>Mod</th><th>Failure Reason</th></tr></thead>
      <tbody>
        {table_rows}
      </tbody>
    </table>
    <footer>Pummelchen Server — mod tracker failure report</footer>
  </div>
</body>
</html>"""


def version_text(files: list[dict[str, Any]]) -> str:
    if not files:
        return "Tracked runtime entry"
    names = [str(file["file_name"]) for file in files[:3]]
    if len(files) > 3:
        names.append(f"+{len(files) - 3} more")
    return "; ".join(names)


def group_for_mod(mod: dict[str, Any]) -> str:
    text = " ".join(
        str(mod.get(key) or "")
        for key in ("name", "canonical_key", "category", "entry_type", "server_status", "client_package")
    ).lower()
    if str(mod.get("entry_type") or "").lower() == "dependency":
        return "Libraries and Dependencies"
    if "client-only" in text or "resource pack" in text or "shaderpack" in text:
        if any(token in text for token in ("iris", "shader", "modernarch", "dramatic", "sodium", "dynamiclights", "resource")):
            return "Client Visuals"
    for group, needles in GROUP_RULES:
        if any(needle in text for needle in needles):
            return group
    return "Gameplay"


def description_for_mod(mod: dict[str, Any]) -> str:
    name = str(mod["name"])
    group = str(mod["group"])
    file_text = str(mod["version"])
    url = primary_url(mod)
    host = urlparse(url).netloc or "the tracker"
    scope = "server and client" if is_server_mod(mod) else "client package"
    details = GROUP_DESCRIPTIONS.get(group, GROUP_DESCRIPTIONS["Gameplay"])
    return (
        f"{name} is included in the Pummelchen pack as a {group.lower()} entry. "
        f"{details} "
        f"The selected version is tracked from {file_text}. "
        f"The source is recorded from {host}, and this entry is kept aligned with the NeoForge 26.1.2 {scope} setup."
    )


def primary_url(mod: dict[str, Any]) -> str:
    sources = mod.get("sources") or []
    if sources:
        return str(sources[0])
    return str(mod.get("primary_url") or "")


def is_server_mod(mod: dict[str, Any]) -> bool:
    return any(int(file.get("installed_on_server") or 0) == 1 for file in mod.get("files", []))


def is_client_included(mod: dict[str, Any]) -> bool:
    if str(mod.get("client_package") or "").lower() == "included":
        return True
    return any(int(file.get("included_in_client") or 0) == 1 for file in mod.get("files", []))


def grouped(mods: list[dict[str, Any]]) -> dict[str, list[dict[str, Any]]]:
    result: dict[str, list[dict[str, Any]]] = {}
    for mod in mods:
        result.setdefault(str(mod["group"]), []).append(mod)
    for group_mods in result.values():
        group_mods.sort(key=lambda mod: str(mod["name"]).lower())
    return dict(sorted(result.items(), key=lambda item: item[0].lower()))


def escape(value: Any) -> str:
    return html.escape(str(value or ""), quote=True)


def safe_external_url(value: Any) -> str:
    url = str(value or "").strip()
    parsed = urlparse(url)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        return ""
    return url


def is_local_url(value: Any) -> bool:
    target = str(value or "").strip()
    if not target:
        return False
    return target.startswith("/")


def update_title_link(href: Any, title: str) -> str:
    target = str(href or "").strip()
    if not target:
        return title
    if is_local_url(target):
        return f'<a href="{escape(target)}">{title}</a>'
    homepage_url = safe_external_url(target)
    if not homepage_url:
        return title
    return (
        f'<a href="{escape(homepage_url)}" target="_blank" rel="noopener noreferrer">{title}</a>'
    )


def parse_release_manifest(manifest_path: Path) -> dict[str, set[str]]:
    manifest_rows: dict[str, set[str]] = {}
    if not manifest_path.exists():
        return manifest_rows
    try:
        for line in manifest_path.read_text(encoding="utf-8", errors="replace").splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) < 2:
                continue
            role = parts[0].strip()
            rel = parts[1].strip()
            if not role or not rel or rel == "relative_path":
                continue
            manifest_rows.setdefault(role, set()).add(rel)
    except Exception:
        return {}
    return manifest_rows


def gather_release_file_sets(release_dir: Path | None) -> dict[str, set[str]]:
    if not release_dir:
        return {
            "server_mod": set(),
            "server_datapack": set(),
            "client_mods": set(),
            "client_resourcepacks": set(),
            "client_shaderpacks": set(),
            "client_tools": set(),
        }
    release_path = Path(release_dir)
    files = parse_release_manifest(release_path / "manifests" / "server-files.tsv")
    files.update(parse_release_manifest(release_path / "manifests" / "client-package.tsv"))
    return {
        "server_mod": files.get("server_mod", set()),
        "server_datapack": files.get("server_datapack", set()),
        "client_mods": files.get("client_mods", set()),
        "client_resourcepacks": files.get("client_resourcepacks", set()),
        "client_shaderpacks": files.get("client_shaderpacks", set()),
        "client_tools": files.get("client_tools", set()),
    }


def read_changelog_text(path_value: Any) -> str:
    if not path_value:
        return ""
    path = Path(path_value)
    if not path.exists():
        return ""
    try:
        return path.read_text(encoding="utf-8", errors="replace").strip()
    except Exception:
        return ""


def release_test_stats(conn: sqlite3.Connection, release_start: str | None, release_end: str | None) -> dict[str, int]:
    if not release_end:
        release_end = dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")
    if not release_start:
        return {"total": 0, "passed": 0, "failed": 0}
    row = conn.execute(
        """
        SELECT
            COALESCE(SUM(CASE WHEN status='applied' THEN 1 ELSE 0 END), 0) AS passed,
            COALESCE(SUM(CASE WHEN status='failed' THEN 1 ELSE 0 END), 0) AS failed,
            COALESCE(SUM(CASE WHEN status IN ('applied', 'failed') THEN 1 ELSE 0 END), 0) AS total
        FROM update_events
        WHERE tested_at >= ? AND tested_at <= ?
          AND status IN ('applied', 'failed')
        """,
        (release_start, release_end),
    ).fetchone()
    if not row:
        return {"total": 0, "passed": 0, "failed": 0}
    return {
        "passed": int(row["passed"]),
        "failed": int(row["failed"]),
        "total": int(row["total"]),
    }


def render_release_report_page(
    release_id: str,
    *,
    created_at: str,
    activated_at: str,
    notes: str,
    changelog: str,
    minecraft_version: str,
    loader_version: str,
    status: str,
    server_mod_count: int,
    client_mod_count: int,
    server_datapack_count: int,
    client_resourcepack_count: int,
    client_shaderpack_count: int,
    client_tool_count: int,
    added_server_mods: list[str],
    removed_server_mods: list[str],
    added_client_mods: list[str],
    removed_client_mods: list[str],
    test_totals: dict[str, int],
    public_url: str,
) -> str:
    public_base = public_url.rstrip("/")
    release_download_base = f"{public_base}/downloads/releases/{escape(release_id)}"
    top_added_server = _render_file_list(added_server_mods, f"{len(added_server_mods)} added server mods")
    top_removed_server = _render_file_list(removed_server_mods, f"{len(removed_server_mods)} removed server mods")
    top_added_client = _render_file_list(added_client_mods, f"{len(added_client_mods)} added client mods")
    top_removed_client = _render_file_list(removed_client_mods, f"{len(removed_client_mods)} removed client mods")
    test_total = int(test_totals.get("total", 0) or 0)
    test_passed = int(test_totals.get("passed", 0) or 0)
    test_failed = int(test_totals.get("failed", 0) or 0)
    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Release report: {escape(release_id)}</title>
  <style>
    :root {{
      --bg: #000000;
      --ink: #f4f7f2;
      --muted: #a5afa6;
      --line: #273127;
      --panel: #0b0f0c;
      --green: #7ed99a;
      --blue: #8fc7ff;
    }}
    body {{
      margin: 0;
      background: var(--bg);
      color: var(--ink);
      font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      padding: 20px;
    }}
    .wrap {{
      max-width: 920px;
      margin: 0 auto;
    }}
    h1 {{ margin: 0 0 12px; }}
    .subtitle {{ color: var(--muted); margin: 0 0 18px; }}
    .panel {{
      background: var(--panel);
      border: 1px solid var(--line);
      border-radius: 8px;
      padding: 14px;
      margin-bottom: 12px;
    }}
    .panel h2 {{ margin: 0 0 10px; }}
    .stats {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 10px; }}
    .stat-card {{ background: #081108; border: 1px solid #1f3a25; border-radius: 6px; padding: 10px; }}
    .stat-label {{ color: var(--muted); font-size: 12px; }}
    .stat-value {{ font-size: 19px; margin-top: 4px; }}
    ul {{ margin-top: 8px; padding-left: 18px; }}
    li {{ margin: 4px 0; }}
    .links a {{ color: var(--blue); text-decoration: none; }}
    .links a:hover {{ text-decoration: underline; }}
    .small {{ color: var(--muted); font-size: 12px; }}
  </style>
</head>
<body>
  <div class="wrap">
    <h1>Release report: {escape(release_id)}</h1>
    <p class="subtitle">Auto-generated summary from tracker database and release manifests.</p>
    <section class="panel">
      <h2>Overview</h2>
      <div class="stats">
        <div class="stat-card">
          <div class="stat-label">Created</div>
          <div class="stat-value">{escape(created_at or "n/a")}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Activated</div>
          <div class="stat-value">{escape(activated_at or "n/a")}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Status</div>
          <div class="stat-value">{escape(status or "n/a")}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Minecraft</div>
          <div class="stat-value">{escape(minecraft_version or "n/a")}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Loader</div>
          <div class="stat-value">{escape(loader_version or "n/a")}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Tests</div>
          <div class="stat-value">{escape(str(test_total))}</div>
          <div class="small">Passed: {escape(str(test_passed))} · Failed: {escape(str(test_failed))}</div>
        </div>
      </div>
    </section>
    <section class="panel">
      <h2>File counts</h2>
      <ul>
        <li>Server mods: {escape(str(server_mod_count))}</li>
        <li>Server datapacks: {escape(str(server_datapack_count))}</li>
        <li>Client mods: {escape(str(client_mod_count))}</li>
        <li>Client resource packs: {escape(str(client_resourcepack_count))}</li>
        <li>Client shaderpacks: {escape(str(client_shaderpack_count))}</li>
        <li>Client tools: {escape(str(client_tool_count))}</li>
      </ul>
    </section>
    <section class="panel">
      <h2>Changes</h2>
      {top_added_server}
      {top_removed_server}
      {top_added_client}
      {top_removed_client}
    </section>
    <section class="panel">
      <h2>Artifacts</h2>
      <p class="links">
        <a href="{release_download_base}/{escape(CLIENT_ZIP_NAME)}">Client ZIP</a> ·
        <a href="{release_download_base}/{escape(MRPACK_NAME)}">MRPACK</a> ·
        <a href="{release_download_base}/{escape(CLIENT_DMG_NAME)}">Client Installer DMG</a> ·
        <a href="{release_download_base}/client-sync-manifest.tsv">Client sync manifest</a>
      </p>
    </section>
    <section class="panel">
      <h2>Notes</h2>
      <p>{escape(notes or "No release notes available.")}</p>
    </section>
    {f'<section class="panel"><h2>Changelog</h2><pre>{escape(changelog[:8000])}</pre></section>' if changelog else ""}
  </div>
</body>
</html>
"""


def _render_file_list(values: list[str], title: str) -> str:
    if not values:
        return f'<h3>{escape(title)}</h3><p>None.</p>'
    shown = values[:20]
    extras = len(values) - len(shown)
    items = "".join(f"<li>{escape(item)}</li>" for item in shown)
    footer = f"<p class=\"small\">+{extras} more</p>" if extras > 0 else ""
    return f"<h3>{escape(title)}</h3><ul>{items}</ul>{footer}"


def write_release_report_pages(
    conn: sqlite3.Connection,
    output_dir: Path,
    public_url: str,
) -> None:
    if not table_exists(conn, "pack_releases"):
        return
    rows = conn.execute(
        """
        SELECT release_id, created_at, activated_at, previous_release_id,
               status, notes, minecraft_version, loader_version, changelog_path, release_dir
        FROM pack_releases
        WHERE activated_at IS NOT NULL OR created_at IS NOT NULL
        ORDER BY COALESCE(activated_at, created_at) DESC, release_id DESC
        """
    ).fetchall()
    if not rows:
        return

    releases_by_id: dict[str, sqlite3.Row] = {str(row["release_id"]): row for row in rows}
    for i, row in enumerate(rows):
        release_id = str(row["release_id"])
        if not release_id:
            continue
        created_at = str(row["created_at"] or "")
        activated_at = str(row["activated_at"] or "")
        prev = None
        prev_id = row["previous_release_id"]
        if prev_id:
            prev = releases_by_id.get(str(prev_id))
        elif i + 1 < len(rows):
            prev = rows[i + 1]
        prev_release_dir = Path(prev["release_dir"]) if prev and prev["release_dir"] else None
        prev_sets = gather_release_file_sets(prev_release_dir)
        current_sets = gather_release_file_sets(Path(row["release_dir"]) if row["release_dir"] else None)

        added_server_mods = _sorted_delta(current_sets["server_mod"], prev_sets["server_mod"])
        removed_server_mods = _sorted_delta(prev_sets["server_mod"], current_sets["server_mod"])
        added_client_mods = _sorted_delta(current_sets["client_mods"], prev_sets["client_mods"])
        removed_client_mods = _sorted_delta(prev_sets["client_mods"], current_sets["client_mods"])
        test_totals = release_test_stats(
            conn,
            prev["activated_at"] if prev and prev["activated_at"] else created_at,
            activated_at or dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
        )
        report_html = render_release_report_page(
            release_id,
            created_at=created_at,
            activated_at=activated_at,
            notes=str(row["notes"] or ""),
            changelog=read_changelog_text(row["changelog_path"]),
            minecraft_version=str(row["minecraft_version"] or ""),
            loader_version=str(row["loader_version"] or ""),
            status=str(row["status"] or ""),
            server_mod_count=len(current_sets["server_mod"]),
            client_mod_count=len(current_sets["client_mods"]),
            server_datapack_count=len(current_sets["server_datapack"]),
            client_resourcepack_count=len(current_sets["client_resourcepacks"]),
            client_shaderpack_count=len(current_sets["client_shaderpacks"]),
            client_tool_count=len(current_sets["client_tools"]),
            added_server_mods=added_server_mods,
            removed_server_mods=removed_server_mods,
            added_client_mods=added_client_mods,
            removed_client_mods=removed_client_mods,
            test_totals=test_totals,
            public_url=public_url,
        )
        release_dir_link = output_dir / "downloads" / "releases" / release_id
        # If a symlink already exists here (created by release_manager to
        # expose the full release public/ tree via nginx), do NOT replace it
        # with a plain directory — that would hide the manifest, client-files,
        # and zip from the web server.  Write the report through the symlink
        # instead so it lands inside the release public/ directory.
        if release_dir_link.is_symlink() or release_dir_link.is_dir():
            target = release_dir_link / RELEASE_REPORT_FILE
            if not release_dir_link.is_symlink():
                release_dir_link.mkdir(parents=True, exist_ok=True)
        else:
            target = release_dir_link / RELEASE_REPORT_FILE
            target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(report_html, encoding="utf-8")

        release_public = Path(row["release_dir"]) / "public" / RELEASE_REPORT_FILE if row["release_dir"] else None
        if release_public and release_public.parent.exists() and release_public != target:
            release_public.write_text(report_html, encoding="utf-8")


def _sorted_delta(current: set[str], previous: set[str]) -> list[str]:
    return sorted(current.difference(previous))


def clean_update_title(value: Any) -> str:
    original = str(value or "").strip()
    if not original:
        return "Pack update"
    platform_tag = re.compile(
        r"\s*(?:"
        r"\[[^\]]*(?:server|client|fabric|forge|neoforge|quilt|modloader)[^\]]*\]"
        r"|"
        r"\([^)]*(?:server|client|fabric|forge|neoforge|quilt|modloader)[^)]*\)"
        r")\s*",
        re.IGNORECASE,
    )
    cleaned = platform_tag.sub(" ", original)
    cleaned = re.sub(r"\s+", " ", cleaned).strip(" -:/|")
    return cleaned or original


def _looks_like_file_name(value: str) -> bool:
    value = (value or "").strip().lower()
    if not value:
        return False
    return bool(re.search(r"\.(?:jar|zip)(?:\.disabled)?$", value))


def _extract_file_from_text(value: Any) -> str:
    text = str(value or "").strip()
    if not text:
        return ""

    paren_candidates = re.findall(r"\(([^)\n\r]+?\.(?:jar|zip)(?:\.disabled)?)\)", text, flags=re.IGNORECASE)
    for candidate in paren_candidates:
        candidate = candidate.strip(" \"'`")
        if _looks_like_file_name(candidate):
            return candidate

    for raw_line in re.split(r"\r?\n", text):
        line = raw_line.strip(" \"'`")
        if not line:
            continue

        direct_candidates = re.split(r"[;,]", line)
        for segment in direct_candidates:
            segment = segment.strip(" \"'`")
            if _looks_like_file_name(segment):
                return segment

        candidates = re.findall(
            r"(?:^|[\s(])(?P<file>[A-Za-z0-9._+\-\[\] ()]+?\.(?:jar|zip)(?:\.disabled)?)(?=[\s)\],;]|$)",
            line,
            flags=re.IGNORECASE,
        )
        for candidate in candidates:
            candidate = candidate.strip(" \"'`")
            if candidate:
                return candidate
    return ""


def _normalize_update_file_name(value: str) -> str:
    file_name = (value or "").strip()
    if not file_name:
        return ""
    if "/" in file_name:
        file_name = file_name.rsplit("/", 1)[-1]
    file_name = file_name.strip(" \"'`")
    file_name = file_name.replace("\ufeff", "").strip()
    base = re.sub(r"\.(?:jar|zip)(?:\.disabled)?$", "", file_name, flags=re.IGNORECASE)
    base = re.sub(r"(?i)(?:-+codex(?:-?fixed)?(?:-?packmeta)?|-+codexfix|-+packmeta)$", "", base)
    base = re.sub(r"[\s_]+", "-", base).lower().strip("-._ ")
    return base


def _extract_version_from_file_name(value: str) -> str:
    stem = re.sub(r"\.(?:jar|zip)(?:\.disabled)?$", "", str(value or ""), flags=re.IGNORECASE)
    if not stem:
        return ""
    chunks = re.split(r"[-_ ]+", stem)
    for chunk in reversed(chunks):
        chunk = chunk.strip().strip("-._")
        if not chunk:
            continue
        if re.search(r"\d+\.\d+", chunk):
            return chunk
        if re.fullmatch(r"\d+", chunk):
            return chunk
    return ""


def _resolve_update_display_file(event: dict[str, Any]) -> tuple[str, str]:
    file_name = (
        _extract_file_from_text(event.get("file_name"))
        or _extract_file_from_text(event.get("new_file"))
        or _extract_file_from_text(event.get("old_file"))
        or _extract_file_from_text(event.get("notes"))
        or _extract_file_from_text(event.get("test_label"))
    )
    if not file_name:
        file_name = clean_update_title(event.get("title") or "")
    file_name = re.sub(r"(?i)^\\s*test\\s*:\\s*", "", file_name).strip()
    if file_name and not _looks_like_file_name(file_name) and re.fullmatch(r"(?i)[a-z0-9][a-z0-9._+\\-\\[\\]]+", file_name):
        file_name = f"{file_name}.jar"
    version = _extract_version_from_file_name(file_name)
    return file_name, version


def _dedupe_updates_for_render(updates: list[dict[str, Any]]) -> list[dict[str, Any]]:
    first_pass: list[dict[str, Any]] = []
    seen: dict[tuple[Any, ...], tuple[int, int]] = {}
    first_bucket: dict[tuple[Any, ...], int] = {}

    for event in updates:
        file_name, file_version = _resolve_update_display_file(event)
        file_key = _normalize_update_file_name(file_name)
        mod_scope = str(event.get("mod_id") if event.get("mod_id") is not None else clean_update_title(event.get("title") or event.get("mod_name") or ""))

        if event.get("event_type") == "release_promotion":
            bucket = (
                "release",
                str(event.get("test_label") or event.get("source_url") or event.get("title") or ""),
                str(event.get("tested_at", "")),
            )
            rank = 3
        elif mod_scope and file_key:
            bucket = ("mod_file", mod_scope, file_key)
            rank = 4 if file_version else 1
        elif file_key:
            bucket = ("file", file_key)
            rank = 2
        else:
            bucket = (
                str(event.get("title") or ""),
                str(event.get("source") or ""),
                str(event.get("tested_at", "")),
            )
            rank = 0

        if bucket in seen:
            existing_index, existing_rank = seen[bucket]
            if rank > existing_rank:
                first_pass[existing_index] = event
                seen[bucket] = (existing_index, rank)
            continue

        first_bucket[bucket] = len(first_pass)
        seen[bucket] = (len(first_pass), rank)
        first_pass.append(event)

    selected: list[dict[str, Any]] = []
    time_seen: dict[tuple[Any, ...], tuple[int, int]] = {}
    for event in first_pass:
        mod_scope = str(event.get("mod_id") if event.get("mod_id") is not None else clean_update_title(event.get("title") or event.get("mod_name") or ""))
        tested_at = str(event.get("tested_at", "")).strip()
        mod_time_key = ("mod_time", mod_scope, tested_at)
        if event.get("event_type") == "release_promotion":
            selected.append(event)
            continue
        if mod_scope and tested_at:
            file_name, file_version = _resolve_update_display_file(event)
            file_key = _normalize_update_file_name(file_name)
            rank = 2 if (file_key or file_version) else 1
            if mod_time_key in time_seen:
                existing_index, existing_rank = time_seen[mod_time_key]
                if rank > existing_rank:
                    selected[existing_index] = event
                    time_seen[mod_time_key] = (existing_index, rank)
                continue
            time_seen[mod_time_key] = (len(selected), rank)
            selected.append(event)
            continue

        selected.append(event)
    return selected


def render_stat_cards(stats: dict[str, str]) -> str:
    preferred = [
        "Last Mod Version", "Minecraft Players",
        "Server OS", "OS Kernel", "Uptime", "CPU", "CPU Cores", "Server Java",
        "Minecraft Java", "Minecraft",
        "NeoForge", "Client Mod Pack", "Client Mod Pack SHA256",
        "Client Mod Pack Generated",
    ]
    cards = []
    for key in preferred:
        value = stats.get(key, "")
        iso_value = stats.get(f"{key} ISO", "")
        if key == "Client Mod Pack Generated" and iso_value:
            value_html = (
                f'<strong data-live-stat>{escape(value)}</strong>'
                f'<small class="stat-age" data-live-stat-age datetime="{escape(iso_value)}"></small>'
            )
        else:
            value_html = f'<strong data-live-stat>{escape(value)}</strong>'
        cards.append(
            f'<article class="stat" data-stat-key="{escape(key)}"><span>{escape(key)}</span>{value_html}</article>'
        )
    return "\n".join(cards)


def render_mod_card(mod: dict[str, Any], *, client_section: bool = False) -> str:
    url = primary_url(mod)
    url_link = f'<a href="{escape(url)}" target="_blank" rel="noreferrer">Source</a>' if url else '<span>No URL</span>'
    file_list = ", ".join(escape(file["file_name"]) for file in mod.get("files", [])[:4]) or "Runtime/tracker entry"
    if len(mod.get("files", [])) > 4:
        file_list += f", +{len(mod['files']) - 4} more"
    scope = "Client" if client_section else "Server"
    search = escape(" ".join([str(mod["name"]), str(mod["group"]), file_list, str(mod.get("canonical_key"))]).lower())
    perf = mod.get("performance")
    perf_html = ""
    if perf:
        mem = perf.get("memory_delta_mb")
        cpu = perf.get("cpu_delta_pct")
        mem_text = f"{float(mem):+.1f} MB" if mem is not None else "n/a"
        cpu_text = f"{float(cpu):+.2f}%" if cpu is not None else "n/a"
        perf_html = f"<div><dt>Idle impact</dt><dd>RAM {escape(mem_text)}, CPU {escape(cpu_text)} ({escape(perf.get('confidence') or 'unknown')})</dd></div>"
    return f"""
<article class="mod-card" data-search="{search}">
  <div class="mod-topline">
    <h4>{escape(mod["name"])}</h4>
    <span class="badge">{escape(mod["group"])}</span>
  </div>
  <dl>
    <div><dt>Scope</dt><dd>{scope}</dd></div>
    <div><dt>Version / file</dt><dd>{escape(mod["version"])}</dd></div>
    <div><dt>URL</dt><dd>{url_link}</dd></div>
    <div><dt>Files</dt><dd>{file_list}</dd></div>
    {perf_html}
  </dl>
  <p>{escape(mod["description"])}</p>
</article>
"""


def render_grouped_mods(mods: list[dict[str, Any]], *, client_section: bool = False) -> str:
    sections = []
    for group, group_mods in grouped(mods).items():
        cards = "\n".join(render_mod_card(mod, client_section=client_section) for mod in group_mods)
        sections.append(
            f"""
<details class="mod-group">
  <summary><span>{escape(group)}</span><b>{len(group_mods)}</b></summary>
  <div class="mod-grid">{cards}</div>
</details>
"""
        )
    return "\n".join(sections)


def make_installer_script(public_url: str) -> str:
    zip_url = f"{public_url.rstrip('/')}/downloads/{CLIENT_ZIP_NAME}"
    return f"""#!/bin/bash
set -euo pipefail

BASE_URL="${{PUMMELCHEN_BASE_URL:-{public_url.rstrip('/')}}}"
ZIP_URL="$BASE_URL/downloads/{CLIENT_ZIP_NAME}"
MC_DIR="${{MINECRAFT_DIR:-$HOME/Library/Application Support/minecraft}}"
WORK_DIR="$(mktemp -d "${{TMPDIR:-/tmp}}/pummelchen-client.XXXXXX")"
ZIP_PATH="$WORK_DIR/{CLIENT_ZIP_NAME}"
SHA_PATH="$WORK_DIR/{CLIENT_ZIP_NAME}.sha256"
RELEASE_JSON="$WORK_DIR/current-release.json"
EXPECTED_SHA=""
RELEASE_ID="legacy"

cleanup() {{
  rm -rf "$WORK_DIR"
}}
trap cleanup EXIT

echo "Pummelchen Server client installer"
echo "Minecraft folder: $MC_DIR"
echo "Downloading: $ZIP_URL"

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is missing. macOS should include it by default."
  exit 1
fi

if ! command -v unzip >/dev/null 2>&1; then
  echo "unzip is missing. macOS should include it by default."
  exit 1
fi

if ! command -v shasum >/dev/null 2>&1; then
  echo "shasum is missing. macOS should include it by default."
  exit 1
fi

json_string_value() {{
  local key="$1"
  local path="$2"
  sed -nE "s/.*\\\"$key\\\"[[:space:]]*:[[:space:]]*\\\"([^\\\"]*)\\\".*/\\1/p" "$path" | head -n 1
}}

if curl -fL "$BASE_URL/downloads/current-release.json" -o "$RELEASE_JSON"; then
  RELEASE_ID="$(json_string_value release_id "$RELEASE_JSON" || true)"
  POINTER_ZIP="$(json_string_value client_zip_url "$RELEASE_JSON" || true)"
  POINTER_SHA="$(json_string_value client_zip_sha256 "$RELEASE_JSON" || true)"
  if [ -n "$POINTER_ZIP" ]; then
    case "$POINTER_ZIP" in
      http://*|https://*) ZIP_URL="$POINTER_ZIP" ;;
      *) ZIP_URL="${{BASE_URL%/}}/${{POINTER_ZIP#/}}" ;;
    esac
  fi
  if [ -n "$POINTER_SHA" ]; then
    EXPECTED_SHA="$POINTER_SHA"
    printf '%s  %s\n' "$EXPECTED_SHA" "{CLIENT_ZIP_NAME}" > "$SHA_PATH"
  fi
fi

if [ -z "$EXPECTED_SHA" ]; then
  curl -fL "$BASE_URL/downloads/{CLIENT_ZIP_NAME}.sha256" -o "$SHA_PATH"
  EXPECTED_SHA="$(awk '{{ print $1; exit }}' "$SHA_PATH")"
fi

echo "Release: $RELEASE_ID"
curl -fL "$ZIP_URL" -o "$ZIP_PATH"
echo "$EXPECTED_SHA  $ZIP_PATH" | shasum -a 256 -c -
unzip -q "$ZIP_PATH" -d "$WORK_DIR"
chmod +x "$WORK_DIR/client-package/Install Mods.command"
"$WORK_DIR/client-package/Install Mods.command" "$MC_DIR"
"""


def render_updates(updates: list[dict[str, Any]]) -> str:
    if not updates:
        return f'<p class="note">No tested successful updates have been logged in the last {UPDATE_LOG_DAYS} days. The daily updater only publishes entries here after a change passes validation and the client package is rebuilt when needed.</p>'

    updates = _dedupe_updates_for_render(updates)
    cards = []
    for event in updates:
        tested_at = escape(event.get("tested_at", ""))
        tested_at_display = escape(event.get("tested_at_display", event.get("tested_at", "")))
        title = escape(clean_update_title(event.get("title") or event.get("mod_name") or "Pack update"))
        homepage_url = event.get("source_url") or event.get("homepage_url")
        title_html = update_title_link(homepage_url, title)
        source_badge = escape(event.get("source", "unknown"))
        event_type = escape(event.get("event_type", "update"))
        file_name, file_version = _resolve_update_display_file(event)
        file_name_html = f'<p><strong>Filename:</strong> {escape(file_name)}</p>' if file_name else ""
        version_html = f'<p><strong>Mod Version:</strong> {escape(file_version)}</p>' if file_version else ""
        cards.append(
            f"""
<article class="update-card">
  <div class="mod-topline">
    <h4>{title_html}</h4>
    <span class="badge">{event_type}</span>
    <span class="badge" style="background:#1a2a1a; border-color:#3d5c3d; color:#9fdfaf;">{source_badge}</span>
  </div>
  <p><strong>When:</strong> <time class="relative-time" datetime="{tested_at}" title="{tested_at}">{tested_at_display}</time></p>
  {file_name_html}
  {version_html}
</article>
"""
        )
    return '<div class="update-grid">' + "\n".join(cards) + "</div>"


def render_update_checks(runs: list[dict[str, Any]]) -> str:
    countdown_html = """
<div class="update-countdown">
  <span class="countdown-label">Next automatic update check:</span>
  <strong id="updateCountdown" class="countdown-value" data-next-run-hour="12" data-activity-url="update-activity.json">--</strong>
  <p id="activityStatus" class="note" style="margin: 6px 0 0; min-height: 1.2em;">Loading update activity...</p>
</div>
<div id="updateActivity" class="update-activity" style="display:none;">
  <h4 class="activity-title">Pipeline Activity</h4>
  <ul id="activityList" class="activity-list"></ul>
</div>
"""
    return countdown_html


def render_page(
    *,
    stats: dict[str, str],
    server_mods: list[dict[str, Any]],
    client_mods: list[dict[str, Any]],
    public_url: str,
    updates: list[dict[str, Any]],
    update_checks: list[dict[str, Any]] | None = None,
    failed_count: int = 0,
    active_release: dict[str, Any] | None = None,
) -> str:
    release_label = display_release_version(stats.get("Last Mod Version", ""))
    release_id = str(active_release.get("release_id") or "") if active_release else ""
    release_report_url = f"{public_url.rstrip('/')}/downloads/releases/{quote(release_id, safe='')}/{RELEASE_REPORT_FILE}" if release_id else ""
    if release_id and release_report_url:
        release_version_html = f'<a class="release-version" href="{escape(release_report_url)}">Latest version: {escape(release_label)}</a>'
    else:
        release_version_html = f'<span class="release-version">Latest version: {escape(release_label)}</span>'
    client_zip_url = f"{public_url.rstrip('/')}/downloads/{CLIENT_ZIP_NAME}"
    client_dmg_url = f"{public_url.rstrip('/')}/downloads/{CLIENT_DMG_NAME}"
    server_count = len(server_mods)
    client_count = len(client_mods)
    world_seed = stats.get("World Seed", "")
    if world_seed:
        seed_url = f"{SEED_MAPPER_BASE_URL}/{quote(str(world_seed), safe='')}#l=-1"
        seed_viewer_html = f'<p class="seed-viewer"><strong>World Seed Viewer:</strong> <a href="{escape(seed_url)}" target="_blank" rel="noopener">{escape(world_seed)}</a></p>'
    else:
        seed_viewer_html = '<p class="seed-viewer"><strong>World Seed Viewer:</strong> <span id="worldSeedLink">loading...</span></p>'
    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Pummelchen Server</title>
  <style>
    :root {{
      --bg: #000000;
      --ink: #f4f7f2;
      --muted: #a5afa6;
      --line: #273127;
      --panel: #0b0f0c;
      --panel-strong: #111711;
      --green: #5fd286;
      --green-strong: #31a85f;
      --lime: #a8d66d;
      --amber: #e2a65f;
      --stone: #c4ccc3;
      --blue: #8fc7ff;
      --accent: #7ee29d;
      --shadow: rgba(0, 0, 0, 0.62);
    }}
    * {{ box-sizing: border-box; }}
    body {{
      margin: 0;
      background: var(--bg);
      color: var(--ink);
      font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      line-height: 1.5;
      letter-spacing: 0;
    }}
    a {{ color: var(--blue); text-decoration: none; }}
    a:hover {{ color: #b8dcff; text-decoration: underline; }}
    .wrap {{ max-width: 1180px; margin: 0 auto; padding: 24px; }}
    header {{
      border-bottom: 1px solid var(--line);
      background: linear-gradient(180deg, #070a07 0%, #000000 100%);
    }}
    .hero {{
      display: grid;
      grid-template-columns: 1fr;
      align-items: center;
      padding: 28px 0 24px;
    }}
    .top-image-wrap {{
      width: min(1180px, calc(100% - 48px));
      margin: 24px auto 0;
    }}
    .top-image {{
      display: block;
      width: 100%;
      height: auto;
      max-height: min(62vh, 620px);
      object-fit: cover;
      object-position: center;
      border-radius: 8px;
      box-shadow: 0 22px 54px var(--shadow);
    }}
    h1 {{ margin: 0; font-size: 42px; line-height: 1.05; }}
    .subtitle {{ margin: 8px 0 0; color: var(--muted); max-width: 760px; }}
    .seed-viewer {{ margin: 10px 0 0; font-size: 14px; color: var(--muted); }}
    .seed-viewer a {{ color: var(--blue); text-decoration: none; font-family: monospace; }}
    .seed-viewer a:hover {{ text-decoration: underline; color: #93c5fd; }}
    .pill-row {{ display: flex; flex-wrap: wrap; gap: 8px; margin-top: 16px; }}
    .pill {{
      border: 1px solid var(--line);
      background: #080c09;
      border-radius: 999px;
      padding: 6px 10px;
      color: var(--stone);
      font-size: 14px;
      white-space: nowrap;
    }}
    a.pill:hover {{ color: var(--blue); border-color: var(--blue); text-decoration: none; }}
    .pill-failed {{ color: #f5b8b8; border-color: #6d2828; background: #2a0d0d; }}
    a.pill-failed:hover {{ color: #ffcaca; border-color: #f5b8b8; }}
    section {{ padding: 24px 0; border-bottom: 1px solid var(--line); }}
    h2 {{ margin: 0 0 14px; font-size: 24px; }}
    h3 {{ margin: 20px 0 10px; font-size: 18px; }}
    .stats {{
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(210px, 1fr));
      gap: 10px;
    }}
    .stat {{
      background: var(--panel);
      border: 1px solid var(--line);
      border-radius: 8px;
      padding: 12px;
      min-height: 84px;
    }}
    .stat span {{ display: block; color: var(--muted); font-size: 13px; }}
    .stat strong {{ display: block; margin-top: 6px; overflow-wrap: anywhere; }}
    .stat-age {{ display: block; margin-top: 4px; color: var(--muted); font-size: 12px; }}
    .live-status {{
      display: flex;
      align-items: center;
      gap: 8px;
      margin: 14px 0;
      color: var(--muted);
      font-size: 14px;
    }}
    .live-dot {{
      width: 9px;
      height: 9px;
      border-radius: 999px;
      background: #555f57;
    }}
    .live-dot.ok {{ background: var(--green); }}
    .live-dot.warn {{ background: var(--amber); }}
    .chart-grid {{
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(240px, 1fr));
      gap: 10px;
      margin-top: 12px;
    }}
    .chart-card {{
      background: var(--panel);
      border: 1px solid var(--line);
      border-radius: 8px;
      padding: 12px;
      min-width: 0;
    }}
    .chart-head {{
      display: flex;
      justify-content: space-between;
      align-items: baseline;
      gap: 12px;
      margin-bottom: 8px;
    }}
    .chart-head h3 {{
      margin: 0;
      font-size: 15px;
      line-height: 1.2;
    }}
    .chart-value {{
      color: var(--green);
      font-weight: 800;
      white-space: nowrap;
    }}
    .chart-card canvas {{
      width: 100%;
      height: 88px;
      display: block;
    }}
    .actions {{ display: flex; flex-wrap: wrap; align-items: center; gap: 10px; margin: 14px 0; }}
    .button {{
      display: inline-flex;
      align-items: center;
      justify-content: center;
      min-height: 42px;
      border-radius: 8px;
      border: 1px solid var(--green-strong);
      background: var(--green-strong);
      color: #031006;
      padding: 10px 14px;
      font-weight: 700;
    }}
    .button.secondary {{
      background: #080d09;
      color: var(--green);
      border-color: var(--line);
    }}
    .release-version {{
      display: inline-flex;
      align-items: center;
      min-height: 42px;
      border: 1px solid var(--line);
      border-radius: 999px;
      padding: 0 12px;
      color: var(--stone);
      background: var(--panel);
      font-weight: 700;
      font-size: 14px;
    }}
    a.release-version:hover {{
      color: var(--blue);
      border-color: var(--blue);
      text-decoration: none;
    }}
    code, pre {{
      font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
      font-size: 13px;
    }}
    pre {{
      margin: 10px 0 0;
      padding: 12px;
      background: #050805;
      color: #eef8ec;
      border: 1px solid var(--line);
      border-radius: 8px;
      white-space: pre-wrap;
      overflow-wrap: anywhere;
      overflow: hidden;
      max-width: 100%;
    }}
    .toolbar {{
      display: flex;
      flex-wrap: wrap;
      gap: 10px;
      align-items: center;
      margin: 12px 0 18px;
    }}
    .search {{
      flex: 1 1 280px;
      min-height: 42px;
      border: 1px solid var(--line);
      border-radius: 8px;
      padding: 0 12px;
      font: inherit;
      background: #070b08;
      color: var(--ink);
    }}
    .search::placeholder {{ color: #778177; }}
    .mod-group {{
      background: transparent;
      margin: 10px 0;
    }}
    .mod-group summary {{
      cursor: pointer;
      list-style: none;
      border: 1px solid var(--line);
      border-radius: 8px;
      background: var(--panel-strong);
      padding: 12px 14px;
      display: flex;
      justify-content: space-between;
      align-items: center;
      font-weight: 800;
    }}
    .mod-group summary::-webkit-details-marker {{ display: none; }}
    .mod-group summary b {{
      color: var(--muted);
      font-weight: 700;
    }}
    .jump-links {{
      display: flex;
      flex-wrap: wrap;
      gap: 10px;
      margin-top: 14px;
    }}
    .mod-grid {{
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(310px, 1fr));
      gap: 10px;
      margin-top: 10px;
    }}
    .update-grid {{
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(300px, 1fr));
      gap: 10px;
      margin-top: 12px;
    }}
    .mod-card {{
      background: var(--panel);
      border: 1px solid var(--line);
      border-radius: 8px;
      padding: 14px;
      min-width: 0;
    }}
    .update-card {{
      background: var(--panel);
      border: 1px solid var(--line);
      border-radius: 8px;
      padding: 14px;
    }}
    .update-card p {{ margin: 8px 0 0; overflow-wrap: anywhere; }}
    .mod-topline {{
      display: flex;
      gap: 10px;
      align-items: flex-start;
      justify-content: space-between;
      min-width: 0;
      flex-wrap: wrap;
    }}
    .mod-card h4,
    .update-card h4 {{
      margin: 0;
      font-size: 16px;
      line-height: 1.25;
      min-width: 0;
      overflow-wrap: normal;
      word-break: normal;
    }}
    .mod-topline h4 {{
      flex: 1 1 0;
      min-width: 160px;
    }}
    .update-card h4 a {{
      color: var(--accent);
      text-decoration: underline;
      text-decoration-thickness: 1px;
      text-underline-offset: 3px;
    }}
    .update-card h4 a:hover,
    .update-card h4 a:focus-visible {{
      color: #bff5cb;
    }}
    .badge {{
      display: inline-flex;
      border: 1px solid #285d3c;
      color: #b9efc8;
      background: #0d2414;
      border-radius: 999px;
      padding: 3px 8px;
      font-size: 12px;
      white-space: nowrap;
      max-width: 58%;
      overflow-wrap: anywhere;
    }}
    .update-countdown {{
      display: flex;
      align-items: center;
      gap: 12px;
      padding: 14px 18px;
      background: var(--panel);
      border: 1px solid var(--line);
      border-radius: 8px;
      margin-bottom: 16px;
    }}
    .countdown-label {{ color: var(--muted); font-size: 14px; }}
    .countdown-value {{ color: var(--green); font-size: 20px; font-variant-numeric: tabular-nums; }}
    .update-activity {{
      background: var(--panel);
      border: 1px solid var(--line);
      border-radius: 8px;
      margin-bottom: 16px;
      padding: 14px 18px;
    }}
    .activity-title {{
      color: var(--muted);
      font-size: 14px;
      font-weight: 600;
      margin: 0 0 10px 0;
    }}
    .activity-list {{
      list-style: none;
      padding: 0;
      margin: 0;
    }}
    .activity-list li {{
      display: flex;
      gap: 10px;
      padding: 5px 0;
      font-size: 13px;
      border-bottom: 1px solid var(--line);
    }}
    .activity-list li:last-child {{ border-bottom: none; }}
    .activity-ts {{
      color: var(--muted);
      white-space: nowrap;
      font-variant-numeric: tabular-nums;
      min-width: 150px;
    }}
    .activity-msg {{ color: var(--text); }}
    .activity-msg[data-status="running"] {{ color: var(--yellow); }}
    .activity-msg[data-status="ok"] {{ color: var(--green); }}
    .activity-msg[data-status="failed"] {{ color: #f87171; }}
    .activity-stage {{
      color: var(--muted);
      font-size: 11px;
      background: rgba(255,255,255,0.04);
      padding: 1px 6px;
      border-radius: 4px;
      white-space: nowrap;
      margin-left: auto;
    }}
    .run-block {{
      background: var(--panel);
      border: 1px solid var(--line);
      border-radius: 8px;
      margin-bottom: 10px;
      overflow: hidden;
    }}
    .run-block summary {{
      display: flex;
      justify-content: space-between;
      align-items: center;
      gap: 12px;
      padding: 12px 16px;
      cursor: pointer;
      list-style: none;
    }}
    .run-block summary::-webkit-details-marker {{ display: none; }}
    .run-block summary::before {{
      content: '';
      display: inline-block;
      width: 0;
      height: 0;
      border-left: 6px solid var(--muted);
      border-top: 5px solid transparent;
      border-bottom: 5px solid transparent;
      flex-shrink: 0;
      transition: transform 0.15s;
    }}
    .run-block[open] summary::before {{ transform: rotate(90deg); }}
    .run-summary-title {{ display: flex; gap: 10px; align-items: center; min-width: 0; }}
    .run-trigger {{
      font-size: 12px;
      color: var(--muted);
      background: var(--panel-strong);
      border: 1px solid var(--line);
      border-radius: 999px;
      padding: 2px 8px;
    }}
    .run-summary-stats {{ font-size: 13px; color: var(--muted); white-space: nowrap; }}
    .run-body {{ padding: 0 16px 14px; }}
    .run-meta {{ font-size: 13px; color: var(--muted); margin: 0 0 10px; }}
    .run-events-table {{
      width: 100%;
      border-collapse: collapse;
      font-size: 13px;
    }}
    .run-events-table th {{
      text-align: left;
      color: var(--muted);
      font-weight: 500;
      padding: 6px 8px;
      border-bottom: 1px solid var(--line);
    }}
    .run-events-table td {{
      padding: 6px 8px;
      border-bottom: 1px solid #1a211a;
      overflow-wrap: anywhere;
    }}
    .run-events-table tr:last-child td {{ border-bottom: none; }}
    .run-events-table a {{
      color: var(--accent);
      text-decoration: underline;
      text-decoration-thickness: 1px;
      text-underline-offset: 2px;
    }}
    .run-detail {{ color: var(--muted); font-size: 12px; }}
    .run-badge {{
      display: inline-block;
      border-radius: 999px;
      padding: 2px 8px;
      font-size: 11px;
      font-weight: 500;
      white-space: nowrap;
    }}
    .badge-applied {{ color: #b9efc8; background: #0d2414; border: 1px solid #285d3c; }}
    .badge-failed {{ color: #f5b8b8; background: #2a0d0d; border: 1px solid #6d2828; }}
    .badge-dryrun {{ color: #d4c89a; background: #1f1c0d; border: 1px solid #5d5428; }}
    .run-block.run-pass {{ border-left: 3px solid var(--green); }}
    .run-block.run-fail {{ border-left: 3px solid #d45f5f; }}
    .run-block.run-neutral {{ border-left: 3px solid var(--muted); }}
    dl {{ margin: 12px 0; display: grid; gap: 6px; }}
    dl div {{ display: grid; grid-template-columns: 96px 1fr; gap: 8px; }}
    dt {{ color: var(--muted); }}
    dd {{ margin: 0; overflow-wrap: anywhere; }}
    .mod-card p {{ margin: 0; color: #d8ded8; overflow-wrap: anywhere; }}
    .note {{ color: var(--muted); max-width: 860px; }}
    .manual-update {{ margin-top: 18px; padding: 14px 18px; background: var(--panel); border: 1px solid var(--line); border-radius: 8px; }}
    .manual-update h4 {{ margin: 0 0 8px; color: var(--text); font-size: 15px; }}
    .operator-section {{
      display: grid;
      gap: 14px;
      max-width: 960px;
    }}
    .operator-steps {{
      margin: 0;
      padding-left: 22px;
      color: #d8ded8;
    }}
    .operator-steps li {{ margin: 7px 0; }}
    .operator-warning {{
      border-left: 3px solid var(--amber);
      padding: 10px 12px;
      background: #171209;
      color: #e8d3ad;
      border-radius: 0 8px 8px 0;
    }}
    .terminal-cmd {{
      background: #0a0f0b;
      border: 1px solid var(--line);
      border-radius: 6px;
      padding: 10px 14px;
      margin: 6px 0;
      overflow-x: auto;
      font-size: 13px;
      line-height: 1.5;
    }}
    .terminal-cmd code {{ color: var(--green); font-family: 'SF Mono', 'Menlo', 'Monaco', monospace; }}
    .terminal-output {{
      background: #060a07;
      border: 1px solid #1a2b1e;
      border-radius: 6px;
      padding: 12px 16px;
      margin: 6px 0;
      font-size: 12px;
      line-height: 1.6;
      color: #8ab88a;
      font-family: 'SF Mono', 'Menlo', 'Monaco', monospace;
      white-space: pre;
      overflow-x: auto;
    }}
    .progress-example {{ margin: 10px 0; }}
    footer {{ padding: 24px 0 42px; color: var(--muted); }}
    @media (max-width: 640px) {{
      .wrap {{ padding: 16px; }}
      .top-image-wrap {{ width: calc(100% - 24px); margin-top: 12px; }}
      .top-image {{ max-height: 52vh; }}
      h1 {{ font-size: 34px; }}
      dl div {{ grid-template-columns: 1fr; }}
      .badge {{ white-space: normal; text-align: center; }}
      pre {{ white-space: pre-wrap; overflow-wrap: anywhere; }}
    }}
  </style>
</head>
<body>
  <div class="top-image-wrap">
    <img class="top-image" src="assets/{HERO_IMAGE_NAME}" alt="Pummelchen Server Minecraft landscape">
  </div>
  <header>
    <div class="wrap hero">
      <div>
        <h1>Pummelchen Server</h1>
        <p class="subtitle">A compact status and install page for the private Minecraft 26.1.2 NeoForge server on the Debian VPS.</p>
        {seed_viewer_html}
        <div class="pill-row">
          <span class="pill">Server: {SERVER_HOST}:{SERVER_MC_PORT}</span>
          <span class="pill">Web: {SERVER_HOST}:7788</span>
          <span class="pill">{server_count} Server Mods</span>
          <span class="pill">{client_count} Client Mods</span>
          <a class="pill pill-failed" href="{FAILED_MODS_PAGE}">{failed_count} Failed Mods</a>
        </div>
      </div>
    </div>
  </header>
  <main class="wrap">
    <section id="stats">
      <h2>Server And VPS Stats</h2>
      <div class="stats">{render_stat_cards(stats)}</div>
      <div class="live-status" aria-live="polite"><span id="liveDot" class="live-dot"></span><span id="liveStatus">Live stats loading...</span></div>
      <div class="chart-grid" aria-label="Live system graphs">
        <article class="chart-card">
          <div class="chart-head"><h3>CPU Usage</h3><strong class="chart-value" data-live-metric="cpu_percent">--</strong></div>
          <canvas data-live-chart="cpu_percent" width="520" height="176" aria-label="CPU usage graph"></canvas>
        </article>
        <article class="chart-card">
          <div class="chart-head"><h3>RAM Used</h3><strong class="chart-value" data-live-metric="ram_used_percent">--</strong></div>
          <canvas data-live-chart="ram_used_percent" width="520" height="176" aria-label="RAM usage graph"></canvas>
        </article>
        <article class="chart-card">
          <div class="chart-head"><h3>Disk Used</h3><strong class="chart-value" data-live-metric="disk_used_percent">--</strong></div>
          <canvas data-live-chart="disk_used_percent" width="520" height="176" aria-label="Disk usage percentage graph"></canvas>
        </article>
      </div>
    </section>

    <section id="safe-world-reset">
      <h2>Safe World Reset</h2>
      <div class="operator-section">
        <p class="note">Use this command when replacing the current world with a new seed. It backs up the active world, writes the new seed, keeps the custom bonus chest enabled, installs required datapacks, starts the server, reapplies safety gamerules, detects spawn, and pregenerates a 1000-block diameter around spawn.</p>
        <pre class="terminal-cmd"><code>python3 /var/minecraft_mods/scripts/safe_reset_world.py &#92;
  --project-dir /var/minecraft_mods &#92;
  --server-dir /var/minecraft_26.1.2 &#92;
  --seed NEW_SEED &#92;
  --diameter-blocks 1000 &#92;
  --yes</code></pre>
        <ol class="operator-steps">
          <li>Replace <code>NEW_SEED</code> with the numeric or text seed to generate.</li>
          <li>Run the command as <code>root</code> on the VPS.</li>
          <li>Wait for <code>pregenerate_done=1</code>; the default square pregeneration covers 4,096 chunks.</li>
          <li>Use <code>--dry-run</code> first to preview the backup path and pregeneration plan without changing the world.</li>
        </ol>
        <p class="operator-warning">Do not delete <code>/var/minecraft_26.1.2/world</code> manually. Manual deletion can skip datapack installation, bonus chest customization, safety gamerules, backups, and pregeneration.</p>
      </div>
    </section>

    <section id="install">
      <h2>Mac Client Install</h2>
      <p class="note">For macOS Apple Silicon M2/M3 clients. The DMG is a small visual bootstrap installer; first run downloads the current verified client pack, about 1 GB, with a step counter and progress window. It reports each setup step, success timestamp, and failure log tail to the VPS, installs a user-local Java 25 runtime when needed, syncs the matching mods and visual packs, installs NeoForge, adds the server entry, and enables automatic background updates from the VPS.</p>
      <div class="actions">
        <a class="button" href="{escape(client_dmg_url)}">Download Small Mac Installer DMG</a>
        {release_version_html}
      </div>
      <div class="manual-update">
        <h4>Manual Client Update (Terminal)</h4>
        <p class="note">Clients auto-update every 5 minutes in the background. To force a manual sync with a live progress bar, paste this in macOS Terminal:</p>
        <pre class="terminal-cmd"><code>~/Library/Application\\ Support/Pummelchen/bin/pummelchen-auto-update.sh --force</code></pre>
        <div class="progress-example">
          <p class="note">Example output:</p>
          <pre class="terminal-output"><code>  Pummelchen Client Updater
  ========================
  Release: release_20260611_V3
  Server:  http://91.99.176.243:7788

  Manifest: 254 file(s) in current release
  251 file(s) already up to date.

  Downloading 3 file(s)...

  [##############################] 3/3 (100%) done

  Done! 3 file(s) updated, 254 verified.

  Pummelchen client is current.</code></pre>
        </div>
        <p class="note">To check status without updating:</p>
        <pre class="terminal-cmd"><code>~/Library/Application\\ Support/Pummelchen/bin/pummelchen-auto-update.sh --check-only</code></pre>
      </div>
    </section>

    <section id="update-checks">
      <h2>Update Checks</h2>
      <p class="note">The daily updater runs at 12:00 UTC. Below are the most recent runs with per-mod results.</p>
      {render_update_checks(update_checks or [])}
    </section>

    <section id="updates">
      <h2>Tested Updates</h2>
      <p class="note">Only successful updates from the last {UPDATE_LOG_DAYS} days are shown here.</p>
      {render_updates(updates)}
      <nav class="jump-links" aria-label="Mod list jumps">
        <a class="button secondary" href="#server-mods">Server-Side Mods</a>
        <a class="button secondary" href="#client-mods">Client-Side Mods</a>
      </nav>
    </section>

    <section id="server-mods">
      <h2>Server-Side Active Mods</h2>
      <p class="note">Sorted by group and name. The Mac client package includes these server-required mods so clients match the server.</p>
      <div class="toolbar"><input id="serverSearch" class="search" type="search" placeholder="Filter server mods by name, group, or file"></div>
      {render_grouped_mods(server_mods)}
    </section>

    <section id="client-mods">
      <h2>Client-Side Extras</h2>
      <p class="note">These are active client-only or visual package entries below the server mod set: shaders, resource packs, client performance, and client presentation mods.</p>
      <div class="toolbar"><input id="clientSearch" class="search" type="search" placeholder="Filter client extras by name, group, or file"></div>
      {render_grouped_mods(client_mods, client_section=True)}
    </section>
  </main>
  <script>
    const liveMetricConfig = {{
      cpu_percent: {{ suffix: '%', label: 'CPU Usage', min: 0, max: 100 }},
      ram_used_percent: {{ suffix: '%', label: 'RAM Used', min: 0, max: 100 }},
      disk_used_percent: {{ suffix: '%', label: 'Disk Used', min: 0, max: 100 }}
    }};
    function boundedLiveValue(value, config) {{
      let number = Number(value);
      if (!Number.isFinite(number)) return '--';
      if (Number.isFinite(config.min)) number = Math.max(config.min, number);
      if (Number.isFinite(config.max)) number = Math.min(config.max, number);
      return number;
    }}
    function formatLiveMetric(value, key, metrics = {{}}) {{
      const config = liveMetricConfig[key] || {{ suffix: '' }};
      const number = boundedLiveValue(value, config);
      if (number === '--') return '--';
      if (key === 'disk_used_percent') {{
        const freeGb = Number(metrics.disk_free_gb);
        const freeText = Number.isFinite(freeGb) ? ` (${{Math.max(0, freeGb).toFixed(1)}} GB free)` : '';
        return `${{number.toFixed(1)}}%${{freeText}}`;
      }}
      const decimals = 1;
      return `${{number.toFixed(decimals)}}${{config.suffix || ''}}`;
    }}
    function updateLiveCards(stats) {{
      if (!stats) return;
      document.querySelectorAll('[data-stat-key]').forEach(card => {{
        const key = card.dataset.statKey || '';
        const value = stats[key];
        const target = card.querySelector('[data-live-stat]');
        if (target && value !== undefined) target.textContent = value;
        const ageTarget = card.querySelector('[data-live-stat-age]');
        const isoValue = stats[`${{key}} ISO`];
        if (ageTarget && isoValue) {{
          ageTarget.setAttribute('datetime', isoValue);
          ageTarget.textContent = relativeTimeLabel(isoValue);
        }}
      }});
    }}
    function drawLiveChart(canvas, samples, key) {{
      const context = canvas.getContext('2d');
      if (!context) return;
      const dpr = window.devicePixelRatio || 1;
      const rect = canvas.getBoundingClientRect();
      const width = Math.max(1, Math.floor(rect.width * dpr));
      const height = Math.max(1, Math.floor(rect.height * dpr));
      if (canvas.width !== width || canvas.height !== height) {{
        canvas.width = width;
        canvas.height = height;
      }}
      context.clearRect(0, 0, width, height);
      context.fillStyle = '#070b08';
      context.fillRect(0, 0, width, height);
      context.strokeStyle = '#1b251d';
      context.lineWidth = Math.max(1, dpr);
      for (let i = 1; i <= 3; i += 1) {{
        const y = (height / 4) * i;
        context.beginPath();
        context.moveTo(0, y);
        context.lineTo(width, y);
        context.stroke();
      }}
      const config = liveMetricConfig[key] || {{}};
      const values = (samples || [])
        .map(sample => boundedLiveValue(sample[key], config))
        .filter(value => Number.isFinite(value));
      if (values.length < 2) {{
        context.fillStyle = '#a5afa6';
        context.font = `${{12 * dpr}}px system-ui, sans-serif`;
        context.fillText('Waiting for samples', 12 * dpr, 26 * dpr);
        return;
      }}
      let min = config.min;
      let max = config.max;
      if (min === null || min === undefined) min = Math.min(...values);
      if (max === null || max === undefined) max = Math.max(100, ...values);
      if (max <= min) max = min + 1;
      const xStep = width / Math.max(1, values.length - 1);
      context.strokeStyle = '#5fd286';
      context.lineWidth = Math.max(2, 2 * dpr);
      context.beginPath();
      values.forEach((value, index) => {{
        const x = index * xStep;
        const y = height - ((value - min) / (max - min)) * height;
        if (index === 0) context.moveTo(x, y);
        else context.lineTo(x, y);
      }});
      context.stroke();
    }}
    function applyLiveStats(payload) {{
      updateLiveCards(payload.stats);
      const metrics = payload.metrics || {{}};
      document.querySelectorAll('[data-live-metric]').forEach(node => {{
        const key = node.dataset.liveMetric || '';
        node.textContent = formatLiveMetric(metrics[key], key, metrics);
      }});
      document.querySelectorAll('canvas[data-live-chart]').forEach(canvas => {{
        drawLiveChart(canvas, payload.history || [], canvas.dataset.liveChart || '');
      }});
      const generated = payload.generated_at ? new Date(payload.generated_at) : null;
      const ageSeconds = generated ? Math.max(0, Math.floor((Date.now() - generated.getTime()) / 1000)) : null;
      const status = document.getElementById('liveStatus');
      const dot = document.getElementById('liveDot');
      if (status) status.textContent = ageSeconds === null ? 'Live stats updated' : `Live stats updated ${{ageSeconds}} seconds ago`;
      if (dot) {{
        dot.classList.toggle('ok', ageSeconds !== null && ageSeconds <= 90);
        dot.classList.toggle('warn', ageSeconds !== null && ageSeconds > 90);
      }}
      if (payload.world_seed) {{
        const seedEl = document.getElementById('worldSeedLink');
        if (seedEl) {{
          const seedUrl = `https://mcseedmap.net/1.21.5-Java/${{encodeURIComponent(payload.world_seed)}}#l=-1`;
          seedEl.innerHTML = `<a href="${{seedUrl}}" target="_blank" rel="noopener">${{payload.world_seed}}</a>`;
        }}
      }}
    }}
    async function refreshLiveStats() {{
      const status = document.getElementById('liveStatus');
      const dot = document.getElementById('liveDot');
      try {{
        const response = await fetch('live-stats.json', {{ cache: 'no-store' }});
        if (!response.ok) throw new Error(`HTTP ${{response.status}}`);
        applyLiveStats(await response.json());
      }} catch (error) {{
        if (status) status.textContent = `Live stats unavailable: ${{error.message}}`;
        if (dot) {{
          dot.classList.remove('ok');
          dot.classList.add('warn');
        }}
      }}
    }}
    function relativeTimeLabel(timestamp) {{
      const parsed = Date.parse(timestamp);
      if (Number.isNaN(parsed)) return timestamp;
      const elapsedSeconds = Math.max(0, Math.floor((Date.now() - parsed) / 1000));
      if (elapsedSeconds < 60) return 'just now';
      const minutes = Math.floor(elapsedSeconds / 60);
      if (minutes < 60) return minutes === 1 ? '1 minute ago' : `${{minutes}} minutes ago`;
      const hours = Math.floor(minutes / 60);
      if (hours < 24) return hours === 1 ? '1 hour ago' : `${{hours}} hours ago`;
      const days = Math.floor(hours / 24);
      return days === 1 ? '1 day ago' : `${{days}} days ago`;
    }}
    function updateRelativeTimes() {{
      document.querySelectorAll('time.relative-time[datetime]').forEach(time => {{
        time.textContent = relativeTimeLabel(time.getAttribute('datetime') || '');
      }});
      document.querySelectorAll('[data-live-stat-age][datetime]').forEach(node => {{
        node.textContent = relativeTimeLabel(node.getAttribute('datetime') || '');
      }});
    }}
    function wireSearch(inputId, sectionId) {{
      const input = document.getElementById(inputId);
      const section = document.getElementById(sectionId);
      if (!input || !section) return;
      input.addEventListener('input', () => {{
        const query = input.value.trim().toLowerCase();
        section.querySelectorAll('.mod-card').forEach(card => {{
          const hit = !query || card.dataset.search.includes(query);
          card.style.display = hit ? '' : 'none';
        }});
        section.querySelectorAll('.mod-group').forEach(group => {{
          const visible = Array.from(group.querySelectorAll('.mod-card')).some(card => card.style.display !== 'none');
          group.style.display = visible ? '' : 'none';
          if (query) {{
            group.open = visible;
          }} else {{
            group.open = false;
          }}
        }});
      }});
    }}
    let updateActivityCache = {{ data: null, loadedAt: 0 }};
    function updateActivityState(entries) {{
      if (!Array.isArray(entries) || entries.length === 0) {{
        return {{ running: false, done: false, latest: null, hasEntries: false }};
      }}
      const latest = entries[entries.length - 1];
      const status = String(latest.status || '').toLowerCase();
      const message = String(latest.message || '');
      const stage = String(latest.stage || '').toLowerCase();
      const isCompletionMessage = /pipeline complete/i.test(message);
      return {{
        running: status === 'running' && !isCompletionMessage,
        done: status === 'ok' && isCompletionMessage,
        latest,
        hasEntries: true,
        stage,
      }};
    }}
    async function fetchUpdateActivity(force) {{
      const now = Date.now();
      const el = document.getElementById('updateCountdown');
      if (!el) return updateActivityCache.data;
      const endpoint = el.dataset.activityUrl || 'update-activity.json';
      if (!force && updateActivityCache.data && now - updateActivityCache.loadedAt < 5000) {{
        return updateActivityCache.data;
      }}
      try {{
        const response = await fetch(endpoint, {{ cache: 'no-store' }});
        if (!response.ok) {{
          return updateActivityCache.data;
        }}
        const data = await response.json();
        updateActivityCache = {{ data: data, loadedAt: now }};
      }} catch {{
        return updateActivityCache.data;
      }}
      return updateActivityCache.data;
    }}
    function renderActivityList(container, list, entries) {{
      if (!Array.isArray(entries) || entries.length === 0) {{
        container.style.display = 'none';
        return;
      }}
      container.style.display = '';
      const rows = entries.slice(-5).reverse();
      list.innerHTML = rows.map(e => {{
        const ts = e.timestamp || '';
        const msg = e.message || '';
        const stage = e.stage || '';
        const status = e.status || 'info';
        const stageHtml = stage ? `<span class="activity-stage">${{stage}}</span>` : '';
        return `<li><span class="activity-ts">${{ts}}</span><span class="activity-msg" data-status="${{status}}">${{msg}}</span>${{stageHtml}}</li>`;
      }}).join('');
    }}
    async function updateCountdown() {{
      const el = document.getElementById('updateCountdown');
      if (!el) return;
      const statusEl = document.getElementById('activityStatus');
      const container = document.getElementById('updateActivity');
      const list = document.getElementById('activityList');
      const data = await fetchUpdateActivity(true);
      const entries = data && Array.isArray(data.entries) ? data.entries : [];
      const state = updateActivityState(entries);
      if (statusEl) {{
        if (state.running) {{
          statusEl.textContent = 'Pipeline status: ' + (state.latest && state.latest.message ? state.latest.message : 'Running');
        }} else if (state.done) {{
          statusEl.textContent = 'Last completed: ' + (state.latest && state.latest.message ? state.latest.message : 'Pipeline complete');
        }} else if (state.latest && state.latest.message) {{
          statusEl.textContent = 'Latest activity: ' + state.latest.message;
        }} else {{
          statusEl.textContent = 'No pipeline activity yet.';
        }}
      }}
      if (container && list) {{
        renderActivityList(container, list, entries);
      }}
      if (state.running) {{
        el.textContent = 'Running now...';
        return;
      }}
      const hour = parseInt(el.dataset.nextRunHour || '12', 10);
      const now = new Date();
      const next = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate(), hour, 0, 0));
      if (now.getTime() >= next.getTime()) {{
        next.setUTCDate(next.getUTCDate() + 1);
      }}
      const diffMs = next.getTime() - now.getTime();
      if (diffMs <= 0) {{
        el.textContent = 'Starting soon...';
        return;
      }}
      const totalMinutes = Math.floor(diffMs / 60000);
      const days = Math.floor(totalMinutes / 1440);
      const hours = Math.floor((totalMinutes % 1440) / 60);
      const minutes = totalMinutes % 60;
      const parts = [];
      if (days > 0) parts.push(`${{days}}d`);
      if (hours > 0) parts.push(`${{hours}}h`);
      if (minutes > 0 || parts.length === 0) parts.push(`${{minutes}}m`);
      el.textContent = parts.join(' ');
    }}
    updateCountdown();
    window.setInterval(updateCountdown, 5000);
    updateRelativeTimes();
    window.setInterval(updateRelativeTimes, 60000);
    refreshLiveStats();
    window.setInterval(refreshLiveStats, 10000);
    window.addEventListener('resize', refreshLiveStats);
    wireSearch('serverSearch', 'server-mods');
    wireSearch('clientSearch', 'client-mods');
  </script>
</body>
</html>
"""


def reset_output_path(path: Path) -> None:
    if path.is_symlink() or path.is_file():
        path.unlink()
    elif path.exists():
        shutil.rmtree(path)


def parse_pack_manifest(manifest_path: Path) -> list[tuple[str, str, str, str]]:
    rows: list[tuple[str, str, str, str]] = []
    section = ""
    if not manifest_path.exists():
        return rows
    for raw_line in manifest_path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw_line.strip()
        if not line:
            continue
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1]
            continue
        parts = raw_line.split("\t")
        if section in {"mods", "resourcepacks", "shaderpacks"} and len(parts) >= 3:
            rows.append((section, parts[0], parts[1], parts[2]))
    return rows


def write_client_sync_manifest(server_dir: Path, downloads: Path) -> None:
    package_dir = server_dir / "client-package"
    rows = parse_pack_manifest(package_dir / "manifest.txt")
    files_dir = downloads / CLIENT_FILES_DIR_NAME
    reset_output_path(files_dir)
    files_dir.mkdir(parents=True, exist_ok=True)

    manifest_lines = [
        "# Pummelchen client sync manifest v1",
        "# section\tname\tsize\tsha256\turl_path",
    ]
    for section, name, size, file_hash in rows:
        source = package_dir / section / name
        if not source.exists():
            continue
        section_dir = files_dir / section
        section_dir.mkdir(parents=True, exist_ok=True)
        link = section_dir / name
        if link.exists() or link.is_symlink():
            link.unlink()
        link.symlink_to(source)
        url_path = "/".join(
            quote(part, safe="")
            for part in ("downloads", CLIENT_FILES_DIR_NAME, section, name)
        )
        manifest_lines.append(f"{section}\t{name}\t{size}\t{file_hash}\t{url_path}")

    (downloads / CLIENT_SYNC_MANIFEST_NAME).write_text("\n".join(manifest_lines) + "\n", encoding="utf-8")


def fetch_tested_updates_json(output_dir: Path) -> list[dict[str, Any]]:
    """Read pre-built tested updates feed written by the 15-min worker."""
    json_path = output_dir / "tested-updates.json"
    if not json_path.exists():
        return []
    try:
        data = json.loads(json_path.read_text(encoding="utf-8"))
        return data.get("updates", [])
    except Exception:
        return []


def write_site(db_path: Path, output_dir: Path, server_dir: Path, public_url: str) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    downloads = output_dir / "downloads"
    downloads.mkdir(parents=True, exist_ok=True)
    output_assets = output_dir / "assets"
    output_assets.mkdir(parents=True, exist_ok=True)
    source_assets = Path(__file__).resolve().parent.parent / "site" / "assets"
    hero_source = source_assets / HERO_IMAGE_NAME
    if hero_source.exists():
        shutil.copy2(hero_source, output_assets / HERO_IMAGE_NAME)

    with connect(db_path) as conn:
        mods = fetch_mods(conn)
        update_checks = fetch_update_checks(conn)
        active_release = fetch_active_release(conn)
        failed_mods = fetch_failed_mods(conn)
        write_release_report_pages(conn, output_dir, public_url)

    # Use the comprehensive tested updates feed from the independent worker
    updates = fetch_tested_updates_json(output_dir)

    server_mods = [mod for mod in mods if is_server_mod(mod)]
    client_mods = [mod for mod in mods if is_client_included(mod) and not is_server_mod(mod)]

    stats = collect_stats(server_dir)
    if active_release:
        stats["Last Mod Version"] = display_release_version(str(active_release.get("release_id") or ""))
    else:
        stats["Last Mod Version"] = "No active release"
    stats["Minecraft Players"] = "Waiting for live feed"
    html_text = render_page(stats=stats, server_mods=server_mods, client_mods=client_mods, public_url=public_url, updates=updates, update_checks=update_checks, failed_count=len(failed_mods), active_release=active_release)
    (output_dir / "index.html").write_text(html_text, encoding="utf-8")
    (output_dir / FAILED_MODS_PAGE).write_text(render_failed_mods_page(failed_mods), encoding="utf-8")
    installer = downloads / INSTALLER_NAME
    installer.write_text(make_installer_script(public_url), encoding="utf-8")
    installer.chmod(0o755)
    write_client_sync_manifest(server_dir, downloads)

    linked_files = [
        (downloads / CLIENT_ZIP_NAME, server_dir / CLIENT_ZIP_NAME),
        (downloads / f"{CLIENT_ZIP_NAME}.sha256", server_dir / f"{CLIENT_ZIP_NAME}.sha256"),
        (downloads / MRPACK_NAME, server_dir / MRPACK_NAME),
        (downloads / CLIENT_DMG_NAME, server_dir / CLIENT_DMG_NAME),
        (downloads / f"{CLIENT_DMG_NAME}.sha256", server_dir / f"{CLIENT_DMG_NAME}.sha256"),
    ]
    for link, target in linked_files:
        if link.exists() or link.is_symlink():
            link.unlink()
        if target.exists():
            link.symlink_to(target)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", type=Path, default=DEFAULT_DB)
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--server-dir", type=Path, default=DEFAULT_SERVER)
    parser.add_argument("--public-url", default=DEFAULT_PUBLIC_URL)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    write_site(args.db, args.output_dir, args.server_dir, args.public_url)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
