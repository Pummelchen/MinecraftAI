# Minecraft Mod Tracker

The production copy lives on the VPS at `/var/minecraft_mods`, outside any
Minecraft server folder. This local folder is only a staging copy.

`/var/minecraft_mods` now holds the SQLite-backed source of truth for the
Minecraft mod tracker. The Google Sheet is legacy context only and should not be
used for current tracker updates.

## Git And Secrets

This repository tracks source code, deployment configuration, documentation,
monitoring config, URL batch inputs, and lightweight CSV exports. Runtime
databases, built client packages, generated status-site output, logs, and
secrets are intentionally excluded by `.gitignore`.

The client log upload token is required at runtime but must not be committed.
The production token lives on the VPS at
`/var/minecraft_mods/secrets/client-log-upload.token` and is copied into the
active server client package as `client-package/tools/upload-token.txt` when a
release is built. The repository keeps only
`client-package/tools/upload-token.txt.example`.

Third-party runtime binaries such as the NeoForge client installer JAR are also
not committed. Run `scripts/fetch_client_runtime_assets.sh` on the VPS or local
build host before rebuilding a client package if
`client-package/neoforge-26.1.2.71-installer.jar` is missing.

## Files

- `data/minecraft_mods.sqlite` - normalized SQLite database.
- `data/minecraft_grid_export_2026-06-03.csv` - raw A:N export imported from the
  Google Sheet.
- `exports/minecraft_clean_sheet_2026-06-03.csv` - deduplicated sheet view.
- `exports/minecraft_google_sheet_clean_2026-06-03.csv` - compact operational
  view used to clean the Google Sheet.
- `exports/minecraft_google_sheet_status_2026-06-03.csv` - status-focused view
  for review in Google Sheets.
- `scripts/moddb.py` - import, export, summary, and read-only SQL CLI.
- `scripts/import_url_batch.py` - imports pasted URL batches into SQLite work
  queue tables and inserts pending tracker rows for unseen projects.
- `scripts/process_url_batch.py` - resolves queued URL-batch projects, downloads
  compatible files, runs isolated acceptance tests before touching live server
  files, then runs full-pack boot tests and updates tracker status.
- `scripts/generate_status_site.py` - generates the static Pummelchen Server
  status/install page from SQLite and current VPS stats.
- `scripts/live_stats_feed.py` - writes `site/public/live-stats.json` every 30
  seconds for live VPS graphs on the status page.
- `scripts/minecraft_metrics_exporter.py` - localhost Prometheus exporter for
  Minecraft process/player/crash/update/release metrics on port `7792`.
- `scripts/client_log_receiver.py` - localhost HTTP receiver for token-protected
  macOS client diagnostic bundle uploads via Nginx `/client-logs/upload` plus
  lightweight installer step events via `/client-logs/installer-event`.
- `scripts/server_ops.py` - manages multi-version server metadata, richer mod
  metadata, and idle performance profiling.
- `scripts/daily_update.py` - daily safe update pipeline: backs up tracker
  state, scans compatible releases, boot-tests candidates, applies only passing
  updates, rebuilds client ZIP/MRPack artifacts, creates an immutable release
  when updates were applied, and logs visible update events.
- `scripts/release_manager.py` - creates, validates, activates, publishes, and
  rolls back immutable pack releases containing server files, client manifests,
  package artifacts, DB snapshot, changelog, and checksums.
- `scripts/gameplay_load_lab.py` - repeatable gameplay/load scenarios for fresh
  worlds, chunk-generation proxy tests, and manual join windows.
- `scripts/mod_acceptance_lab.py` - isolated pre-live mod acceptance lab. It
  creates throwaway NeoForge servers, tests one mod plus its required dependency
  closure plus known-working context, and then rolls 10-mod blocks upward into
  dated acceptance releases.
- `scripts/headless_client_lab.py` - VPS real-client smoke lab. It syncs the
  active client package, launches HeadlessMC/HMC-Specifics under Xvfb or an
  existing X display, joins the server, walks, captures renderer/log evidence,
  and records runs in SQLite.
