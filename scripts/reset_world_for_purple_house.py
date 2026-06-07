#!/usr/bin/env python3
"""Reset the active world and place Purple House near spawn."""

from __future__ import annotations

import argparse
import re
import gzip
import socket
import secrets
import shutil
import struct
import subprocess
import sys
import time
import zipfile
from pathlib import Path
from typing import Any


DEFAULT_PROJECT_DIR = Path("/var/minecraft_mods")
DEFAULT_SERVER_DIR = Path("/var/minecraft_26.1.2")
DEFAULT_SERVICE = "pummelchen-minecraft.service"
RCON_HOST = "127.0.0.1"
RCON_TIMEOUT = 2.5
RCON_AUTH = 3
RCON_COMMAND = 2
RCON_AUTH_FAIL = -1
RCON_CONNECT_TIMEOUT = 0.5
PACK_FORMAT = 81
SUPPORTED_FORMATS = [81, 94]
NAMESPACE = "pummelchen"
STRUCTURE_NAME = "purple_house"
PURPLE_HOUSE_ZIP = "pummelchen-purple-house.zip"
PLACE_PACK_ZIP = "pummelchen-place-purple-house.zip"
ZIP_DATE = (2026, 6, 7, 0, 0, 0)
PLACEMENT_STATE_SCORE = "ph_house_state"
PLACEMENT_ATTEMPT_SCORE = "ph_house_attempt"
PLACEMENT_STATUS_SCORE = "ph_house_status"
PLACEMENT_CLEAR_SIZE = 40
DEFAULT_BOOT_WAIT = 180

TAG_END = 0
TAG_BYTE = 1
TAG_SHORT = 2
TAG_INT = 3
TAG_LONG = 4
TAG_FLOAT = 5
TAG_DOUBLE = 6
TAG_BYTE_ARRAY = 7
TAG_STRING = 8
TAG_LIST = 9
TAG_COMPOUND = 10
TAG_INT_ARRAY = 11
TAG_LONG_ARRAY = 12


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


def ensure_rcon_enabled(
    properties_path: Path,
    rcon_port: int,
    dry_run: bool,
) -> tuple[str, bool, int]:
    """Enable RCON temporarily.

    Returns the previous file contents and whether a change was applied.
    """
    current = properties_path.read_text(encoding="utf-8") if properties_path.exists() else ""
    _, values = read_properties(properties_path)
    enable = values.get("enable-rcon", "false").strip().lower() == "true"
    password = values.get("rcon.password", "").strip()
    port = values.get("rcon.port", str(rcon_port)).strip()
    if enable and password:
        try:
            return current, False, int(port)
        except ValueError:
            return current, False, rcon_port
    if dry_run:
        print("DRY-RUN skip rcon bootstrap (would enable temporary RCON)")
        return current, False, rcon_port
    generated_password = password if password else f"pummelchen-{secrets.token_hex(8)}"
    updates = {
        "enable-rcon": "true",
        "rcon.port": str(rcon_port if port.isdigit() else rcon_port),
        "rcon.password": generated_password,
    }
    write_properties(properties_path, updates)
    return current, True, rcon_port


def restore_file(path: Path, text: str) -> None:
    path.write_text(text, encoding="utf-8")


def wait_for_rcon(port: int, host: str = RCON_HOST, timeout: int = 20) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with socket.create_connection((host, port), timeout=RCON_CONNECT_TIMEOUT):
                return True
        except OSError:
            time.sleep(0.5)
    return False


def _read_exact(sock: socket.socket, length: int) -> bytes:
    chunks: list[bytes] = []
    received = 0
    while received < length:
        piece = sock.recv(length - received)
        if not piece:
            raise ConnectionError("closed while reading RCON packet")
        chunks.append(piece)
        received += len(piece)
    return b"".join(chunks)


def _rcon_packet(request_id: int, packet_type: int, payload: str) -> bytes:
    body = struct.pack("<ii", request_id, packet_type) + payload.encode("utf-8") + b"\x00\x00"
    return struct.pack("<i", len(body)) + body


def _read_rcon_packet(sock: socket.socket) -> tuple[int, int, str]:
    header = _read_exact(sock, 4)
    (length,) = struct.unpack("<i", header)
    if length < 10 or length > 1_048_576:
        raise OSError(f"invalid RCON packet length {length}")
    body = _read_exact(sock, length)
    request_id, packet_type = struct.unpack("<ii", body[:8])
    payload = body[8:-2].decode("utf-8", errors="replace")
    return request_id, packet_type, payload


