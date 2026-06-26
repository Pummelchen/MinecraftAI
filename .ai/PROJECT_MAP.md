<!--
AI onboarding file.
Mode: refresh
Indexed commit: 00e25e1a9584ca075e27b404305bda18157aa7f3
Last generated: 2026-06-25T22:08:15+02:00
Generator: generic high-end AI coding agent
Purpose: Help future AI sessions understand this repository quickly.
Audience: Any high-capability AI coding agent, regardless of vendor or model family.
Human edits are allowed. Future refreshes should preserve valid human edits.
-->
# Project Map

This map answers “where does this behavior live?” It lists the important source areas discovered in the current repository and the responsibility of each one.

## Top-level map

```text
MinecraftAI/
├── README.md
├── AI_INDEX.md
├── AGENTS.md
├── .ai/
├── Client App/
│   └── MCPummelchenModClient/
├── Server App/
│   ├── MCPummelchenModServer/
│   ├── MCPummelchenModShared/
│   ├── Database/duckdb/
│   ├── Docs/contracts/
│   ├── nginx/
│   └── systemd/
└── Live Backup/
```

| Path | Owns | Typical changes |
|---|---|---|
| `Client App/MCPummelchenModClient/` | Client package and tests. | GUI, sync, status, Java/NeoForge, control, self-update. |
| `Server App/MCPummelchenModServer/` | Server package and tests. | API, CLI, release/mod/version/world pipelines, DB helper, soak runner. |
| `Server App/MCPummelchenModShared/` | Shared package and native DuckDB bridge. | Cross-client/server contracts, validation, hashing, defaults, DB access. |
| `Server App/Database/duckdb/` | Canonical production schema. | New numbered migrations, reporting views, DB operator docs. |
| `Server App/Docs/contracts/` | Frozen/expected production behavior. | External behavior or operational contract updates. |
| `Server App/nginx/` | Public web/download/API edge. | TLS/proxy/cache/download aliases and website source. |
| `Server App/systemd/` | Process scheduling and hardening. | Server/update-scan service behavior and drop-ins. |
| `Live Backup/` | Production DB recovery/audit snapshots. | Normally none; only deliberate backup management. |

## Package dependency graph

```text
MCPummelchenModServer
  ├── MCPummelchenModServerCore
  │     └── MCPummelchenModShared
  ├── MCPummelchenModClientCore (headless soak / DMG validation dependency)
  └── executables: server, duckdb helper, headless soak, contracts

MCPummelchenModClient
  ├── MCPummelchenModClientCore
  │     └── MCPummelchenModShared
  ├── pummelchen-client-sync
  └── macOS GUI target

MCPummelchenModShared
  └── CDuckDB -> native libduckdb
```

## Server package map

Base: `Server App/MCPummelchenModServer/`

### Entrypoint executables

| Path | Responsibility | Public interface |
|---|---|---|
| `Sources/MCPummelchenModServer/main.swift` | Parse CLI options, dispatch commands, run local HTTP server, start optional Minecraft supervisor. | `MCPummelchenModServer ...` |
| `Sources/PummelchenDuckDB/main.swift` | Migration/health/Parquet operator tool. | `pummelchen-duckdb migrate|health|export-parquet|verify-parquet` |
| `Sources/PummelchenHeadlessSoak/main.swift` | Fresh-client DMG/live-server release acceptance runner. | `pummelchen-headless-soak ...` |
| `Sources/pummelchen-contracts/main.swift` | Contract validation utility. | `pummelchen-contracts` product |

### Server core modules

Base: `Sources/MCPummelchenModServerCore/`

