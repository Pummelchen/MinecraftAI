#!/usr/bin/env python3
"""Write live system stats JSON for the Pummelchen status site."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import shutil
import sys
from pathlib import Path
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import minecraft_metrics_exporter as mc_metrics


DEFAULT_DB = Path("/var/minecraft_mods/data/minecraft_mods.sqlite")
DEFAULT_OUTPUT = Path("/var/minecraft_mods/site/public/live-stats.json")
DEFAULT_STATE = Path("/var/minecraft_mods/site/live-stats-history.json")
DEFAULT_SERVER = Path("/var/minecraft_26.1.2")
DEFAULT_HISTORY = 120
DEFAULT_SERVER_KEY = "minecraft_26_1_2"
CLIENT_ZIP_NAME = "minecraft_26.1.2_client_macos_apple_silicon.zip"


def normalize_interface_name(value: str | None) -> str | None:
    if not value:
        return None
    iface = value.strip()
    return iface if iface else None


def detect_default_interface() -> str | None:
    route_path = Path("/proc/net/route")
    if not route_path.exists():
        # Fallback to a best-effort local interface choice.
        pass
    else:
        default_metric: int | None = None
        default_iface: str | None = None
        for line in route_path.read_text(encoding="utf-8", errors="replace").splitlines():
            if line.startswith("Iface"):
                continue
            parts = line.split()
            if len(parts) < 3:
                continue
            iface, destination, flags = parts[0], parts[1], parts[3]
            if destination != "00000000":
                continue
            try:
                if int(flags, 16) & 0x0002 == 0:
                    continue
                metric = int(parts[6]) if len(parts) > 6 else 0
            except ValueError:
                continue
            if default_metric is None or metric < default_metric:
                default_metric = metric
                default_iface = iface
        if default_iface is not None:
            return default_iface
    # Fallback when /proc/net/route is unavailable or has no default route.
    dev_path = Path("/proc/net/dev")
    if not dev_path.exists():
        return None
    for line in dev_path.read_text(encoding="utf-8", errors="replace").splitlines():
        if ":" not in line:
            continue
        iface = line.split(":")[0].strip()
        if iface and iface != "lo":
            return iface
    return None


def interface_speed_mbps(interface: str | None) -> float:
    if not interface:
        return 1000.0
    speed_path = Path(f"/sys/class/net/{interface}/speed")
    if not speed_path.exists():
        return 1000.0
    try:
        speed = float(speed_path.read_text(encoding="utf-8", errors="replace").strip())
    except (OSError, ValueError):
        return 1000.0
    if speed <= 0:
        return 1000.0
    return speed


def read_net_bytes(interface: str | None) -> tuple[int, int] | None:
    if not interface:
        return None
    path = Path("/proc/net/dev")
    if not path.exists():
        return None
    needle = f"{interface}:"
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if not line.strip().startswith(needle):
            continue
        data = line.split(":")[-1].split()
        if len(data) < 10:
            return None
        try:
            rx_bytes = int(data[0])
            tx_bytes = int(data[8])
        except ValueError:
            return None
        return rx_bytes, tx_bytes
    return None


def human_bits_per_sec(bits_per_second: float) -> str:
    if bits_per_second < 0:
        return "0 bps"
    units = ["bps", "Kbps", "Mbps", "Gbps"]
    current = float(bits_per_second)
    for unit in units:
        if current < 1000:
            return f"{current:.1f} {unit}"
        current /= 1000
    return f"{current:.1f} Tbps"


def _human_speed_mbps(speed_mbps: float) -> str:
    if speed_mbps >= 1000:
        return f"{speed_mbps / 1000:.1f} Gbps"
    return f"{speed_mbps:.0f} Mbps"


def human_bytes(value: float) -> str:
    units = ["B", "KB", "MB", "GB", "TB"]
    size = float(value)
    for unit in units:
        if size < 1024 or unit == units[-1]:
            return f"{size:.1f} {unit}" if unit != "B" else f"{int(size)} B"
        size /= 1024
    return f"{size:.1f} TB"


def clamp_percent(value: float) -> float:
    return max(0.0, min(100.0, value))


def percent(value: float, total: float) -> str:
    if not total:
        return "0%"
    return f"{clamp_percent((value / total) * 100):.1f}%"


def parse_meminfo() -> dict[str, int]:
    path = Path("/proc/meminfo")
    if not path.exists():
        return {}
    values: dict[str, int] = {}
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        parts = line.split()
        if len(parts) >= 2:
            values[parts[0].rstrip(":")] = int(parts[1]) * 1024
    return values


def read_cpu_times() -> dict[str, int] | None:
    path = Path("/proc/stat")
    if not path.exists():
        return None
    parts = path.read_text(encoding="utf-8", errors="replace").splitlines()[0].split()
    if not parts or parts[0] != "cpu":
        return None
    values = [int(part) for part in parts[1:]]
    idle = values[3] + (values[4] if len(values) > 4 else 0)
    return {"total": sum(values), "idle": idle}


def cpu_usage_percent(previous: dict[str, int] | None, current: dict[str, int] | None) -> float:
    if not previous or not current:
        return 0.0
    total_delta = current["total"] - previous["total"]
    idle_delta = current["idle"] - previous["idle"]
    if total_delta <= 0:
        return 0.0
    return clamp_percent(((total_delta - idle_delta) / total_delta) * 100)


def normalize_history_sample(sample: dict[str, Any], disk_total_gb: float) -> dict[str, Any]:
    normalized = dict(sample)
    normalized.pop("load1_percent", None)
    for key in (
        "cpu_percent",
        "ram_used_percent",
        "disk_used_percent",
        "disk_free_percent",
        "network_traffic_percent",
    ):
        if key in normalized:
            try:
                normalized[key] = round(clamp_percent(float(normalized[key])), 2)
            except (TypeError, ValueError):
                normalized.pop(key, None)
    if "disk_free_percent" not in normalized and "disk_free_gb" in normalized and disk_total_gb > 0:
        try:
            free_percent = (float(normalized["disk_free_gb"]) / disk_total_gb) * 100
            normalized["disk_free_percent"] = round(clamp_percent(free_percent), 2)
        except (TypeError, ValueError):
            pass
    return normalized


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


def active_release_text(db_path: Path, server_key: str) -> str:
    release = mc_metrics.active_release(db_path, server_key)
    if not release:
        return "No active release"
    return display_release_version(release.get("release_id") or "")


def minecraft_live_values(server_dir: Path, db_path: Path, server_key: str) -> dict[str, str]:
    players = "Offline"
    try:
        status = mc_metrics.minecraft_status("127.0.0.1", 25565, timeout=1.0)
        player_data = status.get("players") or {}
        players = f"{int(player_data.get('online') or 0)} / {int(player_data.get('max') or 0)}"
    except Exception:
        pass
    return {
        "Last Mod Version": active_release_text(db_path, server_key),
        "Minecraft Players": players,
    }


def client_pack_live_values(server_dir: Path) -> dict[str, str]:
    zip_path = server_dir / CLIENT_ZIP_NAME
    sha_path = server_dir / f"{CLIENT_ZIP_NAME}.sha256"
    sha = ""
    if sha_path.exists():
        try:
            sha = sha_path.read_text(encoding="utf-8", errors="replace").split()[0]
        except (IndexError, OSError):
            sha = ""
    size_text = "Missing"
    try:
        if zip_path.exists():
            size_text = human_bytes(zip_path.stat().st_size)
    except OSError:
        size_text = "Missing"
    generated_text = "Missing"
    generated_iso = ""
    try:
        if zip_path.exists():
            mtime = dt.datetime.fromtimestamp(zip_path.stat().st_mtime, tz=dt.timezone.utc)
            generated_text = mtime.strftime("%Y-%m-%d %H:%M UTC")
            generated_iso = mtime.isoformat(timespec="seconds")
    except OSError:
        generated_text = "Missing"
        generated_iso = ""
    return {
        "Client Mod Pack": size_text,
        "Client Mod Pack SHA256": sha or "Missing",
        "Client Mod Pack Generated": generated_text,
        "Client Mod Pack Generated ISO": generated_iso,
    }


def build_payload(
    server_dir: Path,
    state: dict[str, Any],
    history_limit: int,
    db_path: Path,
    server_key: str,
) -> tuple[dict[str, Any], dict[str, Any]]:
    now = dt.datetime.now(dt.timezone.utc)
    current_cpu = read_cpu_times()
    cpu_percent = cpu_usage_percent(state.get("previous_cpu"), current_cpu)

    mem = parse_meminfo()
    mem_total = mem.get("MemTotal", 0)
    mem_available = mem.get("MemAvailable", 0)
    mem_used = max(mem_total - mem_available, 0)
    mem_used_percent = clamp_percent((mem_used / mem_total) * 100) if mem_total else 0.0

    disk = shutil.disk_usage(server_dir if server_dir.exists() else "/")
    disk_used_percent = clamp_percent((disk.used / disk.total) * 100) if disk.total else 0.0
    disk_free_percent = clamp_percent((disk.free / disk.total) * 100) if disk.total else 0.0
    disk_free_gb = disk.free / (1024 ** 3)
    disk_total_gb = disk.total / (1024 ** 3)

    interface = normalize_interface_name(state.get("net_interface")) or detect_default_interface()
    net_snapshot = read_net_bytes(interface)
    network_percent = 0.0
    network_text = "Missing"
    if interface and net_snapshot is not None:
        previous_net = state.get("previous_net")
        if isinstance(previous_net, dict) and previous_net.get("interface") == interface:
            prev_ts = float(previous_net.get("ts", 0.0) or 0.0)
            interval = now.timestamp() - prev_ts
            if interval > 0:
                try:
                    prev_rx = int(previous_net.get("rx_bytes", 0))
                    prev_tx = int(previous_net.get("tx_bytes", 0))
                    rx_bytes, tx_bytes = net_snapshot
                    speed_mbps = interface_speed_mbps(interface)
                    rx_delta = max(0, rx_bytes - prev_rx)
                    tx_delta = max(0, tx_bytes - prev_tx)
                    rx_bps = (rx_delta * 8) / interval
                    tx_bps = (tx_delta * 8) / interval
                    rx_pct = clamp_percent((rx_bps / 1_000_000.0 / speed_mbps) * 100) if speed_mbps > 0 else 0.0
                    tx_pct = clamp_percent((tx_bps / 1_000_000.0 / speed_mbps) * 100) if speed_mbps > 0 else 0.0
                    network_percent = round(max(rx_pct, tx_pct), 2)
                    speed_label = _human_speed_mbps(speed_mbps)
                    network_text = (
                        f"{human_bits_per_sec(rx_bps)} in / "
                        f"{human_bits_per_sec(tx_bps)} out "
                        f"({network_percent:.1f}% of {speed_label})"
                    )
                except (TypeError, ValueError):
                    network_text = "Unavailable"
        current_net = {
            "interface": interface,
            "ts": now.timestamp(),
            "rx_bytes": int(net_snapshot[0]),
            "tx_bytes": int(net_snapshot[1]),
        }
    else:
        network_text = "Unavailable"
        current_net = {}

    sample = {
        "t": now.isoformat(timespec="seconds"),
        "cpu_percent": round(cpu_percent, 2),
        "ram_used_percent": round(mem_used_percent, 2),
        "disk_used_percent": round(disk_used_percent, 2),
        "disk_free_gb": round(disk_free_gb, 2),
        "disk_free_percent": round(disk_free_percent, 2),
        "network_traffic_percent": network_percent,
    }
    history = [
        normalize_history_sample(item, disk_total_gb)
        for item in list(state.get("history") or [])
        if isinstance(item, dict)
    ]
    history.append(sample)
    history = history[-history_limit:]

    payload = {
        "generated_at": now.isoformat(timespec="seconds"),
        "interval_seconds": 10,
        "stats": {
            "Generated": now.strftime("%Y-%m-%d %H:%M UTC"),
            "CPU usage": f"{cpu_percent:.1f}%",
            "RAM used": f"{human_bytes(mem_used)} ({percent(mem_used, mem_total)})",
            "RAM available": human_bytes(mem_available),
            "Disk used/free": (
                f"{human_bytes(disk.used)} / {human_bytes(disk.total)} "
                f"({percent(disk.used, disk.total)}); {human_bytes(disk.free)} free"
            ),
            "Network traffic": network_text,
            **client_pack_live_values(server_dir),
            **minecraft_live_values(server_dir, db_path, server_key),
        },
        "metrics": sample,
        "history": history,
    }
    next_state = {
        "previous_cpu": current_cpu,
        "net_interface": interface or None,
        "previous_net": current_net,
        "history": history,
    }
    return payload, next_state


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", type=Path, default=DEFAULT_DB)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--state", type=Path, default=DEFAULT_STATE)
    parser.add_argument("--server-dir", type=Path, default=DEFAULT_SERVER)
    parser.add_argument("--server-key", default=DEFAULT_SERVER_KEY)
    parser.add_argument("--history-limit", type=int, default=DEFAULT_HISTORY)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    state = read_json(args.state)
    payload, next_state = build_payload(args.server_dir, state, max(2, args.history_limit), args.db, args.server_key)
    write_json_atomic(args.state, next_state)
    write_json_atomic(args.output, payload)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
