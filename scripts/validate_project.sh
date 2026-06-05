#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pummelchen-validate.XXXXXX")"
BG_PIDS=()

cleanup() {
  if [ "${#BG_PIDS[@]}" -gt 0 ]; then
    for pid in "${BG_PIDS[@]}"; do
      kill "$pid" >/dev/null 2>&1 || true
      wait "$pid" >/dev/null 2>&1 || true
    done
  fi
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
PY_FILES=()
while IFS= read -r path; do
  PY_FILES+=("$path")
done < <(find "$ROOT_DIR/scripts" -name '*.py' -type f | sort)
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
"$PYTHON_BIN" "$ROOT_DIR/scripts/mod_acceptance_lab.py" --db "$DB" init
"$PYTHON_BIN" "$ROOT_DIR/scripts/headless_client_lab.py" --db "$DB" init

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
"$PYTHON_BIN" - "$PUBLIC" <<'PY'
from pathlib import Path
import stat
import sys

public = Path(sys.argv[1])
checks = [
    public / "current-release.json",
    public / "current-release.txt",
    public / "releases/qa_release_1/client-sync-manifest.tsv",
    public / "releases/qa_release_1/client-files/mods/client-mod-a.jar",
]
for path in checks:
    mode = stat.S_IMODE(path.stat().st_mode)
    assert mode == 0o644, f"{path} has public mode {oct(mode)}"
for path in [public, public / "releases", public / "releases/qa_release_1"]:
    mode = stat.S_IMODE(path.stat().st_mode)
    assert mode == 0o755, f"{path} has directory mode {oct(mode)}"
PY

log "Client package exclusion fixture"
EXCLUSION_SERVER="$TMP_DIR/exclusion-server"
mkdir -p "$EXCLUSION_SERVER/mods" "$EXCLUSION_SERVER/client-package/mods" "$EXCLUSION_SERVER/client-package/resourcepacks" \
  "$EXCLUSION_SERVER/client-package/shaderpacks"
"$PYTHON_BIN" - "$EXCLUSION_SERVER/client-package/mods" <<'PY'
from pathlib import Path
import sys
import zipfile

mods = Path(sys.argv[1])
for name in [
    "keep-me.jar",
    "animalgarden-commonraven-1.0.1-neoforge-26.1.2.10.jar",
    "automated_harvest-26.1.2.jar",
    "automotives-1.0.0-neoforge.jar",
    "better-snowy-biome-2.5.1-26.1.jar",
    "dynamictrees-neoforge-26.1.2-1.8.0-BETA01.jar",
    "Structory_Towers_26.1_v1.0.16.jar",
]:
    with zipfile.ZipFile(mods / name, "w") as archive:
        archive.writestr("pack.mcmeta", '{"pack":{"pack_format":94,"description":"fixture"}}')
PY
cp "$EXCLUSION_SERVER/client-package/mods/animalgarden-commonraven-1.0.1-neoforge-26.1.2.10.jar" "$EXCLUSION_SERVER/mods/"
cp "$EXCLUSION_SERVER/client-package/mods/automotives-1.0.0-neoforge.jar" "$EXCLUSION_SERVER/mods/"
cp "$EXCLUSION_SERVER/client-package/mods/better-snowy-biome-2.5.1-26.1.jar" "$EXCLUSION_SERVER/mods/"
cp "$EXCLUSION_SERVER/client-package/mods/dynamictrees-neoforge-26.1.2-1.8.0-BETA01.jar" "$EXCLUSION_SERVER/mods/"
"$PYTHON_BIN" - "$EXCLUSION_SERVER/mods/ruins-26.1.2.2NF.jar" "$EXCLUSION_SERVER/client-package/mods/ruins-26.1.2.2NF.jar" <<'PY'
from pathlib import Path
import sys
import zipfile

for raw in sys.argv[1:]:
    path = Path(raw)
    path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr("pack.mcmeta", '{"pack":{"pack_format":94,"description":"fixture"}}')
PY
"$PYTHON_BIN" "$ROOT_DIR/scripts/daily_update.py" --db "$DB" --server-dir "$EXCLUSION_SERVER" enforce-safety >/dev/null
"$PYTHON_BIN" - "$EXCLUSION_SERVER/client-package/mods/animalgarden-commonraven-1.0.1-neoforge-26.1.2.10.jar" <<'PY'
from pathlib import Path
import sys
import zipfile

path = Path(sys.argv[1])
path.parent.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(path, "w") as archive:
    archive.writestr("pack.mcmeta", '{"pack":{"pack_format":94,"description":"fixture"}}')
PY
"$PYTHON_BIN" "$ROOT_DIR/scripts/daily_update.py" --db "$DB" --server-dir "$EXCLUSION_SERVER" rebuild-client >/dev/null
[ -f "$EXCLUSION_SERVER/client-package/mods/keep-me.jar" ] || fail "client exclusion removed normal mod"
[ ! -e "$EXCLUSION_SERVER/mods/animalgarden-commonraven-1.0.1-neoforge-26.1.2.10.jar" ] || fail "server safety left Common Raven jar active"
[ ! -e "$EXCLUSION_SERVER/mods/automotives-1.0.0-neoforge.jar" ] || fail "server safety left Create Automotives jar active"
[ ! -e "$EXCLUSION_SERVER/client-package/mods/animalgarden-commonraven-1.0.1-neoforge-26.1.2.10.jar" ] || fail "client exclusion left Common Raven jar active"
[ ! -e "$EXCLUSION_SERVER/client-package/mods/automotives-1.0.0-neoforge.jar" ] || fail "client exclusion left Create Automotives jar active"
[ ! -e "$EXCLUSION_SERVER/client-package/mods/better-snowy-biome-2.5.1-26.1.jar" ] || fail "client exclusion left Better Snowy Biomes jar active"
[ ! -e "$EXCLUSION_SERVER/mods/dynamictrees-neoforge-26.1.2-1.8.0-BETA01.jar" ] || fail "server safety left Dynamic Trees jar active"
[ ! -e "$EXCLUSION_SERVER/client-package/mods/dynamictrees-neoforge-26.1.2-1.8.0-BETA01.jar" ] || fail "client exclusion left Dynamic Trees jar active"
[ ! -e "$EXCLUSION_SERVER/mods/ruins-26.1.2.2NF.jar" ] || fail "server safety left Ruins jar active"
[ ! -e "$EXCLUSION_SERVER/client-package/mods/ruins-26.1.2.2NF.jar" ] || fail "client exclusion left Ruins jar active"
[ ! -e "$EXCLUSION_SERVER/client-package/mods/automated_harvest-26.1.2.jar" ] || fail "client exclusion left automated harvest jar active"
[ ! -e "$EXCLUSION_SERVER/client-package/mods/Structory_Towers_26.1_v1.0.16.jar" ] || fail "client exclusion left Structory Towers jar active"
[ -f "$EXCLUSION_SERVER/mods.failed/pummelchen-server-disabled/mods/animalgarden-commonraven-1.0.1-neoforge-26.1.2.10.jar" ] || fail "server safety did not quarantine Common Raven"
[ -f "$EXCLUSION_SERVER/mods.failed/pummelchen-server-disabled/mods/automotives-1.0.0-neoforge.jar" ] || fail "server safety did not quarantine Create Automotives"
[ -f "$EXCLUSION_SERVER/mods.failed/pummelchen-server-disabled/mods/better-snowy-biome-2.5.1-26.1.jar" ] || fail "server safety did not quarantine Better Snowy Biomes"
[ -f "$EXCLUSION_SERVER/client-package/pummelchen-server-disabled/mods/animalgarden-commonraven-1.0.1-neoforge-26.1.2.10.jar" ] || fail "client exclusion did not quarantine Common Raven"
[ -f "$EXCLUSION_SERVER/mods.failed/pummelchen-server-disabled/mods/ruins-26.1.2.2NF.jar" ] || fail "server safety did not quarantine Ruins"
[ -f "$EXCLUSION_SERVER/client-package/pummelchen-server-disabled/mods/ruins-26.1.2.2NF.jar" ] || fail "client exclusion did not quarantine Ruins"
[ -f "$EXCLUSION_SERVER/client-package/pummelchen-server-disabled/mods/automated_harvest-26.1.2.jar" ] || fail "client exclusion did not quarantine automated harvest"
[ -f "$EXCLUSION_SERVER/client-package/pummelchen-server-disabled/mods/automotives-1.0.0-neoforge.jar" ] || fail "client exclusion did not quarantine Create Automotives"
[ -f "$EXCLUSION_SERVER/client-package/pummelchen-server-disabled/mods/better-snowy-biome-2.5.1-26.1.jar" ] || fail "client exclusion did not quarantine Better Snowy Biomes"
[ -f "$EXCLUSION_SERVER/mods.failed/pummelchen-server-disabled/mods/dynamictrees-neoforge-26.1.2-1.8.0-BETA01.jar" ] || fail "server safety did not quarantine Dynamic Trees"
[ -f "$EXCLUSION_SERVER/client-package/pummelchen-server-disabled/mods/dynamictrees-neoforge-26.1.2-1.8.0-BETA01.jar" ] || fail "client exclusion did not quarantine Dynamic Trees"
[ -f "$EXCLUSION_SERVER/client-package/pummelchen-server-disabled/mods/Structory_Towers_26.1_v1.0.16.jar" ] || fail "client exclusion did not quarantine Structory Towers"
"$PYTHON_BIN" - "$EXCLUSION_SERVER/minecraft_26.1.2_client_macos_apple_silicon.zip" <<'PY'
from pathlib import Path
import sys
import zipfile

zip_path = Path(sys.argv[1])
names = set(zipfile.ZipFile(zip_path).namelist())
assert "client-package/mods/keep-me.jar" in names, "client zip did not include active mod"
for bad in [
    "pummelchen-server-disabled",
    "upload-token.txt",
    "animalgarden-commonraven",
    "automated_harvest",
    "automotives",
    "better-snowy-biome",
    "dynamictrees",
    "Structory_Towers",
    "ruins-26.1.2.2NF",
]:
    assert not any(bad in name for name in names), f"client zip leaked {bad}"
PY

log "Mod acceptance lab planning fixture"
ACCEPTANCE_SERVER="$TMP_DIR/acceptance-server"
mkdir -p "$ACCEPTANCE_SERVER/mods"
"$PYTHON_BIN" - "$ACCEPTANCE_SERVER/mods" <<'PY'
import sys
import zipfile
from pathlib import Path

mods = Path(sys.argv[1])
fixtures = {
    "pummelchen-lib-1.0.0.jar": """
modLoader="javafml"
loaderVersion="[1,)"
license="MIT"
[[mods]]
modId="pummellib"
version="1.0.0"
displayName="Pummel Lib"
""",
    "pummelchen-dependent-1.0.0.jar": """
modLoader="javafml"
loaderVersion="[1,)"
license="MIT"
[[mods]]
modId="pummeldependent"
version="1.0.0"
displayName="Pummel Dependent"
[[dependencies.pummeldependent]]
modId="pummellib"
mandatory=true
versionRange="[1,)"
ordering="NONE"
side="BOTH"
""",
}
for name, toml in fixtures.items():
    with zipfile.ZipFile(mods / name, "w") as archive:
        archive.writestr("META-INF/neoforge.mods.toml", toml)
PY
"$PYTHON_BIN" "$ROOT_DIR/scripts/mod_acceptance_lab.py" --db "$DB" --server-dir "$ACCEPTANCE_SERVER" --bundle-size 1 plan \
  | grep -q 'active_server_jars=2' || fail "mod acceptance lab plan did not scan fixture jars"
"$PYTHON_BIN" "$ROOT_DIR/scripts/mod_acceptance_lab.py" --db "$DB" --server-dir "$ACCEPTANCE_SERVER" run-singles --dry-run --limit 1 \
  | grep -q 'active_server_jars=1' || fail "mod acceptance lab dry-run did not select fixture jar"
"$PYTHON_BIN" "$ROOT_DIR/scripts/mod_acceptance_lab.py" --db "$DB" --server-dir "$ACCEPTANCE_SERVER" --bundle-size 1 run-pyramid --dry-run \
  | grep -q 'max_levels_if_all_pass=2' || fail "mod acceptance pyramid dry-run did not report rollup levels"
"$PYTHON_BIN" "$ROOT_DIR/scripts/mod_acceptance_lab.py" --db "$DB" --server-dir "$ACCEPTANCE_SERVER" run-files --dry-run \
  --candidate-group-size 2 "$ACCEPTANCE_SERVER/mods/pummelchen-dependent-1.0.0.jar" \
  | grep -q 'context_files=1' || fail "candidate acceptance did not add known-working context"
FIXED_JAR="$TMP_DIR/codex-fixed-fixture.jar"
printf 'fixed jar\n' > "$FIXED_JAR"
ORIGINAL_MOD_ID="$("$PYTHON_BIN" - "$DB" <<'PY'
import datetime as dt
import hashlib
import sqlite3
import sys

conn = sqlite3.connect(sys.argv[1])
now = dt.datetime.now(dt.UTC).replace(microsecond=0).isoformat()
cur = conn.execute(
    "INSERT INTO imports(imported_at, source_file, spreadsheet_id, sheet_name, source_range, row_count) "
    "VALUES (?, 'fixture', '', 'fixture', '', 1)",
    (now,),
)
import_id = cur.lastrowid
payload = "broken-fixture".encode()
cur = conn.execute(
    """
    INSERT INTO mods(
        import_id, original_sheet_row, category, name, canonical_key, installation,
        entry_type, tested, target_mc, server_status, client_package,
        last_tested, active_status, status_rank, primary_url, row_hash, created_at, updated_at
    )
    VALUES (?, 1, 'Fixture', 'Broken Fixture', 'broken-fixture', '', 'Mod', '',
            '26.1.2', 'Rejected', '', '', 'failed', 30,
            'https://example.test/broken-fixture', ?, ?, ?)
    """,
    (import_id, hashlib.sha256(payload).hexdigest(), now, now),
)
mod_id = cur.lastrowid
conn.execute(
    "INSERT INTO mod_files(mod_id, role, file_name, path_hint, installed_on_server, included_in_client, status) "
    "VALUES (?, 'server_file', 'broken-fixture.jar', 'broken-fixture.jar', 0, 0, 'Rejected')",
    (mod_id,),
)
conn.commit()
print(mod_id)
PY
)"
"$PYTHON_BIN" "$ROOT_DIR/scripts/mod_acceptance_lab.py" --db "$DB" --server-dir "$ACCEPTANCE_SERVER" register-fixed \
  --original-mod-id "$ORIGINAL_MOD_ID" --fixed-jar "$FIXED_JAR" --patch-notes "fixture repair" \
  | grep -q 'status=candidate' || fail "Codex_Fixed registration did not complete"