| Module | Responsibility | Key interfaces / invariants |
|---|---|---|
| `MCPummelchenModServerCore.swift` | Request/response types, API route switch, site feeds, client write handlers, release/manifest access, report store. | API paths in `AI_INDEX.md`; payload limit; current release and manifest validation. |
| `ControlEventStore.swift` | Persist, query, validate, and acknowledge control events. | 16 KiB payload cap; priorities; no download references; client-targeted/global events. |
| `LiveStatsProvider.swift` | Build live system/server/site metrics and historical payloads. | DuckDB and runtime filesystem/process metrics; no-store API responses. |
| `ModAddPipeline.swift` | Resolve a requested mod and dependency graph, classify side, install, record source, smoke-test, build DMG/release. | CurseForge/Modrinth; max dependency graph; dry-run default; release handoff. |
| `ModBanPipeline.swift` | Mark/remove banned mods and update DB/file state. | Operator-controlled, high-impact mod policy path. |
| `ModUpdateScanner.swift` | Seed source inventory, discover links, check providers, persist scan results and failures. | Provider throttling, discovery cap, live/staging version awareness, Cloudflare classification. |
| `ModUpdateApplyPipeline.swift` | Apply completed-scan candidates into version packages and create releases. | Priority candidate handling, package readiness, dry-run, live activation/staging separation. |
| `ServerVersionBootstrapPipeline.swift` | Carry a working baseline into a new Minecraft version, scan, copy package sections, optionally apply/release. | Target/reference DB rows and dirs; protected statuses; target-specific candidates. |
| `ModVersionPatcher.swift` | Patch NeoForge mod metadata ranges inside JAR/ZIP files. | Uses `unzip`/`zip`; verifies patched archive content. |
| `SwiftReleasePipeline.swift` | Assemble immutable release, manifests, public files, checksums, DB records, activation, retention, cleanup. | Release immutability, live-only global aliases, DMG soak proof, post-create validation. |
| `ClientDMGBuilder.swift` | Build/sign/package macOS app and sync helper, bundle DuckDB, optionally test control and run soak. | macOS-only; optional private resource; checksum/signature/application-bundle validation. |
| `SwiftWorldResetPipeline.swift` | Plan/execute safe world reset, datapack installation, gamerules, pregeneration, backup, audit. | Dry-run and explicit confirmation; RCON/service control; destructive. |
| `MinecraftRCONClient.swift` | RCON protocol client used for commands, watchdog, and world operations. | Secret-bearing network control; localhost by default. |
| `MinecraftLiveServerSupervisor.swift` | Start Minecraft, install local RCON firewall rules, watchdog and restart process. | Environment-driven; root/service privilege boundary; direct iptables/ip6tables execution. |

### Server tests

Base: `Tests/MCPummelchenModServerTests/`

| Path | Coverage discovered |
|---|---|
| `MCPummelchenModServerCoreTests.swift` | Current release and manifest API, status metadata, live stats, DuckDB-backed feeds, failed mods, scanner/version seeding, environment-driven Minecraft supervision, and further server-core behavior. |
| `Fixtures/` | Copied into the test target for release/API/package fixtures. |

The server test target also imports `MCPummelchenModClientCore`, so changes to shared client behavior can affect server tests and headless acceptance tooling.

## Client package map

Base: `Client App/MCPummelchenModClient/`

### Entrypoints

| Path | Responsibility | Public interface |
|---|---|---|
| `Sources/MCPummelchenModClient/main.swift` | SwiftUI/AppKit app, status model, sync/force-update actions, single-instance guard, `--once`. | GUI and `MCPummelchenModClient --once` |
| `Sources/MCPummelchenModClientSync/main.swift` | Sync/watch command parsing and execution. | `pummelchen-client-sync sync|watch` |

### Client core modules

Base: `Sources/MCPummelchenModClientCore/`

