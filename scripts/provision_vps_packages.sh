#!/bin/bash
set -euo pipefail

DRY_RUN=0
INCLUDE_GRAFANA=0

usage() {
  cat <<'USAGE'
Usage: scripts/provision_vps_packages.sh [--dry-run] [--include-grafana]

Installs the Debian packages expected by the Pummelchen control plane. This is
an explicit provisioning step for fresh VPS builds; normal deploys do not run it.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --include-grafana) INCLUDE_GRAFANA=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

[ "$(id -u)" -eq 0 ] || {
  echo "Run as root on the VPS." >&2
  exit 1
}

command -v apt-get >/dev/null 2>&1 || {
  echo "apt-get is required; this script targets Debian/Ubuntu VPS hosts." >&2
  exit 1
}

available_package() {
  apt-cache show "$1" >/dev/null 2>&1
}

PACKAGES=(
  bash
  ca-certificates
  curl
  jq
  nginx
  prometheus
  prometheus-blackbox-exporter
  prometheus-node-exporter
  python3
  python3-venv
  rsync
  sqlite3
  unzip
  zip
)

if available_package openjdk-25-jre-headless; then
  PACKAGES+=(openjdk-25-jre-headless)
elif available_package openjdk-21-jre-headless; then
  PACKAGES+=(openjdk-21-jre-headless)
fi

if [ "$INCLUDE_GRAFANA" = "1" ]; then
  if available_package grafana; then
    PACKAGES+=(grafana)
  else
    echo "grafana package is not available in current apt sources; skipping." >&2
  fi
fi

echo "apt_packages=${PACKAGES[*]}"
if [ "$DRY_RUN" = "1" ]; then
  echo "dry_run=1"
  exit 0
fi

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y "${PACKAGES[@]}"

install -d -m 0755 /var/minecraft_mods /var/minecraft_mods/site /var/minecraft_mods/site/public
install -d -m 0750 /var/minecraft_mods/secrets /var/minecraft_mods/client_log_uploads

systemctl enable nginx prometheus prometheus-node-exporter prometheus-blackbox-exporter >/dev/null 2>&1 || true
if [ "$INCLUDE_GRAFANA" = "1" ] && systemctl list-unit-files | grep -q '^grafana-server\.service'; then
  systemctl enable grafana-server >/dev/null 2>&1 || true
fi

echo "provision=ok"
