# Pummelchen Caddy

Caddy is the production HTTPS edge for the public website, release downloads, status APIs, and client control API. The Swift services listen only on loopback; Caddy maps the public versioned routes to those services:

| Public prefix | Upstream |
| --- | --- |
| `/api/26.1.2/` and `/api/` | `127.0.0.1:8787` |
| `/api/26.2/` | `127.0.0.1:8788` |
| `/api/26.3/` | `127.0.0.1:8789` |

`Caddyfile` defines production hostnames, automatic HTTPS, HTTP/2 and HTTP/3, redirects, and JSON access logs. `PummelchenRoutes.caddy` is the route contract imported by both production and the integration tests. Environment placeholders make isolated tests possible without changing production defaults.

`site/public/` is the tracked website source deployed to `/var/minecraftai/web/site/public`. Its `downloads/` directory contains only a `.gitignore`; the Swift release pipeline generates current-release pointers and immutable release artifacts in the runtime tree. A website deployment must preserve that runtime downloads directory.

## Install

Use the official Caddy Debian package and service. Do not replace the packaged unit; install the tracked hardening drop-in after reviewing it for the target host.

```bash
sudo install -d -m 0755 /etc/caddy
sudo install -m 0644 "Server App/caddy/Caddyfile" /etc/caddy/Caddyfile
sudo install -m 0644 "Server App/caddy/PummelchenRoutes.caddy" /etc/caddy/PummelchenRoutes.caddy
sudo install -d -m 0755 /etc/systemd/system/caddy.service.d
sudo install -m 0644 "Server App/systemd/caddy.service.d/pummelchen-hardening.conf" \
  /etc/systemd/system/caddy.service.d/pummelchen-hardening.conf
sudo caddy fmt --overwrite /etc/caddy/Caddyfile
sudo caddy fmt --overwrite /etc/caddy/PummelchenRoutes.caddy
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl daemon-reload
```

The `caddy` service account must be able to traverse and read `/var/minecraftai/web/site/public`. Caddy stores automatically managed certificates below its packaged service home; do not delete or relocate that state during routine deploys.

## Validation

Run the route integration suite before deployment:

```bash
CADDY_BIN="$(command -v caddy)" python3 "Server App/caddy/Tests/test_edge.py"
```

For a live change, validate the candidate config before stopping the current edge. Keep its configuration and service state available for immediate rollback. After cutover, verify both hostnames, HTTP-to-HTTPS and port-7788 redirects, all three versioned APIs, current-release cache headers, a ranged download, and HTTP/3 externally.

Large artifacts remain static files and never pass through Swift. Current-release pointers and website/API responses are not cached. Immutable release-directory artifacts use a one-year immutable cache; mutable top-level download aliases use a 60-second cache.
