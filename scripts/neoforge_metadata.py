#!/usr/bin/env python3
"""Small NeoForge metadata TOML loader with a Python 3.9-safe fallback."""

from __future__ import annotations

from typing import Any

try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover - Python 3.10 fallback.
    try:
        import tomli as tomllib  # type: ignore[no-redef]
    except ModuleNotFoundError:
        tomllib = None  # type: ignore[assignment]


def strip_toml_comment(line: str) -> str:
    in_single = False
    in_double = False
    escaped = False
    for index, char in enumerate(line):
        if char == "\\" and in_double and not escaped:
            escaped = True
            continue
        if char == '"' and not in_single and not escaped:
            in_double = not in_double
        elif char == "'" and not in_double:
            in_single = not in_single
        elif char == "#" and not in_single and not in_double:
            return line[:index]
        escaped = False
    return line


def parse_simple_toml_value(value: str) -> Any:
    value = value.strip()
    if value.lower() == "true":
        return True
    if value.lower() == "false":
        return False
    if len(value) >= 2 and value[0] == value[-1] and value[0] in {'"', "'"}:
        return value[1:-1]
    return value


def parse_neoforge_metadata_fallback(text: str) -> dict[str, Any]:
    """Parse the NeoForge metadata fields needed for mod/dependency planning.

    This is not a general TOML parser. It intentionally covers the common
    `[[mods]]` and `[[dependencies.<modid>]]` tables used by NeoForge metadata so
    maintenance scripts can still run on Python 3.9 hosts without `tomli`.
    """

    data: dict[str, Any] = {"mods": [], "dependencies": {}}
    current: dict[str, Any] | None = None
    for raw_line in text.splitlines():
        line = strip_toml_comment(raw_line).strip()
        if not line:
            continue
        if line.startswith("[[") and line.endswith("]]"):
            table = line[2:-2].strip()
            if table == "mods":
                current = {}
                data["mods"].append(current)
            elif table.startswith("dependencies."):
                owner = table.split(".", 1)[1].strip().strip('"')
                current = {}
                data["dependencies"].setdefault(owner, []).append(current)
            else:
                current = None
            continue
        if current is None or "=" not in line:
            continue
        key, value = line.split("=", 1)
        current[key.strip().strip('"')] = parse_simple_toml_value(value)
    return data


def load_neoforge_metadata(payload: bytes) -> dict[str, Any]:
    text = payload.decode("utf-8", errors="replace")
    if tomllib is not None:
        return tomllib.loads(text)
    return parse_neoforge_metadata_fallback(text)