| Module | Responsibility | Key interfaces / invariants |
|---|---|---|
| `ClientSyncEngine.swift` | Main managed-file synchronization workflow. | Minecraft-running guard; current-release/manifest fetch; verify/download/replace; first-install behavior; local/store/report/self-update. |
| `ClientHTTPClient.swift` | HTTP requests/downloads, retries, timeout, protocol tracking. | Used for downloads, API, control, installer/self-update calls. |
| `ClientControlChannel.swift` | Control info/events/acks and client write API requests. | Always sends client ID; Authorization only when optional token exists. |
| `ClientControlWatcher.swift` | Poll event batches, apply jitter, trigger sync, acknowledge events. | Sync-triggering event-type switch; retry delays; optional token. |
| `ClientStatusService.swift` | Read server/local/default/endpoint state and record status. | Public/download endpoint checks and local state inspection. |
| `ClientStatusStore.swift` | Local client DuckDB schema and status/inventory/cache persistence. | Local DB source for cached versions, sync results, endpoint/control state. |
| `ClientAppSelfUpdater.swift` | Download, verify, mount, validate, stage, replace, and relaunch app bundle. | Uses DMG metadata and installed release ID; executable update path. |
| `ClientSupportedVersionsResolver.swift` | Fetch supported versions from server, validate, cache, or use bundled fallback. | Requires unique versions and at least one live version. |
| `ClientCredentialProvider.swift` | Read optional client token from environment, Info.plist, or private resource. | No token CLI argument; trims empty values. |
| `ClientDefaultsInspector.swift` | Inspect desired managed client defaults and report health. | Shares expected defaults with writer/repair flow. |
| `ClientDefaultsRepairCoordinator.swift` | Coordinate automatic defaults repair/retry behavior. | Must remain idempotent and avoid unrelated preference resets. |
| `DefaultsRetryTracker.swift` | Track defaults repair attempts/backoff state. | Supports status service/model repair behavior. |
| `JavaRuntimeManager.swift` | Install/verify managed Temurin JDK and remove stale managed runtimes. | Pinned archive name/SHA, verified Java version, managed directory marker. |
| `NeoForgeClientInstaller.swift` | Resolve/download/verify/install supported NeoForge client profiles. | Server-driven installer metadata with pinned fallback; SHA verification. |

### Client tests

Base: `Tests/MCPummelchenModClientTests/`

| Test file | Primary area |
|---|---|
| `ClientSyncEngineTests.swift` | Managed-file sync, manifest behavior, first/repeat install, errors. |
| `ClientStatusTests.swift` | Status aggregation, endpoint/default/client state behavior. |
| `ClientAppSelfUpdaterTests.swift` | DMG/self-update decision and validation behavior. |
| `MinecraftClientDefaultsTests.swift` | Default writing/inspection/idempotency. |

## Shared package map

Base: `Server App/MCPummelchenModShared/`

### Shared Swift modules

Base: `Sources/MCPummelchenModShared/`

| Module | Responsibility | Used by |
|---|---|---|
| `APIModels.swift` | Client reports, inventory, diagnostics, defaults events, health, control event models. | Server API and client channel/sync. |
| `CurrentRelease.swift` | Current-release data model and strict URL/checksum validation. | Release pipeline, server API, client sync/self-update. |
| `ClientSyncManifest.swift` | TSV manifest entry/parser and section/path/SHA validation. | Release generation/validation and client sync. |
| `ReleaseIdentifier.swift` | Validated release identifier parsing/format. | Release create/current-release contracts. |
| `ContractValidation.swift` | Reusable validation primitives. | Shared and server/client APIs. |
| `SafePath.swift` | Constrain child paths to a root. | Client sync and filesystem-sensitive code. |
| `SHA256Hasher.swift` | Hash files for manifests/artifacts/download verification. | Release, DMG, Java/NeoForge, client sync. |
| `FileInventory.swift` | Build/verify managed-file inventory. | Client sync/reporting and release checks. |
| `DuckDBDatabase.swift` | Read/write wrapper over embedded DuckDB C API. | Server, client local store, helper tools. |
| `DuckDBReadOnly.swift` | Read-only database helper behavior. | Reporting/read paths. |
| `MinecraftClientDefaults.swift` | Desired defaults, supported server entries, and default writer. | Client sync, repair, tests, soak. |
| `PummelchenTimestamp.swift` | Timestamp normalization/formatting utilities. | Shared contracts/reporting. |

### Native bridge

| Path | Role | Caution |
|---|---|---|
| `Sources/CDuckDB/duckdb_shim.c` | Native bridge implementation. | Must match the included DuckDB API. |
| `Sources/CDuckDB/include/duckdb.h` | Vendored DuckDB header. | Do not edit casually; update with deliberate native-library compatibility work. |

### Shared tests

Base: `Tests/MCPummelchenModSharedTests/`

