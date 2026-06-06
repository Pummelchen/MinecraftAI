#!/usr/bin/env python3
"""Validate NeoForge client mod dependencies from packaged jar metadata."""

from __future__ import annotations

import argparse
import io
import re
import sys
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Sequence

from neoforge_metadata import load_neoforge_metadata


SPECIAL_VERSIONS = {
    "minecraft": "26.1.2",
    "neoforge": "26.1.2.71",
}
CLIENT_SIDES = {"BOTH", "CLIENT"}


@dataclass(frozen=True)
class ModInfo:
    mod_id: str
    version: str
    source: str


@dataclass(frozen=True)
class Dependency:
    requester: str
    mod_id: str
    version_range: str
    side: str
    source: str


def version_parts(version: str) -> list[int | str]:
    parts: list[int | str] = []
    for token in re.findall(r"\d+|[A-Za-z]+", version):
        if token.isdigit():
            parts.append(int(token))
        else:
            parts.append(token.lower())
    return parts


def compare_versions(left: str, right: str) -> int:
    left_parts = version_parts(left)
    right_parts = version_parts(right)
    max_len = max(len(left_parts), len(right_parts))
    for index in range(max_len):
        a = left_parts[index] if index < len(left_parts) else 0
        b = right_parts[index] if index < len(right_parts) else 0
        if a == b:
            continue
        if isinstance(a, int) and isinstance(b, int):
            return -1 if a < b else 1
        if isinstance(a, int):
            return 1
        if isinstance(b, int):
            return -1
        return -1 if a < b else 1
    return 0


def satisfies_range(actual: str, version_range: str) -> bool:
    value = version_range.strip()
    if not value or value in {"*", "[,)", "(,)"}:
        return True
    if "${" in actual or "${" in value:
        return True
    if value.endswith(",") and not value.startswith(("[", "(")):
        value = f"[{value})"
    if "," not in value and not value.startswith(("[", "(")):
        return compare_versions(actual, value) >= 0
    if value.startswith("[") and value.endswith("]") and "," not in value:
        return actual == value[1:-1].strip()
    match = re.fullmatch(r"([\[(])\s*([^,\]\)]*)\s*,\s*([^\]\)]*)\s*([\])])", value)
    if not match:
        return actual == value
    lower_inclusive = match.group(1) == "["
    lower = match.group(2).strip()
    upper = match.group(3).strip()
    upper_inclusive = match.group(4) == "]"
    if lower:
        cmp = compare_versions(actual, lower)
        if cmp < 0 and actual.startswith(lower + "-"):
            cmp = 0
        if cmp < 0 or (cmp == 0 and not lower_inclusive):
            return False
    if upper:
        cmp = compare_versions(actual, upper)
        if cmp > 0 or (cmp == 0 and not upper_inclusive):
            return False
    return True


def metadata_from_archive(archive: zipfile.ZipFile) -> dict[str, Any] | None:
    for name in ("META-INF/neoforge.mods.toml", "META-INF/mods.toml"):
        try:
            return load_neoforge_metadata(archive.read(name))
        except KeyError:
            continue
    return None


def read_mods_toml(jar_path: Path) -> dict[str, Any] | None:
    try:
        with zipfile.ZipFile(jar_path) as archive:
            return metadata_from_archive(archive)
    except zipfile.BadZipFile as exc:
        raise ValueError(f"{jar_path.name}: not a valid jar: {exc}") from exc


def nested_jar_metadata(jar_path: Path) -> list[tuple[str, dict[str, Any]]]:
    rows: list[tuple[str, dict[str, Any]]] = []
    try:
        with zipfile.ZipFile(jar_path) as archive:
            for name in sorted(archive.namelist()):
                if not name.endswith(".jar"):
                    continue
                try:
                    with zipfile.ZipFile(io.BytesIO(archive.read(name))) as nested:
                        metadata = metadata_from_archive(nested)
                except (KeyError, zipfile.BadZipFile):
                    continue
                if metadata:
                    rows.append((f"{jar_path.name}!{name}", metadata))
    except zipfile.BadZipFile:
        return rows
    return rows


def add_metadata(
    metadata: dict[str, Any],
    source: str,
    mods: dict[str, ModInfo],
    dependencies: list[Dependency],
) -> None:
    for mod in metadata.get("mods") or []:
        mod_id = str(mod.get("modId") or "").strip()
        if not mod_id:
            continue
        mods[mod_id] = ModInfo(mod_id=mod_id, version=str(mod.get("version") or ""), source=source)
    dependency_groups = metadata.get("dependencies") or {}
    for requester, rows in dependency_groups.items():
        for row in rows or []:
            dependency_type = str(row.get("type") or "").lower()
            mandatory = bool(row.get("mandatory", False))
            if dependency_type and dependency_type != "required":
                continue
            if not dependency_type and not mandatory:
                continue
            side = str(row.get("side") or "BOTH").upper()
            if side not in CLIENT_SIDES:
                continue
            dep_id = str(row.get("modId") or "").strip()
            if not dep_id:
                continue
            dependencies.append(
                Dependency(
                    requester=str(requester),
                    mod_id=dep_id,
                    version_range=str(row.get("versionRange") or ""),
                    side=side,
                    source=source,
                )
            )


def collect_metadata(mods_dir: Path) -> tuple[dict[str, ModInfo], list[Dependency], list[str]]:
    mods: dict[str, ModInfo] = {}
    dependencies: list[Dependency] = []
    warnings: list[str] = []
    for jar_path in sorted(mods_dir.glob("*.jar"), key=lambda item: item.name.lower()):
        try:
            metadata = read_mods_toml(jar_path)
        except Exception as exc:
            warnings.append(str(exc))
            continue
        if not metadata:
            continue
        add_metadata(metadata, jar_path.name, mods, dependencies)
        for source, nested_metadata in nested_jar_metadata(jar_path):
            add_metadata(nested_metadata, source, mods, dependencies)
    return mods, dependencies, warnings


def validate_dependencies(mods_dir: Path, special_versions: dict[str, str]) -> list[str]:
    mods, dependencies, warnings = collect_metadata(mods_dir)
    problems = list(warnings)
    for dependency in dependencies:
        actual = special_versions.get(dependency.mod_id)
        source = dependency.source
        if actual is None:
            info = mods.get(dependency.mod_id)
            if not info:
                problems.append(
                    f"{source}: {dependency.requester} requires {dependency.mod_id} {dependency.version_range or '(any)'} but it is not installed"
                )
                continue
            actual = info.version
        if dependency.version_range and not satisfies_range(actual, dependency.version_range):
            problems.append(
                f"{source}: {dependency.requester} requires {dependency.mod_id} {dependency.version_range} but actual is {actual}"
            )
    return problems


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package_dir", type=Path, help="Client package directory or a mods directory")
    parser.add_argument("--minecraft-version", default=SPECIAL_VERSIONS["minecraft"])
    parser.add_argument("--neoforge-version", default=SPECIAL_VERSIONS["neoforge"])
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    mods_dir = args.package_dir / "mods" if (args.package_dir / "mods").is_dir() else args.package_dir
    if not mods_dir.is_dir():
        print(f"ERROR missing mods directory: {mods_dir}", file=sys.stderr)
        return 1
    problems = validate_dependencies(
        mods_dir,
        {
            "minecraft": args.minecraft_version,
            "neoforge": args.neoforge_version,
        },
    )
    if problems:
        for problem in problems:
            print(f"ERROR {problem}", file=sys.stderr)
        return 1
    print("client_mod_dependencies=ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
