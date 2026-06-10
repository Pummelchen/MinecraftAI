#!/bin/bash
set -euo pipefail

CHECK_ONLY=0
QUIET=0
FORCE_UPDATE=0
LOCAL_RELEASE_ID=""
for arg in "$@"; do
  case "$arg" in
    --check-only) CHECK_ONLY=1 ;;
    --force) FORCE_UPDATE=1 ;;
    --quiet) QUIET=1 ;;
  esac
done

DEFAULT_BASE_URL="http://91.99.176.243:7788"
DEFAULT_ZIP_NAME="minecraft_26.1.2_client_macos_apple_silicon.zip"
CONFIG_PATH="${PUMMELCHEN_CONFIG_PATH:-$HOME/Library/Application Support/Pummelchen/client.conf}"
ENV_PUMMELCHEN_BASE_URL="${PUMMELCHEN_BASE_URL:-}"
ENV_BASE_URL="${BASE_URL:-}"
ENV_PUMMELCHEN_CLIENT_ZIP_NAME="${PUMMELCHEN_CLIENT_ZIP_NAME:-}"
ENV_CLIENT_ZIP_NAME="${CLIENT_ZIP_NAME:-}"
ENV_MINECRAFT_DIR="${MINECRAFT_DIR:-}"
ENV_MC_DIR="${MC_DIR:-}"
ENV_PUMMELCHEN_HOME="${PUMMELCHEN_HOME:-}"
ENV_PUMMELCHEN_LOG_DIR="${PUMMELCHEN_LOG_DIR:-}"
ENV_PUMMELCHEN_CACHE_DIR="${PUMMELCHEN_CACHE_DIR:-}"
ENV_PUMMELCHEN_SERVER_NAME="${PUMMELCHEN_SERVER_NAME:-}"
ENV_SERVER_NAME="${SERVER_NAME:-}"
ENV_PUMMELCHEN_SERVER_ADDRESS="${PUMMELCHEN_SERVER_ADDRESS:-}"
ENV_SERVER_ADDRESS="${SERVER_ADDRESS:-}"
ENV_PUMMELCHEN_JAVA_BIN="${PUMMELCHEN_JAVA_BIN:-}"
ENV_JAVA_BIN="${JAVA_BIN:-}"

if [ -f "$CONFIG_PATH" ]; then
  # shellcheck source=/dev/null
  . "$CONFIG_PATH"
fi

BASE_URL="${ENV_PUMMELCHEN_BASE_URL:-${ENV_BASE_URL:-${PUMMELCHEN_BASE_URL:-${BASE_URL:-$DEFAULT_BASE_URL}}}}"
CLIENT_ZIP_NAME="${ENV_PUMMELCHEN_CLIENT_ZIP_NAME:-${ENV_CLIENT_ZIP_NAME:-${PUMMELCHEN_CLIENT_ZIP_NAME:-${CLIENT_ZIP_NAME:-$DEFAULT_ZIP_NAME}}}}"
MC_DIR="${ENV_MINECRAFT_DIR:-${ENV_MC_DIR:-${MINECRAFT_DIR:-${MC_DIR:-$HOME/Library/Application Support/minecraft}}}}"
PUMMELCHEN_HOME="${ENV_PUMMELCHEN_HOME:-${PUMMELCHEN_HOME:-$HOME/Library/Application Support/Pummelchen}}"
LOG_DIR="${ENV_PUMMELCHEN_LOG_DIR:-${PUMMELCHEN_LOG_DIR:-$HOME/Library/Logs/Pummelchen}}"
CACHE_DIR="${ENV_PUMMELCHEN_CACHE_DIR:-${PUMMELCHEN_CACHE_DIR:-$HOME/Library/Caches/Pummelchen}}"
SERVER_NAME="${ENV_PUMMELCHEN_SERVER_NAME:-${ENV_SERVER_NAME:-${PUMMELCHEN_SERVER_NAME:-${SERVER_NAME:-Pummelchen Server}}}}"
SERVER_ADDRESS="${ENV_PUMMELCHEN_SERVER_ADDRESS:-${ENV_SERVER_ADDRESS:-${PUMMELCHEN_SERVER_ADDRESS:-${SERVER_ADDRESS:-91.99.176.243:25565}}}}"
JAVA_BIN="${ENV_PUMMELCHEN_JAVA_BIN:-${ENV_JAVA_BIN:-${PUMMELCHEN_JAVA_BIN:-${JAVA_BIN:-java}}}}"
STATE_DIR="$MC_DIR/.pummelchen"
RELEASE_POINTER_URL="${PUMMELCHEN_RELEASE_POINTER_URL:-${BASE_URL%/}/downloads/current-release.json}"
MANIFEST_URL="${PUMMELCHEN_SYNC_MANIFEST_URL:-}"
TARGET_RELEASE_ID="${PUMMELCHEN_RELEASE_ID:-}"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="${PUMMELCHEN_LOG_FILE:-$LOG_DIR/auto-update-$STAMP.log}"
UPDATE_STATUS_URL="${PUMMELCHEN_UPDATE_STATUS_URL:-${BASE_URL%/}/client-logs/update-status}"
CLIENT_ID_FILE="${PUMMELCHEN_HOME}/client-id"

