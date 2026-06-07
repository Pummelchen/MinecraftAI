#!/usr/bin/env python3
"""Mirror release server/client mod contents into a local Backup directory."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import re
import subprocess
from pathlib import Path
from typing import Sequence


DEFAULT_RELEASE_ROOT = "/var/minecraft_mods/releases"
DEFAULT_OUTPUT = Path("Backup")


def display_release_version(release_id: str) -> str:
    value = (release_id or "").strip()
    match = re.fullmatch(r"release_(\d{4})(\d{2})(\d{2})_([^_]+)(?:_.*)?", value)
    if match:
        year, month, day, version = match.groups()
        if version_match := re.match(r"(V\d+)", version, re.IGNORECASE):
            version = version_match.group(1).upper()
        return f"{year}-{month}-{day}_{version}"
    return re.sub(r"[^A-Za-z0-9_.-]+", "_", value).strip("_") or "unknown_release"


def ssh_base(remote: str, control_path: str | None) -> list[str]:
    cmd = ["ssh", "-o", "BatchMode=yes"]
    if control_path:
        cmd.extend(["-o", f"ControlPath={control_path}"])
    cmd.append(remote)
    return cmd


def rsync_remote_arg(remote: str | None, path: str) -> str:
    return f"{remote}:{path}" if remote else path


def list_releases(release_root: str, remote: str | None, control_path: str | None) -> list[str]:
    if remote:
        cmd = ssh_base(remote, control_path) + [
            f"find {quote_shell(release_root)} -mindepth 1 -maxdepth 1 -type d -printf '%f\\n' | sort"
        ]
        output = subprocess.check_output(cmd, text=True)
        return [line.strip() for line in output.splitlines() if line.strip()]
    root = Path(release_root)
    return sorted(path.name for path in root.iterdir() if path.is_dir()) if root.exists() else []


def quote_shell(value: str) -> str:
    return "'" + value.replace("'", "'\"'\"'") + "'"


def rsync_copy(src: str, dst: Path, *, remote: str | None, control_path: str | None, dry_run: bool) -> None:
    dst.mkdir(parents=True, exist_ok=True)
    cmd = ["rsync", "-a", "--delete"]
    if dry_run:
        cmd.append("--dry-run")
    if remote and control_path:
        cmd.extend(["-e", f"ssh -o BatchMode=yes -o ControlPath={control_path}"])
    cmd.extend([rsync_remote_arg(remote, src.rstrip("/") + "/"), str(dst) + "/"])
    subprocess.run(cmd, check=True)


def backup_release(
    release_id: str,
    *,
    release_root: str,
    output_dir: Path,
    remote: str | None,
    control_path: str | None,
    dry_run: bool,
) -> Path:
    label = display_release_version(release_id)
    target = output_dir / label
    release_path = f"{release_root.rstrip('/')}/{release_id}"
    rsync_copy(f"{release_path}/server-files", target / "server-files", remote=remote, control_path=control_path, dry_run=dry_run)
    rsync_copy(f"{release_path}/client-package", target / "client-package", remote=remote, control_path=control_path, dry_run=dry_run)
    metadata = {
        "release_id": release_id,
        "label": label,
        "source": rsync_remote_arg(remote, release_path),
        "backed_up_at": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
        "contents": ["server-files", "client-package"],
    }
    if not dry_run:
        (target / "release-backup.json").write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"backup_release={release_id}\tlabel={label}\tdestination={target}\tdry_run={1 if dry_run else 0}")
    return target


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--release-root", default=DEFAULT_RELEASE_ROOT)
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--remote", help="Optional ssh target, for example root@91.99.176.243.")
    parser.add_argument("--ssh-control-path")
    parser.add_argument("--release-id", action="append", help="Back up only this release id. Repeatable.")
    parser.add_argument("--dry-run", action="store_true")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    release_ids = args.release_id or list_releases(args.release_root, args.remote, args.ssh_control_path)
    if not release_ids:
        raise SystemExit("no releases found")
    args.output_dir.mkdir(parents=True, exist_ok=True)
    for release_id in release_ids:
        backup_release(
            release_id,
            release_root=args.release_root,
            output_dir=args.output_dir,
            remote=args.remote,
            control_path=args.ssh_control_path,
            dry_run=args.dry_run,
        )
    print(f"release_backups={len(release_ids)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
