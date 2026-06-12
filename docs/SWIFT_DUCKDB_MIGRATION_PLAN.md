# Pummelchen Swift and DuckDB Migration Plan

Status: implementation planning document
Audience: AI coding agents and human maintainers
Target platforms: Debian 13 x86-64 VPS server, macOS Apple Silicon clients
Current production system: Python, Bash, nginx, systemd, LaunchAgent, generated static website, DuckDB/SQLite-style project state
Target system: nginx edge, Swift server daemon with embedded DuckDB, Swift macOS client app/helper with embedded DuckDB
Last revised: 2026-06-12 after release/client/webpage hardening, custom worldgen datapacks, and live safe world reset

## 1. Executive Summary

The project should migrate toward two compiled Swift applications:

- `PummelchenServer`: a Debian 13 x86-64 Swift service running behind nginx, owning the authoritative project DuckDB.
- `PummelchenClient`: a macOS Swift app plus background helper optimized for Apple Silicon M-series chips, owning a local client DuckDB inventory/cache.

nginx remains the public edge for the website, large downloads, HTTPS, static release files, and HTTP/3/QUIC routing to the Swift server app.

DuckDB must be embedded locally on each side. Do not attempt to expose DuckDB directly over TCP or share one database file across clients. Server and client apps communicate through versioned HTTP/3 over QUIC. Bidirectional near-realtime control traffic must use QUIC bidirectional streams through an HTTP/3/WebTransport-style control channel, not WebSocket.

The migration should be staged. The current scripts are production safety rails and must not be removed until the Swift implementation proves equivalent through repeated live releases.

Recent production work changed the migration target. The Swift system must now preserve the full release updater experience, not merely replace the old script set. The current baseline includes immutable release folders, DMG generation, a manual website repair command, client defaults enforcement, BSL shader defaults, ModernArch resource-pack ordering, release health monitoring, project-owned custom datapack generation/registration, a safe world reset workflow with 1000-block radius pregeneration and old-world cleanup, and compact sortable/filterable Tested Updates and Failed Mods tables on the website.

The current server also has gameplay/worldgen policy encoded as release-managed datapacks, not informal operator notes:

- `pummelchen-welcome.zip` for safety gamerules, bonus chest, welcome behavior, and wildlife-friendly-fire protection.
- `pummelchen-tropical-worldgen.zip` for Terralith/Lithostitched overworld biome bias toward bamboo jungles, tropical jungle variants, and nearby sakura valleys.
- `pummelchen-rich-ores.zip` for larger vanilla overworld iron, gold, and diamond ore veins.

Any Swift migration that cannot build, validate, install, and audit these datapacks is not functionally equivalent to production.

Current scale snapshot from the generated status page:

```text
283 server-side active mods
29 client-side extras
312 client install entries
29 failed/inactive mods
```

### Recent Production Delta To Carry Forward

Since the original Swift/DuckDB discussion, the production system gained several behaviors that materially affect the migration:

1. Website data tables moved from large card grids to compact sortable/filterable tables. Swift must emit table-ready data for Tested Updates and Failed Mods, including stable timestamps and problem detail fields.
2. Client defaults now include shader/resource-pack activation, 8 GB memory, ModernArch compatibility cleanup, and duck/goose no-follow config. These are product requirements, not installer conveniences.
3. World generation policy is now project-owned:
   - tropical biome bias is generated from Terralith's Lithostitched overworld map;
   - rich ore veins override vanilla configured features for iron, gold, and diamonds;
   - safety/bonus-chest/wildlife behavior lives in the welcome datapack.
4. Safe world reset was proven live with:
   - seed `178127232016679900`;
   - spawn `608,67,-320`;
   - `12,256` chunks pregenerated for a 1000-block radius circle;
   - no leftover force-loaded chunks;
   - old reset backups deleted after success to recover disk space.
5. The Swift server must therefore model operations as auditable jobs with phases, progress, cleanup, and artifact validation, not as single request/response actions.

## 2. Goals

1. Replace scattered Bash/Python operational logic with maintainable Swift apps.
2. Give macOS players a simple GUI for sync status, manual sync, repair, and history.
3. Keep client state portable through a local DuckDB file.
4. Keep server release/mod/client state authoritative in a server-side DuckDB file.
5. Support near-realtime client notices through bidirectional HTTP/3 over QUIC after the basic HTTP API sync protocol is stable.
6. Preserve current production capabilities:
   - mod manifest generation
   - release activation
   - client package downloads
   - checksum validation
   - stale/unmanaged mod quarantine
   - client update reporting
   - terminal manual updater with clear progress and no-download summary
   - DMG installer generation and publication
   - client default config enforcement
   - shader/resource-pack default activation
   - server health checks
   - release health monitoring
   - world reset safety workflow
   - 1000-block radius spawn pregeneration after safe reset
   - old world backup deletion/retention policy after successful reset
   - custom datapack policy generation for safety, tropical worldgen, and rich ores
   - status website
   - tested updates and failed-mods feeds with sortable/filterable web tables
7. Keep nginx for public traffic, static downloads, caching, logs, TLS, and HTTP/3/QUIC routing.

## 3. Non-Goals

1. Do not rewrite everything in one step.
2. Do not make clients connect directly to DuckDB.
3. Do not expose the server app directly to the public internet.
4. Do not remove nginx.
5. Do not require an Apple Developer account for the first private-group version.
6. Do not embed the Swift compiler in the macOS client. The client is a compiled Swift app.
7. Do not block current production release operations while the Swift migration is in progress.

## 4. Target Architecture

```text
Internet
  |
  | HTTPS static downloads / HTTP/3 over QUIC control traffic
  v
nginx :80/:443
  |
  |-- /                         -> generated/static website
  |-- /downloads/...             -> static releases, DMG, client files
  |-- /downloads/client-files/... -> manual repair/helper downloads during migration
  |-- /api/v1/...                -> versioned API over HTTP/3 where supported
  |-- /h3/v1/control             -> bidirectional QUIC control stream endpoint
  |-- /client-logs/...           -> compatibility route during migration
  |
  v
127.0.0.1:8787
PummelchenServer.service
  |
  |-- DuckDB authoritative project DB
  |-- release/mod/client state
  |-- Minecraft systemd control
  |-- safe world reset orchestration
  |-- release health monitor state
  |-- tested updates feed generation
  |-- manifest/report generation
  |-- client status receiver
```

```text
macOS player machine
  |
PummelchenClient.app
  |
  |-- SwiftUI/AppKit GUI
  |-- LaunchAgent background helper
  |-- local DuckDB inventory/cache
  |-- HTTP/3 manifest/status sync where supported
  |-- static file downloads from nginx
  |-- built-in CLI repair/sync helper
  |-- bidirectional HTTP/3/QUIC control channel for near-realtime notices
  |
Minecraft folder
  |
  |-- mods/
  |-- resourcepacks/
  |-- shaderpacks/
  |-- .pummelchen/
```

## 4.1 Swift Project Location

The Swift migration code lives in:

```text
swift/PummelchenSwift
```

This is a SwiftPM workspace with a shared `PummelchenCore` library and command-line validation tools. It stays inside the existing repository so it can share fixtures, docs, contracts, and validation gates with the current production scripts while avoiding changes to live behavior during early phases.

The first package-level rule is:

```text
Swift code may read and validate existing contracts before it writes or replaces production state.
```

## 5. Why Keep nginx

nginx remains a hard requirement because it is better than the Swift app at:

- serving large ZIP/JAR downloads efficiently
- serving static website assets
- TLS termination and future Let's Encrypt automation
- routing API and bidirectional HTTP/3/QUIC control traffic
- rate limiting and request size limits
- access logs
- cache headers
- keeping downloads/site available while the Swift app restarts

The Swift server should bind only to localhost.

Recommended binding:

```text
PummelchenServer listens on 127.0.0.1:8787
nginx serves public static files and exposes HTTP/3 on the public edge. The Swift server owns the `/api/v1` API and `/h3/v1/control` bidirectional control channel. If nginx on Debian cannot proxy QUIC streams to the Swift process with the required semantics, terminate static HTTPS/HTTP/3 at nginx and bind the Swift QUIC listener separately on a locked-down public UDP port with the same certificate and firewall/rate-limit policy.
```

## 6. Technology Choices

### Server

- Language: Swift 6.3.2
- Platform: Debian 13 on Intel/AMD x86-64
- Build target: `x86_64-unknown-linux-gnu`
- Optimization target: production server builds must use Swift release optimization for throughput and predictable memory use on the VPS CPU family.
- Runtime: systemd service
- Database: DuckDB embedded file
- HTTP/3/QUIC framework: prefer a SwiftNIO-compatible QUIC stack if mature enough on Debian/macOS; otherwise use a narrow C-backed QUIC library wrapper. Vapor may still be used for ordinary HTTP API routing only if it does not block the QUIC transport requirement.
- Static files: served by nginx, not by Swift.
- Process control: Swift executes narrowly scoped commands for `systemctl`, backup tools, and Minecraft RCON/query where required.

