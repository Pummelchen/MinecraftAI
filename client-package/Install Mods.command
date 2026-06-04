#!/bin/bash
set -euo pipefail

PACK_DIR="$(cd "$(dirname "$0")" && pwd)"
MC_DIR="${MINECRAFT_DIR:-$HOME/Library/Application Support/minecraft}"
if [ "${1:-}" != "" ]; then
  MC_DIR="$1"
fi

SERVER_NAME="${PUMMELCHEN_SERVER_NAME:-Pummelchen Server}"
SERVER_ADDRESS="${PUMMELCHEN_SERVER_ADDRESS:-91.99.176.243:25565}"
PUBLIC_URL="${PUMMELCHEN_BASE_URL:-http://91.99.176.243:7788}"
CLIENT_ZIP_NAME="${PUMMELCHEN_CLIENT_ZIP_NAME:-minecraft_26.1.2_client_macos_apple_silicon.zip}"
AUTO_UPDATE_INTERVAL="${PUMMELCHEN_AUTO_UPDATE_INTERVAL:-300}"
INSTALLER_VERSION="${PUMMELCHEN_INSTALLER_VERSION:-1.2}"
STAMP="$(date +%Y%m%d-%H%M%S)"
STATE_DIR="$MC_DIR/.pummelchen"
PUMMELCHEN_HOME="$HOME/Library/Application Support/Pummelchen"
LOG_DIR="$HOME/Library/Logs/Pummelchen"
mkdir -p "$LOG_DIR" "$PUMMELCHEN_HOME"
LOG_FILE="${PUMMELCHEN_LOG_FILE:-$LOG_DIR/client-install-$STAMP.log}"
INSTALLER_SESSION_ID="${PUMMELCHEN_INSTALLER_SESSION_ID:-}"
INSTALLER_EVENT_URL="${PUMMELCHEN_INSTALLER_EVENT_URL:-${PUBLIC_URL%/}/client-logs/installer-event}"
CLIENT_ID_FILE="$PUMMELCHEN_HOME/client-id"
exec > >(tee -a "$LOG_FILE") 2>&1

NONINTERACTIVE="${PUMMELCHEN_NONINTERACTIVE:-0}"
OPEN_LAUNCHER="${PUMMELCHEN_OPEN_LAUNCHER:-0}"
REQUIRE_LOCAL_JAVA="${PUMMELCHEN_REQUIRE_LOCAL_JAVA:-0}"

finish_prompt() {
  if [ "$NONINTERACTIVE" != "1" ]; then
    echo
    read -r -p "Press Return to close this window..." _
  fi
}

fail() {
  echo
  echo "PUMMELCHEN_INSTALL_FAILED: $*"
  echo "Log file: $LOG_FILE"
  emit_event "inner_failed" "error" "failed" "$*" 1
  finish_prompt
  exit 1
}

new_session_id() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr '[:upper:]' '[:lower:]'
  else
    printf 'inner-installer-%s-%s\n' "$(hostname | tr -cd 'A-Za-z0-9_.-')" "$(date +%s)"
  fi
}

client_id() {
  if [ ! -s "$CLIENT_ID_FILE" ]; then
    new_session_id > "$CLIENT_ID_FILE"
    chmod 600 "$CLIENT_ID_FILE" 2>/dev/null || true
  fi
  tr -cd 'A-Za-z0-9_.-' < "$CLIENT_ID_FILE" | cut -c1-80
}

redact_file_to() {
  local src="$1"
  local dst="$2"
  if [ "$src" != "/dev/stdin" ] && [ ! -f "$src" ]; then
    : > "$dst"
    return 0
  fi
  sed -E \
    -e "s#${HOME//\\/\\\\}#~#g" \
    -e 's#/Users/[^/[:space:]]+#~/REDACTED_USER#g' \
    -e 's#(accessToken|clientToken|session|authorization|Authorization|Bearer)[^[:space:],}"]+#\1=REDACTED#g' \
    -e 's#([A-Za-z0-9._%+-]+)@([A-Za-z0-9.-]+)\.[A-Za-z]{2,}#REDACTED_EMAIL#g' \
    "$src" > "$dst" 2>/dev/null || true
}