def rcon_command(host: str, port: int, password: str, command: str, timeout: float = RCON_TIMEOUT) -> str:
    with socket.create_connection((host, port), timeout=timeout) as sock:
        sock.settimeout(timeout)
        sock.sendall(_rcon_packet(1, RCON_AUTH, password))
        auth_id, _auth_type, _auth_payload = _read_rcon_packet(sock)
        if auth_id == RCON_AUTH_FAIL:
            raise PermissionError("RCON authentication failed")
        sock.sendall(_rcon_packet(2, RCON_COMMAND, command))
        response_id, _response_type, response = _read_rcon_packet(sock)
        if response_id != 2:
            # Some servers send an empty response followed by an id=0 heartbeat; retry once.
            if response_id != 0:
                raise OSError("unexpected RCON response id")
            response_id, _response_type, response = _read_rcon_packet(sock)
            if response_id != 2:
                raise OSError("unexpected RCON response id")
        return response


def run_rcon_commands(
    host: str,
    port: int,
    password: str,
    commands: list[str],
    timeout: float = RCON_TIMEOUT,
) -> list[str]:
    with socket.create_connection((host, port), timeout=timeout) as sock:
        sock.settimeout(timeout)
        sock.sendall(_rcon_packet(1, RCON_AUTH, password))
        auth_id, _auth_type, _auth_payload = _read_rcon_packet(sock)
        if auth_id == RCON_AUTH_FAIL:
            raise PermissionError("RCON authentication failed")
        responses: list[str] = []
        next_request_id = 2
        for command in commands:
            sock.sendall(_rcon_packet(next_request_id, RCON_COMMAND, command))
            response_id, _response_type, response = _read_rcon_packet(sock)
            if response_id != next_request_id:
                if response_id != 0:
                    raise OSError(f"unexpected RCON response id for {command}: {response_id}")
            responses.append(response)
            next_request_id += 1
        return responses


def _clean_minecraft_output(text: str) -> str:
    return re.sub(r"\u00a7.", "", text).strip()


def _extract_locate_coordinates(text: str) -> tuple[int, int] | None:
    clean = _clean_minecraft_output(text)
    match = re.search(r"\b(-?\d+)\s*,\s*(?:~|~?-?\d+)\s*,\s*(-?\d+)\b", clean)
    if match:
        return int(match.group(1)), int(match.group(2))
    match = re.search(r"\bat\s+(-?\d+)\s+(-?\d+)\s+(-?\d+)\b", clean)
    if match:
        return int(match.group(1)), int(match.group(3))
    match = re.search(r"x:\s*(-?\d+).*y:\s*(-?\d+).*z:\s*(-?\d+)", clean)
    if match:
        return int(match.group(1)), int(match.group(3))
    match = re.search(r"\[(-?\d+)\s*,\s*~\s*,\s*(-?\d+)\]", clean)
    if match:
        return int(match.group(1)), int(match.group(2))
    match = re.search(r"(-?\d+)\s*,\s*(-?\d+)", clean)
    if not match:
        return None
    return int(match.group(1)), int(match.group(2))


def _forceload_region_for_origin(origin: tuple[int, int, int], radius_blocks: int = 96) -> tuple[int, int, int, int]:
    ox, oy, oz = origin
    min_x = ox - radius_blocks
    min_z = oz - radius_blocks
    max_x = ox + radius_blocks
    max_z = oz + radius_blocks
    min_chunk_x = min_x // 16
    max_chunk_x = max_x // 16
    min_chunk_z = min_z // 16
    max_chunk_z = max_z // 16
    return min_chunk_x, min_chunk_z, max_chunk_x, max_chunk_z


def _block_distance(a: tuple[int, int, int], b: tuple[int, int, int]) -> float:
    return (float((a[0] - b[0]) ** 2 + (a[2] - b[2]) ** 2)) ** 0.5


