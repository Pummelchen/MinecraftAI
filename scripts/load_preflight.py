#!/usr/bin/env python3
"""Network and release preflight checks before larger player sessions."""

from __future__ import annotations

import argparse
import concurrent.futures
import datetime as dt
import json
import socket
import sys
import time
import urllib.request
from pathlib import Path
from typing import Any, Sequence

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import minecraft_metrics_exporter as metrics


DEFAULT_HOST = "91.99.176.243"
DEFAULT_PORT = 25565


def read_release_pointer(location: str) -> dict[str, Any]:
    if not location:
        return {}
    if location.startswith(("http://", "https://")):
        with urllib.request.urlopen(location, timeout=5) as response:
            return json.loads(response.read().decode("utf-8"))
    path = Path(location)
    return json.loads(path.read_text(encoding="utf-8"))


def validate_release_pointer(payload: dict[str, Any]) -> list[str]:
    if not payload:
        return []
    required = ("release_id", "manifest_url", "client_zip_url", "client_zip_sha256")
    problems = [f"missing release pointer field: {key}" for key in required if not str(payload.get(key) or "").strip()]
    sha = str(payload.get("client_zip_sha256") or "")
    if sha and (len(sha) != 64 or any(char not in "0123456789abcdefABCDEF" for char in sha)):
        problems.append("client_zip_sha256 is not a SHA256 hex digest")
    return problems


def tcp_connect(host: str, port: int, timeout: float) -> float:
    start = time.perf_counter()
    with socket.create_connection((host, port), timeout=timeout):
        return time.perf_counter() - start


def status_ping(host: str, port: int, timeout: float) -> tuple[bool, float, str]:
    start = time.perf_counter()
    try:
        status = metrics.minecraft_status(host, port, timeout=timeout)
        elapsed = time.perf_counter() - start
        version = ((status.get("version") or {}).get("name") or "unknown")
        players = status.get("players") or {}
        return True, elapsed, f"{version} players={players.get('online', 0)}/{players.get('max', 0)}"
    except Exception as exc:
        elapsed = time.perf_counter() - start
        return False, elapsed, str(exc)


def run_status_burst(host: str, port: int, clients: int, timeout: float) -> dict[str, Any]:
    if clients <= 0:
        return {
            "attempts": 0,
            "success": 0,
            "failed": 0,
            "latency_min_ms": 0.0,
            "latency_avg_ms": 0.0,
            "latency_max_ms": 0.0,
            "sample": "",
        }
    results: list[tuple[bool, float, str]] = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=clients) as executor:
        futures = [executor.submit(status_ping, host, port, timeout) for _ in range(clients)]
        for future in concurrent.futures.as_completed(futures):
            results.append(future.result())
    latencies = [elapsed * 1000 for _ok, elapsed, _detail in results]
    success = sum(1 for ok, _elapsed, _detail in results if ok)
    sample = next((detail for ok, _elapsed, detail in results if ok), results[0][2] if results else "")
    return {
        "attempts": len(results),
        "success": success,
        "failed": len(results) - success,
        "latency_min_ms": round(min(latencies), 2) if latencies else 0.0,
        "latency_avg_ms": round(sum(latencies) / len(latencies), 2) if latencies else 0.0,
        "latency_max_ms": round(max(latencies), 2) if latencies else 0.0,
        "sample": sample[:300],
    }


def run_preflight(args: argparse.Namespace) -> int:
    release_payload = read_release_pointer(args.current_release_json) if args.current_release_json else {}
    problems = validate_release_pointer(release_payload)
    if args.dry_run:
        print(f"dry_run=1 host={args.host} port={args.port} status_clients={args.status_clients}")
        if release_payload:
            print(f"release_id={release_payload.get('release_id', '')}")
        if problems:
            print("release_pointer=invalid")
            for problem in problems:
                print(f"ERROR {problem}")
            return 2
        print("release_pointer=ok")
        return 0

    started = dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")
    tcp_latency = -1.0
    tcp_error = ""
    try:
        tcp_latency = tcp_connect(args.host, args.port, args.timeout) * 1000
    except Exception as exc:
        tcp_error = str(exc)

    burst = run_status_burst(args.host, args.port, args.status_clients, args.timeout)
    payload = {
        "started_at": started,
        "host": args.host,
        "port": args.port,
        "tcp_ok": tcp_error == "",
        "tcp_latency_ms": round(tcp_latency, 2) if tcp_latency >= 0 else -1,
        "tcp_error": tcp_error[:300],
        "status_burst": burst,
        "release_pointer": {
            "checked": bool(release_payload),
            "release_id": release_payload.get("release_id", "") if release_payload else "",
            "problems": problems,
        },
    }
    if args.json:
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        print(f"tcp_ok={int(payload['tcp_ok'])} latency_ms={payload['tcp_latency_ms']}")
        print(
            "status_attempts={attempts} status_success={success} status_failed={failed} "
            "latency_avg_ms={latency_avg_ms}".format(**burst)
        )
        if release_payload:
            print(f"release_id={payload['release_pointer']['release_id']}")
            print(f"release_pointer={'ok' if not problems else 'invalid'}")
            for problem in problems:
                print(f"ERROR {problem}")
    return 0 if payload["tcp_ok"] and burst["failed"] == 0 and not problems else 1


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default=DEFAULT_HOST)
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--timeout", type=float, default=2.0)
    parser.add_argument("--status-clients", type=int, default=10)
    parser.add_argument("--current-release-json", default="")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    return run_preflight(build_parser().parse_args(argv))


if __name__ == "__main__":
    raise SystemExit(main())
