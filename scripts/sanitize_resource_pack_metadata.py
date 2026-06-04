#!/usr/bin/env python3
"""Remove resource-pack metadata keys that crash modern Minecraft clients."""

from __future__ import annotations

import argparse
import json
import shutil
import sys
import tempfile
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Sequence


@dataclass(frozen=True)
class Change:
    path: Path
    member: str
    added_keys: int
    removed_keys: int


def candidate_files(path: Path) -> list[Path]:
    if path.is_file() and path.suffix.lower() == ".zip":
        return [path]
    if path.is_file() and path.suffix.lower() == ".jar":
        return [path]
    roots: list[Path] = []
    if (path / "mods").is_dir():
        roots.append(path / "mods")
    if (path / "resourcepacks").is_dir():
        roots.append(path / "resourcepacks")
    if not roots and path.is_dir():
        roots.append(path)
    files: list[Path] = []
    for root in roots:
        if not root.exists():
            continue
        files.extend(item for item in root.iterdir() if item.is_file() and item.suffix.lower() in {".zip", ".jar"})
    return sorted(set(files), key=lambda item: item.name.lower())


def format_major(value: Any) -> int | None:
    if isinstance(value, int):
        return value
    if isinstance(value, float):
        return int(value)
    if isinstance(value, list) and value:
        return format_major(value[0])
    if isinstance(value, dict):
        for key in ("min_inclusive", "min_format"):
            major = format_major(value.get(key))
            if major is not None:
                return major
    return None


def entry_uses_new_overlay_schema(entry: dict[str, Any]) -> bool:
    major = format_major(entry.get("min_format"))
    if major is None:
        major = format_major(entry.get("formats"))
    return major is not None and major >= 65


def legacy_formats_present(entries: list[Any]) -> bool:
    for entry in entries:
        if isinstance(entry, dict) and "formats" in entry:
            major = format_major(entry.get("formats"))
            if major is not None and major < 65:
                return True
    return False


def make_formats_value(entry: dict[str, Any], template: Any) -> Any | None:
    min_format = entry.get("min_format")
    max_format = entry.get("max_format")
    if min_format is None or max_format is None:
        return None
    if isinstance(template, dict):
        return {"min_inclusive": min_format, "max_inclusive": max_format}
    return [min_format, max_format]


def first_formats_template(entries: list[Any]) -> Any:
    for entry in entries:
        if isinstance(entry, dict) and "formats" in entry:
            return entry["formats"]
    return []


def sanitize_overlay_entries(entries: Any) -> tuple[int, int]:
    if not isinstance(entries, list):
        return 0, 0
    if legacy_formats_present(entries):
        added = 0
        template = first_formats_template(entries)
        for entry in entries:
            if not isinstance(entry, dict) or "formats" in entry:
                continue
            formats_value = make_formats_value(entry, template)
            if formats_value is not None:
                entry["formats"] = formats_value
                added += 1
        return added, 0
    removed = 0
    for entry in entries:
        if isinstance(entry, dict) and "formats" in entry and entry_uses_new_overlay_schema(entry):
            del entry["formats"]
            removed += 1
    return 0, removed


def sanitize_pack_metadata(metadata: dict[str, Any]) -> tuple[int, int]:
    added = 0
    removed = 0
    for key, value in metadata.items():
        if key == "overlays" or key.endswith(":overlays"):
            if isinstance(value, dict):
                entry_added, entry_removed = sanitize_overlay_entries(value.get("entries"))
                added += entry_added
                removed += entry_removed
    return added, removed


def rewrite_zip_member(path: Path, replacements: dict[str, bytes]) -> None:
    with tempfile.NamedTemporaryFile(prefix=f"{path.name}.", suffix=".tmp", delete=False) as handle:
        tmp_path = Path(handle.name)
    try:
        with zipfile.ZipFile(path, "r") as source, zipfile.ZipFile(tmp_path, "w") as target:
            for info in source.infolist():
                data = replacements.get(info.filename)
                if data is None:
                    data = source.read(info.filename)
                target.writestr(info, data)
        shutil.move(str(tmp_path), path)
    finally:
        tmp_path.unlink(missing_ok=True)


def sanitize_zip(path: Path, *, write: bool) -> list[Change]:
    changes: list[Change] = []
    replacements: dict[str, bytes] = {}
    try:
        with zipfile.ZipFile(path, "r") as archive:
            for member in archive.namelist():
                if not member.endswith("pack.mcmeta"):
                    continue
                if member.startswith("__MACOSX/") or "/._" in member or member.startswith("._"):
                    continue
                try:
                    metadata = json.loads(archive.read(member).decode("utf-8-sig"))
                except Exception as exc:
                    raise ValueError(f"{path}:{member}: invalid pack.mcmeta JSON: {exc}") from exc
                added, removed = sanitize_pack_metadata(metadata)
                if added or removed:
                    changes.append(Change(path=path, member=member, added_keys=added, removed_keys=removed))
                    replacements[member] = (json.dumps(metadata, indent=2, sort_keys=False) + "\n").encode("utf-8")
    except zipfile.BadZipFile as exc:
        raise ValueError(f"{path}: invalid zip file: {exc}") from exc
    if write and replacements:
        rewrite_zip_member(path, replacements)
    return changes


def sanitize_path(path: Path, *, write: bool) -> list[Change]:
    changes: list[Change] = []
    for candidate in candidate_files(path):
        changes.extend(sanitize_zip(candidate, write=write))
    return changes


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", type=Path, help="client-package directory, resourcepacks directory, or one resource-pack zip")
    parser.add_argument("--write", action="store_true", help="rewrite affected zip files in place")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        changes = sanitize_path(args.path, write=args.write)
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    for change in changes:
        action = "sanitized" if args.write else "would_sanitize"
        print(
            f"{action}\t{change.path}\t{change.member}"
            f"\tadded_keys={change.added_keys}\tremoved_keys={change.removed_keys}"
        )
    print(f"resource_pack_metadata_changes={len(changes)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