- `scripts/check_client_manifest.py` - validates client package manifest syntax,
  checksums, and strict parity when package files are present.
- `scripts/check_client_mod_dependencies.py` - scans NeoForge mod metadata,
  including embedded jar-in-jar libraries, and fails the client package when a
  required client-side dependency or Minecraft/NeoForge version range is
  missing.
- `scripts/sanitize_resource_pack_metadata.py` - repairs known pack metadata
  schema drift that can crash the Minecraft client during resource-pack
  discovery, including legacy overlay `formats` gaps and deprecated new overlay
  `formats` keys.
- `scripts/macos_client_launch_smoke.py` - local macOS-only smoke launcher that
  uses the installed Minecraft launcher metadata, strips disabled quick-play
  placeholders, runs NeoForge directly, watches `latest.log`/crash reports, and
  terminates after the client reaches a startup marker.
- `scripts/validate_project.sh` - automated quality gate for Python compile,
  shell syntax, schema migration, release/rollback fixture, manifest checks,
  resource-pack metadata repair, client dependency validation, generated
  website, live stats, exporter, installer-event receiver, acceptance-lab
  planning, headless-client dry-run/sync checks, load-lab dry run, monitoring
  JSON, and optional Nginx syntax.
- `scripts/deploy_project.sh` - validated deployment script for copying
  project-owned files to the VPS, installing/reloading services, smoke-testing,
  and optionally creating a deploy release.
- `scripts/build_mac_client_dmg.sh` - builds the one-touch macOS Apple Silicon
  visual installer DMG. The small DMG resolves the active release pointer, shows
  install progress and planned mod/resource/shader counts, downloads and
  verifies the matching client package, reports setup telemetry to SQLite, and
  installs the managed client tooling.
- `client-installer/` - Swift/AppKit progress runner and bootstrap script used
  inside the Mac installer DMG.
- `scripts/fetch_client_runtime_assets.sh` - downloads third-party runtime
  binaries needed by the client package, such as the NeoForge installer JAR.
- `scripts/update_next_batch.py` - one-off audited update for the 2026-06-03
  manually requested CurseForge URL batch.
- `site/assets/pummelchen-hero.png` - top-of-page image copied into the generated
  status site.
- `client-package/Install Mods.command` - managed macOS client installer used by
  the DMG after the current client package is downloaded.
- `client-package/tools/AddPummelchenServer.java` - idempotent `servers.dat`
  updater that adds or repairs one Pummelchen Server entry by normalized
  address/name and removes duplicates.
- `client-package/tools/pummelchen-auto-update.sh` - installed background
  per-file client sync from the VPS manifest.
- `client-package/tools/pummelchen-client-doctor.sh` - installed diagnostic
  collector/uploader for crash reports, launcher logs, Pummelchen state, and
  mod/resource/shader hashes.
- `nginx/pummelchen-server.conf` - project-owned Nginx site config for port
  `7788`.
- `monitoring/` - project-owned Prometheus scrape config and exporter defaults.
- `monitoring/grafana/` - Grafana datasource/dashboard provisioning for the
  Pummelchen operator cockpit.
- `cron/pummelchen-daily-update` - noon UTC updater cron definition.
- `systemd/pummelchen-live-stats.*` - 30-second systemd timer/service that
  refreshes the live stats JSON feed.
- `systemd/pummelchen-client-log-receiver.service` - upload receiver service for
  client diagnostic bundles.
- `systemd/pummelchen-minecraft-metrics.service` - Prometheus exporter service
  for Minecraft-specific metrics.
- `systemd/pummelchen-minecraft.service` - managed Minecraft server service for
  boot-time start and explicit operator start/stop/restart.
- `server-config/user_jvm_args.txt` - tracked JVM args for the active server.
- `site/public/index.html` - generated static status page staging copy.

For the production audit plan, hardening notes, 100-client readiness checklist,
and deploy validation commands, see `PRODUCTION_AUDIT.md`.

