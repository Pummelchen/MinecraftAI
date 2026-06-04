#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pummelchen-validate.XXXXXX")"
BG_PIDS=()

cleanup() {
  for pid in "${BG_PIDS[@]}"; do
    kill "$pid" >/dev/null 2>&1 || true
    wait "$pid" >/dev/null 2>&1 || true
  done
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

log() {
  printf '==> %s\n' "$*"
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

sha256_line() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1"
  else
    sha256sum "$1"
  fi
}

sha256_value() {
  sha256_line "$1" | awk '{ print $1 }'
}

log "Python compile"
mapfile -t PY_FILES < <(find "$ROOT_DIR/scripts" -name '*.py' -type f | sort)
"$PYTHON_BIN" -m py_compile "${PY_FILES[@]}"

log "Shell syntax"
while IFS= read -r path; do
  bash -n "$path"
done < <(find "$ROOT_DIR/scripts" "$ROOT_DIR/client-package" "$ROOT_DIR/client-installer" -type f \( -name '*.sh' -o -name '*.command' \) | sort)

if command -v java >/dev/null 2>&1; then
  log "Minecraft server list helper"
  SERVER_LIST_MC="$TMP_DIR/server-list-mc"
  java "$ROOT_DIR/client-package/tools/AddPummelchenServer.java" \
    "$SERVER_LIST_MC" "Old Pummelchen" "91.99.176.243" >/dev/null
  java "$ROOT_DIR/client-package/tools/AddPummelchenServer.java" \
    "$SERVER_LIST_MC" "Pummelchen Server" "91.99.176.243:25565" >/dev/null
  java "$ROOT_DIR/client-package/tools/AddPummelchenServer.java" \
    "$SERVER_LIST_MC" "Pummelchen Server" "91.99.176.243:25565" >/dev/null
  "$PYTHON_BIN" - "$SERVER_LIST_MC/servers.dat" <<'PY'
from pathlib import Path
import sys

data = Path(sys.argv[1]).read_bytes()
assert data.count(b"91.99.176.243:25565") == 1, "Pummelchen address was not deduplicated"
assert data.count(b"91.99.176.243") == 1, "Pummelchen host appears more than once"
assert data.count(b"Pummelchen Server") == 1, "Pummelchen name appears more than once"
assert b"Old Pummelchen" not in data, "old equivalent default-port entry was not replaced"
PY
fi

if [ "$(uname -s)" = "Darwin" ] && command -v swiftc >/dev/null 2>&1; then
  log "Swift installer compile"
  swiftc "$ROOT_DIR/client-installer/ProgressInstaller.swift" \
    -o "$TMP_DIR/PummelchenProgressInstaller" \
    -framework AppKit
fi

log "Tracked secret guard"
if git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if git -C "$ROOT_DIR" ls-files | grep -Eq '(^|/)upload-token\.txt$|(^|/)secrets/'; then
    fail "runtime secret file is tracked by git"
  fi
  if git -C "$ROOT_DIR" grep -nE '^[[:space:]]*(password|token)[[:space:]]*[:=][[:space:]]*[A-Za-z0-9_./+-]{24,}' -- ':!*.example' ':!README.md' >/tmp/pummelchen-secret-grep.$$ 2>/dev/null; then
    cat /tmp/pummelchen-secret-grep.$$ >&2
    rm -f /tmp/pummelchen-secret-grep.$$
    fail "possible hard-coded secret in tracked files"
  fi
fi
rm -f /tmp/pummelchen-secret-grep.$$

log "Database migrations"
DB="$TMP_DIR/minecraft_mods.sqlite"
"$PYTHON_BIN" "$ROOT_DIR/scripts/moddb.py" --db "$DB" init
"$PYTHON_BIN" "$ROOT_DIR/scripts/gameplay_load_lab.py" --db "$DB" init

log "Release-manager fixture"
SERVER="$TMP_DIR/server"
RELEASES="$TMP_DIR/releases"
PUBLIC="$TMP_DIR/public/downloads"
mkdir -p "$SERVER/mods" "$SERVER/server-datapacks" "$SERVER/client-package/mods" \
  "$SERVER/client-package/resourcepacks" "$SERVER/client-package/shaderpacks" \
  "$SERVER/client-package/tools" "$SERVER/libraries/net/neoforged/neoforge/26.1.2.71"
printf 'mod-a\n' > "$SERVER/mods/mod-a.jar"
printf 'pack-a\n' > "$SERVER/server-datapacks/pack-a.zip"
printf 'client-mod-a\n' > "$SERVER/client-package/mods/client-mod-a.jar"
printf 'resource-a\n' > "$SERVER/client-package/resourcepacks/resource-a.zip"
printf 'shader-a\n' > "$SERVER/client-package/shaderpacks/shader-a.zip"
printf 'do-not-publish\n' > "$SERVER/client-package/tools/upload-token.txt"
CLIENT_ZIP="$SERVER/minecraft_26.1.2_client_macos_apple_silicon.zip"
printf 'client zip\n' > "$CLIENT_ZIP"
CLIENT_ZIP_SHA="$(sha256_value "$CLIENT_ZIP")"
sha256_line "$CLIENT_ZIP" > "$CLIENT_ZIP.sha256"
printf 'mrpack\n' > "$SERVER/pummelchen-server-26.1.2.mrpack"
printf 'dmg\n' > "$SERVER/Pummelchen-Client-Installer.dmg"
sha256_line "$SERVER/Pummelchen-Client-Installer.dmg" > "$SERVER/Pummelchen-Client-Installer.dmg.sha256"

"$PYTHON_BIN" "$ROOT_DIR/scripts/release_manager.py" \
  --db "$DB" --server-dir "$SERVER" --release-root "$RELEASES" --public-downloads "$PUBLIC" \
  create --release-id qa_release_1 --activate --notes "quality gate release"
"$PYTHON_BIN" "$ROOT_DIR/scripts/release_manager.py" \
  --db "$DB" --server-dir "$SERVER" --release-root "$RELEASES" --public-downloads "$PUBLIC" \
  validate qa_release_1
"$PYTHON_BIN" "$ROOT_DIR/scripts/release_manager.py" \
  --db "$DB" --server-dir "$SERVER" --release-root "$RELEASES" --public-downloads "$PUBLIC" \
  current-json >/dev/null
[ -f "$PUBLIC/current-release.json" ] || fail "current-release.json was not published"
[ -f "$PUBLIC/releases/qa_release_1/client-sync-manifest.tsv" ] || fail "release client manifest was not published"
[ ! -e "$PUBLIC/releases/qa_release_1/client-files/tools/upload-token.txt" ] || fail "upload token leaked into public release"

log "Rollback fixture"
printf 'mod-b\n' > "$SERVER/mods/mod-b.jar"
"$PYTHON_BIN" "$ROOT_DIR/scripts/release_manager.py" \
  --db "$DB" --server-dir "$SERVER" --release-root "$RELEASES" --public-downloads "$PUBLIC" \
  create --release-id qa_release_2 --activate --notes "second quality gate release" >/dev/null
"$PYTHON_BIN" "$ROOT_DIR/scripts/release_manager.py" \
  --db "$DB" --server-dir "$SERVER" --release-root "$RELEASES" --public-downloads "$PUBLIC" \
  rollback --notes "quality gate rollback" >/dev/null
"$PYTHON_BIN" "$ROOT_DIR/scripts/release_manager.py" \
  --db "$DB" --server-dir "$SERVER" --release-root "$RELEASES" --public-downloads "$PUBLIC" \
  validate qa_release_1
[ ! -f "$SERVER/mods/mod-b.jar" ] || fail "rollback did not remove newer mod"

log "Client manifest checker"
MANIFEST_PACKAGE="$TMP_DIR/manifest-package"
mkdir -p "$MANIFEST_PACKAGE/mods" "$MANIFEST_PACKAGE/resourcepacks" "$MANIFEST_PACKAGE/shaderpacks"
printf 'fixture\n' > "$MANIFEST_PACKAGE/mods/fixture.jar"
SIZE="$(wc -c < "$MANIFEST_PACKAGE/mods/fixture.jar" | tr -d '[:space:]')"
HASH="$(sha256_value "$MANIFEST_PACKAGE/mods/fixture.jar")"
printf '[mods]\nfixture.jar\t%s\tsha256:%s\n' "$SIZE" "$HASH" > "$MANIFEST_PACKAGE/manifest.txt"
"$PYTHON_BIN" "$ROOT_DIR/scripts/check_client_manifest.py" "$MANIFEST_PACKAGE" --strict
"$PYTHON_BIN" "$ROOT_DIR/scripts/check_client_manifest.py" "$ROOT_DIR/client-package"

log "Resource pack metadata sanitizer"
RESOURCE_PACKAGE="$TMP_DIR/resource-package"
mkdir -p "$RESOURCE_PACKAGE/resourcepacks"
"$PYTHON_BIN" - "$RESOURCE_PACKAGE/resourcepacks/bad-pack.zip" <<'PY'
import json
import sys
import zipfile

pack = {
    "pack": {"pack_format": 15, "description": "fixture"},
    "overlays": {
        "entries": [
            {
                "directory": "26-1",
                "formats": {"min_inclusive": 84, "max_inclusive": 999},
                "min_format": 84,
                "max_format": 999,
            }
        ]
    },
}
with zipfile.ZipFile(sys.argv[1], "w") as archive:
    archive.writestr("pack.mcmeta", json.dumps(pack))
PY
"$PYTHON_BIN" - "$RESOURCE_PACKAGE/resourcepacks/legacy-missing-formats.zip" <<'PY'
import json
import sys
import zipfile

pack = {
    "pack": {"pack_format": 15, "description": "fixture"},
    "overlays": {
        "entries": [
            {
                "directory": "old",
                "formats": [26, 512],
                "min_format": 26,
                "max_format": 512,
            },
            {
                "directory": "newer",
                "min_format": 71,
                "max_format": 512,
            },
        ]
    },
}
with zipfile.ZipFile(sys.argv[1], "w") as archive:
    archive.writestr("pack.mcmeta", json.dumps(pack))
PY
"$PYTHON_BIN" "$ROOT_DIR/scripts/sanitize_resource_pack_metadata.py" "$RESOURCE_PACKAGE" --write \
  | grep -q 'resource_pack_metadata_changes=2' || fail "resource pack sanitizer did not report changes"
"$PYTHON_BIN" - "$RESOURCE_PACKAGE/resourcepacks/bad-pack.zip" <<'PY'
import json
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as archive:
    metadata = json.loads(archive.read("pack.mcmeta"))
assert "formats" not in metadata["overlays"]["entries"][0], metadata
PY
"$PYTHON_BIN" - "$RESOURCE_PACKAGE/resourcepacks/legacy-missing-formats.zip" <<'PY'
import json
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as archive:
    metadata = json.loads(archive.read("pack.mcmeta"))
entry = metadata["overlays"]["entries"][1]
assert entry["formats"] == [71, 512], metadata
PY

log "Client mod dependency checker"
DEP_PACKAGE="$TMP_DIR/dependency-package"
mkdir -p "$DEP_PACKAGE/mods"
"$PYTHON_BIN" - "$DEP_PACKAGE/mods" <<'PY'
from pathlib import Path
import sys
import zipfile

mods = Path(sys.argv[1])

def write_mod(name, toml):
    with zipfile.ZipFile(mods / name, "w") as archive:
        archive.writestr("META-INF/neoforge.mods.toml", toml)

write_mod("client-a.jar", '''
modLoader = "javafml"
loaderVersion = "[4,)"
license = "MIT"
[[mods]]
modId = "client_a"
version = "1.0.0"
displayName = "Client A"
description = "fixture"
[[dependencies.client_a]]
modId = "client_b"
type = "required"
versionRange = "[0.2.3,)"
ordering = "NONE"
side = "BOTH"
[[dependencies.client_a]]
modId = "minecraft"
type = "required"
versionRange = "[26.1,26.2)"
ordering = "NONE"
side = "CLIENT"
''')
write_mod("client-b.jar", '''
modLoader = "javafml"
loaderVersion = "[4,)"
license = "MIT"
[[mods]]
modId = "client_b"
version = "0.2.3"
displayName = "Client B"
description = "fixture"
''')
PY
"$PYTHON_BIN" "$ROOT_DIR/scripts/check_client_mod_dependencies.py" "$DEP_PACKAGE" \
  --minecraft-version 26.1.2 --neoforge-version 26.1.2.71
"$PYTHON_BIN" - "$DEP_PACKAGE/mods/client-b.jar" <<'PY'
from pathlib import Path
import sys
Path(sys.argv[1]).unlink()
PY
if "$PYTHON_BIN" "$ROOT_DIR/scripts/check_client_mod_dependencies.py" "$DEP_PACKAGE" \
  --minecraft-version 26.1.2 --neoforge-version 26.1.2.71 >/tmp/pummelchen-depcheck.$$ 2>&1; then
  cat /tmp/pummelchen-depcheck.$$ >&2
  rm -f /tmp/pummelchen-depcheck.$$
  fail "dependency checker did not catch missing client dependency"
fi
rm -f /tmp/pummelchen-depcheck.$$

log "macOS client smoke launcher fixture"
SMOKE_MC="$TMP_DIR/client-smoke-mc"
mkdir -p "$SMOKE_MC/versions/26.1.2" "$SMOKE_MC/versions/neoforge-26.1.2.71" \
  "$SMOKE_MC/libraries/com/example/clientlib/1.0.0"
touch "$TMP_DIR/fake-java" \
  "$SMOKE_MC/versions/26.1.2/26.1.2.jar" \
  "$SMOKE_MC/libraries/com/example/clientlib/1.0.0/clientlib-1.0.0.jar"
"$PYTHON_BIN" - "$SMOKE_MC" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
(root / "versions/26.1.2/26.1.2.json").write_text(json.dumps({
    "id": "26.1.2",
    "mainClass": "net.minecraft.client.main.Main",
    "assetIndex": {"id": "30"},
    "arguments": {
        "jvm": [
            {"rules": [{"action": "allow", "os": {"name": "osx"}}], "value": "-XstartOnFirstThread"},
            "-Djava.library.path=${natives_directory}",
            "-cp",
            "${classpath}",
        ],
        "game": [
            "--username", "${auth_player_name}",
            "--version", "${version_name}",
            "--gameDir", "${game_directory}",
            {"rules": [{"action": "allow", "features": {"has_custom_resolution": True}}],
             "value": ["--width", "${resolution_width}", "--height", "${resolution_height}"]},
            {"rules": [{"action": "allow", "features": {"has_quick_plays_support": True}}],
             "value": ["--quickPlayPath", "${quickPlayPath}"]},
            {"rules": [{"action": "allow", "features": {"is_quick_play_multiplayer": True}}],
             "value": ["--quickPlayMultiplayer", "${quickPlayMultiplayer}"]},
        ],
    },
    "libraries": [
        {"downloads": {"artifact": {"path": "com/example/clientlib/1.0.0/clientlib-1.0.0.jar"}}}
    ],
}), encoding="utf-8")
(root / "versions/neoforge-26.1.2.71/neoforge-26.1.2.71.json").write_text(json.dumps({
    "id": "neoforge-26.1.2.71",
    "inheritsFrom": "26.1.2",
    "mainClass": "net.neoforged.fml.startup.Client",
    "arguments": {
        "game": ["--fml.neoForgeVersion", "26.1.2.71"],
        "jvm": ["-DlibraryDirectory=${library_directory}"],
    },
}), encoding="utf-8")
PY
"$PYTHON_BIN" "$ROOT_DIR/scripts/macos_client_launch_smoke.py" \
  --minecraft-dir "$SMOKE_MC" \
  --java-bin "$TMP_DIR/fake-java" \
  --force \
  --print-command > "$TMP_DIR/client-smoke-command.txt"
grep -q -- "--width" "$TMP_DIR/client-smoke-command.txt" || fail "client smoke command omitted resolution args"
grep -q -- "1280" "$TMP_DIR/client-smoke-command.txt" || fail "client smoke command omitted resolved width"
if grep -q -- "quickPlay" "$TMP_DIR/client-smoke-command.txt"; then
  cat "$TMP_DIR/client-smoke-command.txt" >&2
  fail "client smoke command included disabled quick-play args"
fi
if grep -q -- '${' "$TMP_DIR/client-smoke-command.txt"; then
  cat "$TMP_DIR/client-smoke-command.txt" >&2
  fail "client smoke command left unresolved placeholders"
fi

log "Generated status site"
SITE_OUT="$TMP_DIR/site"
"$PYTHON_BIN" "$ROOT_DIR/scripts/generate_status_site.py" --db "$DB" --server-dir "$SERVER" --output-dir "$SITE_OUT" --public-url "http://127.0.0.1:7788"
[ -f "$SITE_OUT/index.html" ] || fail "status site was not generated"
grep -q "Pummelchen Server" "$SITE_OUT/index.html" || fail "status site title missing"

log "Live stats and exporter"
"$PYTHON_BIN" "$ROOT_DIR/scripts/live_stats_feed.py" --db "$DB" --server-dir "$SERVER" --output "$TMP_DIR/live-stats.json" --state "$TMP_DIR/live-state.json"
grep -q "Active release" "$TMP_DIR/live-stats.json" || fail "live stats missing release data"
"$PYTHON_BIN" - "$TMP_DIR/live-stats.json" "$CLIENT_ZIP_SHA" "$ROOT_DIR/scripts" <<'PY'
import json
import sys

stats_path, expected_sha, scripts_dir = sys.argv[1:]
sys.path.insert(0, scripts_dir)
import live_stats_feed

payload = json.loads(open(stats_path, encoding="utf-8").read())
stats = payload["stats"]
metrics = payload["metrics"]
assert stats["Client pack"] == "11 B", "live stats missing client package size"
assert stats["Client pack SHA256"] == expected_sha, "live stats missing client package checksum"
assert live_stats_feed.clamp_percent(138.1) == 100.0, "percent clamp does not cap overload values"
for key in ("cpu_percent", "load1_percent", "ram_used_percent", "disk_used_percent", "disk_free_percent"):
    assert key in metrics, f"live stats missing {key}"
    assert 0 <= float(metrics[key]) <= 100, f"{key} is outside 0-100"
for sample in payload["history"]:
    for key in ("cpu_percent", "load1_percent", "ram_used_percent", "disk_used_percent", "disk_free_percent"):
        if key in sample:
            assert 0 <= float(sample[key]) <= 100, f"history {key} is outside 0-100"
PY
"$PYTHON_BIN" "$ROOT_DIR/scripts/minecraft_metrics_exporter.py" --db "$DB" --server-dir "$SERVER" --state "$TMP_DIR/metrics-state.json" --once | grep -q "pummelchen_minecraft_up"

log "Installer event receiver"
RECEIVER_PORT="$("$PYTHON_BIN" - <<'PY'
import socket
with socket.socket() as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
)"
"$PYTHON_BIN" "$ROOT_DIR/scripts/client_log_receiver.py" \
  --db "$DB" \
  --upload-dir "$TMP_DIR/client-log-uploads" \
  --token-file "$TMP_DIR/client-log-upload.token" \
  --host 127.0.0.1 \
  --port "$RECEIVER_PORT" \
  > "$TMP_DIR/client-log-receiver.log" 2>&1 &
