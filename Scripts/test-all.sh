#!/bin/sh

set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repository_root"

: "${CADDY_BIN:=$(command -v caddy || true)}"
if [ -z "$CADDY_BIN" ]; then
    echo "error: set CADDY_BIN or install caddy before running the full suite" >&2
    exit 1
fi

swift test --package-path "Server App/MCPummelchenModShared"
swift test --package-path "Client App/MCPummelchenModClient"
swift test --package-path "Server App/MCPummelchenModServer"
CADDY_BIN="$CADDY_BIN" python3 "Server App/caddy/Tests/test_edge.py"
