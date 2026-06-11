#!/usr/bin/env python3
"""Release Health Monitor — server-side agent for client update integrity.

Runs every 5 minutes via cron to verify the client update pipeline is healthy.
Automatically fixes common issues (broken symlinks, stale pointers) and logs
every finding to a status JSON that the dashboard can surface.

Checks performed:
  1. Active release exists in database and is marked tested/deployed
  2. current-release.json matches the active release and is valid
  3. All release symlinks in public/downloads/releases/ resolve correctly
  4. Key artifacts (ZIP, mrpack, DMG, manifest) are HTTP-accessible
  5. SHA256 integrity of active release artifacts matches database records
  6. Minecraft service is running
  7. Broken symlinks are auto-repaired with absolute paths
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import subprocess
import sys
import urllib.request
import urllib.error
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from moddb import connect
from update_activity import log_activity


# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
DEFAULT_DB = Path("/var/minecraft_mods/data/minecraft_mods.sqlite")
DEFAULT_SERVER_DIR = Path("/var/minecraft_26.1.2")
DEFAULT_RELEASE_ROOT = Path("/var/minecraft_mods/releases")
DEFAULT_PUBLIC_DOWNLOADS = Path("/var/minecraft_mods/site/public/downloads")
DEFAULT_SERVER_KEY = "minecraft_26_1_2"
DEFAULT_BASE_URL = "http://127.0.0.1:7788"
DEFAULT_SERVICE = "pummelchen-minecraft.service"
HEALTH_STATUS_PATH = Path("/var/minecraft_mods/site/public/release-health.json")
CLIENT_ZIP_NAME = "minecraft_26.1.2_client_macos_apple_silicon.zip"
MRPACK_NAME = "pummelchen-server-26.1.2.mrpack"
DMG_NAME = "Pummelchen-Client-Installer.dmg"
MANIFEST_NAME = "client-sync-manifest.tsv"


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def http_head(url: str, timeout: float = 5.0) -> tuple[int, str]:
    """Return (status_code, reason) for a HEAD request."""
    req = urllib.request.Request(url, method="HEAD")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.reason
    except urllib.error.HTTPError as exc:
        return exc.code, exc.reason
    except Exception as exc:
        return 0, str(exc)


def now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S+00:00")


def now_human() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")


# ---------------------------------------------------------------------------
# Finding recorder
# ---------------------------------------------------------------------------

class HealthReport:
    """Accumulates findings and writes the final status JSON."""

    def __init__(self) -> None:
        self.findings: list[dict[str, str]] = []
        self.fixes: list[dict[str, str]] = []
        self.ok_count = 0
        self.warn_count = 0
        self.error_count = 0
        self.active_release_id = ""
        self.started = now_iso()

    def ok(self, check: str, detail: str = "") -> None:
        self.findings.append({"level": "ok", "check": check, "detail": detail})
        self.ok_count += 1

    def warn(self, check: str, detail: str) -> None:
        self.findings.append({"level": "warn", "check": check, "detail": detail})
        self.warn_count += 1

    def error(self, check: str, detail: str) -> None:
        self.findings.append({"level": "error", "check": check, "detail": detail})
        self.error_count += 1

    def fixed(self, check: str, detail: str) -> None:
        self.fixes.append({"check": check, "detail": detail})

    def write(self, path: Path) -> str:
        overall = "healthy"
        if self.error_count > 0:
            overall = "degraded"
        elif self.warn_count > 0:
            overall = "warning"

        payload = {
            "checked_at": now_iso(),
            "checked_at_human": now_human(),
            "overall": overall,
            "active_release": self.active_release_id,
            "ok_count": self.ok_count,
            "warn_count": self.warn_count,
            "error_count": self.error_count,
            "fixes_applied": len(self.fixes),
            "fixes": self.fixes,
            "findings": self.findings,
        }
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(".tmp")
        tmp.write_text(json.dumps(payload, indent=2), encoding="utf-8")
        os.replace(str(tmp), str(path))
        return overall


# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------

def check_active_release(report: HealthReport, db_path: Path, server_key: str) -> dict | None:
    """Verify the active release exists in the database."""
    try:
        with connect(db_path) as conn:
            row = conn.execute(
                "SELECT * FROM pack_releases WHERE server_key = ? AND active = 1 "
                "ORDER BY activated_at DESC LIMIT 1",
                (server_key,),
            ).fetchone()
            if not row:
                report.error("active_release", "No active release found in database")
                return None
            rel = dict(row)
            report.active_release_id = rel["release_id"]
            status = rel.get("status", "")
            if status not in ("tested", "deployed"):
                report.warn("active_release_status", f"Active release status is '{status}' (expected tested/deployed)")
            else:
                report.ok("active_release", f"{rel['release_id']} (status={status})")
            return rel
    except Exception as exc:
        report.error("active_release", f"Database error: {exc}")
        return None


def check_current_release_json(
    report: HealthReport,
    public_downloads: Path,
    expected_release_id: str,
) -> None:
    """Verify current-release.json is valid and points to the right release."""
    path = public_downloads / "current-release.json"
    if not path.exists():
        report.error("current_release_json", "File missing")
        return
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        report.error("current_release_json", f"Invalid JSON: {exc}")
        return

    release_id = data.get("release_id", "")
    if release_id != expected_release_id:
        report.error("current_release_json", f"Points to '{release_id}' but active is '{expected_release_id}'")
        return

    for key in ("manifest_url", "client_zip_url", "client_zip_sha256"):
        if not data.get(key):
            report.warn("current_release_json", f"Missing field: {key}")
            return
    report.ok("current_release_json", f"Valid, points to {release_id}")


def check_symlinks(
    report: HealthReport,
    public_downloads: Path,
    release_root: Path,
) -> None:
    """Check all release symlinks resolve correctly; auto-fix broken ones."""
    releases_link_dir = public_downloads / "releases"
    if not releases_link_dir.is_dir():
        report.warn("symlinks_dir", f"Missing: {releases_link_dir}")
        return

    for entry in sorted(releases_link_dir.iterdir()):
        rel_id = entry.name
        if not entry.is_symlink():
            if entry.is_dir():
                report.ok(f"symlink:{rel_id}", "Directory (not symlink)")
            continue

        # Check if symlink resolves
        target = entry.resolve(strict=False)
        if not target.is_dir():
            # Broken symlink — attempt auto-fix
            expected_public = release_root / rel_id / "public"
            if expected_public.is_dir():
                try:
                    entry.unlink()
                    entry.symlink_to(expected_public.resolve(), target_is_directory=True)
                    report.fixed(f"symlink:{rel_id}", f"Repaired → {expected_public.resolve()}")
                    report.ok(f"symlink:{rel_id}", "Fixed: was broken, now points to absolute path")
                    log_activity(
                        f"Health monitor: repaired broken symlink for {rel_id}",
                        stage="health",
                        status="ok",
                    )
                except OSError as exc:
                    report.error(f"symlink:{rel_id}", f"Broken, fix failed: {exc}")
            else:
                report.warn(f"symlink:{rel_id}", f"Broken symlink, target dir missing: {expected_public}")
        else:
            # Verify it actually has the manifest
            manifest = entry / MANIFEST_NAME
            if manifest.exists():
                report.ok(f"symlink:{rel_id}", f"OK → {target}")
            else:
                report.warn(f"symlink:{rel_id}", f"Resolves but missing {MANIFEST_NAME}")


def check_http_artifacts(
    report: HealthReport,
    base_url: str,
    release_id: str,
) -> None:
    """HTTP HEAD check on key downloadable files for the active release."""
    prefix = f"{base_url.rstrip('/')}/downloads/releases/{release_id}"
    targets = [
        ("http_manifest", f"{prefix}/{MANIFEST_NAME}"),
        ("http_client_zip", f"{prefix}/{CLIENT_ZIP_NAME}"),
        ("http_mrpack", f"{prefix}/{MRPACK_NAME}"),
        ("http_dmg", f"{prefix}/{DMG_NAME}"),
    ]
    for label, url in targets:
        code, reason = http_head(url)
        if code == 200:
            report.ok(label, f"HTTP {code}")
        elif code == 404:
            report.error(label, f"HTTP 404 — {url}")
        else:
            report.warn(label, f"HTTP {code} ({reason}) — {url}")


def check_artifact_integrity(
    report: HealthReport,
    db_path: Path,
    release_root: Path,
    release_id: str,
) -> None:
    """Verify SHA256 of active release artifacts against database records."""
    release_dir = release_root / release_id
    artifacts_dir = release_dir / "artifacts"
    if not artifacts_dir.is_dir():
        report.warn("artifact_integrity", f"Artifacts dir missing: {artifacts_dir}")
        return

    try:
        with connect(db_path) as conn:
            # Check main artifacts
            for artifact_name, column in (
                (CLIENT_ZIP_NAME, "client_zip_sha256"),
                (MRPACK_NAME, "mrpack_sha256"),
            ):
                row = conn.execute(
                    "SELECT release_dir, {} as expected FROM pack_releases WHERE release_id = ?".format(column),
                    (release_id,),
                ).fetchone()
                if not row or not row["expected"]:
                    continue
                artifact_path = artifacts_dir / artifact_name
                if not artifact_path.exists():
                    report.error(f"artifact:{artifact_name}", "File missing")
                    continue
                actual = sha256_file(artifact_path)
                if actual != row["expected"]:
                    report.error(f"artifact:{artifact_name}", f"SHA256 mismatch: expected {row['expected'][:16]}… got {actual[:16]}…")
                else:
                    report.ok(f"artifact:{artifact_name}", f"SHA256 verified ({actual[:16]}…)")

            # Check release_artifacts table (DMG, etc.)
            rows = conn.execute(
                "SELECT relative_path, sha256 FROM release_artifacts WHERE release_id = ?",
                (release_id,),
            ).fetchall()
            for row in rows:
                rpath = row["relative_path"]
                expected = row["sha256"]
                artifact_path = release_dir / rpath
                if not expected:
                    continue
                if not artifact_path.exists():
                    report.warn(f"artifact:{Path(rpath).name}", "File missing")
                    continue
                actual = sha256_file(artifact_path)
                if actual != expected:
                    report.warn(f"artifact:{Path(rpath).name}", f"SHA256 drift: expected {expected[:16]}… got {actual[:16]}…")
                else:
                    report.ok(f"artifact:{Path(rpath).name}", f"SHA256 verified ({actual[:16]}…)")
    except Exception as exc:
        report.error("artifact_integrity", f"Database error: {exc}")


def check_minecraft_service(report: HealthReport, service: str) -> None:
    """Check if the Minecraft systemd service is running."""
    try:
        result = subprocess.run(
            ["systemctl", "is-active", service],
            capture_output=True, text=True, timeout=10,
        )
        state = result.stdout.strip()
        if state == "active":
            report.ok("minecraft_service", f"{service} is running")
        else:
            report.error("minecraft_service", f"{service} is '{state}'")
    except Exception as exc:
        report.warn("minecraft_service", f"Could not check: {exc}")


def check_server_dir_sync(
    report: HealthReport,
    server_dir: Path,
    release_root: Path,
    release_id: str,
) -> None:
    """Verify the live server mods directory matches the release snapshot."""
    release_server_files = release_root / release_id / "server-files" / "mods"
    live_mods = server_dir / "mods"
    if not release_server_files.is_dir():
        report.warn("server_sync", "Release server-files/mods snapshot missing")
        return
    if not live_mods.is_dir():
        report.error("server_sync", f"Live mods dir missing: {live_mods}")
        return

    release_jars = {f.name for f in release_server_files.iterdir() if f.suffix in (".jar", ".zip")}
    live_jars = {f.name for f in live_mods.iterdir() if f.suffix in (".jar", ".zip")}

    missing_in_live = sorted(release_jars - live_jars)
    extra_in_live = sorted(live_jars - release_jars)

    if missing_in_live:
        report.error("server_sync", f"{len(missing_in_live)} mod(s) missing from live: {', '.join(missing_in_live[:3])}{'…' if len(missing_in_live) > 3 else ''}")
    elif extra_in_live:
        report.warn("server_sync", f"{len(extra_in_live)} extra mod(s) in live (not in release snapshot)")
    else:
        report.ok("server_sync", f"Live server has all {len(release_jars)} release mods")


def check_dmg_freshness(
    report: HealthReport,
    server_dir: Path,
    release_root: Path,
    release_id: str,
) -> None:
    """Check that the DMG in the server dir matches the release artifact."""
    live_dmg = server_dir / DMG_NAME
    release_dmg = release_root / release_id / "artifacts" / DMG_NAME
    if not live_dmg.exists():
        report.warn("dmg_freshness", f"Live DMG missing: {live_dmg}")
        return
    if not release_dmg.exists():
        report.warn("dmg_freshness", f"Release artifact DMG missing: {release_dmg}")
        return

    live_hash = sha256_file(live_dmg)
    release_hash = sha256_file(release_dmg)
    if live_hash != release_hash:
        report.warn("dmg_freshness", f"Live DMG ({live_hash[:12]}…) differs from release artifact ({release_hash[:12]}…)")
    else:
        report.ok("dmg_freshness", f"DMG in sync ({live_hash[:12]}…)")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def run_monitor(
    *,
    db_path: Path,
    server_dir: Path,
    release_root: Path,
    public_downloads: Path,
    server_key: str,
    base_url: str,
    service: str,
    quiet: bool = False,
) -> int:
    report = HealthReport()

    # 1. Active release
    rel = check_active_release(report, db_path, server_key)
    release_id = rel["release_id"] if rel else ""

    if rel:
        # 2. current-release.json
        check_current_release_json(report, public_downloads, release_id)

        # 3. Symlink health (all releases)
        check_symlinks(report, public_downloads, release_root)

        # 4. HTTP accessibility
        check_http_artifacts(report, base_url, release_id)

        # 5. Artifact integrity
        check_artifact_integrity(report, db_path, release_root, release_id)

        # 6. Minecraft service
        check_minecraft_service(report, service)

        # 7. Server mods in sync
        check_server_dir_sync(report, server_dir, release_root, release_id)

        # 8. DMG freshness
        check_dmg_freshness(report, server_dir, release_root, release_id)

    # Write status
    overall = report.write(HEALTH_STATUS_PATH)

    # Summary
    if not quiet:
        ts = now_human()
        summary = (
            f"[{ts}] Release Health: {overall.upper()} "
            f"— {report.ok_count} ok, {report.warn_count} warn, "
            f"{report.error_count} error, {len(report.fixes)} fix(es)"
        )
        print(summary)
        if report.fixes:
            for fix in report.fixes:
                print(f"  FIXED: [{fix['check']}] {fix['detail']}")
        if report.error_count > 0:
            for f in report.findings:
                if f["level"] == "error":
                    print(f"  ERROR: [{f['check']}] {f['detail']}")

    # Log significant events to activity feed
    if report.fixes:
        log_activity(
            f"Health monitor applied {len(report.fixes)} fix(es)",
            stage="health",
            status="ok",
        )
    if report.error_count > 0:
        log_activity(
            f"Health monitor: {report.error_count} error(s) detected",
            stage="health",
            status="failed",
        )

    return 1 if report.error_count > 0 else 0


def main() -> None:
    parser = argparse.ArgumentParser(description="Release health monitor")
    parser.add_argument("--db", type=Path, default=DEFAULT_DB)
    parser.add_argument("--server-dir", type=Path, default=DEFAULT_SERVER_DIR)
    parser.add_argument("--release-root", type=Path, default=DEFAULT_RELEASE_ROOT)
    parser.add_argument("--public-downloads", type=Path, default=DEFAULT_PUBLIC_DOWNLOADS)
    parser.add_argument("--server-key", default=DEFAULT_SERVER_KEY)
    parser.add_argument("--base-url", default=DEFAULT_BASE_URL)
    parser.add_argument("--service", default=DEFAULT_SERVICE)
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args()

    sys.exit(run_monitor(
        db_path=args.db,
        server_dir=args.server_dir,
        release_root=args.release_root,
        public_downloads=args.public_downloads,
        server_key=args.server_key,
        base_url=args.base_url,
        service=args.service,
        quiet=args.quiet,
    ))


if __name__ == "__main__":
    main()