### Client

- Language: Swift 6.3.2 or current Xcode Swift equivalent on macOS development machine
- Platform: macOS Apple Silicon only for the first private client line
- Build target: `arm64-apple-macosx`
- Optimization target: production client builds must be optimized for Apple M1, M2, M3, M4, and M5 class chips. Do not ship Intel slices unless a future Intel Mac support requirement is explicitly added.
- UI: SwiftUI with narrow AppKit interop where needed
- Database: DuckDB embedded file in `~/Library/Application Support/Pummelchen/client.duckdb`
- Background agent: LaunchAgent helper
- Distribution: unsigned or ad-hoc signed for private group initially
- Networking: URLSession for ordinary HTTPS/HTTP requests and a dedicated HTTP/3/QUIC client transport for the bidirectional control channel
- File sync: native Swift file operations, checksum validation, resumable downloads where practical
- CLI helper: same sync engine as GUI, with text progress suitable for Terminal support

### CPU Architecture And Build Requirements

The Swift migration has two different production CPU targets:

```text
PummelchenClient.app      arm64-apple-macosx, Apple M1-M5 optimized
PummelchenServer.service  x86_64-unknown-linux-gnu, Debian 13 VPS optimized
```

Client build rules:

- Build the DMG client app/helper as Apple Silicon `arm64` release binaries.
- Prefer modern macOS APIs and concurrency patterns that perform well on Apple M-series efficiency/performance core scheduling.
- Keep file hashing, download verification, DuckDB writes, and inventory scans off the main SwiftUI thread.
- Keep background sync power-aware: avoid tight polling, batch filesystem scans, and respect sleep/wake behavior.
- Treat Intel Mac support as out of scope unless a later requirement adds a universal build.

Server build rules:

- Build the Debian service as `x86_64-unknown-linux-gnu` release binaries on the VPS or a matching Linux builder.
- Tune for long-running service stability: bounded memory, explicit job concurrency limits, controlled DuckDB connection ownership, and no unbounded task creation under load.
- Keep Minecraft/systemd operations outside request handlers and inside the job queue.
- Validate the release binary on the actual VPS CPU before cutover.

Architecture acceptance:

- `file`/platform checks prove the client app/helper are `arm64` Mach-O binaries.
- `file`/platform checks prove the server service is an `x86-64` ELF binary.
- Release builds pass the same contract tests as debug builds.
- The client smoke test runs on at least two Apple Silicon Macs before production cutover.
- The server smoke test runs on the Debian 13 x86-64 VPS under systemd before production cutover.

### DuckDB

Use DuckDB as embedded state, not as a network database.

Server DB:

```text
/var/minecraft_mods/data/pummelchen.duckdb
```

Client DB:

```text
~/Library/Application Support/Pummelchen/client.duckdb
```

### DuckDB Features To Use Deliberately

Do not migrate SQLite into DuckDB as a flat 1:1 copy. Use DuckDB's stronger analytical and embedded features where they fit production needs.

#### SQLite Compatibility Extension

Use DuckDB's SQLite extension for the initial migration and parity phase:

- attach/read the existing SQLite database without immediately replacing it;
- copy tables into DuckDB with explicit casts and normalization;
- compare source and target row counts, hashes, and representative query outputs;
- keep the current SQLite-backed scripts as the production writer until parity is proven.

This supports the side-by-side migration strategy: current scripts remain authoritative while Swift/DuckDB runs in shadow mode.

#### Schemas

Use schemas to separate raw imports, normalized state, audits, and report contracts:

```sql
CREATE SCHEMA IF NOT EXISTS raw;
CREATE SCHEMA IF NOT EXISTS core;
CREATE SCHEMA IF NOT EXISTS audit;
CREATE SCHEMA IF NOT EXISTS reporting;
CREATE SCHEMA IF NOT EXISTS archive;
```

Recommended use:

- `raw`: imported SQLite rows, raw API responses, raw log/diagnostic payloads.
- `core`: normalized releases, mods, clients, files, datapacks, and world reset state.
- `audit`: append-only jobs, reset runs, release actions, cleanup actions, and operator events.
- `reporting`: stable views consumed by Swift APIs and static website generation.
- `archive`: exported/imported historical summary tables and Parquet-backed analysis.

#### JSON

Keep critical query/filter fields as typed columns, but retain full payloads as JSON for diagnostics and future replay.

Use JSON payload columns for:

- release health check details;
- failed mod problem details;
- client diagnostic bundles;
- custom datapack validation results;
- safe world reset phase/progress details;
- raw Modrinth/CurseForge metadata.

Swift code should not parse opaque strings when DuckDB can expose stable JSON fields through views.

#### Parquet Exports

Use Parquet as the durable history/export format for analytical and rollback-adjacent data:

```text
/var/minecraft_mods/exports/parquet/
  releases/
  client_sync_runs/
  failed_mod_reports/
  tested_updates/
  world_reset_runs/
  datapack_validation_runs/
```

Exports should be generated after release activation, after safe world reset, and during scheduled maintenance. Parquet exports are not the primary database backup; they are compact historical snapshots for audit and analysis.

#### Full-Text Search

Use the `fts` extension for operator search once basic DuckDB migration is stable.

Searchable content:

- mod names and canonical keys;
- failure reasons and problem details;
- changelog notes;
- test labels;
- crash headlines and sanitized stack traces;
- custom datapack notes.

Do not make FTS part of the first production cutover. It is a quality-of-life layer after core parity is stable.

#### Views As API Contracts

Expose website/API data through DuckDB views so Swift handlers do not duplicate reporting logic:

```sql
CREATE OR REPLACE VIEW reporting.v_tested_updates_table AS ...;
CREATE OR REPLACE VIEW reporting.v_failed_mods_table AS ...;
CREATE OR REPLACE VIEW reporting.v_release_health_latest AS ...;
CREATE OR REPLACE VIEW reporting.v_client_sync_status AS ...;
CREATE OR REPLACE VIEW reporting.v_custom_datapack_status AS ...;
CREATE OR REPLACE VIEW reporting.v_world_reset_history AS ...;
```

Views are the compatibility boundary for static site generation and API output. If a table layout changes, keep the view contract stable.

#### Constraints And Indexes

Use constraints for production invariants:

- SHA256 values are 64 hex characters;
- file sizes and chunk counts are non-negative;
- world reset radius is positive;
- ore configured feature size is between 1 and 64;
- job and release statuses are constrained to known values;
- manifest sections are one of `mods`, `resourcepacks`, `shaderpacks`, `config`, `server-datapacks`, or `tools`.

Use ART indexes sparingly for highly selective lookups:

- `release_id`;
- `client_id`;
- `job_id`;
- `mod_id`;
- `canonical_key`;
- `sha256`.

Do not add broad dashboard indexes by default. DuckDB is optimized for scans, aggregation, joins, and analytical reporting; unnecessary indexes slow writes and imports.

#### Concurrency

The Swift server process should be the only writer to the server DuckDB file. Background jobs must use a serialized write queue for schema migrations and destructive operations.

Allowed:

- multiple read connections inside the Swift server process;
- append-heavy job/event inserts through the server job runner;
- client-side DuckDB writes only to each client's local DB.

Not allowed:

- multiple daemons writing `/var/minecraft_mods/data/pummelchen.duckdb`;
- clients connecting directly to DuckDB;
- sharing a DuckDB file over network storage;
- writing schema migrations while release/reset jobs are active.

#### Health And Introspection

Add DB health checks using DuckDB metadata functions:

- loaded extensions;
- schema version;
- row counts for critical tables;
- current settings;
- memory and temporary file usage;
- last checkpoint/export time;
- latest migration status.

Expose this through `GET /api/v1/admin/db-health` after authentication exists.

#### DuckDB Reference Links

Implementation agents should verify exact syntax against current official DuckDB docs before coding:

- SQLite extension: https://duckdb.org/docs/current/core_extensions/sqlite.html
- JSON: https://duckdb.org/docs/current/data/json/overview.html
- Parquet: https://duckdb.org/docs/current/data/parquet/overview.html
- Full-text search: https://duckdb.org/docs/current/core_extensions/full_text_search.html
- Concurrency: https://duckdb.org/docs/current/connect/concurrency.html
- Transactions: https://duckdb.org/docs/current/sql/statements/transactions.html
- Constraints: https://duckdb.org/docs/current/sql/constraints.html
- Indexes: https://duckdb.org/docs/current/sql/indexes.html
- Metadata functions: https://duckdb.org/docs/current/sql/meta/duckdb_table_functions.html

## 6.1 Current Production Contracts To Preserve

