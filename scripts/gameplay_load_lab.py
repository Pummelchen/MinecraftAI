#!/usr/bin/env python3
"""Repeatable gameplay/load scenarios for Pummelchen Minecraft testing."""

from __future__ import annotations

import argparse
import datetime as dt
import os
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

import minecraft_metrics_exporter as metrics
from moddb import connect, init_db, utc_now


DEFAULT_DB = Path("/var/minecraft_mods/data/minecraft_mods.sqlite")
DEFAULT_SERVER_DIR = Path("/var/minecraft_26.1.2")
DEFAULT_LOG_DIR = Path("/var/minecraft_mods/load_lab")
DEFAULT_SERVER_KEY = "minecraft_26_1_2"
DEFAULT_RELEASE_POINTER = Path("/var/minecraft_mods/site/public/downloads/current-release.json")

SCENARIOS: dict[str, dict[str, Any]] = {
    "fresh_world_idle": {
        "description": "Boot a temporary fresh world, wait for Done, then sample idle health.",
        "duration": 180,
        "commands": [],
        "temporary_world": True,
    },
    "chunk_spiral": {
        "description": "Boot a temporary world and force-load a small chunk spiral to exercise generation.",
        "duration": 240,
        "commands": [
            "forceload add 0 0",
            "forceload add 1 0",
            "forceload add 0 1",
            "forceload add -1 0",
            "forceload add 0 -1",
            "forceload add 2 0",
            "forceload add 0 2",
            "forceload add -2 0",
            "forceload add 0 -2",
        ],
        "temporary_world": True,
    },
    "manual_join_window": {
        "description": "Boot a temporary world and keep it open so real clients can join while samples are collected.",
        "duration": 600,
        "commands": [],
        "temporary_world": True,
    },
}


def read_key_values(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.exists():
        return values
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key] = value
    return values


def write_key_values(path: Path, values: dict[str, str], original: str) -> None:
    seen: set[str] = set()
    lines: list[str] = []
    for raw in original.splitlines():
        if raw and not raw.startswith("#") and "=" in raw:
            key = raw.split("=", 1)[0]
            if key in values:
                lines.append(f"{key}={values[key]}")
                seen.add(key)
                continue
        lines.append(raw)
    for key, value in values.items():
        if key not in seen:
            lines.append(f"{key}={value}")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def configure_temporary_world(server_dir: Path, run_label: str) -> tuple[Path, Path | None]:
    properties = server_dir / "server.properties"
    original = properties.read_text(encoding="utf-8", errors="replace") if properties.exists() else ""
    backup = properties.with_suffix(properties.suffix + f".load-lab-{run_label}.bak")
    if properties.exists():
        shutil.copy2(properties, backup)
    level_name = f"pummelchen_lab_{run_label}"
    values = read_key_values(properties)
    values["level-name"] = level_name
    values.setdefault("enable-command-block", "true")
    values.setdefault("online-mode", "true")
    values.setdefault("motd", "Pummelchen Load Lab")
    write_key_values(properties, values, original)
    return server_dir / level_name, backup if properties.exists() else None


def restore_server_properties(server_dir: Path, backup: Path | None) -> None:
    if not backup:
        return
    target = server_dir / "server.properties"
    shutil.copy2(backup, target)
    backup.unlink(missing_ok=True)


def active_release_id(db_path: Path, server_key: str, pointer: Path) -> str:
    if pointer.exists():
        try:
            data = metrics.read_json(pointer)
            if data.get("release_id"):
                return str(data["release_id"])
        except Exception:
            pass
    try:
        with connect(db_path) as conn:
            init_db(conn)
            row = conn.execute(
                "SELECT release_id FROM pack_releases WHERE server_key = ? AND active = 1 ORDER BY activated_at DESC LIMIT 1",
                (server_key,),
            ).fetchone()
            return str(row["release_id"]) if row else ""
    except Exception:
        return ""


def server_instance_id(conn: sqlite3.Connection, server_key: str) -> int | None:
    row = conn.execute("SELECT id FROM server_instances WHERE server_key = ?", (server_key,)).fetchone()
    return int(row["id"]) if row else None


def command_path(server_dir: Path) -> list[str]:
    for name in ("run.sh", "start.sh"):
        script = server_dir / name
        if script.exists():
            return ["bash", str(script)]
    raise SystemExit(f"no run.sh or start.sh found in {server_dir}")