emit_event() {
  local event_type="$1"
  local severity="$2"
  local status="$3"
  local message="$4"
  local include_tail="${5:-0}"
  [ "${PUMMELCHEN_DISABLE_INSTALLER_EVENTS:-0}" = "1" ] && return 0
  command -v curl >/dev/null 2>&1 || return 0
  [ -n "$INSTALLER_EVENT_URL" ] || return 0

  if [ -z "$INSTALLER_SESSION_ID" ]; then
    INSTALLER_SESSION_ID="$(new_session_id)"
  fi

  local work_tail cid os_summary arch redacted_log event_at
  work_tail="$PUMMELCHEN_HOME/installer-event-tail.tmp"
  cid="$(client_id || true)"
  os_summary="$(sw_vers -productName 2>/dev/null || printf macOS) $(sw_vers -productVersion 2>/dev/null || true)"
  arch="$(uname -m 2>/dev/null || true)"
  redacted_log="${LOG_FILE/#$HOME/~}"
  event_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local curl_args=(
    --silent --show-error --fail --location
    --retry 1 --retry-delay 1
    --connect-timeout 3 --max-time 8
    -X POST
    -H "Content-Type: application/x-www-form-urlencoded; charset=utf-8"
    -H "User-Agent: PummelchenManagedInstaller/$INSTALLER_VERSION"
    --data-urlencode "session_id=$INSTALLER_SESSION_ID"
    --data-urlencode "client_id=$cid"
    --data-urlencode "event_type=$event_type"
    --data-urlencode "severity=$severity"
    --data-urlencode "status=$status"
    --data-urlencode "event_at=$event_at"
    --data-urlencode "installer_version=$INSTALLER_VERSION"
    --data-urlencode "minecraft_version=26.1.2"
    --data-urlencode "os=$os_summary"
    --data-urlencode "arch=$arch"
    --data-urlencode "local_log_path=$redacted_log"
    --data-urlencode "step_current=8"
    --data-urlencode "step_total=10"
    --data-urlencode "message=$message"
  )
  if [ "$include_tail" = "1" ]; then
    { tail -n 120 "$LOG_FILE" 2>/dev/null || true; } | redact_file_to /dev/stdin "$work_tail"
    curl_args+=(--data-urlencode "log_excerpt@$work_tail")
  fi

  if ! curl "${curl_args[@]}" "$INSTALLER_EVENT_URL" >/dev/null 2>> "$LOG_FILE"; then
    printf 'Installer event upload failed: %s %s\n' "$event_type" "$message" >> "$LOG_FILE"
  fi
  rm -f "$work_tail"
}

on_unhandled_error() {
  local status="$1"
  local line="$2"
  trap - ERR
  echo "PUMMELCHEN_INSTALL_FAILED: unexpected exit code $status at line $line"
  emit_event "inner_failed" "error" "failed" "Unexpected managed installer error at line $line with exit code $status." 1
  finish_prompt
  exit "$status"
}

trap 'on_unhandled_error "$?" "$LINENO"' ERR

echo "Pummelchen Server client installer"
echo "Package: $PACK_DIR"
echo "Minecraft folder: $MC_DIR"
echo "Log file: $LOG_FILE"
echo
emit_event "inner_started" "info" "running" "Managed client installer started." 0

if [ "$(uname -m)" != "arm64" ]; then
  fail "This package is built for Apple Silicon Macs."
fi

if [ ! -f "$PACK_DIR/manifest.txt" ]; then
  fail "Package manifest is missing."
fi

mkdir -p "$MC_DIR" "$STATE_DIR" "$PUMMELCHEN_HOME"

java_major() {
  local bin="$1"
  local version
  version="$("$bin" -version 2>&1 | awk -F '"' '/version/ {print $2; exit}')"
  if [[ "$version" == 1.* ]]; then
    printf '%s\n' "$version" | cut -d. -f2
  else
    printf '%s\n' "$version" | cut -d. -f1
  fi
}

