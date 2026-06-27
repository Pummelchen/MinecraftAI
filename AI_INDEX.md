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
# AI Index: MinecraftAI

This is the primary entrypoint for a new AI coding session. Read this file first, then `AGENTS.md`, then the task-specific files under `.ai/`. Re-open current source before editing: this index is a map, not a substitute for code.

## Repository snapshot

| Field | Value | Confidence |
|---|---|---|
| Repository | `Pummelchen/MinecraftAI` | verified |
| Indexed commit | `00e25e1a9584ca075e27b404305bda18157aa7f3` | verified |
| Previous indexed commit | `743356f85b0d4343cb8b1f71a92731eaf479bf47` | verified |
| Operation mode | `refresh` | verified |
| Primary purpose | Operate a large NeoForge Minecraft server/client mod pack: discover and validate mods, build immutable releases, publish downloads, synchronize macOS clients, monitor the live server, and retain operational state in DuckDB. | verified |
| Primary languages | Swift, C, SQL, HTML/CSS/JavaScript, nginx configuration, systemd unit files, Markdown | verified |
| Build/package system | Swift Package Manager | verified |
| Server platform | Debian 13, Intel x86-64 | verified from README |
| Client platform | macOS 26, Apple Silicon | verified from README and package manifests |
| Production database | DuckDB | verified |
| Public edge | nginx with HTTPS, HTTP/2, and HTTP/3 | verified |
| Process manager | systemd | verified |
| Test framework | Swift Testing (`@Suite`, `@Test`, `#expect`) | verified |
| CI | No GitHub Actions workflow was found in the inspected repository | unknown/absent in inspected tree |

### Status labels

- `verified`: directly supported by current source, package/configuration files, tests, or current docs.
- `inferred`: a reasonable conclusion from several verified files; confirm before changing behavior.
- `conflicting`: current sources disagree.
- `unknown`: not recoverable from the repository state that was inspected.
- `needs_human_review`: technically sensitive or operationally ambiguous enough that a maintainer should decide.

## What the system does

MinecraftAI is not a conventional web application with a single server and UI. It is an operations platform composed of:

1. A **Swift server command-line application and local HTTP API** that owns release creation, mod discovery and updates, version bootstrap, client-control events, public site data, world reset, RCON, and live Minecraft supervision.
2. A **macOS SwiftUI client** and bundled `pummelchen-client-sync` helper that install/repair a managed Minecraft client, verify release files, manage Java and NeoForge, apply defaults, watch control events, and stage self-updates.
3. A **shared Swift package** containing release/manifest contracts, API models, hashing, safe-path validation, file inventory, Minecraft defaults, and the DuckDB C wrapper.
4. A **DuckDB database** that stores release, mod, scan, supported-version, client, control, world, audit, and reporting state.
5. An **nginx public edge** that serves the website and large static release artifacts and proxies `/api/` to the local Swift server.
6. **systemd units and drop-ins** that run the Swift server, supervise the Minecraft process tree, and schedule the daily all-supported mod scan.

## High-level architecture

```text
macOS SwiftUI app / pummelchen-client-sync
       |
       | HTTPS release metadata, manifests, downloads, control events,
       | client status/inventory/diagnostics/default reports
       v
nginx public edge
       |-- static website and /downloads/ artifacts
       |-- /api/* and operational JSON aliases
       v
MCPummelchenModServer on 127.0.0.1:8787
       |-- HTTP API and client/control stores
       |-- release/mod/version/world/operator pipelines
       |-- optional Minecraft process supervision and RCON
       v
DuckDB + immutable release directories + Minecraft runtime
```

See `.ai/ARCHITECTURE.md` for detailed request, release, scan, client-sync, DMG, deployment, and world-reset flows.

## Top-level directory map