FORCED_UPDATE_WINDOW_SECONDS=60
SERVER_REQUIRES_UPDATE=1
SERVER_UPDATE_WINDOW_SECONDS="$FORCED_UPDATE_WINDOW_SECONDS"
SERVER_REQUIREMENT_NOTE=""
FORCED_TRIGGER_NOTE=""
LOCK_DIR="$PUMMELCHEN_HOME/update.lock"
INSTALLED_RELEASE_FILE="$STATE_DIR/installed-release.txt"

mkdir -p "$PUMMELCHEN_HOME" "$LOG_DIR" "$CACHE_DIR" "$STATE_DIR"
if [ "$CHECK_ONLY" != "1" ] && [ "${PUMMELCHEN_LOG_TO_STDOUT:-0}" != "1" ]; then
  exec >> "$LOG_FILE" 2>&1
fi

log() {
  if [ "$QUIET" != "1" ] || [ "${PUMMELCHEN_LOG_TO_STDOUT:-0}" = "1" ] || [ "$CHECK_ONLY" = "1" ]; then
    printf '%s\n' "$*"
  else
    printf '%s\n' "$*"
  fi
}

fail() {
  log "PUMMELCHEN_AUTO_UPDATE_FAILED: $*"
  report_update_status "error" "$LOCAL_RELEASE_ID" "${TARGET_RELEASE_ID:-legacy}" "" "" "$*"
  write_status "failed" "$*" "$LOCAL_RELEASE_ID" "${TARGET_RELEASE_ID:-legacy}"
  exit 1
}

write_status() {
  local status="$1"
  local message="${2:-}"
  local installed_release="${3:-}"
  local target_release="${4:-}"
  cat > "$STATE_DIR/auto-update-status.txt" <<EOF
updated_at=$STAMP
status=$status
message=$message
base_url=$BASE_URL
manifest_url=$MANIFEST_URL
release_id=${TARGET_RELEASE_ID:-legacy}
installed_release_id=${installed_release:-unknown}
target_release_id=${target_release:-legacy}
log_file=$LOG_FILE
EOF
}

normalize_update_window() {
  local value="$1"
  case "$value" in
    ''|*[!0-9]*) echo "$FORCED_UPDATE_WINDOW_SECONDS" ;;
    0) echo "$FORCED_UPDATE_WINDOW_SECONDS" ;;
    *)
      if [ "$value" -lt 1 ] || [ "$value" -gt 3600 ]; then
        echo "$FORCED_UPDATE_WINDOW_SECONDS"
      else
        echo "$value"
      fi
      ;;
  esac
}