"$PYTHON_BIN" - "$DB" "$ORIGINAL_MOD_ID" <<'PY' || fail "Codex_Fixed registration did not persist linked duplicate"
import sqlite3
import sys

conn = sqlite3.connect(sys.argv[1])
original_id = int(sys.argv[2])
row = conn.execute(
    "SELECT m.category, m.duplicate_of_id, c.status "
    "FROM codex_fixed_mods c JOIN mods m ON m.id = c.fixed_mod_id "
    "WHERE c.original_mod_id = ?",
    (original_id,),
).fetchone()
assert row == ("Codex_Fixed", original_id, "candidate"), row
PY

log "Headless client lab fixture"
HEADLESS_SERVER="$TMP_DIR/headless-server"
HEADLESS_BASE="$TMP_DIR/headless-client"
mkdir -p "$HEADLESS_SERVER/client-package/mods" "$HEADLESS_SERVER/client-package/resourcepacks" \
  "$HEADLESS_SERVER/client-package/shaderpacks"
printf 'mod\n' > "$HEADLESS_SERVER/client-package/mods/headless-fixture.jar"
printf 'resource\n' > "$HEADLESS_SERVER/client-package/resourcepacks/headless-resource.zip"
"$PYTHON_BIN" "$ROOT_DIR/scripts/headless_client_lab.py" --db "$DB" --server-dir "$HEADLESS_SERVER" --base-dir "$HEADLESS_BASE" setup --dry-run \
  | grep -q 'would_download=' || fail "headless client setup dry-run did not report download"
