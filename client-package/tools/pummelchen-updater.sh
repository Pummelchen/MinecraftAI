#!/bin/bash
set -euo pipefail

# Compatibility entrypoint for users who still have or call the old terminal
# updater name. Keep all real sync logic in pummelchen-auto-update.sh so the
# LaunchAgent, manual terminal command, repair curl command, and release
# manifest use one maintained updater implementation.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AUTO_UPDATER="$SCRIPT_DIR/pummelchen-auto-update.sh"

if [ ! -x "$AUTO_UPDATER" ]; then
  echo "Pummelchen auto-updater is missing or not executable: $AUTO_UPDATER" >&2
  echo "Repair it with the one-line curl command from the Pummelchen status page." >&2
  exit 1
fi

exec "$AUTO_UPDATER" "$@"