client_id() {
  if [ -n "${PUMMELCHEN_CLIENT_ID:-}" ]; then
    tr -cd 'A-Za-z0-9_.-' <<< "${PUMMELCHEN_CLIENT_ID}" | cut -c1-80
    return 0
  fi
  if [ -f "$CLIENT_ID_FILE" ]; then
    local existing
    existing="$(tr -cd 'A-Za-z0-9_.-' < "$CLIENT_ID_FILE" | tr -d '\r\n' | cut -c1-80)"
    if [ -n "$existing" ]; then
      printf '%s\n' "$existing"
      return 0
    fi
  fi
  local generated_id
  if command -v uuidgen >/dev/null 2>&1; then
    generated_id="$(uuidgen | tr '[:upper:]' '[:lower:]' | tr -dc 'a-z0-9-')"
  else
    generated_id="$(printf 'client-%s-%s' "$(hostname | tr -cd 'A-Za-z0-9_.-')" "$(date +%s)")"
  fi
  mkdir -p "$PUMMELCHEN_HOME"
  printf '%s\n' "$generated_id" > "$CLIENT_ID_FILE" 2>/dev/null || true
  chmod 600 "$CLIENT_ID_FILE" 2>/dev/null || true
  printf '%s\n' "$generated_id"
  return 0
}

read_installed_release() {
  if [ -f "$INSTALLED_RELEASE_FILE" ]; then
    tr -d '\r\n ' < "$INSTALLED_RELEASE_FILE" | tr -cd 'A-Za-z0-9._-' | cut -c1-120
  fi
}

write_installed_release() {
  local release_id="$1"
  [ -n "$release_id" ] || return 0
  mkdir -p "$STATE_DIR"
  printf '%s\n' "$release_id" > "$INSTALLED_RELEASE_FILE"
}

report_update_status() {
  local status="$1"
  local installed_release="$2"
  local target_release="$3"
  local changed_files="${4:-}"
  local manifest_entries="${5:-}"
  local message="${6:-}"
  if [ "$CHECK_ONLY" = "1" ]; then
    return 0
  fi
  command -v curl >/dev/null 2>&1 || return 0
  [ -n "$UPDATE_STATUS_URL" ] || return 0
  local cid os_summary arch
  cid="$(client_id || true)"
  [ -n "$cid" ] || return 0
  os_summary="$(sw_vers -productName 2>/dev/null || printf macOS) $(sw_vers -productVersion 2>/dev/null || true)"
  arch="$(uname -m 2>/dev/null || true)"

  local curl_args=(
    --silent --show-error --fail --location
    --retry 1 --retry-delay 1
    --connect-timeout 3 --max-time 8
    -X POST
    -H "Content-Type: application/x-www-form-urlencoded; charset=utf-8"
    -H "User-Agent: PummelchenAutoUpdater/1.0"
    --data-urlencode "client_id=$cid"
    --data-urlencode "installed_release_id=$installed_release"
    --data-urlencode "target_release_id=$target_release"
    --data-urlencode "status=$status"
    --data-urlencode "manifest_entries=$manifest_entries"
    --data-urlencode "changed_files=$changed_files"
    --data-urlencode "os=$os_summary"
    --data-urlencode "arch=$arch"
    --data-urlencode "message=$message"
  )
  curl "${curl_args[@]}" "$UPDATE_STATUS_URL" >/dev/null 2>&1 || true
}

