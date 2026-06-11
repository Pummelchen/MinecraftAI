#!/usr/bin/env python3
"""Safely replace the active world with a new seeded world and pregenerate spawn."""

from __future__ import annotations

import argparse
import math
import secrets
import sys
import time
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import reset_world_for_purple_house as reset


DEFAULT_PROJECT_DIR = reset.DEFAULT_PROJECT_DIR
DEFAULT_SERVER_DIR = reset.DEFAULT_SERVER_DIR
DEFAULT_SERVICE = reset.DEFAULT_SERVICE
DEFAULT_DIAMETER_BLOCKS = 1000
DEFAULT_BATCH_SIZE = 16
DEFAULT_BATCH_PAUSE = 0.25
DEFAULT_PREGEM_TIMEOUT = 1800

SAFETY_GAMERULES = {
    "keep_inventory": "true",
    "mob_griefing": "false",
    "projectiles_can_break_blocks": "false",
    "block_explosion_drop_decay": "false",
    "mob_explosion_drop_decay": "false",
    "tnt_explodes": "false",
    "tnt_explosion_drop_decay": "false",
}


def pregeneration_chunks(
    spawn: tuple[int, int, int],
    diameter_blocks: int,
    *,
    shape: str,
) -> list[tuple[int, int]]:
    radius_blocks = max(0, diameter_blocks // 2)
    sx, _sy, sz = spawn
    min_chunk_x = math.floor((sx - radius_blocks) / 16)
    max_chunk_x = math.floor((sx + radius_blocks) / 16)
    min_chunk_z = math.floor((sz - radius_blocks) / 16)
    max_chunk_z = math.floor((sz + radius_blocks) / 16)
    chunks: list[tuple[int, int]] = []
    for chunk_x in range(min_chunk_x, max_chunk_x + 1):
        for chunk_z in range(min_chunk_z, max_chunk_z + 1):
            if shape == "circle":
                center_x = chunk_x * 16 + 8
                center_z = chunk_z * 16 + 8
                if ((center_x - sx) ** 2 + (center_z - sz) ** 2) ** 0.5 > radius_blocks:
                    continue
            chunks.append((chunk_x, chunk_z))
    return chunks


def apply_safety_gamerules(rcon_port: int, password: str, *, dry_run: bool) -> None:
    commands = [f"gamerule {name} {value}" for name, value in SAFETY_GAMERULES.items()]
    if dry_run:
        for command in commands:
            print(f"DRY-RUN rcon {command}")
        return
    responses = reset.run_rcon_commands(
        reset.RCON_HOST,
        rcon_port,
        password,
        commands,
        timeout=reset.RCON_COMMAND_TIMEOUT,
    )
    for command, response in zip(commands, responses):
        clean = reset._clean_minecraft_output(response)
        print(f"gamerule_applied={command}\tresponse={clean}")


def pregenerate_chunks(
    chunks: list[tuple[int, int]],
    rcon_port: int,
    password: str,
    *,
    batch_size: int,
    batch_pause: float,
    timeout: int,
    dry_run: bool,
) -> None:
    if not chunks:
        print("pregenerate_chunks=0")
        return
    print(f"pregenerate_chunks={len(chunks)}")
    if dry_run:
        first = chunks[0]
        last = chunks[-1]
        print(f"DRY-RUN pregenerate first_chunk={first[0]},{first[1]} last_chunk={last[0]},{last[1]}")
        return

    started = time.monotonic()
    loaded: list[tuple[int, int]] = []
    for index, (chunk_x, chunk_z) in enumerate(chunks, start=1):
        if timeout > 0 and time.monotonic() - started > timeout:
            raise TimeoutError(f"pregeneration timeout after {index - 1}/{len(chunks)} chunks")
        reset.rcon_command(
            reset.RCON_HOST,
            rcon_port,
            password,
            f"forceload add {chunk_x} {chunk_z}",
            timeout=reset.RCON_COMMAND_TIMEOUT,
        )
        loaded.append((chunk_x, chunk_z))
        if len(loaded) >= batch_size or index == len(chunks):
            reset.rcon_command(reset.RCON_HOST, rcon_port, password, "save-all flush", timeout=reset.RCON_COMMAND_TIMEOUT)
            for loaded_x, loaded_z in loaded:
                reset.rcon_command(
                    reset.RCON_HOST,
                    rcon_port,
                    password,
                    f"forceload remove {loaded_x} {loaded_z}",
                    timeout=reset.RCON_COMMAND_TIMEOUT,
                )
            print(f"pregenerate_progress={index}/{len(chunks)}")
            loaded.clear()
            if batch_pause > 0:
                time.sleep(batch_pause)
    reset.rcon_command(reset.RCON_HOST, rcon_port, password, "save-all flush", timeout=reset.RCON_COMMAND_TIMEOUT)
    print(f"pregenerate_done=1\tchunks={len(chunks)}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project-dir", type=Path, default=DEFAULT_PROJECT_DIR)
    parser.add_argument("--server-dir", type=Path, default=DEFAULT_SERVER_DIR)
    parser.add_argument("--service", default=DEFAULT_SERVICE)
    parser.add_argument("--seed", default=str(secrets.randbelow(2**63)))
    parser.add_argument("--diameter-blocks", type=int, default=DEFAULT_DIAMETER_BLOCKS)
    parser.add_argument("--shape", choices=("square", "circle"), default="square")
    parser.add_argument("--batch-size", type=int, default=DEFAULT_BATCH_SIZE)
    parser.add_argument("--batch-pause", type=float, default=DEFAULT_BATCH_PAUSE)
    parser.add_argument("--pregenerate-timeout", type=int, default=DEFAULT_PREGEM_TIMEOUT)
    parser.add_argument("--rcon-port", type=int, default=25575)
    parser.add_argument("--wait-timeout", type=int, default=240)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--yes", action="store_true", help="required confirmation for destructive world reset")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if not args.yes:
        print("ERROR destructive reset requires --yes", file=sys.stderr)
        return 2
    if args.diameter_blocks <= 0:
        raise SystemExit("--diameter-blocks must be positive")
    if args.batch_size <= 0:
        raise SystemExit("--batch-size must be positive")

    server_dir = args.server_dir
    world_name = reset.active_world_name(server_dir)
    world_dir = server_dir / world_name
    if not world_name or world_dir.resolve() == server_dir.resolve():
        raise SystemExit(f"refusing to reset server directory as world: level-name={world_name!r}")
    seed = str(args.seed).strip() or str(secrets.randbelow(2**63))

    print(f"world_name={world_name}")
    print(f"world_seed={seed}")
    print(f"diameter_blocks={args.diameter_blocks}")
    print(f"pregenerate_shape={args.shape}")
    print(f"rcon_port={args.rcon_port}")

    reset.stop_service(args.service, args.dry_run)
    backup = reset.backup_world(world_dir, server_dir / "world-reset-backups", args.dry_run)
    print(f"world_backup={backup or ''}")

    if args.dry_run:
        print("DRY-RUN write server.properties level-seed, bonus-chest, and project datapacks")
        print(f"world_dir={world_dir}")
        chunks = pregeneration_chunks((0, 0, 0), args.diameter_blocks, shape=args.shape)
        pregenerate_chunks(
            chunks,
            args.rcon_port,
            "",
            batch_size=args.batch_size,
            batch_pause=args.batch_pause,
            timeout=args.pregenerate_timeout,
            dry_run=True,
        )
        return 0

    reset.write_properties(
        server_dir / "server.properties",
        {"level-name": world_name, "level-seed": seed, "bonus-chest": "true"},
    )
    changed = reset.install_datapacks(
        args.project_dir,
        server_dir,
        world_dir,
        install_place_pack=False,
        origin=(0, 80, 0),
        spawn=(0, 83, 0),
    )
    print(f"datapacks_changed={changed}")

    props_path = server_dir / "server.properties"
    restored_contents, changed_rcon, rcon_port = reset.ensure_rcon_enabled(props_path, args.rcon_port, args.dry_run)
    try:
        started_at = time.time()
        reset.start_service(args.service, args.dry_run)
        done = reset.wait_for_done(args.service, started_at, args.wait_timeout)
        print(f"server_done_seen={int(done)}")
        if not done:
            raise TimeoutError(f"server did not finish booting within {args.wait_timeout}s")
        if not reset.wait_for_rcon(rcon_port, timeout=reset.RCON_BOOT_TIMEOUT):
            raise TimeoutError(f"RCON unavailable on port {rcon_port}")
        _lines, values = reset.read_properties(props_path)
        password = values.get("rcon.password", "").strip()
        if not password:
            raise RuntimeError("RCON password missing after bootstrap")
        apply_safety_gamerules(rcon_port, password, dry_run=False)
        detected_spawn = reset.read_level_spawn(world_dir) or (0, 0, 0)
        print(f"detected_spawn={detected_spawn[0]},{detected_spawn[1]},{detected_spawn[2]}")
        chunks = pregeneration_chunks(detected_spawn, args.diameter_blocks, shape=args.shape)
        pregenerate_chunks(
            chunks,
            rcon_port,
            password,
            batch_size=args.batch_size,
            batch_pause=args.batch_pause,
            timeout=args.pregenerate_timeout,
            dry_run=False,
        )
    finally:
        if changed_rcon:
            reset.stop_service(args.service, args.dry_run)
            reset.restore_file(props_path, restored_contents)
            reset.start_service(args.service, args.dry_run)
            print("rcon_bootstrap_restored=1")

    print(f"world_dir={world_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
