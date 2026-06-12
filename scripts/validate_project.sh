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

log "Custom server datapacks"
CUSTOM_DATAPACK_COUNT="$($PYTHON_BIN - "$ROOT_DIR/server-datapacks-src/custom_datapacks.json" <<'PY'
import json
import sys

payload = json.loads(open(sys.argv[1], encoding="utf-8").read())
print(len(payload.get("datapacks", [])))
PY
)"
"$PYTHON_BIN" "$ROOT_DIR/scripts/sync_custom_datapacks.py" --project-dir "$ROOT_DIR" --check
log "Project-owned custom mods"
"$PYTHON_BIN" "$ROOT_DIR/scripts/sync_pummelchen_mods.py" --db "$TMP_DIR/pummelchen-mods.sqlite" --server-dir "$TMP_DIR/project-mods-server" --mods-dir "$ROOT_DIR/Pummelchen_Mods" --check

if [ "$CUSTOM_DATAPACK_COUNT" -eq 0 ]; then
  log "No project-owned custom datapacks configured"
else
  CUSTOM_DATAPACKS_SERVER="$TMP_DIR/custom-datapacks-server"
  mkdir -p "$CUSTOM_DATAPACKS_SERVER"
  printf 'level-name=custom-live-world\n' > "$CUSTOM_DATAPACKS_SERVER/server.properties"
  CUSTOM_DATAPACKS_OUTPUT="$("$PYTHON_BIN" "$ROOT_DIR/scripts/sync_custom_datapacks.py" \
    --db "$TMP_DIR/custom-datapacks.sqlite" \
    --project-dir "$ROOT_DIR" \
    --server-dir "$CUSTOM_DATAPACKS_SERVER")"
  EXPECTED_CHANGED=$((CUSTOM_DATAPACK_COUNT * 2))
  printf '%s\n' "$CUSTOM_DATAPACKS_OUTPUT" | grep -q "custom_datapacks_changed=$EXPECTED_CHANGED" \
    || fail "custom datapack sync did not install into server and active world"

  CUSTOM_DATAPACK_FILES="$($PYTHON_BIN - "$ROOT_DIR/server-datapacks-src/custom_datapacks.json" <<'PY'
import json
import sys

payload = json.loads(open(sys.argv[1], encoding="utf-8").read())
for item in payload.get("datapacks", []):
    print(item["file_name"])
PY
)"
  for file_name in $CUSTOM_DATAPACK_FILES; do
    [ -f "$CUSTOM_DATAPACKS_SERVER/server-datapacks/$file_name" ] \
      || fail "custom datapack was not copied to server-datapacks ($file_name)"
    [ -f "$CUSTOM_DATAPACKS_SERVER/custom-live-world/datapacks/$file_name" ] \
      || fail "custom datapack was not copied to active level-name datapacks folder ($file_name)"
  done
  grep -q '^bonus-chest=true$' "$ROOT_DIR/server-config/server.properties.override" \
    || fail "server properties must enable the customized generated bonus chest"
  "$PYTHON_BIN" - "$ROOT_DIR/server-datapacks/pummelchen-welcome.zip" <<'PY' \
    || fail "welcome datapack does not enforce new-world safety policy"
import json
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as archive:
    load = archive.read("data/pummelchen/function/load.mcfunction").decode()
    tick = archive.read("data/pummelchen/function/tick.mcfunction").decode()
    tick_tag = archive.read("data/minecraft/tags/function/tick.json").decode()
    bonus_chest = json.loads(archive.read("data/minecraft/loot_table/chests/spawn_bonus_chest.json"))
    protected_wildlife = json.loads(archive.read("data/pummelchen/tags/entity_type/protected_wildlife.json"))

required_load = [
    "gamerule keep_inventory true",
    "gamerule mob_griefing false",
    "gamerule projectiles_can_break_blocks false",
    "gamerule block_explosion_drop_decay false",
    "gamerule mob_explosion_drop_decay false",
    "gamerule tnt_explodes false",
    "gamerule tnt_explosion_drop_decay false",
]
for command in required_load:
    assert command in load, command
assert "kill @e[type=minecraft:tnt]" in tick
assert "kill @e[type=minecraft:tnt_minecart]" in tick
assert "pummelchen:tick" in tick_tag
assert "team add pummelchen_wildlife" in load
assert "team modify pummelchen_wildlife friendlyFire false" in load
assert "team join pummelchen_wildlife @e[type=#jeg:gunner,team=!pummelchen_wildlife]" in tick
assert "team join pummelchen_wildlife @e[type=#pummelchen:protected_wildlife,team=!pummelchen_wildlife]" in tick
protected_values = protected_wildlife["values"]
assert "minecraft:cow" in protected_values
assert {"id": "untitledduckmod:duck", "required": False} in protected_values
pools = bonus_chest["pools"]
assert len(pools) == 3
assert [pool["rolls"] for pool in pools] == [3, 3, 3]
food_names = {entry["name"] for entry in pools[0]["entries"]}
assert {"minecraft:bread", "minecraft:cooked_beef", "minecraft:apple"} <= food_names
assert pools[1]["entries"][0] == {"type": "minecraft:loot_table", "value": "chems_guns:guns/starter_pistol"}
assert pools[2]["entries"][0] == {"type": "minecraft:loot_table", "value": "chems_guns:ammo/standard/pistol_magazine"}
PY
  "$PYTHON_BIN" - "$ROOT_DIR/server-datapacks/pummelchen-tropical-worldgen.zip" <<'PY' \
    || fail "tropical worldgen datapack does not enforce requested biome bias"
import json
import sys
import zipfile

targets = {
    "minecraft:bamboo_jungle",
    "minecraft:jungle",
    "minecraft:sparse_jungle",
    "terralith:tropical_jungle",
    "terralith:jungle_mountains",
    "terralith:rocky_jungle",
    "terralith:amethyst_rainforest",
}
cherry = {
    "minecraft:cherry_grove",
    "terralith:sakura_grove",
    "terralith:sakura_valley",
}
keys = ("weirdness", "continentalness", "erosion", "temperature", "humidity")

def width(value):
    return max(0.0, float(value[1]) - float(value[0])) if isinstance(value, list) else 0.0

def volume(entry):
    result = 1.0
    for key in keys:
        result *= width(entry["parameters"][key])
    return result

with zipfile.ZipFile(sys.argv[1]) as archive:
    data = json.loads(archive.read("data/minecraft/worldgen/multi_noise_biome_source_parameter_list/overworld.json"))
    pack = json.loads(archive.read("pack.mcmeta"))

assert pack["pack"]["max_format"] == 101
assert data["preset"] == "minecraft:overworld"
biomes = data["lithostitched:biomes"]
counts = {}
for entry in biomes:
    counts[entry["biome"]] = counts.get(entry["biome"], 0) + 1
tropical_volume = sum(volume(entry) for entry in biomes if entry["biome"] in targets)
cherry_volume = sum(volume(entry) for entry in biomes if entry["biome"] in cherry)
assert len(biomes) == 1713
assert counts["minecraft:bamboo_jungle"] >= 100
assert counts["terralith:sakura_valley"] >= 35
assert tropical_volume >= 7.0
assert cherry_volume >= 1.5
PY
  "$PYTHON_BIN" - "$ROOT_DIR/server-datapacks/pummelchen-rich-ores.zip" <<'PY' \
    || fail "rich ores datapack does not enforce requested ore vein sizes"
import json
import sys
import zipfile

expected_sizes = {
    "ore_iron": 64,
    "ore_iron_small": 40,
    "ore_gold": 64,
    "ore_gold_buried": 64,
    "ore_diamond_small": 40,
    "ore_diamond_medium": 64,
    "ore_diamond_large": 64,
    "ore_diamond_buried": 64,
}
expected_blocks = {
    "ore_iron": {"minecraft:iron_ore", "minecraft:deepslate_iron_ore"},
    "ore_iron_small": {"minecraft:iron_ore", "minecraft:deepslate_iron_ore"},
    "ore_gold": {"minecraft:gold_ore", "minecraft:deepslate_gold_ore"},
    "ore_gold_buried": {"minecraft:gold_ore", "minecraft:deepslate_gold_ore"},
    "ore_diamond_small": {"minecraft:diamond_ore", "minecraft:deepslate_diamond_ore"},
    "ore_diamond_medium": {"minecraft:diamond_ore", "minecraft:deepslate_diamond_ore"},
    "ore_diamond_large": {"minecraft:diamond_ore", "minecraft:deepslate_diamond_ore"},
    "ore_diamond_buried": {"minecraft:diamond_ore", "minecraft:deepslate_diamond_ore"},
}

