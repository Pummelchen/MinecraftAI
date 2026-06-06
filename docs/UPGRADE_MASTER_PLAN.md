# Pummelchen Upgrade Master Plan

Date: 2026-06-04

This plan lifts the project from a tested modpack control plane into an
operated release platform. The implementation is split into four upgrades that
share one rule: server, client, database, website, and monitoring state must
move together or fail closed.

## Master Plan

1. Establish release identity.
   - Create immutable release directories under `/var/minecraft_mods/releases`.
   - Store release metadata in SQLite.
   - Publish a current release pointer for the website and clients.
   - Keep release artifacts addressable by release ID.

2. Make runtime state observable.
   - Add a localhost Prometheus exporter for Minecraft-specific metrics.
   - Add Prometheus scrape configuration.
   - Add Grafana dashboard/provisioning files.
   - Add simplified Minecraft runtime metrics to the public website.

3. Add repeatable validation and deployment.
   - Add local/project validation script.
   - Add GitHub Actions CI.
   - Add deploy script that validates, syncs, reloads, smokes, and can record a
     release.

4. Add gameplay load lab.
   - Add repeatable temporary-world scenarios.
   - Sample CPU, RSS, errors, region-file growth, and startup behavior.
   - Store run and sample data in SQLite.
   - Make the lab safe by restoring `server.properties` and stopping the test
     server cleanly.

5. Verify and close.
   - Compare code against this plan.
   - Run local automated validation.
   - Deploy to VPS through the deploy script.
   - Run VPS automated validation and smoke tests.
   - Capture website screenshots when UI changes are made.
   - Update README and wiki.
   - Commit and push.

## Automated Quality Gate

Every implementation pass should be covered by repeatable checks:

- Python compile for all project scripts.
- Shell syntax checks for all shell entrypoints.
- SQLite schema init/migration against a temporary DB.
- Release manager dry-run/create/validate checks on a temporary fixture.
- Client manifest parity checks.
- Status-site generation against a temporary fixture.
- Nginx syntax checks when nginx is available.
- Prometheus exporter `/metrics` smoke check.
- Load lab `--dry-run` check.
- Git secret checks for runtime upload tokens and known sensitive strings.
- Website screenshot checks when frontend output changes.

The Minecraft client on the MacBook can be used for end-to-end client validation
when client install/update behavior changes. Prefer automated server/control
plane tests for backend changes; avoid opening Minecraft unless it is needed to
validate client-facing behavior.

## Upgrade 1: Release System With Rollback

### Goals

- Immutable pack releases: server files, client manifest, ZIP/MRPack, checksums,
  DB snapshot, changelog, tested status.
- Clients sync from a release ID, not an unversioned moving manifest.
- One-command rollback to a previous good release.

### Implementation

- Add SQLite tables:
  - `pack_releases`
  - `release_artifacts`
  - `release_events`
- Add `scripts/release_manager.py` with commands:
  - `init`
  - `create`
  - `list`
  - `show`
  - `validate`
  - `activate`
  - `rollback`
  - `current-json`
- Release directory layout:
  - `metadata.json`
  - `CHANGELOG.md`
  - `db/minecraft_mods.sqlite`
  - `manifests/server-files.tsv`
  - `manifests/client-package.tsv`
  - `server-files/mods/...`
  - `server-files/server-datapacks/...`
  - `client-package/...`
  - `artifacts/client.zip`
  - `artifacts/client.zip.sha256`
  - `artifacts/server.mrpack`
- Publish:
  - `/var/minecraft_mods/site/public/downloads/current-release.json`
  - `/var/minecraft_mods/site/public/downloads/releases/<release_id>/...`
- Rollback:
  - Restore server mod/datapack files from release manifests.
  - Restore `client-package`.
  - Restore ZIP/MRPack artifacts.
  - Republish current release pointer.
  - Optionally restore DB snapshot with `--restore-db`.

### Acceptance Checks

- `release_manager.py create --activate` creates DB rows and release files.
- `release_manager.py validate <release_id>` verifies all checksums.
- `release_manager.py rollback` updates the current release pointer to the
  previous active release.
- Client sync manifest URL includes a release ID.

## Upgrade 2: Real Server Observability

### Goals

- Prometheus metrics for TPS/MSPT, heap, player count, chunk/region growth,
  disk/network IO context, crash counters, and mod-update events.
