#!/usr/bin/env python3

import gzip
import json
import os
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
CADDY_DIRECTORY = REPOSITORY_ROOT / "Server App" / "caddy"


def free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


class UpstreamHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    upstream_name = "unknown"

    def do_GET(self):
        self.respond()

    def do_POST(self):
        self.respond()

    def respond(self):
        content_length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(content_length)
        response = json.dumps(
            {
                "upstream": self.upstream_name,
                "method": self.command,
                "path": self.path,
                "body_size": len(body),
                "host": self.headers.get("Host"),
                "x_forwarded_for": self.headers.get("X-Forwarded-For"),
                "x_forwarded_proto": self.headers.get("X-Forwarded-Proto"),
                "x_real_ip": self.headers.get("X-Real-IP"),
            }
        ).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(response)))
        self.send_header("Connection", "close")
        self.end_headers()
        try:
            self.wfile.write(response)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, _format, *_args):
        return


def upstream_server(name):
    handler = type(
        f"UpstreamHandler_{name.replace('.', '_')}",
        (UpstreamHandler,),
        {"upstream_name": name},
    )
    server = ThreadingHTTPServer(("127.0.0.1", free_port()), handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server


class CaddyEdgeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.caddy_bin = os.environ.get("CADDY_BIN") or shutil.which("caddy")
        if not cls.caddy_bin:
            raise RuntimeError("set CADDY_BIN or install caddy before running edge tests")

        cls.temp_directory = tempfile.TemporaryDirectory(prefix="minecraftai-caddy-test-")
        cls.temp_root = Path(cls.temp_directory.name)
        cls.site_root = cls.temp_root / "site"
        (cls.site_root / "downloads" / "releases" / "release-test").mkdir(
            parents=True
        )

        (cls.site_root / "index.html").write_text("PUMMELCHEN SPA", encoding="utf-8")
        (cls.site_root / "app.js").write_text("const value = 'edge-test';\n" * 200, encoding="utf-8")
        (cls.site_root / "secret.duckdb").write_text("private", encoding="utf-8")
        (cls.site_root / "backup-config.json").write_text("private", encoding="utf-8")
        (cls.site_root / "downloads" / "current-release.json").write_text(
            '{"release_id":"release-test"}', encoding="utf-8"
        )
        (cls.site_root / "downloads" / "current-release-26.3.json").write_text(
            '{"release_id":"release-test"}', encoding="utf-8"
        )
        cls.release_bytes = b"immutable-release-artifact"
        (cls.site_root / "downloads" / "releases" / "release-test" / "client.zip").write_bytes(
            cls.release_bytes
        )
        (cls.site_root / "downloads" / "latest.zip").write_bytes(b"mutable-alias")

        cls.upstreams = {
            "26.1.2": upstream_server("26.1.2"),
            "26.2": upstream_server("26.2"),
            "26.3": upstream_server("26.3"),
        }
        cls.edge_port = free_port()
        cls.config_path = cls.temp_root / "Caddyfile"
        cls.config_path.write_text(
            "\n".join(
                [
                    "{",
                    "\tadmin off",
                    "\tauto_https off",
                    "}",
                    f'import "{CADDY_DIRECTORY / "PummelchenRoutes.caddy"}"',
                    f"http://127.0.0.1:{cls.edge_port} {{",
                    "\timport pummelchen_routes",
                    "}",
                    "",
                ]
            ),
            encoding="utf-8",
        )

        cls.caddy_environment = os.environ.copy()
        cls.caddy_environment.update(
            {
                "PUMMELCHEN_SITE_ROOT": str(cls.site_root),
                "PUMMELCHEN_API_26_1_2": cls.upstream_address("26.1.2"),
                "PUMMELCHEN_API_26_2": cls.upstream_address("26.2"),
                "PUMMELCHEN_API_26_3": cls.upstream_address("26.3"),
            }
        )

        validation = subprocess.run(
            [cls.caddy_bin, "validate", "--config", str(cls.config_path)],
            cwd=REPOSITORY_ROOT,
            env=cls.caddy_environment,
            capture_output=True,
            text=True,
            timeout=10,
        )
        if validation.returncode != 0:
            raise RuntimeError(
                f"Caddy test configuration failed validation:\n{validation.stderr}"
            )

        cls.caddy_process = subprocess.Popen(
            [cls.caddy_bin, "run", "--config", str(cls.config_path)],
            cwd=REPOSITORY_ROOT,
            env=cls.caddy_environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        cls.wait_for_edge()

    @classmethod
    def upstream_address(cls, version):
        host, port = cls.upstreams[version].server_address
        return f"{host}:{port}"

    @classmethod
    def wait_for_edge(cls):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if cls.caddy_process.poll() is not None:
                output = cls.caddy_process.stdout.read()
                raise RuntimeError(f"Caddy exited during startup:\n{output}")
            try:
                with socket.create_connection(("127.0.0.1", cls.edge_port), timeout=0.2):
                    return
            except OSError:
                time.sleep(0.05)
        raise RuntimeError("Caddy did not accept connections within 10 seconds")

    @classmethod
    def tearDownClass(cls):
        if hasattr(cls, "caddy_process") and cls.caddy_process.poll() is None:
            cls.caddy_process.terminate()
            try:
                cls.caddy_process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                cls.caddy_process.kill()
                cls.caddy_process.wait(timeout=5)
        if hasattr(cls, "caddy_process") and cls.caddy_process.stdout:
            cls.caddy_process.stdout.close()
        for server in getattr(cls, "upstreams", {}).values():
            server.shutdown()
            server.server_close()
        if hasattr(cls, "temp_directory"):
            cls.temp_directory.cleanup()

    def request(self, path, method="GET", body=None, headers=None):
        request = urllib.request.Request(
            f"http://127.0.0.1:{self.edge_port}{path}",
            data=body,
            headers=headers or {},
            method=method,
        )
        try:
            with urllib.request.urlopen(request, timeout=5) as response:
                return response.status, response.headers, response.read()
        except urllib.error.HTTPError as error:
            try:
                return error.code, error.headers, error.read()
            finally:
                error.close()

    def request_json(self, path, method="GET", body=None, headers=None):
        status, response_headers, response_body = self.request(
            path, method=method, body=body, headers=headers
        )
        return status, response_headers, json.loads(response_body)

    def test_versioned_and_unversioned_api_routing(self):
        cases = [
            ("/api/26.1.2/v1/status?probe=one", "26.1.2", "/api/v1/status?probe=one"),
            ("/api/26.2/v1/status", "26.2", "/api/v1/status"),
            ("/api/26.3/v1/status", "26.3", "/api/v1/status"),
            ("/api/v1/status", "26.1.2", "/api/v1/status"),
        ]
        for path, expected_upstream, expected_path in cases:
            with self.subTest(path=path):
                status, headers, response = self.request_json(path)
                self.assertEqual(status, 200)
                self.assertEqual(response["upstream"], expected_upstream)
                self.assertEqual(response["path"], expected_path)
                self.assertEqual(headers["Cache-Control"], "no-store, max-age=0")

    def test_legacy_json_aliases_use_primary_api(self):
        cases = {
            "/live-stats.json": "/api/v1/site/live-stats",
            "/update-activity.json": "/api/v1/site/update-activity",
            "/neoforge-version.json": "/api/v1/site/neoforge-version",
            "/release-health.json": "/api/v1/site/release-health",
            "/server-versions.json": "/api/v1/minecraft/server-versions",
        }
        for public_path, upstream_path in cases.items():
            with self.subTest(path=public_path):
                status, headers, response = self.request_json(public_path)
                self.assertEqual(status, 200)
                self.assertEqual(response["upstream"], "26.1.2")
                self.assertEqual(response["path"], upstream_path)
                self.assertEqual(headers["Cache-Control"], "no-store, max-age=0")

    def test_proxy_headers_are_normalized(self):
        status, _, response = self.request_json(
            "/api/26.3/v1/status",
            headers={"X-Forwarded-For": "203.0.113.10"},
        )
        self.assertEqual(status, 200)
        self.assertEqual(response["host"], f"127.0.0.1:{self.edge_port}")
        self.assertEqual(response["x_forwarded_for"], "127.0.0.1")
        self.assertEqual(response["x_forwarded_proto"], "http")
        self.assertEqual(response["x_real_ip"], "127.0.0.1")

    def test_api_request_body_limit(self):
        accepted_body = b"a" * (256 * 1024)
        status, _, response = self.request_json(
            "/api/26.2/v1/clients/report", method="POST", body=accepted_body
        )
        self.assertEqual(status, 200)
        self.assertEqual(response["body_size"], len(accepted_body))

        rejected_body = b"a" * ((256 * 1024) + 1)
        status, _, _ = self.request(
            "/api/26.2/v1/clients/report", method="POST", body=rejected_body
        )
        self.assertEqual(status, 413)

    def test_current_release_pointers_are_never_cached(self):
        for path in (
            "/downloads/current-release.json",
            "/downloads/current-release-26.3.json",
        ):
            with self.subTest(path=path):
                status, headers, _ = self.request(path)
                self.assertEqual(status, 200)
                self.assertEqual(
                    headers["Cache-Control"], "no-store, max-age=0, must-revalidate"
                )
                self.assertEqual(headers["Pragma"], "no-cache")
                self.assertEqual(headers["Expires"], "0")

    def test_download_cache_and_range_contract(self):
        release_path = "/downloads/releases/release-test/client.zip"
        status, headers, body = self.request(release_path)
        self.assertEqual(status, 200)
        self.assertEqual(body, self.release_bytes)
        self.assertEqual(
            headers["Cache-Control"], "public, max-age=31536000, immutable"
        )

        status, headers, body = self.request(
            release_path, headers={"Range": "bytes=0-3"}
        )
        self.assertEqual(status, 206)
        self.assertEqual(body, self.release_bytes[:4])
        self.assertEqual(headers["Content-Range"], f"bytes 0-3/{len(self.release_bytes)}")

        status, headers, _ = self.request("/downloads/latest.zip")
        self.assertEqual(status, 200)
        self.assertEqual(headers["Cache-Control"], "public, max-age=60")

    def test_sensitive_files_and_directory_listing_are_blocked(self):
        for path in (
            "/secret.duckdb",
            "/backup-config.json",
            "/downloads/releases/release-test/",
        ):
            with self.subTest(path=path):
                status, _, _ = self.request(path)
                self.assertEqual(status, 404)

    def test_spa_fallback_security_headers_and_compression(self):
        status, headers, body = self.request("/missing/client/route")
        self.assertEqual(status, 200)
        self.assertEqual(body, b"PUMMELCHEN SPA")
        self.assertEqual(
            headers["Cache-Control"], "no-store, no-cache, max-age=0, must-revalidate"
        )
        self.assertEqual(headers["Strict-Transport-Security"], "max-age=31536000")
        self.assertEqual(headers["X-Content-Type-Options"], "nosniff")
        self.assertEqual(headers["X-Frame-Options"], "DENY")
        self.assertEqual(headers["Referrer-Policy"], "no-referrer")
        self.assertNotIn("Server", headers)

        status, headers, body = self.request(
            "/app.js", headers={"Accept-Encoding": "gzip"}
        )
        self.assertEqual(status, 200)
        self.assertEqual(headers["Content-Encoding"], "gzip")
        self.assertIn(b"edge-test", gzip.decompress(body))


if __name__ == "__main__":
    unittest.main(verbosity=2)