valid_java25() {
  local bin="$1"
  [ -x "$bin" ] || return 1
  local major
  major="$(java_major "$bin" || true)"
  [[ "$major" =~ ^[0-9]+$ ]] && [ "$major" -ge 25 ]
}

download_pummelchen_jdk25() {
  echo "Installing user-local Java 25 for Pummelchen..." >&2
  local java_root="$PUMMELCHEN_HOME/java25"
  local tmp_dir="$PUMMELCHEN_HOME/tmp-java25"
  local archive="$tmp_dir/temurin-java25.tar.gz"
  rm -rf "$tmp_dir"
  mkdir -p "$tmp_dir" "$PUMMELCHEN_HOME"
  curl --silent --show-error --fail --location --retry 3 --retry-delay 2 \
    "https://api.adoptium.net/v3/binary/latest/25/ga/mac/aarch64/jdk/hotspot/normal/eclipse?project=jdk" \
    -o "$archive"
  tar -xzf "$archive" -C "$tmp_dir"
  local extracted
  extracted="$(find "$tmp_dir" -path '*/Contents/Home/bin/java' -type f | head -n 1)"
  if [ -z "$extracted" ]; then
    fail "Downloaded Java archive did not contain a macOS Java runtime."
  fi
  rm -rf "$java_root"
  mkdir -p "$java_root"
  cp -R "$(dirname "$(dirname "$extracted")")"/. "$java_root"/
  rm -rf "$tmp_dir"
}

ensure_java25() {
  local managed_java="$PUMMELCHEN_HOME/java25/bin/java"
  if valid_java25 "$managed_java"; then
    printf '%s\n' "$managed_java"
    return 0
  fi
  if [ "$REQUIRE_LOCAL_JAVA" != "1" ]; then
    if command -v java >/dev/null 2>&1 && valid_java25 "$(command -v java)"; then
      command -v java
      return 0
    fi
    if command -v /usr/libexec/java_home >/dev/null 2>&1; then
      local home
      home="$(/usr/libexec/java_home -v 25 2>/dev/null || true)"
      if [ -n "$home" ] && valid_java25 "$home/bin/java"; then
        printf '%s\n' "$home/bin/java"
        return 0
      fi
    fi
  fi
  download_pummelchen_jdk25
  if valid_java25 "$managed_java"; then
    printf '%s\n' "$managed_java"
    return 0
  fi
  fail "Java 25 install did not produce a usable java binary."
}

