#!/usr/bin/env python3
"""Operational tools for versioned Minecraft server tracking and profiling."""

from __future__ import annotations

import argparse
import datetime as dt
import os
import re
import shutil
import signal
import sqlite3
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Sequence

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import generate_status_site as site
from moddb import connect, init_db, utc_now


DEFAULT_DB = Path("/var/minecraft_mods/data/minecraft_mods.sqlite")
DEFAULT_SERVER_DIR = Path("/var/minecraft_26.1.2")
DEFAULT_SERVER_KEY = "minecraft_26_1_2"
DEFAULT_DISPLAY_NAME = "Pummelchen Server"
CLIENT_ZIP_NAME = "minecraft_26.1.2_client_macos_apple_silicon.zip"
PROFILE_WORLD = "codex_perfworld"
ERROR_RE = re.compile(
    r"(^|[^A-Za-z])ERROR([^A-Za-z]|$)|Exception|Crash report|Failed to start|"
    r"ModLoadingException|Missing.*dependencies|UnsupportedClassVersion|mixin apply failed",
    re.IGNORECASE,
)


def today() -> str:
    return dt.datetime.now(dt.timezone.utc).date().isoformat()


def run_text(cmd: list[str], cwd: Path | None = None) -> str:
    try:
        return subprocess.check_output(cmd, cwd=cwd, text=True, stderr=subprocess.STDOUT, timeout=15).strip()
    except Exception:
        return ""


def sha256_file(path: Path) -> str:
    import hashlib

    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def java_version() -> str:
    text = run_text(["java", "-version"])
    return text.splitlines()[0].replace('"', "") if text else ""


def server_java_version(server_dir: Path) -> str:
    binary = site.detect_server_java_binary(server_dir)
    if not binary:
        return java_version()
    version = site.detect_java(binary)
    return f"{version} ({binary})" if version else binary


def detect_neoforge(server_dir: Path) -> str:
    nf_dir = server_dir / "libraries" / "net" / "neoforged" / "neoforge"
    if not nf_dir.exists():
        return ""
    versions = sorted(path.name for path in nf_dir.iterdir() if path.is_dir())
    return versions[-1] if versions else ""


def infer_minecraft_version(server_dir: Path) -> str:
    version = detect_neoforge(server_dir)
    if version:
        parts = version.split(".")
        if len(parts) >= 3:
            return ".".join(parts[:3])
    return "26.1.2"