The Swift migration must treat the following behaviors as compatibility contracts.

### Release and Packaging

- Release directories remain immutable once activated.
- `current-release.json`, `client-sync-manifest.tsv`, client ZIP, MRPACK, DMG, and SHA256 sidecars remain published under `/downloads`.
- Client sync manifests keep section/name/size/sha256/url semantics so old Bash clients and new Swift clients can coexist.
- DMG builds include the current updater/helper, default config files, resource packs, shader packs, and launch defaults.
- NeoForge preflight remains part of release/DMG build gating. The system should report whether the configured NeoForge version is current before publishing.
- Release health checks must run after release activation and DMG publication.

### Client Defaults

The Swift client must apply the same defaults that the current Bash updater applies:

- 8 GB standard Minecraft memory allocation for clients.
- Pummelchen multiplayer server entry.
- BSL shader active by default when shader support is installed.
- Complementary Reimagined available as an alternate shader.
- ModernArch resource pack stack enabled in order:
  1. base mod resources
  2. `ModernArch v2.8.2 [26.1] [128x]`
  3. `ModernArch FA Extension v2.2`
  4. `ModernArch Denser Grass Addon`
- Known-compatible resource packs must not be left in the incompatible-resource-pack list after sync.
- NeoForge/Forge load warning popups and noisy client checks stay suppressed where current defaults suppress them.
- Untitled Duck server/client config defaults set:
  ```toml
  duck_tamed_no_follow = true
  goose_tamed_no_follow = true
  ```

### Manual Repair and Terminal UX

- The website keeps a one-line Terminal repair command.
- During migration, that command may download Bash or Swift helpers, but it must keep the same user promise: repair updater/helper files, make them executable, and run a forced sync.
- Manual forced sync must print a clear terminal status.
- If no downloads are required, it must still print a friendly summary with server release, client release, file count, verified count, and "all synced, no downloads required".
- If downloads are required, it must show deterministic progress suitable for non-technical macOS users.

### Server Defaults and World Reset

- Server config overrides are first-class release inputs, not ad-hoc files.
- Project-owned datapacks are first-class release inputs. Swift must register, checksum, install, and validate them in both server-level and active-world datapack folders.
- Current required datapacks:
  - `pummelchen-welcome.zip`
  - `pummelchen-tropical-worldgen.zip`
  - `pummelchen-rich-ores.zip`
- Swift must preserve generator parity for:
  - Terralith/Lithostitched tropical biome policy: bamboo/jungle/sakura bias with schema validation.
  - Rich ores policy: iron/gold/diamond configured feature sizes, clamped to Minecraft's valid maximum of 64 where required.
- Safe world reset must:
  - require dry-run support
  - backup before destructive changes
  - move the old world out of the active path before booting the new world
  - write the requested seed
  - reinstall datapacks and server config overrides
  - preserve bonus chest behavior
  - apply gamerules such as keep inventory and block-damage controls
  - detect spawn after first boot
  - pregenerate a 1000-block radius around spawn
  - remove all temporary forceloads after pregeneration
  - optionally delete old world backups after a successful reset when the operator explicitly requests disk cleanup
  - record the operation and result
  - record the cleanup result separately from the reset result

### Website

- The website remains a static nginx-served page during migration.
- Server/VPS stats and charts remain visible.
- Manual client update and safe reset sections remain documented.
- Failed Mods remains a compact data table with:
  - first column timestamp
  - failure reason
  - detailed problem column
  - sortable/filterable headers
- Tested Updates remains a compact table with:
  - first column `Updated At`
  - timestamp format `YYYY-MM-DD HH:MM:SS`
  - sortable headers
  - free-text filtering
  - hyperlink support for mod/update names
- Every script or command shown on the website keeps a copy-to-clipboard icon button.

### Watch Agents and Health

- Existing systemd timers/services remain active until Swift replacements prove equivalent.
- Release health must continue to report a single pass/fail/warn summary.
- Client log receiver/client status ingestion must remain backward compatible with installed clients.
- Failed mod tracking and Tested Updates generation remain part of the live site.

## 7. Protocol Design

Use HTTP/3 over QUIC for server/client communication. Keep static release downloads on nginx-served HTTPS/HTTP/3. Do not move large ZIP/JAR/DMG payloads over the bidirectional control channel.

The implementation must distinguish three traffic classes:

1. Static downloads: nginx-served immutable files under `/downloads/...`.
2. Versioned API calls: request/response JSON endpoints under `/api/v1/...`, using HTTP/3 where the client and edge support it.
3. Bidirectional control: small near-realtime messages over `/h3/v1/control` using QUIC bidirectional streams through an HTTP/3/WebTransport-style channel.

HTTP/2 HTTPS polling remains an explicit compatibility fallback for early private builds and network environments that block UDP/QUIC. The fallback is not the target transport.

### API Versioning

All routes must be versioned:

```text
/api/v1/...
/h3/v1/control
```

Every response should include:

```json
{
  "api_version": "v1",
  "server_time": "2026-06-12T00:00:00Z",
  "request_id": "uuid"
}
```

### Core HTTP API Endpoints

```text
GET  /api/v1/status
GET  /api/v1/releases/current
GET  /api/v1/releases/{release_id}
GET  /api/v1/releases/{release_id}/manifest
GET  /api/v1/releases/{release_id}/health
GET  /api/v1/tested-updates
GET  /api/v1/site/status
POST /api/v1/clients/register
POST /api/v1/clients/{client_id}/heartbeat
POST /api/v1/clients/{client_id}/sync-runs
POST /api/v1/clients/{client_id}/inventory
POST /api/v1/clients/{client_id}/diagnostics
POST /api/v1/clients/{client_id}/installer-events
GET  /api/v1/messages
```

Downloads stay on nginx:

```text
/downloads/releases/{release_id}/client-sync-manifest.tsv
/downloads/releases/{release_id}/minecraft_26.1.2_client_macos_apple_silicon.zip
/downloads/client-files/...
```

### Bidirectional HTTP/3/QUIC Events

Use the HTTP/3/QUIC control channel for small control/status events only, not for file downloads.

```text
/h3/v1/control
```

Event examples:

```json
{"type":"release.available","release_id":"release_20260612_V3_updater-summary"}
{"type":"message.server","severity":"info","title":"Restart in 10 minutes","body":"Please finish your current activity."}
{"type":"client.sync.request","reason":"critical_mod_update"}
{"type":"server.health","minecraft_up":true,"players_online":4}
{"type":"release.health","release_id":"release_20260612_V16_duck-goose-no-follow-defaults-v2","status":"healthy"}
```

## 8. Authentication and Security

Private group does not mean no security. Use simple, robust controls.

### Client Identity

Each client gets:

- `client_id`: random UUID
- `client_secret`: random 256-bit token

Store on macOS:

```text
~/Library/Application Support/Pummelchen/client-id
Keychain or local config for token
```

For first private release, a file token is acceptable if permissions are locked down. Prefer Keychain when the Swift app is mature.

### Request Authentication

Use HTTP/3 over TLS with bearer token for client write/report APIs:

```http
Authorization: Bearer <client_secret>
X-Pummelchen-Client-ID: <client_id>
```

### Manifest Integrity

Each release manifest must include:

- release id
- Minecraft version
- NeoForge version
- file list
- SHA256 per file
- total file count
- generation timestamp

Future improvement: sign manifest with an Ed25519 server key and verify in the client.

### File Safety

Client must:

- download to temporary path first
- verify SHA256 before install
- never partially overwrite a live mod file
- quarantine unmanaged files instead of deleting them
- avoid updating while Minecraft is running unless operation is safe

## 9. Data Model

### Server DuckDB Tables

Initial authoritative tables:

