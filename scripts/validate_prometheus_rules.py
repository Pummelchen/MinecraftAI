#!/usr/bin/env python3
"""Small stdlib validation for project-owned Prometheus alert rule files."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


ALERT_RE = re.compile(r"^\s*-\s+alert:\s*(\S+)\s*$")
KEY_RE = re.compile(r"^\s*(expr|for|labels|annotations|summary|description):")


def validate_file(path: Path) -> list[str]:
    problems: list[str] = []
    text = path.read_text(encoding="utf-8")
    if "groups:" not in text:
        problems.append(f"{path}: missing groups")
    alerts: list[tuple[str, set[str]]] = []
    current_name = ""
    current_keys: set[str] = set()
    for line in text.splitlines():
        alert = ALERT_RE.match(line)
        if alert:
            if current_name:
                alerts.append((current_name, current_keys))
            current_name = alert.group(1)
            current_keys = set()
            continue
        if current_name:
            key = KEY_RE.match(line)
            if key:
                current_keys.add(key.group(1))
    if current_name:
        alerts.append((current_name, current_keys))
    if not alerts:
        problems.append(f"{path}: no alerts found")
    seen: set[str] = set()
    for name, keys in alerts:
        if name in seen:
            problems.append(f"{path}: duplicate alert {name}")
        seen.add(name)
        required = {"expr", "for", "labels", "annotations", "summary", "description"}
        missing = sorted(required - keys)
        if missing:
            problems.append(f"{path}: alert {name} missing {', '.join(missing)}")
    return problems


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="+", type=Path)
    args = parser.parse_args(argv)
    problems: list[str] = []
    for path in args.paths:
        problems.extend(validate_file(path))
    if problems:
        for problem in problems:
            print(f"ERROR {problem}", file=sys.stderr)
        return 1
    print(f"prometheus_rules=ok count={len(args.paths)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
