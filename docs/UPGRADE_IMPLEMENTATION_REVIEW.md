# Upgrade Implementation Review

Date: 2026-06-04
Updated: 2026-06-06

## Plan Comparison

### Release System With Rollback

Implemented:

- `scripts/release_manager.py` creates immutable releases with server files,
  client package manifest, ZIP/MRPack/DMG artifacts when available, DB snapshot,
  checksums, metadata, changelog, tested status, activation state, and public
  release manifest.
- Clients resolve `/downloads/current-release.json` and sync from a release-id
  manifest instead of the moving legacy manifest.
- `rollback` restores server mods/datapacks, client package artifacts, and can
  restore the DB snapshot with `--restore-db`.
- `scripts/daily_update.py` creates and activates a release only after
  successful applied updates.
- `systemd/pummelchen-minecraft.service` makes the game server an explicit
  managed service instead of an ad hoc shell process.

Checks:

- `scripts/validate_project.sh` creates two fixture releases, validates them,
  activates them, rolls back, and confirms newer files are removed.
- The fixture includes a fake upload token and asserts it is not exposed in the
  public release tree.

### Real Server Observability

Implemented:

- `scripts/minecraft_metrics_exporter.py` exposes Minecraft-specific Prometheus
  metrics on localhost port `7792`.
- Prometheus now scrapes `pummelchen_minecraft`.
- Optional RCON/Spark integration provides authoritative TPS/MSPT when RCON is
  enabled, port `25575` is firewalled away from the public internet, and
  `/var/minecraft_mods/secrets/rcon.password` exists. The exporter connects to
  `127.0.0.1` only. Without that secret the exporter falls back to log parsing
  and emits `-1` when no TPS/MSPT signal is available.
- Project-owned Prometheus alert rules cover server down, Java process missing,
  recent crash reports, high heap/RSS, low TPS/high MSPT, low root disk, and
  missing/stale/mismatched `current-release.json` client release pointers.
- Release pointer freshness and DB match are exported as Prometheus metrics.
- Grafana datasource/dashboard provisioning is stored under
  `monitoring/grafana/`.
- `scripts/live_stats_feed.py` and the generated status page include active
  release, player count, and Minecraft RSS alongside existing live VPS graphs.

### CI/CD And Git

Implemented:

- `.github/workflows/ci.yml` runs the project quality gate.
- `scripts/validate_project.sh` automates compile, shell syntax, migrations,
  release/rollback fixture, manifest checks, website generation, live stats,
  exporter, Spark parser fixtures, release pointer metrics, load-lab dry run,
  load preflight dry run, Prometheus alert-rule validation, monitoring JSON, and
  optional Nginx syntax.
- `scripts/deploy_project.sh` validates, syncs project-owned files, installs
  systemd/Nginx/Prometheus/Grafana config and alert rules, regenerates the site,
  smoke-tests, and optionally creates a deploy release.
- `scripts/provision_vps_packages.sh` is the explicit fresh-host apt bootstrap
  for Nginx, Prometheus exporters, Python, SQLite, Java, and optional Grafana.
  Normal deploys still do not run apt.
- Release cleanup removes old client diagnostic ZIP uploads, stale partial
  upload files, empty upload directories, and recreatable caches after a
  successful tested release is activated.

### Gameplay Load Lab

Implemented:

- `scripts/gameplay_load_lab.py` supports schema init, scenario listing, dry
  runs, and real scenarios against a temporary world.
- Scenario samples are written to `load_lab_runs` and `load_lab_samples`.
- Supported scenarios are `fresh_world_idle`, `chunk_spiral`, and
  `manual_join_window`.
- `scripts/load_preflight.py` adds a lighter pre-session gate for TCP
  reachability, concurrent Minecraft status pings, and release pointer
  validation.

Known limitation:

- Fully automated 100-client synthetic joins are not implemented. The current
  lab covers server boot, temporary fresh worlds, chunk-generation proxy load,
  and measured manual join windows. Real bot-client load should be added only
  after selecting a protocol-compatible bot framework for Minecraft 26.1.2.

## Bug Check Notes

- Fixed load-lab dry-run so it no longer writes to `/var/minecraft_mods` during
  local/CI validation.
- Fixed load-lab CPU sampling to carry previous process state between samples.
- Included release metadata JSON in artifact validation.
- Changed DMG and generated command installer to resolve the active release
  pointer and verify the selected ZIP checksum.
- Kept public release publishing scoped to client mods/resourcepacks/shaderpacks
  and package artifacts; private tools such as upload tokens are not published.
- Fixed Spark TPS parsing so duration labels such as `last 5s, 10s, 1m` are not
  mistaken for the actual TPS value.
- Kept RCON optional and local-only; missing or failing RCON never breaks the
  exporter.

## Remaining Production Hardening

- Add a protocol-compatible bot load framework before claiming automated
  100-client gameplay simulation.