| Path | Responsibility | Important notes |
|---|---|---|
| `Client App/MCPummelchenModClient/` | Client SwiftPM package: macOS app, reusable client core, sync/watch CLI, and tests. | macOS GUI target is conditional; core and sync helper are also used by server-side soak tooling. |
| `Server App/MCPummelchenModServer/` | Server SwiftPM package: operator CLI, local HTTP API, release/mod/world pipelines, DuckDB helper, headless soak runner, contract helper, and tests. | Main operational package. Several commands can affect production files or services. |
| `Server App/MCPummelchenModShared/` | Shared models, validators, hashing, safe paths, defaults, file inventory, and DuckDB C integration. | Contract changes affect both server and client. |
| `Server App/Database/duckdb/` | Canonical schema entrypoint, numbered migrations, and database operator documentation. | Migrations are the schema source of truth. Runtime `CREATE TABLE IF NOT EXISTS` guards are compatibility fallbacks. |
| `Server App/Docs/contracts/` | Production behavior and client identity contracts plus API/DB contract artifacts. | Some authentication statements conflict with current code; see `.ai/KNOWN_UNKNOWNS.md`. |
| `Server App/nginx/` | nginx configuration and tracked public website source. | Runtime `/downloads/` contents are generated and intentionally not tracked. |
| `Server App/systemd/` | Server/update-scan units, timer, and service drop-ins. | Root-owned live service; preserve hardening and write-path restrictions. |
| `Live Backup/` | In-repository production DuckDB backup/checksum snapshots described by README. | Treat as recovery/audit material, not ordinary source. Do not rewrite casually. |
| `.ai/` | Vendor-neutral AI onboarding system. | Refresh after architectural, command, deployment, schema, security, or testing changes. |

## Swift package and product map

### Server package

Manifest: `Server App/MCPummelchenModServer/Package.swift`

| Product/target | Kind | Role |
|---|---|---|
| `MCPummelchenModServerCore` | library | API router, stores, live stats, release/mod/version/world pipelines, Minecraft supervision. |
| `MCPummelchenModServer` | executable | Operator command router and local socket-based HTTP server. |
| `pummelchen-duckdb` | executable | Apply migrations, run health checks, export and verify Parquet reporting views. |
| `pummelchen-headless-soak` | executable | Validate the exact client DMG in a fresh isolated environment and produce the release-gate report. |
| `pummelchen-contracts` | executable | Contract-oriented validation tooling. |
| `MCPummelchenModServerTests` | test target | API, DB-backed reporting, update, release, version, environment, and other server-core behavior. |

Dependencies: local shared package and local client package.

### Client package

Manifest: `Client App/MCPummelchenModClient/Package.swift`

| Product/target | Kind | Role |
|---|---|---|
| `MCPummelchenModClientCore` | library | Sync engine, status service/store, HTTP/control channel, self-update, defaults repair, Java and NeoForge management. |
| `pummelchen-client-sync` | executable | Non-GUI `sync` and `watch` interface bundled inside the app/DMG. |
| `MCPummelchenModClient` | macOS executable | SwiftUI/AppKit status and repair application. |
| `MCPummelchenModClientTests` | test target | Sync, status, defaults, and self-update behavior. |

Dependency: local shared package.

### Shared package

Manifest: `Server App/MCPummelchenModShared/Package.swift`

| Product/target | Kind | Role |
|---|---|---|
| `MCPummelchenModShared` | library | Cross-process contracts and utility code. |
| `CDuckDB` | C target | DuckDB header and C shim. |
| `MCPummelchenModSharedTests` | test target | Release, manifest, identifier, hashing/path, and shared utility tests. |

`PUMMELCHEN_DUCKDB_LIB_DIR` overrides the default native DuckDB library directory.

## Main entrypoints

| Surface | Path | Start here when… |
|---|---|---|
| Server command router and HTTP listener | `Server App/MCPummelchenModServer/Sources/MCPummelchenModServer/main.swift` | adding a command, changing CLI flags, local binding, startup, or command orchestration. |
| Server API core | `Server App/MCPummelchenModServer/Sources/MCPummelchenModServerCore/MCPummelchenModServerCore.swift` | changing routes, API payloads, client reports, public site feeds, release lookup, or error mapping. |
| Client GUI | `Client App/MCPummelchenModClient/Sources/MCPummelchenModClient/main.swift` | changing displayed status, actions, lifecycle, single-instance behavior, or `--once`. |
| Client sync/watch CLI | `Client App/MCPummelchenModClient/Sources/MCPummelchenModClientSync/main.swift` | changing CLI flags or non-GUI sync/control behavior. |
| DuckDB helper | `Server App/MCPummelchenModServer/Sources/PummelchenDuckDB/main.swift` | migrations, DB health, Parquet exports, or reporting verification. |
| Headless acceptance runner | `Server App/MCPummelchenModServer/Sources/PummelchenHeadlessSoak/main.swift` | DMG release-gate behavior. |
| Public website | `Server App/nginx/site/public/index.html` and companion pages | changing live site UI or API consumption. |
| Public edge | `Server App/nginx/sites-available/pummelchen-swift.conf` | changing TLS/listeners, API proxying, aliases, caching, or downloads. |
| Live service | `Server App/systemd/MCPummelchenModServer_26.1.2.service` | changing process ownership, runtime paths, restart policy, or hardening. |