BG_PIDS+=("$!")
"$PYTHON_BIN" - "$RECEIVER_PORT" <<'PY'
import sys
import time
import urllib.request

port = sys.argv[1]
url = f"http://127.0.0.1:{port}/health"
for _ in range(50):
    try:
        with urllib.request.urlopen(url, timeout=0.5) as response:
            if response.status == 200:
                raise SystemExit(0)
    except Exception:
        time.sleep(0.1)
raise SystemExit("receiver did not become healthy")
PY
"$PYTHON_BIN" - "$DB" "$RECEIVER_PORT" <<'PY'
import sqlite3
import sys
import urllib.parse
import urllib.request

db_path, port = sys.argv[1], sys.argv[2]
url = f"http://127.0.0.1:{port}/client-logs/installer-event"

def post(event_type, status, message):
    body = urllib.parse.urlencode(
        {
            "session_id": "qa-installer-session",
            "client_id": "qa-client",
            "event_type": event_type,
            "severity": "info" if status != "failed" else "error",
            "status": status,
            "installer_version": "qa",
            "release_id": "qa_release_1",
            "minecraft_version": "26.1.2",
            "step_current": "10" if status == "ok" else "1",
            "step_total": "10",
            "message": message,
            "log_excerpt": "qa log line",
        }
    ).encode()
    request = urllib.request.Request(
        url,
        data=body,
        headers={"Content-Type": "application/x-www-form-urlencoded; charset=utf-8"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=5) as response:
        if response.status != 200:
            raise RuntimeError(response.read().decode())

post("app_started", "running", "started")
post("completed", "ok", "completed")

with sqlite3.connect(db_path) as conn:
    session = conn.execute(
        "SELECT status, completed_at, event_count, release_id FROM client_installer_sessions WHERE session_id = ?",
        ("qa-installer-session",),
    ).fetchone()
    assert session is not None, "installer session missing"
    assert session[0] == "ok", session
    assert session[1], session
    assert session[2] == 2, session
    assert session[3] == "qa_release_1", session
    event_count = conn.execute(
        "SELECT COUNT(*) FROM client_installer_events WHERE session_id = ?",
        ("qa-installer-session",),
    ).fetchone()[0]
    assert event_count == 2, event_count
PY

log "Load-lab dry run"
"$PYTHON_BIN" "$ROOT_DIR/scripts/gameplay_load_lab.py" --db "$DB" --server-dir "$SERVER" run fresh_world_idle --dry-run

log "Monitoring JSON"
"$PYTHON_BIN" -m json.tool "$ROOT_DIR/monitoring/grafana/dashboards/pummelchen-overview.json" >/dev/null

if command -v nginx >/dev/null 2>&1; then
  log "Nginx syntax"
  NGINX_MAIN="$TMP_DIR/nginx.conf"
  NGINX_SITE="$TMP_DIR/pummelchen-server.conf"
  sed "s#/var/log/nginx/#$TMP_DIR/#g" "$ROOT_DIR/nginx/pummelchen-server.conf" > "$NGINX_SITE"
  {
    printf 'pid "%s/nginx.pid";\n' "$TMP_DIR"
    printf 'error_log "%s/nginx-error.log";\n' "$TMP_DIR"
    printf 'events {}\n'
    printf 'http { include "%s"; }\n' "$NGINX_SITE"
  } > "$NGINX_MAIN"
  nginx -t -c "$NGINX_MAIN" -p "$TMP_DIR" >/dev/null
fi

log "Quality gate passed"
