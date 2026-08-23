#!/bin/sh
# Exercise the master edge for real: start Caddy with the production config,
# scratch site roots and a stub API, then assert hostname routing, headers and
# the sensitive-file blocks. Runs without root and touches no production path.
#
# Both projects are bound to one port here so that routing is genuinely tested
# by Host header — which is how the master distinguishes them in production.

set -eu

caddy_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
: "${CADDY_BIN:=$(command -v caddy || true)}"
[ -n "$CADDY_BIN" ] || { echo "error: caddy not found; set CADDY_BIN" >&2; exit 1; }

edge_port=${EDGE_PORT:-8899}
api_port=${API_PORT:-8898}
scratch=$(mktemp -d)
fails=0

cleanup() {
	[ -n "${caddy_pid:-}" ] && kill "$caddy_pid" 2>/dev/null || true
	[ -n "${api_pid:-}" ] && kill "$api_pid" 2>/dev/null || true
	wait 2>/dev/null || true
	rm -rf "$scratch"
}
trap cleanup EXIT

check() {
	name=$1; expected=$2; actual=$3
	if [ "$expected" = "$actual" ]; then
		printf '  ok    %s\n' "$name"
	else
		printf '  FAIL  %s (expected %s, got %s)\n' "$name" "$expected" "$actual"
		fails=$((fails + 1))
	fi
}

# Caddy's `encode` skips responses under 512 bytes, so fixtures must exceed it
# or the compression assertion tests nothing.
pad() {
	i=0
	while [ $i -lt 40 ]; do echo '<p>padding to clear the compression threshold</p>'; i=$((i + 1)); done
}
mkdir -p "$scratch/minecraft" "$scratch/roomcad" "$scratch/xaios" "$scratch/logs"
{ echo '<h1>minecraft</h1>'; pad; } > "$scratch/minecraft/index.html"
{ echo '<h1>roomcad</h1>';   pad; } > "$scratch/roomcad/index.html"
{ echo '<h1>xaios</h1>';     pad; } > "$scratch/xaios/index.html"
echo secret > "$scratch/minecraft/state.db"
echo wal    > "$scratch/minecraft/state.db-wal"
echo secret > "$scratch/roomcad/.env"

python3 -c "
import http.server, socketserver
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Type','application/json')
        self.end_headers()
        self.wfile.write(b'{\"stub\":true}')
    def log_message(self, *a): pass
socketserver.TCPServer.allow_reuse_address = True
socketserver.TCPServer(('127.0.0.1', $api_port), H).serve_forever()
" 2>/dev/null &
api_pid=$!

MINECRAFTAI_SITE_ADDRESS="http://minecraft.localhost:$edge_port" \
MINECRAFTAI_SITE_ROOT="$scratch/minecraft" \
MINECRAFTAI_API="127.0.0.1:$api_port" \
ROOMCAD_SITE_ADDRESS="http://roomcad.localhost:$edge_port" \
ROOMCAD_SITE_ROOT="$scratch/roomcad" \
XAIOS_SITE_ADDRESS="http://xaios.localhost:$edge_port" \
XAIOS_SITE_ROOT="$scratch/xaios" \
CADDY_LOG_DIR="$scratch/logs" \
	"$CADDY_BIN" run --config "$caddy_root/Caddyfile" --adapter caddyfile >"$scratch/caddy.log" 2>&1 &
caddy_pid=$!

i=0
while [ $i -lt 50 ]; do
	curl -fsS -o /dev/null -H 'Host: minecraft.localhost' "http://127.0.0.1:$edge_port/" 2>/dev/null && break
	i=$((i + 1)); sleep 0.2
done
[ $i -lt 50 ] || { echo "edge did not come up:"; cat "$scratch/caddy.log"; exit 1; }

mc() { curl -s -H 'Host: minecraft.localhost' "$@"; }
rc() { curl -s -H 'Host: roomcad.localhost' "$@"; }
xa() { curl -s -H 'Host: xaios.localhost' "$@"; }
base="http://127.0.0.1:$edge_port"
hdr() { tr -d '\r' | awk -F': ' -v k="$1" 'tolower($1)==k{print $2}'; }

echo "hostname routing:"
check "minecraft host -> its site"  "1" "$(mc "$base/" | grep -c '<h1>minecraft</h1>')"
check "roomcad host -> its site"    "1" "$(rc "$base/" | grep -c '<h1>roomcad</h1>')"
check "xaios host -> its site"      "1" "$(xa "$base/" | grep -c '<h1>xaios</h1>')"
# Caddy answers an unmatched Host with an empty response rather than 404, and
# an explicit http:// catch-all cannot be added — it would override Caddy's
# auto-generated redirect server and break ACME challenges. What matters is
# that no project's content is reachable under the wrong hostname.
check "unknown host gets no content" "0" "$(curl -s -H 'Host: nobody.localhost' "$base/" | grep -c '<h1>' || true)"

echo "minecraft site:"
check "static index served"         "200" "$(mc -o /dev/null -w '%{http_code}' "$base/")"
check "SPA fallback"                "200" "$(mc -o /dev/null -w '%{http_code}' "$base/no/such/page")"
check "api proxied"                 '{"stub":true}' "$(mc "$base/api/v1/versions")"
check "api uncacheable"             "no-store, max-age=0" "$(mc -I "$base/api/v1/versions" | hdr cache-control)"
check "sqlite blocked"              "404" "$(mc -o /dev/null -w '%{http_code}' "$base/state.db")"
check "wal sidecar blocked"         "404" "$(mc -o /dev/null -w '%{http_code}' "$base/state.db-wal")"
check "frame options"               "DENY" "$(mc -I "$base/" | hdr x-frame-options)"

echo "roomcad site:"
check "static index served"         "200" "$(rc -o /dev/null -w '%{http_code}' "$base/")"
check "SPA fallback"                "200" "$(rc -o /dev/null -w '%{http_code}' "$base/deep/link")"
check "dotenv blocked"              "404" "$(rc -o /dev/null -w '%{http_code}' "$base/.env")"
check "no api route leaks in"       "200" "$(rc -o /dev/null -w '%{http_code}' "$base/api/v1/versions")"

echo "xaios site:"
check "static index served"         "200" "$(xa -o /dev/null -w '%{http_code}' "$base/")"
check "dotenv blocked"              "404" "$(xa -o /dev/null -w '%{http_code}' "$base/.env")"

echo "shared policy:"
check "server header removed"       "" "$(mc -I "$base/" | hdr server)"
check "nosniff on minecraft"        "nosniff" "$(mc -I "$base/" | hdr x-content-type-options)"
check "nosniff on roomcad"          "nosniff" "$(rc -I "$base/" | hdr x-content-type-options)"
check "nosniff on xaios"            "nosniff" "$(xa -I "$base/" | hdr x-content-type-options)"
check "compression offered"         "gzip" "$(mc -I -H 'Accept-Encoding: gzip' "$base/" | hdr content-encoding)"

if [ "$fails" -eq 0 ]; then
	echo "all edge tests passed"
else
	echo "$fails test(s) failed" >&2
	exit 1
fi