## Server HTTP API surface

The route switch is in `MCPummelchenModServerCore.swift`.

### Read endpoints

| Method | Path | Purpose |
|---|---|---|
| GET | `/api/v1/status` | Service, release, transport, and mode metadata. |
| GET | `/api/v1/releases/current` | Validated current-release JSON. |
| GET | `/api/v1/clients/health` | Aggregated client status. |
| GET | `/api/v1/site/live-stats` | Live system/server/site metrics. |
| GET | `/api/v1/minecraft/server-versions` | DuckDB-backed supported live/staging version list and installer metadata. |
| GET | `/api/v1/site/mod-inventory/mods` | Merged server/client mod inventory. |
| GET | `/api/v1/site/mod-inventory/server` | Server-scope inventory. |
| GET | `/api/v1/site/mod-inventory/client` | Client-scope inventory. |
| GET | `/api/v1/site/failed-mods` | Failed/banned candidates and latest scan status. |
| GET | `/api/v1/site/release-history` | Release history from DuckDB. |
| GET | `/api/v1/site/update-activity` | Combined release/scan/health activity. |
| GET | `/api/v1/site/neoforge-version` | Current official NeoForge installer metadata. |
| GET | `/api/v1/site/release-health` | Latest release-health state. |
| GET | `/api/v1/control/info` | Control-channel metadata. |
| GET | `/api/v1/control/events` | Pending global or client-targeted events. |
| GET | release manifest route | Release-scoped TSV manifest. |

### Write/control endpoints

| Method | Path | Purpose |
|---|---|---|
| POST | `/api/v1/control/events` | Create a control event. |
| POST | `/api/v1/control/acks` | Acknowledge receipt of an event. |
| POST | `/api/v1/clients/register` | Register/update a client identity record. |
| POST | `/api/v1/clients/heartbeat` | Store a status report. |
| POST | `/api/v1/clients/sync-runs` | Store sync result/status. |
| POST | `/api/v1/clients/inventory` | Store versioned managed-file inventory. |
| POST | `/api/v1/clients/diagnostics` | Store diagnostic metadata/log summary. |
| POST | `/api/v1/clients/defaults-events` | Store client-default inspection/repair events. |

`conflicting`: these routes currently do not invoke the former authorization guard, while older docs still say control and write/report endpoints require bearer credentials. See `.ai/SECURITY.md` and `.ai/KNOWN_UNKNOWNS.md` before changing this area.

## Primary workflows

### Client synchronization

1. Refuse to mutate managed files while Minecraft is running unless explicitly allowed.
2. Fetch `/downloads/current-release.json`; fall back to `/api/v1/releases/current`.
3. Validate the `CurrentRelease` contract and release-scoped URLs.
4. Fetch and parse `client-sync-manifest.tsv` (`mods`, `resourcepacks`, `shaderpacks`, `tools`).
5. Remove files managed by the previous manifest but absent from the new one.
6. On first install, quarantine unmanaged files in managed directories.
7. Verify existing files by size and SHA256; download only missing/corrupt entries.
8. Verify the temporary download before atomically replacing the destination.
9. Apply full defaults only on first install; later syncs update server entries without resetting unrelated player preferences.
10. Write installed-release and manifest state, record local DuckDB state, optionally report server status/inventory/defaults, and evaluate DMG self-update.

### Add a mod

`ModAddPipeline` resolves a Modrinth/CurseForge artifact plus required dependencies (bounded graph), classifies server/client placement, copies files, patches version metadata, records source rows, smoke-checks, optionally builds a DMG on macOS, then creates and optionally activates a release. Dry-run defaults to `true`.

