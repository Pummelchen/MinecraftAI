#!/usr/bin/env python3
"""SQLite manager for the Minecraft mod tracker.

SQLite is the source of truth for install/test history. The Google Sheet import
and export commands remain only for legacy migration and review workflows.
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import hashlib
import re
import sqlite3
from pathlib import Path
from typing import Iterable, Sequence
from urllib.parse import urlparse


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

SHEET_VIEW_HEADERS = [
    "Mod",
    "Category",
    "Installation",
    "Type",
    "Tested",
    "Target MC",
    "Server Status",
    "Server File",
    "Client Package",
    "Last Tested",
    "Resolved Source",
    "URL",
    "DB Notes",
]

ACTIVE_STATUS_LABELS = {
    "ok": "OK",
    "failed": "Failed",
    "codex_fixed_candidate": "Codex_Fixed Candidate",
    "awaiting_compatible_release": "Awaiting Compatible Release",
    "blocked_by_dependency": "Blocked By Dependency",
    "reference_only": "Reference Only",
    "source_unresolved": "Source Unresolved",
    "duplicate": "Duplicate",
    "pending": "Pending Review",
    "unknown": "Unknown",
}

ACTIVE_STATUS_RANKS = {
    "ok": 80,
    "failed": 70,
    "codex_fixed_candidate": 60,
    "awaiting_compatible_release": 50,
    "blocked_by_dependency": 40,
    "reference_only": 30,
    "source_unresolved": 20,
    "duplicate": 10,
    "pending": 5,
    "unknown": 0,
}

STATUS_SORT_ORDER = {
    status: index for index, status in enumerate(ACTIVE_STATUS_LABELS)
}

UPDATE_SCAN_ACTIVE_STATUSES = (
    "ok",
    "awaiting_compatible_release",
    "blocked_by_dependency",
    # Legacy value retained so older DBs remain scannable before normalization.
    "skipped",
)

DB_SCHEMA = """
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS schema_info (
    version INTEGER PRIMARY KEY,
    applied_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS imports (
    id INTEGER PRIMARY KEY,
    imported_at TEXT NOT NULL,
    source_file TEXT NOT NULL,
    spreadsheet_id TEXT,
    sheet_name TEXT NOT NULL,
    source_range TEXT,
    row_count INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS mods (
    id INTEGER PRIMARY KEY,
    import_id INTEGER NOT NULL REFERENCES imports(id) ON DELETE CASCADE,
    original_sheet_row INTEGER NOT NULL,
    category TEXT,
    name TEXT NOT NULL,
    canonical_key TEXT NOT NULL,
    installation TEXT,
    entry_type TEXT,
    tested TEXT,
    target_mc TEXT,
    server_status TEXT,
    client_package TEXT,
    last_tested TEXT,
    active_status TEXT NOT NULL,
    status_rank INTEGER NOT NULL,
    primary_url TEXT,
    is_duplicate INTEGER NOT NULL DEFAULT 0,
    duplicate_of_id INTEGER REFERENCES mods(id),
    row_hash TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS mod_notes (
    mod_id INTEGER PRIMARY KEY REFERENCES mods(id) ON DELETE CASCADE,
    notes_1 TEXT,
    notes_2 TEXT,
    migration_notes TEXT
);

CREATE TABLE IF NOT EXISTS source_urls (
    id INTEGER PRIMARY KEY,
    mod_id INTEGER NOT NULL REFERENCES mods(id) ON DELETE CASCADE,
    source_kind TEXT NOT NULL,
    url TEXT NOT NULL,
    host TEXT,
    project_slug TEXT,
    resolved_source TEXT,
    file_id TEXT,
    release_channel TEXT,
    is_primary INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE IF NOT EXISTS mod_files (
    id INTEGER PRIMARY KEY,
    mod_id INTEGER NOT NULL REFERENCES mods(id) ON DELETE CASCADE,
    role TEXT NOT NULL,
    file_name TEXT NOT NULL,
    path_hint TEXT,
    installed_on_server INTEGER NOT NULL DEFAULT 0,
    included_in_client INTEGER NOT NULL DEFAULT 0,
    status TEXT
);

CREATE TABLE IF NOT EXISTS test_runs (
    id INTEGER PRIMARY KEY,
    mod_id INTEGER NOT NULL REFERENCES mods(id) ON DELETE CASCADE,
    tested_at TEXT,
    test_label TEXT,
    status TEXT,
    error_count INTEGER,
    log_path TEXT,
    notes TEXT
);

CREATE TABLE IF NOT EXISTS sheet_rows (
    id INTEGER PRIMARY KEY,
    mod_id INTEGER NOT NULL REFERENCES mods(id) ON DELETE CASCADE,
    spreadsheet_id TEXT,
    sheet_name TEXT NOT NULL,
    row_number INTEGER NOT NULL,
    row_hash TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_mods_key ON mods(canonical_key);
CREATE INDEX IF NOT EXISTS idx_mods_status ON mods(active_status);
CREATE INDEX IF NOT EXISTS idx_mods_duplicate ON mods(duplicate_of_id);
CREATE INDEX IF NOT EXISTS idx_source_urls_mod ON source_urls(mod_id);
CREATE INDEX IF NOT EXISTS idx_files_mod ON mod_files(mod_id);
CREATE INDEX IF NOT EXISTS idx_tests_mod ON test_runs(mod_id);

CREATE VIEW IF NOT EXISTS v_mod_clean AS
SELECT
    m.id AS db_id,
    m.category,
    m.name,
    m.installation,
    m.entry_type,
    m.tested,
    n.notes_1,
    n.notes_2,
    m.primary_url,
    m.target_mc,
    m.server_status,
    GROUP_CONCAT(f.file_name, '; ') AS files,
    m.client_package,
    m.active_status,
    m.original_sheet_row
FROM mods m
LEFT JOIN mod_notes n ON n.mod_id = m.id
LEFT JOIN mod_files f ON f.mod_id = m.id
WHERE m.duplicate_of_id IS NULL
GROUP BY m.id;
"""

EXTENDED_DB_SCHEMA = """
CREATE TABLE IF NOT EXISTS server_instances (
    id INTEGER PRIMARY KEY,
    server_key TEXT NOT NULL UNIQUE,
    display_name TEXT NOT NULL,
    minecraft_version TEXT NOT NULL,
    loader TEXT NOT NULL,
    loader_version TEXT,
    java_version TEXT,
    server_dir TEXT NOT NULL,
    client_package_path TEXT,
    active INTEGER NOT NULL DEFAULT 1,
    notes TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS mod_metadata (
    mod_id INTEGER PRIMARY KEY REFERENCES mods(id) ON DELETE CASCADE,
    group_tag TEXT,
    side TEXT,
    summary TEXT,
    gameplay_tags TEXT,
    risk_flags TEXT,
    dependency_notes TEXT,
    performance_notes TEXT,
    metadata_source TEXT,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS mod_server_files (
    id INTEGER PRIMARY KEY,
    server_instance_id INTEGER NOT NULL REFERENCES server_instances(id) ON DELETE CASCADE,
    mod_id INTEGER NOT NULL REFERENCES mods(id) ON DELETE CASCADE,
    mod_file_id INTEGER REFERENCES mod_files(id) ON DELETE SET NULL,
    file_name TEXT NOT NULL,
    role TEXT NOT NULL,
    source_url TEXT,
    compatibility_status TEXT NOT NULL,
    installed_on_server INTEGER NOT NULL DEFAULT 0,
    included_in_client INTEGER NOT NULL DEFAULT 0,
    selected INTEGER NOT NULL DEFAULT 1,
    file_sha256 TEXT,
    file_size_bytes INTEGER,
    release_channel TEXT,
    file_id TEXT,
    last_synced TEXT NOT NULL,
    notes TEXT,
    UNIQUE(server_instance_id, mod_id, file_name, role)
);

CREATE TABLE IF NOT EXISTS performance_runs (
    id INTEGER PRIMARY KEY,
    server_instance_id INTEGER NOT NULL REFERENCES server_instances(id) ON DELETE CASCADE,
    run_label TEXT NOT NULL,
    run_type TEXT NOT NULL,
    mod_id INTEGER REFERENCES mods(id) ON DELETE SET NULL,
    started_at TEXT NOT NULL,
    duration_seconds REAL,
    idle_seconds REAL,
    status TEXT NOT NULL,
    done_seen INTEGER NOT NULL DEFAULT 0,
    sample_count INTEGER NOT NULL DEFAULT 0,
    avg_rss_mb REAL,
    peak_rss_mb REAL,
    avg_cpu_pct REAL,
    peak_cpu_pct REAL,
    avg_load_1m REAL,
    error_count INTEGER,
    severe_error_count INTEGER,
    log_path TEXT,
    notes TEXT
);

CREATE TABLE IF NOT EXISTS mod_performance_profiles (
    id INTEGER PRIMARY KEY,
    mod_id INTEGER NOT NULL REFERENCES mods(id) ON DELETE CASCADE,
    server_instance_id INTEGER NOT NULL REFERENCES server_instances(id) ON DELETE CASCADE,
    baseline_run_id INTEGER REFERENCES performance_runs(id) ON DELETE SET NULL,
    comparison_run_id INTEGER REFERENCES performance_runs(id) ON DELETE SET NULL,
    measured_at TEXT NOT NULL,
    method TEXT NOT NULL,
    memory_delta_mb REAL,
    cpu_delta_pct REAL,
    status TEXT NOT NULL,
    confidence TEXT,
    notes TEXT,
    UNIQUE(mod_id, server_instance_id, method)
);

CREATE TABLE IF NOT EXISTS backup_snapshots (
    id INTEGER PRIMARY KEY,
    server_instance_id INTEGER REFERENCES server_instances(id) ON DELETE SET NULL,
    label TEXT NOT NULL UNIQUE,
    created_at TEXT NOT NULL,
    db_backup_path TEXT,
    server_manifest_path TEXT,
    client_manifest_path TEXT,
    client_zip_path TEXT,
    client_zip_sha256 TEXT,
    server_dir TEXT,
    notes TEXT
);

CREATE TABLE IF NOT EXISTS update_runs (
    id INTEGER PRIMARY KEY,
    server_instance_id INTEGER REFERENCES server_instances(id) ON DELETE SET NULL,
    run_label TEXT NOT NULL UNIQUE,
    started_at TEXT NOT NULL,
    completed_at TEXT,
    status TEXT NOT NULL,
    trigger_type TEXT NOT NULL,
    scanned_mods INTEGER NOT NULL DEFAULT 0,
    candidates INTEGER NOT NULL DEFAULT 0,
    applied INTEGER NOT NULL DEFAULT 0,
    failed INTEGER NOT NULL DEFAULT 0,
    skipped INTEGER NOT NULL DEFAULT 0,
    backup_snapshot_id INTEGER REFERENCES backup_snapshots(id) ON DELETE SET NULL,
    notes TEXT
);

CREATE TABLE IF NOT EXISTS update_events (
    id INTEGER PRIMARY KEY,
    update_run_id INTEGER NOT NULL REFERENCES update_runs(id) ON DELETE CASCADE,
    mod_id INTEGER REFERENCES mods(id) ON DELETE SET NULL,
    event_type TEXT NOT NULL,
    status TEXT NOT NULL,
    old_file_name TEXT,
    new_file_name TEXT,
    old_file_id TEXT,
    new_file_id TEXT,
    source_kind TEXT,
    source_url TEXT,
    release_channel TEXT,
    tested_at TEXT,
    test_label TEXT,
    log_path TEXT,
    client_package_sha256 TEXT,
    visible_on_site INTEGER NOT NULL DEFAULT 0,
    notes TEXT
);

CREATE TABLE IF NOT EXISTS mod_risk_scores (
    mod_id INTEGER NOT NULL REFERENCES mods(id) ON DELETE CASCADE,
    server_instance_id INTEGER NOT NULL REFERENCES server_instances(id) ON DELETE CASCADE,
    risk_score INTEGER NOT NULL,
    risk_level TEXT NOT NULL,
    factors TEXT,
    updated_at TEXT NOT NULL,
    PRIMARY KEY(mod_id, server_instance_id)
);

CREATE TABLE IF NOT EXISTS profiling_queue (
    id INTEGER PRIMARY KEY,
    mod_id INTEGER NOT NULL REFERENCES mods(id) ON DELETE CASCADE,
    server_instance_id INTEGER NOT NULL REFERENCES server_instances(id) ON DELETE CASCADE,
    priority INTEGER NOT NULL,
    status TEXT NOT NULL DEFAULT 'queued',
    requested_at TEXT NOT NULL,
    last_profiled_at TEXT,
    runs_completed INTEGER NOT NULL DEFAULT 0,
    notes TEXT,
    UNIQUE(mod_id, server_instance_id)
);

CREATE TABLE IF NOT EXISTS pack_releases (
    release_id TEXT PRIMARY KEY,
    created_at TEXT NOT NULL,
    activated_at TEXT,
    server_instance_id INTEGER REFERENCES server_instances(id) ON DELETE SET NULL,
    server_key TEXT NOT NULL,
    minecraft_version TEXT,
    loader_version TEXT,
    server_dir TEXT NOT NULL,
    release_dir TEXT NOT NULL,
    status TEXT NOT NULL,
    active INTEGER NOT NULL DEFAULT 0,
    previous_release_id TEXT REFERENCES pack_releases(release_id) ON DELETE SET NULL,
    git_commit TEXT,
    server_manifest_sha256 TEXT,
    client_manifest_sha256 TEXT,
    db_snapshot_sha256 TEXT,
    client_zip_sha256 TEXT,
    mrpack_sha256 TEXT,
    changelog_path TEXT,
    notes TEXT
);

CREATE TABLE IF NOT EXISTS release_artifacts (
    id INTEGER PRIMARY KEY,
    release_id TEXT NOT NULL REFERENCES pack_releases(release_id) ON DELETE CASCADE,
    artifact_role TEXT NOT NULL,
    relative_path TEXT NOT NULL,
    source_path TEXT,
    size_bytes INTEGER,
    sha256 TEXT,
    created_at TEXT NOT NULL,
    UNIQUE(release_id, artifact_role, relative_path)
);

CREATE TABLE IF NOT EXISTS release_events (
    id INTEGER PRIMARY KEY,
    release_id TEXT REFERENCES pack_releases(release_id) ON DELETE SET NULL,
    event_at TEXT NOT NULL,
    event_type TEXT NOT NULL,
    status TEXT NOT NULL,
    actor TEXT,
    notes TEXT
);

CREATE TABLE IF NOT EXISTS load_lab_runs (
    id INTEGER PRIMARY KEY,
    server_instance_id INTEGER REFERENCES server_instances(id) ON DELETE SET NULL,
    release_id TEXT REFERENCES pack_releases(release_id) ON DELETE SET NULL,
    run_label TEXT NOT NULL UNIQUE,
    scenario TEXT NOT NULL,
    started_at TEXT NOT NULL,
    completed_at TEXT,
    status TEXT NOT NULL,
    duration_seconds REAL,
    sample_count INTEGER NOT NULL DEFAULT 0,
    peak_rss_mb REAL,
    avg_cpu_pct REAL,
    max_region_files INTEGER,
    error_count INTEGER,
    severe_error_count INTEGER,
    log_path TEXT,
    notes TEXT
);

CREATE TABLE IF NOT EXISTS load_lab_samples (
    id INTEGER PRIMARY KEY,
    run_id INTEGER NOT NULL REFERENCES load_lab_runs(id) ON DELETE CASCADE,
    sampled_at TEXT NOT NULL,
    elapsed_seconds REAL NOT NULL,
    rss_mb REAL,
    cpu_pct REAL,
    load_1m REAL,
    region_files INTEGER,
    players_online INTEGER,
    tps REAL,
    mspt REAL
);

CREATE TABLE IF NOT EXISTS mod_acceptance_runs (
    id INTEGER PRIMARY KEY,
    server_instance_id INTEGER REFERENCES server_instances(id) ON DELETE SET NULL,
    run_label TEXT NOT NULL UNIQUE,
    run_type TEXT NOT NULL,
    started_at TEXT NOT NULL,
    completed_at TEXT,
    status TEXT NOT NULL,
    bundle_size INTEGER,
    target_count INTEGER NOT NULL DEFAULT 0,
    passed_count INTEGER NOT NULL DEFAULT 0,
    failed_count INTEGER NOT NULL DEFAULT 0,
    blocked_count INTEGER NOT NULL DEFAULT 0,
    lab_root TEXT,
    notes TEXT
);

CREATE TABLE IF NOT EXISTS mod_acceptance_items (
    id INTEGER PRIMARY KEY,
    acceptance_run_id INTEGER NOT NULL REFERENCES mod_acceptance_runs(id) ON DELETE CASCADE,
    mod_id INTEGER REFERENCES mods(id) ON DELETE SET NULL,
    ordinal INTEGER NOT NULL,
    bundle_index INTEGER,
    stage TEXT NOT NULL,
    status TEXT NOT NULL,
    target_file_names TEXT NOT NULL,
    included_file_names TEXT,
    missing_dependencies TEXT,
    log_path TEXT,
    boot_seconds REAL,
    idle_seconds REAL,
    error_count INTEGER,
    severe_error_count INTEGER,
    notes TEXT,
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS mod_acceptance_releases (
    id INTEGER PRIMARY KEY,
    release_key TEXT NOT NULL UNIQUE,
    server_instance_id INTEGER REFERENCES server_instances(id) ON DELETE SET NULL,
    created_at TEXT NOT NULL,
    completed_at TEXT,
    status TEXT NOT NULL,
    bundle_size INTEGER NOT NULL,
    active_file_count INTEGER NOT NULL DEFAULT 0,
    level_count INTEGER NOT NULL DEFAULT 0,
    top_block_id INTEGER,
    notes TEXT
);

CREATE TABLE IF NOT EXISTS mod_acceptance_blocks (
    id INTEGER PRIMARY KEY,
    acceptance_release_id INTEGER NOT NULL REFERENCES mod_acceptance_releases(id) ON DELETE CASCADE,
    parent_left_block_id INTEGER REFERENCES mod_acceptance_blocks(id) ON DELETE SET NULL,
    parent_right_block_id INTEGER REFERENCES mod_acceptance_blocks(id) ON DELETE SET NULL,
    level INTEGER NOT NULL,
    ordinal INTEGER NOT NULL,
    block_key TEXT NOT NULL,
    status TEXT NOT NULL,
    target_file_names TEXT NOT NULL,
    included_file_names TEXT,
    missing_dependencies TEXT,
    run_label TEXT,
    log_path TEXT,
    boot_seconds REAL,
    idle_seconds REAL,
    error_count INTEGER,
    severe_error_count INTEGER,
    notes TEXT,
    created_at TEXT NOT NULL,
    UNIQUE(acceptance_release_id, level, ordinal)
);

CREATE TABLE IF NOT EXISTS codex_fixed_mods (
    id INTEGER PRIMARY KEY,
    original_mod_id INTEGER NOT NULL REFERENCES mods(id) ON DELETE CASCADE,
    fixed_mod_id INTEGER NOT NULL REFERENCES mods(id) ON DELETE CASCADE,
    original_file_name TEXT,
    fixed_file_name TEXT NOT NULL,
    fixed_file_path TEXT NOT NULL,
    patch_notes TEXT,
    patch_path TEXT,
    created_at TEXT NOT NULL,
    status TEXT NOT NULL,
    UNIQUE(original_mod_id, fixed_file_name)
);

CREATE TABLE IF NOT EXISTS mod_acceptance_block_client_runs (
    id INTEGER PRIMARY KEY,
    acceptance_block_id INTEGER NOT NULL REFERENCES mod_acceptance_blocks(id) ON DELETE CASCADE,
    run_label TEXT NOT NULL UNIQUE,
    status TEXT NOT NULL,
    started_at TEXT NOT NULL,
    completed_at TEXT,
    client_mod_file_names TEXT,
    missing_client_file_names TEXT,
    server_log_path TEXT,
    hmc_log_path TEXT,
    minecraft_log_path TEXT,
    notes TEXT
);

CREATE TABLE IF NOT EXISTS headless_client_runs (
    id INTEGER PRIMARY KEY,
    server_instance_id INTEGER REFERENCES server_instances(id) ON DELETE SET NULL,
    release_id TEXT REFERENCES pack_releases(release_id) ON DELETE SET NULL,
    run_label TEXT NOT NULL UNIQUE,
    started_at TEXT NOT NULL,
    completed_at TEXT,
    status TEXT NOT NULL,
    minecraft_version TEXT NOT NULL,
    loader TEXT NOT NULL,
    server_host TEXT NOT NULL,
    server_port INTEGER NOT NULL,
    duration_seconds REAL,
    requested_duration_seconds INTEGER,
    game_dir TEXT NOT NULL,
    run_dir TEXT NOT NULL,
    display TEXT,
    renderer_summary TEXT,
    hmc_log_path TEXT,
    minecraft_log_path TEXT,
    crash_report_count INTEGER NOT NULL DEFAULT 0,
    fatal_log_count INTEGER NOT NULL DEFAULT 0,
    notes TEXT
);

CREATE TABLE IF NOT EXISTS client_installer_sessions (
    session_id TEXT PRIMARY KEY,
    client_id TEXT,
    first_seen_at TEXT NOT NULL,
    last_seen_at TEXT NOT NULL,
    completed_at TEXT,
    status TEXT NOT NULL,
    installer_version TEXT,
    app_version TEXT,
    release_id TEXT,
    minecraft_version TEXT,
    os_summary TEXT,
    arch TEXT,
    remote_addr TEXT,
    user_agent TEXT,
    local_log_path TEXT,
    latest_step INTEGER,
    total_steps INTEGER,
    event_count INTEGER NOT NULL DEFAULT 0,
    latest_message TEXT,
    notes TEXT
);

CREATE TABLE IF NOT EXISTS client_installer_events (
    id INTEGER PRIMARY KEY,
    session_id TEXT NOT NULL REFERENCES client_installer_sessions(session_id) ON DELETE CASCADE,
    received_at TEXT NOT NULL,
    event_at TEXT,
    event_type TEXT NOT NULL,
    severity TEXT NOT NULL,
    status TEXT,
    step_current INTEGER,
    step_total INTEGER,
    message TEXT,
    detail TEXT,
    release_id TEXT,
    minecraft_version TEXT,
    local_log_path TEXT,
    log_excerpt TEXT,
    authenticated INTEGER NOT NULL DEFAULT 0,
    remote_addr TEXT,
    user_agent TEXT
);

CREATE INDEX IF NOT EXISTS idx_server_instances_key ON server_instances(server_key);
CREATE INDEX IF NOT EXISTS idx_mod_metadata_group ON mod_metadata(group_tag);
CREATE INDEX IF NOT EXISTS idx_mod_server_files_instance ON mod_server_files(server_instance_id);
CREATE INDEX IF NOT EXISTS idx_mod_server_files_mod ON mod_server_files(mod_id);
CREATE INDEX IF NOT EXISTS idx_performance_runs_instance ON performance_runs(server_instance_id, run_type);
CREATE INDEX IF NOT EXISTS idx_performance_runs_mod ON performance_runs(mod_id);
CREATE INDEX IF NOT EXISTS idx_mod_performance_profiles_instance ON mod_performance_profiles(server_instance_id);
CREATE INDEX IF NOT EXISTS idx_mod_performance_profiles_mod ON mod_performance_profiles(mod_id);
CREATE INDEX IF NOT EXISTS idx_backup_snapshots_instance ON backup_snapshots(server_instance_id);
CREATE INDEX IF NOT EXISTS idx_update_runs_instance ON update_runs(server_instance_id, started_at);
CREATE INDEX IF NOT EXISTS idx_update_events_run ON update_events(update_run_id);
CREATE INDEX IF NOT EXISTS idx_update_events_visible ON update_events(visible_on_site, tested_at);
CREATE INDEX IF NOT EXISTS idx_mod_risk_scores_score ON mod_risk_scores(server_instance_id, risk_score);
CREATE INDEX IF NOT EXISTS idx_profiling_queue_priority ON profiling_queue(server_instance_id, status, priority);
CREATE INDEX IF NOT EXISTS idx_pack_releases_active ON pack_releases(server_key, active, created_at);
CREATE INDEX IF NOT EXISTS idx_pack_releases_status ON pack_releases(server_key, status, created_at);
CREATE INDEX IF NOT EXISTS idx_release_artifacts_release ON release_artifacts(release_id, artifact_role);
CREATE INDEX IF NOT EXISTS idx_release_events_release ON release_events(release_id, event_at);
CREATE INDEX IF NOT EXISTS idx_load_lab_runs_scenario ON load_lab_runs(server_instance_id, scenario, started_at);
CREATE INDEX IF NOT EXISTS idx_load_lab_samples_run ON load_lab_samples(run_id, elapsed_seconds);
CREATE INDEX IF NOT EXISTS idx_mod_acceptance_runs_instance ON mod_acceptance_runs(server_instance_id, run_type, started_at);
CREATE INDEX IF NOT EXISTS idx_mod_acceptance_items_run ON mod_acceptance_items(acceptance_run_id, stage, ordinal);
CREATE INDEX IF NOT EXISTS idx_mod_acceptance_items_mod ON mod_acceptance_items(mod_id, stage, created_at);
CREATE INDEX IF NOT EXISTS idx_mod_acceptance_releases_key ON mod_acceptance_releases(release_key);
CREATE INDEX IF NOT EXISTS idx_mod_acceptance_blocks_release ON mod_acceptance_blocks(acceptance_release_id, level, ordinal);
CREATE INDEX IF NOT EXISTS idx_mod_acceptance_blocks_status ON mod_acceptance_blocks(status, level);
CREATE INDEX IF NOT EXISTS idx_codex_fixed_mods_original ON codex_fixed_mods(original_mod_id, status);
CREATE INDEX IF NOT EXISTS idx_mod_acceptance_block_client_block ON mod_acceptance_block_client_runs(acceptance_block_id, status);
CREATE INDEX IF NOT EXISTS idx_headless_client_runs_status ON headless_client_runs(status, started_at);
CREATE INDEX IF NOT EXISTS idx_headless_client_runs_release ON headless_client_runs(release_id, started_at);
CREATE INDEX IF NOT EXISTS idx_client_installer_sessions_status ON client_installer_sessions(status, first_seen_at);
CREATE INDEX IF NOT EXISTS idx_client_installer_events_session ON client_installer_events(session_id, received_at);
CREATE INDEX IF NOT EXISTS idx_client_installer_events_type ON client_installer_events(event_type, received_at);

CREATE VIEW IF NOT EXISTS v_mod_version_status AS
SELECT
    si.server_key,
    si.display_name AS server_name,
    si.minecraft_version,
    si.loader,
    si.loader_version,
    m.id AS mod_id,
    m.name,
    m.canonical_key,
    mm.group_tag,
    mm.side,
    msf.file_name,
    msf.compatibility_status,
    msf.installed_on_server,
    msf.included_in_client,
    msf.file_sha256,
    msf.file_size_bytes,
    msf.last_synced
FROM mod_server_files msf
JOIN server_instances si ON si.id = msf.server_instance_id
JOIN mods m ON m.id = msf.mod_id
LEFT JOIN mod_metadata mm ON mm.mod_id = m.id;
"""


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()


def clean_cell(value: str | None) -> str:
    if value is None:
        return ""
    return str(value).replace("\r\n", "\n").replace("\r", "\n").strip()


def normalize_row(row: Sequence[str]) -> list[str]:
    cells = [clean_cell(v) for v in row]
    if len(cells) < len(HEADERS):
        cells.extend([""] * (len(HEADERS) - len(cells)))
    return cells[: len(HEADERS)]


def slugify(value: str) -> str:
    value = value.strip().lower()
    value = value.replace("&", " and ")
    value = re.sub(r"[^a-z0-9]+", "-", value)
    return value.strip("-") or "unknown"


def row_hash(cells: Sequence[str]) -> str:
    payload = "\x1f".join(cells).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def is_blank_row(cells: Sequence[str]) -> bool:
    return not any(clean_cell(c) for c in cells)


def is_section_row(cells: Sequence[str]) -> bool:
    return bool(clean_cell(cells[0])) and not any(clean_cell(c) for c in cells[1:])


def active_status_label(active_status: str) -> str:
    return ACTIVE_STATUS_LABELS.get(active_status, active_status.replace("_", " ").title())


def classify_active_status(
    tested: str,
    server_status: str,
    client_package: str,
    *,
    is_duplicate: bool = False,
) -> str:
    tested_lower = tested.strip().lower()
    server_lower = server_status.strip().lower()
    client_lower = client_package.strip().lower()
    text = " ".join([tested_lower, server_lower, client_lower])
    if "codex_fixed active" in text or "codex fixed active" in text:
        return "ok"
    if "codex_fixed rejected" in text or "codex fixed rejected" in text:
        return "failed"
    if "codex_fixed obsolete" in text or "codex fixed obsolete" in text:
        return "reference_only"
    if "codex_fixed candidate" in text or "codex fixed candidate" in text:
        return "codex_fixed_candidate"
    if is_duplicate:
        return "duplicate"
    if tested_lower == "pending" or server_lower.startswith("pending") or client_lower == "pending":
        return "pending"
    if (
        "missing compatible dependency" in text
        or "duplicate missing stable dependency" in text
        or "requires create" in text
        or "no compatible create" in text
    ):
        return "blocked_by_dependency"
    if "no resolvable project" in text or "project not found" in text:
        return "source_unresolved"
    if "online reference" in text or "not a server mod" in text or "reference only" in text:
        return "reference_only"
    if "no compatible" in text or "no compatible stable release" in text:
        return "awaiting_compatible_release"
    if (
        "crash" in text
        or "failed" in text
        or "rejected" in text
        or "log error" in text
        or "watchdog" in text
        or "dependency rejected" in text
    ):
        return "failed"
    if (
        tested_lower == "ok"
        or server_lower == "ok"
        or "runtime ok" in text
        or server_lower.startswith("client-only: included")
        or server_lower.startswith("client dependency: included")
        or client_lower == "included"
        or server_lower == "installed"
        or server_lower.startswith("clean-world ok")
    ):
        return "ok"
    if "skip" in text or client_lower == "not included":
        return "awaiting_compatible_release"
    return "unknown"


def status_rank(tested: str, server_status: str, client_package: str) -> tuple[str, int]:
    active_status = classify_active_status(tested, server_status, client_package)
    return active_status, ACTIVE_STATUS_RANKS[active_status]


def normalize_all_active_statuses(conn: sqlite3.Connection) -> int:
    changed = 0
    now = utc_now()
    rows = conn.execute(
        "SELECT id, tested, server_status, client_package, active_status, status_rank, duplicate_of_id FROM mods"
    ).fetchall()
    for row in rows:
        active_status = classify_active_status(
            str(row["tested"] or ""),
            str(row["server_status"] or ""),
            str(row["client_package"] or ""),
            is_duplicate=row["duplicate_of_id"] is not None,
        )
        rank = ACTIVE_STATUS_RANKS[active_status]
        if row["active_status"] != active_status or int(row["status_rank"] or -1) != rank:
            conn.execute(
                "UPDATE mods SET active_status = ?, status_rank = ?, updated_at = ? WHERE id = ?",
                (active_status, rank, now, int(row["id"])),
            )
            changed += 1
    conn.commit()
    return changed


def source_kind(url: str) -> tuple[str, str, str]:
    if not url:
        return "unknown", "", ""
    parsed = urlparse(url)
    host = parsed.netloc.lower()
    path = parsed.path
    kind = "other"
    slug = ""
    if "curseforge.com" in host:
        kind = "curseforge"
        match = re.search(r"/minecraft/(?:mc-mods|texture-packs|data-packs|shaders)/([^/]+)", path)
        slug = match.group(1) if match else ""
    elif "modrinth.com" in host:
        kind = "modrinth"
        match = re.search(r"/(?:mod|datapack)/([^/]+)", path)
        slug = match.group(1) if match else ""
    elif "mojang.com" in host or "piston-meta" in host:
        kind = "mojang"
    elif "neoforged.net" in host:
        kind = "neoforge"
    return kind, host, slug


def release_channel(resolved_source: str) -> str:
    lower = resolved_source.lower()
    if "beta" in lower:
        return "beta"
    if "alpha" in lower:
        return "alpha"
    if "stable" in lower or "release file" in lower:
        return "stable"
    return ""


def extract_file_id(resolved_source: str) -> str:
    match = re.search(r"(?:file|release file|resource-pack file)\s+([A-Za-z0-9_-]+)", resolved_source)
    return match.group(1) if match else ""


def split_file_names(server_file: str) -> list[str]:
    if not server_file:
        return []
    lower = server_file.lower()
    if lower in {"not installed", "not installed on server"}:
        return []
    if lower.startswith("moved to "):
        server_file = server_file.removeprefix("Moved to ").strip()
    parts = [p.strip() for p in server_file.split(";") if p.strip()]
    return [Path(p).name for p in parts]


def test_label_from_notes(notes: str) -> str:
    patterns = [
        r"Boot test\s+([A-Za-z0-9_.-]+)",
        r"validation\s+([A-Za-z0-9_.-]+)",
        r"test\s+([A-Za-z0-9_.-]+)",
    ]
    for pattern in patterns:
        match = re.search(pattern, notes)
        if match:
            return match.group(1)
    return ""


def error_count_from_notes(notes: str) -> int | None:
    match = re.search(r"ERROR_LINES=(\d+)", notes)
    if match:
        return int(match.group(1))
    return None


def connect(db_path: Path, *, timeout: float = 30.0) -> sqlite3.Connection:
    db_path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(db_path, timeout=timeout)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    conn.execute("PRAGMA journal_mode = WAL")
    return conn


def init_db(conn: sqlite3.Connection) -> None:
    conn.executescript(DB_SCHEMA)
    conn.executescript(EXTENDED_DB_SCHEMA)
    conn.execute(
        "INSERT OR IGNORE INTO schema_info(version, applied_at) VALUES (?, ?)",
        (1, utc_now()),
    )
    conn.execute(
        "INSERT OR IGNORE INTO schema_info(version, applied_at) VALUES (?, ?)",
        (2, utc_now()),
    )
    conn.commit()


def reset_imported_data(conn: sqlite3.Connection) -> None:
    for table in [
        "sheet_rows",
        "test_runs",
        "mod_files",
        "source_urls",
        "mod_notes",
        "mods",
        "imports",
    ]:
        conn.execute(f"DELETE FROM {table}")
    conn.commit()


def import_csv(
    conn: sqlite3.Connection,
    csv_path: Path,
    spreadsheet_id: str,
    sheet_name: str,
    source_range: str,
    reset: bool,
) -> int:
    init_db(conn)
    if reset:
        reset_imported_data(conn)

    with csv_path.open(newline="", encoding="utf-8") as handle:
        rows = [normalize_row(row) for row in csv.reader(handle)]

    if not rows:
        raise ValueError(f"{csv_path} is empty")
    if rows[0] != HEADERS:
        raise ValueError(f"unexpected CSV header: {rows[0]!r}")

    now = utc_now()
    cur = conn.execute(
        """
        INSERT INTO imports(imported_at, source_file, spreadsheet_id, sheet_name, source_range, row_count)
        VALUES (?, ?, ?, ?, ?, ?)
        """,
        (now, str(csv_path), spreadsheet_id, sheet_name, source_range, len(rows)),
    )
    import_id = int(cur.lastrowid)

    current_category = ""
    for row_number, cells in enumerate(rows[1:], start=2):
        if is_blank_row(cells):
            continue
        if is_section_row(cells):
            current_category = cells[0]
            continue

        name = cells[0]
        if not name:
            continue

        active_status, rank = status_rank(cells[3], cells[8], cells[10])
        kind, host, project_slug = source_kind(cells[6])
        canonical_key = slugify(project_slug or name)
        hash_value = row_hash(cells)

        cur = conn.execute(
            """
            INSERT INTO mods(
                import_id, original_sheet_row, category, name, canonical_key, installation,
                entry_type, tested, target_mc, server_status, client_package,
                last_tested, active_status, status_rank, primary_url, row_hash, created_at, updated_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                import_id,
                row_number,
                current_category,
                name,
                canonical_key,
                cells[1],
                cells[2],
                cells[3],
                cells[7],
                cells[8],
                cells[10],
                cells[11],
                active_status,
                rank,
                cells[6],
                hash_value,
                now,
                now,
            ),
        )
        mod_id = int(cur.lastrowid)

        conn.execute(
            "INSERT INTO mod_notes(mod_id, notes_1, notes_2, migration_notes) VALUES (?, ?, ?, ?)",
            (mod_id, cells[4], cells[5], cells[13]),
        )
        conn.execute(
            """
            INSERT INTO source_urls(
                mod_id, source_kind, url, host, project_slug, resolved_source,
                file_id, release_channel, is_primary
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1)
            """,
            (
                mod_id,
                kind,
                cells[6],
                host,
                project_slug,
                cells[12],
                extract_file_id(cells[12]),
                release_channel(cells[12]),
            ),
        )
        for file_name in split_file_names(cells[9]):
            conn.execute(
                """
                INSERT INTO mod_files(
                    mod_id, role, file_name, path_hint, installed_on_server,
                    included_in_client, status
                )
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    mod_id,
                    "server_file",
                    file_name,
                    cells[9],
                    int(cells[8].lower() == "ok" or cells[8].lower().startswith("runtime")),
                    int(cells[10].lower() == "included"),
                    cells[8],
                ),
            )
        label = test_label_from_notes(cells[13])
        if cells[11] or label or cells[13]:
            conn.execute(
                """
                INSERT INTO test_runs(mod_id, tested_at, test_label, status, error_count, log_path, notes)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    mod_id,
                    cells[11],
                    label,
                    cells[8] or cells[3],
                    error_count_from_notes(cells[13]),
                    "",
                    cells[13],
                ),
            )
        conn.execute(
            """
            INSERT INTO sheet_rows(mod_id, spreadsheet_id, sheet_name, row_number, row_hash)
            VALUES (?, ?, ?, ?, ?)
            """,
            (mod_id, spreadsheet_id, sheet_name, row_number, hash_value),
        )

    mark_duplicates(conn)
    conn.commit()
    return import_id


def mark_duplicates(conn: sqlite3.Connection) -> None:
    groups = conn.execute(
        """
        SELECT canonical_key, COALESCE(NULLIF(primary_url, ''), canonical_key) AS url_key,
               COUNT(*) AS count
        FROM mods
        GROUP BY canonical_key, url_key
        HAVING COUNT(*) > 1
        """
    ).fetchall()
    for group in groups:
        mods = conn.execute(
            """
            SELECT id
            FROM mods
            WHERE canonical_key = ?
              AND COALESCE(NULLIF(primary_url, ''), canonical_key) = ?
            ORDER BY status_rank DESC, original_sheet_row ASC, id ASC
            """,
            (group["canonical_key"], group["url_key"]),
        ).fetchall()
        canonical_id = int(mods[0]["id"])
        for row in mods[1:]:
            conn.execute(
                "UPDATE mods SET is_duplicate = 1, duplicate_of_id = ? WHERE id = ?",
                (canonical_id, int(row["id"])),
            )


def duplicate_note(conn: sqlite3.Connection, mod_id: int) -> str:
    rows = conn.execute(
        "SELECT original_sheet_row FROM mods WHERE duplicate_of_id = ? ORDER BY original_sheet_row",
        (mod_id,),
    ).fetchall()
    if not rows:
        return ""
    row_numbers = ", ".join(str(r["original_sheet_row"]) for r in rows)
    return f" Duplicate rows collapsed into this clean view: original sheet rows {row_numbers}."


def clean_rows(conn: sqlite3.Connection) -> list[list[str]]:
    rows = conn.execute(
        """
        SELECT m.*, n.notes_1, n.notes_2, n.migration_notes,
               su.resolved_source
        FROM mods m
        LEFT JOIN mod_notes n ON n.mod_id = m.id
        LEFT JOIN source_urls su ON su.mod_id = m.id AND su.is_primary = 1
        WHERE m.duplicate_of_id IS NULL
        ORDER BY
            CASE m.category
                WHEN 'Core Game' THEN 0
                WHEN 'Online Resources' THEN 1
                WHEN 'Core Game Mods' THEN 2
                WHEN 'Server Optimizer' THEN 3
                WHEN 'World Mods - Fix' THEN 4
                WHEN 'World Mods' THEN 5
                ELSE 9
            END,
            COALESCE(m.category, ''),
            LOWER(m.name)
        """
    ).fetchall()
    output = [HEADERS]
    for row in rows:
        note = row["migration_notes"] or ""
        note = (note + duplicate_note(conn, int(row["id"]))).strip()
        output.append(
            [
                row["name"],
                row["installation"] or "",
                row["entry_type"] or "",
                row["tested"] or "",
                row["notes_1"] or "",
                row["notes_2"] or "",
                row["primary_url"] or "",
                row["target_mc"] or "",
                row["server_status"] or "",
                original_server_file(conn, int(row["id"])),
                row["client_package"] or "",
                row["last_tested"] or "",
                row["resolved_source"] or "",
                note,
            ]
        )
    return output


def original_server_file(conn: sqlite3.Connection, mod_id: int) -> str:
    row = conn.execute(
        "SELECT path_hint FROM mod_files WHERE mod_id = ? ORDER BY id LIMIT 1",
        (mod_id,),
    ).fetchone()
    if row:
        return row["path_hint"]
    mod = conn.execute("SELECT server_status FROM mods WHERE id = ?", (mod_id,)).fetchone()
    if mod and mod["server_status"].lower().startswith("client"):
        return ""
    return ""


def export_clean_csv(conn: sqlite3.Connection, output_path: Path) -> int:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    rows = clean_rows(conn)
    with output_path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        writer.writerows(rows)
    return len(rows)


def first_sentence(value: str, limit: int = 220) -> str:
    text = " ".join((value or "").split())
    if not text:
        return ""
    match = re.search(r"(?<=[.!?])\s+", text)
    if match:
        text = text[: match.start()].strip()
    if len(text) > limit:
        text = text[: limit - 1].rstrip() + "..."
    return text


def sheet_view_rows(conn: sqlite3.Connection) -> list[list[str]]:
    rows = conn.execute(
        """
        SELECT m.*, n.migration_notes, su.resolved_source
        FROM mods m
        LEFT JOIN mod_notes n ON n.mod_id = m.id
        LEFT JOIN source_urls su ON su.mod_id = m.id AND su.is_primary = 1
        WHERE m.duplicate_of_id IS NULL
        ORDER BY
            CASE m.active_status
                WHEN 'ok' THEN 0
                WHEN 'failed' THEN 1
                WHEN 'codex_fixed_candidate' THEN 2
                WHEN 'awaiting_compatible_release' THEN 3
                WHEN 'blocked_by_dependency' THEN 4
                WHEN 'reference_only' THEN 5
                WHEN 'source_unresolved' THEN 6
                WHEN 'duplicate' THEN 7
                WHEN 'pending' THEN 8
                ELSE 9
            END,
            LOWER(COALESCE(m.category, '')),
            LOWER(m.name)
        """
    ).fetchall()
    output = [SHEET_VIEW_HEADERS]
    for row in rows:
        duplicate = duplicate_note(conn, int(row["id"])).strip()
        note = first_sentence(row["migration_notes"])
        if duplicate:
            note = f"{note} {duplicate}".strip()
        output.append(
            [
                row["name"],
                row["category"] or "",
                row["installation"] or "",
                row["entry_type"] or "",
                row["tested"] or "",
                row["target_mc"] or "",
                row["server_status"] or "",
                original_server_file(conn, int(row["id"])),
                row["client_package"] or "",
                row["last_tested"] or "",
                row["resolved_source"] or "",
                row["primary_url"] or "",
                note,
            ]
        )
    return output


def export_sheet_view_csv(conn: sqlite3.Connection, output_path: Path) -> int:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    rows = sheet_view_rows(conn)
    with output_path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        writer.writerows(rows)
    return len(rows)


def print_summary(conn: sqlite3.Connection) -> None:
    total = conn.execute("SELECT COUNT(*) AS c FROM mods").fetchone()["c"]
    canonical = conn.execute("SELECT COUNT(*) AS c FROM mods WHERE duplicate_of_id IS NULL").fetchone()["c"]
    duplicates = total - canonical
    print(f"records={total}")
    print(f"canonical_records={canonical}")
    print(f"duplicates_collapsed={duplicates}")
    for row in conn.execute(
        """
        SELECT active_status, COUNT(*) AS c
        FROM mods
        GROUP BY active_status
        ORDER BY
            CASE active_status
                WHEN 'ok' THEN 0
                WHEN 'failed' THEN 1
                WHEN 'codex_fixed_candidate' THEN 2
                WHEN 'awaiting_compatible_release' THEN 3
                WHEN 'blocked_by_dependency' THEN 4
                WHEN 'reference_only' THEN 5
                WHEN 'source_unresolved' THEN 6
                WHEN 'duplicate' THEN 7
                WHEN 'pending' THEN 8
                ELSE 9
            END,
            active_status
        """
    ):
        label = active_status_label(str(row["active_status"]))
        print(f"status.{row['active_status']}={row['c']} # {label}")
    included = conn.execute(
        "SELECT COUNT(*) AS c FROM mods WHERE LOWER(client_package) = 'included'"
    ).fetchone()["c"]
    print(f"client_included={included}")


def run_sql(conn: sqlite3.Connection, sql: str) -> None:
    for row in conn.execute(sql):
        print(dict(row))


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", type=Path, default=Path("data/minecraft_mods.sqlite"))
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("init", help="Create or migrate the database schema")

    import_parser = sub.add_parser("import-sheet-csv", help="Import a Google Sheet grid CSV")
    import_parser.add_argument("csv_path", type=Path)
    import_parser.add_argument("--spreadsheet-id", default="1OIJFcikV6d6qKxFDnT34eEFCFOVFXUqRCIcWHMDq1Wo")
    import_parser.add_argument("--sheet-name", default="Minecraft")
    import_parser.add_argument("--source-range", default="A1:N400")
    import_parser.add_argument("--reset", action="store_true")

    export_parser = sub.add_parser("export-clean-csv", help="Export the deduplicated sheet view")
    export_parser.add_argument("output_path", type=Path)

    sheet_export_parser = sub.add_parser(
        "export-google-sheet-csv",
        help="Export a compact canonical table intended to replace the Google Sheet tab",
    )
    sheet_export_parser.add_argument("output_path", type=Path)

    sub.add_parser("summary", help="Print database summary counts")

    sub.add_parser("normalize-statuses", help="Rewrite mods.active_status to the current top-level taxonomy")

    sql_parser = sub.add_parser("sql", help="Run a read-only SQL query")
    sql_parser.add_argument("query")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    conn = connect(args.db)
    try:
        if args.command == "init":
            init_db(conn)
        elif args.command == "import-sheet-csv":
            import_id = import_csv(
                conn,
                args.csv_path,
                args.spreadsheet_id,
                args.sheet_name,
                args.source_range,
                args.reset,
            )
            print(f"import_id={import_id}")
        elif args.command == "export-clean-csv":
            count = export_clean_csv(conn, args.output_path)
            print(f"rows_written={count}")
        elif args.command == "export-google-sheet-csv":
            count = export_sheet_view_csv(conn, args.output_path)
            print(f"rows_written={count}")
        elif args.command == "summary":
            print_summary(conn)
        elif args.command == "normalize-statuses":
            changed = normalize_all_active_statuses(conn)
            print(f"statuses_normalized={changed}")
        elif args.command == "sql":
            if not args.query.lstrip().lower().startswith("select"):
                raise ValueError("sql command only allows SELECT queries")
            run_sql(conn, args.query)
        else:
            parser.error(f"unknown command: {args.command}")
    finally:
        conn.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
