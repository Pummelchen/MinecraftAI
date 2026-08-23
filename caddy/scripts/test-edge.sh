#!/bin/sh
# Exercise the master edge for real: start Caddy with the production routing
# config against stub upstreams, and assert that each hostname reaches the right
# one and arrives with the client's Host intact. Runs without root and touches
# no production path.
#
# The Host assertion is the important one. Caddy sends the dial address as Host
# to an HTTPS upstream unless told otherwise, and a project whose own config
# matches a specific hostname then matches nothing and returns a bare empty 200
# — success status, no body, no error logged anywhere. That reached production
# once; these stubs echo the Host they received so it cannot again.

set -eu

caddy_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
: "${CADDY_BIN:=$(command -v caddy || true)}"
[ -n "$CADDY_BIN" ] || { echo "error: caddy not found; set CADDY_BIN" >&2; exit 1; }

edge_port=${EDGE_PORT:-8899}
stub_base=${STUB_BASE:-8901}   # must not collide with edge_port
scratch=$(mktemp -d)
fails=0

cleanup() {
	[ -n "${caddy_pid:-}" ] && kill "$caddy_pid" 2>/dev/null || true
	for p in ${api_pid:-}; do kill "$p" 2>/dev/null || true; done
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
mkdir -p "$scratch/logs"

# Each stub reports which upstream it is and what Host it was given.
start_stub() {
	python3 -c "
import http.server, socketserver
name = '$1'
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = ('upstream=%s host=%s' % (name, self.headers.get('Host'))).encode()
        self.send_response(200)
        self.send_header('Content-Type','text/plain')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass
socketserver.TCPServer.allow_reuse_address = True
socketserver.TCPServer(('127.0.0.1', $2), H).serve_forever()
" 2>/dev/null &
}
start_stub minecraft $((stub_base + 0)); s1=$!
start_stub xaios     $((stub_base + 2)); s3=$!
api_pid="$s1 $s3"

MINECRAFTAI_SITE_ADDRESS="http://minecraft.localhost:$edge_port" \
MINECRAFTAI_UPSTREAM="127.0.0.1:$((stub_base + 0))" \
XAIOS_SITE_ADDRESS="http://xaios.localhost:$edge_port" \
XAIOS_UPSTREAM="127.0.0.1:$((stub_base + 2))" \
CADDY_LOG_DIR="$scratch/logs" \
CADDY_ADMIN="unix/$scratch/admin.sock" \
	"$CADDY_BIN" run --config "$caddy_root/Caddyfile" --adapter caddyfile >"$scratch/caddy.log" 2>&1 &
caddy_pid=$!

i=0
while [ $i -lt 50 ]; do
	curl -fsS -o /dev/null -H 'Host: minecraft.localhost' "http://127.0.0.1:$edge_port/" 2>/dev/null && break
	i=$((i + 1)); sleep 0.2
done
[ $i -lt 50 ] || { echo "edge did not come up:"; cat "$scratch/caddy.log"; exit 1; }

base="http://127.0.0.1:$edge_port"
get() { curl -s -H "Host: $1.localhost" "$base${2:-/}"; }

echo "routing — each hostname reaches its own upstream:"
check "minecraft -> minecraft stub" "upstream=minecraft" "$(get minecraft | awk '{print $1}')"
check "xaios     -> xaios stub"     "upstream=xaios"     "$(get xaios     | awk '{print $1}')"

echo "host preservation — upstream sees the client's Host, not the dial address:"
check "minecraft Host forwarded"    "host=minecraft.localhost" "$(get minecraft | awk '{print $2}')"
check "xaios Host forwarded"        "host=xaios.localhost"     "$(get xaios     | awk '{print $2}')"

echo "isolation:"
check "unknown host reaches nothing" "0" "$(curl -s -H 'Host: nobody.localhost' "$base/" | grep -c 'upstream=' || true)"

echo "edge policy:"
check "deep paths route too"        "upstream=xaios"   "$(get xaios /os/some/deep/path | awk '{print $1}')"

# RoomCAD's own Caddy terminates TLS on 8443, so a plain stub cannot stand in
# for it. Its two correctness properties are asserted against the adapted
# config instead: SNI must name RoomCAD's certificate, or the handshake fails,
# and Host must be forwarded, or its hostname-matched site block matches
# nothing and returns a bare empty 200. Both regressed in development.
echo "roomcad https upstream (from adapted config):"
adapted=$(CADDY_LOG_DIR="$scratch/logs" CADDY_ADMIN="unix/$scratch/adapt.sock" \
	"$CADDY_BIN" adapt --config "$caddy_root/Caddyfile" --adapter caddyfile 2>/dev/null)
rc_sni=$(printf '%s' "$adapted" | python3 -c "
import sys, json
c = json.load(sys.stdin)
for s in c['apps']['http']['servers'].values():
    for r in s.get('routes', []):
        if any('roomcad' in h for m in r.get('match', []) for h in m.get('host', [])):
            for sub in r['handle'][0]['routes']:
                for h in sub['handle']:
                    if h.get('handler') == 'reverse_proxy':
                        print(h.get('transport', {}).get('tls', {}).get('server_name', ''))
")
rc_host=$(printf '%s' "$adapted" | python3 -c "
import sys, json
c = json.load(sys.stdin)
for s in c['apps']['http']['servers'].values():
    for r in s.get('routes', []):
        if any('roomcad' in h for m in r.get('match', []) for h in m.get('host', [])):
            for sub in r['handle'][0]['routes']:
                for h in sub['handle']:
                    if h.get('handler') == 'reverse_proxy':
                        print(h.get('headers', {}).get('request', {}).get('set', {}).get('Host', [''])[0])
")
check "sni names roomcad cert"      "roomcad.91.99.176.243.nip.io" "$rc_sni"
check "host header forwarded"       "{http.request.host}"          "$rc_host"

if [ "$fails" -eq 0 ]; then
	echo "all edge tests passed"
else
	echo "$fails test(s) failed" >&2
	exit 1
fi