## Current Snapshot

As of the 2026-06-04 macOS installer rollout:

- 489 tracker rows, 476 canonical rows, 13 duplicate rows collapsed.
- 296 canonical rows OK, 155 skipped, 25 failed; work score is `62.2%`.
- The active `/var/minecraft_26.1.2` server has 271 active server mod jars.
- The built macOS Apple Silicon package currently contains 286 mod files, 9
  resource packs, and 1 shader pack. Every active server jar is present in the
  client package; the remaining client jars are client-only extras.
- System Java and the Minecraft server runtime are aligned on OpenJDK `25.0.3`;
  `/usr/bin/java` resolves to `/usr/lib/jvm/java-25-openjdk-amd64/bin/java`,
  which is also the explicit runtime in `/var/minecraft_26.1.2/run.sh`.
- The server JVM args are tracked in `server-config/user_jvm_args.txt` and on
  the VPS at `/var/minecraft_26.1.2/user_jvm_args.txt`.
- The rebuilt one-touch client package is
  `/var/minecraft_26.1.2/minecraft_26.1.2_client_macos_apple_silicon.zip`.
- Active tested release:
  `release_20260604_193955_deploy`.
- Current ZIP SHA256:
  `d5979386be446ea0fb215db524897976574f0788753c10166530f6d18f76ed97`.
- Current MRPack SHA256:
  `abed3858c5487bd2c70b90cfe6a555f56ff56d228b433903a19e01ca21360b74`.
- Current macOS installer DMG SHA256:
  `60561dc06cc03c6b8fb231221b7ccad01adf60e9a95326d1d5df7192b92e1d2d`.
- The 2026-06-04 client launch repair added OELib for Yumemigusa, replaced
  HealingBed with the 26.1.2 NeoForge build, repaired Structory Towers pack
  metadata, and verified the installed macOS client with
  `scripts/macos_client_launch_smoke.py` until the client reached a startup
  marker.
- Final update validation `daily_update_clumps_20260604_110950` reached
  `STATUS=started` after Spark, Architectury API, ChocoCraft, and Clumps were
  active together.
  Residual nonfatal ERROR-tagged content/model/version-check lines are covered by
  `scripts/process_url_batch.py`'s baseline filter.

## Latest Batch Notes

The 2026-06-04 automation/update run added and tested:

- Spark profiler: `spark-1.10.172-neoforge.jar`, accepted after
  `20260604_spark_final_active_set`.
- Architectury API: `architectury-neoforge-20.0.4.jar`, accepted by the daily
  updater and included in the rebuilt client package.
- ChocoCraft: `chococraft-26.1.2-neoforge-0.17.1.jar`, accepted from a beta
  compatible release after boot testing.
- Clumps: `Clumps-neoforge-26.1.2-26.1.2.1.jar`, accepted after boot testing.
- Abridged: `abridged-2.0.1-neoforge-26.1.jar`, rejected by boot test and
  rolled back; it remains non-public in update history.

The earlier 2026-06-04 Create: Steam 'n' Rails URL batch processed 1 requested
URL:

- Create: Steam 'n' Rails was added to the SQLite watchlist and marked skipped:
  no official NeoForge 26.1.x release exists yet. CurseForge project `688231`
  and Modrinth project `ZzjhlDgM` are tracked; latest stable NeoForge-tagged
  release found is `I6GhUCyk` for Minecraft 1.20.1.
- It is not installed on the server and is not included in the Mac client
  package. Recheck when Create and Steam 'n' Rails publish compatible 26.1.x
  builds.
- The prior AutoFishing URL batch processed 1 requested URL:
  `autofishing-1.0.1.jar` accepted after boot testing and included in the Mac
  client package.
- The prior next-batch-6 URL batch processed 30 requested URLs: 29 server-side
  mods accepted, 1 client-only mod included, and no failures.
- Core client entries are tracked and included: Sodium, Iris, BSL Classic,
  ModernArch, and Dramatic Skys. NeoForge is tracked as the runtime/client
  loader requirement.
