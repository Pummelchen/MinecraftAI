#!/bin/sh
# Install the master edge on the VPS. Run as root, from a checkout of this repo.
#
# This does NOT start Caddy or take ports 80/443. It stages everything and
# validates it. Read MIGRATION.md before cutting over — whatever holds 80 and
# 443 today has to be dealt with first, and getting that wrong takes every
# site on this host offline.

set -eu

caddy_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

[ "$(id -u)" -eq 0 ] || { echo "error: run as root" >&2; exit 1; }
command -v caddy >/dev/null || { echo "error: caddy not installed — see MIGRATION.md" >&2; exit 1; }

echo "==> validating before touching anything"
"$caddy_root/scripts/validate.sh"

echo "==> creating directories"
install -d -o caddy -g caddy -m 755 /var/caddy /var/caddy/projects /var/caddy/data /var/caddy/config
install -d -o caddy -g caddy -m 755 /var/log/caddy

echo "==> installing config"
install -o caddy -g caddy -m 644 "$caddy_root/Caddyfile" /var/caddy/Caddyfile
for f in "$caddy_root"/projects/*.caddy; do
	[ -e "$f" ] || continue
	install -o caddy -g caddy -m 644 "$f" "/var/caddy/projects/$(basename "$f")"
done

echo "==> installing systemd drop-in"
install -d -m 755 /etc/systemd/system/caddy.service.d
install -m 644 "$caddy_root/systemd/caddy.service.d/override.conf" \
	/etc/systemd/system/caddy.service.d/override.conf
systemctl daemon-reload

echo "==> validating the installed config"
CADDY_LOG_DIR=/var/log/caddy caddy validate --config /var/caddy/Caddyfile --adapter caddyfile

cat <<'NOTE'

Staged. Caddy has NOT been started and ports 80/443 are untouched.

Next, from MIGRATION.md:
  1. Identify what holds 80 and 443.
  2. Add each of its hostnames as a project fragment.
  3. Cut over inside a window, with the rollback command ready.
NOTE