def players_online() -> int:
    try:
        status = metrics.minecraft_status("127.0.0.1", 25565, timeout=1.0)
        return int((status.get("players") or {}).get("online") or 0)
    except Exception:
        return 0


def sample(
    server_dir: Path,
    pid: int | None,
    start_monotonic: float,
    process_state: dict[str, Any],
) -> tuple[dict[str, float], dict[str, Any]]:
    rss_mb = 0.0
    cpu_pct = 0.0
    next_process_state = process_state
    if pid is not None:
        process, next_process_state = metrics.process_metrics(pid, {"process": process_state}, time.time())
        rss_mb = process["process_rss_bytes"] / (1024 * 1024)
        cpu_pct = process["process_cpu_percent"]
    log_values = metrics.latest_log_metrics(server_dir)
    return {
        "elapsed_seconds": time.monotonic() - start_monotonic,
        "rss_mb": rss_mb,
        "cpu_pct": cpu_pct,
        "load_1m": os.getloadavg()[0] if hasattr(os, "getloadavg") else 0.0,
        "region_files": float(metrics.count_region_files(server_dir)),
        "players_online": float(players_online()),
        "tps": log_values["latest_tps"],
        "mspt": log_values["latest_mspt"],
    }, next_process_state


def wait_for_done(log_path: Path, timeout: int) -> bool:
    deadline = time.monotonic() + timeout
    position = 0
    while time.monotonic() < deadline:
        if log_path.exists():
            text = log_path.read_text(encoding="utf-8", errors="replace")
            if len(text) != position:
                position = len(text)
            if "Done (" in text or "Done (" in text.replace(",", "."):
                return True
        time.sleep(2)
    return False


def stop_server(process: subprocess.Popen[str]) -> None:
    if process.poll() is not None:
        return
    try:
        if process.stdin:
            process.stdin.write("stop\n")
            process.stdin.flush()
    except Exception:
        pass
    try:
        process.wait(timeout=60)
        return
    except subprocess.TimeoutExpired:
        pass
    process.send_signal(signal.SIGTERM)
    try:
        process.wait(timeout=20)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=20)


def insert_run(
    conn: sqlite3.Connection,
    *,
    server_id: int | None,
    release_id: str,
    run_label: str,
    scenario: str,
    status: str,
    log_path: Path,
    notes: str,
) -> int:
    cur = conn.execute(
        """
        INSERT INTO load_lab_runs(
            server_instance_id, release_id, run_label, scenario, started_at,
            status, log_path, notes
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (server_id, release_id or None, run_label, scenario, utc_now(), status, str(log_path), notes),
    )
    conn.commit()
    return int(cur.lastrowid)


def finish_run(conn: sqlite3.Connection, run_id: int, samples: list[dict[str, float]], status: str, notes: str) -> None:
    peak_rss = max((sample_row["rss_mb"] for sample_row in samples), default=0.0)
    avg_cpu = sum(sample_row["cpu_pct"] for sample_row in samples) / len(samples) if samples else 0.0
    max_regions = int(max((sample_row["region_files"] for sample_row in samples), default=0.0))
    conn.execute(
        """
        UPDATE load_lab_runs
        SET completed_at = ?, status = ?, duration_seconds = ?,
            sample_count = ?, peak_rss_mb = ?, avg_cpu_pct = ?,
            max_region_files = ?, error_count = ?, severe_error_count = ?,
            notes = ?
        WHERE id = ?
        """,
        (
            utc_now(),
            status,
            max((sample_row["elapsed_seconds"] for sample_row in samples), default=0.0),
            len(samples),
            peak_rss,
            avg_cpu,
            max_regions,
            0,
            0,
            notes,
            run_id,
        ),
    )
    for sample_row in samples:
        conn.execute(
            """
            INSERT INTO load_lab_samples(
                run_id, sampled_at, elapsed_seconds, rss_mb, cpu_pct, load_1m,
                region_files, players_online, tps, mspt
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                run_id,
                utc_now(),
                sample_row["elapsed_seconds"],
                sample_row["rss_mb"],
                sample_row["cpu_pct"],
                sample_row["load_1m"],
                int(sample_row["region_files"]),
                int(sample_row["players_online"]),
                sample_row["tps"],
                sample_row["mspt"],
            ),
        )
    conn.commit()


