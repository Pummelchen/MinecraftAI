# Pummelchen nginx

This directory contains the nginx-facing files for the live Pummelchen server website.

- `sites-available/pummelchen-swift.conf` is the nginx virtual host used on the VPS.
- `nginx.conf` is the tuned global nginx configuration used on the VPS.
- `site/public/` is the tracked website source currently served from `/opt/pummelchen-swift/runtime/site/public`.
- `site/public/downloads/current-release.json` and `current-release.txt` are small release pointers kept with the website.

The live HTTPS virtual host serves the website and proxies `/api/` plus `/h3/` to the Swift server app on `127.0.0.1:8787`; static release downloads remain nginx-served files under `/downloads/`.

WebTransport is not proxied through nginx. The Swift server app owns UDP port `443` directly and advertises the dedicated endpoint through `/api/v1/transport/webtransport/preflight`.

The global nginx tuning raises worker connection capacity, enables static-file descriptor caching, keeps sendfile/tcp_nopush enabled for large client downloads, and compresses text/json/js/css/svg assets. Large release artifacts remain uncompressed on the fly because ZIP, DMG, MRPACK, and JAR files are already compressed.

Generated release payloads are intentionally not tracked here. DMGs, MRPACKs, release ZIPs, copied mod files, and full release directories are produced by the Swift server app and live under the VPS runtime downloads directory.