### Scan and apply mod updates

`ModUpdateScanner` seeds source data, optionally carries live-version inventory into a staging-version candidate set, discovers redundant links, enforces fetch throttling, checks NeoForge/Modrinth/CurseForge/generic HTML sources, and persists scan results. `ModUpdateApplyPipeline` consumes a completed scan, gives protected/priority candidates precedence, blocks incomplete packages, downloads and installs replacements, smoke-checks, creates a release, and only activates a live-version release when configured.

### Bootstrap a new Minecraft version

`ServerVersionBootstrapPipeline` locates a target and reference version in DuckDB, runs a target-version scan seeded from project/live data, copies server mods, datapacks, client mods, shaders, resource packs, and tools into the target package, preserves `Priority Mod` and `Admin Locked`, and can hand off to update application and release creation.

### Create and activate a release

`SwiftReleasePipeline` creates an immutable release directory, copies package content, writes manifests and metadata, rebuilds version-scoped ZIP/MRPACK artifacts, verifies checksums, validates any DMG soak proof, writes public release data, persists release/audit rows, and optionally activates. Only the DuckDB version marked live may update global current-release files and stable aliases.

### Build and gate a client DMG

`ClientDMGBuilder` builds the GUI and sync helper, constructs and signs an app bundle, embeds the DuckDB dylib, optionally embeds a private bootstrap resource with owner-only permissions, creates the DMG, and can run nginx/control and headless soak validation. Production contracts require a matching `MCPummelchenModClient.dmg.headless-live-soak.json` proof for a DMG-backed release.

### Reset a world

`SwiftWorldResetPipeline` is destructive. It supports a dry-run plan, requires explicit confirmation for mutation, controls the service, backs up the world, updates server properties, installs and verifies required datapacks, waits for RCON, applies safety gamerules, pregenerates/clears forceloads, optionally removes the backup, and persists the job result.

## Database overview

DuckDB is the only supported production database. Canonical migrations currently documented:

| Migration | Purpose |
|---|---|
| `001_foundation.sql` | Foundation schemas, core/audit/reporting/archive objects and views. |
| `002_operational_schemas_and_indexes.sql` | `client`, `control`, `release`, and `world` operational schemas plus indexes. |
| `003_minecraft_versions.sql` | Supported Minecraft versions and version-aware mod/scan/client fields. |
| `004_client_inventory_by_version.sql` | Canonical version-keyed client inventory. |
| `005_reporting_status_normalization.sql` | Normalize active/accepted reporting status. |
| `006_release_history_source_of_truth.sql` | Make `release.pack_releases` authoritative for release history. |
| `007_mod_source_links.sql` | Multiple normalized provider links per source. |
| `008_mod_source_discovery_results.sql` | Persist discovery attempts/outcomes. |
| `009_priority_mod_status.sql` | Treat `Priority Mod` as protected/accepted. |
| `010_server_version_installer_metadata.sql` | Store per-version NeoForge installer name/URL/SHA256. |
| `011_admin_locked_status.sql` | Treat `Admin Locked` as protected/accepted. |

Schemas visible in code/docs: `core`, `client`, `control`, `release`, `world`, `audit`, `reporting`, and `archive`.

## Build, run, and test essentials

Run commands from the repository root and quote paths containing spaces.

```sh
swift build --package-path "Server App/MCPummelchenModShared"
swift build --package-path "Server App/MCPummelchenModServer"
swift build --package-path "Client App/MCPummelchenModClient"

swift test --package-path "Server App/MCPummelchenModShared"
swift test --package-path "Server App/MCPummelchenModServer"
swift test --package-path "Client App/MCPummelchenModClient"
```

Local server example:

```sh
swift run --package-path "Server App/MCPummelchenModServer" MCPummelchenModServer serve \
  --project-root "$PWD" --host 127.0.0.1 --port 8787
```

See `.ai/COMMANDS.md` for the full command catalogue and safety classification.

## Important invariants and conventions