def run_scenario(args: argparse.Namespace) -> int:
    scenario = SCENARIOS[args.scenario]
    run_label = args.run_label or f"{args.scenario}_{dt.datetime.now(dt.timezone.utc).strftime('%Y%m%d_%H%M%S')}"
    duration = args.duration or int(scenario["duration"])
    if args.dry_run:
        print(f"dry_run=1 scenario={args.scenario} duration={duration} server_dir={args.server_dir}")
        print(f"description={scenario['description']}")
        return 0
    args.log_dir.mkdir(parents=True, exist_ok=True)
    log_path = args.log_dir / f"{run_label}.log"

    with connect(args.db) as conn:
        init_db(conn)
        sid = server_instance_id(conn, args.server_key)
        release_id = active_release_id(args.db, args.server_key, args.release_pointer)
        run_id = insert_run(
            conn,
            server_id=sid,
            release_id=release_id,
            run_label=run_label,
            scenario=args.scenario,
            status="running",
            log_path=log_path,
            notes=scenario["description"],
        )

    temp_world: Path | None = None
    backup: Path | None = None
    process: subprocess.Popen[str] | None = None
    samples: list[dict[str, float]] = []
    status = "failed"
    notes = ""
    try:
        if scenario.get("temporary_world"):
            temp_world, backup = configure_temporary_world(args.server_dir, run_label)
            if args.clean_world and temp_world.exists():
                shutil.rmtree(temp_world)
        with log_path.open("w", encoding="utf-8") as log_handle:
            process = subprocess.Popen(
                command_path(args.server_dir),
                cwd=args.server_dir,
                stdin=subprocess.PIPE,
                stdout=log_handle,
                stderr=subprocess.STDOUT,
                text=True,
            )
            if not wait_for_done(log_path, args.boot_timeout):
                notes = "Server did not reach Done before timeout."
                return_code = process.poll()
                if return_code is not None:
                    notes += f" Process exited with {return_code}."
                raise RuntimeError(notes)
            for command in scenario.get("commands") or []:
                if process.stdin:
                    process.stdin.write(command + "\n")
                    process.stdin.flush()
                time.sleep(2)
            pid = metrics.find_minecraft_pid(args.server_dir)
            process_state: dict[str, Any] = {}
            start = time.monotonic()
            while time.monotonic() - start < duration:
                sample_row, process_state = sample(args.server_dir, pid, start, process_state)
                samples.append(sample_row)
                time.sleep(args.sample_interval)
            status = "ok"
            notes = "Scenario completed."
    except Exception as exc:
        status = "failed"
        notes = str(exc)
    finally:
        if process is not None:
            stop_server(process)
        restore_server_properties(args.server_dir, backup)
        with connect(args.db) as conn:
            init_db(conn)
            finish_run(conn, run_id, samples, status, notes)
        if temp_world and args.remove_lab_world and temp_world.exists():
            shutil.rmtree(temp_world)
    print(f"run_label={run_label}")
    print(f"status={status}")
    print(f"log_path={log_path}")
    return 0 if status == "ok" else 1


def list_scenarios() -> int:
    for name, data in SCENARIOS.items():
        print(f"{name}\t{data['duration']}s\t{data['description']}")
    return 0


def init_database(db_path: Path) -> int:
    with connect(db_path) as conn:
        init_db(conn)
    print("schema=ok")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", type=Path, default=DEFAULT_DB)
    parser.add_argument("--server-dir", type=Path, default=DEFAULT_SERVER_DIR)
    parser.add_argument("--server-key", default=DEFAULT_SERVER_KEY)
    parser.add_argument("--log-dir", type=Path, default=DEFAULT_LOG_DIR)
    parser.add_argument("--release-pointer", type=Path, default=DEFAULT_RELEASE_POINTER)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("init")
    sub.add_parser("scenarios")
    run = sub.add_parser("run")
    run.add_argument("scenario", choices=sorted(SCENARIOS))
    run.add_argument("--run-label")
    run.add_argument("--duration", type=int)
    run.add_argument("--sample-interval", type=int, default=10)
    run.add_argument("--boot-timeout", type=int, default=240)
    run.add_argument("--clean-world", action="store_true")
    run.add_argument("--remove-lab-world", action="store_true")
    run.add_argument("--dry-run", action="store_true")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.command == "init":
        return init_database(args.db)
    if args.command == "scenarios":
        return list_scenarios()
    if args.command == "run":
        return run_scenario(args)
    raise SystemExit(f"unknown command {args.command}")


if __name__ == "__main__":
    raise SystemExit(main())
