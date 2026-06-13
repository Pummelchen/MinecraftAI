# Pummelchen nginx

This directory contains the nginx-facing files for the live Pummelchen server website.

- `sites-available/pummelchen-swift.conf` is the nginx virtual host used on the VPS.
- `site/public/` is the tracked website source currently served from `/opt/pummelchen-swift/runtime/site/public`.
- `site/public/downloads/current-release.json` and `current-release.txt` are small release pointers kept with the website.

The live HTTPS virtual host enables HTTP/3 over QUIC with `listen 443 quic reuseport`, `http3 on`, and `Alt-Svc: h3=":443"; ma=86400`. `/api/` and `/h3/` are proxied to the Swift server app on `127.0.0.1:8787`; static release downloads remain nginx-served files under `/downloads/`.

WebTransport is not proxied through nginx. The Swift server app advertises its dedicated WebTransport endpoint separately through `/api/v1/transport/webtransport/preflight`, defaulting to UDP port `7443`.

Generated release payloads are intentionally not tracked here. DMGs, MRPACKs, release ZIPs, copied mod files, and full release directories are produced by the Swift server app and live under the VPS runtime downloads directory.
