#!/usr/bin/env python3
"""Generate the static Pummelchen Server status site."""

from __future__ import annotations

import argparse
import datetime as dt
import html
import os
import platform
import re
import shutil
import sqlite3
import subprocess
from pathlib import Path
from typing import Any
from urllib.parse import quote, urlparse


DEFAULT_DB = Path("/var/minecraft_mods/data/minecraft_mods.sqlite")
DEFAULT_OUTPUT = Path("/var/minecraft_mods/site/public")
DEFAULT_SERVER = Path("/var/minecraft_26.1.2")
DEFAULT_PUBLIC_URL = "http://91.99.176.243:7788"
CLIENT_ZIP_NAME = "minecraft_26.1.2_client_macos_apple_silicon.zip"
INSTALLER_NAME = "install-pummelchen.command"
MRPACK_NAME = "pummelchen-server-26.1.2.mrpack"
CLIENT_DMG_NAME = "Pummelchen-Client-Installer.dmg"
CLIENT_SYNC_MANIFEST_NAME = "client-sync-manifest.tsv"
CLIENT_FILES_DIR_NAME = "client-files"
UPDATE_LOG_DAYS = 7
HERO_IMAGE_NAME = "pummelchen-hero.png"


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


def human_bytes(value: float) -> str:
    units = ["B", "KB", "MB", "GB", "TB"]
    size = float(value)
    for unit in units:
        if size < 1024 or unit == units[-1]:
            return f"{size:.1f} {unit}" if unit != "B" else f"{int(size)} B"
        size /= 1024
    return f"{size:.1f} TB"


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
    return {
        "Generated": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d %H:%M UTC"),
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
    }


def connect(db_path: Path) -> sqlite3.Connection:
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    return conn


def table_exists(conn: sqlite3.Connection, table_name: str) -> bool:
    row = conn.execute(
        "SELECT 1 FROM sqlite_master WHERE type IN ('table', 'view') AND name = ?",
        (table_name,),
    ).fetchone()
    return bool(row)


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


def display_release_version(release_id: str) -> str:
    value = (release_id or "").strip()
    match = re.fullmatch(r"release_(\d{4})(\d{2})(\d{2})_([^_]+)(?:_.*)?", value)
    if match:
        year, month, day, version = match.groups()
        if version_match := re.match(r"(V\d+)", version, re.IGNORECASE):
            version = version_match.group(1).upper()
        return f"{year}-{month}-{day}_{version}"
    match = re.fullmatch(r"(\d{4})-(\d{2})-(\d{2})_([^_]+)(?:_.*)?", value)
    if match:
        year, month, day, version = match.groups()
        if version_match := re.match(r"(V\d+)", version, re.IGNORECASE):
            version = version_match.group(1).upper()
        return f"{year}-{month}-{day}_{version}"
    return value or "Unknown"


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
    cards = []
    for event in updates:
        tested_at = escape(event.get("tested_at"))
        mod_name = escape(clean_update_title(event.get("mod_name") or "Pack update"))
        homepage_url = safe_external_url(event.get("homepage_url"))
        title_html = (
            f'<a href="{escape(homepage_url)}" target="_blank" rel="noopener noreferrer">{mod_name}</a>'
            if homepage_url
            else mod_name
        )
        old_new = ""
        if event.get("old_file_name") or event.get("new_file_name"):
            old_new = f"<p><strong>File:</strong> {escape(event.get('old_file_name') or 'none')} -> {escape(event.get('new_file_name') or 'none')}</p>"
        cards.append(
            f"""
<article class="update-card">
  <div class="mod-topline">
    <h4>{title_html}</h4>
    <span class="badge">{escape(event.get('event_type'))}</span>
  </div>
  <p><strong>When:</strong> <time class="relative-time" datetime="{tested_at}" title="{tested_at}">{tested_at}</time></p>
  {old_new}
</article>
"""
        )
    return '<div class="update-grid">' + "\n".join(cards) + "</div>"


def render_page(
    *,
    stats: dict[str, str],
    server_mods: list[dict[str, Any]],
    client_mods: list[dict[str, Any]],
    public_url: str,
    updates: list[dict[str, Any]],
) -> str:
    generated = escape(stats.get("Generated", ""))
    release_label = display_release_version(stats.get("Last Mod Version", ""))
    client_zip_url = f"{public_url.rstrip('/')}/downloads/{CLIENT_ZIP_NAME}"
    client_dmg_url = f"{public_url.rstrip('/')}/downloads/{CLIENT_DMG_NAME}"
    server_count = len(server_mods)
    client_count = len(client_mods)
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
    }}
    .mod-card h4,
    .update-card h4 {{
      margin: 0;
      font-size: 16px;
      line-height: 1.25;
      min-width: 0;
      overflow-wrap: anywhere;
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
    dl {{ margin: 12px 0; display: grid; gap: 6px; }}
    dl div {{ display: grid; grid-template-columns: 96px 1fr; gap: 8px; }}
    dt {{ color: var(--muted); }}
    dd {{ margin: 0; overflow-wrap: anywhere; }}
    .mod-card p {{ margin: 0; color: #d8ded8; overflow-wrap: anywhere; }}
    .note {{ color: var(--muted); max-width: 860px; }}
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
        <div class="pill-row">
          <span class="pill">Server: 91.99.176.243:25565</span>
          <span class="pill">Web: 91.99.176.243:7788</span>
          <span class="pill">Generated: {generated}</span>
          <span class="pill">{server_count} Server Mods</span>
          <span class="pill">{client_count} Client Mods</span>
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
          <div class="chart-head"><h3>Disk Free</h3><strong class="chart-value" data-live-metric="disk_free_percent">--</strong></div>
          <canvas data-live-chart="disk_free_percent" width="520" height="176" aria-label="Free disk space percentage graph"></canvas>
        </article>
      </div>
    </section>

    <section id="install">
      <h2>Mac Client Install</h2>
      <p class="note">For macOS Apple Silicon M2/M3 clients. The DMG is a small visual bootstrap installer; first run downloads the current verified client pack, about 1 GB, with a step counter and progress window. It reports each setup step, success timestamp, and failure log tail to the VPS, installs a user-local Java 25 runtime when needed, syncs the matching mods and visual packs, installs NeoForge, adds the server entry, and enables automatic background updates from the VPS.</p>
      <div class="actions">
        <a class="button" href="{escape(client_dmg_url)}">Download Small Mac Installer DMG</a>
        <span class="release-version">Latest version: {escape(release_label)}</span>
      </div>
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
      disk_free_percent: {{ suffix: '%', label: 'Disk Free', min: 0, max: 100 }}
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
      if (key === 'disk_free_percent') {{
        const freeGb = Number(metrics.disk_free_gb);
        const freeText = Number.isFinite(freeGb) ? `${{Math.max(0, freeGb).toFixed(1)}} GB / ` : '';
        return `${{freeText}}${{number.toFixed(1)}}%`;
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
        updates = fetch_updates(conn)
        active_release = fetch_active_release(conn)

    server_mods = [mod for mod in mods if is_server_mod(mod)]
    client_mods = [mod for mod in mods if is_client_included(mod) and not is_server_mod(mod)]

    stats = collect_stats(server_dir)
    if active_release:
        stats["Last Mod Version"] = display_release_version(str(active_release.get("release_id") or ""))
    else:
        stats["Last Mod Version"] = "No active release"
    stats["Minecraft Players"] = "Waiting for live feed"
    html_text = render_page(stats=stats, server_mods=server_mods, client_mods=client_mods, public_url=public_url, updates=updates)
    (output_dir / "index.html").write_text(html_text, encoding="utf-8")
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