```sql
CREATE TABLE releases (
  release_id VARCHAR PRIMARY KEY,
  created_at TIMESTAMP NOT NULL,
  activated_at TIMESTAMP,
  status VARCHAR NOT NULL,
  minecraft_version VARCHAR NOT NULL,
  neoforge_version VARCHAR NOT NULL,
  manifest_sha256 VARCHAR,
  client_zip_sha256 VARCHAR,
  notes VARCHAR
);

CREATE TABLE release_files (
  release_id VARCHAR NOT NULL,
  section VARCHAR NOT NULL,
  name VARCHAR NOT NULL,
  size_bytes BIGINT NOT NULL,
  sha256 VARCHAR NOT NULL,
  url_path VARCHAR NOT NULL,
  role VARCHAR,
  PRIMARY KEY (release_id, section, name)
);

CREATE TABLE mods (
  mod_id VARCHAR PRIMARY KEY,
  name VARCHAR NOT NULL,
  source_url VARCHAR,
  side VARCHAR NOT NULL,
  status VARCHAR NOT NULL,
  current_file VARCHAR,
  notes VARCHAR
);

CREATE TABLE clients (
  client_id VARCHAR PRIMARY KEY,
  registered_at TIMESTAMP NOT NULL,
  display_name VARCHAR,
  last_seen_at TIMESTAMP,
  current_release_id VARCHAR,
  os_version VARCHAR,
  app_version VARCHAR,
  status VARCHAR
);

CREATE TABLE client_sync_runs (
  run_id VARCHAR PRIMARY KEY,
  client_id VARCHAR NOT NULL,
  started_at TIMESTAMP NOT NULL,
  finished_at TIMESTAMP,
  from_release_id VARCHAR,
  target_release_id VARCHAR,
  result VARCHAR NOT NULL,
  files_verified INTEGER,
  files_downloaded INTEGER,
  files_quarantined INTEGER,
  error_message VARCHAR
);

CREATE TABLE client_inventory_snapshots (
  snapshot_id VARCHAR PRIMARY KEY,
  client_id VARCHAR NOT NULL,
  created_at TIMESTAMP NOT NULL,
  release_id VARCHAR,
  file_count INTEGER,
  payload_json VARCHAR NOT NULL
);

CREATE TABLE server_messages (
  message_id VARCHAR PRIMARY KEY,
  created_at TIMESTAMP NOT NULL,
  severity VARCHAR NOT NULL,
  title VARCHAR NOT NULL,
  body VARCHAR NOT NULL,
  expires_at TIMESTAMP
);

CREATE TABLE release_health_runs (
  run_id VARCHAR PRIMARY KEY,
  release_id VARCHAR,
  created_at TIMESTAMP NOT NULL,
  status VARCHAR NOT NULL,
  ok_count INTEGER NOT NULL,
  warn_count INTEGER NOT NULL,
  error_count INTEGER NOT NULL,
  summary VARCHAR NOT NULL,
  payload_json VARCHAR NOT NULL
);

CREATE TABLE tested_updates (
  update_id VARCHAR PRIMARY KEY,
  tested_at TIMESTAMP NOT NULL,
  title VARCHAR NOT NULL,
  event_type VARCHAR NOT NULL,
  source VARCHAR NOT NULL,
  source_url VARCHAR,
  file_name VARCHAR,
  file_version VARCHAR,
  test_label VARCHAR,
  notes VARCHAR
);

CREATE TABLE client_installer_events (
  event_id VARCHAR PRIMARY KEY,
  client_id VARCHAR,
  created_at TIMESTAMP NOT NULL,
  session_id VARCHAR,
  phase VARCHAR,
  status VARCHAR NOT NULL,
  message VARCHAR,
  payload_json VARCHAR
);

CREATE TABLE server_config_overrides (
  override_id VARCHAR PRIMARY KEY,
  path VARCHAR NOT NULL,
  sha256 VARCHAR NOT NULL,
  applied_at TIMESTAMP,
  payload_text VARCHAR NOT NULL
);

CREATE TABLE custom_datapacks (
  datapack_id VARCHAR PRIMARY KEY,
  name VARCHAR NOT NULL,
  file_name VARCHAR NOT NULL,
  sha256 VARCHAR NOT NULL,
  target_mc VARCHAR NOT NULL,
  policy_kind VARCHAR NOT NULL,
  source_path VARCHAR,
  generated_at TIMESTAMP,
  installed_server_at TIMESTAMP,
  installed_world_at TIMESTAMP,
  notes VARCHAR
);

CREATE TABLE datapack_validation_runs (
  run_id VARCHAR PRIMARY KEY,
  datapack_id VARCHAR NOT NULL,
  created_at TIMESTAMP NOT NULL,
  status VARCHAR NOT NULL,
  validator_name VARCHAR NOT NULL,
  checked_paths_json VARCHAR NOT NULL,
  result_json VARCHAR NOT NULL,
  error_message VARCHAR
);

CREATE TABLE world_reset_runs (
  run_id VARCHAR PRIMARY KEY,
  requested_at TIMESTAMP NOT NULL,
  started_at TIMESTAMP,
  finished_at TIMESTAMP,
  status VARCHAR NOT NULL,
  seed VARCHAR NOT NULL,
  radius_blocks INTEGER NOT NULL,
  backup_path VARCHAR,
  backup_deleted_at TIMESTAMP,
  backup_delete_bytes BIGINT,
  backup_delete_status VARCHAR,
  spawn_x INTEGER,
  spawn_y INTEGER,
  spawn_z INTEGER,
  chunks_requested INTEGER,
  chunks_completed INTEGER,
  forceloads_cleared BOOLEAN,
  error_message VARCHAR,
  payload_json VARCHAR
);

CREATE TABLE failed_mod_reports (
  report_id VARCHAR PRIMARY KEY,
  observed_at TIMESTAMP NOT NULL,
  mod_id VARCHAR,
  name VARCHAR NOT NULL,
  source_url VARCHAR,
  file_name VARCHAR,
  failure_reason VARCHAR NOT NULL,
  problem_details VARCHAR,
  status VARCHAR NOT NULL,
  test_label VARCHAR,
  log_path VARCHAR
);
```

### Client DuckDB Tables

```sql
CREATE TABLE client_state (
  key VARCHAR PRIMARY KEY,
  value VARCHAR NOT NULL,
  updated_at TIMESTAMP NOT NULL
);

CREATE TABLE installed_files (
  section VARCHAR NOT NULL,
  name VARCHAR NOT NULL,
  path VARCHAR NOT NULL,
  size_bytes BIGINT,
  sha256 VARCHAR,
  release_id VARCHAR,
  verified_at TIMESTAMP,
  status VARCHAR NOT NULL,
  PRIMARY KEY (section, name)
);

CREATE TABLE sync_runs (
  run_id VARCHAR PRIMARY KEY,
  started_at TIMESTAMP NOT NULL,
  finished_at TIMESTAMP,
  from_release_id VARCHAR,
  target_release_id VARCHAR,
  result VARCHAR NOT NULL,
  files_verified INTEGER,
  files_downloaded INTEGER,
  files_quarantined INTEGER,
  error_message VARCHAR
);

CREATE TABLE sync_events (
  event_id VARCHAR PRIMARY KEY,
  run_id VARCHAR NOT NULL,
  timestamp TIMESTAMP NOT NULL,
  level VARCHAR NOT NULL,
  message VARCHAR NOT NULL,
  file_name VARCHAR
);

CREATE TABLE release_history (
  release_id VARCHAR PRIMARY KEY,
  first_seen_at TIMESTAMP NOT NULL,
  installed_at TIMESTAMP,
  status VARCHAR NOT NULL,
  manifest_sha256 VARCHAR
);

CREATE TABLE settings (
  key VARCHAR PRIMARY KEY,
  value VARCHAR NOT NULL,
  updated_at TIMESTAMP NOT NULL
);

CREATE TABLE client_defaults (
  key VARCHAR PRIMARY KEY,
  desired_value VARCHAR NOT NULL,
  applied_value VARCHAR,
  applied_at TIMESTAMP,
  status VARCHAR NOT NULL,
  source VARCHAR NOT NULL
);

CREATE TABLE installer_events (
  event_id VARCHAR PRIMARY KEY,
  timestamp TIMESTAMP NOT NULL,
  phase VARCHAR,
  status VARCHAR NOT NULL,
  message VARCHAR,
  payload_json VARCHAR
);
```

## 10. macOS Client GUI

The client should be a practical status and repair app.

### Navigation

Use a compact sidebar or segmented control:

```text
Status | Sync | History | Mods | Settings
```

### Status View

Primary question: can the player play safely?

Show:

- state badge: `Synced`, `Update Available`, `Syncing`, `Repair Needed`, `Server Offline`, `Minecraft Running`
- server release id
- client release id
- verified file count
- last check
- background helper state
- Minecraft folder path
- active shader
- active resource-pack stack
- client memory allocation
- default config health

Actions:

- Sync Now
- Repair Client
- Open Minecraft Folder
- Copy Diagnostics
- Reapply Client Defaults

Success copy:

```text
All synced. No downloads required.
Server release: release_...
Client release: release_...
271 files verified.
```

### Sync View

Live progress:

- current phase
- current file
- progress bar
- verified/downloaded/skipped/quarantined/failed counts
- event stream

### History View

Show local sync runs from DuckDB:

```text
Date        Result    Server Release        Files Changed    Duration
Today       OK        20260612_V3           0                14s
Yesterday   OK        20260612_V2           1                31s
Jun 11      Failed    20260611_V3           0                Network timeout
```

Click row for details:

- manifest URL
- before/after release
- downloaded files
- quarantined files
- error log
- checksum failures

### Mods View

Show installed mods and expected server manifest status.

Filters:

- All
- Server-required
- Client-only
- Outdated
- Problem

### Defaults View

Show enforced defaults and their current state:

```text
Memory: 8 GB
Shader: BSL_v10.1.3.zip active
Resource packs: ModernArch base, FA Extension, Denser Grass
Server entry: present
Duck/goose no-follow: true
Warnings suppressed: true
```

Each row should show:

- desired value
- detected value
- status: `OK`, `Needs Repair`, `Unknown`
- last applied timestamp

The `Reapply Client Defaults` action runs the same default writer used after sync.

### Settings View

Fields:

- Server URL
- Minecraft folder
- Auto-sync interval
- background sync enabled
- notifications enabled
- diagnostics level

Advanced actions:

- Reset Local Sync State
- Reinstall Current Release
- Quarantine Unmanaged Mods
- Reapply Client Defaults

## 11. Server App Responsibilities

`PummelchenServer` should eventually own:

1. HTTP API and bidirectional HTTP/3/QUIC control server.
2. Authoritative release state in DuckDB.
3. Current release pointer.
4. Client status ingestion.
5. Server-side mod metadata tracking.
6. Release creation orchestration.
7. Safe world reset workflow.
8. Minecraft service health and systemd control.
9. Status website data generation, or direct API data for a static/SSR page.
10. Compatibility endpoints while old clients still exist.
11. Release health monitoring and health history.
12. Tested Updates feed generation.
13. Server config override inventory and application.
14. DMG/client package publication metadata.
15. Website repair command payload/version management.
16. Custom datapack generation, checksum registration, validation, and installation.
17. Failed Mods feed generation with timestamp/reason/details fields.
18. World-reset backup retention and explicit disk cleanup audit.

It should not:

- serve huge files itself unless nginx is unavailable
- expose DuckDB directly
- run as root unless unavoidable
- accept unauthenticated client write calls

## 12. Migration Phases

### Phase 0: Baseline and Contracts

No behavior replacement yet.

Tasks:

1. Freeze current behavior in documentation:
   - updater flows
   - manual repair one-liner
   - client no-download summary
   - DMG contents
   - client default config writer
   - release creation
   - manifest format
   - server health checks
   - release health checks
   - tested updates table/feed shape
   - world reset behavior
2. Define JSON API schemas.
3. Define DuckDB schemas and migrations.
4. Define client identity/token model.
5. Add conformance tests that compare Swift-produced manifests with current manifests.

Acceptance:

- No production behavior changed.
- API/schema docs exist.
- Swift contract package builds and tests through `scripts/validate_project.sh` when Swift is installed.
- Current scripts still pass `scripts/validate_project.sh`.

### Phase 1: DuckDB Foundation And SQLite Parity

Build the DuckDB foundation before replacing application behavior.

Implementation location:

```text
database/duckdb
swift/PummelchenSwift/Sources/PummelchenDuckDB
```

The first Phase 1 runner invokes the installed DuckDB CLI from Swift. That is intentional for the parity phase: it proves schemas, imports, row-count parity, reporting views, current-release/tested-updates parity, and Parquet exports on macOS/Debian without introducing embedded-linker risk. Direct embedded DuckDB integration should be added after the parity database contracts are stable.

Tasks:

1. Create `database/duckdb/schema.sql` with schemas:
   - `raw`
   - `core`
   - `audit`
   - `reporting`
   - `archive`
2. Create migrations table and migration runner:
   ```sql
   CREATE TABLE IF NOT EXISTS core.schema_migrations (
     version INTEGER PRIMARY KEY,
     name VARCHAR NOT NULL,
     applied_at TIMESTAMP NOT NULL,
     checksum VARCHAR NOT NULL
   );
   ```
3. Use DuckDB's SQLite extension to import current SQLite into `raw`.
4. Build normalized `core` tables from `raw` with explicit type conversion.
5. Add critical constraints and selective indexes only where justified.
6. Create reporting views:
   - `reporting.v_tested_updates_table`
   - `reporting.v_failed_mods_table`
   - `reporting.v_release_health_latest`
   - `reporting.v_client_sync_status`
   - `reporting.v_custom_datapack_status`
   - `reporting.v_world_reset_history`
7. Add Parquet export jobs for release/client/mod/reset/datapack history.
8. Add DuckDB health/introspection queries for extensions, settings, table counts, memory, temp files, and schema version.
9. Add a read-only Swift or CLI proof that opens the DuckDB file, runs the reporting views, and exits cleanly on Debian and macOS.
10. Keep current SQLite/Python scripts as production writers during this entire phase.

Acceptance:

- DuckDB can be rebuilt from current SQLite and project files without production downtime.
- Row counts and representative query outputs match current SQLite/status-site outputs.
- Reporting views emit Tested Updates and Failed Mods table rows with required timestamp/detail fields.
- Parquet exports are created and can be read back by DuckDB.
- DB health query reports schema version, extension state, table counts, and no critical errors.
- No production writer has switched from SQLite/Python to DuckDB/Swift yet.

### Phase 2: Swift Shared Core Library

Create shared Swift package:

```text
Packages/PummelchenCore
```

Responsibilities:

- release id parsing
- manifest model
- SHA256 hashing
- file inventory model
- DuckDB access wrapper
- JSON API models
- logging primitives
- filesystem safety helpers
- Minecraft options/config default writer
- resource-pack and shader option model
- timestamp formatting for website/API output

Acceptance:

- Unit tests pass on macOS and Debian.
- Can parse current `client-sync-manifest.tsv`.
- Can hash and verify current client files.
- Can apply client defaults into fixture Minecraft config folders without duplicate keys.
- Can render Tested Updates timestamps as `YYYY-MM-DD HH:MM:SS`.
- Can open the DuckDB foundation database read-only and query reporting views.

Implementation status:

- Implemented in `swift/PummelchenSwift/Sources/PummelchenCore`.
- The package now includes release-id parsing, API envelope/client-status/release-history/reporting models, SHA256 file hashing, managed file inventory, safe path validation, timestamp display formatting, Minecraft client default writing, and a read-only DuckDB reporting-view wrapper.
- The `pummelchen-contracts duckdb-reporting-smoke <duckdb-file>` command exercises the shared core read-only DuckDB wrapper against `reporting.v_tested_updates_table`, `reporting.v_failed_mods_table`, and `reporting.v_release_health_latest`.
- Phase 2 remains non-invasive: no production writer is switched to Swift, and no live client/server behavior is replaced.

### Phase 3: Server Read-Only API

Create `PummelchenServer` service with read-only endpoints:

- `/api/v1/status`
- `/api/v1/releases/current`
- `/api/v1/releases/{release_id}/manifest`

`/api/v1` is served over HTTP/3 where supported. nginx remains responsible for static files and may route API traffic if its HTTP/3/QUIC behavior satisfies the bidirectional requirements; otherwise the Swift service owns the QUIC listener for API/control traffic.

Acceptance:

- API returns current release identical to static `current-release.json`.
- HTTP/3 request/response path works from macOS client to Debian server.
- HTTP/2 HTTPS fallback remains available for read-only API requests during early private builds.
- systemd service restarts cleanly.
- No write operations yet.

Implementation status:

- Implemented the read-only API behavior in `swift/PummelchenSwift/Sources/PummelchenServerCore`.
- Added `pummelchen-server smoke --project-root <repo>` for release-pointer and manifest validation.
- Added `pummelchen-server serve --project-root <repo> [--host 127.0.0.1] [--port 8787]` as the local service entrypoint.
- Added `systemd/pummelchen-server.service` as the read-only service unit template. It is not enabled by default during Phase 3.
- Endpoints implemented:
  - `GET /api/v1/status`
  - `GET /api/v1/releases/current`
  - `GET /api/v1/releases/{release_id}/manifest`
- This phase remains read-only. HTTP/3/QUIC edge transport is still a deployment/networking gate; the Swift API emits transport-target metadata and keeps the compatibility HTTP path for smoke testing.

### Phase 4: Client GUI Read-Only Status

Create macOS app:

- status screen
- server URL setting
- local DuckDB initialization
- current release fetch
- local installed release read
- display synced/outdated/offline state
- display current default-config health

Acceptance:

- App runs unsigned/ad-hoc signed.
- Shows correct server release.
- Shows local release.
- Writes local status into DuckDB.
- Does not mutate Minecraft folder yet.
- Clearly reports whether shader/resource-pack/memory/server-entry defaults are OK.

Implementation status:

- Implemented `PummelchenClientCore` for read-only client status checks, local installed-release discovery, default-health inspection, and local DuckDB status persistence.
- Implemented `PummelchenClient`, a macOS SwiftUI/AppKit status app with a server URL setting, refresh action, synced/outdated/offline/repair-needed state, server and local release display, and default-health table.
- Added `PummelchenClient --once` as the non-interactive Phase 4 smoke path. It fetches the live `current-release.json`, reads `~/Library/Application Support/minecraft/.pummelchen/installed-release.txt`, inspects defaults without writing Minecraft files, and records status in `~/Library/Application Support/Pummelchen/client.duckdb`.
- The Phase 4 local DuckDB path uses the installed DuckDB executable from common macOS/Linux paths, with a clear repair-needed error if DuckDB is missing. Direct embedded DuckDB linking remains a later migration hardening step.
- Verified on macOS against the live server: `state=synced`, server and client release both `release_20260612_V16_duck-goose-no-follow-defaults-v2`, default health OK, and `client_state`, `client_defaults`, and `sync_runs` rows written.

### Phase 5: Swift Client Sync Engine

Implement native sync in macOS client:

- fetch manifest
- compare installed files
- download missing/changed files
- verify SHA256
- install atomically
- quarantine unmanaged files
- apply client defaults after sync
- update local DuckDB
- report sync run to server

Keep existing Bash updater available as fallback.

Acceptance:

- Swift sync produces same filesystem result as current Bash updater.
- Forced sync with no downloads shows "all synced".
- Failed checksum leaves original file untouched.
- Minecraft-running state is handled explicitly.
- Local DuckDB history is accurate.
- BSL shader, ModernArch stack, 8 GB memory, server entry, suppressed warnings, and duck/goose no-follow defaults are applied idempotently.
- Re-running sync does not duplicate config keys.

Implementation status:

- Implemented `ClientSyncEngine` in `PummelchenClientCore` and the `pummelchen-client-sync` CLI.
- Native sync now fetches `current-release.json`, fetches and validates `client-sync-manifest.tsv`, removes stale managed files from the previous manifest, quarantines unmanaged files, downloads missing/changed files to a temp area, verifies SHA256 before atomic install, chmods synced tools, writes the installed-release marker, stores the current manifest, applies client defaults, and records local DuckDB sync history.
- `--force` now means a forced full verification pass. Files with matching size/SHA256 are not re-downloaded, so a forced already-current sync reports `all synced, no downloads required`.
- Minecraft-running detection is implemented before mutation. A live macOS smoke run while Minecraft was active refused to sync with an explicit close-Minecraft message.
- Local DuckDB records `sync_runs`, `sync_events`, `release_history`, `client_state`, `installed_files`, and `client_defaults`.
- Added a temp HTTP release fixture test that verifies first-run downloads, forced no-download rerun, unmanaged quarantine, stale managed cleanup, defaults health, and local history recording without touching the real Minecraft folder.
- Existing Bash updater remains available and unchanged as fallback.

### Phase 6: Server Write APIs and Client Reports

Implement:

- client register
- heartbeat
- sync run report
- inventory upload
- diagnostics upload
- installer/defaults event upload

Acceptance:

- Server DuckDB shows client status.
- Status page can show aggregate client health.
- Bad tokens are rejected.
- Request payloads are size-limited.
- Server can distinguish `synced`, `needs defaults repair`, `failed checksum`, and `stale release`.

Implementation status:

- Implemented Phase 6 write endpoints in `PummelchenServerAPI`:
  - `POST /api/v1/clients/register`
  - `POST /api/v1/clients/heartbeat`
  - `POST /api/v1/clients/sync-runs`
  - `POST /api/v1/clients/inventory`
  - `POST /api/v1/clients/diagnostics`
  - `POST /api/v1/clients/defaults-events`
  - `GET /api/v1/clients/health`
- Write endpoints require `Authorization: Bearer <token>` and matching `X-Pummelchen-Client-ID`; missing/bad tokens and client-id mismatches are rejected.
- Write payloads are bounded by `maxWritePayloadBytes` before JSON decoding.
- Server-side Phase 6 persistence writes to DuckDB client tables for reports, latest status, inventory, diagnostics, defaults reports, and defaults events.
- Aggregate health reports counts for synced clients, defaults repair, failed checksums, stale release, and error/blocked clients.
- The Swift client sync engine can post JSON sync reports to `/api/v1/clients/sync-runs` when `PUMMELCHEN_CLIENT_API_TOKEN` or `--client-api-token` is configured; otherwise it keeps using the legacy `/client-logs/update-status` fallback during migration.
- Phase 6 is still a migration layer, not the production cutover. nginx/static releases and the existing Python/Bash production writers remain authoritative until later phases.

### Phase 7: Release Pipeline in Swift

Move release logic into `PummelchenServer` or a companion Swift CLI:

- build manifest
- validate dependencies
- create release directory
- activate current release
- build/publish client ZIP
- build/publish DMG metadata and checksums
- write/publish current release pointer
- publish manual repair/helper artifacts
- trigger service restart if required
- generate status page data
- generate tested updates feed
- run release health monitor

During transition, Swift should call existing scripts only through narrow wrappers. Remove wrappers only after equivalent Swift logic exists and tests pass.

Acceptance:

- Swift-created release matches current release format.
- Client can sync from Swift-created release.
- Rollback remains possible.
- DMG contains the correct helper/defaults files.
- Release health result is persisted and visible.
- Tested Updates website table data is generated from Swift-owned state or an equivalent compatibility feed.

Implementation status:

- Implemented `SwiftReleasePipeline` in `PummelchenServerCore` and exposed it through `pummelchen-server release-create` / `release-validate`.
- Swift release creation now writes the legacy-compatible immutable release layout: `CHANGELOG.md`, `metadata.json`, `server-files`, `client-package`, `manifests/server-files.tsv`, `manifests/client-package.tsv`, `artifacts`, `public/client-files`, `public/client-sync-manifest.tsv`, and `public/current-release.json`.
- Swift activation publishes `/downloads/releases/<release_id>`, writes `current-release.json` and `current-release.txt`, and records release events in DuckDB.
- Client ZIP and MRPack artifacts are required and checksummed. The Swift pipeline can build the client ZIP via a narrow `zip` wrapper if the artifact is missing; DMG and DMG checksum metadata are copied/published when present.
- Rollback remains possible through immutable release directories plus `previous_release_id` tracking in DuckDB. The existing production rollback command remains the operational rollback path during migration.
- Release health is persisted in `release.release_health_results`; an optional `--health-command` runs the current health monitor as a transition hook.
- Service restart is an optional `--restart-command` transition hook. When not configured, the release event records `restart=skipped` instead of touching production services.
- A Tested Updates compatibility feed is emitted at `public/data/tested-updates.json`; later Phase 7 hardening can replace this with a full Swift-owned website feed generated from DuckDB reporting tables.
- End-to-end fixture coverage creates a Swift release, validates it, serves it through the local HTTP fixture, syncs a Swift client from it, and verifies release health/restart state in DuckDB.

### Phase 8: Bidirectional HTTP/3/QUIC Realtime Events

Add `/h3/v1/control`.

Events:

- release available
- server message
- server restart notice
- client sync requested
- health update

Acceptance:

- Client reconnects safely.
- Missed messages are fetched via HTTP API fallback.
- No downloads happen over the QUIC control channel.
- UDP/QUIC blocked-network behavior is handled gracefully through polling fallback.

### Phase 9: Safe World Reset in Swift

Port safe reset workflow:

- backup world
- move existing world out of the active path after backup
- write seed
- ensure datapacks
- validate required custom datapacks before server boot:
  - welcome/safety datapack
  - tropical Terralith/Lithostitched biome policy datapack
  - rich iron/gold/diamond ore policy datapack
- ensure server config overrides
- ensure gamerules
- start/restart server
- detect spawn
- pregenerate configured radius; current production default is 1000 blocks around spawn
- remove all forceloads after each pregeneration batch and verify none remain at the end
- optionally delete old world backup data after successful pregeneration when requested
- record operation in DuckDB

Acceptance:

- Dry-run mode matches current script plan.
- Backup is created before destructive changes.
- Gamerules/datapacks are verified after reset.
- Pregeneration completion is recorded.
- Existing world is gone from the active path after successful reset.
- Backup deletion is recorded when disk cleanup is requested.
- No force-loaded chunks remain after pregeneration.
- New world uses the requested seed.

### Phase 10: Decommission Scripts

Remove or archive old scripts only after:

- two or more production releases were created by Swift path
- multiple clients synced through Swift client
- rollback tested
- safe world reset tested on staging
- status page and health monitoring still work

Keep emergency fallback scripts in `legacy/` until the new system has lived through several updates.

## 13. Testing Strategy

### Server Tests

- x86-64 release build test on Debian 13
- server binary architecture check: `x86-64` ELF
- DuckDB migration tests
- DuckDB SQLite-extension import tests
- DuckDB schema migration/checksum tests
- DuckDB reporting view contract tests
- DuckDB Parquet export/readback tests
- DuckDB FTS smoke tests for mod/failure search after FTS is enabled
- DuckDB health/introspection tests
- API contract tests
- manifest generation comparison tests
- release activation dry-run tests
- release health monitor tests
- tested updates feed/table contract tests
- DMG publication metadata tests
- server config override application tests
- custom datapack metadata/checksum tests
- custom datapack generator parity tests:
  - tropical worldgen output keeps Lithostitched schema and required biome bias thresholds
  - rich ores output keeps valid ore configured-feature schema and max size clamp
