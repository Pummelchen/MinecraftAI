#!/usr/bin/env python3
"""Receive Pummelchen client diagnostic bundles from macOS clients."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import re
import secrets
import shutil
import sqlite3
import tempfile
import urllib.parse
import zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any


DEFAULT_DB = Path("/var/minecraft_mods/data/minecraft_mods.sqlite")
DEFAULT_UPLOAD_DIR = Path("/var/minecraft_mods/client_log_uploads")
DEFAULT_TOKEN_FILE = Path("/var/minecraft_mods/secrets/client-log-upload.token")
DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 7791
MAX_UPLOAD_BYTES = 25 * 1024 * 1024
MAX_INSTALLER_EVENT_BYTES = 96 * 1024
REQUEST_TIMEOUT_SECONDS = 35
TERMINAL_SESSION_STATUSES = {"ok", "failed", "cancelled"}


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")


def safe_name(value: str, fallback: str) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9_.-]+", "_", value.strip())
    cleaned = cleaned.strip("._")
    return cleaned[:120] or fallback


def clean_text(value: Any, limit: int) -> str:
    text = str(value or "").replace("\x00", "")
    text = text.replace("\r\n", "\n").replace("\r", "\n").strip()
    return text[:limit]


def parse_int(value: Any) -> int | None:
    try:
        if value is None or str(value).strip() == "":
            return None
        return int(str(value).strip())
    except ValueError:
        return None


def session_status_for_event(event_type: str, status: str) -> str:
    event_type = event_type.lower()
    status = status.lower()
    if status in TERMINAL_SESSION_STATUSES:
        return status
    if event_type in {"completed", "app_finished"}:
        return "ok"
    if event_type in {"failed", "script_launch_failed", "script_missing"}:
        return "failed"
    if event_type == "cancelled":
        return "cancelled"
    return "running"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def ensure_token(path: Path) -> str:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        return path.read_text(encoding="utf-8").strip()
    token = secrets.token_urlsafe(32)
    path.write_text(token + "\n", encoding="utf-8")
    path.chmod(0o600)
    return token


def init_db(db_path: Path) -> None:
    db_path.parent.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(db_path) as conn:
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS client_log_uploads (
                id INTEGER PRIMARY KEY,
                uploaded_at TEXT NOT NULL,
                client_id TEXT NOT NULL,
                remote_addr TEXT,
                file_name TEXT NOT NULL,
                stored_path TEXT NOT NULL,
                size_bytes INTEGER NOT NULL,
                sha256 TEXT NOT NULL,
                pack_sha256 TEXT,
                minecraft_version TEXT,
                os_summary TEXT,
                java_summary TEXT,
                crash_headline TEXT,
                notes TEXT
            )
            """
        )
        conn.execute("CREATE INDEX IF NOT EXISTS idx_client_log_uploads_uploaded ON client_log_uploads(uploaded_at)")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_client_log_uploads_client ON client_log_uploads(client_id)")
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS client_installer_sessions (
                session_id TEXT PRIMARY KEY,
                client_id TEXT,
                first_seen_at TEXT NOT NULL,
                last_seen_at TEXT NOT NULL,
                completed_at TEXT,
                status TEXT NOT NULL,
                installer_version TEXT,
                app_version TEXT,
                release_id TEXT,
                minecraft_version TEXT,
                os_summary TEXT,
                arch TEXT,
                remote_addr TEXT,
                user_agent TEXT,
                local_log_path TEXT,
                latest_step INTEGER,
                total_steps INTEGER,
                event_count INTEGER NOT NULL DEFAULT 0,
                latest_message TEXT,
                notes TEXT
            )
            """
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS client_installer_events (
                id INTEGER PRIMARY KEY,
                session_id TEXT NOT NULL REFERENCES client_installer_sessions(session_id) ON DELETE CASCADE,
                received_at TEXT NOT NULL,
                event_at TEXT,
                event_type TEXT NOT NULL,
                severity TEXT NOT NULL,
                status TEXT,
                step_current INTEGER,
                step_total INTEGER,
                message TEXT,
                detail TEXT,
                release_id TEXT,
                minecraft_version TEXT,
                local_log_path TEXT,
                log_excerpt TEXT,
                authenticated INTEGER NOT NULL DEFAULT 0,
                remote_addr TEXT,
                user_agent TEXT
            )
            """
        )
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_client_installer_sessions_status ON client_installer_sessions(status, first_seen_at)"
        )
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_client_installer_events_session ON client_installer_events(session_id, received_at)"
        )
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_client_installer_events_type ON client_installer_events(event_type, received_at)"
        )


