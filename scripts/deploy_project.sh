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
  ssh "${SSH_ARGS[@]}" "$HOST" "$@"
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
python3 scripts/release_manager.py --db "$PROJECT_DIR/data/minecraft_mods.sqlite" --server-dir "$SERVER_DIR" init
python3 scripts/gameplay_load_lab.py --db "$PROJECT_DIR/data/minecraft_mods.sqlite" --server-dir "$SERVER_DIR" init

install -m 0644 systemd/pummelchen-live-stats.service /etc/systemd/system/pummelchen-live-stats.service
install -m 0644 systemd/pummelchen-live-stats.timer /etc/systemd/system/pummelchen-live-stats.timer
install -m 0644 systemd/pummelchen-client-log-receiver.service /etc/systemd/system/pummelchen-client-log-receiver.service
install -m 0644 systemd/pummelchen-minecraft-metrics.service /etc/systemd/system/pummelchen-minecraft-metrics.service
install -m 0644 systemd/pummelchen-minecraft.service /etc/systemd/system/pummelchen-minecraft.service
systemctl daemon-reload
systemctl enable --now pummelchen-live-stats.timer pummelchen-client-log-receiver.service pummelchen-minecraft-metrics.service
systemctl enable pummelchen-minecraft.service
systemctl restart pummelchen-client-log-receiver.service pummelchen-minecraft-metrics.service

if [ -d /etc/prometheus ]; then
  install -m 0644 monitoring/prometheus.yml /etc/prometheus/prometheus.yml
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

python3 scripts/generate_status_site.py --db "$PROJECT_DIR/data/minecraft_mods.sqlite" --server-dir "$SERVER_DIR" --output-dir "$PROJECT_DIR/site/public" --public-url "http://91.99.176.243:7788"
python3 scripts/live_stats_feed.py --db "$PROJECT_DIR/data/minecraft_mods.sqlite" --server-dir "$SERVER_DIR" --output "$PROJECT_DIR/site/public/live-stats.json"
python3 scripts/release_manager.py --db "$PROJECT_DIR/data/minecraft_mods.sqlite" --server-dir "$SERVER_DIR" --public-downloads "$PROJECT_DIR/site/public/downloads" current-json >/dev/null 2>&1 || true

if [ "$CREATE_RELEASE" = "1" ]; then
  python3 scripts/release_manager.py \
    --db "$PROJECT_DIR/data/minecraft_mods.sqlite" \
    --server-dir "$SERVER_DIR" \
    --release-root "$PROJECT_DIR/releases" \
    --public-downloads "$PROJECT_DIR/site/public/downloads" \
    create --label deploy --status tested --activate --notes "Validated deploy release"
fi

systemctl reload nginx
curl -fsS http://127.0.0.1:7788/ >/dev/null
curl -fsS http://127.0.0.1:7792/metrics | grep -q pummelchen_minecraft_up
sqlite3 "$PROJECT_DIR/data/minecraft_mods.sqlite" 'PRAGMA integrity_check;' | grep -q '^ok$'
REMOTE
}

run_local_validate
sync_project
remote_install "$CREATE_RELEASE"
printf 'deploy=ok host=%s project_dir=%s\n' "$HOST" "$PROJECT_DIR"