with zipfile.ZipFile(sys.argv[1]) as archive:
    pack = json.loads(archive.read("pack.mcmeta"))
    assert pack["pack"]["max_format"] == 101
    names = set(archive.namelist())
    for feature, size in expected_sizes.items():
        path = f"data/minecraft/worldgen/configured_feature/{feature}.json"
        assert path in names, path
        data = json.loads(archive.read(path))
        assert data["type"] == "minecraft:ore"
        assert data["config"]["size"] == size, (feature, data["config"]["size"])
        blocks = {target["state"]["Name"] for target in data["config"]["targets"]}
        assert blocks == expected_blocks[feature], (feature, blocks)
PY
fi

SAFE_RESET_SERVER="$TMP_DIR/safe-reset-server"
mkdir -p "$SAFE_RESET_SERVER/world/region"
printf 'level-name=world\nlevel-seed=old-seed\nbonus-chest=false\n' > "$SAFE_RESET_SERVER/server.properties"
printf 'old-region\n' > "$SAFE_RESET_SERVER/world/region/r.0.0.mca"
SAFE_RESET_OUTPUT="$("$PYTHON_BIN" "$ROOT_DIR/scripts/safe_reset_world.py" \
  --project-dir "$ROOT_DIR" \
  --server-dir "$SAFE_RESET_SERVER" \
  --seed 987654321 \
  --radius-blocks 1000 \
  --batch-size 32 \
  --dry-run \
  --yes)"
printf '%s\n' "$SAFE_RESET_OUTPUT" | grep -q 'world_seed=987654321' \
  || fail "safe world reset did not report requested seed"
printf '%s\n' "$SAFE_RESET_OUTPUT" | grep -q 'radius_blocks=1000' \
  || fail "safe world reset did not plan 1000-block radius"
printf '%s\n' "$SAFE_RESET_OUTPUT" | grep -q 'diameter_blocks=2000' \
  || fail "safe world reset did not report 2000-block diameter for 1000-block radius"
printf '%s\n' "$SAFE_RESET_OUTPUT" | grep -q 'pregenerate_chunks=' \
  || fail "safe world reset did not plan pregeneration chunks"

log "Server config overrides"
CONFIG_SOURCE="$TMP_DIR/config-overrides"
CONFIG_TARGET="$TMP_DIR/server-config"
mkdir -p "$CONFIG_SOURCE/nested" "$CONFIG_TARGET"
printf 'removeErroringEntities = true\n' > "$CONFIG_SOURCE/neoforge-server.toml"
printf 'answer=42\n' > "$CONFIG_SOURCE/nested/example.toml"
CONFIG_DRY="$("$PYTHON_BIN" "$ROOT_DIR/scripts/apply_config_overrides.py" --source "$CONFIG_SOURCE" --target "$CONFIG_TARGET" --dry-run)"
printf '%s\n' "$CONFIG_DRY" | grep -q 'config_overrides_changed=2' || fail "config override dry-run did not detect changes"
[ ! -e "$CONFIG_TARGET/neoforge-server.toml" ] || fail "config override dry-run wrote files"
CONFIG_APPLY="$("$PYTHON_BIN" "$ROOT_DIR/scripts/apply_config_overrides.py" --source "$CONFIG_SOURCE" --target "$CONFIG_TARGET")"
printf '%s\n' "$CONFIG_APPLY" | grep -q 'config_overrides_changed=2' || fail "config override apply did not report changes"
grep -q 'removeErroringEntities = true' "$CONFIG_TARGET/neoforge-server.toml" || fail "config override was not copied"
CONFIG_REPEAT="$("$PYTHON_BIN" "$ROOT_DIR/scripts/apply_config_overrides.py" --source "$CONFIG_SOURCE" --target "$CONFIG_TARGET")"
printf '%s\n' "$CONFIG_REPEAT" | grep -q 'config_overrides_changed=0' || fail "config override repeat was not a no-op"
grep -q '^	duck_tamed_no_follow = true$' "$ROOT_DIR/server-config/config-overrides/untitledduckmod-server.toml" \
  || fail "project Untitled Duck config must disable tamed duck following"
grep -q '^	goose_tamed_no_follow = true$' "$ROOT_DIR/server-config/config-overrides/untitledduckmod-server.toml" \
  || fail "project Untitled Duck config must disable tamed goose following"

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

log "Daily release pipeline dry run"
TODAY_RELEASE_KEY="$(date -u +%Y-%m-%d)_V9"
TODAY_RELEASE_ID="release_$(date -u +%Y%m%d)_V9"
PIPELINE_ACTIVITY_DRY="$TMP_DIR/update-activity.json"
PIPELINE_DRY="$("$PYTHON_BIN" "$ROOT_DIR/scripts/daily_release_pipeline.py" \
  --db "$DB" \
  --server-dir "$TMP_DIR/server" \
  --project-root "$TMP_DIR/project" \
  --release-root "$TMP_DIR/releases" \
  --public-downloads "$TMP_DIR/public/downloads" \
  --site-output "$TMP_DIR/site/public" \
  --release-backup-dir "$TMP_DIR/release_backups" \
  --release-key "$TODAY_RELEASE_KEY" \
  --activity-path "$PIPELINE_ACTIVITY_DRY" \
  --dry-run \
  --simulate-applied)"
printf '%s\n' "$PIPELINE_DRY" | grep -q 'daily_update.py' || fail "daily pipeline dry-run did not call daily updater"
printf '%s\n' "$PIPELINE_DRY" | grep -q -- '--no-create-release' || fail "daily pipeline dry-run did not defer release creation"
printf '%s\n' "$PIPELINE_DRY" | grep -q 'mod_acceptance_lab.py.*run-pyramid' || fail "daily pipeline dry-run did not call pyramid"
printf '%s\n' "$PIPELINE_DRY" | grep -q 'mod_acceptance_lab.py.*run-block-clients' || fail "daily pipeline dry-run did not call headless client block test"
printf '%s\n' "$PIPELINE_DRY" | grep -q 'sync_pummelchen_mods.py' || fail "daily pipeline dry-run did not sync project mods"
printf '%s\n' "$PIPELINE_DRY" | grep -q "release_manager.py.*create.*$TODAY_RELEASE_ID" || fail "daily pipeline dry-run did not create versioned release"
printf '%s\n' "$PIPELINE_DRY" | grep -q 'backup_releases_local.py' || fail "daily pipeline dry-run did not create release backups"
grep -q 'run_daily_release_pipeline.sh' "$ROOT_DIR/cron/pummelchen-daily-update" || fail "daily cron does not call full release pipeline"
grep -q '/etc/cron.d/pummelchen-daily-update' "$ROOT_DIR/scripts/deploy_project.sh" || fail "deploy does not install daily cron"
"$PYTHON_BIN" - "$ROOT_DIR" "$DB" <<'PY' || fail "daily pipeline release key increment failed"
import datetime as dt
import sqlite3
import sys
from pathlib import Path

root, db = sys.argv[1:3]
sys.path.insert(0, root + "/scripts")
import daily_release_pipeline

today = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d")
conn = sqlite3.connect(db)
conn.execute(
    """
    INSERT INTO mod_acceptance_releases(
        release_key, created_at, status, bundle_size, active_file_count
    ) VALUES (?, ?, 'passed', 10, 1)
    """,
    (f"{today}_V8", dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")),
)
conn.commit()
conn.close()
assert daily_release_pipeline.next_release_key(Path(db)) == f"{today}_V9"
PY
"$PYTHON_BIN" - "$DB" <<'PY'
import datetime as dt
import hashlib
import sqlite3
import sys

db = sys.argv[1]
conn = sqlite3.connect(db)
now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()
cur = conn.execute(
    "INSERT INTO imports(imported_at, source_file, spreadsheet_id, sheet_name, source_range, row_count) "
    "VALUES (?, 'status-fixture', '', 'fixture', '', 7)",
    (now,),
)
import_id = cur.lastrowid
rows = [
    ("Await Fixture", "Skipped", "Skipped: no compatible stable release", "Not included"),
    ("Dependency Fixture", "Skipped", "Skipped: requires Create 6.0.0+; no compatible Create NeoForge 26.1.x release found", "Not included"),
    ("Reference Fixture", "Skipped", "Skipped: not a server mod", "Not included"),
    ("Source Fixture", "Skipped", "No resolvable project", "Not included"),
    ("Fixed Fixture", "candidate", "Codex_Fixed candidate", "Included"),
    ("Duplicate Fixture", "OK", "OK", "Included"),
    ("Duplicate Fixture Copy", "OK", "OK", "Included"),
]
ids = []
for index, (name, tested, server_status, client_package) in enumerate(rows, start=1):
    payload = f"{name}\0{server_status}".encode()
    cur = conn.execute(
        """
        INSERT INTO mods(
            import_id, original_sheet_row, category, name, canonical_key, installation,
            entry_type, tested, target_mc, server_status, client_package,
            last_tested, active_status, status_rank, primary_url, row_hash, created_at, updated_at
        )
        VALUES (?, ?, 'Fixture', ?, ?, '', 'Mod', ?, '26.1.2', ?, ?,
                '', 'skipped', 20, ?, ?, ?, ?)
        """,
        (
            import_id,
            index,
            name,
            "duplicate-fixture" if "Duplicate Fixture" in name else name.lower().replace(" ", "-"),
            tested,
            server_status,
            client_package,
            "https://example.test/duplicate-fixture" if "Duplicate Fixture" in name else f"https://example.test/{index}",
            hashlib.sha256(payload).hexdigest(),
            now,
            now,
        ),
    )
    ids.append(cur.lastrowid)
conn.execute("UPDATE mods SET duplicate_of_id = ?, is_duplicate = 1 WHERE id = ?", (ids[-2], ids[-1]))
conn.execute("UPDATE mods SET duplicate_of_id = ?, is_duplicate = 1 WHERE id = ?", (ids[0], ids[4]))
conn.commit()
PY
"$PYTHON_BIN" "$ROOT_DIR/scripts/moddb.py" --db "$DB" normalize-statuses \
  | grep -q 'statuses_normalized=' || fail "status normalization command did not run"
"$PYTHON_BIN" - "$DB" <<'PY' || fail "status normalization did not classify ambiguous skipped rows"
import sqlite3
import sys

conn = sqlite3.connect(sys.argv[1])
expected = {
    "Await Fixture": "awaiting_compatible_release",
    "Dependency Fixture": "blocked_by_dependency",
    "Reference Fixture": "reference_only",
    "Source Fixture": "source_unresolved",
    "Fixed Fixture": "codex_fixed_candidate",
    "Duplicate Fixture Copy": "duplicate",
}
rows = dict(conn.execute("SELECT name, active_status FROM mods WHERE name IN (%s)" % ",".join("?" for _ in expected), tuple(expected)).fetchall())
assert rows == expected, rows
PY

log "Ultimate Plane install-state sync fixture"
SYNC_SERVER="$TMP_DIR/sync-server"
mkdir -p "$SYNC_SERVER/mods" "$SYNC_SERVER/client-package/mods"
printf '# section\tname\tsize\tsha256\turl_path\n' > "$TMP_DIR/empty-client-sync-manifest.tsv"
"$PYTHON_BIN" - "$DB" <<'PY'
import datetime as dt
import hashlib
import sqlite3
import sys

db = sys.argv[1]
conn = sqlite3.connect(db)
now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()
cur = conn.execute(
    "INSERT INTO imports(imported_at, source_file, spreadsheet_id, sheet_name, source_range, row_count) "
    "VALUES (?, 'ultimate-plane-sync-fixture', '', 'fixture', '', 1)",
    (now,),
)
import_id = cur.lastrowid
payload = b"Ultimate Plane Mod stale installed row"
cur = conn.execute(
    """
    INSERT INTO mods(
        import_id, original_sheet_row, category, name, canonical_key, installation,
        entry_type, tested, target_mc, server_status, client_package,
        last_tested, active_status, status_rank, primary_url, row_hash, created_at, updated_at
    )
    VALUES (?, 9001, 'Fixture', 'Ultimate Plane Mod', 'ultimate-plane-mod',
            'Server', 'Mod', 'OK', '26.1.2', 'OK', 'Included', '',
            'ok', 80, 'https://example.test/ultimate-plane-mod', ?, ?, ?)
    """,
    (import_id, hashlib.sha256(payload).hexdigest(), now, now),
)
mod_id = cur.lastrowid
conn.execute(
    """
    INSERT INTO mod_files(mod_id, role, file_name, path_hint, installed_on_server, included_in_client, status)
    VALUES (?, 'server_mod', 'plane-neoforge-1.5.8+26.1.2.jar', '/tmp/stale/mods', 1, 1, 'OK')
    """,
    (mod_id,),
)
conn.commit()
PY
"$PYTHON_BIN" "$ROOT_DIR/scripts/sync_mod_install_state.py" \
  --db "$DB" \
  --server-dir "$SYNC_SERVER" \
  --client-manifest "$TMP_DIR/empty-client-sync-manifest.tsv" \
  --filter-regex 'ultimate.*plane|plane-neoforge' \
  --apply \
  | tee "$TMP_DIR/ultimate-plane-sync.out"
grep -q 'file_changes=1' "$TMP_DIR/ultimate-plane-sync.out" || fail "Ultimate Plane sync did not clear stale file flags"
grep -q 'mod_status_changes=1' "$TMP_DIR/ultimate-plane-sync.out" || fail "Ultimate Plane sync did not update stale mod status"
"$PYTHON_BIN" - "$DB" <<'PY'
import sqlite3
import sys

conn = sqlite3.connect(sys.argv[1])
row = conn.execute(
    """
    SELECT m.active_status, m.server_status, m.client_package,
           f.installed_on_server, f.included_in_client
    FROM mods m
    JOIN mod_files f ON f.mod_id = m.id
    WHERE m.canonical_key = 'ultimate-plane-mod'
      AND f.file_name = 'plane-neoforge-1.5.8+26.1.2.jar'
    ORDER BY m.id DESC
    LIMIT 1
    """
).fetchone()
assert row == ("failed", "Rejected: Removed from current release: jar absent from live server mods and active client manifest", "Not included", 0, 0), row
PY

log "Release-manager fixture"
SERVER="$TMP_DIR/server"
RELEASES="$TMP_DIR/releases"
PUBLIC="$TMP_DIR/public/downloads"
mkdir -p "$SERVER/mods" "$SERVER/server-datapacks" "$SERVER/client-package/mods" \
  "$SERVER/client-package/resourcepacks" "$SERVER/client-package/shaderpacks" \
  "$SERVER/client-package/tools" "$SERVER/libraries/net/neoforged/neoforge/26.1.2.75"
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
"$PYTHON_BIN" "$ROOT_DIR/scripts/release_manager.py" \
  --db "$DB" --server-dir "$SERVER" --release-root "$RELEASES" --public-downloads "$PUBLIC" \
  create --release-id release_20260607_V1_test --notes "versioned backup fixture"
"$PYTHON_BIN" "$ROOT_DIR/scripts/backup_releases_local.py" \
  --release-root "$RELEASES" \
  --output-dir "$TMP_DIR/BackupDryRun" \
  --dry-run \
  | tee "$TMP_DIR/release-backup-dry-run.out"
grep -q 'skip_release=qa_release_1' "$TMP_DIR/release-backup-dry-run.out" || fail "release backup script did not skip non-version fixture release"
grep -q 'backup_release=release_20260607_V1_test' "$TMP_DIR/release-backup-dry-run.out" || fail "release backup script did not include versioned fixture release"
"$PYTHON_BIN" "$ROOT_DIR/scripts/backup_releases_local.py" \
  --release-root "$RELEASES" \
  --output-dir "$TMP_DIR/Backup" \
  --release-id release_20260607_V1_test \
  | tee "$TMP_DIR/release-backup.out"
grep -q 'release_backups=1' "$TMP_DIR/release-backup.out" || fail "release backup script did not back up versioned fixture release"
"$PYTHON_BIN" - "$TMP_DIR/Backup/Server_26.1.2_2026-06-07_V1.zip" "$TMP_DIR/Backup/Client_26.1.2_2026-06-07_V1.zip" <<'PY'
import sys
import zipfile

server_zip, client_zip = sys.argv[1:]
with zipfile.ZipFile(server_zip) as archive:
    names = set(archive.namelist())
    assert "server-files/mods/mod-a.jar" in names, "server backup missing server mod"
    assert "server-files/release-backup.json" in names, "server backup metadata missing"
with zipfile.ZipFile(client_zip) as archive:
    names = set(archive.namelist())
    assert "client-package/mods/client-mod-a.jar" in names, "client backup missing client mod"
    assert "client-package/release-backup.json" in names, "client backup metadata missing"
PY
"$PYTHON_BIN" "$ROOT_DIR/scripts/release_manager.py" \
  --db "$DB" --server-dir "$SERVER" --release-root "$RELEASES" --public-downloads "$PUBLIC" \
  create --label deploy --notes "generated version-style release fixture" \
  | tee "$TMP_DIR/release-generated-id.out"
grep -Eq '^release_id=release_[0-9]{8}_V[0-9]+_deploy$' "$TMP_DIR/release-generated-id.out" || fail "release manager did not generate a version-style release id"

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
"$PYTHON_BIN" - "$ROOT_DIR" "$TMP_DIR/jarjar-parent.jar" <<'PY'
from pathlib import Path
import io
import json
import sys
import zipfile

sys.path.insert(0, str(Path(sys.argv[1]) / "scripts"))
import mod_acceptance_lab

parent = Path(sys.argv[2])
nested_bytes = io.BytesIO()
with zipfile.ZipFile(nested_bytes, "w") as nested:
    nested.writestr(
        "META-INF/neoforge.mods.toml",
        """
modLoader="javafml"
loaderVersion="[1,)"
license="MIT"
[[mods]]
modId="pummeljarjarlib"
version="1.0.0"
displayName="Pummel JarJar Lib"
""",
    )
with zipfile.ZipFile(parent, "w") as archive:
    archive.writestr(
        "META-INF/neoforge.mods.toml",
        """
modLoader="javafml"
loaderVersion="[1,)"
license="MIT"
[[mods]]
modId="pummeljarjarparent"
version="1.0.0"
displayName="Pummel JarJar Parent"
[[dependencies.pummeljarjarparent]]
modId="pummeljarjarlib"
mandatory=true
versionRange="[1,)"
ordering="NONE"
side="BOTH"
""",
    )
    archive.writestr("META-INF/jarjar/pummeljarjarlib-1.0.0.jar", nested_bytes.getvalue())
    archive.writestr(
        "META-INF/jarjar/metadata.json",
        json.dumps(
            {
                "jars": [
                    {
                        "identifier": {"group": "test", "artifact": "pummeljarjarlib"},
                        "version": {"range": "[1,)", "artifactVersion": "1.0.0"},
                        "path": "META-INF/jarjar/pummeljarjarlib-1.0.0.jar",
                    }
                ]
            }
        ),
    )
jar = mod_acceptance_lab.build_mod_jar(parent)
assert "pummeljarjarlib" in jar.mod_ids, jar
assert "pummeljarjarlib" not in jar.required_deps, jar
PY
"$PYTHON_BIN" - "$ROOT_DIR" "$TMP_DIR/gbg-provider.jar" "$TMP_DIR/gbg-extension.jar" <<'PY'
from pathlib import Path
import json
import sys
import zipfile

sys.path.insert(0, str(Path(sys.argv[1]) / "scripts"))
import mod_acceptance_lab

provider = Path(sys.argv[2])
extension = Path(sys.argv[3])
with zipfile.ZipFile(provider, "w") as archive:
    archive.writestr(
        "META-INF/neoforge.mods.toml",
        """
modLoader="javafml"
loaderVersion="[1,)"
license="MIT"
[[mods]]
modId="mrgamingbarnsguns"
version="1.0.0"
displayName="Gamingbarn Fixture"
""",
    )
    archive.writestr("data/gbg/enchantment/shoot_gun.json", "{}")
with zipfile.ZipFile(extension, "w") as archive:
    archive.writestr(
        "data/example/loot_table/guns/test.json",
        json.dumps({"components": {"minecraft:enchantments": {"gbg:shoot_gun": 1}}}),
    )
provider_jar = mod_acceptance_lab.build_mod_jar(provider)
extension_jar = mod_acceptance_lab.build_mod_jar(extension)
assert "gbg" in provider_jar.mod_ids, provider_jar
assert "mrgamingbarnsguns" in provider_jar.mod_ids, provider_jar
assert "gbg" in extension_jar.required_deps, extension_jar
included, missing = mod_acceptance_lab.dependency_closure([extension_jar], [extension_jar, provider_jar])
assert not missing, missing
assert {jar.path for jar in included} == {provider, extension}, included
PY
"$PYTHON_BIN" - "$ROOT_DIR" "$TMP_DIR/quack-gecko-user.jar" <<'PY'
from pathlib import Path
import sys
import zipfile

sys.path.insert(0, str(Path(sys.argv[1]) / "scripts"))
import mod_acceptance_lab

path = Path(sys.argv[2])
with zipfile.ZipFile(path, "w") as archive:
    archive.writestr("example/NeedsGecko.class", b"com/geckolib/animatable/GeoEntity")
jar = mod_acceptance_lab.build_mod_jar(path)
assert "geckolib" in jar.required_deps, jar
PY
FIXED_JAR="$TMP_DIR/codex-fixed-fixture.jar"
printf 'fixed jar\n' > "$FIXED_JAR"
ORIGINAL_MOD_ID="$("$PYTHON_BIN" - "$DB" <<'PY'
import datetime as dt
import hashlib
import sqlite3
import sys

conn = sqlite3.connect(sys.argv[1])
now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()
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
"$PYTHON_BIN" - "$DB" <<'PY'
import datetime as dt
import sqlite3
import sys

conn = sqlite3.connect(sys.argv[1])
now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()
cur = conn.execute(
    "INSERT INTO mod_acceptance_releases(release_key, created_at, status, bundle_size, active_file_count, notes) "
    "VALUES ('qa_acceptance', ?, 'running', 2, 2, 'fixture')",
    (now,),
)
release_id = cur.lastrowid
conn.execute(
    """
    INSERT INTO mod_acceptance_blocks(
        acceptance_release_id, level, ordinal, block_key, status,
        target_file_names, included_file_names, created_at
    )
    VALUES (?, 0, 1, 'L00_B001', 'passed',
            'pummelchen-dependent-1.0.0.jar',
            'pummelchen-dependent-1.0.0.jar\npummelchen-lib-1.0.0.jar',
            ?)
    """,
    (release_id, now),
)
conn.commit()
PY
"$PYTHON_BIN" "$ROOT_DIR/scripts/mod_acceptance_lab.py" --db "$DB" --server-dir "$ACCEPTANCE_SERVER" run-block-client \
  --release-key qa_acceptance --level 0 --ordinal 1 --dry-run \
  | grep -q 'included_server_jars=2' || fail "block-client dry-run did not resolve included jars"
"$PYTHON_BIN" - "$DB" <<'PY'
import datetime as dt
import sqlite3
import sys

conn = sqlite3.connect(sys.argv[1])
now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()
release_id = conn.execute(
    "SELECT id FROM mod_acceptance_releases WHERE release_key = 'qa_acceptance'"
).fetchone()[0]
conn.execute(
    """
    INSERT INTO mod_acceptance_blocks(
        acceptance_release_id, level, ordinal, block_key, status,
        target_file_names, included_file_names, created_at
    )
    VALUES (?, 0, 2, 'L00_B002', 'passed',
            'pummelchen-dependent-1.0.0.jar',
            'pummelchen-dependent-1.0.0.jar',
            ?)
    """,
    (release_id, now),
)
conn.commit()
PY
if "$PYTHON_BIN" "$ROOT_DIR/scripts/mod_acceptance_lab.py" --db "$DB" --server-dir "$ACCEPTANCE_SERVER" run-block-client \
  --release-key qa_acceptance --level 0 --ordinal 2 --dry-run >"$TMP_DIR/block-client-missing-deps.out" 2>&1; then
  fail "block-client dry-run allowed an omitted dependency"
fi
grep -q 'missing_required_dependencies=pummelchen-dependent-1.0.0.jar requires pummellib' \
  "$TMP_DIR/block-client-missing-deps.out" || fail "block-client dry-run did not report omitted dependency"
cat > "$TMP_DIR/acceptance-errors.log" <<'LOG'
[15:07:36] [NeoForge Version Check/WARN] [ne.ne.fm.VersionChecker/]: Failed to process update information
com.google.gson.JsonSyntaxException: java.lang.IllegalStateException: Expected BEGIN_OBJECT but was STRING at line 1 column 1 path $
Caused by: java.lang.IllegalStateException: Expected BEGIN_OBJECT but was STRING at line 1 column 1 path $
[17:46:00] [Worker-Main-2/ERROR] [minecraft/BlockAttachedEntity]: Block-attached entity at invalid position: BlockPos{x=-177, y=-34, z=759}
[19:13:05] [Worker-Main-2/ERROR] [minecraft/JigsawPlacement]: No starting jigsaw minecraft:start found in start pool mot_structures:well/cherry
[15:24:07] [Worker-Main-1/ERROR] [minecraft/SimpleJsonResourceReloadListener]: Couldn't parse data file 'example:guns/test' from 'example:loot_table/guns/test.json'
LOG
"$PYTHON_BIN" - "$ROOT_DIR" "$TMP_DIR/acceptance-errors.log" <<'PY'
from pathlib import Path
import sys

sys.path.insert(0, str(Path(sys.argv[1]) / "scripts"))
import mod_acceptance_lab

count, severe = mod_acceptance_lab.severe_errors(Path(sys.argv[2]))
assert count >= 1, (count, severe)
assert len(severe) == 1, (count, severe)
assert "SimpleJsonResourceReloadListener" in severe[0], severe
PY
"$PYTHON_BIN" - "$TMP_DIR/gbg-source.jar" <<'PY'
from pathlib import Path
import json
import sys
import zipfile

with zipfile.ZipFile(Path(sys.argv[1]), "w") as archive:
    archive.writestr(
        "data/example/loot_table/guns/test.json",
        json.dumps(
            {
                "pools": [
                    {
                        "entries": [
                            {
                                "functions": [
                                    {
                                        "function": "minecraft:set_components",
                                        "components": {"minecraft:enchantments": {"gbg:shoot_gun": 1}},
                                    }
                                ]
                            }
                        ]
                    }
                ]
            }
        ),
    )
PY
"$PYTHON_BIN" "$ROOT_DIR/scripts/patch_gbg_enchantments.py" "$TMP_DIR/gbg-source.jar" "$TMP_DIR/gbg-patched.jar" \
  | grep -q 'patched_components=1' || fail "GBG enchantment patcher did not rewrite fixture"
"$PYTHON_BIN" - "$TMP_DIR/gbg-patched.jar" <<'PY' || fail "GBG enchantment patcher wrote unexpected JSON"
from pathlib import Path
import json
import sys
import zipfile

with zipfile.ZipFile(Path(sys.argv[1])) as archive:
    data = json.loads(archive.read("data/example/loot_table/guns/test.json"))
value = data["pools"][0]["entries"][0]["functions"][0]["components"]["minecraft:enchantments"]
assert value == {"levels": {"gbg:shoot_gun": 1}}, value
PY
"$PYTHON_BIN" - "$TMP_DIR/mots-broken.jar" <<'PY'
from pathlib import Path
import sys
import zipfile

with zipfile.ZipFile(Path(sys.argv[1]), "w") as archive:
    archive.writestr(
        "assets/mot/lang/en_us.json",
        """{
    "item.mot.chart.village_taiga": "Taiga Village Chart"
    "item.mot.chart.explorer_jungle": "Jungle Explorer Chart"


    "advancement.mot.adventure.find_resin_crypt.title": "Echoing Creaks"
}
""",
    )
PY
"$PYTHON_BIN" "$ROOT_DIR/scripts/patch_mots_structures_lang.py" "$TMP_DIR/mots-broken.jar" "$TMP_DIR/mots-fixed.jar" \
  | grep -q 'patched_resource_count=2' || fail "MOTS language patcher did not repair fixture"
"$PYTHON_BIN" - "$TMP_DIR/mots-fixed.jar" <<'PY' || fail "MOTS language patcher wrote invalid JSON"
from pathlib import Path
import json
import sys
import zipfile

with zipfile.ZipFile(Path(sys.argv[1])) as archive:
    data = json.loads(archive.read("assets/mot/lang/en_us.json"))
assert data["item.mot.chart.village_taiga"] == "Taiga Village Chart", data
assert data["item.mot.chart.explorer_jungle"] == "Jungle Explorer Chart", data
PY
"$PYTHON_BIN" - "$TMP_DIR/productivefarming-broken.jar" <<'PY'
from pathlib import Path
import json
import sys
import zipfile

broken = {
    "parent": "neoforge:item/bucket",
    "loader": "neoforge:fluid_container",
    "fluid": "productivefarming:nutrient_water",
}
with zipfile.ZipFile(Path(sys.argv[1]), "w") as archive:
    archive.writestr("assets/productivefarming/models/item/nutrient_water_bucket.json", json.dumps(broken))
    archive.writestr("assets/productivefarming/items/nutrient_water_bucket.json", json.dumps({"model": {"type": "neoforge:fluid_container"}}))
PY
"$PYTHON_BIN" "$ROOT_DIR/scripts/patch_productivefarming_bucket_model.py" \
  "$TMP_DIR/productivefarming-broken.jar" "$TMP_DIR/productivefarming-fixed.jar" \
  | grep -q 'patched_models=2' || fail "Productive Farming bucket patcher did not repair fixture"
"$PYTHON_BIN" - "$TMP_DIR/productivefarming-fixed.jar" <<'PY' || fail "Productive Farming bucket patcher wrote unexpected JSON"
from pathlib import Path
import json
import sys
import zipfile

with zipfile.ZipFile(Path(sys.argv[1])) as archive:
    item = json.loads(archive.read("assets/productivefarming/items/nutrient_water_bucket.json"))
    assert item == {
        "model": {
            "type": "minecraft:model",
            "model": "minecraft:item/water_bucket",
        }
    }, item
    model = json.loads(archive.read("assets/productivefarming/models/item/nutrient_water_bucket.json"))
    assert model["parent"] == "minecraft:item/generated", model
    assert model["textures"]["layer0"] == "minecraft:item/water_bucket", model
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
grep -q 'hmc_specifics=hmc-specifics-26.1.2-neoforge-latest.jar' /tmp/headless-sync.$$ || fail "headless client sync did not install HMC-Specifics"
rm -f /tmp/headless-sync.$$
[ -f "$HEADLESS_BASE/game/options.txt" ] || fail "headless client sync did not seed options.txt"
grep -q '^simulationDistance:5$' "$HEADLESS_BASE/game/options.txt" || fail "headless client sync wrote invalid simulation distance"
"$PYTHON_BIN" "$ROOT_DIR/scripts/headless_client_lab.py" --db "$DB" --server-dir "$HEADLESS_SERVER" --base-dir "$HEADLESS_BASE" run --dry-run \
  | grep -q 'launch=launch neoforge:26.1.2 -specifics' || fail "headless client dry-run did not print launch command"
"$PYTHON_BIN" "$ROOT_DIR/scripts/headless_client_lab.py" --db "$DB" --server-dir "$HEADLESS_SERVER" --base-dir "$HEADLESS_BASE" run --dry-run --offline \
  | grep -q -- '-offline' || fail "headless client offline dry-run did not include offline flag"
"$PYTHON_BIN" - "$ROOT_DIR" "$TMP_DIR" <<'PY' || fail "headless client fatal classifier mishandled Realms offline auth noise"
import io
import os
import shutil
from pathlib import Path
import sys
import zipfile

root = Path(sys.argv[1])
tmp = Path(sys.argv[2])
sys.path.insert(0, str(root / "scripts"))
import headless_client_lab

realms_log = tmp / "realms-invalid-session.log"
realms_log.write_text(
    "[Download-2/INFO] [mojang/RealmsClient]: Could not authorize you against Realms server: "
    "javax.ws.rs.BadRequestException: Invalid session\n"
    "com.mojang.realmsclient.exception.RealmsServiceException: "
    "Realms authentication error with message 'javax.ws.rs.BadRequestException: Invalid session'\n",
    encoding="utf-8",
)
assert headless_client_lab.fatal_lines([realms_log]) == []
login_log = tmp / "multiplayer-invalid-session.log"
login_log.write_text("multiplayer.disconnect.unverified_username: Invalid session\n", encoding="utf-8")
assert headless_client_lab.fatal_lines([login_log]), "real multiplayer invalid-session failure must remain fatal"
stack_log = tmp / "client-stack-overflow.log"
stack_log.write_text(
    "[Render thread/ERROR] [net.minecraft.util.thread.BlockableEventLoop/FATAL]: Error executing task on Client\n"
    "Caused by: java.lang.StackOverflowError\n",
    encoding="utf-8",
)
assert headless_client_lab.fatal_lines([stack_log]), "client StackOverflowError must be fatal"
class_log = tmp / "missing-client-class.log"
class_log.write_text("java.lang.NoClassDefFoundError: com/example/MissingClass\n", encoding="utf-8")
assert headless_client_lab.fatal_lines([class_log]), "client missing-class failures must be fatal"
kqueue_log = tmp / "linux-headless-kqueue.log"
kqueue_log.write_text(
    "org.apache.logging.log4j.core.appender.AppenderLoggingException: "
    "java.lang.NoClassDefFoundError: Could not initialize class io.netty.channel.kqueue.Native\n"
    "Caused by: java.lang.IllegalStateException: Only supported on OSX/BSD\n",
    encoding="utf-8",
)
assert headless_client_lab.fatal_lines([kqueue_log]) == []
public_key_log = tmp / "offline-publickeys-timeout.log"
public_key_log.write_text(
    "com.mojang.authlib.exceptions.MinecraftClientException: "
    "Failed to read from https://api.minecraftservices.com/publickeys due to Connect timed out\n",
    encoding="utf-8",
)
assert headless_client_lab.fatal_lines([public_key_log]) == []
server_timeout_log = tmp / "server-timeout.log"
server_timeout_log.write_text("Failed to connect to the server: Timed out\n", encoding="utf-8")
assert headless_client_lab.fatal_lines([server_timeout_log]), "server connection timeout must remain fatal"
loading_error_log = tmp / "loading-error-screen.log"
loading_error_log.write_text("Screen: net.neoforged.neoforge.client.gui.LoadingErrorScreen\n", encoding="utf-8")
assert headless_client_lab.fatal_lines([loading_error_log]) == []
fatal_loading = "Screen: net.neoforged.neoforge.client.gui.LoadingErrorScreen\nButtons:\n0    Quit Game\n"
assert headless_client_lab.is_fatal_loading_error_screen(fatal_loading)
dismissible_loading = (
    "Screen: net.neoforged.neoforge.client.gui.LoadingErrorScreen\n"
    "Buttons:\n"
    "2    Proceed to main menu   50   246   185   20   1   ExtendedButton\n"
)
assert not headless_client_lab.is_fatal_loading_error_screen(dismissible_loading)
assert headless_client_lab.is_dismissible_loading_error_screen(dismissible_loading)
class FakeProc:
    stdin = io.StringIO()

fake = FakeProc()
attempted = {}
headless_client_lab.dismiss_startup_dialog(
    fake,
    dismissible_loading,
    server_host="127.0.0.1",
    server_port=25690,
    display="",
    attempted_actions=attempted,
)
commands = fake.stdin.getvalue().splitlines()
assert commands == ["connect 127.0.0.1 25690"], commands
assert attempted == {"loading_error_connect": 1}, attempted
assert not any(command.startswith("key ") for command in commands), commands
assert headless_client_lab.gui_button_center(dismissible_loading, "Proceed to main menu") == (142, 256)
assert (
    headless_client_lab.hmc_legacy_specifics_name("26.1.2", "neoforge")
    == "hmc-specifics-26.1.2-2.4.0-neoforge-release.jar"
)
cache_src = tmp / "hmc-specifics-26.1.2-neoforge-latest.jar"
with zipfile.ZipFile(cache_src, "w") as archive:
    archive.writestr("META-INF/MANIFEST.MF", "Manifest-Version: 1.0\n")
game_mods = tmp / "game" / "mods"
game_mods.mkdir(parents=True)
stale_game_specifics = game_mods / cache_src.name
shutil.copy2(cache_src, stale_game_specifics)
original_ensure = headless_client_lab.ensure_hmc_specifics
headless_client_lab.ensure_hmc_specifics = lambda game_dir, minecraft_version, loader: cache_src
cwd = Path.cwd()
cache_cwd = tmp / "hmc-cache-cwd"
cache_cwd.mkdir()
os.chdir(cache_cwd)
try:
    seeded = headless_client_lab.seed_hmc_specifics_cache(tmp / "game", "26.1.2", "neoforge")
finally:
    os.chdir(cwd)
    headless_client_lab.ensure_hmc_specifics = original_ensure
assert seeded.name == "hmc-specifics-26.1.2-2.4.0-neoforge-release.jar"
assert seeded.exists()
assert zipfile.is_zipfile(seeded)
assert not stale_game_specifics.exists()
connect_screen = """Screen: net.minecraft.client.gui.screens.ConnectScreen
Buttons:
0    Cancel   140   199   200   20   1   Plain
"""
assert not headless_client_lab.is_blocking_startup_dialog(connect_screen)
title_screen = "Screen: net.minecraft.client.gui.screens.TitleScreen\n"
assert headless_client_lab.is_title_screen(title_screen)
assert not headless_client_lab.is_blocking_startup_dialog(title_screen)
mod_error_log = tmp / "mod-loading-error.log"
mod_error_log.write_text(
    "Loading errors encountered:\n"
    "- More Babies (more_babies) has failed to load correctly\n"
    "Mod yumemigusa requires oelib 6.2.3 or above\n"
    "Currently, oelib is not installed\n",
    encoding="utf-8",
)
assert len(headless_client_lab.fatal_lines([mod_error_log])) >= 3
loading = """Screen: net.minecraft.client.gui.screens.GenericMessageScreen
Other:
0    Loading Minecraft   177   131   126   33   FocusableTextWidget
"""
assert not headless_client_lab.is_blocking_startup_dialog(loading)
welcome = """Screen: net.minecraft.client.gui.screens.dialog.MultiButtonDialogScreen
Other:
1    Welcome to Chems' Guns!   197   13   55   9   StringWidget
"""
assert headless_client_lab.is_blocking_startup_dialog(welcome)
PY

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

log "Release cleanup fixture"
CLEAN_PROJECT="$TMP_DIR/project-root"
mkdir -p "$CLEAN_PROJECT/downloads/stale-cache" \
  "$CLEAN_PROJECT/test_sources/pyramid_old" \
  "$CLEAN_PROJECT/headless_client_lab/game/mods" \
  "$CLEAN_PROJECT/headless_client_lab/game/resourcepacks" \
  "$CLEAN_PROJECT/client_log_uploads/2026/01/01" \
  "$SERVER/codex-downloads/daily_update" \
  "$SERVER/mods.rollback/old-update" \
  "$PUBLIC/releases"
printf 'stale\n' > "$CLEAN_PROJECT/downloads/stale-cache/file.tmp"
printf 'source\n' > "$CLEAN_PROJECT/test_sources/pyramid_old/source.jar"
printf 'headless\n' > "$CLEAN_PROJECT/headless_client_lab/game/mods/cache.jar"
printf 'resource\n' > "$CLEAN_PROJECT/headless_client_lab/game/resourcepacks/cache.zip"
printf 'diagnostic\n' > "$CLEAN_PROJECT/client_log_uploads/2026/01/01/client.zip"
printf 'partial\n' > "$CLEAN_PROJECT/client_log_uploads/2026/01/01/.upload-stalled"
printf 'download\n' > "$SERVER/codex-downloads/daily_update/cache.jar"
printf 'rollback\n' > "$SERVER/mods.rollback/old-update/mod.jar"
ln -s "$RELEASES/missing/public" "$PUBLIC/releases/release_missing_cleanup"
"$PYTHON_BIN" "$ROOT_DIR/scripts/release_manager.py" \
  --db "$DB" --server-dir "$SERVER" --release-root "$RELEASES" --public-downloads "$PUBLIC" \
  cleanup --project-root "$CLEAN_PROJECT" --keep-releases 0 --temp-max-age-hours 0 \
  --rollback-keep-days 0 --lab-keep-days 0 --client-upload-keep-days 0 \
  --client-uploads "$CLEAN_PROJECT/client_log_uploads" --upload-temp-max-age-hours 0 \
  --include-headless-cache >/dev/null
[ -d "$RELEASES/qa_release_1" ] || fail "cleanup removed active release"
[ ! -e "$PUBLIC/releases/release_missing_cleanup" ] || fail "cleanup kept stale public release link"
[ ! -e "$CLEAN_PROJECT/downloads/stale-cache" ] || fail "cleanup kept project download cache"
[ ! -e "$CLEAN_PROJECT/test_sources/pyramid_old" ] || fail "cleanup kept recreatable test source"
[ ! -e "$CLEAN_PROJECT/headless_client_lab/game/mods" ] || fail "cleanup kept headless mod cache"
[ ! -e "$CLEAN_PROJECT/client_log_uploads/2026/01/01/client.zip" ] || fail "cleanup kept old client upload"
[ ! -e "$CLEAN_PROJECT/client_log_uploads/2026/01/01/.upload-stalled" ] || fail "cleanup kept stale upload temp"
[ ! -e "$SERVER/codex-downloads/daily_update" ] || fail "cleanup kept server download cache"
[ ! -e "$SERVER/mods.rollback/old-update" ] || fail "cleanup kept old rollback snapshot"
"$PYTHON_BIN" - "$DB" <<'PY' || fail "cleanup event was not recorded"
import sqlite3
import sys

conn = sqlite3.connect(sys.argv[1])
count = conn.execute("SELECT COUNT(*) FROM release_events WHERE event_type = 'cleanup'").fetchone()[0]
assert count >= 1, count
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
"$PYTHON_BIN" - "$RESOURCE_PACKAGE/resourcepacks/decimal-pack.zip" <<'PY'
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1], "w") as archive:
    archive.writestr(
        "pack.mcmeta",
        '{"pack":{"pack_format":68.0,"min_format":65.0,"max_format":99.0,'
        '"description":"fixture",}}',
    )
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
  | grep -q 'resource_pack_metadata_changes=5' || fail "resource pack sanitizer did not report changes"
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
"$PYTHON_BIN" - "$RESOURCE_PACKAGE/resourcepacks/decimal-pack.zip" <<'PY'
import json
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as archive:
    metadata = json.loads(archive.read("pack.mcmeta"))