- ModernArch now tracks both CurseForge and Modrinth sources. The requested
  Modrinth 26.1.2 URL resolves to release `noJHxn6d`, which matches the already
  included `ModernArch v2.4.3 [26.1] [128x].zip` file by hash.
- BSL Classic is included as a shader pack for Iris even though the latest stable
  CurseForge file is tagged `1.21.9`/Iris instead of `26.1.x`; SQLite records
  this as a client-side compatibility override.
- `scripts/process_url_batch.py` supports Modrinth project URLs in addition to
  CurseForge URLs, including Modrinth version selection, downloads, and required
  dependency handling.

## Status Site

The VPS serves a static Pummelchen Server page at:

```text
http://91.99.176.243:7788/
```

Nginx is configured with `/var/minecraft_mods/nginx/pummelchen-server.conf` and
only listens on port `7788`. The site is generated into
`/var/minecraft_mods/site/public` and refreshed every five minutes by
`/etc/cron.d/pummelchen-status-site`.

The page starts with the centered Pummelchen Server image, then includes current
Debian/VPS stats, successful tested updates, the active server-side mod list,
client-side visual extras, and one macOS Apple Silicon installer path. The
supported client install is the DMG at:

```text
http://91.99.176.243:7788/downloads/Pummelchen-Client-Installer.dmg
```

The DMG app is intentionally small. It opens a native progress window, resolves
the current release, shows how many mods/resource packs/shader packs are in the
pack, downloads the current verified ZIP package on first install, installs or
updates a user-local Temurin Java 25 Apple Silicon runtime when needed, syncs
mods, resource packs, and shader packs, installs the NeoForge client profile,
adds or repairs exactly one `Pummelchen Server` entry in `servers.dat`, verifies
hashes, and opens the Minecraft Launcher when the client is ready. It also
installs a user LaunchAgent for
`/Users/<user>/Library/Application Support/Pummelchen/bin/pummelchen-auto-update.sh`.
After the first install, clients resolve `/downloads/current-release.json` and
sync from `/downloads/releases/<release-id>/client-sync-manifest.tsv`, so every
sync run targets a specific tested release. The legacy
`/downloads/client-sync-manifest.tsv` path remains as a compatibility fallback.
The installer also creates
`~/Applications/Pummelchen Minecraft.command`, which runs an immediate sync and
then opens Minecraft for a deterministic pre-play update.
It also creates `~/Applications/Pummelchen Send Logs.command`, which redacts and
uploads a diagnostic bundle to the VPS. The background updater runs the same
doctor in `--upload-if-new-crash` mode after update checks, so fresh crash
reports are uploaded automatically.

Client diagnostic bundles are stored on the VPS under
`/var/minecraft_mods/client_log_uploads/YYYY/MM/DD/` and indexed in SQLite table
`client_log_uploads`. The upload endpoint is proxied by Nginx at
`/client-logs/upload` to the localhost receiver on port `7791`.

The DMG installer also reports lightweight setup events immediately to
`/client-logs/installer-event`. The Swift app sends `app_started` before the
bootstrap shell script runs, the bootstrap reports each visible step, and the
managed installer reports Java/file-sync/NeoForge/updater phases. Success is
recorded as a completed installer session with a timestamp in
`client_installer_sessions`; failures include a redacted recent log excerpt in
`client_installer_events` as soon as the error is observed.

The stats area polls `/live-stats.json` every 30 seconds and updates the CPU
usage, load average, RAM, disk, client package metadata, and compact history
graphs directly in the browser without a page reload. Player-facing percentage
metrics are normalized to a 0-100% range; disk free space is shown as GB plus
free percent.

## Releases And Rollback

Pack releases live under `/var/minecraft_mods/releases/<release-id>`. A release
contains:

- server mod/datapack files,
- client package files and sync manifest,
- ZIP/MRPack/DMG artifacts when present,
- SQLite DB snapshot,
- checksums, metadata, and changelog,
- tested/active status in SQLite.

