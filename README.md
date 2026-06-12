# Pummelchen Minecraft Server — AI Agent Briefing

> **System identity**: Automated Minecraft mod pack management platform. Tracks ~250 mods in SQLite, tests candidates in isolated throwaway servers, distributes a macOS Apple Silicon client package, and serves a live status page. Runs on a single Debian VPS.

## System Metadata

| Key | Value |
|---|---|
| Repository | `https://github.com/Pummelchen/MinecraftServer` |
| Minecraft version | `26.1.2` |
| Mod loader | NeoForge `26.1.2.75` |
| Java runtime | OpenJDK `25.0.3` (system-wide, server + client) |
| Server OS | Debian 13, kernel `6.12.90` |
| VPS hostname | `deltasona` |
| VPS IP | `91.99.176.243` |
| SSH access | `root@91.99.176.243` (key-based, ed25519) |
| Production project dir | `/var/minecraft_mods` (control plane, scripts, DB) |
| Production server dir | `/var/minecraft_26.1.2` (runtime, mods, worlds) |
| Active release | `release_20260612_V6_modernarch-refresh` |
| Server-side jars | 253 |
| Client package | 257 mods, 12 resource packs, 2 shader packs |
| Central config file | `config.toml` (single source of truth for all paths/ports/limits) |

## Network Topology

| Port | Binding | Purpose |
|---|---|---|
| `25565` | public | Minecraft server |
| `7788` | public | Nginx static status/install site |
| `7791` | localhost | Client diagnostic log upload receiver (proxied by Nginx) |
| `7792` | localhost | Prometheus Minecraft metrics exporter |
| `9090` | localhost | Prometheus |
| `9100` | localhost | Node exporter (host CPU/RAM/disk) |
| `9115` | localhost | Blackbox exporter (HTTP/TCP probes) |
| `25575` | localhost (firewalled) | Minecraft RCON (optional, requires secret) |

## Architecture — Why This Shape

### SQLite as source of truth
All mod metadata, test results, release state, and update history live in one SQLite database (`data/minecraft_mods.sqlite`). This was chosen over a web service because the project is single-operator, single-VPS, and needs transactional consistency between mod state, test runs, and release artifacts.

### Isolated acceptance testing
Every new or updated mod is tested in a throwaway NeoForge server instance before touching the live server. This prevents a broken mod from crashing the production pack. The test uses the candidate + its dependency closure + 9 known-good mods to keep the candidate as the likely failure source.

### Immutable releases
Each release is a directory under `/var/minecraft_mods/releases/<release-id>` containing server files, client manifest, ZIP/MRPack/DMG artifacts, DB snapshot, checksums, and changelog. Once created, a release is never mutated. Rollback switches the active pointer to a previous release. This was chosen to make deploys atomic and reversible.

### Daily automated pipeline
Cron at 12:00 UTC runs the full release pipeline: scan for compatible updates → acceptance test → rebuild client package → create immutable release → deploy → cleanup. The pipeline uses staging copies and only mutates live files at deploy time. Rollback is automatic if a late step fails.

### Client distribution via sync manifest
Clients resolve `/downloads/current-release.json` to find the active release ID, then download individual files listed in `/downloads/releases/<release-id>/client-sync-manifest.tsv` with SHA256 checksums. This per-file sync avoids re-downloading ~1 GB on every update.

## Directory Map

```
.
├── scripts/              # All Python/Shell automation (~45 scripts)
├── systemd/              # Systemd unit files for all services
├── monitoring/           # Prometheus config, alert rules, Grafana provisioning
│   ├── alert-rules/      # Prometheus alert rule YAML
│   └── grafana/          # Grafana datasource/dashboard provisioning
├── client-package/       # macOS client installer payload and tools
│   ├── Install Mods.command   # Main installer script (run by DMG)
│   └── tools/            # Auto-updater, client doctor, server.dat editor
├── client-installer/     # Swift/AppKit progress window for DMG installer
├── server-config/        # JVM args, server.properties overrides, NeoForge config
│   └── config-overrides/ # Files copied into live server config/ on deploy
├── server-datapacks/     # Custom datapack zips deployed to server
├── server-datapacks-src/ # Datapack source and registry JSON
├── Pummelchen_Mods/     # Project-owned custom mod jars
├── nginx/                # Nginx site configuration
├── cron/                 # Cron job definitions
├── exports/              # CSV exports from SQLite (historical snapshots)
├── site/                 # Generated static status page
│   └── assets/           # Static assets (hero image)
├── data/                 # SQLite DB and import data (DB is gitignored)
├── database/duckdb/      # Phase 1 DuckDB schemas, migrations, parity docs
├── docs/                 # Design documents, production contracts, migration plans
├── swift/                # Swift/DuckDB migration workspace
│   └── PummelchenSwift/  # SwiftPM package for shared contracts and future apps
├── wiki/                 # GitHub Wiki clone (operator handbook)
├── config.toml           # Central configuration for all paths/ports/limits
├── PRODUCTION_AUDIT.md   # Hardening notes and 100-client readiness checklist
└── .github/workflows/    # CI: validate_project.sh on push/PR
```

