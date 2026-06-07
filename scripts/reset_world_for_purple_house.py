#!/usr/bin/env python3
"""Reset the active world and place Purple House near spawn."""

from __future__ import annotations

import argparse
import secrets
import shutil
import subprocess
import sys
import time
import zipfile
from pathlib import Path


DEFAULT_PROJECT_DIR = Path("/var/minecraft_mods")
DEFAULT_SERVER_DIR = Path("/var/minecraft_26.1.2")
DEFAULT_SERVICE = "pummelchen-minecraft.service"
PACK_FORMAT = 81
SUPPORTED_FORMATS = [81, 94]
PURPLE_HOUSE_ZIP = "pummelchen-purple-house.zip"
PLACE_PACK_ZIP = "pummelchen-place-purple-house.zip"
ZIP_DATE = (2026, 6, 7, 0, 0, 0)


def read_properties(path: Path) -> tuple[list[str], dict[str, str]]:
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines() if path.exists() else []
    values: dict[str, str] = {}
    for raw in lines:
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip()
    return lines, values


def write_properties(path: Path, updates: dict[str, str]) -> None:
    lines, _values = read_properties(path)
    seen: set[str] = set()
    merged: list[str] = []
    for raw in lines:
        if "=" in raw and not raw.lstrip().startswith("#"):
            key = raw.split("=", 1)[0].strip()
            if key in updates:
                merged.append(f"{key}={updates[key]}")
                seen.add(key)
                continue
        merged.append(raw)
    for key, value in updates.items():
        if key not in seen:
            merged.append(f"{key}={value}")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(merged) + "\n", encoding="utf-8")


def active_world_name(server_dir: Path) -> str:
    _lines, values = read_properties(server_dir / "server.properties")
    level_name = values.get("level-name") or "world"
    level_path = Path(level_name)
    if level_path.is_absolute() or ".." in level_path.parts:
        raise SystemExit(f"unsafe level-name in server.properties: {level_name!r}")
    return level_name


def copy_if_changed(src: Path, dst: Path) -> bool:
    dst.parent.mkdir(parents=True, exist_ok=True)
    if dst.exists() and dst.read_bytes() == src.read_bytes():
        return False
    tmp = dst.with_suffix(dst.suffix + ".tmp")
    shutil.copy2(src, tmp)
    tmp.replace(dst)
    return True


def stop_service(service: str, dry_run: bool) -> None:
    if dry_run:
        print(f"DRY-RUN systemctl stop {service}")
        return
    subprocess.run(["systemctl", "stop", service], check=True)


def start_service(service: str, dry_run: bool) -> None:
    if dry_run:
        print(f"DRY-RUN systemctl start {service}")
        return
    subprocess.run(["systemctl", "start", service], check=True)