"$PYTHON_BIN" "$ROOT_DIR/scripts/headless_client_lab.py" --db "$DB" --server-dir "$HEADLESS_SERVER" --base-dir "$HEADLESS_BASE" sync >/tmp/headless-sync.$$
grep -q 'mods=1' /tmp/headless-sync.$$ || fail "headless client sync did not copy mod fixture"
grep -q 'resourcepacks=1' /tmp/headless-sync.$$ || fail "headless client sync did not copy resource fixture"
rm -f /tmp/headless-sync.$$
[ -f "$HEADLESS_BASE/game/options.txt" ] || fail "headless client sync did not seed options.txt"
"$PYTHON_BIN" "$ROOT_DIR/scripts/headless_client_lab.py" --db "$DB" --server-dir "$HEADLESS_SERVER" --base-dir "$HEADLESS_BASE" run --dry-run \
  | grep -q 'launch=launch neoforge:26.1.2 -specifics' || fail "headless client dry-run did not print launch command"

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
"$PYTHON_BIN" "$ROOT_DIR/scripts/release_manager.py" \
  --db "$DB" --server-dir "$SERVER" --release-root "$RELEASES" --public-downloads "$PUBLIC" \
  prune --keep 0 >/dev/null
[ -d "$RELEASES/qa_release_1" ] || fail "release prune removed active release"
[ ! -e "$RELEASES/qa_release_2" ] || fail "release prune kept inactive release with keep=0"
[ ! -e "$PUBLIC/releases/qa_release_2" ] || fail "release prune kept inactive public release link"
"$PYTHON_BIN" - "$DB" <<'PY' || fail "release prune did not mark inactive release"
import sqlite3
import sys