def place_house_via_rcon(
    server_dir: Path,
    spawn: tuple[int, int, int],
    origin: tuple[int, int, int],
    rcon_port: int,
    project_dir: Path = DEFAULT_PROJECT_DIR,
) -> bool:
    _, values = read_properties(server_dir / "server.properties")
    if values.get("enable-rcon", "false").lower() != "true":
        return False
    password = values.get("rcon.password", "").strip()
    if not password:
        return False
    sx, sy, sz = spawn
    ox, oy, oz = origin
    nbt_zip = server_dir / "server-datapacks" / PURPLE_HOUSE_ZIP
    if not nbt_zip.exists():
        nbt_zip = project_dir / "server-datapacks" / PURPLE_HOUSE_ZIP
    nbt_data = read_structure_nbt(nbt_zip)
    if nbt_data is None:
        print(f"placement_via_rcon_error=could_not_read_nbt from {nbt_zip}")
        return False
    palette, blocks = nbt_data
    fill_commands = generate_fill_commands(palette, blocks, origin)
    print(f"placement_via_rcon_fill_commands={len(fill_commands)}")
    min_chunk_x, min_chunk_z, max_chunk_x, max_chunk_z = _forceload_region_for_origin((ox, oy, oz), PLACEMENT_CLEAR_SIZE + 56)
    try:
        if not wait_for_rcon(rcon_port):
            print(f"placement_via_rcon_error=RCON unavailable on port {rcon_port}")
            return False
        rcon_command(RCON_HOST, rcon_port, password, f"forceload add {min_chunk_x} {min_chunk_z} {max_chunk_x} {max_chunk_z}")
        print("placement_via_rcon_forceload=ok")
        time.sleep(10)
        batch_size = 100
        total_batches = (len(fill_commands) + batch_size - 1) // batch_size
        for batch_idx in range(total_batches):
            batch = fill_commands[batch_idx * batch_size : (batch_idx + 1) * batch_size]
            try:
                run_rcon_commands(RCON_HOST, rcon_port, password, batch, timeout=30)
                print(f"placement_via_rcon_batch={batch_idx + 1}/{total_batches}")
            except Exception as exc:
                print(f"placement_via_rcon_batch_error={batch_idx + 1}/{total_batches}: {exc}")
                return False
            time.sleep(1)
        rcon_command(RCON_HOST, rcon_port, password, f"setworldspawn {sx} {sy} {sz}")
        rcon_command(RCON_HOST, rcon_port, password, f"forceload remove {min_chunk_x} {min_chunk_z} {max_chunk_x} {max_chunk_z}")
    except Exception as exc:
        print(f"placement_via_rcon_error={exc.__class__.__name__}: {exc}")
        return False
    print("placement_via_rcon_success=1")
    return True


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
            candidates.extend(sorted(path for path in root.iterdir() if path.is_file() and path.suffix == ".zip"))
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


def _read_string(payload: bytes, offset: int) -> tuple[str, int]:
    size = struct.unpack_from(">H", payload, offset)[0]
    offset += 2
    end = offset + size
    value = payload[offset:end].decode("utf-8", errors="replace")
    return value, end


def _parse_payload(payload: bytes, offset: int, tag: int) -> tuple[object, int]:
    if tag == TAG_END:
        return None, offset
    if tag == TAG_BYTE:
        return struct.unpack_from(">b", payload, offset)[0], offset + 1
    if tag == TAG_SHORT:
        return struct.unpack_from(">h", payload, offset)[0], offset + 2
    if tag == TAG_INT:
        return struct.unpack_from(">i", payload, offset)[0], offset + 4
    if tag == TAG_LONG:
        return struct.unpack_from(">q", payload, offset)[0], offset + 8
    if tag == TAG_FLOAT:
        return struct.unpack_from(">f", payload, offset)[0], offset + 4
    if tag == TAG_DOUBLE:
        return struct.unpack_from(">d", payload, offset)[0], offset + 8
    if tag == TAG_BYTE_ARRAY:
        count = struct.unpack_from(">i", payload, offset)[0]
        offset += 4
        return payload[offset : offset + count], offset + count
    if tag == TAG_STRING:
        value, offset = _read_string(payload, offset)
        return value, offset
    if tag == TAG_LIST:
        element_tag = payload[offset]
        offset += 1
        count = struct.unpack_from(">i", payload, offset)[0]
        offset += 4
        items: list[object] = []
        for _ in range(count):
            item, offset = _parse_payload(payload, offset, element_tag)
            items.append(item)
        return items, offset
    if tag == TAG_COMPOUND:
        compound: dict[str, object] = {}
        while True:
            child_tag = payload[offset]
            offset += 1
            if child_tag == TAG_END:
                return compound, offset
            name, offset = _read_string(payload, offset)
            value, offset = _parse_payload(payload, offset, child_tag)
            compound[name] = value
    if tag == TAG_INT_ARRAY:
        count = struct.unpack_from(">i", payload, offset)[0]
        return [struct.unpack_from(">i", payload, offset + 4 + i * 4)[0] for i in range(count)], offset + 4 + count * 4
    if tag == TAG_LONG_ARRAY:
        count = struct.unpack_from(">i", payload, offset)[0]
        values = []
        cursor = offset + 4
        for _ in range(count):
            values.append(struct.unpack_from(">q", payload, cursor)[0])
            cursor += 8
        return values, cursor
    raise TypeError(f"unsupported nbt tag {tag}")