query_server_update_state() {
  local status="$1"
  local installed_release="$2"
  local target_release="$3"
  SERVER_REQUIRES_UPDATE=1
  SERVER_UPDATE_WINDOW_SECONDS="$FORCED_UPDATE_WINDOW_SECONDS"
  SERVER_STATUS_MESSAGE=""
  local parsed_window=""
  [ -n "$UPDATE_STATUS_URL" ] || return 0
  command -v curl >/dev/null 2>&1 || return 0
  local cid os_summary arch
  cid="$(client_id || true)"
  [ -n "$cid" ] || return 0
  os_summary="$(sw_vers -productName 2>/dev/null || printf macOS) $(sw_vers -productVersion 2>/dev/null || true)"
  arch="$(uname -m 2>/dev/null || true)"
  local response
  response="$(curl     --silent --show-error --fail --location     --retry 1 --retry-delay 1     --connect-timeout 3 --max-time 8     -X POST     -H "Content-Type: application/x-www-form-urlencoded; charset=utf-8"     -H "User-Agent: PummelchenAutoUpdater/1.0"     --data-urlencode "client_id=$cid"     --data-urlencode "installed_release_id=$installed_release"     --data-urlencode "target_release_id=$target_release"     --data-urlencode "status=$status"     --data-urlencode "manifest_entries=0"     --data-urlencode "changed_files=0"     --data-urlencode "os=$os_summary"     --data-urlencode "arch=$arch"     --data-urlencode "message=pre-check status" "$UPDATE_STATUS_URL" 2>/dev/null || true)"
  if [ -z "$response" ]; then
    return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    SERVER_REQUIRES_UPDATE="$(printf "%s" "$response" | python3 -c 'import json,sys; payload=json.loads(sys.stdin.read() or "{}"); print(str(payload.get("require_update", True)).lower())' 2>/dev/null || echo "true")"
    parsed_window="$(printf "%s" "$response" | python3 -c 'import json,sys; payload=json.loads(sys.stdin.read() or "{}"); print(payload.get("update_window_seconds", ""))' 2>/dev/null || true)"
    SERVER_STATUS_MESSAGE="$(printf "%s" "$response" | python3 -c 'import json,sys; payload=json.loads(sys.stdin.read() or "{}"); print((payload.get("message") or ""), end="")' 2>/dev/null || true)"
  else
    SERVER_REQUIRES_UPDATE="$(printf "%s" "$response" | sed -n 's/.*"require_update"[[:space:]]*:[[:space:]]*\(true\|false\).*/\1/p' | head -n 1)"
    parsed_window="$(printf "%s" "$response" | sed -n 's/.*"update_window_seconds"[[:space:]]*:[[:space:]]*\([0-9]\{1,\}\).*/\1/p' | head -n 1)"
    SERVER_STATUS_MESSAGE="$(printf "%s" "$response" | sed -n 's/.*"message"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/p' | head -n 1)"
  fi
  if [ "$SERVER_REQUIRES_UPDATE" = "true" ]; then
    SERVER_REQUIRES_UPDATE=1
  elif [ "$SERVER_REQUIRES_UPDATE" = "false" ]; then
    SERVER_REQUIRES_UPDATE=0
  else
    SERVER_REQUIRES_UPDATE=1
  fi
  if [ -n "$parsed_window" ]; then
    SERVER_UPDATE_WINDOW_SECONDS="$(normalize_update_window "$parsed_window")"
  fi
  SERVER_REQUIREMENT_NOTE=""
  FORCED_TRIGGER_NOTE=""
  if [ "$SERVER_REQUIRES_UPDATE" = "1" ]; then
    SERVER_REQUIREMENT_NOTE="Update required now; window=${SERVER_UPDATE_WINDOW_SECONDS}s"
    if [ "$SERVER_UPDATE_WINDOW_SECONDS" -lt "$FORCED_UPDATE_WINDOW_SECONDS" ]; then
      FORCED_TRIGGER_NOTE="server requested fast-track sync window"
    fi
  fi
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "$1 is missing."
}

sha256_file() {
  shasum -a 256 "$1" | awk '{ print $1 }'
}

download_url() {
  local url="$1"
  local output="$2"
  curl --silent --show-error --fail --location --retry 3 --retry-delay 2 \
    --connect-timeout 10 --max-time 600 "$url" -o "$output"
}

json_string_value() {
  local key="$1"
  local path="$2"
  awk -v key="$key" '
    BEGIN {
      RS = ""
      FS = "\n"
    }
    {
      pattern = "\"" key "\"[[:space:]]*:[[:space:]]*\""
      start = match($0, pattern)
      if (!start) exit 1
      value = substr($0, start + RLENGTH)
      end = index(value, "\"")
      if (!end) exit 1
      print substr(value, 1, end - 1)
    }
  ' "$path"
}