conn = sqlite3.connect(sys.argv[1])
status = conn.execute("SELECT status FROM pack_releases WHERE release_id = 'qa_release_2'").fetchone()[0]
assert status == "pruned", status
PY

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
"$PYTHON_BIN" - "$RESOURCE_PACKAGE/resourcepacks/ranged-pack.jar" <<'PY'
import json
import sys
import zipfile

pack = {
    "pack": {
        "pack_format": 94,
        "description": "fixture",
        "supported_formats": [81, 94],
        "min_format": 81,
        "max_format": 94,
    },
    "overlays": {
        "entries": [
            {
                "directory": "1-21-5-overlay",
                "min_format": 81,
                "max_format": 94,
            },
            {
                "directory": "1-21-11-overlay",
                "min_format": [101, 1],
                "max_format": [101, 1],
            }
        ]
    },
}
with zipfile.ZipFile(sys.argv[1], "w") as archive:
    archive.writestr("pack.mcmeta", json.dumps(pack))
PY
"$PYTHON_BIN" - "$RESOURCE_PACKAGE/resourcepacks/new-schema-pack.jar" <<'PY'
import json
import sys
import zipfile

pack = {
    "pack": {
        "description": "fixture",
        "min_format": [94, 1],
        "max_format": [101, 1],
    },
    "overlays": {
        "entries": [
            {
                "directory": "26-1-overlay",
                "min_format": [101, 1],
                "max_format": [101, 1],
                "formats": [101, 101],
            }
        ]
    },
}
with zipfile.ZipFile(sys.argv[1], "w") as archive:
    archive.writestr("pack.mcmeta", json.dumps(pack))
