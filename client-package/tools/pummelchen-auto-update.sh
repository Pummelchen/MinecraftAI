#!/bin/bash
set -uo pipefail

CHECK_ONLY=0
QUIET=0
for arg in "$@"; do
  case "$arg" in
    --check-only) CHECK_ONLY=1 ;;
    --quiet) QUIET=1 ;;
  esac
done

DEFAULT_BASE_URL="http://91.99.176.243:7788"
DEFAULT_ZIP_NAME="minecraft_26.1.2_client_macos_apple_silicon.zip"
CONFIG_PATH="${PUMMELCHEN_CONFIG_PATH:-$HOME/Library/Application Support/Pummelchen/client.conf}"

if [ -f "$CONFIG_PATH" ]; then
  # shellcheck source=/dev/null
  . "$CONFIG_PATH"
fi

BASE_URL="${PUMMELCHEN_BASE_URL:-${BASE_URL:-$DEFAULT_BASE_URL}}"
CLIENT_ZIP_NAME="${PUMMELCHEN_CLIENT_ZIP_NAME:-${CLIENT_ZIP_NAME:-$DEFAULT_ZIP_NAME}}"
MC_DIR="${MINECRAFT_DIR:-${MC_DIR:-$HOME/Library/Application Support/minecraft}}"
PUMMELCHEN_HOME="${PUMMELCHEN_HOME:-$HOME/Library/Application Support/Pummelchen}"
LOG_DIR="${PUMMELCHEN_LOG_DIR:-$HOME/Library/Logs/Pummelchen}"
CACHE_DIR="${PUMMELCHEN_CACHE_DIR:-$HOME/Library/Caches/Pummelchen}"
SERVER_NAME="${PUMMELCHEN_SERVER_NAME:-${SERVER_NAME:-Pummelchen Server}}"
SERVER_ADDRESS="${PUMMELCHEN_SERVER_ADDRESS:-${SERVER_ADDRESS:-91.99.176.243:25565}}"
JAVA_BIN="${PUMMELCHEN_JAVA_BIN:-${JAVA_BIN:-java}}"
STATE_DIR="$MC_DIR/.pummelchen"
RELEASE_POINTER_URL="${PUMMELCHEN_RELEASE_POINTER_URL:-${BASE_URL%/}/downloads/current-release.json}"
MANIFEST_URL="${PUMMELCHEN_SYNC_MANIFEST_URL:-}"
TARGET_RELEASE_ID="${PUMMELCHEN_RELEASE_ID:-}"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="${PUMMELCHEN_LOG_FILE:-$LOG_DIR/auto-update-$STAMP.log}"
LOCK_DIR="$PUMMELCHEN_HOME/update.lock"

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
  write_status "failed" "$*"
  exit 1
}

write_status() {
  local status="$1"
  local message="${2:-}"
  cat > "$STATE_DIR/auto-update-status.txt" <<EOF
updated_at=$STAMP
status=$status
message=$message
base_url=$BASE_URL
manifest_url=$MANIFEST_URL
release_id=${TARGET_RELEASE_ID:-legacy}
log_file=$LOG_FILE
EOF
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
      mods|resourcepacks|shaderpacks) ;;
      *) continue ;;
    esac
    local key path
    key="$(printf '%s\t%s' "$section" "$name")"
    if grep -Fqx "$key" "$current_keys"; then
      continue
    fi
    path="$MC_DIR/$section/$name"
    if [ -e "$path" ]; then
      rm -f "$path" || fail "Could not remove stale managed file: $path"
      removed=$((removed + 1))
    fi
  done < "$previous_keys"
  log "Removed $removed stale managed file(s)."
}

