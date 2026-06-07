#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST=""
PROJECT_DIR="/var/minecraft_mods"
SERVER_DIR="/var/minecraft_26.1.2"
CREATE_RELEASE=0
DRY_RUN=0
SKIP_VALIDATE=0
SSH_OPTS_STRING="${SSH_OPTS:-}"
SSH_ARGS=()
if [ -n "$SSH_OPTS_STRING" ]; then
  # shellcheck disable=SC2206
  SSH_ARGS=($SSH_OPTS_STRING)
fi

usage() {
  cat <<'USAGE'
Usage: scripts/deploy_project.sh --host root@91.99.176.243 [options]

Options:
  --project-dir PATH     Remote project directory. Default: /var/minecraft_mods
  --server-dir PATH      Remote Minecraft server directory. Default: /var/minecraft_26.1.2
  --create-release      Create and activate an immutable release from current server files after deploy.
  --dry-run             Print rsync/ssh actions without changing the remote.
  --skip-validate       Skip the local quality gate.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --host)
      HOST="${2:-}"
      shift 2
      ;;
    --project-dir)
      PROJECT_DIR="${2:-}"
      shift 2
      ;;
    --server-dir)
      SERVER_DIR="${2:-}"
      shift 2
      ;;
    --create-release)
      CREATE_RELEASE=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --skip-validate)
      SKIP_VALIDATE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[ -n "$HOST" ] || {
  usage >&2
  exit 2
}

run_local_validate() {
  [ "$SKIP_VALIDATE" = "1" ] && return 0
  "$ROOT_DIR/scripts/validate_project.sh"
}

remote() {
  if [ "$DRY_RUN" = "1" ]; then
    printf 'DRY-RUN ssh %s %q\n' "$HOST" "$*"
    return 0
  fi
  if [ -n "$SSH_OPTS_STRING" ]; then
    ssh "${SSH_ARGS[@]}" "$HOST" "$@"
  else
    ssh "$HOST" "$@"
  fi
}

sync_project() {
  local rsync_args=(
    -az
    --exclude '__pycache__/'
    --exclude '*.pyc'
    --exclude '.DS_Store'
    --exclude 'client-package/tools/upload-token.txt'
    --exclude 'data/*.sqlite'
    --exclude 'data/*.db'
    --exclude 'dist/'
    --exclude 'site/public/'
    "$ROOT_DIR/README.md"
    "$ROOT_DIR/PRODUCTION_AUDIT.md"
    "$ROOT_DIR/cron"
    "$ROOT_DIR/nginx"
    "$ROOT_DIR/monitoring"
    "$ROOT_DIR/scripts"
    "$ROOT_DIR/systemd"
    "$ROOT_DIR/server-config"
    "$ROOT_DIR/site/assets"
    "$ROOT_DIR/client-installer"
    "$ROOT_DIR/client-package"
    "$ROOT_DIR/server-datapacks"
    "$ROOT_DIR/server-datapacks-src"
    "$ROOT_DIR/docs"
    "$HOST:$PROJECT_DIR/"
  )
  if [ "$DRY_RUN" = "1" ]; then
    printf 'DRY-RUN rsync'
    printf ' %q' "${rsync_args[@]}"
    printf '\n'
  else
    remote "mkdir -p '$PROJECT_DIR'"
    if [ -n "$SSH_OPTS_STRING" ]; then
      rsync -e "ssh $SSH_OPTS_STRING" "${rsync_args[@]}"
    else
      rsync "${rsync_args[@]}"
    fi
  fi
}