PY
"$PYTHON_BIN" "$ROOT_DIR/scripts/sanitize_resource_pack_metadata.py" "$RESOURCE_PACKAGE" --write \
  | grep -q 'resource_pack_metadata_changes=4' || fail "resource pack sanitizer did not report changes"
"$PYTHON_BIN" - "$RESOURCE_PACKAGE/resourcepacks/bad-pack.zip" <<'PY'
import json
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as archive:
    metadata = json.loads(archive.read("pack.mcmeta"))
assert metadata["overlays"]["entries"][0]["formats"] == [84, 999], metadata
assert metadata["overlays"]["entries"][0]["min_format"] == 84, metadata
assert metadata["overlays"]["entries"][0]["max_format"] == 999, metadata
PY
"$PYTHON_BIN" - "$RESOURCE_PACKAGE/resourcepacks/legacy-missing-formats.zip" <<'PY'
import json
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as archive:
    metadata = json.loads(archive.read("pack.mcmeta"))
entry = metadata["overlays"]["entries"][1]
assert entry["formats"] == [71, 512], metadata
for item in metadata["overlays"]["entries"]:
    assert "min_format" in item, metadata
    assert "max_format" in item, metadata
PY
"$PYTHON_BIN" - "$RESOURCE_PACKAGE/resourcepacks/ranged-pack.jar" <<'PY'
import json
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as archive:
    metadata = json.loads(archive.read("pack.mcmeta"))