| Test file | Primary area |
|---|---|
| `CoreUtilityTests.swift` | Hashing, paths, timestamp, DB/shared utilities. |
| `CurrentReleaseTests.swift` | Release JSON and URL/checksum contract. |
| `ReleaseIdentifierTests.swift` | Release ID validation/parsing. |
| `ClientSyncManifestTests.swift` | TSV parsing, sections, paths, duplicates, SHA requirements. |
| `Fixtures/` | Shared contract fixtures. |

## DuckDB map

Base: `Server App/Database/duckdb/`

| Path | Role |
|---|---|
| `README.md` | Operator setup, migration, health, Parquet, schema explanation. |
| `schema.sql` | Canonical schema entrypoint for operators. |
| `migrations/001_foundation.sql` | Foundation schemas and reporting views. |
| `migrations/002_operational_schemas_and_indexes.sql` | Client/control/release/world schemas and indexes. |
| `migrations/003_minecraft_versions.sql` | Supported versions and version-aware mod/client state. |
| `migrations/004_client_inventory_by_version.sql` | Version-keyed client inventory. |
| `migrations/005_reporting_status_normalization.sql` | Accepted status normalization. |
| `migrations/006_release_history_source_of_truth.sql` | DuckDB release history source of truth. |
| `migrations/007_mod_source_links.sql` | Multiple normalized provider links. |
| `migrations/008_mod_source_discovery_results.sql` | Discovery audit rows. |
| `migrations/009_priority_mod_status.sql` | `Priority Mod` accepted/protected behavior. |
| `migrations/010_server_version_installer_metadata.sql` | Server-driven installer metadata. |
| `migrations/011_admin_locked_status.sql` | `Admin Locked` accepted/protected behavior. |

### Schema responsibilities

| Schema | Responsibility (verified/inferred from migrations and code) |
|---|---|
| `core` | Supported versions, mods/files/sources/links/scans/failures, schema migrations. |
| `client` | Client registration, status, sync/default/inventory state. |
| `control` | Control events and acknowledgements. |
| `release` | Pack releases, events, health and publication state. |
| `world` | World-reset jobs/history. |
| `audit` | Exports and operational audit records. |
| `reporting` | Views consumed by site/API/health tools. |
| `archive` | Retained/historical data structures. |

## Production contracts map

Base: `Server App/Docs/contracts/`

| Path | Role |
|---|---|
| `PRODUCTION_CONTRACTS.md` | Runtime/tool boundary, updater, release, DMG, scan, site/API, world and operational rules. |
| `CLIENT_IDENTITY.md` | Intended client identity/credential/storage/auth model. Currently conflicts with current route behavior. |
| `api/*.schema.json` | Machine-readable public API contract schemas where present. |
| `duckdb/001_initial.sql` | Historical/contract DB artifact; canonical current schema is under `Server App/Database/duckdb/`. |

## nginx and website map

Base: `Server App/nginx/`

| Path | Role |
|---|---|
| `nginx.conf` | Global nginx tuning. |
| `sites-available/pummelchen-swift.conf` | Public virtual hosts, TLS/HTTP2/HTTP3, API proxy, JSON aliases, downloads, cache/security headers. |
| `README.md` | Deployment/runtime layout and no-static-fallback rule. |
| `site/public/index.html` | Main status/install/operator page, live metrics, server versions, mod/update data. |
| `site/public/release.html` | Release detail view. |
| `site/public/failed-mods.html` | Failed/banned mod view. |
| `site/public/server-26.1.2.html` | Version-specific page. |
| `site/public/server-26.2.html` | Version-specific page. |
| `site/public/assets/` | Theme, scripts, hero/other static assets. |
| `site/public/downloads/` | Runtime-generated release output; intentionally untracked except ignore scaffolding. |

The main page loads Tabulator from a CDN and consumes the Swift/DuckDB API for operational tables and metrics.

## systemd map

Base: `Server App/systemd/`

| Path | Role |
|---|---|
| `MCPummelchenModServer.service` | Root-owned Swift API/server supervisor service. |
| `MCPummelchenModServer.service.d/minecraft-autostart.conf` | Enable Minecraft autostart and local RCON firewall behavior. |
| `MCPummelchenModServer.service.d/performance.conf` | Raise service/process resource limits. |
| `MCPummelchenModUpdateScan.service` | Stop API service, run exclusive all-supported scan under `flock`, restart API service. |
| `MCPummelchenModUpdateScan.timer` | Daily 12:00 UTC update scan. |
| `README.md` | Deployment and version-bootstrap notes. |

