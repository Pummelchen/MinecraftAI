#!/usr/bin/env python3
"""Prometheus exporter for the Pummelchen Minecraft server."""

from __future__ import annotations

import argparse
import datetime as dt
import http.server
import json
import os
import re
import socket
import sqlite3
import struct
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Iterable, Sequence

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

DEFAULT_DB = Path("/var/minecraft_mods/data/minecraft_mods.sqlite")
DEFAULT_SERVER_DIR = Path("/var/minecraft_26.1.2")
DEFAULT_STATE = Path("/var/minecraft_mods/site/minecraft-metrics-state.json")
DEFAULT_RELEASE_POINTER = Path("/var/minecraft_mods/site/public/downloads/current-release.json")
DEFAULT_HOST = "127.0.0.1"
DEFAULT_MINECRAFT_PORT = 25565
DEFAULT_EXPORTER_PORT = 7792
DEFAULT_RCON_HOST = "127.0.0.1"
ERROR_RE = re.compile(r"\b(ERROR|FATAL)\b|Exception|Crash report|Failed to start", re.IGNORECASE)
TPS_RE = re.compile(r"\bTPS\b[^0-9]*(\d+(?:\.\d+)?)", re.IGNORECASE)
MSPT_RE = re.compile(r"\bMSPT\b[^0-9]*(\d+(?:\.\d+)?)", re.IGNORECASE)
MC_COLOR_RE = re.compile(r"§.")
FLOAT_RE = re.compile(r"\d+(?:\.\d+)?")
RCON_AUTH = 3
RCON_COMMAND = 2


def utc_now() -> dt.datetime:
    return dt.datetime.now(dt.UTC).replace(microsecond=0)


