# Pummelchen Production Audit

Date: 2026-06-04

This project is the control plane for the Pummelchen Server Minecraft pack. The
production copy runs on the VPS in `/var/minecraft_mods`; the live server folder
is `/var/minecraft_26.1.2`.

## Audit Scope

Server-side:
- SQLite tracker schema and write paths.
- URL import and mod resolution.
- Server boot-test flow and rollback behavior.
- Daily update automation.
- Client package and MRPack rebuilds.
- Nginx, cron, systemd, and live stats services.
- Web status generation.

Client-side:
- macOS Apple Silicon DMG installer.
- Managed `Install Mods.command` package installer.
- Java 25 install/update path.
- NeoForge profile install.
- Per-file auto-updater.
- Client Doctor diagnostics uploader.
- Generated user helper commands.

Server-client boundary:
- `/downloads/client-sync-manifest.tsv`.
- `/downloads/client-files/...` static file sync.
- ZIP and SHA256 package publication.
- Nginx `/client-logs/upload` proxy.
- Token-protected upload receiver and SQLite upload index.
- Crash log and local path redaction.

## Production Readiness Model

The project should tolerate these expected failures without corrupting the pack:
- A mod metadata API times out or returns malformed data.
- A candidate file downloads partially or has an unexpected size.
- A candidate mod crashes during boot test.
- A package rebuild fails after a boot test passed.
- A client update is interrupted during download or install.
- Two update jobs are triggered close together.
- A client uploads a slow, oversized, invalid, or unauthenticated diagnostic
  bundle.
- The static site generator and live stats writer run while the daily updater is
  active.

The current design should keep these invariants:
- SQLite is the source of truth for mod status.
- Only boot-tested server mods are marked OK and shown as successful updates.
- Every active server mod is included in the client package.
- Client auto-update uses a manifest with SHA256 verification.
- Failed server candidates are quarantined outside `mods/`.
- Failed client package rebuilds do not leave a half-updated package.
- The public web page exposes install/status information, not secrets or upload
  tokens.

## Audit Findings And Fixes

### Server

Finding: a passing boot test followed by a failed client package rebuild could
leave the server file updated while SQLite and the client package still reflected
the old state.

Fix: `scripts/daily_update.py` now snapshots `client-package` before each
client-affecting update. If the rebuild fails after a server boot test, it
restores the previous client package, moves the new server jar to
`mods.failed/<label>`, restores old server jars, and records a failed update
event.

Finding: manual URL batch installs changed `client-package` but did not rebuild
the ZIP/MRPack artifacts before returning.

Fix: `scripts/process_url_batch.py` now triggers the shared daily updater
`rebuild-client` command after any successful non-metadata batch install.

Finding: the status-site cron was live on the VPS but not represented as a
project-owned file, and it had no lock.

Fix: `cron/pummelchen-status-site` was added with `flock` so repeated deploys
are reproducible and overlapping generators are skipped.

Finding: the live stats and upload receiver services had minimal sandboxing.

Fix: both systemd services now run with `NoNewPrivileges`, private tmp/devices,
strict system protection, home protection, native syscall architecture, and
limited writable paths.

### Client

Finding: the generated `Pummelchen Minecraft.command` could open Minecraft even
if the pre-launch sync failed.

Fix: the command now opens Minecraft only after the updater exits successfully.
On failure it stops with a clear message so the client does not join with a
stale mod pack.

Finding: the generated `Pummelchen Send Logs.command` printed a success message
even if diagnostic upload failed.

Fix: the command now checks the doctor exit status and prints success or failure
accordingly.

### Server-Client Boundary

Finding: the diagnostic upload receiver had no per-connection read timeout.

Fix: `scripts/client_log_receiver.py` now applies a 35-second socket timeout and
returns `upload_timeout` for stalled uploads.

Finding: Nginx proxied the upload endpoint without explicit upload method and
proxy timeouts.

Fix: the upload location now accepts POST only and has explicit body, send,
connect, write, and read timeouts.

Finding: internal risk flags were still rendered on public mod cards.

Fix: risk flags remain in SQLite for operations, but are no longer displayed on
the user-facing web page.

## Operational Checks

Run after code or config changes:

```bash
python3 -m py_compile scripts/client_log_receiver.py scripts/daily_update.py scripts/process_url_batch.py scripts/generate_status_site.py scripts/live_stats_feed.py scripts/server_ops.py scripts/moddb.py
bash -n "client-package/Install Mods.command" client-package/tools/pummelchen-auto-update.sh client-package/tools/pummelchen-client-doctor.sh scripts/build_mac_client_dmg.sh
python3 scripts/generate_status_site.py --db data/minecraft_mods.sqlite --output-dir /tmp/pummelchen-audit-site --server-dir /var/minecraft_26.1.2 --public-url http://91.99.176.243:7788
```

Run on the VPS after deploy:

```bash
systemctl daemon-reload
systemctl restart pummelchen-client-log-receiver.service
systemctl restart pummelchen-live-stats.service
systemctl status --no-pager pummelchen-client-log-receiver.service
systemctl status --no-pager pummelchen-live-stats.timer
nginx -t
sqlite3 /var/minecraft_mods/data/minecraft_mods.sqlite "PRAGMA integrity_check;"
python3 /var/minecraft_mods/scripts/daily_update.py --db /var/minecraft_mods/data/minecraft_mods.sqlite --server-dir /var/minecraft_26.1.2 rebuild-client
python3 /var/minecraft_mods/scripts/generate_status_site.py --db /var/minecraft_mods/data/minecraft_mods.sqlite --output-dir /var/minecraft_mods/site/public --server-dir /var/minecraft_26.1.2 --public-url http://91.99.176.243:7788
python3 /var/minecraft_mods/scripts/live_stats_feed.py --output /var/minecraft_mods/site/public/live-stats.json --state /var/minecraft_mods/site/live-stats-history.json --server-dir /var/minecraft_26.1.2
curl -fsS http://127.0.0.1:7788/ >/dev/null
curl -fsS http://127.0.0.1:7788/live-stats.json >/dev/null
curl -fsS http://127.0.0.1:7791/health
```

## 100-Client Readiness Notes

The static web page, client downloads, and per-file sync are suitable for about
100 clients because Nginx serves static files directly and the client updater
uses SHA256 checks to skip unchanged files.

The upload receiver is intentionally small and localhost-only behind Nginx. It
does not extract uploaded zips, enforces a 25 MB upload limit, uses a shared
token, and stores files by date. For 100 clients, watch disk growth under
`/var/minecraft_mods/client_log_uploads`; release cleanup removes diagnostic ZIP
uploads after 30 days and stale partial uploads after one hour.

The remaining capacity question is the Minecraft server itself, not the project
control plane. Before opening to 100 concurrent clients, run a staged load test
with representative players or bots, start with `scripts/load_preflight.py`, and
track TPS, heap, GC pauses, RAM, and CPU while worldgen-heavy areas are explored.

## Residual Risks

- The mod boot test proves startup, not long multiplayer gameplay stability.
- Performance profiling currently uses low-confidence idle comparisons and needs
  repeated runs before tuning decisions.
- The client upload token is shared by installed clients. If it leaks, rotate
  `/var/minecraft_mods/secrets/client-log-upload.token`, rebuild the client
  package, and reinstall or auto-update clients with the new token.
- The macOS installer is unsigned and not notarized because the project has no
  Apple Developer account. Fresh Macs need the normal first-launch manual
  override; package contents are still SHA256-verified by the installer.
- The active Minecraft server has many worldgen and structure mods. Pregenerating
  chunks or rate-limiting exploration may be needed for 100-player events.