manifest_lines() {
  local section="$1"
  awk -v section="[$section]" '
    $0 == section { active = 1; next }
    /^\[/ { active = 0 }
    active && NF { print }
  ' "$PACK_DIR/manifest.txt"
}

manifest_names() {
  local section="$1"
  manifest_lines "$section" | awk -F '\t' '{ print $1 }'
}

previous_manifest_names() {
  local section="$1"
  local previous="$STATE_DIR/manifest.txt"
  [ -f "$previous" ] || return 0
  awk -v section="[$section]" '
    $0 == section { active = 1; next }
    /^\[/ { active = 0 }
    active && NF { split($0, fields, "\t"); print fields[1] }
  ' "$previous"
}

copy_dir_contents() {
  local src="$1"
  local dst="$2"
  mkdir -p "$dst"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a "$src"/ "$dst"/
  else
    cp -R "$src"/. "$dst"/
  fi
}

remove_previous_managed_files() {
  local section="$1"
  local dst="$2"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if [ -e "$dst/$name" ]; then
      rm -f "$dst/$name"
    fi
  done < <(previous_manifest_names "$section")
}

move_conflicting_mods() {
  local dst="$1"
  local current_list="$STATE_DIR/current-mods-$STAMP.txt"
  manifest_names "mods" > "$current_list"
  local backup_dir="$MC_DIR/mods.before-pummelchen-$STAMP"
  local moved=0
  shopt -s nullglob
  for path in "$dst"/*.jar; do
    local name
    name="$(basename "$path")"
    if ! grep -Fxq "$name" "$current_list"; then
      mkdir -p "$backup_dir"
      mv "$path" "$backup_dir/$name"
      moved=$((moved + 1))
    fi
  done
  shopt -u nullglob
  if [ "$moved" -gt 0 ]; then
    echo "Moved $moved non-Pummelchen mod jar(s) to: $backup_dir"
  fi
}

sync_section() {
  local section="$1"
  local src="$PACK_DIR/$section"
  local dst="$MC_DIR/$section"
  [ -d "$src" ] || return 0
  mkdir -p "$dst"
  remove_previous_managed_files "$section" "$dst"
  if [ "$section" = "mods" ]; then
    move_conflicting_mods "$dst"
  fi
  copy_dir_contents "$src" "$dst"
}

verify_section() {
  local section="$1"
  local dst="$MC_DIR/$section"
  local count=0
  while IFS=$'\t' read -r name size hash; do
    [ -n "${name:-}" ] || continue
    local path="$dst/$name"
    local expected="${hash#sha256:}"
    [ -f "$path" ] || fail "Missing $section file after install: $name"
    local actual
    actual="$(shasum -a 256 "$path" | awk '{ print $1 }')"
    [ "$actual" = "$expected" ] || fail "Checksum mismatch for $section file: $name"
    count=$((count + 1))
  done < <(manifest_lines "$section")
  echo "Verified $count $section file(s)."
}

count_installed_mods() {
  local dir="$1"
  [ -d "$dir" ] || {
    printf '0\n'
    return 0
  }
  find "$dir" -maxdepth 1 -type f -name '*.jar' 2>/dev/null | wc -l | tr -d '[:space:]'
}

count_installed_packs() {
  local dir="$1"
  [ -d "$dir" ] || {
    printf '0\n'
    return 0
  }
  find "$dir" -maxdepth 1 -type f \( -name '*.zip' -o -name '*.jar' \) 2>/dev/null | wc -l | tr -d '[:space:]'
}

profile_exists() {
  local profiles="$MC_DIR/launcher_profiles.json"
  [ -f "$profiles" ] || return 1
  grep -qi "neoforge" "$profiles"
}

install_neoforge_profile() {
  local java_bin="$1"
  local installer="$PACK_DIR/neoforge-26.1.2.71-installer.jar"
  [ -f "$installer" ] || fail "NeoForge client installer jar is missing."
  echo "Installing NeoForge client profile..."
  if (cd "$LOG_DIR" && "$java_bin" -jar "$installer" --install-client); then
    echo "NeoForge client installer completed."
    return 0
  fi
  if profile_exists; then
    echo "NeoForge installer returned non-zero, but a NeoForge launcher profile already exists."
    return 0
  fi
  fail "NeoForge client profile install failed."
}

add_server_entry() {
  local java_bin="$1"
  local helper="$PACK_DIR/tools/AddPummelchenServer.java"
  if [ -f "$helper" ]; then
    echo "Adding Pummelchen Server to Minecraft server list..."
    if "$java_bin" "$helper" "$MC_DIR" "$SERVER_NAME" "$SERVER_ADDRESS"; then
      return 0
    fi
  fi
  echo "Could not update servers.dat automatically. The server address is $SERVER_ADDRESS."
}

shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

xml_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

install_auto_updater() {
  local updater_src="$PACK_DIR/tools/pummelchen-auto-update.sh"
  local doctor_src="$PACK_DIR/tools/pummelchen-client-doctor.sh"
  local server_helper_src="$PACK_DIR/tools/AddPummelchenServer.java"
  local token_src="$PACK_DIR/tools/upload-token.txt"
  [ -f "$updater_src" ] || {
    echo "Auto-updater payload is not present in this package; skipping LaunchAgent install."
    return 0
  }
  [ -f "$doctor_src" ] || {
    echo "Client Doctor payload is not present in this package; log upload helper will not be installed."
  }

  local bin_dir="$PUMMELCHEN_HOME/bin"
  local updater_dst="$bin_dir/pummelchen-auto-update.sh"
  local doctor_dst="$bin_dir/pummelchen-client-doctor.sh"
  local server_helper_dst="$bin_dir/AddPummelchenServer.java"
  local config_path="$PUMMELCHEN_HOME/client.conf"
  local launch_agents="$HOME/Library/LaunchAgents"
  local plist_path="$launch_agents/com.pummelchen.client-updater.plist"
  local user_apps="$HOME/Applications"
  local play_command="$user_apps/Pummelchen Minecraft.command"
  local send_logs_command="$user_apps/Pummelchen Send Logs.command"
  local support_play_command="$PUMMELCHEN_HOME/Pummelchen Minecraft.command"
  local support_send_logs_command="$PUMMELCHEN_HOME/Pummelchen Send Logs.command"
  local uid
  uid="$(id -u)"
  local plist_updater_dst plist_log_dir
  plist_updater_dst="$(xml_escape "$updater_dst")"
  plist_log_dir="$(xml_escape "$LOG_DIR")"
  local upload_token
  upload_token="${PUMMELCHEN_LOG_UPLOAD_TOKEN:-}"
  if [ -z "$upload_token" ] && [ -f "$token_src" ]; then
    upload_token="$(tr -d '\r\n[:space:]' < "$token_src")"
  fi

  mkdir -p "$bin_dir" "$launch_agents" "$LOG_DIR" "$user_apps"
  cp "$updater_src" "$updater_dst"
  chmod +x "$updater_dst"
  if [ -f "$doctor_src" ]; then
    cp "$doctor_src" "$doctor_dst"
    chmod +x "$doctor_dst"
  fi
  if [ -f "$server_helper_src" ]; then
    cp "$server_helper_src" "$server_helper_dst"
    chmod 0644 "$server_helper_dst"
  fi

  {
    printf 'PUMMELCHEN_BASE_URL=%s\n' "$(shell_quote "$PUBLIC_URL")"
    printf 'PUMMELCHEN_CLIENT_ZIP_NAME=%s\n' "$(shell_quote "$CLIENT_ZIP_NAME")"
    printf 'MINECRAFT_DIR=%s\n' "$(shell_quote "$MC_DIR")"
    printf 'PUMMELCHEN_SERVER_NAME=%s\n' "$(shell_quote "$SERVER_NAME")"
    printf 'PUMMELCHEN_SERVER_ADDRESS=%s\n' "$(shell_quote "$SERVER_ADDRESS")"
    printf 'PUMMELCHEN_JAVA_BIN=%s\n' "$(shell_quote "$JAVA_BIN")"
    printf 'PUMMELCHEN_LOG_UPLOAD_URL=%s\n' "$(shell_quote "${PUBLIC_URL%/}/client-logs/upload")"
    printf 'PUMMELCHEN_LOG_UPLOAD_TOKEN=%s\n' "$(shell_quote "$upload_token")"
  } > "$config_path"
  chmod 600 "$config_path"

  cat > "$plist_path" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.pummelchen.client-updater</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$plist_updater_dst</string>
    <string>--quiet</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>StartInterval</key>
  <integer>$AUTO_UPDATE_INTERVAL</integer>
  <key>StandardOutPath</key>
  <string>$plist_log_dir/auto-update.launchd.log</string>
  <key>StandardErrorPath</key>
  <string>$plist_log_dir/auto-update.launchd.log</string>
</dict>
</plist>
PLIST

  for command_path in "$play_command" "$support_play_command"; do
    {
      printf '#!/bin/bash\n'
      if [ -f "$doctor_src" ]; then
        printf '%s --upload-if-new-crash --quiet >/dev/null 2>&1 || true\n' "$(shell_quote "$doctor_dst")"
      fi
      printf 'if %s --quiet; then\n' "$(shell_quote "$updater_dst")"
      printf '  open -a "Minecraft" >/dev/null 2>&1 || open -a "Minecraft Launcher" >/dev/null 2>&1 || true\n'
      printf 'else\n'
      printf '  printf "\\nPummelchen update failed. Minecraft was not opened so the client does not join with a stale pack.\\n"\n'
      printf '  read -r -p "Press Return to close this window..." _\n'
      printf '  exit 1\n'
      printf 'fi\n'
    } > "$command_path"
    chmod +x "$command_path"
  done

  if [ -f "$doctor_src" ]; then
    for command_path in "$send_logs_command" "$support_send_logs_command"; do
      {
        printf '#!/bin/bash\n'
        printf 'if %s --upload; then\n' "$(shell_quote "$doctor_dst")"
        printf '  printf "\\nDiagnostic upload complete. You can close this window.\\n"\n'
        printf 'else\n'
        printf '  printf "\\nDiagnostic upload failed. Check ~/Library/Logs/Pummelchen for details.\\n"\n'
        printf 'fi\n'
        printf 'read -r -p "Press Return to close this window..." _\n'
      } > "$command_path"
      chmod +x "$command_path"
    done
  fi

  if [ "${PUMMELCHEN_SKIP_LAUNCHAGENT_RELOAD:-0}" != "1" ] && command -v launchctl >/dev/null 2>&1; then
    launchctl bootout "gui/$uid/com.pummelchen.client-updater" >/dev/null 2>&1 || true
    if launchctl bootstrap "gui/$uid" "$plist_path" >/dev/null 2>&1; then
      launchctl kickstart -k "gui/$uid/com.pummelchen.client-updater" >/dev/null 2>&1 || true
    else
      launchctl unload "$plist_path" >/dev/null 2>&1 || true
      launchctl load "$plist_path" >/dev/null 2>&1 || echo "Could not load LaunchAgent automatically; it will load at next login."
    fi
  fi

  echo "Auto-updater installed: $plist_path"
  echo "Manual pre-launch sync command: $play_command"
  if [ -f "$doctor_src" ]; then
    echo "Manual log upload command: $send_logs_command"
  fi
}

write_state() {
  mkdir -p "$STATE_DIR"
  cp "$PACK_DIR/manifest.txt" "$STATE_DIR/manifest.txt"
  cat > "$STATE_DIR/status.txt" <<EOF
installed_at=$STAMP
server_name=$SERVER_NAME
server_address=$SERVER_ADDRESS
log_file=$LOG_FILE
EOF
}

echo "Preparing Java..."
emit_event "inner_phase" "info" "running" "Preparing Java 25 runtime." 0
JAVA_BIN="$(ensure_java25)"
"$JAVA_BIN" -version 2>&1 | sed -n '1p'
emit_event "inner_phase" "info" "running" "Java runtime is ready." 0

echo "Syncing Pummelchen files..."
emit_event "inner_phase" "info" "running" "Syncing mods, resource packs, and shader packs." 0
sync_section "mods"
sync_section "resourcepacks"
sync_section "shaderpacks"

echo "Verifying installed files..."
emit_event "inner_phase" "info" "running" "Verifying installed client files." 0
verify_section "mods"
verify_section "resourcepacks"
verify_section "shaderpacks"

emit_event "inner_phase" "info" "running" "Installing NeoForge launcher profile." 0
install_neoforge_profile "$JAVA_BIN"
emit_event "inner_phase" "info" "running" "Adding Pummelchen server entry." 0
add_server_entry "$JAVA_BIN"
emit_event "inner_phase" "info" "running" "Installing background updater and log uploader." 0
install_auto_updater
emit_event "inner_phase" "info" "running" "Writing client install state." 0
write_state

if [ "$OPEN_LAUNCHER" = "1" ]; then
  emit_event "inner_phase" "info" "running" "Opening Minecraft Launcher." 0
  open -a "Minecraft" >/dev/null 2>&1 || open -a "Minecraft Launcher" >/dev/null 2>&1 || true
fi

MOD_COUNT="$(count_installed_mods "$MC_DIR/mods")"
RP_COUNT="$(count_installed_packs "$MC_DIR/resourcepacks")"
SHADER_COUNT="$(count_installed_packs "$MC_DIR/shaderpacks")"

echo
echo "Ready to play Pummelchen Server."
echo "Installed $MOD_COUNT mod jar(s), $RP_COUNT resource pack file(s), and $SHADER_COUNT shader pack file(s)."
echo "Server: $SERVER_ADDRESS"
echo "Log file: $LOG_FILE"
emit_event "inner_completed" "info" "running" "Managed client installer completed without errors." 0
finish_prompt