Useful commands:

```bash
systemctl start pummelchen-minecraft.service
systemctl stop pummelchen-minecraft.service
systemctl restart pummelchen-minecraft.service
python3 /var/minecraft_mods/scripts/release_manager.py list
python3 /var/minecraft_mods/scripts/release_manager.py validate <release-id>
python3 /var/minecraft_mods/scripts/release_manager.py rollback
python3 /var/minecraft_mods/scripts/release_manager.py rollback --release-id <release-id> --restore-db
python3 /var/minecraft_mods/scripts/release_manager.py prune --keep 2
```

The daily noon UTC updater creates and activates a release only when at least
one update was applied successfully. Clients then see the new release pointer on
their next launch or background sync.

Release pruning keeps the active release plus the requested number of inactive
rollback releases, removes older generated release directories and public
download links, and records a `prune` event in SQLite. This prevents repeated
client ZIP/MRPack builds from filling the VPS disk during heavy test cycles.

## Quality Gate And Deploy

Run the full local gate before pushing:

```bash
bash scripts/validate_project.sh
```

Deploy from the local checkout:

```bash
bash scripts/deploy_project.sh --host root@91.99.176.243 --create-release
```

The deploy script runs the same gate locally, syncs project-owned files,
installs systemd/Nginx/Prometheus/Grafana config, regenerates the status page,
smoke-tests HTTP and the metrics exporter, and checks SQLite integrity.

GitHub Actions runs `scripts/validate_project.sh` on pushes and pull requests.

After client-package changes, also run the real local macOS client smoke on a
machine with the Minecraft client installed:

```bash
python3 scripts/check_client_mod_dependencies.py "$HOME/Library/Application Support/minecraft/mods" --minecraft-version 26.1.2 --neoforge-version 26.1.2.71
python3 scripts/sanitize_resource_pack_metadata.py "$HOME/Library/Application Support/minecraft" --write
python3 scripts/macos_client_launch_smoke.py --timeout 600
```

The smoke launcher is intentionally not part of CI because it opens the local
Minecraft client and depends on installed launcher assets, native libraries, and
an Apple Silicon Java runtime.

## Observability

Prometheus scrapes:

- node exporter for host CPU, RAM, disk, disk IO, and network,
- blackbox exporter for HTTP/TCP health,
- `pummelchen-minecraft-metrics` on `127.0.0.1:7792` for Minecraft players,
  process RSS/CPU, JVM heap where `jcmd` can read it, chunk-generation proxy,
  TCP connections, crash report counters, update counters, and active release
  labels.

Grafana provisioning is stored in `monitoring/grafana/`. The website remains the
simple user-facing view; Grafana is the operator cockpit.

## Gameplay Load Lab

New mods and updates should pass the acceptance lab before they are installed in
the live pack. The lab uses the filesystem `mods/` directory as the source of
truth, parses NeoForge TOML metadata to include required dependencies, boots a
temporary server on a non-live port, and writes candidate results to
`mod_acceptance_runs` and `mod_acceptance_items`. Full active-pack acceptance is
stored as dated pyramid releases in `mod_acceptance_releases` and
`mod_acceptance_blocks`.

```bash
python3 scripts/mod_acceptance_lab.py init
python3 scripts/mod_acceptance_lab.py plan
python3 scripts/mod_acceptance_lab.py run-singles --limit 10
python3 scripts/mod_acceptance_lab.py run-bundles --limit 1
python3 scripts/mod_acceptance_lab.py run-pyramid
python3 scripts/mod_acceptance_lab.py run-files --include-active-deps /path/to/candidate.jar
python3 scripts/mod_acceptance_lab.py register-fixed --original-mod-id 123 --fixed-jar /path/to/fixed.jar --patch-notes "Short repair note"
```

The acceptance order is:

1. Candidate jar plus required dependency closure and 9 deterministic random
   known-working active mods in an isolated throwaway server.