assert metadata["pack"]["supported_formats"] == [81, 94], metadata
assert "min_format" not in metadata["pack"], metadata
assert "max_format" not in metadata["pack"], metadata
assert "formats" not in metadata["overlays"]["entries"][0], metadata
assert "formats" not in metadata["overlays"]["entries"][1], metadata
PY
"$PYTHON_BIN" - "$RESOURCE_PACKAGE/resourcepacks/new-schema-pack.jar" <<'PY'
import json
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as archive:
    metadata = json.loads(archive.read("pack.mcmeta"))
assert "formats" not in metadata["overlays"]["entries"][0], metadata
PY
CLIENT_NEW_SCHEMA_PACK="$RESOURCE_PACKAGE/resourcepacks/client-new-schema-pack.jar"
"$PYTHON_BIN" - "$CLIENT_NEW_SCHEMA_PACK" <<'PY'
import json
import sys
import zipfile

pack = {
    "pack": {
        "pack_format": 48,
        "description": "fixture",
        "supported_formats": [48, 101],
        "min_format": 48,
        "max_format": [101, 1],
    },
    "overlays": {
        "entries": [
            {
                "directory": "1-21-5-overlay",
                "min_format": 71,
                "max_format": [101, 1],
                "formats": [71, 101],
            },
            {
                "directory": "1-21-11-overlay",
                "min_format": [94, 1],
                "max_format": [101, 1],
                "formats": [94, 101],
            },
        ]
    },
}
with zipfile.ZipFile(sys.argv[1], "w") as archive:
    archive.writestr("pack.mcmeta", json.dumps(pack))
PY
"$PYTHON_BIN" "$ROOT_DIR/scripts/sanitize_resource_pack_metadata.py" "$CLIENT_NEW_SCHEMA_PACK" --target client --write \
  | grep -q 'resource_pack_metadata_changes=1' || fail "client resource pack sanitizer did not report changes"
"$PYTHON_BIN" - "$CLIENT_NEW_SCHEMA_PACK" <<'PY'
import json
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as archive:
    metadata = json.loads(archive.read("pack.mcmeta"))
assert metadata["pack"]["supported_formats"] == [48, 101], metadata
assert "min_format" not in metadata["pack"], metadata
assert "max_format" not in metadata["pack"], metadata
assert metadata["overlays"]["entries"][0]["formats"] == [71, 101], metadata
assert metadata["overlays"]["entries"][1]["formats"] == [94, 101], metadata
for item in metadata["overlays"]["entries"]:
    assert "min_format" in item, metadata
    assert "max_format" in item, metadata
PY
CLIENT_MIXED_SCHEMA_PACK="$RESOURCE_PACKAGE/resourcepacks/client-mixed-schema-pack.jar"
"$PYTHON_BIN" - "$CLIENT_MIXED_SCHEMA_PACK" <<'PY'
import json
import sys
import zipfile

pack = {
    "pack": {
        "pack_format": 15,
        "description": "fixture",
        "supported_formats": [15, 101],
        "min_format": 15,
        "max_format": [101, 1],
    },
    "overlays": {
        "entries": [
            {
                "directory": "legacy-overlay",
                "min_format": 48,
                "max_format": 48,
            },
            {
                "directory": "newer-overlay",
                "min_format": 71,
                "max_format": [101, 1],
            },
        ]
    },
}
with zipfile.ZipFile(sys.argv[1], "w") as archive:
    archive.writestr("pack.mcmeta", json.dumps(pack))