assert metadata["pack"]["pack_format"] == 68, metadata
assert metadata["pack"]["supported_formats"] == [65, 99], metadata
assert "min_format" not in metadata["pack"], metadata
assert "max_format" not in metadata["pack"], metadata
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
  --minecraft-version 26.1.2 --neoforge-version 26.1.2.75

log "NeoForge version preflight fixture"
NEOFORGE_METADATA="$TMP_DIR/neoforge-maven-metadata.xml"
NEOFORGE_STATUS="$TMP_DIR/neoforge-version.json"
cat > "$NEOFORGE_METADATA" <<'XML'
<metadata>
  <versioning>
    <versions>
      <version>26.1.2.70</version>
      <version>26.1.2.75</version>
      <version>26.1.2.76</version>
      <version>26.1.3.1</version>
    </versions>
  </versioning>
</metadata>
XML
"$PYTHON_BIN" "$ROOT_DIR/scripts/check_neoforge_version.py" \
  --current 26.1.2.75 \
  --minecraft-version 26.1.2 \
  --metadata-url "file://$NEOFORGE_METADATA" \
  --write-json "$NEOFORGE_STATUS"
"$PYTHON_BIN" - "$NEOFORGE_STATUS" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert payload["latest_neoforge_version"] == "26.1.2.76", payload
assert payload["update_available"] is True, payload
assert payload["status"] == "update_available", payload
PY
"$PYTHON_BIN" - "$DEP_PACKAGE/mods/client-b.jar" <<'PY'
from pathlib import Path
import sys
Path(sys.argv[1]).unlink()
PY
if "$PYTHON_BIN" "$ROOT_DIR/scripts/check_client_mod_dependencies.py" "$DEP_PACKAGE" \
  --minecraft-version 26.1.2 --neoforge-version 26.1.2.75 >/tmp/pummelchen-depcheck.$$ 2>&1; then
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
  "$AUTO_REMOTE/downloads/client-files/tools" \
  "$AUTO_MC/mods" "$AUTO_MC/resourcepacks/Old Pack" "$AUTO_MC/shaderpacks/OldShader" \
  "$AUTO_MC/config"