- nginx proxy smoke tests
- systemd restart tests
- world reset dry-run tests
- world reset new-seed and old-world deletion tests
- pregeneration plan/result tests
- forceload cleanup tests
- old-world backup cleanup tests
- backup/rollback tests

### Client Tests

- Apple Silicon release build test on macOS
- client app/helper architecture check: `arm64` Mach-O
- local DB migration tests
- manifest parse tests
- hash verification tests
- no-download sync tests
- changed-file sync tests
- failed checksum tests
- interrupted download tests
- unmanaged mod quarantine tests
- Minecraft-running detection tests
- client defaults idempotency tests
- shader/resource-pack activation tests
- incompatible resource-pack cleanup tests
- manual repair CLI output tests
- no-download summary output tests
- GUI state tests

### End-to-End Tests

- server creates release
- client sees release
- client syncs
- client reports status
- server records inventory
- website shows client health
- website shows Tested Updates table with sortable/filterable data
- website shows Failed Mods table with timestamp, reason, and problem detail columns
- manual repair command still works
- rollback release
- client downgrades or holds based on policy

## 14. Deployment Strategy

### Server

Systemd unit:

```text
/etc/systemd/system/pummelchen-server.service
```

Binary:

```text
/opt/pummelchen/bin/PummelchenServer
```

DB:

```text
/var/minecraft_mods/data/pummelchen.duckdb
```

Config:

```text
/etc/pummelchen/server.toml
```

Logs:

```text
journalctl -u pummelchen-server.service
```

### Client

Install:

```text
/Applications/PummelchenClient.app
```

or private-group local install:

```text
~/Applications/PummelchenClient.app
```

Data:

```text
~/Library/Application Support/Pummelchen/
```

LaunchAgent:

```text
~/Library/LaunchAgents/com.pummelchen.client.helper.plist
```

## 15. Operational Safeguards

1. Never update mods while Minecraft is actively using files unless the update is known safe.
2. Never delete unmanaged files immediately; quarantine first.
3. Never activate release without manifest validation.
4. Never write partial downloads to final paths.
5. Never expose localhost server app port publicly.
6. Never accept unauthenticated client write requests.
7. Always keep one known-good release available for rollback.
8. Always include a manual repair path on the website.
9. Always maintain compatibility with the existing updater during migration.
10. Always apply client defaults idempotently; duplicate config keys are release blockers.
11. Always validate DMG contents before publishing.
12. Always run release health after release activation and package publication.
13. Always keep old Bash/Python repair path available until the Swift CLI has survived multiple real client repairs.
14. Keep the current SQLite/Python path as production writer until DuckDB parity checks pass repeatedly.
15. Make the Swift server the only writer to server DuckDB; all background jobs write through its job queue.
16. Treat `reporting.*` views as API contracts and protect them with contract tests.
17. Pin required DuckDB extensions and verify extension availability during startup health checks.
18. Export Parquet history after destructive operations and release activations, but do not treat Parquet as the primary backup.

## 16. AI Coding Agent Instructions

When implementing this plan:

1. Read existing project behavior before replacing it.
2. Prefer narrow vertical slices over broad rewrites.
3. Preserve current release and updater compatibility.
4. Add tests for every behavior moved from scripts to Swift.
5. Do not remove existing scripts until the acceptance criteria for the replacement phase pass.
6. Keep nginx in front of the Swift server.
7. Keep DuckDB embedded locally; do not build network access to DuckDB itself.
8. Use explicit schema migrations.
9. Treat the macOS client as a user-facing app; every sync failure needs a clear UI state and a repair option.
10. Treat the server app as production infrastructure; every destructive operation needs dry-run, backup, and rollback.
11. Before replacing a script, write a fixture test that proves the Swift result matches the current script result.
12. Preserve the current website user contract: manual commands have copy buttons, Tested Updates is a table, and status/release information is visible without logging in.

## 17. Server Perspective Production Review

The server-side Swift/DuckDB system is production-ready only if it can run the Pummelchen operation as a reliable control plane, not merely as an API wrapper around existing files.

### Server Must Own

1. **Authoritative state**
   - DuckDB stores releases, release files, mod state, failed mods, tested updates, custom datapacks, client reports, health runs, jobs, and audit logs.
   - Current SQLite import remains available only for migration/parity until cutover.
   - Reporting views are the contract for website/API outputs.

2. **Release pipeline**
   - Create immutable release directories.
   - Generate manifests, checksums, MRPack/ZIP/DMG metadata, and current-release pointer.
   - Run NeoForge preflight before publication.
   - Run release health after activation.
   - Roll back atomically to a previous known-good release.

3. **Client distribution**
   - Publish static release files for nginx to serve.
   - Keep old manifest semantics until all clients are migrated.
   - Expose versioned API endpoints for current release, manifest metadata, client status ingestion, and update history.
   - Send QUIC control-channel notices only for small control/status events. Downloads remain static HTTPS/HTTP/3 files via nginx.

4. **Custom datapack policy**
   - Build or validate `pummelchen-welcome.zip`, `pummelchen-tropical-worldgen.zip`, and `pummelchen-rich-ores.zip`.
   - Store checksums and validation results in DuckDB.
   - Install required datapacks in both server-level and active-world datapack folders.
   - Treat datapack failure as a release/reset blocker.

5. **Safe world reset**
   - Run only through a job queue.
   - Require dry-run, explicit confirmation, backup/move of active world, seed write, datapack/config reinstall, gamerule verification, spawn detection, 1000-block radius pregeneration, forceload cleanup, and optional backup deletion.
   - Persist progress and final result in DuckDB.
   - Never delete old world backup data until the new world has booted, pregenerated, and passed health checks.

6. **Observability and operations**
   - Expose health endpoints for Swift service, DuckDB, nginx proxy, active release, Minecraft server ping, disk space, datapack status, and client-report ingestion.
   - Persist job logs and audit events.
   - Export Parquet history after release activation and destructive operations.
   - Provide an admin-safe view of failed jobs and recovery steps.

### Server Must Not Do

- Do not serve large downloads directly unless nginx is unavailable and an emergency mode is explicitly enabled.
- Do not expose DuckDB over TCP or to clients.
- Do not allow multiple processes to write the server DuckDB file.
- Do not perform release activation, world reset, backup deletion, or Minecraft restart directly inside an HTTP request handler.
- Do not run as unrestricted root if narrow `sudo`/systemd permissions can do the job.
- Do not use the QUIC control channel as a second write/control plane; authoritative writes still go through authenticated API/job endpoints.

### Required Server Runtime Shape

```text
nginx public edge
  -> static site/download files
  -> HTTP/3 for public static downloads where supported
  -> /api/v1 route to PummelchenServer where HTTP/3 routing/proxying is viable

PummelchenServer QUIC listener
  -> /api/v1 request/response API over HTTP/3 where supported
  -> /h3/v1/control bidirectional QUIC control streams
  -> HTTP/2 HTTPS fallback for early private builds and blocked UDP networks

PummelchenServer.service
  -> single process owning server DuckDB writes
  -> internal job queue
  -> restricted systemd/RCON/Minecraft control helpers
  -> static artifact writer under release/download roots
```

### Server Go-Live Gates

- Server service is built as an optimized `x86_64-unknown-linux-gnu` release binary and verified on the Debian 13 VPS.
- DuckDB foundation rebuilds from current SQLite/project files and passes parity checks.
- Current scripts and Swift shadow outputs match for release manifests, Tested Updates, Failed Mods, release health, custom datapacks, and world reset dry-run plans.
- At least two full releases are created, activated, validated, and rolled back successfully in staging.
- At least one staging safe world reset completes with seed write, datapack validation, 1000-block pregeneration, no leftover forceloads, and optional backup cleanup.
- Release health and DB health are visible and green after each staging operation.
- nginx serves all large files while Swift only serves API and QUIC control traffic.
- A server reboot restores nginx, Swift service, Minecraft service, health timers, and current release state without manual repair.
- Production cutover has a rollback command that restores the old script-controlled path.

### Server Schema Additions

```sql
CREATE TABLE jobs (
  job_id VARCHAR PRIMARY KEY,
  kind VARCHAR NOT NULL,
  status VARCHAR NOT NULL,
  created_at TIMESTAMP NOT NULL,
  started_at TIMESTAMP,
  finished_at TIMESTAMP,
  requested_by VARCHAR,
  input_json VARCHAR NOT NULL,
  result_json VARCHAR,
  error_message VARCHAR
);

CREATE TABLE audit_log (
  event_id VARCHAR PRIMARY KEY,
  created_at TIMESTAMP NOT NULL,
  actor VARCHAR NOT NULL,
  action VARCHAR NOT NULL,
  target VARCHAR,
  payload_json VARCHAR
);
```