- Grafana dashboard as operator cockpit.
- Public website shows simplified Minecraft runtime status.

### Implementation

- Add `scripts/minecraft_metrics_exporter.py`.
- Add `systemd/pummelchen-minecraft-metrics.service`.
- Add Prometheus job `pummelchen_minecraft`.
- Add Prometheus alert rules for server health, resource pressure, crashes, and
  stale release pointers.
- Add Grafana provisioning and dashboard JSON under `monitoring/grafana`.
- Extend `live_stats_feed.py` with Minecraft runtime summary fields.
- Extend `generate_status_site.py` to show summary stat cards.

### Metrics Strategy

- Player count via Minecraft status ping.
- Process memory/CPU via `/proc`.
- Heap via `jcmd` when available.
- TPS/MSPT via optional RCON/Spark when RCON is firewalled away from the public
  internet and `/var/minecraft_mods/secrets/rcon.password` exists; otherwise log
  pattern parsing when available, or `-1`.
- Chunk growth via world region-file count/rate.
- Crash counters via `crash-reports`.
- Update events via SQLite.
- Release pointer presence, age, and SQLite active-release match via
  `current-release.json`.
- Disk/network details rely on node exporter and Grafana panels.

### Acceptance Checks

- `curl http://127.0.0.1:7792/metrics` returns Prometheus text.
- Prometheus config includes `127.0.0.1:7792`.
- Prometheus rule validation passes for `monitoring/alert-rules/*.yml`.
- Metrics include `pummelchen_release_pointer_present` and
  `pummelchen_release_pointer_matches_active`.
- Website `live-stats.json` includes `minecraft` summary.

## Upgrade 3: CI/CD And Git

### Goals

- GitHub CI validates source changes.
- Deploy script validates, syncs, reloads, smokes, and records a release.
- No manual copy without validation.

### Implementation

- Add `.github/workflows/ci.yml`.
- Add `scripts/validate_project.sh`.
- Add `scripts/deploy_project.sh`.
- Validation covers:
  - Python compile.
  - Shell syntax.
  - SQLite migration/init.
  - Status-site generation.
  - Client manifest parse.
  - Secret exclusion check.
  - Prometheus alert-rule validation.
  - Nginx syntax when nginx is installed.
- Deploy covers:
  - Local validation.
  - Rsync project files to `/var/minecraft_mods`.
  - Install systemd/nginx/cron configs.
  - Install Prometheus scrape config and alert rules when Prometheus is present.
  - Reload services.
  - Run VPS validation.
  - Optionally create an active release.
- Fresh-host package bootstrap is a separate explicit step through
  `scripts/provision_vps_packages.sh`. Deploy does not run apt implicitly.

### Acceptance Checks

- `scripts/validate_project.sh` passes locally.
- GitHub Actions config exists.
- `scripts/deploy_project.sh --dry-run` shows planned actions.

## Upgrade 4: Gameplay Load Lab

### Goals

- Move from "server starts" to "server survives representative scenarios."
- Repeatable temporary-world load scenarios.
- Data stored in SQLite and comparable across releases.

### Implementation

- Add `scripts/gameplay_load_lab.py`.
- Add SQLite tables:
  - `load_lab_runs`
  - `load_lab_samples`
- Scenarios:
  - `fresh_world_idle`
  - `chunk_spiral`
  - `manual_join_window`
- The lab:
  - Backs up and restores `server.properties`.
  - Uses a temporary `level-name`.
  - Starts `./run.sh` or `./start.sh`.
  - Waits for `Done`.
  - Sends console commands for the scenario.
  - Samples RSS/CPU/load/region files/error counters.
  - Stops the server cleanly.

### Acceptance Checks

- `gameplay_load_lab.py --help` works.
- `--dry-run` prints scenario steps without starting Minecraft.
- SQLite tables initialize successfully.
- Run records include status, duration, sample count, and log path.

## Known Limits After This Pass

- TPS/MSPT is authoritative only when local RCON/Spark is enabled; otherwise it
  remains best-effort log parsing or `-1`.
- Player joins are supported as a manual join window plus concurrent status-ping
  preflight; full protocol-compatible bot simulation is a later step.
- Grafana is provisioned by files, but installing Grafana itself remains an
  explicit package bootstrap decision.
- Release rollback defaults to file/package rollback; DB restore is explicit to
  avoid losing later operational logs.