def _read_level_root(payload: bytes) -> dict[str, object]:
    if not payload:
        return {}
    if payload[0] != TAG_COMPOUND:
        return {}
    # Skip root tag (1 byte), name length + name
    _, name_end = _read_string(payload, 1)
    root, _cursor = _parse_payload(payload, name_end, TAG_COMPOUND)
    if not isinstance(root, dict):
        return {}
    return root


def read_level_spawn(world_dir: Path) -> tuple[int, int, int] | None:
    level_dat = world_dir / "level.dat"
    if not level_dat.exists():
        return None
    try:
        raw = level_dat.read_bytes()
    except OSError:
        return None
    try:
        payload = gzip.decompress(raw)
    except OSError:
        payload = raw
    root = _read_level_root(payload)
    data = root.get("Data")
    if not isinstance(data, dict):
        return None
    sx = data.get("SpawnX")
    sy = data.get("SpawnY")
    sz = data.get("SpawnZ")
    if isinstance(sx, int) and isinstance(sy, int) and isinstance(sz, int):
        return (sx, sy, sz)
    spawn_entry = data.get("spawn")
    if isinstance(spawn_entry, dict):
        spawn_pos = spawn_entry.get("pos")
        if (
            isinstance(spawn_pos, list)
            and len(spawn_pos) == 3
            and all(isinstance(v, int) for v in spawn_pos)
        ):
            return int(spawn_pos[0]), int(spawn_pos[1]), int(spawn_pos[2])
    return None


def read_structure_nbt(zip_path: Path) -> tuple[list[dict[str, Any]], list[dict[str, Any]]] | None:
    if not zip_path.exists():
        return None
    try:
        with zipfile.ZipFile(zip_path) as archive:
            nbt_path = f"data/{NAMESPACE}/structures/{STRUCTURE_NAME}.nbt"
            if nbt_path not in archive.namelist():
                return None
            raw = gzip.decompress(archive.read(nbt_path))
    except (OSError, zipfile.BadZipFile, OSError):
        return None
    if not raw or raw[0] != TAG_COMPOUND:
        return None
    _, name_end = _read_string(raw, 1)
    root, _cursor = _parse_payload(raw, name_end, TAG_COMPOUND)
    if not isinstance(root, dict):
        return None
    palette = root.get("palette")
    blocks = root.get("blocks")
    if not isinstance(palette, list) or not isinstance(blocks, list):
        return None
    return palette, blocks


def _block_state_string(state: dict[str, Any]) -> str:
    name = str(state.get("Name", "minecraft:air"))
    props = state.get("Properties")
    if not props or not isinstance(props, dict):
        return name
    parts = ",".join(f"{k}={v}" for k, v in sorted(props.items()))
    return f"{name}[{parts}]"