move_unmanaged_mods() {
  local wanted_manifest="$1"
  local wanted_mods="$2"
  awk -F '\t' 'NF >= 5 && $1 == "mods" { print $2 }' "$wanted_manifest" > "$wanted_mods"

  local dst="$MC_DIR/mods"
  [ -d "$dst" ] || return 0
  local backup_dir="$MC_DIR/mods.before-pummelchen-auto-$STAMP"
  local moved=0
  shopt -s nullglob
  for path in "$dst"/*.jar; do
    local name
    name="$(basename "$path")"
    if ! grep -Fxq "$name" "$wanted_mods"; then
      mkdir -p "$backup_dir"
      mv "$path" "$backup_dir/$name" || fail "Could not move unmanaged mod jar: $path"
      moved=$((moved + 1))
    fi
  done
  shopt -u nullglob
  if [ "$moved" -gt 0 ]; then
    log "Moved $moved unmanaged mod jar(s) to: $backup_dir"
  fi
}

sync_files() {
  local wanted_manifest="$1"
  local download_dir="$2"
  local changed=0
  local verified=0
  while IFS=$'\t' read -r section name size hash url_path; do
    [ -n "${section:-}" ] || continue
    case "$section" in
      mods|resourcepacks|shaderpacks) ;;
      *) continue ;;
    esac
    local expected dst tmp file_url
    expected="${hash#sha256:}"
    dst="$MC_DIR/$section/$name"
    mkdir -p "$(dirname "$dst")"
    if verify_hash "$dst" "$expected"; then
      verified=$((verified + 1))
      continue
    fi
    tmp="$download_dir/$section/$name"
    mkdir -p "$(dirname "$tmp")"
    case "$url_path" in
      http://*|https://*) file_url="$url_path" ;;
      *) file_url="${BASE_URL%/}/${url_path#/}" ;;
    esac
    log "Downloading $section/$name"
    download_url "$file_url" "$tmp" || fail "Could not download $file_url"
    verify_hash "$tmp" "$expected" || fail "Checksum mismatch for downloaded file: $section/$name"
    mv "$tmp" "$dst" || fail "Could not install $section/$name"
    changed=$((changed + 1))
    verified=$((verified + 1))
  done < "$wanted_manifest"
  log "Verified $verified file(s); changed $changed file(s)."
  printf '%s\n' "$changed"
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
WANTED_MODS="$WORK_DIR/wanted-mods.txt"
DOWNLOAD_DIR="$WORK_DIR/downloads"

resolve_release_manifest "$RELEASE_JSON"

log "Pummelchen auto-update"
log "Release: ${TARGET_RELEASE_ID:-legacy}"
log "Manifest: $MANIFEST_URL"
log "Minecraft folder: $MC_DIR"

download_url "$MANIFEST_URL" "$RAW_MANIFEST" || fail "Could not download sync manifest."
awk -F '\t' 'NF >= 5 && $1 !~ /^#/ && $1 ~ /^(mods|resourcepacks|shaderpacks)$/ { print }' "$RAW_MANIFEST" > "$WANTED_MANIFEST"
manifest_to_keys "$WANTED_MANIFEST" > "$CURRENT_KEYS"

ENTRY_COUNT="$(wc -l < "$WANTED_MANIFEST" | tr -d '[:space:]')"
if [ "$ENTRY_COUNT" = "0" ]; then
  fail "Sync manifest did not contain any client files."
fi

if [ "$CHECK_ONLY" = "1" ]; then
  log "Manifest is readable. Client file entries: $ENTRY_COUNT"
  exit 0
fi

mkdir -p "$MC_DIR/mods" "$MC_DIR/resourcepacks" "$MC_DIR/shaderpacks" "$DOWNLOAD_DIR"
remove_stale_managed_files "$WANTED_MANIFEST" "$CURRENT_KEYS" "$PREVIOUS_KEYS"
CHANGED_COUNT="$(sync_files "$WANTED_MANIFEST" "$DOWNLOAD_DIR" | tail -n 1)"
move_unmanaged_mods "$WANTED_MANIFEST" "$WANTED_MODS"
repair_server_entry

cp "$WANTED_MANIFEST" "$STATE_DIR/client-sync-manifest.tsv"
write_legacy_manifest "$WANTED_MANIFEST"
write_status "ok" "changed_files=$CHANGED_COUNT entries=$ENTRY_COUNT"
DOCTOR="$PUMMELCHEN_HOME/bin/pummelchen-client-doctor.sh"
if [ -x "$DOCTOR" ]; then
  "$DOCTOR" --upload-if-new-crash --quiet >/dev/null 2>&1 || true
fi
log "Pummelchen client is current."