def read_json(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {}


def write_json_atomic(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    tmp.replace(path)


def encode_varint(value: int) -> bytes:
    result = bytearray()
    value &= 0xFFFFFFFF
    while True:
        temp = value & 0x7F
        value >>= 7
        if value:
            temp |= 0x80
        result.append(temp)
        if not value:
            return bytes(result)


def read_exact(sock: socket.socket, length: int) -> bytes:
    chunks = bytearray()
    while len(chunks) < length:
        chunk = sock.recv(length - len(chunks))
        if not chunk:
            raise OSError("socket closed")
        chunks.extend(chunk)
    return bytes(chunks)


def read_varint(sock: socket.socket) -> int:
    value = 0
    for index in range(5):
        byte = sock.recv(1)
        if not byte:
            raise OSError("socket closed while reading varint")
        current = byte[0]
        value |= (current & 0x7F) << (7 * index)
        if not current & 0x80:
            return value
    raise OSError("varint too long")


def minecraft_status(host: str, port: int, timeout: float = 1.5) -> dict[str, Any]:
    server_host = host.encode("utf-8")
    handshake = (
        encode_varint(0)
        + encode_varint(0)
        + encode_varint(len(server_host))
        + server_host
        + struct.pack(">H", port)
        + encode_varint(1)
    )
    request = encode_varint(1) + encode_varint(0)
    with socket.create_connection((host, port), timeout=timeout) as sock:
        sock.settimeout(timeout)
        sock.sendall(encode_varint(len(handshake)) + handshake)
        sock.sendall(request)
        packet_length = read_varint(sock)
        payload = read_exact(sock, packet_length)
    offset = 0
    packet_id, read = decode_varint_from_bytes(payload, offset)
    offset += read
    if packet_id != 0:
        raise OSError(f"unexpected status packet id {packet_id}")
    json_length, read = decode_varint_from_bytes(payload, offset)
    offset += read
    return json.loads(payload[offset : offset + json_length].decode("utf-8"))


def read_properties(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.exists():
        return values
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip()
    return values


def rcon_settings(server_dir: Path, password_file: Path | None, explicit_port: int | None) -> tuple[int, str] | None:
    password = ""
    if password_file and password_file.exists():
        password = password_file.read_text(encoding="utf-8", errors="replace").strip()
    properties = read_properties(server_dir / "server.properties")
    if not password:
        if properties.get("enable-rcon", "false").lower() != "true":
            return None
        password = properties.get("rcon.password", "").strip()
    if not password:
        return None
    try:
        port = explicit_port or int(properties.get("rcon.port") or "25575")
    except ValueError:
        port = explicit_port or 25575
    return port, password


def rcon_packet(request_id: int, packet_type: int, payload: str) -> bytes:
    body = struct.pack("<ii", request_id, packet_type) + payload.encode("utf-8") + b"\x00\x00"
    return struct.pack("<i", len(body)) + body


def read_rcon_packet(sock: socket.socket) -> tuple[int, int, str]:
    header = read_exact(sock, 4)
    (length,) = struct.unpack("<i", header)
    if length < 10 or length > 1_048_576:
        raise OSError(f"invalid RCON packet length {length}")
    body = read_exact(sock, length)
    request_id, packet_type = struct.unpack("<ii", body[:8])
    payload = body[8:-2].decode("utf-8", errors="replace")
    return request_id, packet_type, payload


def rcon_command(host: str, port: int, password: str, command: str, timeout: float) -> str:
    with socket.create_connection((host, port), timeout=timeout) as sock:
        sock.settimeout(timeout)
        sock.sendall(rcon_packet(1, RCON_AUTH, password))
        auth_id, _auth_type, _auth_payload = read_rcon_packet(sock)
        if auth_id == -1:
            raise PermissionError("RCON authentication failed")
        sock.sendall(rcon_packet(2, RCON_COMMAND, command))
        response_id, _response_type, response = read_rcon_packet(sock)
        if response_id != 2:
            raise OSError("unexpected RCON response id")
        return response


def first_metric_value(output: str, label: str) -> float | None:
    compact = MC_COLOR_RE.sub("", output)
    for raw_line in compact.splitlines():
        line = " ".join(raw_line.split())
        label_index = line.lower().find(label.lower())
        if label_index < 0:
            continue
        labeled_segment = line[label_index:]
        _head, separator, tail = labeled_segment.partition(":")
        search_area = tail if separator else labeled_segment
        match = FLOAT_RE.search(search_area)
        if match:
            return float(match.group(0))
    return None


def parse_spark_tps(output: str) -> dict[str, float]:
    values = {"spark_tps": -1.0, "spark_mspt": -1.0}
    tps = first_metric_value(output, "TPS")
    if tps is not None:
        values["spark_tps"] = min(max(tps, 0.0), 20.0)
    mspt = first_metric_value(output, "MSPT")
    if mspt is not None:
        values["spark_mspt"] = max(mspt, 0.0)
    return values


def spark_metrics(args: argparse.Namespace) -> dict[str, float]:
    values = {"rcon_up": 0.0, "spark_tps": -1.0, "spark_mspt": -1.0}
    settings = rcon_settings(args.server_dir, args.rcon_password_file, args.rcon_port)
    if not settings:
        return values
    port, password = settings
    try:
        output = rcon_command(args.rcon_host, port, password, args.spark_tps_command, args.rcon_timeout)
    except Exception:
        return values
    values["rcon_up"] = 1.0
    values.update(parse_spark_tps(output))
    return values


def decode_varint_from_bytes(data: bytes, offset: int) -> tuple[int, int]:
    value = 0
    for index in range(5):
        if offset + index >= len(data):
            raise OSError("short varint")
        current = data[offset + index]
        value |= (current & 0x7F) << (7 * index)
        if not current & 0x80:
            return value, index + 1
    raise OSError("varint too long")


def find_minecraft_pid(server_dir: Path) -> int | None:
    proc = Path("/proc")
    if not proc.exists():
        return None
    wanted = str(server_dir.resolve()) if server_dir.exists() else str(server_dir)
    candidates: list[tuple[int, int]] = []
    for path in proc.iterdir():
        if not path.name.isdigit():
            continue
        pid = int(path.name)
        try:
            cmdline = (path / "cmdline").read_bytes().replace(b"\x00", b" ").decode("utf-8", "replace")
            cwd = os.readlink(path / "cwd")
        except Exception:
            continue
        score = 0
        lower = cmdline.lower()
        if "java" not in lower:
            continue
        score += 1
        if "neoforge" in lower or "minecraft" in lower:
            score += 1
        if wanted in cwd or wanted in cmdline:
            score += 5
        if score >= 5:
            candidates.append((score, pid))
    if not candidates:
        return None
    return sorted(candidates, reverse=True)[0][1]


def read_proc_stat(pid: int) -> dict[str, float]:
    stat = Path(f"/proc/{pid}/stat").read_text(encoding="utf-8", errors="replace")
    close = stat.rfind(")")
    parts = stat[close + 2 :].split()
    ticks = os.sysconf(os.sysconf_names.get("SC_CLK_TCK", "SC_CLK_TCK"))
    page_size = os.sysconf(os.sysconf_names.get("SC_PAGE_SIZE", "SC_PAGE_SIZE"))
    utime = int(parts[11])
    stime = int(parts[12])
    rss_pages = int(parts[21])
    cpu_seconds = (utime + stime) / ticks
    return {
        "cpu_seconds": cpu_seconds,
        "rss_bytes": rss_pages * page_size,
    }


def read_proc_io(pid: int) -> dict[str, float]:
    path = Path(f"/proc/{pid}/io")
    values = {"read_bytes": 0.0, "write_bytes": 0.0}
    if not path.exists():
        return values
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if line.startswith("read_bytes:"):
            values["read_bytes"] = float(line.split()[1])
        elif line.startswith("write_bytes:"):
            values["write_bytes"] = float(line.split()[1])
    return values


def process_metrics(pid: int | None, state: dict[str, Any], now: float) -> tuple[dict[str, float], dict[str, Any]]:
    metrics = {
        "java_process_up": 0.0,
        "process_rss_bytes": 0.0,
        "process_cpu_percent": 0.0,
        "process_read_bytes": 0.0,
        "process_write_bytes": 0.0,
    }
    if pid is None:
        return metrics, {"pid": None, "sampled_at": now}
    try:
        stat = read_proc_stat(pid)
        io = read_proc_io(pid)
    except Exception:
        return metrics, {"pid": None, "sampled_at": now}

    previous = state.get("process") or {}
    cpu_percent = 0.0
    if previous.get("pid") == pid and previous.get("sampled_at") and previous.get("cpu_seconds") is not None:
        elapsed = max(now - float(previous["sampled_at"]), 0.001)
        cpu_delta = max(float(stat["cpu_seconds"]) - float(previous["cpu_seconds"]), 0.0)
        cpu_percent = (cpu_delta / elapsed) * 100.0 / max(os.cpu_count() or 1, 1)

    metrics.update(
        {
            "java_process_up": 1.0,
            "process_rss_bytes": float(stat["rss_bytes"]),
            "process_cpu_percent": max(0.0, cpu_percent),
            "process_read_bytes": io["read_bytes"],
            "process_write_bytes": io["write_bytes"],
        }
    )
    next_state = {
        "pid": pid,
        "sampled_at": now,
        "cpu_seconds": stat["cpu_seconds"],
    }
    return metrics, next_state


def heap_metrics(pid: int | None) -> dict[str, float]:
    values = {"heap_used_bytes": -1.0, "heap_committed_bytes": -1.0}
    if pid is None:
        return values
    try:
        output = subprocess.check_output(
            ["jcmd", str(pid), "GC.heap_info"],
            text=True,
            stderr=subprocess.STDOUT,
            timeout=4,
        )
    except Exception:
        return values
    match = re.search(r"heap\s+total\s+(\d+)K,\s+used\s+(\d+)K", output, re.IGNORECASE)
    if match:
        values["heap_committed_bytes"] = float(match.group(1)) * 1024
        values["heap_used_bytes"] = float(match.group(2)) * 1024
    return values


def count_region_files(server_dir: Path) -> int:
    world = server_dir / "world"
    if not world.exists():
        return 0
    return sum(1 for _ in world.rglob("region/*.mca"))


def latest_log_metrics(server_dir: Path) -> dict[str, float]:
    path = server_dir / "logs" / "latest.log"
    metrics = {"log_errors_total": 0.0, "latest_tps": -1.0, "latest_mspt": -1.0}
    if not path.exists():
        return metrics
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()[-2000:]
    except Exception:
        return metrics
    for line in lines:
        if ERROR_RE.search(line):
            metrics["log_errors_total"] += 1
        tps = TPS_RE.search(line)
        mspt = MSPT_RE.search(line)
        if tps:
            metrics["latest_tps"] = float(tps.group(1))
        if mspt:
            metrics["latest_mspt"] = float(mspt.group(1))
    return metrics


def crash_metrics(server_dir: Path) -> dict[str, float]:
    crash_dir = server_dir / "crash-reports"
    if not crash_dir.exists():
        return {"crash_reports_total": 0.0, "latest_crash_timestamp_seconds": 0.0}
    reports = [path for path in crash_dir.glob("*.txt") if path.is_file()]
    latest = max((path.stat().st_mtime for path in reports), default=0.0)
    return {"crash_reports_total": float(len(reports)), "latest_crash_timestamp_seconds": float(latest)}


def tcp_connection_count(port: int) -> int:
    needle = f":{port:04X}"
    count = 0
    for table in (Path("/proc/net/tcp"), Path("/proc/net/tcp6")):
        if not table.exists():
            continue
        for line in table.read_text(encoding="utf-8", errors="replace").splitlines()[1:]:
            parts = line.split()
            if len(parts) < 4:
                continue
            local_address = parts[1]
            state = parts[3]
            if local_address.endswith(needle) and state == "01":
                count += 1
    return count


def update_metrics(db_path: Path) -> dict[str, float]:
    values = {
        "mod_updates_success_total": 0.0,
        "mod_updates_failed_total": 0.0,
        "mod_updates_latest_timestamp_seconds": 0.0,
    }
    if not db_path.exists():
        return values
    try:
        with sqlite3.connect(db_path) as conn:
            conn.row_factory = sqlite3.Row
            if not table_exists(conn, "update_events"):
                return values
            row = conn.execute(
                """
                SELECT
                    SUM(CASE WHEN status IN ('applied', 'ok') THEN 1 ELSE 0 END) AS success_count,
                    SUM(CASE WHEN status NOT IN ('applied', 'ok', 'skipped') THEN 1 ELSE 0 END) AS failed_count,
                    MAX(tested_at) AS latest_tested
                FROM update_events
                """
            ).fetchone()
            if row:
                values["mod_updates_success_total"] = float(row["success_count"] or 0)
                values["mod_updates_failed_total"] = float(row["failed_count"] or 0)
                latest = row["latest_tested"] or ""
                if latest:
                    values["mod_updates_latest_timestamp_seconds"] = dt.datetime.fromisoformat(latest).timestamp()
    except Exception:
        return values
    return values


def table_exists(conn: sqlite3.Connection, name: str) -> bool:
    row = conn.execute(
        "SELECT 1 FROM sqlite_master WHERE type IN ('table', 'view') AND name = ?",
        (name,),
    ).fetchone()
    return bool(row)


def active_release(db_path: Path, server_key: str) -> dict[str, str]:
    if not db_path.exists():
        return {}
    try:
        with sqlite3.connect(db_path) as conn:
            conn.row_factory = sqlite3.Row
            if not table_exists(conn, "pack_releases"):
                return {}
            row = conn.execute(
                """
                SELECT release_id, status, minecraft_version, loader_version
                FROM pack_releases
                WHERE server_key = ? AND active = 1
                ORDER BY activated_at DESC
                LIMIT 1
                """,
                (server_key,),
            ).fetchone()
            return dict(row) if row else {}
    except Exception:
        return {}


def release_pointer_metrics(path: Path, active_release_id: str, now: float) -> dict[str, float]:
    values = {
        "release_pointer_present": 0.0,
        "release_pointer_age_seconds": -1.0,
        "release_pointer_matches_active": 0.0,
    }
    try:
        stat = path.stat()
    except OSError:
        values["release_pointer_matches_active"] = 1.0 if not active_release_id else 0.0
        return values
    values["release_pointer_present"] = 1.0
    values["release_pointer_age_seconds"] = max(now - stat.st_mtime, 0.0)
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return values
    pointer_release_id = str(payload.get("release_id") or "")
    values["release_pointer_matches_active"] = 1.0 if pointer_release_id == active_release_id else 0.0
    return values


def region_rate(region_files: int, state: dict[str, Any], now: float) -> tuple[float, dict[str, Any]]:
    previous = state.get("regions") or {}
    rate = 0.0
    if previous.get("sampled_at") and previous.get("region_files") is not None:
        elapsed = max(now - float(previous["sampled_at"]), 0.001)
        rate = max(region_files - int(previous["region_files"]), 0) / elapsed
    return rate, {"sampled_at": now, "region_files": region_files}


def build_metrics(args: argparse.Namespace) -> tuple[str, dict[str, Any]]:
    now = time.time()
    state = read_json(args.state)
    pid = find_minecraft_pid(args.server_dir)
    proc_metrics, proc_state = process_metrics(pid, state, now)
    heap = heap_metrics(pid)
    regions = count_region_files(args.server_dir)
    region_files_rate, region_state = region_rate(regions, state, now)
    log_values = latest_log_metrics(args.server_dir)
    spark_values = spark_metrics(args)
    crash_values = crash_metrics(args.server_dir)
    update_values = update_metrics(args.db)
    effective_tps = spark_values["spark_tps"] if spark_values["spark_tps"] >= 0 else log_values["latest_tps"]
    effective_mspt = spark_values["spark_mspt"] if spark_values["spark_mspt"] >= 0 else log_values["latest_mspt"]

    server_up = 0.0
    players_online = 0.0
    players_max = 0.0
    try:
        status = minecraft_status(args.minecraft_host, args.minecraft_port)
        server_up = 1.0
        players = status.get("players") or {}
        players_online = float(players.get("online") or 0)
        players_max = float(players.get("max") or 0)
    except Exception:
        pass

    release = active_release(args.db, args.server_key)
    label_release = release.get("release_id", "")
    label_status = release.get("status", "")
    release_pointer = release_pointer_metrics(args.current_release_json, label_release, now)

    metrics: list[tuple[str, float, str]] = [
        ("pummelchen_minecraft_up", server_up, "Minecraft server-list ping status."),
        ("pummelchen_minecraft_players_online", players_online, "Online player count from Minecraft status ping."),
        ("pummelchen_minecraft_players_max", players_max, "Configured max player count from Minecraft status ping."),
        ("pummelchen_minecraft_java_process_up", proc_metrics["java_process_up"], "Whether the Java process for this server directory is visible."),
        ("pummelchen_minecraft_process_rss_bytes", proc_metrics["process_rss_bytes"], "Resident memory for the Minecraft Java process."),
        ("pummelchen_minecraft_process_cpu_percent", proc_metrics["process_cpu_percent"], "Minecraft process CPU percent since previous scrape, normalized by host cores."),
        ("pummelchen_minecraft_process_read_bytes", proc_metrics["process_read_bytes"], "Minecraft process read bytes from /proc/pid/io."),
        ("pummelchen_minecraft_process_write_bytes", proc_metrics["process_write_bytes"], "Minecraft process write bytes from /proc/pid/io."),
        ("pummelchen_minecraft_heap_used_bytes", heap["heap_used_bytes"], "Best-effort JVM heap used bytes from jcmd, or -1 when unavailable."),
        ("pummelchen_minecraft_heap_committed_bytes", heap["heap_committed_bytes"], "Best-effort JVM committed heap bytes from jcmd, or -1 when unavailable."),
        ("pummelchen_minecraft_region_files_total", float(regions), "World region file count."),
        ("pummelchen_minecraft_region_file_rate", region_files_rate, "New region files per second since previous scrape."),
        ("pummelchen_minecraft_tcp_connections", float(tcp_connection_count(args.minecraft_port)), "Established TCP connections to the Minecraft port."),
        ("pummelchen_minecraft_log_errors_total", log_values["log_errors_total"], "Best-effort ERROR/FATAL/exception lines in the latest log tail."),
        ("pummelchen_minecraft_rcon_up", spark_values["rcon_up"], "Whether optional local RCON metrics collection succeeded."),
        ("pummelchen_minecraft_spark_tps", spark_values["spark_tps"], "Latest TPS from Spark over local RCON, or -1 when unavailable."),
        ("pummelchen_minecraft_spark_mspt", spark_values["spark_mspt"], "Latest MSPT from Spark over local RCON, or -1 when unavailable."),
        ("pummelchen_minecraft_tps", effective_tps, "Latest TPS from Spark/RCON when available, else best-effort log parse, or -1."),
        ("pummelchen_minecraft_mspt", effective_mspt, "Latest MSPT from Spark/RCON when available, else best-effort log parse, or -1."),
        ("pummelchen_minecraft_crash_reports_total", crash_values["crash_reports_total"], "Crash report file count."),
        ("pummelchen_minecraft_latest_crash_timestamp_seconds", crash_values["latest_crash_timestamp_seconds"], "Newest crash report mtime as a Unix timestamp."),
        ("pummelchen_mod_updates_success_total", update_values["mod_updates_success_total"], "Successful mod update events recorded in SQLite."),
        ("pummelchen_mod_updates_failed_total", update_values["mod_updates_failed_total"], "Failed mod update events recorded in SQLite."),
        ("pummelchen_mod_updates_latest_timestamp_seconds", update_values["mod_updates_latest_timestamp_seconds"], "Newest update test timestamp from SQLite."),
        ("pummelchen_release_pointer_present", release_pointer["release_pointer_present"], "Whether current-release.json exists for client auto-update."),
        ("pummelchen_release_pointer_age_seconds", release_pointer["release_pointer_age_seconds"], "Age of current-release.json in seconds, or -1 when missing."),
        ("pummelchen_release_pointer_matches_active", release_pointer["release_pointer_matches_active"], "Whether current-release.json release_id matches the active SQLite release."),
    ]

    lines = [
        "# HELP pummelchen_exporter_build_info Exporter metadata.",
        "# TYPE pummelchen_exporter_build_info gauge",
        f'pummelchen_exporter_build_info{{server_key="{escape_label(args.server_key)}",release_id="{escape_label(label_release)}",status="{escape_label(label_status)}"}} 1',
    ]
    for name, value, help_text in metrics:
        lines.append(f"# HELP {name} {help_text}")
        lines.append(f"# TYPE {name} gauge")
        lines.append(f"{name} {float(value):.6f}")
    next_state = dict(state)
    next_state["process"] = proc_state
    next_state["regions"] = region_state
    next_state["updated_at"] = utc_now().isoformat()
    return "\n".join(lines) + "\n", next_state


def escape_label(value: str) -> str:
    return str(value).replace("\\", "\\\\").replace("\n", "\\n").replace('"', '\\"')


class MetricsHandler(http.server.BaseHTTPRequestHandler):
    args: argparse.Namespace

    def log_message(self, fmt: str, *args: Any) -> None:
        return

    def do_GET(self) -> None:
        if self.path == "/health":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.end_headers()
            self.wfile.write(b"ok\n")
            return
        if self.path.split("?", 1)[0] != "/metrics":
            self.send_response(404)
            self.end_headers()
            return
        try:
            body, state = build_metrics(self.args)
            write_json_atomic(self.args.state, state)
            payload = body.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
        except Exception as exc:
            payload = f"exporter_error {exc}\n".encode("utf-8", "replace")
            self.send_response(500)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", type=Path, default=DEFAULT_DB)
    parser.add_argument("--server-dir", type=Path, default=DEFAULT_SERVER_DIR)
    parser.add_argument("--server-key", default="minecraft_26_1_2")
    parser.add_argument("--state", type=Path, default=DEFAULT_STATE)
    parser.add_argument("--current-release-json", type=Path, default=DEFAULT_RELEASE_POINTER)
    parser.add_argument("--listen-host", default=DEFAULT_HOST)
    parser.add_argument("--listen-port", type=int, default=DEFAULT_EXPORTER_PORT)
    parser.add_argument("--minecraft-host", default=DEFAULT_HOST)
    parser.add_argument("--minecraft-port", type=int, default=DEFAULT_MINECRAFT_PORT)
    parser.add_argument("--rcon-host", default=DEFAULT_RCON_HOST)
    parser.add_argument("--rcon-port", type=int)
    parser.add_argument("--rcon-password-file", type=Path)
    parser.add_argument("--rcon-timeout", type=float, default=2.0)
    parser.add_argument("--spark-tps-command", default="spark tps")
    parser.add_argument("--once", action="store_true", help="Print one metrics payload and exit.")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.once:
        body, state = build_metrics(args)
        write_json_atomic(args.state, state)
        print(body, end="")
        return 0
    MetricsHandler.args = args
    server = http.server.ThreadingHTTPServer((args.listen_host, args.listen_port), MetricsHandler)
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