PY
"$PYTHON_BIN" "$ROOT_DIR/scripts/sanitize_resource_pack_metadata.py" "$CLIENT_MIXED_SCHEMA_PACK" --target client --write \
  | grep -q 'resource_pack_metadata_changes=1' || fail "client mixed resource pack sanitizer did not report changes"
"$PYTHON_BIN" - "$CLIENT_MIXED_SCHEMA_PACK" <<'PY'
import json
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as archive:
    metadata = json.loads(archive.read("pack.mcmeta"))
assert metadata["pack"]["supported_formats"] == [15, 101], metadata
assert "min_format" not in metadata["pack"], metadata
assert "max_format" not in metadata["pack"], metadata
assert metadata["overlays"]["entries"][0]["formats"] == [48, 48], metadata
assert metadata["overlays"]["entries"][1]["formats"] == [71, 101], metadata
assert metadata["overlays"]["entries"][0]["min_format"] == 48, metadata
assert metadata["overlays"]["entries"][0]["max_format"] == 48, metadata
assert metadata["overlays"]["entries"][1]["min_format"] == 71, metadata
assert metadata["overlays"]["entries"][1]["max_format"] == [101, 1], metadata
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

log "Auto-updater cleanup fixture"
AUTO_REMOTE="$TMP_DIR/auto-remote"
AUTO_MC="$TMP_DIR/auto-mc"
AUTO_HOME="$TMP_DIR/auto-home"
AUTO_LOGS="$TMP_DIR/auto-logs"
AUTO_CACHE="$TMP_DIR/auto-cache"
mkdir -p "$AUTO_REMOTE/downloads/client-files/mods" \
  "$AUTO_REMOTE/downloads/client-files/resourcepacks" \
  "$AUTO_REMOTE/downloads/client-files/shaderpacks" \
  "$AUTO_MC/mods" "$AUTO_MC/resourcepacks/Old Pack" "$AUTO_MC/shaderpacks/OldShader" \
  "$AUTO_MC/config"
printf 'wanted mod\n' > "$AUTO_REMOTE/downloads/client-files/mods/wanted.jar"
printf 'wanted resource\n' > "$AUTO_REMOTE/downloads/client-files/resourcepacks/Wanted Pack[1].zip"
printf 'wanted shader\n' > "$AUTO_REMOTE/downloads/client-files/shaderpacks/wanted-shader.zip"
printf 'old mod\n' > "$AUTO_MC/mods/old.jar"
printf 'old resource\n' > "$AUTO_MC/resourcepacks/Old Pack/pack.mcmeta"
printf 'old shader\n' > "$AUTO_MC/shaderpacks/OldShader/shaders.properties"
printf 'resourcePacks:["vanilla","file/Old Pack"]\nincompatibleResourcePacks:["file/Old Pack"]\n' > "$AUTO_MC/options.txt"
printf 'shaderPack=OldShader\n' > "$AUTO_MC/optionsshaders.txt"
printf 'shaderPack=OldShader\n' > "$AUTO_MC/config/iris.properties"
printf 'showLoadWarnings = true\n' > "$AUTO_MC/config/neoforge-client.toml"
printf 'showLoadWarnings = true\n' > "$AUTO_MC/config/forge-client.toml"
printf 'showCheckScreen = true\n' > "$AUTO_MC/config/yuushya-client.toml"
mkdir -p "$AUTO_MC/config/underground_village"
printf '{"enableInGameMessage":{"value":true}}\n' > "$AUTO_MC/config/underground_village/common.json"
printf '{"general":{"showTutorial":{"value":true}}}\n' > "$AUTO_MC/config/mtsconfigclient.json"
{
  printf 'mods\twanted.jar\t%s\tsha256:%s\tfile://%s\n' \
    "$(wc -c < "$AUTO_REMOTE/downloads/client-files/mods/wanted.jar" | tr -d '[:space:]')" \
    "$(sha256_value "$AUTO_REMOTE/downloads/client-files/mods/wanted.jar")" \
    "$AUTO_REMOTE/downloads/client-files/mods/wanted.jar"
  printf 'resourcepacks\tWanted Pack[1].zip\t%s\tsha256:%s\tdownloads/client-files/resourcepacks/Wanted Pack[1].zip\n' \
    "$(wc -c < "$AUTO_REMOTE/downloads/client-files/resourcepacks/Wanted Pack[1].zip" | tr -d '[:space:]')" \
    "$(sha256_value "$AUTO_REMOTE/downloads/client-files/resourcepacks/Wanted Pack[1].zip")"
  printf 'shaderpacks\twanted-shader.zip\t%s\tsha256:%s\tfile://%s\n' \
    "$(wc -c < "$AUTO_REMOTE/downloads/client-files/shaderpacks/wanted-shader.zip" | tr -d '[:space:]')" \
    "$(sha256_value "$AUTO_REMOTE/downloads/client-files/shaderpacks/wanted-shader.zip")" \
    "$AUTO_REMOTE/downloads/client-files/shaderpacks/wanted-shader.zip"
} > "$AUTO_REMOTE/client-sync-manifest.tsv"
PUMMELCHEN_SYNC_MANIFEST_URL="file://$AUTO_REMOTE/client-sync-manifest.tsv" \
  PUMMELCHEN_BASE_URL="file://$AUTO_REMOTE" \
  MINECRAFT_DIR="$AUTO_MC" \
  PUMMELCHEN_HOME="$AUTO_HOME" \
  PUMMELCHEN_LOG_DIR="$AUTO_LOGS" \
  PUMMELCHEN_CACHE_DIR="$AUTO_CACHE" \
  PUMMELCHEN_LOG_TO_STDOUT=1 \
  bash "$ROOT_DIR/client-package/tools/pummelchen-auto-update.sh" --quiet >/dev/null