def read_zip_text(archive_path: Path, candidates: tuple[str, ...], max_bytes: int = 64_000) -> str:
    try:
        with zipfile.ZipFile(archive_path) as archive:
            names = archive.namelist()
            name_set = set(names)
            for candidate in candidates:
                if candidate in name_set:
                    with archive.open(candidate) as handle:
                        return handle.read(max_bytes).decode("utf-8", errors="replace")
            for name in names:
                if any(name.endswith(f"/{candidate}") for candidate in candidates):
                    with archive.open(name) as handle:
                        return handle.read(max_bytes).decode("utf-8", errors="replace")
    except Exception:
        return ""
    return ""


def metadata_from_zip(archive_path: Path) -> dict[str, str]:
    summary = read_zip_text(archive_path, ("summary.txt", "diagnostics/summary.txt"))
    crash = read_zip_text(archive_path, ("crash-headline.txt", "diagnostics/crash-headline.txt"), max_bytes=8_000)
    values: dict[str, str] = {}
    for line in summary.splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip()
    if crash.strip():
        values["crash_headline"] = crash.strip().splitlines()[0][:500]
    return values


class UploadHandler(BaseHTTPRequestHandler):
    server_version = "PummelchenClientLogReceiver/1.0"

    def setup(self) -> None:
        super().setup()
        self.connection.settimeout(REQUEST_TIMEOUT_SECONDS)

    def log_message(self, fmt: str, *args: Any) -> None:
        return

    def send_json(self, status: int, payload: dict[str, Any]) -> None:
        body = json.dumps(payload, sort_keys=True).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        if self.path == "/health":
            self.send_json(200, {"ok": True})
            return
        self.send_json(404, {"ok": False, "error": "not_found"})

    def do_POST(self) -> None:
        if self.path in {"/installer-event", "/client-logs/installer-event"}:
            self.handle_installer_event()
            return

        if self.path not in {"/upload", "/client-logs/upload"}:
            self.send_json(404, {"ok": False, "error": "not_found"})
            return

        token = self.headers.get("X-Pummelchen-Upload-Token", "")
        if not secrets.compare_digest(token, self.server.upload_token):
            self.send_json(403, {"ok": False, "error": "forbidden"})
            return

        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self.send_json(411, {"ok": False, "error": "missing_length"})
            return
        if length <= 0:
            self.send_json(400, {"ok": False, "error": "empty_upload"})
            return
        if length > self.server.max_upload_bytes:
            self.send_json(413, {"ok": False, "error": "too_large"})
            return

        client_id = safe_name(self.headers.get("X-Pummelchen-Client-Id", ""), "unknown-client")
        original_name = safe_name(self.headers.get("X-Pummelchen-Filename", ""), "pummelchen-client-logs.zip")
        if not original_name.endswith(".zip"):
            original_name += ".zip"

        now = dt.datetime.now(dt.timezone.utc)
        day_dir = self.server.upload_dir / now.strftime("%Y") / now.strftime("%m") / now.strftime("%d")
        day_dir.mkdir(parents=True, exist_ok=True)
        stored_name = f"{now.strftime('%Y%m%dT%H%M%SZ')}_{client_id}_{original_name}"
        final_path = day_dir / stored_name

        temp_path: Path | None = None
        try:
            with tempfile.NamedTemporaryFile(dir=day_dir, prefix=".upload-", delete=False) as tmp:
                temp_path = Path(tmp.name)
                remaining = length
                while remaining > 0:
                    chunk = self.rfile.read(min(1024 * 1024, remaining))
                    if not chunk:
                        temp_path.unlink(missing_ok=True)
                        self.send_json(400, {"ok": False, "error": "truncated_upload"})
                        return
                    tmp.write(chunk)
                    remaining -= len(chunk)
        except (OSError, TimeoutError):
            if temp_path:
                temp_path.unlink(missing_ok=True)
            self.send_json(408, {"ok": False, "error": "upload_timeout"})
            return

        if not zipfile.is_zipfile(temp_path):
            temp_path.unlink(missing_ok=True)
            self.send_json(400, {"ok": False, "error": "not_zip"})
            return

        digest = sha256_file(temp_path)
        shutil.move(str(temp_path), final_path)
        final_path.chmod(0o640)

        meta = metadata_from_zip(final_path)
        remote_addr = self.headers.get("X-Real-IP") or self.client_address[0]
        with sqlite3.connect(self.server.db_path) as conn:
            cursor = conn.execute(
                """
                INSERT INTO client_log_uploads(
                    uploaded_at, client_id, remote_addr, file_name, stored_path,
                    size_bytes, sha256, pack_sha256, minecraft_version,
                    os_summary, java_summary, crash_headline, notes
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    utc_now(),
                    client_id,
                    remote_addr,
                    original_name,
                    str(final_path),
                    final_path.stat().st_size,
                    digest,
                    self.headers.get("X-Pummelchen-Pack-Sha", "") or meta.get("pack_sha256", ""),
                    meta.get("minecraft_version", ""),
                    meta.get("os", ""),
                    meta.get("java", ""),
                    meta.get("crash_headline", ""),
                    meta.get("notes", ""),
                ),
            )
            upload_id = int(cursor.lastrowid)

        self.send_json(
            200,
            {
                "ok": True,
                "id": upload_id,
                "sha256": digest,
                "stored": stored_name,
                "size_bytes": final_path.stat().st_size,
            },
        )

    def read_event_fields(self, length: int) -> dict[str, str]:
        raw = self.rfile.read(length)
        content_type = self.headers.get("Content-Type", "").split(";", 1)[0].strip().lower()
        if content_type == "application/json":
            payload = json.loads(raw.decode("utf-8", errors="replace"))
            if not isinstance(payload, dict):
                raise ValueError("json body must be an object")
            return {str(key): str(value) for key, value in payload.items() if value is not None}

        parsed = urllib.parse.parse_qs(raw.decode("utf-8", errors="replace"), keep_blank_values=True)
        return {key: values[-1] if values else "" for key, values in parsed.items()}

    def handle_installer_event(self) -> None:
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self.send_json(411, {"ok": False, "error": "missing_length"})
            return
        if length <= 0:
            self.send_json(400, {"ok": False, "error": "empty_event"})
            return
        if length > self.server.max_event_bytes:
            self.send_json(413, {"ok": False, "error": "event_too_large"})
            return

        try:
            fields = self.read_event_fields(length)
        except (json.JSONDecodeError, UnicodeDecodeError, ValueError):
            self.send_json(400, {"ok": False, "error": "bad_event_body"})
            return

        session_id = safe_name(fields.get("session_id", ""), "")
        if not session_id:
            self.send_json(400, {"ok": False, "error": "missing_session_id"})
            return

        received_at = utc_now()
        event_type = safe_name(fields.get("event_type", ""), "event")[:80]
        severity = clean_text(fields.get("severity", "info"), 20).lower() or "info"
        if severity not in {"debug", "info", "warning", "error"}:
            severity = "info"
        status = clean_text(fields.get("status", ""), 30).lower()
        session_status = session_status_for_event(event_type, status)
        completed_at = received_at if session_status in TERMINAL_SESSION_STATUSES else None
        authenticated = int(secrets.compare_digest(self.headers.get("X-Pummelchen-Upload-Token", ""), self.server.upload_token))
        remote_addr = self.headers.get("X-Real-IP") or self.client_address[0]
        user_agent = clean_text(self.headers.get("User-Agent", ""), 300)

        step_current = parse_int(fields.get("step_current"))
        step_total = parse_int(fields.get("step_total"))
        message = clean_text(fields.get("message", ""), 2_000)
        detail = clean_text(fields.get("detail", ""), 4_000)
        log_excerpt = clean_text(fields.get("log_excerpt", ""), 32_000)
        local_log_path = clean_text(fields.get("local_log_path", ""), 1_000)
        client_id = safe_name(fields.get("client_id", ""), "")
        installer_version = clean_text(fields.get("installer_version", ""), 80)
        app_version = clean_text(fields.get("app_version", ""), 80)
        release_id = clean_text(fields.get("release_id", ""), 160)
        minecraft_version = clean_text(fields.get("minecraft_version", ""), 80)
        os_summary = clean_text(fields.get("os", ""), 300)
        arch = clean_text(fields.get("arch", ""), 40)
        event_at = clean_text(fields.get("event_at", ""), 80)

        with sqlite3.connect(self.server.db_path) as conn:
            conn.execute("PRAGMA foreign_keys = ON")
            conn.execute(
                """
                INSERT INTO client_installer_sessions(
                    session_id, client_id, first_seen_at, last_seen_at, completed_at,
                    status, installer_version, app_version, release_id,
                    minecraft_version, os_summary, arch, remote_addr, user_agent,
                    local_log_path, latest_step, total_steps, event_count,
                    latest_message, notes
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?)
                ON CONFLICT(session_id) DO UPDATE SET
                    client_id = COALESCE(NULLIF(excluded.client_id, ''), client_installer_sessions.client_id),
                    last_seen_at = excluded.last_seen_at,
                    completed_at = CASE
                        WHEN excluded.completed_at IS NOT NULL THEN excluded.completed_at
                        ELSE client_installer_sessions.completed_at
                    END,
                    status = CASE
                        WHEN excluded.status IN ('ok', 'failed', 'cancelled') THEN excluded.status
                        WHEN client_installer_sessions.status IN ('ok', 'failed', 'cancelled') THEN client_installer_sessions.status
                        ELSE excluded.status
                    END,
                    installer_version = COALESCE(NULLIF(excluded.installer_version, ''), client_installer_sessions.installer_version),
                    app_version = COALESCE(NULLIF(excluded.app_version, ''), client_installer_sessions.app_version),
                    release_id = COALESCE(NULLIF(excluded.release_id, ''), client_installer_sessions.release_id),
                    minecraft_version = COALESCE(NULLIF(excluded.minecraft_version, ''), client_installer_sessions.minecraft_version),
                    os_summary = COALESCE(NULLIF(excluded.os_summary, ''), client_installer_sessions.os_summary),
                    arch = COALESCE(NULLIF(excluded.arch, ''), client_installer_sessions.arch),
                    remote_addr = COALESCE(NULLIF(excluded.remote_addr, ''), client_installer_sessions.remote_addr),
                    user_agent = COALESCE(NULLIF(excluded.user_agent, ''), client_installer_sessions.user_agent),
                    local_log_path = COALESCE(NULLIF(excluded.local_log_path, ''), client_installer_sessions.local_log_path),
                    latest_step = COALESCE(excluded.latest_step, client_installer_sessions.latest_step),
                    total_steps = COALESCE(excluded.total_steps, client_installer_sessions.total_steps),
                    event_count = client_installer_sessions.event_count + 1,
                    latest_message = COALESCE(NULLIF(excluded.latest_message, ''), client_installer_sessions.latest_message)
                """,
                (
                    session_id,
                    client_id,
                    received_at,
                    received_at,
                    completed_at,
                    session_status,
                    installer_version,
                    app_version,
                    release_id,
                    minecraft_version,
                    os_summary,
                    arch,
                    remote_addr,
                    user_agent,
                    local_log_path,
                    step_current,
                    step_total,
                    message,
                    "",
                ),
            )
            cursor = conn.execute(
                """
                INSERT INTO client_installer_events(
                    session_id, received_at, event_at, event_type, severity, status,
                    step_current, step_total, message, detail, release_id,
                    minecraft_version, local_log_path, log_excerpt, authenticated,
                    remote_addr, user_agent
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    session_id,
                    received_at,
                    event_at,
                    event_type,
                    severity,
                    session_status,
                    step_current,
                    step_total,
                    message,
                    detail,
                    release_id,
                    minecraft_version,
                    local_log_path,
                    log_excerpt,
                    authenticated,
                    remote_addr,
                    user_agent,
                ),
            )
            event_id = int(cursor.lastrowid)

        self.send_json(
            200,
            {
                "ok": True,
                "event_id": event_id,
                "session_id": session_id,
                "session_status": session_status,
                "received_at": received_at,
            },
        )


class UploadServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(
        self,
        server_address: tuple[str, int],
        handler_class: type[BaseHTTPRequestHandler],
        *,
        db_path: Path,
        upload_dir: Path,
        upload_token: str,
        max_upload_bytes: int,
        max_event_bytes: int,
    ) -> None:
        super().__init__(server_address, handler_class)
        self.db_path = db_path
        self.upload_dir = upload_dir
        self.upload_token = upload_token
        self.max_upload_bytes = max_upload_bytes
        self.max_event_bytes = max_event_bytes


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", type=Path, default=DEFAULT_DB)
    parser.add_argument("--upload-dir", type=Path, default=DEFAULT_UPLOAD_DIR)
    parser.add_argument("--token-file", type=Path, default=DEFAULT_TOKEN_FILE)
    parser.add_argument("--host", default=DEFAULT_HOST)
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--max-mb", type=int, default=25)
    parser.add_argument("--max-event-kb", type=int, default=MAX_INSTALLER_EVENT_BYTES // 1024)
    parser.add_argument("--print-token", action="store_true")
    return parser


def main() -> None:
    args = build_parser().parse_args()
    token = ensure_token(args.token_file)
    if args.print_token:
        print(token)
        return

    init_db(args.db)
    args.upload_dir.mkdir(parents=True, exist_ok=True)
    server = UploadServer(
        (args.host, args.port),
        UploadHandler,
        db_path=args.db,
        upload_dir=args.upload_dir,
        upload_token=token,
        max_upload_bytes=args.max_mb * 1024 * 1024,
        max_event_bytes=args.max_event_kb * 1024,
    )
    print(f"client_log_receiver listening on {args.host}:{args.port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