def wait_for_done(service: str, started_at: float, timeout: int) -> bool:
    if timeout <= 0:
        return False
    deadline = time.time() + timeout
    since = f"@{int(started_at)}"
    while time.time() < deadline:
        result = subprocess.run(
            ["journalctl", "-u", service, "--since", since, "--no-pager"],
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
        if "Done (" in result.stdout:
            return True
        time.sleep(3)
    return False


def backup_world(world_dir: Path, backup_root: Path, dry_run: bool) -> Path | None:
    if not world_dir.exists():
        return None
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    backup = backup_root / f"{world_dir.name}-{stamp}"
    index = 1
    while backup.exists():
        index += 1
        backup = backup_root / f"{world_dir.name}-{stamp}-{index}"
    if dry_run:
        print(f"DRY-RUN move {world_dir} {backup}")
        return backup
    backup.parent.mkdir(parents=True, exist_ok=True)
    shutil.move(str(world_dir), str(backup))
    return backup


def datapack_sources(project_dir: Path, server_dir: Path) -> list[Path]:
    candidates = []
    for root in (project_dir / "server-datapacks", server_dir / "server-datapacks"):
        if root.exists():
            candidates.extend(
                sorted(path for path in root.iterdir() if path.is_file() and path.suffix == ".zip")
            )
    deduped: dict[str, Path] = {}
    for path in candidates:
        deduped[path.name] = path
    if PURPLE_HOUSE_ZIP not in deduped:
        raise SystemExit(f"missing {PURPLE_HOUSE_ZIP} in project or server datapacks")
    return list(deduped.values())


def write_zip(path: Path, files: dict[str, bytes]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    with zipfile.ZipFile(tmp, "w", compression=zipfile.ZIP_STORED) as archive:
        for rel in sorted(files):
            info = zipfile.ZipInfo(rel, ZIP_DATE)
            info.compress_type = zipfile.ZIP_STORED
            info.external_attr = 0o644 << 16
            archive.writestr(info, files[rel])
    tmp.replace(path)


def placement_pack(origin: tuple[int, int, int], spawn: tuple[int, int, int]) -> dict[str, bytes]:
    ox, oy, oz = origin
    sx, sy, sz = spawn
    function_body = "\n".join(
        [
            "scoreboard objectives add pummelchen_ops dummy",
            "scoreboard players set #place_success pummelchen_ops 0",
            "execute unless score #purple_house pummelchen_ops matches 1 "
            "store success score #place_success pummelchen_ops "
            f"run place structure pummelchen:purple_house {ox} {oy} {oz}",
            f"execute if score #place_success pummelchen_ops matches 1 run setworldspawn {sx} {sy} {sz}",
            "execute if score #place_success pummelchen_ops matches 1 run scoreboard players set #purple_house pummelchen_ops 1",
            "",
        ]
    ).encode("utf-8")
    load_tag = b'{"replace":false,"values":["pummelchen_ops:place_purple_house"]}\n'
    return {
        "pack.mcmeta": (
            '{"pack":{"pack_format":%d,"supported_formats":[%d,%d],'
            '"description":"One-shot Purple House spawn placement."}}\n'
            % (PACK_FORMAT, SUPPORTED_FORMATS[0], SUPPORTED_FORMATS[1])
        ).encode("utf-8"),
        "data/minecraft/tags/function/load.json": load_tag,
        "data/minecraft/tags/function/tick.json": load_tag,
        "data/minecraft/tags/functions/load.json": load_tag,
        "data/minecraft/tags/functions/tick.json": load_tag,
        "data/pummelchen_ops/function/place_purple_house.mcfunction": function_body,
        "data/pummelchen_ops/functions/place_purple_house.mcfunction": function_body,
    }


def install_datapacks(
    project_dir: Path,
    server_dir: Path,
    world_dir: Path,
    origin: tuple[int, int, int],
    spawn: tuple[int, int, int],
) -> int:
    changed = 0
    server_datapacks = server_dir / "server-datapacks"
    world_datapacks = world_dir / "datapacks"
    for source in datapack_sources(project_dir, server_dir):
        if copy_if_changed(source, server_datapacks / source.name):
            changed += 1
        if copy_if_changed(source, world_datapacks / source.name):
            changed += 1
    place_pack = world_datapacks / PLACE_PACK_ZIP
    write_zip(place_pack, placement_pack(origin, spawn))
    changed += 1
    return changed


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project-dir", type=Path, default=DEFAULT_PROJECT_DIR)
    parser.add_argument("--server-dir", type=Path, default=DEFAULT_SERVER_DIR)
    parser.add_argument("--service", default=DEFAULT_SERVICE)
    parser.add_argument("--seed", default=str(secrets.randbelow(2**63)))
    parser.add_argument("--origin-x", type=int, default=-28)
    parser.add_argument("--origin-y", type=int, default=80)
    parser.add_argument("--origin-z", type=int, default=-28)
    parser.add_argument("--spawn-x", type=int, default=0)
    parser.add_argument("--spawn-y", type=int, default=83)
    parser.add_argument("--spawn-z", type=int, default=18)
    parser.add_argument("--wait-timeout", type=int, default=180)
    parser.add_argument("--no-restart", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--yes", action="store_true", help="required confirmation for destructive world reset")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if not args.yes:
        print("ERROR destructive reset requires --yes", file=sys.stderr)
        return 2
    server_dir = args.server_dir
    world_name = active_world_name(server_dir)
    world_dir = server_dir / world_name
    seed = str(args.seed).strip() or str(secrets.randbelow(2**63))
    origin = (args.origin_x, args.origin_y, args.origin_z)
    spawn = (args.spawn_x, args.spawn_y, args.spawn_z)

    print(f"world_name={world_name}")
    print(f"world_seed={seed}")
    print(f"purple_house_origin={origin[0]},{origin[1]},{origin[2]}")
    print(f"spawn={spawn[0]},{spawn[1]},{spawn[2]}")

    if not args.no_restart:
        stop_service(args.service, args.dry_run)
    backup = backup_world(world_dir, server_dir / "world-reset-backups", args.dry_run)
    print(f"world_backup={backup or ''}")
    if not args.dry_run:
        write_properties(server_dir / "server.properties", {"level-name": world_name, "level-seed": seed})
        changed = install_datapacks(args.project_dir, server_dir, world_dir, origin, spawn)
        print(f"datapacks_changed={changed}")
    else:
        print("DRY-RUN write server.properties level-seed and placement datapack")
    started_at = time.time()
    if not args.no_restart:
        start_service(args.service, args.dry_run)
        done = False if args.dry_run else wait_for_done(args.service, started_at, args.wait_timeout)
        print(f"server_done_seen={int(done)}")
    print(f"world_dir={world_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