Add endpoints:

```text
POST /api/v1/jobs
GET  /api/v1/jobs/{job_id}
GET  /api/v1/jobs
```

Long-running operations must run through this job system.

## 18. Client Perspective Production Review

The client-side Swift/DuckDB system is production-ready only if a non-technical player can install it, stay synced, understand status, and recover from common failures without Terminal scripting.

### Client Must Own

1. **Installation and identity**
   - DMG installs `PummelchenClient.app`.
   - App creates/loads client identity and stores secrets in Keychain when mature; a locked-down file token is acceptable only for early private builds.
   - App initializes local DuckDB and records installer/sync history.

2. **Background sync**
   - LaunchAgent helper checks for updates in the background.
   - Helper uses the same sync engine as the GUI and CLI.
   - Helper does not mutate files while Minecraft is running unless the operation is explicitly safe.
   - Helper recovers from sleep/offline/interrupted downloads.

3. **Manual sync and repair**
   - GUI has a clear Sync Now action.
   - App bundle includes CLI helper for Terminal repair:
     ```text
     PummelchenClient.app/Contents/MacOS/pummelchen-client-cli
     ```
   - Website manual repair command remains available until the Swift path survives real client recoveries.
   - No-download sync still prints/shows useful status: server release, client release, verified files, and all-synced message.

4. **Minecraft folder management**
   - Syncs mods, resource packs, shader packs, tools, config defaults, and server entry.
   - Downloads to temp files, verifies SHA256, then atomically installs.
   - Quarantines unmanaged files instead of deleting them.
   - Applies client defaults idempotently:
     - 8 GB memory
     - Pummelchen server entry
     - BSL active shader
     - Complementary Reimagined available
     - ModernArch stack active and ordered correctly
     - compatible resource packs removed from incompatible list
     - duck/goose no-follow config

5. **Player-facing GUI**
   - Shows current server release and installed release.
   - Shows synced/outdated/downloading/error/offline states.
   - Shows last sync, next background sync, file counts, downloaded bytes, and failed files.
   - Shows active shader/resource-pack/memory defaults health.
   - Shows release history and recent update notes.
   - Provides Copy Diagnostics and Upload Diagnostics actions.

6. **Near-realtime notices**
   - Uses bidirectional HTTP/3 over QUIC for update notices, restart warnings, server messages, and sync requests.
   - Falls back to HTTP API polling if UDP/QUIC fails.
   - Never downloads files over the QUIC control channel.

### Client Must Not Do

- Do not require players to run Bash/Python scripts for normal operation.
- Do not hide errors behind silent background failure.
- Do not overwrite live mod/resource files before checksum validation.
- Do not duplicate config keys or reset player-owned settings unnecessarily.
- Do not force updates while Minecraft is running without a clear user-facing warning.
- Do not require an Apple Developer account for the first private-group build.

### Required Client Bundle

```text
PummelchenClient.app
  Contents/MacOS/PummelchenClient
  Contents/MacOS/PummelchenClientHelper
  Contents/MacOS/pummelchen-client-cli
  Contents/Resources/default-config.json
```

### Minimum First Useful Client Version

1. Status screen
2. Sync Now
3. History screen
4. Settings screen
5. Copy Diagnostics
6. CLI helper with:
   ```text
   pummelchen-client-cli status
   pummelchen-client-cli sync --force
   pummelchen-client-cli repair
   pummelchen-client-cli diagnostics
   ```

### Client Go-Live Gates

- Client app/helper are built as optimized `arm64-apple-macosx` release binaries for Apple M1-M5 class Macs.
- Fresh install from DMG works on at least two macOS Apple Silicon machines.
- Background LaunchAgent starts after login and survives reboot.
- Manual Sync Now and CLI `sync --force` produce the same filesystem result.
- No-download path clearly reports all-synced status.
- Interrupted download resumes or restarts safely without corrupting files.
- Minecraft-running detection blocks unsafe mutation and explains the issue.
- Client defaults are idempotent across at least five repeated syncs.
- BSL/ModernArch/8 GB/server-entry defaults are visible in GUI and verified on disk.
- Client can recover from missing helper, missing local DB, stale manifest, bad checksum, and offline server.
- Client reports status to server DuckDB and appears in server-side health/client views.
- At least three real player machines run one week with background sync before legacy updater removal.

## 19. Final Revised Implementation Order

After server and client review, the recommended order is:

1. Define contracts: schemas, manifest model, API JSON, client identity.
2. Build DuckDB foundation: SQLite import, normalized schemas, reporting views, Parquet exports, health checks.
3. Build `PummelchenCore` Swift package against the DuckDB foundation.
4. Build server read-only API behind nginx.
5. Build macOS read-only client GUI.
6. Build Swift config/defaults engine with fixture parity against the current updater.
7. Build client DuckDB history and inventory.
8. Build Swift CLI helper with `status`, `sync --force`, `repair`, and `diagnostics`, while keeping Bash fallback.
9. Build Swift client sync engine and wire it into both GUI and CLI.
10. Add client report APIs and server-side client dashboard data.
11. Add server job queue and audit log.
12. Port custom datapack registry/build/validation into Swift or a Swift-owned compatibility wrapper.
13. Port release health, Tested Updates, and Failed Mods feed generation.
14. Port release pipeline into Swift job system, including DMG metadata/publication.
15. Add bidirectional HTTP/3/QUIC control events.
16. Port safe world reset into Swift job system, including backup retention and cleanup.
17. Decommission legacy scripts only after repeated live success.

## 20. Sign-Off Criteria

Do not declare the migration complete until:

- all clients can sync through the Swift client
- client app/helper binaries are optimized Apple Silicon `arm64` builds
- server service binary is an optimized Debian `x86-64` build
- the server can create and activate releases through Swift
- DuckDB foundation can rebuild from current SQLite/project files and pass parity checks
- reporting views are the source for Tested Updates, Failed Mods, release health, client sync status, datapack status, and world reset history
- Parquet history exports run and can be read back
- DuckDB health endpoint reports schema version, extensions, row counts, and no critical errors
- nginx serves downloads and proxies APIs correctly
- current website/manual repair path still exists
- Tested Updates table remains sortable/filterable and timestamped
- Failed Mods table remains sortable/filterable and includes timestamp, reason, and problem detail
- DMG publication and manifest publication are verified
- client defaults are applied idempotently without duplicate config keys
- shader/resource-pack/memory defaults are visible in the client GUI
- safe world reset is implemented with dry-run and backup
- safe world reset deletes the old world, applies the requested seed, and pregenerates 1000 blocks around spawn
- safe world reset verifies no force-loaded chunks remain
- safe world reset can delete old world backup data after success when explicitly requested
- required custom datapacks are generated, checksum-registered, installed, and validated by the Swift-controlled path
- DuckDB migrations are tested and backed up
- rollback from bad release is tested
- at least two production releases complete without using legacy scripts
- player-facing GUI clearly reports synced/update/error states
- server-side health monitoring reports clean after release activation
- the website manual repair command can recover at least one real macOS client using the Swift CLI/helper path

## 21. Production Cutover Matrix

Use this matrix before switching production ownership from the legacy script path to Swift.

| Area | Legacy remains owner until | Swift can become owner when |
|---|---|---|
| DuckDB state | SQLite import parity is incomplete | DuckDB rebuilds from SQLite/project files, views match current site/API outputs, and DB health is green |
| Client sync | Swift client has not survived real installs | DMG install, GUI sync, CLI repair, background LaunchAgent, and diagnostics pass on real macOS clients |
| Release creation | Swift release output differs from legacy | Swift creates immutable release artifacts matching legacy format and release health passes |
| Website data | Swift table feeds are not contract-tested | Tested Updates and Failed Mods views generate sortable/filterable table data with required timestamps/details |
| Custom datapacks | Swift cannot validate policy datapacks | Swift builds or validates welcome, tropical worldgen, and rich ores datapacks with matching checksums/contracts |
| Safe world reset | Swift reset has not completed staging | Swift completes staging reset with backup, seed, datapacks, gamerules, 1000-block pregeneration, no forceloads, and cleanup audit |
| QUIC notices | HTTP polling is not enough yet | HTTP/3/QUIC reconnect/fallback works and never carries file downloads |
| Rollback | No tested fallback exists | Old release/script path can be restored and Minecraft returns healthy |

Final go-live rule:

```text
Swift may replace a legacy responsibility only after it runs that responsibility in shadow or staging,
produces matching artifacts/results, records the operation in DuckDB, and has a tested rollback path.
```