## Configuration and environment variable map

### Shared/native

- `PUMMELCHEN_DUCKDB_LIB_DIR`: native DuckDB link search path at build time.

### API/transport and client credentials

- `PUMMELCHEN_CLIENT_API_TOKEN`
- `PUMMELCHEN_TRANSPORT_TARGET`

### DMG/release/client build

- `PUMMELCHEN_SERVER_PACKAGE_DIR`
- `PUMMELCHEN_CLIENT_VERSION`
- `PUMMELCHEN_SERVER_URL`
- `PUMMELCHEN_SERVER_ADDRESS`
- `PUMMELCHEN_DUCKDB_DYLIB`
- `MACOSX_DEPLOYMENT_TARGET`
- `PUMMELCHEN_SKIP_NGINX_CONTROL_LIVE_TEST`
- `PUMMELCHEN_REQUIRE_HEADLESS_SOAK`
- `PUMMELCHEN_HEADLESS_SOAK_SECONDS`
- `PUMMELCHEN_HEADLESS_COMMAND`
- `PUMMELCHEN_HEADLESS_EXPECTED_INSTALLED_RELEASE_ID`
- `PUMMELCHEN_RELEASE_ID` (documented for build/soak integration)

### Minecraft supervisor/RCON

- `PUMMELCHEN_MINECRAFT_AUTOSTART`
- `PUMMELCHEN_MINECRAFT_DIR`
- `PUMMELCHEN_MINECRAFT_START_COMMAND`
- `PUMMELCHEN_MINECRAFT_HOST`
- `PUMMELCHEN_MINECRAFT_PORT`
- `PUMMELCHEN_MINECRAFT_LOG`
- `PUMMELCHEN_MINECRAFT_WATCHDOG`
- `PUMMELCHEN_MINECRAFT_WATCHDOG_STARTUP_GRACE_SECONDS`
- `PUMMELCHEN_MINECRAFT_WATCHDOG_INTERVAL_SECONDS`
- `PUMMELCHEN_MINECRAFT_WATCHDOG_FAILURE_THRESHOLD`
- `PUMMELCHEN_MINECRAFT_WATCHDOG_COMMAND_TIMEOUT_SECONDS`
- `PUMMELCHEN_MINECRAFT_WATCHDOG_COMMAND`
- `PUMMELCHEN_MINECRAFT_GRACEFUL_STOP_TIMEOUT_SECONDS`
- `PUMMELCHEN_MINECRAFT_RCON_HOST`
- `PUMMELCHEN_MINECRAFT_RCON_PORT`
- `PUMMELCHEN_MINECRAFT_RCON_PASSWORD`
- `PUMMELCHEN_MINECRAFT_RCON_FIREWALL`

Do not put values for sensitive variables into source or generated docs.

## Generated/output map

| Generated area | Generator/source |
|---|---|
| Release directories | `SwiftReleasePipeline` |
| Public `current-release*.json/.txt` and aliases | Release activation |
| `client-sync-manifest.tsv` and public client files | Release pipeline |
| Version-scoped client ZIP and MRPACK | Release pipeline/package builder |
| `MCPummelchenModClient.dmg` and checksum | `ClientDMGBuilder` |
| DMG headless soak report | `pummelchen-headless-soak` |
| Parquet reporting files | `pummelchen-duckdb export-parquet` |
| Local client `.pummelchen` state and DuckDB | `ClientSyncEngine` / `ClientStatusStore` |
| Client quarantine/temp directories | Client sync first-install and download workflow |
| Swift `.build/` | SwiftPM |

## Evidence

- Package manifests in all three packages
- Source paths listed throughout this file
- `Server App/Database/duckdb/README.md`
- `Server App/Docs/contracts/PRODUCTION_CONTRACTS.md`
- `Server App/nginx/README.md`
- `Server App/systemd/README.md`
- Swift Testing search results and package test targets