[ -f "$AUTO_MC/mods/wanted.jar" ] || fail "auto-updater did not install wanted mod"
[ -f "$AUTO_MC/resourcepacks/Wanted Pack[1].zip" ] || fail "auto-updater did not install wanted resource pack"
[ -f "$AUTO_MC/shaderpacks/wanted-shader.zip" ] || fail "auto-updater did not install wanted shader pack"
[ ! -e "$AUTO_MC/mods/old.jar" ] || fail "auto-updater left unmanaged old mod active"
[ ! -e "$AUTO_MC/resourcepacks/Old Pack" ] || fail "auto-updater left unmanaged resource pack active"
[ ! -e "$AUTO_MC/shaderpacks/OldShader" ] || fail "auto-updater left unmanaged shader pack active"
find "$AUTO_MC" -maxdepth 2 -path '*before-pummelchen-auto-*/*' -print | grep -q 'Old Pack' || fail "auto-updater did not quarantine old resource pack"
grep -Fq 'resourcePacks:["vanilla"]' "$AUTO_MC/options.txt" || fail "auto-updater did not reset active resource packs"
grep -Fq 'incompatibleResourcePacks:[]' "$AUTO_MC/options.txt" || fail "auto-updater did not reset incompatible resource packs"
grep -Fxq 'shaderPack=' "$AUTO_MC/optionsshaders.txt" || fail "auto-updater did not disable options shader"
grep -Fxq 'shaderPack=' "$AUTO_MC/config/iris.properties" || fail "auto-updater did not disable Iris shader"
grep -Fxq 'showLoadWarnings=false' "$AUTO_MC/config/neoforge-client.toml" || fail "auto-updater did not quiet NeoForge load warnings"
grep -Fxq 'showLoadWarnings=false' "$AUTO_MC/config/forge-client.toml" || fail "auto-updater did not quiet Forge load warnings"
grep -Fxq 'showCheckScreen=false' "$AUTO_MC/config/yuushya-client.toml" || fail "auto-updater did not quiet Yuushya check screen"
grep -Fq '"enableInGameMessage":{"value":false}' "$AUTO_MC/config/underground_village/common.json" || fail "auto-updater did not disable underground village message"
grep -Fq '"showTutorial":{"value":false}' "$AUTO_MC/config/mtsconfigclient.json" || fail "auto-updater did not disable MTS tutorial"

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