printf 'wanted mod\n' > "$AUTO_REMOTE/downloads/client-files/mods/wanted.jar"
printf 'wanted resource\n' > "$AUTO_REMOTE/downloads/client-files/resourcepacks/Wanted Pack[1].zip"
printf 'wanted shader\n' > "$AUTO_REMOTE/downloads/client-files/shaderpacks/wanted-shader.zip"
printf '#!/bin/sh\necho updated\n' > "$AUTO_REMOTE/downloads/client-files/tools/wanted-tool.sh"
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
  printf 'tools\twanted-tool.sh\t%s\tsha256:%s\tfile://%s\n' \
    "$(wc -c < "$AUTO_REMOTE/downloads/client-files/tools/wanted-tool.sh" | tr -d '[:space:]')" \
    "$(sha256_value "$AUTO_REMOTE/downloads/client-files/tools/wanted-tool.sh")" \
    "$AUTO_REMOTE/downloads/client-files/tools/wanted-tool.sh"
} > "$AUTO_REMOTE/client-sync-manifest.tsv"
PUMMELCHEN_SYNC_MANIFEST_URL="file://$AUTO_REMOTE/client-sync-manifest.tsv" \
  PUMMELCHEN_RELEASE_ID="qa-auto-release" \
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
[ -x "$AUTO_HOME/bin/wanted-tool.sh" ] || fail "auto-updater did not install wanted tool as executable"
[ ! -e "$AUTO_MC/mods/old.jar" ] || fail "auto-updater left unmanaged old mod active"
[ ! -e "$AUTO_MC/resourcepacks/Old Pack" ] || fail "auto-updater left unmanaged resource pack active"
[ ! -e "$AUTO_MC/shaderpacks/OldShader" ] || fail "auto-updater left unmanaged shader pack active"
find "$AUTO_MC" -maxdepth 2 -path '*before-pummelchen-auto-*/*' -print | grep -q 'Old Pack' || fail "auto-updater did not quarantine old resource pack"
grep -Fq 'resourcePacks:["vanilla","mod_resources","file/ModernArch v2.8.2 [26.1] [128x].zip","file/ModernArch FA Extension v2.2.zip","file/ModernArch Denser Grass Addon.zip"]' "$AUTO_MC/options.txt" || fail "auto-updater did not enable ModernArch resource pack stack"
grep -Fq 'incompatibleResourcePacks:[]' "$AUTO_MC/options.txt" || fail "auto-updater did not reset incompatible resource packs"
grep -Fxq 'shaderPack=BSL_v10.1.3.zip' "$AUTO_MC/optionsshaders.txt" || fail "auto-updater did not select BSL in options shader"
grep -Fxq 'shaderPack=BSL_v10.1.3.zip' "$AUTO_MC/config/iris.properties" || fail "auto-updater did not select BSL in Iris shader"
grep -Fxq 'enableShaders=true' "$AUTO_MC/config/iris.properties" || fail "auto-updater did not enable Iris shaders"
grep -Fxq 'duck_tamed_no_follow=true' "$AUTO_MC/config/untitledduckmod-server.toml" || fail "auto-updater did not disable tamed duck following"
grep -Fxq 'goose_tamed_no_follow=true' "$AUTO_MC/config/untitledduckmod-server.toml" || fail "auto-updater did not disable tamed goose following"
grep -Fxq 'showLoadWarnings=false' "$AUTO_MC/config/neoforge-client.toml" || fail "auto-updater did not quiet NeoForge load warnings"
grep -Fxq 'showLoadWarnings=false' "$AUTO_MC/config/forge-client.toml" || fail "auto-updater did not quiet Forge load warnings"
grep -Fxq 'showCheckScreen=false' "$AUTO_MC/config/yuushya-client.toml" || fail "auto-updater did not quiet Yuushya check screen"
grep -Fq '"enableInGameMessage":{"value":false}' "$AUTO_MC/config/underground_village/common.json" || fail "auto-updater did not disable underground village message"
grep -Fq '"showTutorial":{"value":false}' "$AUTO_MC/config/mtsconfigclient.json" || fail "auto-updater did not disable MTS tutorial"
mkdir -p "$AUTO_MC/.pummelchen"
printf 'qa-auto-release\n' > "$AUTO_MC/.pummelchen/installed-release.txt"
PUMMELCHEN_SYNC_MANIFEST_URL="file://$AUTO_REMOTE/client-sync-manifest.tsv" \
  PUMMELCHEN_RELEASE_ID="qa-auto-release" \
  PUMMELCHEN_BASE_URL="file://$AUTO_REMOTE" \
  MINECRAFT_DIR="$AUTO_MC" \
  PUMMELCHEN_HOME="$AUTO_HOME" \
  PUMMELCHEN_LOG_DIR="$AUTO_LOGS" \
  PUMMELCHEN_CACHE_DIR="$AUTO_CACHE" \
  PUMMELCHEN_LOG_TO_STDOUT=1 \
  bash "$ROOT_DIR/client-package/tools/pummelchen-auto-update.sh" --force > "$TMP_DIR/auto-update-current.txt"