- Current source/config outranks older docs when facts conflict.
- Runtime duties are Swift + embedded DuckDB + nginx; shell/Python should remain build/test/operator tooling, not always-on production logic.
- Public operational website data must come from Swift API/DuckDB, not stale committed JSON fallbacks.
- Release directories are immutable and named with validated release identifiers.
- Global current-release aliases belong only to the DuckDB `is_live` Minecraft version.
- Client manifest paths are release-scoped, traversal-free, and tied to section/file names.
- Client writes are checksum-verified and atomically replaced.
- Repeat client sync must preserve unrelated player preferences.
- Schema evolution uses new numbered migrations.
- Control events may not carry file-download URLs or downloadable artifact references.
- Dry-run should remain the default for high-impact operator pipelines where currently supported.
- Tests use Swift Testing rather than XCTest in inspected suites.

## Security-sensitive areas

| Area | Why extra care is required |
|---|---|
| Client identity/reporting/control | Current code and contracts disagree about authentication requirements. |
| `PUMMELCHEN_CLIENT_API_TOKEN` and private app resources | Private bootstrap/reporting material; never commit or expose in logs/metadata. |
| `/etc/pummelchen-swift/server.env` | Runtime environment file referenced by the root service. |
| RCON and Minecraft supervisor | Direct live-server control and watchdog restart capability. |
| systemd service/drop-ins | Root privilege, firewall manipulation, process-tree semantics, hardening. |
| nginx configuration | Public TLS/API/download boundary and cache behavior. |
| DuckDB production file and `Live Backup/` | Operational/client/release/audit history and recovery state. |
| Release/DMG pipeline | Publishes executable artifacts and stable client aliases. |
| World reset | Deliberately destructive filesystem/service/RCON workflow. |

## Generated files and do-not-edit zones

Unless the task explicitly targets generated artifacts, avoid editing or committing:

- `Server App/nginx/site/public/downloads/`
- runtime release directories and current-release pointers
- generated DMG, ZIP, MRPACK, JAR, checksum, and headless-soak outputs
- Swift `.build/` directories
- Parquet exports from `pummelchen-duckdb export-parquet`
- client quarantine and temporary sync directories
- runtime paths under `/opt/pummelchen-swift/runtime`
- the vendored DuckDB header except during a deliberate native-library update
- production DuckDB backups/snapshots under `Live Backup/`

## Common task map

| Task | First files to read | Minimum validation |
|---|---|---|
| Add/change an API endpoint | API core, `APIModels.swift`, nginx alias if relevant, server tests | server build + focused/API tests |
| Change client sync | `ClientSyncEngine.swift`, manifest/current-release contracts, client tests | client build + sync tests; first and repeat install cases |
| Change control events | `APIModels.swift`, `ControlEventStore.swift`, `ClientControlChannel.swift`, `ClientControlWatcher.swift` | server + client tests; auth/conflict review |
| Add DB field/table/view | DuckDB README, latest migration, all query sites | new migration + disposable migrate/health + tests |
| Change release publication | `SwiftReleasePipeline.swift`, contracts, current-release validators | server tests and artifact/contract validation |
| Change mod discovery | `ModUpdateScanner.swift`, DB migration/schema, scanner tests | dry-run/focused tests; rate-limit behavior |
| Change mod application | `ModUpdateApplyPipeline.swift`, `ModVersionPatcher.swift`, release pipeline | dry-run + server tests + package readiness cases |
| Add supported Minecraft version | DuckDB version row/migration, bootstrap pipeline, client resolver/installer | bootstrap dry-run + version/client tests |
| Change client app UI | client `main.swift`, status service/model | client build + status tests |
| Change Java/NeoForge setup | `JavaRuntimeManager.swift`, `NeoForgeClientInstaller.swift`, server-version API | pinned-hash tests/validation and client tests |
| Change website | `Server App/nginx/site/public/` and API payloads it consumes | static review plus endpoint tests |
| Change nginx/systemd | corresponding config/docs and `.ai/SECURITY.md` | config review; deployment-owner approval |
| Change world reset/RCON | world pipeline, RCON client, supervisor, contracts | dry-run only unless explicitly authorized |

## Recommended first-read order

