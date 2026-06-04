#!/usr/bin/env python3
"""Launch the installed macOS Minecraft client long enough to catch mod-load crashes.

This is intentionally a local smoke test, not a CI test. It uses the installed
launcher metadata and libraries under ~/Library/Application Support/minecraft,
then runs NeoForge directly with a throwaway offline profile.
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import time
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable, Sequence


MACOS_OS_NAME = "osx"
DEFAULT_VERSION = "neoforge-26.1.2.71"
DEFAULT_MINECRAFT_DIR = Path.home() / "Library/Application Support/minecraft"
DEFAULT_PUMMELCHEN_JAVA = Path.home() / "Library/Application Support/Pummelchen/java25/bin/java"
SUCCESS_MARKERS = (
    "Sound engine started",
    "minecraft:textures/atlas/gui.png-atlas",
    "minecraft:textures/atlas/blocks.png-atlas",
)
FAILURE_MARKERS = (
    "Game crashed!",
    "Error loading mods",
    "Preparing crash report",
    "Crash report saved to:",
)
PLACEHOLDER_RE = re.compile(r"\$\{([^}]+)\}")


class SmokeError(RuntimeError):
    pass


@dataclass(frozen=True)
class Library:
    path: Path
    natives: Path | None = None


def read_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def version_json_path(minecraft_dir: Path, version_id: str) -> Path:
    return minecraft_dir / "versions" / version_id / f"{version_id}.json"


def load_version_chain(minecraft_dir: Path, version_id: str) -> list[dict[str, Any]]:
    path = version_json_path(minecraft_dir, version_id)
    if not path.exists():
        raise SmokeError(f"missing Minecraft version metadata: {path}")
    version = read_json(path)
    parent_id = version.get("inheritsFrom")
    if parent_id:
        return [*load_version_chain(minecraft_dir, str(parent_id)), version]
    return [version]


def current_arch() -> str:
    machine = platform.machine().lower()
    if machine in {"arm64", "aarch64"}:
        return "arm64"
    if machine in {"x86_64", "amd64"}:
        return "x86_64"
    return machine


def rule_matches(rule: dict[str, Any], features: dict[str, bool]) -> bool:
    os_rule = rule.get("os")
    if isinstance(os_rule, dict):
        name = os_rule.get("name")
        if name and name != MACOS_OS_NAME:
            return False
        arch = os_rule.get("arch")
        if arch and arch != current_arch():
            return False
    feature_rule = rule.get("features")
    if isinstance(feature_rule, dict):
        for feature_name, expected in feature_rule.items():
            if bool(features.get(str(feature_name), False)) != bool(expected):
                return False
    return True


def include_rule_entry(entry: dict[str, Any], features: dict[str, bool]) -> bool:
    rules = entry.get("rules")
    if not isinstance(rules, list):
        return True
    result: bool | None = None
    for rule in rules:
        if not isinstance(rule, dict) or not rule_matches(rule, features):
            continue
        result = rule.get("action", "allow") == "allow"
    return bool(result)


def flatten_argument_entries(entries: Iterable[Any], features: dict[str, bool]) -> list[str]:
    args: list[str] = []
    for entry in entries:
        if isinstance(entry, str):
            args.append(entry)
            continue
        if not isinstance(entry, dict) or not include_rule_entry(entry, features):
            continue
        value = entry.get("value")
        if isinstance(value, str):
            args.append(value)
        elif isinstance(value, list):
            args.extend(str(item) for item in value)
    return args


def substitute_placeholders(args: Sequence[str], variables: dict[str, str]) -> list[str]:
    resolved: list[str] = []
    for item in args:
        missing: list[str] = []

        def replacement(match: re.Match[str]) -> str:
            key = match.group(1)
            if key not in variables:
                missing.append(key)
                return match.group(0)
            return variables[key]

        value = PLACEHOLDER_RE.sub(replacement, item)
        if missing:
            raise SmokeError(f"unresolved launcher placeholder(s) in {item!r}: {', '.join(sorted(set(missing)))}")
        resolved.append(value)
    return resolved


def artifact_path(libraries_dir: Path, artifact: dict[str, Any]) -> Path:
    artifact_path_value = artifact.get("path")
    if not artifact_path_value:
        raise SmokeError(f"library artifact missing path: {artifact!r}")
    return libraries_dir / str(artifact_path_value)


def parse_libraries(version_chain: Sequence[dict[str, Any]], libraries_dir: Path, features: dict[str, bool]) -> list[Library]:
    libraries: list[Library] = []
    seen: set[Path] = set()
    for version in version_chain:
        for library in version.get("libraries", []):
            if not isinstance(library, dict) or not include_rule_entry(library, features):
                continue
            downloads = library.get("downloads")
            if not isinstance(downloads, dict):
                continue
            artifact = downloads.get("artifact")
            if not isinstance(artifact, dict):
                continue
            path = artifact_path(libraries_dir, artifact)
            natives_path: Path | None = None
            natives = library.get("natives")
            classifiers = downloads.get("classifiers")
            if isinstance(natives, dict) and isinstance(classifiers, dict):
                classifier_key = str(natives.get(MACOS_OS_NAME, "")).replace("${arch}", "64")
                classifier = classifiers.get(classifier_key)
                if isinstance(classifier, dict):
                    natives_path = artifact_path(libraries_dir, classifier)
            if path not in seen:
                libraries.append(Library(path=path, natives=natives_path))
                seen.add(path)
    return libraries


def extract_natives(libraries: Sequence[Library], natives_dir: Path) -> None:
    exclude_prefixes = ("META-INF/", "META-INF\\")
    for library in libraries:
        if library.natives is None:
            continue
        if not library.natives.exists():
            raise SmokeError(f"missing native library jar: {library.natives}")
        with zipfile.ZipFile(library.natives) as archive:
            for member in archive.infolist():
                name = member.filename
                if not name or name.endswith("/") or name.startswith(exclude_prefixes):
                    continue
                target = natives_dir / name
                target.parent.mkdir(parents=True, exist_ok=True)
                with archive.open(member) as src, target.open("wb") as dst:
                    shutil.copyfileobj(src, dst)


def version_main_class(version_chain: Sequence[dict[str, Any]]) -> str:
    for version in reversed(version_chain):
        main_class = version.get("mainClass")
        if main_class:
            return str(main_class)
    raise SmokeError("version metadata does not define mainClass")


def version_jar(minecraft_dir: Path, version_chain: Sequence[dict[str, Any]]) -> Path:
    for version in reversed(version_chain):
        version_id = version.get("id")
        if not version_id:
            continue
        candidate = minecraft_dir / "versions" / str(version_id) / f"{version_id}.jar"
        if candidate.exists():
            return candidate
    raise SmokeError("could not find a Minecraft client jar in version chain")


def merged_arguments(version_chain: Sequence[dict[str, Any]], kind: str, features: dict[str, bool]) -> list[str]:
    merged: list[str] = []
    legacy_game_args: list[str] = []
    for version in version_chain:
        arguments = version.get("arguments")
        if isinstance(arguments, dict):
            entries = arguments.get(kind)
            if isinstance(entries, list):
                merged.extend(flatten_argument_entries(entries, features))
        elif kind == "game":
            minecraft_args = version.get("minecraftArguments")
            if isinstance(minecraft_args, str):
                legacy_game_args.extend(minecraft_args.split())
    return merged or legacy_game_args


def latest_log_size(log_path: Path) -> int:
    try:
        return log_path.stat().st_size
    except FileNotFoundError:
        return 0


def latest_crash_reports(crash_dir: Path, started_at: float) -> list[Path]:
    if not crash_dir.exists():
        return []
    reports: list[Path] = []
    for path in crash_dir.glob("crash-*.txt"):
        try:
            if path.stat().st_mtime >= started_at:
                reports.append(path)
        except FileNotFoundError:
            continue
    return sorted(reports, key=lambda item: item.stat().st_mtime, reverse=True)


def read_new_log_text(log_path: Path, offset: int) -> tuple[str, int]:
    try:
        with log_path.open("rb") as handle:
            handle.seek(offset)
            data = handle.read()
            return data.decode("utf-8", errors="replace"), offset + len(data)
    except FileNotFoundError:
        return "", offset


def tail_text(path: Path, max_bytes: int = 32768) -> str:
    try:
        size = path.stat().st_size
        with path.open("rb") as handle:
            handle.seek(max(0, size - max_bytes))
            return handle.read().decode("utf-8", errors="replace")
    except FileNotFoundError:
        return ""


def terminate_process(process: subprocess.Popen[str], grace_seconds: float = 8.0) -> None:
    if process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=grace_seconds)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=grace_seconds)


def build_launch_command(args: argparse.Namespace, natives_dir: Path) -> list[str]:
    minecraft_dir = args.minecraft_dir.expanduser().resolve()
    libraries_dir = minecraft_dir / "libraries"
    features = {
        "has_custom_resolution": True,
        "has_quick_plays_support": False,
        "is_demo_user": bool(args.demo),
        "is_quick_play_singleplayer": False,
        "is_quick_play_multiplayer": False,
        "is_quick_play_realms": False,
    }
    version_chain = load_version_chain(minecraft_dir, args.version)
    libraries = parse_libraries(version_chain, libraries_dir, features)
    missing = [str(library.path) for library in libraries if not library.path.exists()]
    if missing:
        preview = "\n".join(missing[:10])
        suffix = "" if len(missing) <= 10 else f"\n... and {len(missing) - 10} more"
        raise SmokeError(f"missing client libraries:\n{preview}{suffix}")
    extract_natives(libraries, natives_dir)
    classpath_items = [str(library.path) for library in libraries]
    classpath_items.append(str(version_jar(minecraft_dir, version_chain)))
    classpath = os.pathsep.join(classpath_items)
    root_version = version_chain[0]
    asset_index = root_version.get("assetIndex") if isinstance(root_version.get("assetIndex"), dict) else {}
    variables = {
        "assets_index_name": str(asset_index.get("id", root_version.get("assets", ""))),
        "assets_root": str(minecraft_dir / "assets"),
        "auth_access_token": "0",
        "auth_player_name": args.username,
        "auth_uuid": "e2e13b61d14e4d42a2f4ded369704326",
        "auth_xuid": "0",
        "classpath": classpath,
        "clientid": "0",
        "game_directory": str(minecraft_dir),
        "launcher_name": "pummelchen-smoke",
        "launcher_version": "1",
        "library_directory": str(libraries_dir),
        "natives_directory": str(natives_dir),
        "quickPlayPath": str(minecraft_dir / "quickPlay/java"),
        "resolution_height": str(args.height),
        "resolution_width": str(args.width),
        "user_properties": "{}",
        "user_type": "legacy",
        "version_name": args.version,
        "version_type": "release",
    }
    jvm_args = substitute_placeholders(merged_arguments(version_chain, "jvm", features), variables)
    game_args = substitute_placeholders(merged_arguments(version_chain, "game", features), variables)
    extra_jvm_args = args.extra_jvm_arg if args.extra_jvm_arg else ["-Xmx6G"]
    return [
        str(args.java_bin),
        *extra_jvm_args,
        *jvm_args,
        version_main_class(version_chain),
        *game_args,
    ]


def run_smoke(args: argparse.Namespace) -> int:
    if platform.system() != "Darwin" and not args.force:
        raise SmokeError("macOS client smoke can only run on Darwin unless --force is used")
    if not args.java_bin.exists():
        raise SmokeError(f"Java executable not found: {args.java_bin}")
    minecraft_dir = args.minecraft_dir.expanduser().resolve()
    log_path = minecraft_dir / "logs/latest.log"
    crash_dir = minecraft_dir / "crash-reports"
    log_offset = latest_log_size(log_path)
    started_at = time.time()
    with tempfile.TemporaryDirectory(prefix="pummelchen-client-natives.") as tmp:
        command = build_launch_command(args, Path(tmp))
        if args.print_command:
            print("\n".join(command))
            return 0
        print(f"client_smoke_version={args.version}")
        print(f"client_smoke_minecraft_dir={minecraft_dir}")
        print(f"client_smoke_java={args.java_bin}")
        stdout_path = Path(tmp) / "client-smoke-stdout.log"
        stdout_handle = stdout_path.open("w", encoding="utf-8", errors="replace")
        success_marker = ""
        deadline = time.monotonic() + args.timeout
        process = subprocess.Popen(
            command,
            cwd=str(minecraft_dir),
            stdout=stdout_handle,
            stderr=subprocess.STDOUT,
            text=True,
        )
        try:
            while True:
                new_log, log_offset = read_new_log_text(log_path, log_offset)
                if new_log:
                    if args.verbose:
                        print(new_log, end="")
                    for marker in SUCCESS_MARKERS:
                        if marker in new_log:
                            success_marker = marker
                            break
                    for marker in FAILURE_MARKERS:
                        if marker in new_log:
                            reports = latest_crash_reports(crash_dir, started_at)
                            detail = f"; crash report: {reports[0]}" if reports else ""
                            raise SmokeError(f"client smoke saw failure marker {marker!r}{detail}")
                reports = latest_crash_reports(crash_dir, started_at)
                if reports:
                    raise SmokeError(f"client smoke created crash report: {reports[0]}")
                if success_marker:
                    print(f"client_smoke=ok marker={success_marker!r}")
                    return 0
                code = process.poll()
                if code is not None:
                    output_tail = tail_text(stdout_path)
                    raise SmokeError(f"client exited before startup marker with code {code}\n{output_tail}")
                if time.monotonic() > deadline:
                    raise SmokeError(f"client smoke timed out after {args.timeout}s without startup marker")
                time.sleep(1)
        finally:
            terminate_process(process)
            stdout_handle.close()


def existing_java() -> Path:
    if DEFAULT_PUMMELCHEN_JAVA.exists():
        return DEFAULT_PUMMELCHEN_JAVA
    java_path = shutil.which("java")
    if java_path:
        return Path(java_path)
    return DEFAULT_PUMMELCHEN_JAVA


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--minecraft-dir", type=Path, default=DEFAULT_MINECRAFT_DIR)
    parser.add_argument("--version", default=DEFAULT_VERSION)
    parser.add_argument("--java-bin", type=Path, default=existing_java())
    parser.add_argument("--timeout", type=int, default=420)
    parser.add_argument("--width", type=int, default=1280)
    parser.add_argument("--height", type=int, default=720)
    parser.add_argument("--username", default="PummelchenSmoke")
    parser.add_argument("--demo", action="store_true")
    parser.add_argument("--extra-jvm-arg", action="append")
    parser.add_argument("--print-command", action="store_true")
    parser.add_argument("--verbose", action="store_true")
    parser.add_argument("--force", action="store_true")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return run_smoke(args)
    except KeyboardInterrupt:
        return 130
    except SmokeError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