grep -Fq 'Server mod release:' "$TMP_DIR/auto-update-current.txt" || fail "auto-updater current run did not print server release"
grep -Fq 'Client mod release:' "$TMP_DIR/auto-update-current.txt" || fail "auto-updater current run did not print client release"
grep -Fq 'Status:             all synced, no downloads required' "$TMP_DIR/auto-update-current.txt" || fail "auto-updater current run did not print no-download summary"

log "macOS client smoke launcher fixture"
SMOKE_MC="$TMP_DIR/client-smoke-mc"
mkdir -p "$SMOKE_MC/versions/26.1.2" "$SMOKE_MC/versions/neoforge-26.1.2.75" \
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
(root / "versions/neoforge-26.1.2.75/neoforge-26.1.2.75.json").write_text(json.dumps({
    "id": "neoforge-26.1.2.75",
    "inheritsFrom": "26.1.2",
    "mainClass": "net.neoforged.fml.startup.Client",
    "arguments": {
        "game": ["--fml.neoForgeVersion", "26.1.2.75"],
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
grep -q "Last Mod Version" "$SITE_OUT/index.html" || fail "status site release label missing"
grep -q "Minecraft Players" "$SITE_OUT/index.html" || fail "status site player label missing"
grep -q "Client Mod Pack Generated" "$SITE_OUT/index.html" || fail "status site client pack generated label missing"
if grep -q "Minecraft RSS" "$SITE_OUT/index.html"; then
  fail "status site still exposes Minecraft RSS"
fi
"$PYTHON_BIN" - "$ROOT_DIR/scripts" <<'PY'
import sys

scripts_dir = sys.argv[1]
sys.path.insert(0, scripts_dir)
import tested_updates_worker

cases = {
    "antiquetradingship-1.0.0 Neoforge 26.1.2.jar": "antiquetradingship",
    "cleanswing-1.9-26.1.jar": "cleanswing",
    "epherolib-neoforge-26.1-1.3.0.jar": "epherolib",
}
for file_name, expected_slug in cases.items():
    slug = tested_updates_worker.slug_from_file_name(file_name)
    if slug != expected_slug:
        raise SystemExit(f"bad tested update slug for {file_name}: {slug!r}")
basenames = tested_updates_worker.file_name_basenames("antiquetradingship-1.0.0 Neoforge 26.1.2.jar")
if basenames != ["antiquetradingship-1.0.0-Neoforge-26.1.2"]:
    raise SystemExit(f"bad tested update basenames: {basenames!r}")
PY

log "Live stats and exporter"
"$PYTHON_BIN" "$ROOT_DIR/scripts/live_stats_feed.py" --db "$DB" --server-dir "$SERVER" --output "$TMP_DIR/live-stats.json" --state "$TMP_DIR/live-state.json"
grep -q "Last Mod Version" "$TMP_DIR/live-stats.json" || fail "live stats missing release data"
"$PYTHON_BIN" - "$TMP_DIR/live-stats.json" "$CLIENT_ZIP_SHA" "$ROOT_DIR/scripts" <<'PY'
import json
import sys

stats_path, expected_sha, scripts_dir = sys.argv[1:]
sys.path.insert(0, scripts_dir)
import live_stats_feed

payload = json.loads(open(stats_path, encoding="utf-8").read())
stats = payload["stats"]
metrics = payload["metrics"]
assert stats["Client Mod Pack"] == "11 B", "live stats missing client package size"
assert stats["Client Mod Pack SHA256"] == expected_sha, "live stats missing client package checksum"
assert stats["Client Mod Pack Generated"], "live stats missing client package generated timestamp"
assert "Client Mod Pack Generated ISO" in stats, "live stats missing client package generated ISO timestamp"
assert live_stats_feed.clamp_percent(138.1) == 100.0, "percent clamp does not cap overload values"
for key in ("cpu_percent", "ram_used_percent", "disk_used_percent", "disk_free_percent", "network_traffic_percent"):
    assert key in metrics, f"live stats missing {key}"
    assert 0 <= float(metrics[key]) <= 100, f"{key} is outside 0-100"
for sample in payload["history"]:
    for key in ("cpu_percent", "ram_used_percent", "disk_used_percent", "disk_free_percent", "network_traffic_percent"):
        if key in sample:
            assert 0 <= float(sample[key]) <= 100, f"history {key} is outside 0-100"
PY
METRICS_OUT="$TMP_DIR/metrics.prom"
"$PYTHON_BIN" "$ROOT_DIR/scripts/minecraft_metrics_exporter.py" \
  --db "$DB" --server-dir "$SERVER" --state "$TMP_DIR/metrics-state.json" \
  --current-release-json "$PUBLIC/current-release.json" --once > "$METRICS_OUT"
grep -q "pummelchen_minecraft_up" "$METRICS_OUT" || fail "metrics exporter missing minecraft status metric"
grep -q "pummelchen_release_pointer_present 1.000000" "$METRICS_OUT" || fail "metrics exporter missed release pointer"
grep -q "pummelchen_release_pointer_matches_active 1.000000" "$METRICS_OUT" || fail "metrics exporter missed active release pointer match"
"$PYTHON_BIN" - "$ROOT_DIR/scripts" <<'PY' || fail "Spark parser fixture failed"
import sys
sys.path.insert(0, sys.argv[1])
import minecraft_metrics_exporter as exporter

parsed = exporter.parse_spark_tps("TPS from last 5s, 10s, 1m: 20.0, 19.98, 19.95 MSPT: 12.4")
assert parsed["spark_tps"] == 20.0
assert parsed["spark_mspt"] == 12.4
missing = exporter.parse_spark_tps("spark is installed but no tps data was returned")
assert missing["spark_tps"] == -1.0
assert missing["spark_mspt"] == -1.0
PY

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
PRECHECK_RELEASE="$TMP_DIR/current-release.json"
cat > "$PRECHECK_RELEASE" <<'JSON'
{
  "release_id": "qa_release_1",
  "manifest_url": "/downloads/releases/qa_release_1/client-sync-manifest.tsv",
  "client_zip_url": "/downloads/releases/qa_release_1/minecraft_26.1.2_client_macos_apple_silicon.zip",
  "client_zip_sha256": "c98cd7baae991701c27820f9507ba6e76aa7d098a8b5379e05aa0bef220bf4ef"
}
JSON
"$PYTHON_BIN" "$ROOT_DIR/scripts/load_preflight.py" --current-release-json "$PRECHECK_RELEASE" --status-clients 3 --dry-run

log "Monitoring JSON"
"$PYTHON_BIN" -m json.tool "$ROOT_DIR/monitoring/grafana/dashboards/pummelchen-overview.json" >/dev/null
"$PYTHON_BIN" "$ROOT_DIR/scripts/validate_prometheus_rules.py" "$ROOT_DIR"/monitoring/alert-rules/*.yml
if command -v promtool >/dev/null 2>&1; then
  promtool check rules "$ROOT_DIR"/monitoring/alert-rules/*.yml
fi

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