remote_install() {
  local create_release="$1"
  remote "PROJECT_DIR='$PROJECT_DIR' SERVER_DIR='$SERVER_DIR' CREATE_RELEASE='$create_release' bash -s" <<'REMOTE'
set -euo pipefail

cd "$PROJECT_DIR"
chmod +x scripts/*.py scripts/*.sh client-package/tools/*.sh "client-package/Install Mods.command" || true

bash scripts/validate_project.sh
python3 scripts/moddb.py --db "$PROJECT_DIR/data/minecraft_mods.sqlite" init
python3 scripts/moddb.py --db "$PROJECT_DIR/data/minecraft_mods.sqlite" normalize-statuses
python3 scripts/release_manager.py --db "$PROJECT_DIR/data/minecraft_mods.sqlite" --server-dir "$SERVER_DIR" init
python3 scripts/gameplay_load_lab.py --db "$PROJECT_DIR/data/minecraft_mods.sqlite" --server-dir "$SERVER_DIR" init
python3 scripts/mod_acceptance_lab.py --db "$PROJECT_DIR/data/minecraft_mods.sqlite" --server-dir "$SERVER_DIR" init
python3 scripts/headless_client_lab.py --db "$PROJECT_DIR/data/minecraft_mods.sqlite" --server-dir "$SERVER_DIR" init
CUSTOM_DATAPACKS_OUTPUT="$(python3 scripts/sync_custom_datapacks.py --db "$PROJECT_DIR/data/minecraft_mods.sqlite" --project-dir "$PROJECT_DIR" --server-dir "$SERVER_DIR")"

PROPERTIES_OUTPUT="server_properties_changed=0"
if [ -f "$PROJECT_DIR/server-config/server.properties.override" ]; then
  PROPERTIES_OUTPUT="$(python3 - "$SERVER_DIR/server.properties" "$PROJECT_DIR/server-config/server.properties.override" <<'PY'
from pathlib import Path
import sys

target = Path(sys.argv[1])
override = Path(sys.argv[2])
updates = {}
for raw in override.read_text(encoding="utf-8").splitlines():
    line = raw.strip()
    if not line or line.startswith("#") or "=" not in line:
        continue
    key, value = line.split("=", 1)
    updates[key.strip()] = value.strip()

lines = target.read_text(encoding="utf-8", errors="replace").splitlines() if target.exists() else []
seen = set()
merged = []
for raw in lines:
    if "=" in raw and not raw.lstrip().startswith("#"):
        key = raw.split("=", 1)[0]
        if key in updates:
            merged.append(f"{key}={updates[key]}")
            seen.add(key)
            continue
    merged.append(raw)
for key, value in updates.items():
    if key not in seen:
        merged.append(f"{key}={value}")
new_text = "\n".join(merged) + "\n"
old_text = target.read_text(encoding="utf-8", errors="replace") if target.exists() else ""
if old_text != new_text:
    target.write_text(new_text, encoding="utf-8")
    print("server_properties_changed=1")
else:
    print("server_properties_changed=0")
PY
)"
fi

CONFIG_OUTPUT="$(python3 scripts/apply_config_overrides.py --source "$PROJECT_DIR/server-config/config-overrides" --target "$SERVER_DIR/config")"

install -m 0644 systemd/pummelchen-live-stats.service /etc/systemd/system/pummelchen-live-stats.service
install -m 0644 systemd/pummelchen-live-stats.timer /etc/systemd/system/pummelchen-live-stats.timer
install -m 0644 systemd/pummelchen-client-log-receiver.service /etc/systemd/system/pummelchen-client-log-receiver.service
install -m 0644 systemd/pummelchen-minecraft-metrics.service /etc/systemd/system/pummelchen-minecraft-metrics.service
install -m 0644 systemd/pummelchen-minecraft.service /etc/systemd/system/pummelchen-minecraft.service
install -m 0644 cron/pummelchen-daily-update /etc/cron.d/pummelchen-daily-update
install -m 0644 cron/pummelchen-status-site /etc/cron.d/pummelchen-status-site
systemctl daemon-reload
systemctl enable --now pummelchen-live-stats.timer pummelchen-client-log-receiver.service pummelchen-minecraft-metrics.service
systemctl enable pummelchen-minecraft.service
systemctl restart pummelchen-client-log-receiver.service pummelchen-minecraft-metrics.service

if [ -d /etc/prometheus ]; then
  install -d -m 0755 /etc/prometheus/pummelchen-rules
  install -m 0644 monitoring/prometheus.yml /etc/prometheus/prometheus.yml
  install -m 0644 monitoring/alert-rules/*.yml /etc/prometheus/pummelchen-rules/
  systemctl reload-or-restart prometheus.service || true
fi

if [ -d /etc/grafana ]; then
  install -d -m 0755 /etc/grafana/provisioning/dashboards /etc/grafana/provisioning/datasources
  install -m 0644 monitoring/grafana/provisioning/dashboards/pummelchen.yml /etc/grafana/provisioning/dashboards/pummelchen.yml
  install -m 0644 monitoring/grafana/provisioning/datasources/prometheus.yml /etc/grafana/provisioning/datasources/prometheus.yml
  systemctl reload-or-restart grafana-server.service || true
fi

install -m 0644 nginx/pummelchen-server.conf /etc/nginx/sites-available/pummelchen-server.conf
ln -sfn /etc/nginx/sites-available/pummelchen-server.conf /etc/nginx/sites-enabled/pummelchen-server.conf
nginx -t

SERVER_SANITIZE_OUTPUT="$(python3 scripts/sanitize_resource_pack_metadata.py "$SERVER_DIR" --target server --write)"
CLIENT_SANITIZE_OUTPUT="$(python3 scripts/sanitize_resource_pack_metadata.py "$SERVER_DIR/client-package" --target client --write)"
SAFETY_OUTPUT="$(python3 scripts/daily_update.py --db "$PROJECT_DIR/data/minecraft_mods.sqlite" --server-dir "$SERVER_DIR" enforce-safety)"
CLIENT_EXCLUDED_FILES="$(find "$SERVER_DIR/client-package/mods" -maxdepth 1 -type f \( \
  -iname '*animalgarden*common*raven*.jar' -o \
  -iname '*automated*harvest*.jar' -o \
  -iname '*automotives*.jar' -o \
  -iname '*better*snowy*biome*.jar' -o \
  -iname '*dynamictrees*.jar' -o \
  -iname '*dynamic*trees*.jar' -o \
  -iname '*structory*towers*.jar' -o \
  -iname 'Incendium_*.jar' -o \
  -iname 'guns++*.jar' -o \
  -iname 'mine-treasure*.jar' \
\) -print 2>/dev/null || true)"
printf '%s\n' "$SERVER_SANITIZE_OUTPUT"
printf '%s\n' "$CLIENT_SANITIZE_OUTPUT"
printf '%s\n' "$SAFETY_OUTPUT"
printf '%s\n' "$CUSTOM_DATAPACKS_OUTPUT"
printf '%s\n' "$PROPERTIES_OUTPUT"
printf '%s\n' "$CONFIG_OUTPUT"
if printf '%s\n' "$CLIENT_SANITIZE_OUTPUT" | grep -Eq 'resource_pack_metadata_changes=[1-9]' \
  || printf '%s\n' "$SAFETY_OUTPUT" | grep -Eq 'client_removed=[1-9]' \
  || [ -n "$CLIENT_EXCLUDED_FILES" ]; then
  python3 scripts/daily_update.py --db "$PROJECT_DIR/data/minecraft_mods.sqlite" --server-dir "$SERVER_DIR" rebuild-client
fi
python3 scripts/generate_status_site.py --db "$PROJECT_DIR/data/minecraft_mods.sqlite" --server-dir "$SERVER_DIR" --output-dir "$PROJECT_DIR/site/public" --public-url "http://91.99.176.243:7788"
python3 scripts/live_stats_feed.py --db "$PROJECT_DIR/data/minecraft_mods.sqlite" --server-dir "$SERVER_DIR" --output "$PROJECT_DIR/site/public/live-stats.json"
python3 scripts/release_manager.py --db "$PROJECT_DIR/data/minecraft_mods.sqlite" --server-dir "$SERVER_DIR" --public-downloads "$PROJECT_DIR/site/public/downloads" current-json >/dev/null 2>&1 || true
python3 scripts/check_client_mod_dependencies.py "$SERVER_DIR/client-package" --minecraft-version 26.1.2 --neoforge-version 26.1.2.71

if [ "$CREATE_RELEASE" = "1" ]; then
  python3 scripts/release_manager.py \
    --db "$PROJECT_DIR/data/minecraft_mods.sqlite" \
    --server-dir "$SERVER_DIR" \
    --release-root "$PROJECT_DIR/releases" \
    --public-downloads "$PROJECT_DIR/site/public/downloads" \
    create --label deploy --status tested --activate --notes "Validated deploy release"
  python3 scripts/release_manager.py \
    --db "$PROJECT_DIR/data/minecraft_mods.sqlite" \
    --server-dir "$SERVER_DIR" \
    --release-root "$PROJECT_DIR/releases" \
    --public-downloads "$PROJECT_DIR/site/public/downloads" \
    cleanup --project-root "$PROJECT_DIR" --keep-releases 1 --include-headless-cache
fi

systemctl reload nginx
if printf '%s\n' "$SERVER_SANITIZE_OUTPUT" | grep -Eq 'resource_pack_metadata_changes=[1-9]' \
  || printf '%s\n' "$SAFETY_OUTPUT" | grep -Eq 'server_removed=[1-9]' \
  || printf '%s\n' "$CUSTOM_DATAPACKS_OUTPUT" | grep -Eq 'custom_datapacks_changed=[1-9]' \
  || printf '%s\n' "$PROPERTIES_OUTPUT" | grep -q 'server_properties_changed=1' \
  || printf '%s\n' "$CONFIG_OUTPUT" | grep -Eq 'config_overrides_changed=[1-9]'; then
  systemctl restart pummelchen-minecraft.service
fi
curl -fsS http://127.0.0.1:7788/ >/dev/null
METRICS_TMP="$(mktemp)"
trap 'rm -f "$METRICS_TMP"' EXIT
curl -fsS http://127.0.0.1:7792/metrics -o "$METRICS_TMP"
grep -q pummelchen_minecraft_up "$METRICS_TMP"
sqlite3 "$PROJECT_DIR/data/minecraft_mods.sqlite" 'PRAGMA integrity_check;' | grep -q '^ok$'
REMOTE
}

sync_local_release_backups() {
  [ "$CREATE_RELEASE" = "1" ] || return 0
  local backup_cmd=(
    python3 "$ROOT_DIR/scripts/backup_releases_local.py"
    --remote "$HOST"
    --release-root "$PROJECT_DIR/releases"
    --output-dir "$ROOT_DIR/Backup"
  )
  if [ "$DRY_RUN" = "1" ]; then
    printf 'DRY-RUN'
    printf ' %q' "${backup_cmd[@]}"
    printf '\n'
    return 0
  fi
  "${backup_cmd[@]}"
}

run_local_validate
sync_project
remote_install "$CREATE_RELEASE"
sync_local_release_backups
printf 'deploy=ok host=%s project_dir=%s\n' "$HOST" "$PROJECT_DIR"