2. Full-pack boot test after the candidate passes isolation.
3. Level-0 bundle tests in groups of 10 active mods.
4. Pyramid rollups: passing adjacent blocks are merged and retested until one
   passing block remains, recorded as `YYYY-MM-DD_Vn`.
5. Headless real-client join/walk smoke test for the active client release.
6. Gameplay/load lab scenarios for player-facing survival checks.

Failed mods stay out of the live server and should be investigated one at a
time in isolated lab servers. If a small repair is fully understood, register
the repaired jar as a linked `Codex_Fixed` duplicate with `register-fixed`; the
original remains marked failed while the fixed copy carries its own checksum,
patch notes, and promotion status.

## Headless Client Lab

The headless client lab follows the HeadlessMC/HMC-Specifics path from the
research note: it is a real Minecraft Java client under Xvfb or an existing
GPU-backed `DISPLAY`, not a protocol bot. Xvfb/Mesa is enough for boot, join,
movement, and obvious shader compile crashes; GPU-backed Xorg is still required
for driver-faithful shader validation.

One-time VPS setup:

```bash
apt install -y xvfb mesa-utils libgl1-mesa-dri libglx-mesa0 x11-utils
python3 scripts/headless_client_lab.py setup
python3 scripts/headless_client_lab.py sync
python3 scripts/headless_client_lab.py login-command
```

The login command opens the HeadlessMC console. Run `login`, complete the
Microsoft device-code login from another browser with a dedicated paid test
account, then run `account`. Do not put account passwords or tokens into shell
commands or git.

After the account is ready:

```bash
python3 scripts/headless_client_lab.py run --duration 600
```

Runs are stored in `headless_client_runs` with the active release id, renderer
summary, HeadlessMC log, Minecraft `latest.log`, crash-report count, fatal-log
count, and pass/fail notes. The lab always syncs from
`/var/minecraft_26.1.2/client-package`, so it tests the same client pack that
Mac users install.

The load lab supports dry-run validation plus real scenarios:

```bash
python3 scripts/gameplay_load_lab.py scenarios
python3 scripts/gameplay_load_lab.py run fresh_world_idle --remove-lab-world
python3 scripts/gameplay_load_lab.py run chunk_spiral --remove-lab-world
python3 scripts/gameplay_load_lab.py run manual_join_window --duration 900
```

Runs are stored in SQLite tables `load_lab_runs` and `load_lab_samples`. Real
scenarios use a temporary `level-name` and restore `server.properties` when the
test ends.

## Automation And Stability

All seven improvement areas from the 2026-06-04 implementation pass are now
represented in the project:

- Multi-version server support: `server_instances` and `mod_server_files` record
  which file is selected for each Minecraft/NeoForge server folder, so future
  servers can coexist beside `minecraft_26_1_2`.
- Rich mod metadata: `mod_metadata` stores group tags, client/server side,
  generated summaries, risk flags, dependency notes, and profiling priority.
- Idle performance profiling: `performance_runs` stores full-pack baseline
  runs, and `mod_performance_profiles` stores remove-one RAM/CPU deltas per mod.
- Profiling queue: `mod_risk_scores` and `profiling_queue` prioritize higher
  risk mods for repeated idle RAM/CPU profiling. Current queue size is 259.
- Monitoring: Prometheus, node exporter, and blackbox exporter are installed.
  Prometheus, node exporter, and blackbox exporter bind only to localhost on
  ports `9090`, `9100`, and `9115`; public HTTP remains Nginx on `7788`.
- Daily update/watchlist scanner: `/etc/cron.d/pummelchen-daily-update` runs at
  `12:00 UTC` daily. It scans up to 40 tracker rows per run, applies up to 5
  passing updates, creates an automatic backup snapshot, tests candidates one by
  one, and logs successful visible events to the site.
- Launcher/client packaging: the ZIP package, per-file sync manifest, and
  `pummelchen-server-26.1.2.mrpack` are rebuilt from the same `client-package`
  tree whenever a passing server or client update is applied.