resolve_release_manifest() {
  local release_json="$1"
  if [ -n "$MANIFEST_URL" ]; then
    return 0
  fi
  if [ -n "$TARGET_RELEASE_ID" ]; then
    MANIFEST_URL="${BASE_URL%/}/downloads/releases/$TARGET_RELEASE_ID/client-sync-manifest.tsv"
    return 0
  fi
  if download_url "$RELEASE_POINTER_URL" "$release_json"; then
    TARGET_RELEASE_ID="$(json_string_value release_id "$release_json" 2>/dev/null || true)"
    local pointer_manifest
    pointer_manifest="$(json_string_value manifest_url "$release_json" 2>/dev/null || true)"
    if [ -n "$pointer_manifest" ]; then
      case "$pointer_manifest" in
        http://*|https://*) MANIFEST_URL="$pointer_manifest" ;;
        *) MANIFEST_URL="${BASE_URL%/}/${pointer_manifest#/}" ;;
      esac
      return 0
    fi
  fi
  TARGET_RELEASE_ID="legacy"
  MANIFEST_URL="${BASE_URL%/}/downloads/client-sync-manifest.tsv"
}

verify_hash() {
  local path="$1"
  local expected="$2"
  [ -f "$path" ] || return 1
  local actual
  actual="$(sha256_file "$path" || true)"
  [ "$actual" = "$expected" ]
}

url_escape_path() {
  local value="$1"
  value="${value//%/%25}"
  value="${value// /%20}"
  value="${value//\[/%5B}"
  value="${value//\]/%5D}"
  value="${value//\"/%22}"
  value="${value//#/%23}"
  value="${value//\?/%3F}"
  value="${value//</%3C}"
  value="${value//>/%3E}"
  printf '%s\n' "$value"
}

manifest_to_keys() {
  awk -F '\t' 'NF >= 5 && $1 !~ /^#/ { print $1 "\t" $2 }' "$1"
}

legacy_manifest_to_keys() {
  awk -F '\t' '
    /^\[/ {
      section = $0
      gsub(/^\[/, "", section)
      gsub(/\]$/, "", section)
      next
    }
    section != "" && NF >= 3 { print section "\t" $1 }
  ' "$1"
}

write_legacy_manifest() {
  awk -F '\t' '
    NF >= 5 && $1 !~ /^#/ {
      if ($1 != section) {
        if (section != "") print ""
        section = $1
        print "[" section "]"
      }
      print $2 "\t" $3 "\t" $4
    }
  ' "$1" > "$STATE_DIR/manifest.txt"
}

remove_stale_managed_files() {
  local wanted_manifest="$1"
  local current_keys="$2"
  local previous_keys="$3"
  : > "$previous_keys"
  if [ -f "$STATE_DIR/client-sync-manifest.tsv" ]; then
    manifest_to_keys "$STATE_DIR/client-sync-manifest.tsv" > "$previous_keys"
  elif [ -f "$STATE_DIR/manifest.txt" ]; then
    legacy_manifest_to_keys "$STATE_DIR/manifest.txt" > "$previous_keys"
  fi

  local removed=0
  while IFS=$'\t' read -r section name; do
    [ -n "${section:-}" ] || continue
    case "$section" in
      mods|resourcepacks|shaderpacks|tools) ;;
      *) continue ;;
    esac
    local key path
    key="$(printf '%s\t%s' "$section" "$name")"
    if grep -Fqx "$key" "$current_keys"; then
      continue
    fi
    case "$section" in
      mods|resourcepacks|shaderpacks) path="$MC_DIR/$section/$name" ;;
      tools) path="$PUMMELCHEN_HOME/bin/$name" ;;
    esac
    if [ -e "$path" ]; then
      rm -rf "$path" || fail "Could not remove stale managed file: $path"
      removed=$((removed + 1))
    fi
  done < "$previous_keys"
  log "Removed $removed stale managed file(s)."
}