def ensure_server_instance(
    conn: sqlite3.Connection,
    *,
    server_key: str,
    display_name: str,
    server_dir: Path,
    active: bool = True,
) -> int:
    init_db(conn)
    now = utc_now()
    loader_version = detect_neoforge(server_dir)
    minecraft_version = infer_minecraft_version(server_dir)
    client_package = server_dir / CLIENT_ZIP_NAME
    row = conn.execute(
        "SELECT id FROM server_instances WHERE server_key = ?",
        (server_key,),
    ).fetchone()
    values = (
        display_name,
        minecraft_version,
        "NeoForge",
        loader_version,
        server_java_version(server_dir),
        str(server_dir),
        str(client_package) if client_package.exists() else "",
        int(active),
        "Current production server instance",
        now,
    )
    if row:
        conn.execute(
            """
            UPDATE server_instances
            SET display_name = ?, minecraft_version = ?, loader = ?,
                loader_version = ?, java_version = ?, server_dir = ?,
                client_package_path = ?, active = ?, notes = ?, updated_at = ?
            WHERE id = ?
            """,
            (*values, int(row["id"])),
        )
        return int(row["id"])
    cur = conn.execute(
        """
        INSERT INTO server_instances(
            server_key, display_name, minecraft_version, loader, loader_version,
            java_version, server_dir, client_package_path, active, notes,
            created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (server_key, *values, now),
    )
    return int(cur.lastrowid)


def fetch_mod_rows(conn: sqlite3.Connection) -> list[sqlite3.Row]:
    return conn.execute(
        """
        SELECT m.*, n.notes_1, n.notes_2, n.migration_notes
        FROM mods m
        LEFT JOIN mod_notes n ON n.mod_id = m.id
        WHERE m.duplicate_of_id IS NULL
        ORDER BY lower(m.name), m.id
        """
    ).fetchall()


def mod_files(conn: sqlite3.Connection, mod_id: int) -> list[sqlite3.Row]:
    return conn.execute(
        """
        SELECT *
        FROM mod_files
        WHERE mod_id = ?
        ORDER BY installed_on_server DESC, included_in_client DESC, file_name
        """,
        (mod_id,),
    ).fetchall()


def source_urls(conn: sqlite3.Connection, mod_id: int) -> list[str]:
    return [
        str(row["url"])
        for row in conn.execute(
            "SELECT url FROM source_urls WHERE mod_id = ? ORDER BY is_primary DESC, id",
            (mod_id,),
        )
    ]


def metadata_mod_dict(conn: sqlite3.Connection, row: sqlite3.Row) -> dict[str, Any]:
    files = [dict(file_row) for file_row in mod_files(conn, int(row["id"]))]
    return {
        "id": row["id"],
        "name": row["name"],
        "canonical_key": row["canonical_key"],
        "category": row["category"],
        "entry_type": row["entry_type"],
        "primary_url": row["primary_url"],
        "server_status": row["server_status"],
        "client_package": row["client_package"],
        "target_mc": row["target_mc"],
        "last_tested": row["last_tested"],
        "notes_1": row["notes_1"],
        "notes_2": row["notes_2"],
        "migration_notes": row["migration_notes"],
        "files": files,
        "sources": source_urls(conn, int(row["id"])),
    }


def infer_side(mod: dict[str, Any]) -> str:
    files = mod.get("files") or []
    server = any(int(file.get("installed_on_server") or 0) == 1 for file in files)
    client = str(mod.get("client_package") or "").lower() == "included" or any(
        int(file.get("included_in_client") or 0) == 1 for file in files
    )
    if server and client:
        return "server+client"
    if server:
        return "server"
    if client:
        return "client"
    return "watchlist"


def risk_flags(mod: dict[str, Any], group: str) -> str:
    flags: list[str] = []
    text = " ".join(str(mod.get(key) or "") for key in ("server_status", "migration_notes", "name", "canonical_key")).lower()
    if group == "Worldgen and Structures":
        flags.append("worldgen")
    if group == "Libraries and Dependencies":
        flags.append("dependency")
    if "beta" in text:
        flags.append("beta")
    if "client-only" in text or infer_side(mod) == "client":
        flags.append("client-only")
    if "no compatible" in text or "watchlist" in text or infer_side(mod) == "watchlist":
        flags.append("watchlist")
    return ",".join(dict.fromkeys(flags))


def performance_priority(group: str, side: str) -> str:
    if side == "client" or side == "watchlist":
        return "low"
    if group in {"Worldgen and Structures", "Mobs and Wildlife", "Performance"}:
        return "high"
    if group in {"Libraries and Dependencies", "Gameplay"}:
        return "medium"
    return "normal"


def backfill_metadata(conn: sqlite3.Connection) -> int:
    init_db(conn)
    now = utc_now()
    count = 0
    for row in fetch_mod_rows(conn):
        mod = metadata_mod_dict(conn, row)
        group = site.group_for_mod(mod)
        mod["group"] = group
        mod["version"] = site.version_text(mod["files"])
        summary = site.description_for_mod(mod)
        side = infer_side(mod)
        conn.execute(
            """
            INSERT INTO mod_metadata(
                mod_id, group_tag, side, summary, gameplay_tags, risk_flags,
                dependency_notes, performance_notes, metadata_source, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(mod_id) DO UPDATE SET
                group_tag = excluded.group_tag,
                side = excluded.side,
                summary = excluded.summary,
                gameplay_tags = excluded.gameplay_tags,
                risk_flags = excluded.risk_flags,
                dependency_notes = excluded.dependency_notes,
                performance_notes = excluded.performance_notes,
                metadata_source = excluded.metadata_source,
                updated_at = excluded.updated_at
            """,
            (
                int(row["id"]),
                group,
                side,
                summary,
                group.lower().replace(" and ", ",").replace(" ", "-"),
                risk_flags(mod, group),
                row["notes_2"] or "",
                f"profile_priority={performance_priority(group, side)}",
                "server_ops.py heuristic",
                now,
            ),
        )
        count += 1
    conn.commit()
    return count


def risk_for_mod(conn: sqlite3.Connection, mod_id: int, group: str, side: str, flags: str) -> tuple[int, str, str]:
    score = 0
    factors: list[str] = []
    if side == "server+client" or side == "server":
        score += 10
        factors.append("server-side")
    if group == "Worldgen and Structures":
        score += 35
        factors.append("worldgen/structures")
    elif group == "Mobs and Wildlife":
        score += 25
        factors.append("mobs")
    elif group == "Performance":
        score += 20
        factors.append("performance-sensitive")
    elif group == "Libraries and Dependencies":
        score += 15
        factors.append("dependency")
    if "beta" in (flags or ""):
        score += 20
        factors.append("beta")
    failed_runs = conn.execute(
        "SELECT COUNT(*) AS c FROM test_runs WHERE mod_id = ? AND lower(status) NOT IN ('ok', 'started')",
        (mod_id,),
    ).fetchone()["c"]
    if failed_runs:
        score += min(int(failed_runs) * 5, 20)
        factors.append(f"{failed_runs} prior non-ok test runs")
    perf = conn.execute(
        """
        SELECT memory_delta_mb, cpu_delta_pct
        FROM mod_performance_profiles
        WHERE mod_id = ?
        ORDER BY measured_at DESC
        LIMIT 1
        """,
        (mod_id,),
    ).fetchone()
    if perf:
        mem = abs(float(perf["memory_delta_mb"] or 0))
        cpu = abs(float(perf["cpu_delta_pct"] or 0))
        if mem >= 250:
            score += 20
            factors.append("large measured RAM delta")
        elif mem >= 100:
            score += 10
            factors.append("measured RAM delta")
        if cpu >= 5:
            score += 15
            factors.append("large measured CPU delta")
        elif cpu >= 1:
            score += 8
            factors.append("measured CPU delta")
    if "client-only" in (flags or "") or side == "client":
        score = max(score - 20, 0)
        factors.append("client-only")
    if "watchlist" in (flags or "") or side == "watchlist":
        score = 0
        factors.append("watchlist")
    if score >= 70:
        level = "high"
    elif score >= 40:
        level = "medium"
    elif score:
        level = "low"
    else:
        level = "none"
    return score, level, ",".join(factors)


def score_risks(conn: sqlite3.Connection, server_instance_id: int) -> int:
    init_db(conn)
    now = utc_now()
    rows = conn.execute(
        """
        SELECT m.id, m.active_status, mm.group_tag, mm.side, mm.risk_flags
        FROM mods m
        LEFT JOIN mod_metadata mm ON mm.mod_id = m.id
        WHERE m.duplicate_of_id IS NULL
        """
    ).fetchall()
    count = 0
    for row in rows:
        score, level, factors = risk_for_mod(
            conn,
            int(row["id"]),
            row["group_tag"] or "",
            row["side"] or "",
            row["risk_flags"] or "",
        )
        conn.execute(
            """
            INSERT INTO mod_risk_scores(
                mod_id, server_instance_id, risk_score, risk_level, factors, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(mod_id, server_instance_id) DO UPDATE SET
                risk_score = excluded.risk_score,
                risk_level = excluded.risk_level,
                factors = excluded.factors,
                updated_at = excluded.updated_at
            """,
            (int(row["id"]), server_instance_id, score, level, factors, now),
        )
        has_server_file = conn.execute(
            "SELECT 1 FROM mod_files WHERE mod_id = ? AND installed_on_server = 1 LIMIT 1",
            (int(row["id"]),),
        ).fetchone()
        if has_server_file and score > 0 and row["active_status"] == "ok":
            conn.execute(
                """
                INSERT INTO profiling_queue(
                    mod_id, server_instance_id, priority, status, requested_at, notes
                ) VALUES (?, ?, ?, 'queued', ?, ?)
                ON CONFLICT(mod_id, server_instance_id) DO UPDATE SET
                    priority = excluded.priority,
                    notes = excluded.notes
                """,
                (int(row["id"]), server_instance_id, score, now, factors),
            )
        count += 1
    conn.commit()
    return count


def file_path_for(server_dir: Path, file_row: sqlite3.Row) -> Path | None:
    name = str(file_row["file_name"])
    role = str(file_row["role"] or "")
    candidates = []
    if int(file_row["installed_on_server"] or 0):
        if role == "server_datapack":
            candidates.append(server_dir / "server-datapacks" / name)
            candidates.append(server_dir / "world" / "datapacks" / name)
        else:
            candidates.append(server_dir / "mods" / name)
    if int(file_row["included_in_client"] or 0):
        if role == "shaderpack":
            candidates.append(server_dir / "client-package" / "shaderpacks" / name)
        elif name.endswith(".zip"):
            candidates.append(server_dir / "client-package" / "resourcepacks" / name)
        candidates.append(server_dir / "client-package" / "mods" / name)
        candidates.append(server_dir / "client-package" / "resourcepacks" / name)
    for candidate in candidates:
        if candidate.exists():
            return candidate
    return None


def sync_instance_files(conn: sqlite3.Connection, server_instance_id: int, server_dir: Path) -> int:
    init_db(conn)
    now = utc_now()
    count = 0
    for mod in fetch_mod_rows(conn):
        mod_id = int(mod["id"])
        conn.execute(
            "DELETE FROM mod_server_files WHERE server_instance_id = ? AND mod_id = ?",
            (server_instance_id, mod_id),
        )
        urls = source_urls(conn, mod_id)
        primary_url = urls[0] if urls else str(mod["primary_url"] or "")
        files = mod_files(conn, mod_id)
        compatibility = str(mod["active_status"])
        if not files:
            file_name = "(no selected file)"
            conn.execute(
                """
                INSERT INTO mod_server_files(
                    server_instance_id, mod_id, mod_file_id, file_name, role,
                    source_url, compatibility_status, installed_on_server,
                    included_in_client, selected, last_synced, notes
                ) VALUES (?, ?, NULL, ?, 'watchlist', ?, ?, 0, 0, 1, ?, ?)
                ON CONFLICT(server_instance_id, mod_id, file_name, role) DO UPDATE SET
                    source_url = excluded.source_url,
                    compatibility_status = excluded.compatibility_status,
                    last_synced = excluded.last_synced,
                    notes = excluded.notes
                """,
                (
                    server_instance_id,
                    mod_id,
                    file_name,
                    primary_url,
                    compatibility,
                    now,
                    mod["server_status"] or "",
                ),
            )
            count += 1
            continue
        for file_row in files:
            path = file_path_for(server_dir, file_row)
            file_size = path.stat().st_size if path and path.exists() else None
            file_hash = sha256_file(path) if path and path.exists() else ""
            conn.execute(
                """
                INSERT INTO mod_server_files(
                    server_instance_id, mod_id, mod_file_id, file_name, role,
                    source_url, compatibility_status, installed_on_server,
                    included_in_client, selected, file_sha256, file_size_bytes,
                    release_channel, file_id, last_synced, notes
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(server_instance_id, mod_id, file_name, role) DO UPDATE SET
                    mod_file_id = excluded.mod_file_id,
                    source_url = excluded.source_url,
                    compatibility_status = excluded.compatibility_status,
                    installed_on_server = excluded.installed_on_server,
                    included_in_client = excluded.included_in_client,
                    file_sha256 = excluded.file_sha256,
                    file_size_bytes = excluded.file_size_bytes,
                    release_channel = excluded.release_channel,
                    file_id = excluded.file_id,
                    last_synced = excluded.last_synced,
                    notes = excluded.notes
                """,
                (
                    server_instance_id,
                    mod_id,
                    int(file_row["id"]),
                    file_row["file_name"],
                    file_row["role"],
                    primary_url,
                    compatibility,
                    int(file_row["installed_on_server"] or 0),
                    int(file_row["included_in_client"] or 0),
                    file_hash,
                    file_size,
                    "",
                    "",
                    now,
                    file_row["status"] or "",
                ),
            )
            count += 1
    conn.commit()
    return count


def latest_baseline(conn: sqlite3.Connection, server_instance_id: int) -> sqlite3.Row | None:
    return conn.execute(
        """
        SELECT *
        FROM performance_runs
        WHERE server_instance_id = ?
          AND run_type = 'baseline'
          AND status = 'started'
          AND done_seen = 1
        ORDER BY id DESC
        LIMIT 1
        """,
        (server_instance_id,),
    ).fetchone()


def read_proc_stat(pid: int) -> tuple[int, int]:
    text = Path(f"/proc/{pid}/stat").read_text(encoding="utf-8", errors="replace")
    after = text.rsplit(")", 1)[1].strip().split()
    utime = int(after[11])
    stime = int(after[12])
    return utime, stime


def read_rss_mb(pid: int) -> float:
    status = Path(f"/proc/{pid}/status").read_text(encoding="utf-8", errors="replace")
    for line in status.splitlines():
        if line.startswith("VmRSS:"):
            return float(line.split()[1]) / 1024.0
    return 0.0


def load_1m() -> float:
    try:
        return float(Path("/proc/loadavg").read_text().split()[0])
    except Exception:
        return 0.0


def sample_java(pid: int, seconds: int, interval: float) -> tuple[list[float], list[float], list[float]]:
    rss_samples: list[float] = []
    cpu_samples: list[float] = []
    load_samples: list[float] = []
    clk_tck = os.sysconf(os.sysconf_names["SC_CLK_TCK"])
    cpu_count = os.cpu_count() or 1
    end = time.monotonic() + seconds
    try:
        prev_utime, prev_stime = read_proc_stat(pid)
        prev_time = time.monotonic()
    except Exception:
        return rss_samples, cpu_samples, load_samples
    while time.monotonic() < end and Path(f"/proc/{pid}").exists():
        time.sleep(interval)
        now = time.monotonic()
        try:
            utime, stime = read_proc_stat(pid)
            rss_samples.append(read_rss_mb(pid))
            load_samples.append(load_1m())
        except Exception:
            break
        proc_delta = (utime + stime) - (prev_utime + prev_stime)
        wall_delta = max(now - prev_time, 0.001)
        cpu_pct = ((proc_delta / clk_tck) / wall_delta) / cpu_count * 100.0
        cpu_samples.append(cpu_pct)
        prev_utime, prev_stime, prev_time = utime, stime, now
    return rss_samples, cpu_samples, load_samples


def set_level_name(server_dir: Path, level_name: str) -> Path | None:
    props = server_dir / "server.properties"
    if not props.exists():
        return None
    backup = server_dir / "server-test-results" / f"{level_name}.server.properties.bak"
    backup.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(props, backup)
    lines = props.read_text(encoding="utf-8", errors="replace").splitlines()
    found = False
    for index, line in enumerate(lines):
        if line.startswith("level-name="):
            lines[index] = f"level-name={level_name}"
            found = True
            break
    if not found:
        lines.append(f"level-name={level_name}")
    props.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return backup


def restore_level_name(server_dir: Path, backup: Path | None) -> None:
    if backup and backup.exists():
        shutil.move(str(backup), str(server_dir / "server.properties"))


def grep_errors(log_path: Path) -> tuple[int, int]:
    if not log_path.exists():
        return 0, 0
    error_lines = [
        f"{index}:{line}"
        for index, line in enumerate(log_path.read_text(encoding="utf-8", errors="replace").splitlines(), start=1)
        if ERROR_RE.search(line)
    ]
    if not error_lines:
        return 0, 0
    try:
        import process_url_batch

        temp = log_path.with_suffix(".profile.errors")
        temp.write_text("\n".join(error_lines), encoding="utf-8")
        severe = process_url_batch.filtered_error_lines(temp)
        return len(error_lines), len(severe)
    except Exception:
        return len(error_lines), len(error_lines)


def run_profile(
    *,
    server_dir: Path,
    label: str,
    timeout: int,
    idle_seconds: int,
    sample_interval: float,
) -> dict[str, Any]:
    results_dir = server_dir / "server-test-results"
    results_dir.mkdir(parents=True, exist_ok=True)
    safe_label = re.sub(r"[^A-Za-z0-9._-]+", "_", label).strip("_")
    log_path = results_dir / f"{safe_label}.profile.log"
    world_dir = server_dir / PROFILE_WORLD
    if world_dir.exists():
        shutil.rmtree(world_dir)
    datapacks_dir = server_dir / "server-datapacks"
    if datapacks_dir.exists():
        target = world_dir / "datapacks"
        target.mkdir(parents=True, exist_ok=True)
        for pack in datapacks_dir.iterdir():
            if pack.is_file():
                shutil.copy2(pack, target / pack.name)
    backup = set_level_name(server_dir, PROFILE_WORLD)
    start = time.monotonic()
    started_at = utc_now()
    status = "timeout"
    done_seen = False
    proc: subprocess.Popen[str] | None = None
    rss: list[float] = []
    cpu: list[float] = []
    loads: list[float] = []
    try:
        with log_path.open("w", encoding="utf-8") as log_handle:
            proc = subprocess.Popen(
                ["./start.sh"],
                cwd=server_dir,
                stdin=subprocess.PIPE,
                stdout=log_handle,
                stderr=subprocess.STDOUT,
                text=True,
            )
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                if proc.poll() is not None:
                    status = "exited"
                    break
                if log_path.exists() and "Done (" in log_path.read_text(encoding="utf-8", errors="replace"):
                    status = "started"
                    done_seen = True
                    break
                time.sleep(1)
            if done_seen and proc.poll() is None:
                rss, cpu, loads = sample_java(proc.pid, idle_seconds, sample_interval)
            if proc.poll() is None and proc.stdin:
                try:
                    proc.stdin.write("stop\n")
                    proc.stdin.flush()
                except Exception:
                    pass
            try:
                proc.wait(timeout=90)
            except subprocess.TimeoutExpired:
                proc.terminate()
                try:
                    proc.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait(timeout=10)
    finally:
        restore_level_name(server_dir, backup)
    elapsed = time.monotonic() - start
    raw_errors, severe_errors = grep_errors(log_path)
    if severe_errors:
        status = "severe_errors"
    return {
        "started_at": started_at,
        "duration_seconds": elapsed,
        "idle_seconds": idle_seconds if done_seen else 0,
        "status": status,
        "done_seen": int(done_seen),
        "sample_count": len(rss),
        "avg_rss_mb": sum(rss) / len(rss) if rss else None,
        "peak_rss_mb": max(rss) if rss else None,
        "avg_cpu_pct": sum(cpu) / len(cpu) if cpu else None,
        "peak_cpu_pct": max(cpu) if cpu else None,
        "avg_load_1m": sum(loads) / len(loads) if loads else None,
        "error_count": raw_errors,
        "severe_error_count": severe_errors,
        "log_path": str(log_path),
    }


def insert_performance_run(
    conn: sqlite3.Connection,
    *,
    server_instance_id: int,
    run_label: str,
    run_type: str,
    mod_id: int | None,
    metrics: dict[str, Any],
    notes: str,
) -> int:
    cur = conn.execute(
        """
        INSERT INTO performance_runs(
            server_instance_id, run_label, run_type, mod_id, started_at,
            duration_seconds, idle_seconds, status, done_seen, sample_count,
            avg_rss_mb, peak_rss_mb, avg_cpu_pct, peak_cpu_pct, avg_load_1m,
            error_count, severe_error_count, log_path, notes
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            server_instance_id,
            run_label,
            run_type,
            mod_id,
            metrics["started_at"],
            metrics["duration_seconds"],
            metrics["idle_seconds"],
            metrics["status"],
            metrics["done_seen"],
            metrics["sample_count"],
            metrics["avg_rss_mb"],
            metrics["peak_rss_mb"],
            metrics["avg_cpu_pct"],
            metrics["peak_cpu_pct"],
            metrics["avg_load_1m"],
            metrics["error_count"],
            metrics["severe_error_count"],
            metrics["log_path"],
            notes,
        ),
    )
    conn.commit()
    return int(cur.lastrowid)


def find_mod(conn: sqlite3.Connection, value: str) -> sqlite3.Row:
    row = conn.execute(
        """
        SELECT *
        FROM mods
        WHERE duplicate_of_id IS NULL
          AND (canonical_key = ? OR lower(name) = lower(?))
        ORDER BY status_rank DESC, id
        LIMIT 1
        """,
        (value, value),
    ).fetchone()
    if not row:
        raise SystemExit(f"mod not found: {value}")
    return row


def move_mod_files(server_dir: Path, mod_id: int, conn: sqlite3.Connection, label: str) -> list[tuple[Path, Path]]:
    moved: list[tuple[Path, Path]] = []
    quarantine = server_dir / "mods.profiled-out" / label
    quarantine.mkdir(parents=True, exist_ok=True)
    for file_row in conn.execute(
        "SELECT file_name FROM mod_files WHERE mod_id = ? AND installed_on_server = 1",
        (mod_id,),
    ):
        src = server_dir / "mods" / str(file_row["file_name"])
        if not src.exists():
            continue
        dst = quarantine / src.name
        shutil.move(str(src), str(dst))
        moved.append((dst, src))
    if not moved:
        raise SystemExit("selected mod has no installed server-side files to profile")
    return moved


def restore_moved_files(moved: list[tuple[Path, Path]]) -> None:
    for src, dst in reversed(moved):
        if src.exists():
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(src), str(dst))


def profile_mod(
    conn: sqlite3.Connection,
    *,
    server_instance_id: int,
    server_dir: Path,
    mod_key: str,
    timeout: int,
    idle_seconds: int,
    sample_interval: float,
) -> int:
    baseline = latest_baseline(conn, server_instance_id)
    if not baseline:
        raise SystemExit("no successful baseline profile exists for this server instance")
    mod = find_mod(conn, mod_key)
    label = f"without_{mod['canonical_key']}_{dt.datetime.now(dt.timezone.utc).strftime('%Y%m%d_%H%M%S')}"
    moved = move_mod_files(server_dir, int(mod["id"]), conn, label)
    try:
        metrics = run_profile(
            server_dir=server_dir,
            label=label,
            timeout=timeout,
            idle_seconds=idle_seconds,
            sample_interval=sample_interval,
        )
    finally:
        restore_moved_files(moved)
    run_id = insert_performance_run(
        conn,
        server_instance_id=server_instance_id,
        run_label=label,
        run_type="without_mod",
        mod_id=int(mod["id"]),
        metrics=metrics,
        notes=f"Remove-one idle profile for {mod['name']}",
    )
    status = "ok" if metrics["status"] == "started" and metrics["done_seen"] else "comparison_failed"
    memory_delta = None
    cpu_delta = None
    confidence = "low-single-run"
    if status == "ok" and baseline["avg_rss_mb"] is not None and metrics["avg_rss_mb"] is not None:
        memory_delta = float(baseline["avg_rss_mb"]) - float(metrics["avg_rss_mb"])
        cpu_delta = float(baseline["avg_cpu_pct"] or 0) - float(metrics["avg_cpu_pct"] or 0)
        confidence = "low-single-run"
    conn.execute(
        """
        INSERT INTO mod_performance_profiles(
            mod_id, server_instance_id, baseline_run_id, comparison_run_id,
            measured_at, method, memory_delta_mb, cpu_delta_pct, status,
            confidence, notes
        ) VALUES (?, ?, ?, ?, ?, 'remove-one-idle', ?, ?, ?, ?, ?)
        ON CONFLICT(mod_id, server_instance_id, method) DO UPDATE SET
            baseline_run_id = excluded.baseline_run_id,
            comparison_run_id = excluded.comparison_run_id,
            measured_at = excluded.measured_at,
            memory_delta_mb = excluded.memory_delta_mb,
            cpu_delta_pct = excluded.cpu_delta_pct,
            status = excluded.status,
            confidence = excluded.confidence,
            notes = excluded.notes
        """,
        (
            int(mod["id"]),
            server_instance_id,
            int(baseline["id"]),
            run_id,
            utc_now(),
            memory_delta,
            cpu_delta,
            status,
            confidence,
            f"Positive deltas mean the full pack used more resources than the pack without {mod['name']}.",
        ),
    )
    conn.commit()
    return run_id


def export_performance_csv(conn: sqlite3.Connection, output_path: Path) -> int:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    rows = conn.execute(
        """
        SELECT
            si.server_key,
            m.name,
            m.canonical_key,
            mm.group_tag,
            mm.side,
            p.method,
            p.status,
            p.memory_delta_mb,
            p.cpu_delta_pct,
            p.confidence,
            p.measured_at,
            p.notes
        FROM mod_performance_profiles p
        JOIN mods m ON m.id = p.mod_id
        JOIN server_instances si ON si.id = p.server_instance_id
        LEFT JOIN mod_metadata mm ON mm.mod_id = m.id
        ORDER BY p.memory_delta_mb DESC, p.cpu_delta_pct DESC, lower(m.name)
        """
    ).fetchall()
    import csv

    with output_path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        writer.writerow(rows[0].keys() if rows else [
            "server_key", "name", "canonical_key", "group_tag", "side",
            "method", "status", "memory_delta_mb", "cpu_delta_pct",
            "confidence", "measured_at", "notes",
        ])
        for row in rows:
            writer.writerow([row[key] for key in row.keys()])
    return len(rows)


def print_summary(conn: sqlite3.Connection) -> None:
    for row in conn.execute("SELECT server_key, minecraft_version, loader_version, server_dir FROM server_instances ORDER BY id"):
        print(f"server={row['server_key']} mc={row['minecraft_version']} loader={row['loader_version']} dir={row['server_dir']}")
    for row in conn.execute("SELECT group_tag, COUNT(*) AS c FROM mod_metadata GROUP BY group_tag ORDER BY c DESC, group_tag"):
        print(f"group.{row['group_tag']}={row['c']}")
    row = conn.execute("SELECT COUNT(*) AS c FROM performance_runs").fetchone()
    print(f"performance_runs={row['c']}")
    row = conn.execute("SELECT COUNT(*) AS c FROM mod_performance_profiles").fetchone()
    print(f"mod_performance_profiles={row['c']}")
    if conn.execute("SELECT 1 FROM sqlite_master WHERE name='mod_risk_scores'").fetchone():
        for row in conn.execute("SELECT risk_level, COUNT(*) AS c FROM mod_risk_scores GROUP BY risk_level ORDER BY c DESC"):
            print(f"risk.{row['risk_level']}={row['c']}")
    if conn.execute("SELECT 1 FROM sqlite_master WHERE name='profiling_queue'").fetchone():
        row = conn.execute("SELECT COUNT(*) AS c FROM profiling_queue WHERE status = 'queued'").fetchone()
        print(f"profiling_queue.queued={row['c']}")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", type=Path, default=DEFAULT_DB)
    parser.add_argument("--server-dir", type=Path, default=DEFAULT_SERVER_DIR)
    parser.add_argument("--server-key", default=DEFAULT_SERVER_KEY)
    parser.add_argument("--display-name", default=DEFAULT_DISPLAY_NAME)
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("migrate", help="Create additive multi-version/performance tables")
    sub.add_parser("backfill-metadata", help="Populate mod_metadata group tags and summaries")
    sub.add_parser("sync-instance", help="Register/sync current server instance mod files")
    sub.add_parser("score-risks", help="Calculate risk scores and refresh the profiling queue")

    baseline = sub.add_parser("profile-baseline", help="Run and store an idle baseline profile")
    baseline.add_argument("--timeout", type=int, default=900)
    baseline.add_argument("--idle-seconds", type=int, default=45)
    baseline.add_argument("--sample-interval", type=float, default=5.0)

    profile = sub.add_parser("profile-mod", help="Run a remove-one idle profile for one server mod")
    profile.add_argument("mod")
    profile.add_argument("--timeout", type=int, default=900)
    profile.add_argument("--idle-seconds", type=int, default=45)
    profile.add_argument("--sample-interval", type=float, default=5.0)

    export = sub.add_parser("export-performance-csv", help="Export mod performance deltas")
    export.add_argument("output_path", type=Path)

    sub.add_parser("summary", help="Print version/performance metadata summary")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    with connect(args.db) as conn:
        init_db(conn)
        if args.command == "migrate":
            print("schema=ok")
        elif args.command == "backfill-metadata":
            print(f"metadata_rows={backfill_metadata(conn)}")
        elif args.command == "sync-instance":
            server_id = ensure_server_instance(
                conn,
                server_key=args.server_key,
                display_name=args.display_name,
                server_dir=args.server_dir,
            )
            count = sync_instance_files(conn, server_id, args.server_dir)
            print(f"server_instance_id={server_id}")
            print(f"versioned_file_rows={count}")
        elif args.command == "score-risks":
            server_id = ensure_server_instance(
                conn,
                server_key=args.server_key,
                display_name=args.display_name,
                server_dir=args.server_dir,
            )
            print(f"risk_rows={score_risks(conn, server_id)}")
        elif args.command == "profile-baseline":
            server_id = ensure_server_instance(
                conn,
                server_key=args.server_key,
                display_name=args.display_name,
                server_dir=args.server_dir,
            )
            label = f"baseline_{args.server_key}_{dt.datetime.now(dt.timezone.utc).strftime('%Y%m%d_%H%M%S')}"
            metrics = run_profile(
                server_dir=args.server_dir,
                label=label,
                timeout=args.timeout,
                idle_seconds=args.idle_seconds,
                sample_interval=args.sample_interval,
            )
            run_id = insert_performance_run(
                conn,
                server_instance_id=server_id,
                run_label=label,
                run_type="baseline",
                mod_id=None,
                metrics=metrics,
                notes="Full active pack idle baseline",
            )
            print(f"performance_run_id={run_id}")
            for key in ("status", "done_seen", "sample_count", "avg_rss_mb", "peak_rss_mb", "avg_cpu_pct", "peak_cpu_pct", "severe_error_count", "log_path"):
                print(f"{key}={metrics[key]}")
        elif args.command == "profile-mod":
            server_id = ensure_server_instance(
                conn,
                server_key=args.server_key,
                display_name=args.display_name,
                server_dir=args.server_dir,
            )
            run_id = profile_mod(
                conn,
                server_instance_id=server_id,
                server_dir=args.server_dir,
                mod_key=args.mod,
                timeout=args.timeout,
                idle_seconds=args.idle_seconds,
                sample_interval=args.sample_interval,
            )
            print(f"comparison_run_id={run_id}")
        elif args.command == "export-performance-csv":
            count = export_performance_csv(conn, args.output_path)
            print(f"rows_written={count}")
        elif args.command == "summary":
            print_summary(conn)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