- Automated backups and rollback: `backup_snapshots` stores pre-update DB and
  manifest snapshots. Failed server candidates are moved into
  `/var/minecraft_26.1.2/mods.failed/<test-label>` and previous files are moved
  back into place.
- Web reporting: the status site shows successful tested updates, grouped active
  mods, idle-impact fields where available, current VPS stats, and Mac client
  installation paths. The visible tested-update log is a rolling
  7-day window; older successful update events remain in SQLite for audit but
  drop off the public page automatically.
- Live stats: `/etc/systemd/system/pummelchen-live-stats.timer` refreshes the
  public `live-stats.json` feed every 30 seconds so the page can redraw CPU,
  load, RAM, disk, and client package metadata while it is open.
- Watchlist/compatibility management: skipped mods such as Create: Steam 'n'
  Rails remain in SQLite and are rechecked by the updater when compatible builds
  appear.

The current seeded profile data is intentionally conservative: one full-pack
baseline and one remove-one AutoFishing comparison. The AutoFishing single-run
estimate is `+482.8 MB` RAM and `-0.13%` CPU with `low-single-run` confidence,
so it is a profiling smoke test, not a tuning decision by itself. Repeat runs
and profiling high-risk groups first will make the ranking useful.

Common server-ops commands on the VPS:

```bash
cd /var/minecraft_mods
python3 scripts/server_ops.py --db data/minecraft_mods.sqlite --server-dir /var/minecraft_26.1.2 migrate
python3 scripts/server_ops.py --db data/minecraft_mods.sqlite --server-dir /var/minecraft_26.1.2 backfill-metadata
python3 scripts/server_ops.py --db data/minecraft_mods.sqlite --server-dir /var/minecraft_26.1.2 sync-instance
python3 scripts/server_ops.py --db data/minecraft_mods.sqlite --server-dir /var/minecraft_26.1.2 score-risks
python3 scripts/server_ops.py --db data/minecraft_mods.sqlite --server-dir /var/minecraft_26.1.2 profile-baseline --timeout 900 --idle-seconds 45
python3 scripts/server_ops.py --db data/minecraft_mods.sqlite --server-dir /var/minecraft_26.1.2 profile-mod autofishing --timeout 900 --idle-seconds 45
python3 scripts/server_ops.py --db data/minecraft_mods.sqlite export-performance-csv exports/mod_performance_profiles_2026-06-04.csv
```

## Common Commands

```bash
python3 scripts/moddb.py --db data/minecraft_mods.sqlite summary
python3 scripts/moddb.py --db data/minecraft_mods.sqlite export-clean-csv exports/minecraft_clean_sheet_2026-06-04.csv
python3 scripts/moddb.py --db data/minecraft_mods.sqlite export-google-sheet-csv exports/minecraft_sqlite_status_2026-06-04.csv
python3 scripts/moddb.py --db data/minecraft_mods.sqlite sql "SELECT name, active_status, server_status FROM mods WHERE active_status = 'failed'"
python3 scripts/import_url_batch.py /path/to/urls.txt --db data/minecraft_mods.sqlite --batch-name 20260604-create-steam-n-rails
python3 scripts/process_url_batch.py --db data/minecraft_mods.sqlite --batch-name 20260604-create-steam-n-rails --limit 5
python3 scripts/daily_update.py --db data/minecraft_mods.sqlite --server-dir /var/minecraft_26.1.2 scan-apply --dry-run --limit 20 --trigger manual-dry-run
python3 scripts/daily_update.py --db data/minecraft_mods.sqlite --server-dir /var/minecraft_26.1.2 scan-apply --trigger manual
python3 scripts/daily_update.py --db data/minecraft_mods.sqlite --server-dir /var/minecraft_26.1.2 rebuild-client
python3 scripts/update_next_batch.py --db data/minecraft_mods.sqlite
```

The database preserves original Google Sheet row numbers in `sheet_rows` and
keeps duplicate tracker rows in `mods`; the clean export collapses exact
duplicates by canonical URL/key.