move_unmanaged_files() {
  local wanted_manifest="$1"
  local wanted_dir="$2"
  local section
  for section in mods resourcepacks shaderpacks tools; do
    local wanted_names="$wanted_dir/$section.txt"
    awk -F '\t' -v section="$section" 'NF >= 5 && $1 == section { print $2 }' "$wanted_manifest" > "$wanted_names"

    local dst
    case "$section" in
      mods|resourcepacks|shaderpacks) dst="$MC_DIR/$section" ;;
      tools) dst="$PUMMELCHEN_HOME/bin" ;;
    esac
    [ -d "$dst" ] || continue
    local backup_dir="$MC_DIR/$section.before-pummelchen-auto-$STAMP"
    [ "$section" = "tools" ] && backup_dir="$PUMMELCHEN_HOME/bin.before-pummelchen-auto-$STAMP"
    local moved=0
    shopt -s nullglob
    for path in "$dst"/*; do
      local name
      name="$(basename "$path")"
      [ "$name" = ".DS_Store" ] && continue
      if [ "$section" = "mods" ]; then
        case "$name" in
          *.jar|*.zip) ;;
          *) continue ;;
        esac
      fi
      if ! grep -Fxq "$name" "$wanted_names"; then
        mkdir -p "$backup_dir"
        mv "$path" "$backup_dir/$name" || fail "Could not move unmanaged $section item: $path"
        moved=$((moved + 1))
      fi
    done
    shopt -u nullglob
    if [ "$moved" -gt 0 ]; then
      log "Moved $moved unmanaged $section item(s) to: $backup_dir"
    fi
  done
}

set_options_line() {
  local path="$1"
  local key="$2"
  local value="$3"
  mkdir -p "$(dirname "$path")"
  [ -f "$path" ] || : > "$path"
  local tmp="$path.pummelchen.tmp"
  awk -v key="$key" -v value="$value" '
    BEGIN { replaced = 0 }
    index($0, key ":") == 1 {
      print key ":" value
      replaced = 1
      next
    }
    { print }
    END {
      if (!replaced) print key ":" value
    }
  ' "$path" > "$tmp" && mv "$tmp" "$path"
}

set_property_line() {
  local path="$1"
  local key="$2"
  local value="$3"
  [ -f "$path" ] || return 0
  local tmp="$path.pummelchen.tmp"
  awk -v key="$key" -v value="$value" '
    BEGIN { replaced = 0 }
    index($0, key "=") == 1 {
      print key "=" value
      replaced = 1
      next
    }
    { print }
    END {
      if (!replaced) print key "=" value
    }
  ' "$path" > "$tmp" && mv "$tmp" "$path"
}

set_json_boolean_value() {
  local path="$1"
  local key="$2"
  local value="$3"
  [ -f "$path" ] || return 0
  command -v perl >/dev/null 2>&1 || return 0
  perl -0pi -e "s/(\\\"$key\\\"\\s*:\\s*\\{\\s*\\\"value\\\"\\s*:\\s*)(true|false)/\${1}$value/s" "$path" || true
}

apply_pummelchen_client_defaults() {
  set_property_line "$MC_DIR/config/neoforge-client.toml" "showLoadWarnings" "false"
  set_property_line "$MC_DIR/config/forge-client.toml" "showLoadWarnings" "false"
  set_property_line "$MC_DIR/config/yuushya-client.toml" "showCheckScreen" "false"
  set_json_boolean_value "$MC_DIR/config/underground_village/common.json" "enableInGameMessage" "false"
  set_json_boolean_value "$MC_DIR/config/mtsconfigclient.json" "showTutorial" "false"
  log "Applied Pummelchen client defaults for quieter first launch."
}

reset_client_visual_state() {
  local options="$MC_DIR/options.txt"
  if [ -f "$options" ]; then
    cp "$options" "$options.before-pummelchen-auto-$STAMP"
  fi
  set_options_line "$options" "resourcePacks" '["vanilla"]'
  set_options_line "$options" "incompatibleResourcePacks" '[]'
  set_property_line "$MC_DIR/optionsshaders.txt" "shaderPack" ""
  set_property_line "$MC_DIR/config/iris.properties" "shaderPack" ""
  set_property_line "$MC_DIR/iris.properties" "shaderPack" ""
  log "Reset active resource packs to vanilla and disabled active shader selection."
}

SYNC_CHANGED_COUNT=0

sync_files() {
  local wanted_manifest="$1"
  local download_dir="$2"
  local changed=0
  local verified=0
  while IFS=$'\t' read -r section name size hash url_path; do
    [ -n "${section:-}" ] || continue
    case "$section" in
      mods|resourcepacks|shaderpacks|tools) ;;
      *) continue ;;
    esac
    local expected dst tmp file_url
    expected="${hash#sha256:}"
    case "$section" in
      mods|resourcepacks|shaderpacks) dst="$MC_DIR/$section/$name" ;;
      tools) dst="$PUMMELCHEN_HOME/bin/$name" ;;
    esac
    mkdir -p "$(dirname "$dst")"
    if verify_hash "$dst" "$expected"; then
      verified=$((verified + 1))
      continue
    fi
    tmp="$download_dir/$section/$name"
    mkdir -p "$(dirname "$tmp")"
    case "$url_path" in
      http://*|https://*|file://*) file_url="$url_path" ;;
      *) file_url="${BASE_URL%/}/$(url_escape_path "${url_path#/}")" ;;
    esac
    log "Downloading $section/$name"
    download_url "$file_url" "$tmp" || fail "Could not download $file_url"
    verify_hash "$tmp" "$expected" || fail "Checksum mismatch for downloaded file: $section/$name"
    mv "$tmp" "$dst" || fail "Could not install $section/$name"
    changed=$((changed + 1))
    verified=$((verified + 1))
  done < "$wanted_manifest"
  log "Verified $verified file(s); changed $changed file(s)."
  SYNC_CHANGED_COUNT="$changed"
}

repair_server_entry() {
  local helper="$PUMMELCHEN_HOME/bin/AddPummelchenServer.java"
  [ -f "$helper" ] || return 0
  if [ -x "$JAVA_BIN" ]; then
    "$JAVA_BIN" "$helper" "$MC_DIR" "$SERVER_NAME" "$SERVER_ADDRESS" || {
      log "Could not repair Minecraft server list with configured Java: $JAVA_BIN"
      return 0
    }
    return 0
  fi
  if command -v "$JAVA_BIN" >/dev/null 2>&1; then
    "$JAVA_BIN" "$helper" "$MC_DIR" "$SERVER_NAME" "$SERVER_ADDRESS" || {
      log "Could not repair Minecraft server list with Java command: $JAVA_BIN"
      return 0
    }
  fi
}

WORK_DIR=""
LOCK_HELD=0
cleanup() {
  [ -n "$WORK_DIR" ] && rm -rf "$WORK_DIR"
  if [ "$LOCK_HELD" = "1" ]; then
    rmdir "$LOCK_DIR" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

require_command curl
require_command shasum
require_command awk
require_command grep

if ! mkdir "$LOCK_DIR" >/dev/null 2>&1; then
  log "Another Pummelchen update is already running."
  exit 0
fi
LOCK_HELD=1

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pummelchen-auto-update.XXXXXX")"
RAW_MANIFEST="$WORK_DIR/client-sync-manifest.raw.tsv"
WANTED_MANIFEST="$WORK_DIR/client-sync-manifest.tsv"
RELEASE_JSON="$WORK_DIR/current-release.json"
CURRENT_KEYS="$WORK_DIR/current.keys"
PREVIOUS_KEYS="$WORK_DIR/previous.keys"
WANTED_NAMES_DIR="$WORK_DIR/wanted-names"
DOWNLOAD_DIR="$WORK_DIR/downloads"

resolve_release_manifest "$RELEASE_JSON"

log "Pummelchen auto-update"
log "Release: ${TARGET_RELEASE_ID:-legacy}"
log "Manifest: $MANIFEST_URL"
log "Minecraft folder: $MC_DIR"
LOCAL_RELEASE_ID="$(read_installed_release)"
CURRENT_STATUS="up_to_date"
if [ -z "$LOCAL_RELEASE_ID" ]; then
  CURRENT_STATUS="unknown"
elif [ "$LOCAL_RELEASE_ID" != "${TARGET_RELEASE_ID:-legacy}" ]; then
  CURRENT_STATUS="behind"
fi

download_url "$MANIFEST_URL" "$RAW_MANIFEST" || fail "Could not download sync manifest."
awk -F '\t' 'NF >= 5 && $1 !~ /^#/ && $1 ~ /^(mods|resourcepacks|shaderpacks|tools)$/ { print }' "$RAW_MANIFEST" > "$WANTED_MANIFEST"
manifest_to_keys "$WANTED_MANIFEST" > "$CURRENT_KEYS"

ENTRY_COUNT="$(wc -l < "$WANTED_MANIFEST" | tr -d '[:space:]')"
if [ "$ENTRY_COUNT" = "0" ]; then
  fail "Sync manifest did not contain any client files."
fi

if [ "$CHECK_ONLY" = "1" ]; then
  log "Manifest is readable. Client file entries: $ENTRY_COUNT"
  report_update_status "$CURRENT_STATUS" "$LOCAL_RELEASE_ID" "${TARGET_RELEASE_ID:-legacy}" "" "$ENTRY_COUNT" "manifest check-only"
  exit 0
fi


query_server_update_state "$CURRENT_STATUS" "$LOCAL_RELEASE_ID" "${TARGET_RELEASE_ID:-legacy}"
if [ -n "$SERVER_STATUS_MESSAGE" ]; then
  log "Server status: $SERVER_STATUS_MESSAGE"
fi
if [ -n "$SERVER_REQUIREMENT_NOTE" ]; then
  log "$SERVER_REQUIREMENT_NOTE"
fi
if [ -n "$FORCED_TRIGGER_NOTE" ]; then
  log "$FORCED_TRIGGER_NOTE"
fi
if [ "$FORCE_UPDATE" = "1" ]; then
  log "FORCE_UPDATE is enabled; forcing full sync check."
fi
if [ "$FORCE_UPDATE" != "1" ] && [ "$SERVER_REQUIRES_UPDATE" = "0" ] && [ -n "${LOCAL_RELEASE_ID:-}" ] && [ "$LOCAL_RELEASE_ID" = "${TARGET_RELEASE_ID:-legacy}" ]; then
  log "Server status check says this client is up to date; skipping full sync."
  write_status "up_to_date" "no changes required" "$LOCAL_RELEASE_ID" "${TARGET_RELEASE_ID:-legacy}"
  report_update_status "up_to_date" "$LOCAL_RELEASE_ID" "${TARGET_RELEASE_ID:-legacy}" "0" "$ENTRY_COUNT" "server reported up-to-date"
  log "Pummelchen client is current."
  if [ -n "$SERVER_STATUS_MESSAGE" ]; then
    log "Server status note: $SERVER_STATUS_MESSAGE"
  fi
  exit 0
fi

mkdir -p "$MC_DIR/mods" "$MC_DIR/resourcepacks" "$MC_DIR/shaderpacks" "$DOWNLOAD_DIR" "$WANTED_NAMES_DIR"
mkdir -p "$PUMMELCHEN_HOME/bin"
remove_stale_managed_files "$WANTED_MANIFEST" "$CURRENT_KEYS" "$PREVIOUS_KEYS"
sync_files "$WANTED_MANIFEST" "$DOWNLOAD_DIR"
CHANGED_COUNT="$SYNC_CHANGED_COUNT"
move_unmanaged_files "$WANTED_MANIFEST" "$WANTED_NAMES_DIR"
reset_client_visual_state
apply_pummelchen_client_defaults
repair_server_entry
if [ "$CURRENT_STATUS" = "behind" ]; then
  CURRENT_STATUS="updated"
  LOCAL_RELEASE_ID="$TARGET_RELEASE_ID"
fi
write_installed_release "$TARGET_RELEASE_ID"
write_status "ok" "changed_files=$CHANGED_COUNT entries=$ENTRY_COUNT" "$LOCAL_RELEASE_ID" "$TARGET_RELEASE_ID"
report_update_status "$CURRENT_STATUS" "$LOCAL_RELEASE_ID" "$TARGET_RELEASE_ID" "$CHANGED_COUNT" "$ENTRY_COUNT" "sync complete"

cp "$WANTED_MANIFEST" "$STATE_DIR/client-sync-manifest.tsv"
write_legacy_manifest "$WANTED_MANIFEST"
DOCTOR="$PUMMELCHEN_HOME/bin/pummelchen-client-doctor.sh"
if [ -x "$DOCTOR" ]; then
  "$DOCTOR" --upload-if-new-crash --quiet >/dev/null 2>&1 || true
fi
log "Pummelchen client is current."