## Key Scripts

| Script | Purpose |
|---|---|
| `moddb.py` | SQLite CLI: summary, export, normalize, raw SQL queries |
| `daily_update.py` | Single-mod update pipeline: scan → test → apply → rebuild client |
| `daily_release_pipeline.py` | Full daily pipeline: updates → acceptance → headless client → release → deploy |
| `release_manager.py` | Create, validate, activate, rollback, prune immutable releases |
| `mod_acceptance_lab.py` | Isolated mod testing: singles, bundles, pyramid rollups |
| `headless_client_lab.py` | Real Minecraft client testing under Xvfb (HeadlessMC/HMC-Specifics) |
| `gameplay_load_lab.py` | Gameplay scenarios: fresh world idle, chunk spiral, manual join |
| `import_url_batch.py` | Import CurseForge/Modrinth URL batches into SQLite |
| `process_url_batch.py` | Resolve batch imports: download, test, install |
| `generate_status_site.py` | Generate static status page from SQLite + VPS stats |
| `live_stats_feed.py` | Write `live-stats.json` every 10 seconds for browser graphs |
| `minecraft_metrics_exporter.py` | Prometheus exporter for Minecraft metrics on port 7792 |
| `client_log_receiver.py` | HTTP receiver for client diagnostic uploads on port 7791 |
| `server_ops.py` | Server metadata, mod metadata, idle performance profiling |
| `deploy_project.sh` | VPS deployment: validate → sync → install services → smoke test |
| `validate_project.sh` | Full quality gate: compile, schema, manifests, site, monitoring |
| `build_mac_client_dmg.sh` | Build macOS Apple Silicon installer DMG |
| `check_neoforge_version.py` | Check upstream NeoForge metadata before installer/release builds |
| `release_health_monitor.py` | Verify active release files, status JSON, client downloads, and server health |
| `sync_mod_install_state.py` | Reconcile SQLite install flags with live server/client |
| `check_client_manifest.py` | Validate client package manifest and checksums |
| `check_client_mod_dependencies.py` | Scan NeoForge metadata for missing client-side dependencies |
| `sanitize_resource_pack_metadata.py` | Repair pack.mcmeta schema drift that crashes the client |
| `sync_custom_datapacks.py` | Deploy custom datapacks to server and world |
| `sync_pummelchen_mods.py` | Register and deploy project-owned custom jars |
| `safe_reset_world.py` | Safely replace the active world with a new seed, install required datapacks/gamerules, and pregenerate spawn chunks |
| `build_tropical_worldgen_datapack.py` | Build the project datapack that biases new worlds toward bamboo jungles, jungle variants, and nearby sakura valleys |
| `build_rich_ores_datapack.py` | Build the project datapack that increases iron, gold, and diamond ore vein sizes |

## Systemd Services

| Service | Purpose |
|---|---|
| `pummelchen-minecraft.service` | Main Minecraft server (starts `start.sh`) |
| `pummelchen-live-stats.timer/service` | Refreshes `live-stats.json` every 10 seconds |
| `pummelchen-client-log-receiver.service` | Client diagnostic upload receiver (port 7791) |
| `pummelchen-minecraft-metrics.service` | Prometheus Minecraft exporter (port 7792) |
| `pummelchen-tested-updates.service/timer` | Background tested-updates worker |
| `pummelchen-acceptance-lab-cleanup.service/timer` | Lab working directory cleanup |
| `pummelchen-release-health.service/timer` | Five-minute release/download/server health watchdog |
| `pummelchen-headless-client.service` | Headless client lab runner |

## Mod Status Taxonomy

`mods.active_status` values — the top-level tracker enum:

| Status | Meaning |
|---|---|
| `ok` | Accepted and deployed in production |
| `failed` | Tested and rejected, crashed, or disabled |
| `codex_fixed_candidate` | AI-repaired duplicate exists, awaiting promotion decision |
| `awaiting_compatible_release` | Valid project, no compatible NeoForge 26.1.x file yet |
| `blocked_by_dependency` | Valid project, required dependency missing or incompatible |
| `reference_only` | Tracked for context, not deployable |
| `source_unresolved` | URL/project could not be resolved |
| `duplicate` | Collapsed into a canonical row |
| `pending` | Imported but not processed |
| `unknown` | Needs review |

Detailed reasons are stored in `mods.server_status`, `mods.client_package`, and `mod_notes`.

## Data Flow: Mod URL → Live Server

```
1. Import URL batch → SQLite queue tables
2. Resolve metadata (CurseForge/Modrinth API) → download candidate file
3. Isolated acceptance test (candidate + deps + 9 known-good mods)
4. If pass → full-pack boot test with all 243 active mods
5. If pass → copy to server mods/ and client-package/mods/
6. Rebuild client ZIP/MRPack/manifest with SHA256 checksums
7. Create immutable release directory
8. Deploy: switch active release pointer, regenerate status site
9. Clients sync on next launch via per-file manifest
```

Failed candidates are quarantined under `mods.failed/<test-label>/` and previous files are restored automatically.

## Secrets Management

| Secret | Location | Notes |
|---|---|---|
| Client log upload token | `/var/minecraft_mods/secrets/client-log-upload.token` | Shared between clients and VPS receiver |
| RCON password | `/var/minecraft_mods/secrets/rcon.password` | Optional, enables TPS/MSPT metrics |
| Upload token example | `client-package/tools/upload-token.txt.example` | Committed placeholder only |

**Never commit**: tokens, passwords, live SQLite databases, generated packages, logs, or `site/public/` output. All enforced by `.gitignore`.

## Quality Gate

```bash
# Local validation (run before pushing)
bash scripts/validate_project.sh

# Swift migration contract tests only
swift test --package-path swift/PummelchenSwift

# Build temporary DuckDB parity database on a host with duckdb installed
swift run --package-path swift/PummelchenSwift pummelchen-duckdb phase1-build \
  --duckdb /tmp/pummelchen_phase1.duckdb \
  --sqlite data/minecraft_mods.sqlite \
  --project-root .

# Deploy to VPS (runs gate + syncs + smoke tests)
bash scripts/deploy_project.sh --host root@91.99.176.243

# Deploy and create immutable release
bash scripts/deploy_project.sh --host root@91.99.176.243 --create-release
```

CI runs `validate_project.sh` on every push and PR via GitHub Actions.

## Common Commands

```bash
# Mod database
python3 scripts/moddb.py --db data/minecraft_mods.sqlite summary
python3 scripts/moddb.py --db data/minecraft_mods.sqlite sql "SELECT name, active_status FROM mods WHERE active_status = 'failed'"

# Update pipeline
python3 scripts/daily_update.py --db data/minecraft_mods.sqlite --server-dir /var/minecraft_26.1.2 scan-apply --dry-run --limit 20
python3 scripts/daily_update.py --db data/minecraft_mods.sqlite --server-dir /var/minecraft_26.1.2 scan-apply --trigger manual

# Release management
python3 scripts/release_manager.py list
python3 scripts/release_manager.py validate <release-id>
python3 scripts/release_manager.py rollback
python3 scripts/release_manager.py prune --keep 2

# Server control
systemctl start|stop|restart pummelchen-minecraft.service

# Safe world reset with spawn-radius pregeneration
python3 scripts/safe_reset_world.py --seed <new-seed> --radius-blocks 1000 --yes

# Rebuild tropical worldgen datapack after a Terralith update
python3 scripts/build_tropical_worldgen_datapack.py --source-overworld-json /tmp/pummelchen-terralith-overworld.json

# Rebuild rich ore vein datapack
python3 scripts/build_rich_ores_datapack.py

# Acceptance lab
python3 scripts/mod_acceptance_lab.py run-files --include-active-deps /path/to/candidate.jar
python3 scripts/mod_acceptance_lab.py run-pyramid --release-key YYYY-MM-DD_V1

# Headless client test
python3 scripts/headless_client_lab.py run --duration 600
```

## Wiki

The [GitHub Wiki](https://github.com/Pummelchen/MinecraftServer/wiki) contains detailed operator documentation covering architecture rationale, acceptance testing strategy, release discipline, client distribution, monitoring, security model, troubleshooting procedures, and production readiness assessment.