1. `AI_INDEX.md`
2. `AGENTS.md`
3. `.ai/START_HERE.md`
4. `.ai/PROJECT_MAP.md`
5. `.ai/ARCHITECTURE.md`
6. `.ai/COMPONENTS.md`
7. `.ai/COMMANDS.md`
8. `.ai/TESTING.md`
9. `.ai/SECURITY.md`
10. `.ai/PLAYBOOKS.md`
11. `.ai/KNOWN_UNKNOWNS.md`
12. Current source files for the requested task

## Refresh analysis

The previous index referenced `743356f85b0d4343cb8b1f71a92731eaf479bf47`. Current `main` is `00e25e1a9584ca075e27b404305bda18157aa7f3`. The change range contains the prior onboarding files and README onboarding block; no product-source change was found in that range. This refresh is a **full documentation rewrite** because the previous onboarding set was too shallow for a new AI session, not because architecture changed.

## Known conflicts that must not be silently resolved

1. **Authentication**: current server routes no longer call the former authorization guard; current client polling works without a token; client status reporting still returns early without a token; contracts and README still describe authenticated traffic.
2. **Status mode naming**: `/api/v1/status` derives `read_only` versus `phase6_writes_enabled` from presence of a configured token even though route-level write authorization was removed.
3. **Swift version wording**: package manifests use Swift tools version 6.2; the database README describes a host with Swift 6.3.2.
4. **Production state**: live service, DB contents, external provider responses, certificates, DNS, and release artifacts cannot be verified from repository source alone.

## Evidence

- `README.md`
- `Client App/MCPummelchenModClient/Package.swift`
- `Client App/MCPummelchenModClient/Sources/MCPummelchenModClient/main.swift`
- `Client App/MCPummelchenModClient/Sources/MCPummelchenModClientCore/ClientSyncEngine.swift`
- `Client App/MCPummelchenModClient/Sources/MCPummelchenModClientCore/ClientControlChannel.swift`
- `Client App/MCPummelchenModClient/Sources/MCPummelchenModClientCore/ClientControlWatcher.swift`
- `Client App/MCPummelchenModClient/Sources/MCPummelchenModClientSync/main.swift`
- `Server App/MCPummelchenModServer/Package.swift`
- `Server App/MCPummelchenModServer/Sources/MCPummelchenModServer/main.swift`
- `Server App/MCPummelchenModServer/Sources/MCPummelchenModServerCore/MCPummelchenModServerCore.swift`
- `Server App/MCPummelchenModServer/Sources/MCPummelchenModServerCore/ModAddPipeline.swift`
- `Server App/MCPummelchenModServer/Sources/MCPummelchenModServerCore/ModUpdateScanner.swift`
- `Server App/MCPummelchenModServer/Sources/MCPummelchenModServerCore/ModUpdateApplyPipeline.swift`
- `Server App/MCPummelchenModServer/Sources/MCPummelchenModServerCore/ServerVersionBootstrapPipeline.swift`
- `Server App/MCPummelchenModServer/Sources/MCPummelchenModServerCore/SwiftReleasePipeline.swift`
- `Server App/MCPummelchenModServer/Sources/MCPummelchenModServerCore/ClientDMGBuilder.swift`
- `Server App/MCPummelchenModServer/Sources/MCPummelchenModServerCore/SwiftWorldResetPipeline.swift`
- `Server App/MCPummelchenModServer/Sources/MCPummelchenModServerCore/MinecraftLiveServerSupervisor.swift`
- `Server App/MCPummelchenModServer/Sources/PummelchenDuckDB/main.swift`
- `Server App/MCPummelchenModShared/Package.swift`
- `Server App/MCPummelchenModShared/Sources/MCPummelchenModShared/APIModels.swift`
- `Server App/MCPummelchenModShared/Sources/MCPummelchenModShared/CurrentRelease.swift`
- `Server App/MCPummelchenModShared/Sources/MCPummelchenModShared/ClientSyncManifest.swift`
- `Server App/Database/duckdb/README.md`
- `Server App/Docs/contracts/PRODUCTION_CONTRACTS.md`
- `Server App/Docs/contracts/CLIENT_IDENTITY.md`
- `Server App/nginx/README.md`
- `Server App/nginx/sites-available/pummelchen-swift.conf`
- `Server App/systemd/README.md`
- `Server App/systemd/MCPummelchenModServer_26.1.2.service`
- `Server App/systemd/MCPummelchenModUpdateScan.service`
