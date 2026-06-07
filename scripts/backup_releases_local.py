#!/usr/bin/env python3
"""Mirror release server/client mod contents into flat local Backup ZIP files."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import re
import subprocess
import tempfile
import zipfile
from pathlib import Path
from typing import Sequence


DEFAULT_RELEASE_ROOT = "/var/minecraft_mods/releases"
DEFAULT_OUTPUT = Path("Backup")
DEFAULT_MINECRAFT_VERSION = "26.1.2"
VERSION_LABEL_RE = re.compile(r"^\d{4}-\d{2}-\d{2}_V\d+$")


def release_backup_label(release_id: str) -> str | None:
    value = (release_id or "").strip()
    if VERSION_LABEL_RE.fullmatch(value):
        return value
    match = re.fullmatch(r"release_(\d{4})(\d{2})(\d{2})_(V\d+)(?:[A-Z])?(?:_.*)?", value, re.IGNORECASE)
    if match:
        year, month, day, version = match.groups()
        return f"{year}-{month}-{day}_{version.upper()}"
    return None


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


def zip_tree(source: Path, zip_path: Path, root_name: str) -> None:
    if zip_path.exists():
        zip_path.unlink()
    with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        for path in sorted(source.rglob("*")):
            rel = path.relative_to(source)
            arcname = Path(root_name) / rel
            try:
                stat = path.stat()
            except OSError:
                continue
            mode = stat.st_mode & 0o777
            if path.is_dir():
                info = zipfile.ZipInfo(str(arcname).rstrip("/") + "/")
                info.date_time = dt.datetime.fromtimestamp(stat.st_mtime).timetuple()[:6]
                info.filename = info.filename.rstrip("/") + "/"
                info.external_attr = (mode or 0o755) << 16
                archive.writestr(info, b"")
            elif path.is_file():
                archive.write(path, str(arcname))


def write_metadata(path: Path, *, release_id: str, label: str, source: str, contents: list[str]) -> None:
    payload = {
        "release_id": release_id,
        "label": label,
        "source": source,
        "backed_up_at": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
        "contents": contents,
    }
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def backup_release(
    release_id: str,
    *,
    release_root: str,
    output_dir: Path,
    minecraft_version: str,
    remote: str | None,
    control_path: str | None,
    dry_run: bool,
) -> tuple[Path, Path]:
    label = release_backup_label(release_id)
    if label is None:
        raise SystemExit(f"release id does not map to YYYY-MM-DD_VN: {release_id}")
    client_zip = output_dir / f"Client_{label}.zip"
    server_zip = output_dir / f"Server_{minecraft_version}_{label}.zip"
    release_path = f"{release_root.rstrip('/')}/{release_id}"
    if dry_run:
        print(
            f"backup_release={release_id}\tlabel={label}"
            f"\tclient_zip={client_zip}\tserver_zip={server_zip}\tdry_run=1"
        )
        return client_zip, server_zip

    with tempfile.TemporaryDirectory(prefix=".backup-stage-", dir=output_dir) as raw_tmp:
        stage = Path(raw_tmp) / label
        server_stage = stage / "server-files"
        client_stage = stage / "client-package"
        rsync_copy(f"{release_path}/server-files", server_stage, remote=remote, control_path=control_path, dry_run=False)
        rsync_copy(f"{release_path}/client-package", client_stage, remote=remote, control_path=control_path, dry_run=False)
        source = rsync_remote_arg(remote, release_path)
        write_metadata(server_stage / "release-backup.json", release_id=release_id, label=label, source=source, contents=["server-files"])
        write_metadata(client_stage / "release-backup.json", release_id=release_id, label=label, source=source, contents=["client-package"])
        zip_tree(server_stage, server_zip, "server-files")
        zip_tree(client_stage, client_zip, "client-package")
    print(
        f"backup_release={release_id}\tlabel={label}"
        f"\tclient_zip={client_zip}\tserver_zip={server_zip}\tdry_run=0"
    )
    return client_zip, server_zip


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--release-root", default=DEFAULT_RELEASE_ROOT)
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--minecraft-version", default=DEFAULT_MINECRAFT_VERSION)
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
    versioned_release_ids = []
    for release_id in release_ids:
        if release_backup_label(release_id):
            versioned_release_ids.append(release_id)
        elif args.release_id:
            raise SystemExit(f"release id does not map to YYYY-MM-DD_VN: {release_id}")
        else:
            print(f"skip_release={release_id}\treason=non_version_label")
    if not versioned_release_ids:
        raise SystemExit("no version-style releases found")
    args.output_dir.mkdir(parents=True, exist_ok=True)
    for release_id in versioned_release_ids:
        backup_release(
            release_id,
            release_root=args.release_root,
            output_dir=args.output_dir,
            minecraft_version=args.minecraft_version,
            remote=args.remote,
            control_path=args.ssh_control_path,
            dry_run=args.dry_run,
        )
    print(f"release_backups={len(versioned_release_ids)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
