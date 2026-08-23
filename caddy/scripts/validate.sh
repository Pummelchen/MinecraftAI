#!/bin/sh
# Validate the master config and every project fragment.
# Runs without root: log output is redirected to a scratch directory.

set -eu

caddy_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
: "${CADDY_BIN:=$(command -v caddy || true)}"

if [ -z "$CADDY_BIN" ]; then
	echo "error: caddy not found; set CADDY_BIN" >&2
	exit 1
fi

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

if CADDY_LOG_DIR="$scratch" "$CADDY_BIN" validate \
	--config "$caddy_root/Caddyfile" --adapter caddyfile >"$scratch/out" 2>&1; then
	printf 'ok: %s and %d project fragment(s) are valid\n' \
		"Caddyfile" "$(find "$caddy_root/projects" -name '*.caddy' | wc -l | tr -d ' ')"
else
	echo "FAILED — config is not valid:" >&2
	cat "$scratch/out" >&2
	exit 1
fi