def generate_fill_commands(
    palette: list[dict[str, Any]],
    blocks: list[dict[str, Any]],
    origin: tuple[int, int, int],
) -> list[str]:
    ox, oy, oz = origin
    by_layer: dict[int, list[tuple[int, int, int, int]]] = {}
    for block in blocks:
        pos = block.get("pos")
        state_idx = block.get("state")
        if not isinstance(pos, list) or len(pos) != 3 or not isinstance(state_idx, int):
            continue
        x, y, z = int(pos[0]), int(pos[1]), int(pos[2])
        by_layer.setdefault(y, []).append((x, z, state_idx, y))
    commands: list[str] = []
    for y in sorted(by_layer):
        layer_blocks = by_layer[y]
        by_state: dict[int, list[tuple[int, int]]] = {}
        for x, z, state_idx, _ly in layer_blocks:
            by_state.setdefault(state_idx, []).append((x, z))
        for state_idx in sorted(by_state):
            positions = by_state[state_idx]
            state_str = _block_state_string(palette[state_idx]) if state_idx < len(palette) else "minecraft:air"
            by_z: dict[int, list[int]] = {}
            for x, z in positions:
                by_z.setdefault(z, []).append(x)
            for z in sorted(by_z):
                xs = sorted(by_z[z])
                run_start = xs[0]
                run_end = xs[0]
                for x in xs[1:]:
                    if x == run_end + 1:
                        run_end = x
                    else:
                        wx1, wy, wz1 = ox + run_start, oy + y, oz + z
                        wx2 = ox + run_end
                        commands.append(f"fill {wx1} {wy} {wz1} {wx2} {wy} {wz1} {state_str}")
                        run_start = x
                        run_end = x
                wx1, wy, wz1 = ox + run_start, oy + y, oz + z
                wx2 = ox + run_end
                commands.append(f"fill {wx1} {wy} {wz1} {wx2} {wy} {wz1} {state_str}")
    return commands


def placement_pack(
    origin: tuple[int, int, int],
    spawn: tuple[int, int, int],
    fill_commands: list[str],
) -> dict[str, bytes]:
    ox, oy, oz = origin
    sx, sy, sz = spawn
    min_chunk_x, min_chunk_z, max_chunk_x, max_chunk_z = _forceload_region_for_origin(
        (ox, oy, oz), PLACEMENT_CLEAR_SIZE + 56
    )
    batch_size = 200
    batches = [fill_commands[i : i + batch_size] for i in range(0, len(fill_commands), batch_size)]
    total_batches = len(batches)
    files: dict[str, bytes] = {}
    files["pack.mcmeta"] = (
        '{"pack":{"pack_format":%d,"supported_formats":[%d,%d],'
        '"description":"One-shot Purple House spawn placement."}}\n'
        % (PACK_FORMAT, SUPPORTED_FORMATS[0], SUPPORTED_FORMATS[1])
    ).encode("utf-8")
    for idx, batch in enumerate(batches):
        batch_body = "\n".join(batch).encode("utf-8")
        files[f"data/pummelchen_ops/function/place_batch_{idx}.mcfunction"] = batch_body
        files[f"data/pummelchen_ops/functions/place_batch_{idx}.mcfunction"] = batch_body
    init_lines = [
        "scoreboard objectives add pummelchen_ops dummy",
        f"scoreboard players set {PLACEMENT_STATE_SCORE} pummelchen_ops 0",
        f"scoreboard players set {PLACEMENT_ATTEMPT_SCORE} pummelchen_ops 0",
        f"scoreboard players set {PLACEMENT_STATUS_SCORE} pummelchen_ops 0",
        "",
    ]
    tick_lines: list[str] = []
    tick_lines.append(
        f"execute if score {PLACEMENT_STATE_SCORE} pummelchen_ops matches 0 "
        "run scoreboard players add ph_house_attempt pummelchen_ops 1"
    )
    tick_lines.append(
        f"execute if score {PLACEMENT_STATE_SCORE} pummelchen_ops matches 0 "
        f"if score ph_house_attempt pummelchen_ops matches 1 "
        f"run forceload add {min_chunk_x} {min_chunk_z} {max_chunk_x} {max_chunk_z}"
    )
    for idx in range(total_batches):
        tick_lines.append(
            f"execute if score {PLACEMENT_STATE_SCORE} pummelchen_ops matches 0 "
            f"if score {PLACEMENT_STATUS_SCORE} pummelchen_ops matches {idx} "
            f"run function pummelchen_ops:place_batch_{idx}"
        )
        tick_lines.append(
            f"execute if score {PLACEMENT_STATE_SCORE} pummelchen_ops matches 0 "
            f"if score {PLACEMENT_STATUS_SCORE} pummelchen_ops matches {idx} "
            f"run scoreboard players add {PLACEMENT_STATUS_SCORE} pummelchen_ops 1"
        )
    tick_lines.append(
        f"execute if score {PLACEMENT_STATE_SCORE} pummelchen_ops matches 0 "
        f"if score {PLACEMENT_STATUS_SCORE} pummelchen_ops matches {total_batches}.. "
        f"run setworldspawn {sx} {sy} {sz}"
    )
    tick_lines.append(
        f"execute if score {PLACEMENT_STATE_SCORE} pummelchen_ops matches 0 "
        f"if score {PLACEMENT_STATUS_SCORE} pummelchen_ops matches {total_batches}.. "
        f"run forceload remove {min_chunk_x} {min_chunk_z} {max_chunk_x} {max_chunk_z}"
    )
    tick_lines.append(
        f"execute if score {PLACEMENT_STATE_SCORE} pummelchen_ops matches 0 "
        f"if score {PLACEMENT_STATUS_SCORE} pummelchen_ops matches {total_batches}.. "
        f"run scoreboard players set {PLACEMENT_STATE_SCORE} pummelchen_ops 1"
    )
    tick_lines.append(
        "execute if score ph_house_status pummelchen_ops matches 1 "
        "run say [PUMMELCHEN] Purple House placed and world spawn updated."
    )
    tick_lines.append(
        "execute if score ph_house_status pummelchen_ops matches 0 "
        "run execute if score ph_house_attempt pummelchen_ops matches 600.. "
        "run say [PUMMELCHEN] Purple House placement skipped after retry limit."
    )
    tick_lines.append(
        "execute if score ph_house_status pummelchen_ops matches 0 "
        "run execute if score ph_house_attempt pummelchen_ops matches 600.. "
        f"run scoreboard players set {PLACEMENT_STATE_SCORE} pummelchen_ops 1"
    )
    tick_lines.append("")
    init_body = "\n".join(init_lines).encode("utf-8")
    tick_body = "\n".join(tick_lines).encode("utf-8")
    load_tag = b'{"replace":false,"values":["pummelchen_ops:init_purple_house"]}\n'
    tick_tag = b'{"replace":false,"values":["pummelchen_ops:place_purple_house"]}\n'
    files["data/minecraft/tags/function/load.json"] = load_tag
    files["data/minecraft/tags/function/tick.json"] = tick_tag
    files["data/minecraft/tags/functions/load.json"] = load_tag
    files["data/minecraft/tags/functions/tick.json"] = tick_tag
    files["data/pummelchen_ops/function/init_purple_house.mcfunction"] = init_body
    files["data/pummelchen_ops/functions/init_purple_house.mcfunction"] = init_body
    files["data/pummelchen_ops/function/place_purple_house.mcfunction"] = tick_body
    files["data/pummelchen_ops/functions/place_purple_house.mcfunction"] = tick_body
    return files


def install_datapacks(
    project_dir: Path,
    server_dir: Path,
    world_dir: Path,
    install_place_pack: bool,
    origin: tuple[int, int, int],
    spawn: tuple[int, int, int],
) -> int:
    changed = 0
    server_datapacks = server_dir / "server-datapacks"
    world_datapacks = world_dir / "datapacks"
    world_datapacks.mkdir(parents=True, exist_ok=True)
    for source in datapack_sources(project_dir, server_dir):
        if copy_if_changed(source, server_datapacks / source.name):
            changed += 1
        if copy_if_changed(source, world_datapacks / source.name):
            changed += 1
    if install_place_pack:
        nbt_zip = server_datapacks / PURPLE_HOUSE_ZIP
        if not nbt_zip.exists():
            nbt_zip = project_dir / "server-datapacks" / PURPLE_HOUSE_ZIP
        nbt_data = read_structure_nbt(nbt_zip)
        if nbt_data is None:
            print(f"warning=could_not_read_structure_nbt from {nbt_zip}")
            fill_commands: list[str] = []
        else:
            palette, blocks = nbt_data
            fill_commands = generate_fill_commands(palette, blocks, origin)
            print(f"fill_commands_generated={len(fill_commands)}")
        write_zip(world_datapacks / PLACE_PACK_ZIP, placement_pack(origin, spawn, fill_commands))
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
    parser.add_argument("--place-offset-x", type=int, default=0)
    parser.add_argument("--place-offset-y", type=int, default=0)
    parser.add_argument("--place-offset-z", type=int, default=0)
    parser.add_argument("--rcon-port", type=int, default=25575)
    parser.add_argument("--auto-place", action="store_true", help="rebuild datapack after spawn detection")
    parser.add_argument("--auto-phase-timeout", type=int, default=DEFAULT_BOOT_WAIT)
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
    spawn = (args.spawn_x, args.spawn_y, args.spawn_z)
    origin = (args.origin_x, args.origin_y, args.origin_z)

    print(f"world_name={world_name}")
    print(f"world_seed={seed}")
    print(f"purple_house_origin={origin[0]},{origin[1]},{origin[2]}")
    print(f"spawn={spawn[0]},{spawn[1]},{spawn[2]}")
    print(f"auto_place={int(args.auto_place)}")
    print(f"auto_phase_timeout={args.auto_phase_timeout}")
    print(f"rcon_port={args.rcon_port}")

    if not args.no_restart:
        stop_service(args.service, args.dry_run)
    backup = backup_world(world_dir, server_dir / "world-reset-backups", args.dry_run)
    print(f"world_backup={backup or ''}")

    if args.dry_run:
        print("DRY-RUN write server.properties level-seed and placement datapack")
        print(f"world_dir={world_dir}")
        return 0

    write_properties(server_dir / "server.properties", {"level-name": world_name, "level-seed": seed})

    if args.auto_place:
        # bootstrap world once, detect generated spawn, then place house with RCON.
        if args.no_restart:
            print("warning=auto_place_requires_restart; skipping placement")
            changed = install_datapacks(args.project_dir, server_dir, world_dir, install_place_pack=True, origin=origin, spawn=spawn)
            print(f"datapacks_changed={changed}")
        else:
            install_datapacks(args.project_dir, server_dir, world_dir, install_place_pack=False, origin=origin, spawn=spawn)
            started_at = time.time()
            start_service(args.service, args.dry_run)
            first_done = False if args.dry_run else wait_for_done(args.service, started_at, args.auto_phase_timeout)
            print(f"world_boot_done={int(first_done)}")
            stop_service(args.service, args.dry_run)

            detected = read_level_spawn(world_dir)
            if detected is None:
                print("warning=detected_spawn_missing_falling_back_to_arguments")
                detected = spawn
            else:
                print(f"detected_spawn={detected[0]},{detected[1]},{detected[2]}")
            sx, sy, sz = detected
            spawn = (sx, sy, sz)
            origin = (sx + args.place_offset_x, sy + args.place_offset_y, sz + args.place_offset_z)
            print(f"placement_origin={origin[0]},{origin[1]},{origin[2]}")
            print(f"placement_spawn={spawn[0]},{spawn[1]},{spawn[2]}")

            # Keep original server.properties safe to restore after bootstrap.
            props_path = server_dir / "server.properties"
            restored_contents, changed_rcon, rcon_port = ensure_rcon_enabled(props_path, args.rcon_port, args.dry_run)
            placement_ok = False
            start_service(args.service, args.dry_run)
            second_done = False if args.dry_run else wait_for_done(args.service, time.time(), args.auto_phase_timeout)
            print(f"bootstrap_rcon_boot={int(second_done)}")
            placement_ok = place_house_via_rcon(server_dir, spawn, origin, rcon_port, args.project_dir) if not args.dry_run else False

            # Restore RCON settings to avoid leaving temporary credentials behind.
            if changed_rcon:
                stop_service(args.service, args.dry_run)
                restore_file(props_path, restored_contents)

            if not placement_ok:
                print("warning=placement_via_rcon_failed_falling_back_to_datapack")
                changed = install_datapacks(args.project_dir, server_dir, world_dir, install_place_pack=True, origin=origin, spawn=spawn)
                print(f"datapacks_changed={changed}")
            else:
                print("placement_via_rcon_success=1")
                changed = install_datapacks(args.project_dir, server_dir, world_dir, install_place_pack=False, origin=origin, spawn=spawn)
                print(f"datapacks_changed={changed}")
    else:
        changed = install_datapacks(args.project_dir, server_dir, world_dir, install_place_pack=True, origin=origin, spawn=spawn)
        print(f"datapacks_changed={changed}")

    if not args.no_restart:
        started_at = time.time()
        start_service(args.service, args.dry_run)
        done = False if args.dry_run else wait_for_done(args.service, started_at, args.wait_timeout)
        print(f"server_done_seen={int(done)}")

    print(f"world_dir={world_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
