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
# Architecture

## 1. System context

MinecraftAI manages the lifecycle of a large, versioned Minecraft/NeoForge mod pack across a Debian server and macOS clients. Its primary architectural goal is to turn potentially unsafe manual operations—mod discovery, compatibility selection, package mutation, client repair, release publication, and world maintenance—into validated, repeatable workflows with checksums and DuckDB audit state.

```text
                    Modrinth / CurseForge / NeoForged / Java sources
                                      |
                                      | metadata and artifacts
                                      v
Operator ------> MCPummelchenModServer CLI/API <------ systemd timer
                    |       |       |                       |
                    |       |       +--> Minecraft process + RCON
                    |       |
                    |       +----------> DuckDB
                    |
                    +--> immutable releases + public release tree
                                      |
                                      v
                                  nginx edge
                       website / API / static downloads
                                      |
                                      v
                         macOS app + sync/watch helper
                       local Minecraft dir + client DuckDB
```

The system is deliberately split between **control/metadata traffic** and **large immutable downloads**. The Swift API handles control, status, reports, and operational data. nginx serves large release files under `/downloads/`.

## 2. Process and deployment architecture

### 2.1 Public edge

`Server App/nginx/sites-available/pummelchen-swift.conf` defines:

- HTTP listeners redirecting to HTTPS.
- TLS listeners on IPv4 and IPv6.
- HTTP/2 and HTTP/3/QUIC.
- `/api/` proxying to `127.0.0.1:8787`.
- `client_max_body_size 256k` for proxied API requests.
- Operational JSON aliases such as `/live-stats.json`, `/update-activity.json`, `/neoforge-version.json`, `/release-health.json`, and `/server-versions.json` mapped to Swift endpoints.
- No-store/no-cache behavior for current release pointers and operational data.
- Static `/downloads/` alias to the runtime downloads directory.
- Static website delivery from the runtime `site/public` tree.

The edge is a trust boundary: browser/client traffic is public; the Swift server is expected to remain locally bound behind nginx.

### 2.2 Swift server service

`MCPummelchenModServer_26.1.2.service` runs:

```text
/opt/pummelchen-swift/bin/MCPummelchenModServer serve
  --project-root /opt/pummelchen-swift/runtime
  --host 127.0.0.1
  --port 8787
```

The service is root-owned because it may supervise the Minecraft process and install local firewall rules. Hardening includes `NoNewPrivileges`, `PrivateTmp`, `ProtectHome`, `ProtectSystem=full`, `RestrictSUIDSGID`, and constrained `ReadWritePaths`. `KillMode=process` is significant: the service's Minecraft child process behavior is intentionally different from a conventional control-group kill.

### 2.3 Minecraft supervisor

When `PUMMELCHEN_MINECRAFT_AUTOSTART` and required environment values are present, `MinecraftLiveServerSupervisor`:

1. Validates the runtime directory and executable command.
2. Installs IPv4/IPv6 firewall rules that reject non-local RCON traffic.
3. Checks whether the Minecraft TCP port is already open.
4. Starts the Minecraft process and logs stdout/stderr.
5. Optionally starts a watchdog.
6. Uses RCON to probe the server thread.
7. Restarts the process after a configured failure threshold.

This creates a privilege and availability boundary. Changes to process ownership, firewall execution, watchdog timing, RCON handling, or systemd kill semantics require deployment-owner review.

### 2.4 Scheduled update scan

`MCPummelchenModUpdateScan.timer` runs daily. The corresponding oneshot service:

1. Stops the Swift server service.
2. Acquires an `flock` lock.
3. Runs `mod-update-scan --all-supported true` against the production DuckDB.
4. Enables project-data seeding and source-link discovery with configured throttles.
5. Restarts the Swift server in `ExecStopPost`.

The design aims to give the write-heavy scanner exclusive DuckDB write access while preserving intended Minecraft process behavior through the service boundary.

## 3. Server application architecture

### 3.1 Command router

`Sources/MCPummelchenModServer/main.swift` is the operator-facing composition root. It owns:

- CLI usage and option parsing.
- Command dispatch.
- Construction of pipeline configurations.
- The local socket-based HTTP listener.
- Optional supervisor startup.
- Process exit/error formatting.

Business logic should generally live in `MCPummelchenModServerCore`, not grow indefinitely in the command router.

### 3.2 HTTP server and API core

The local HTTP server parses requests into `HTTPRequest` and delegates to `MCPummelchenModServerAPI.response(for:)`. The API core:

- normalizes request paths;
- routes by `(method, path)`;
- validates payload size and contracts;
- delegates persistence to `ServerClientReportStore` and `ControlEventStore`;
- delegates metrics to `LiveStatsProvider`;
- reads current release/manifest files;
- queries DuckDB for website/reporting payloads;
- maps typed failures to HTTP status codes.

The route switch is explicit rather than framework-driven, which makes the core file the authoritative API inventory.

### 3.3 Public operational data

The API owns the source of truth for:

- live stats;
- server-supported versions;
- merged/server/client mod inventory;
- failed/banned mod status;
- release history;
- update activity;
- NeoForge version metadata;
- release health;
- client health.

The website must display an unavailable state if these APIs fail. Static JSON fallbacks are intentionally prohibited because they can present stale operational state.

## 4. Shared contracts and validation architecture

The shared package is the compatibility layer between server, client, tests, and release tooling.

### 4.1 Current release contract

`CurrentRelease` carries:

- release ID and timestamps;
- status, Minecraft version, loader version, server key;
- manifest, client ZIP, MRPACK, and optional DMG URLs/checksums;
- notes.

`CurrentReleaseValidator` enforces:

- valid release identifier;
- required fields;
- relative, release-scoped URLs;
- no parent traversal, backslashes, or empty path segments;
- expected file extensions/suffixes;
- paired DMG URL/SHA fields;
- SHA256 syntax;
- stable DMG alias preference.

This contract is consumed by the server API, release pipeline, client sync, and self-update logic. Any field change is cross-package and must be versioned/tested as a contract change.

### 4.2 Client sync manifest contract

The manifest is a five-column UTF-8 TSV:

```text
section    name    size_bytes    sha256:<hex>    url_path
```

Allowed sections are `mods`, `resourcepacks`, `shaderpacks`, and `tools`. The parser enforces:

- exactly five columns;
- known section;
- plain non-hidden filename;
- non-negative size;
- SHA256 marker and 64-hex value;
- release-scoped URL;
- URL suffix matching section and filename;
- no duplicate `(section, name)` entries.

### 4.3 Shared API models

`APIModels.swift` defines client registration/status/inventory/diagnostics/default reports, health summaries, acknowledgements, control event types, create requests, event batches, and acknowledgements. Changing JSON coding keys or optionality requires checking both the API handlers and client channel.

### 4.4 Filesystem and integrity utilities

- `SafePath` constrains writes to a root.
- `SHA256Hasher` hashes source and downloaded files.
- `FileInventory` records and verifies managed files.
- `ContractValidation` centralizes input constraints.

These are security controls, not incidental helpers.

## 5. Client architecture

### 5.1 GUI lifecycle

The macOS application is an AppKit application hosting SwiftUI content. `ClientStatusModel` owns:

- server URL and current snapshot;
- refresh/sync/force-update state;
- startup auto-sync decision;
- control watcher task;
- endpoint latency refresh task;
- retry after Minecraft closes.

The UI provides:

- server/client release status;
- endpoint health and latency;
- managed-default health;
- Sync Now;
- Force Update;
- Refresh;
- editable server URL.

A POSIX file lock prevents multiple application instances; a second launch activates the existing app.

### 5.2 Sync/watch CLI

`pummelchen-client-sync` exposes:

- `sync`: run one synchronization and print a machine/human-readable summary;
- `watch`: poll control events and trigger syncs.

The CLI explicitly rejects a token value passed as `--client-api-token`, reducing exposure through process listings. Optional credentials come from environment, Info.plist, or a private bundle resource.

### 5.3 Client sync state machine

```text
start
  |
  +-- Minecraft running and no override? --> fail/record/report
  |
  +-- prepare directories
  +-- fetch & validate current release
  +-- fetch & parse manifest
  +-- remove stale previously managed files
  +-- first install? quarantine unmanaged files
  +-- for each entry:
  |      existing file valid? -> verified
  |      else download -> verify -> atomic replace
  +-- install/verify Java and NeoForge as configured
  +-- apply defaults (full first install; server entries later)
  +-- write release marker + local manifest
  +-- record local DuckDB status/inventory
  +-- optional server reports
  +-- evaluate/stage app self-update
  v
result
```

The failure path records a local failed sync result and attempts optional reporting before rethrowing.

### 5.4 First install versus later sync

This distinction is an invariant:

- **First install**: quarantine unmanaged managed-section files, sync every manifest section, apply all managed defaults, inspect/report defaults and full inventory.
- **Later sync**: synchronize managed mods while preserving already-present non-mod content and unrelated player settings; apply server entries rather than resetting all defaults.

Changes that collapse this distinction risk data loss or preference resets.

### 5.5 Managed Java

`JavaRuntimeManager` uses a pinned Temurin arm64 macOS JDK archive with a pinned SHA256. It checks bundled/cache/download locations, verifies the archive, extracts to a managed directory, runs `java -version`, removes stale managed runtime versions, and writes a marker.

### 5.6 Supported NeoForge versions

`ClientSupportedVersionsResolver` fetches the version list from the server, validates uniqueness and presence of a live version, caches it locally, then falls back to bundled defaults only when server/cache resolution fails. `NeoForgeClientInstaller` prefers server-provided installer name/URL/SHA metadata and uses pinned fallback requirements when needed.

### 5.7 Self-update

The client treats current-release DMG metadata as the application-update contract. Self-update code downloads and verifies the DMG, mounts it read-only, validates the app bundle and helper/native library, stages replacement, exits, installs the new app, and relaunches. This path handles executable code and must retain checksum/signature/bundle validation.

## 6. Control and client-report architecture

### 6.1 Control event data flow

```text
operator/API creates event
  -> control.control_events
  -> client GET /api/v1/control/events?client_id=...
  -> ClientControlWatcher interprets type
  -> optional jitter + ClientSyncEngine.sync(force: true)
  -> client POST acknowledgement
  -> control.control_acks
```

Global events have no target client; targeted events include a client ID. Pending query excludes already acknowledged events.

Immediate sync types:

- `release_available`
- `sync_required`
- `defaults_changed`
- `client_sync_requested`

Informational types:

- `server_message`
- `server_restart_notice`
- `health_update`

Control payloads are capped at 16 KiB and cannot contain download URL/file references. Large downloads always go through the release/download channel.

### 6.2 Client reports

When reporting is enabled and a client token is available, the client sends:

- sync/status report;
- managed-file inventory;
- defaults inspection/repair events;
- diagnostics where applicable.

`conflicting`: server routes currently accept these endpoints without invoking the former authorization guard, while `ClientSyncEngine.report` still skips all report uploads when no token is present. This asymmetry should be resolved by an explicit security decision, not an opportunistic code cleanup.

## 7. Mod lifecycle architecture

### 7.1 Add-mod flow

```text
source URL / optional local artifact
  -> provider resolver (Modrinth or CurseForge)
  -> required dependency graph (bounded)
  -> JAR metadata inspection / side classification
  -> copy to server and/or client package
  -> optional metadata range patch
  -> persist mod source rows
  -> smoke check
  -> optional macOS DMG build
  -> release pipeline
  -> optional activation
```

The pipeline's dry-run mode resolves/classifies without copying or creating a release.

### 7.2 Scan flow

`ModUpdateScanner`:

1. Ensures needed runtime tables/columns exist.
2. Optionally seeds from project release manifests.
3. Seeds missing target-version candidates from the live baseline for staging versions.
4. Optionally discovers missing redundant provider links.
5. Creates a scan row.
6. Loads source records for the selected version.
7. Applies fetch throttling.
8. Checks official APIs/pages or generic source HTML.
9. Classifies results, including Cloudflare blocking.
10. Persists per-source result, failure status, progress, and completed summary.

Provider behavior is differentiated: NeoForge, Modrinth, CurseForge, and generic web sources do not have identical loader/version rules.

### 7.3 Discovery flow

Documented discovery order:

1. Modrinth/CurseForge APIs.
2. Direct provider-site HTML search.
3. Google results filtered to accepted provider URLs.

Discovery is capped at two searches per second and recorded in DuckDB. A discovered link remains evidence, not deployment authorization.

### 7.4 Apply flow

`ModUpdateApplyPipeline`:

1. Load live/staging targets.
2. Load latest completed scan candidates.
3. If priority candidates exist, apply only that protected/priority set first.
4. Verify package readiness.
5. Group candidates by artifact URL.
6. Download and inspect the artifact.
7. Remove replaced files from applicable server/client locations.
8. Copy and patch the replacement.
9. Update source rows.
10. Smoke-check the version package.
11. Build DMG for the live version when available.
12. Create release; activate only a configured live target, otherwise stage.
13. Record update activity.

## 8. Multi-version architecture

DuckDB `core.minecraft_server_versions` and related views are the source of truth for supported versions, status, `is_live`, server address, sort order, loader version, and NeoForge installer metadata.

### Version bootstrap flow

```text
registered target version + registered reference version
  -> scan target with live/project seeding
  -> query accepted reference-version mods/files
  -> create/ensure target package sections
  -> use target-specific scanned artifact where available
  -> otherwise copy validated baseline file
  -> preserve Priority Mod/Admin Locked state
  -> copy client shaders/resourcepacks/tools/datapacks
  -> optional apply pipeline and release
```

A staging version may have compatibility candidates without being a deployed install. Code and reporting must maintain that distinction.

## 9. Release architecture

### 9.1 Release directory structure

A release contains, at minimum:

```text
<release-id>/
├── CHANGELOG.md
├── metadata.json
├── manifests/
│   ├── server-files.tsv
│   └── client-package.tsv
├── server-files/
│   ├── mods/
│   └── server-datapacks/
├── client-package/
├── artifacts/
│   ├── version-scoped client ZIP + checksum
│   ├── version-scoped MRPACK + checksum
│   └── optional DMG + checksum + soak report
├── db/
└── public/
    ├── current-release.json
    ├── client-sync-manifest.tsv
    └── client-files/
```

The exact copied DB/public structure is owned by `SwiftReleasePipeline`; verify current implementation before adding fields.

### 9.2 Creation and validation

The release pipeline:

- rejects an existing release directory;
- copies server and client package content;
- generates manifests and hashes;
- rebuilds client distribution artifacts;
- validates required ZIP/MRPACK;
- validates optional DMG and soak report;
- writes deterministic metadata/current-release content;
- builds public release files;
- persists release state;
- validates the completed release.

### 9.3 Activation

Activation:

- publishes the release public tree to nginx downloads;
- always writes version-scoped current-release files;
- writes global current-release JSON/text and stable aliases only if DuckDB marks that version live;
- updates active release rows/events;
- prunes old release storage using configured retention;
- performs configured cleanup and service restart.

A staging release must never overwrite the global client pointer.

## 10. DMG and acceptance architecture

### DMG build

On macOS the builder:

1. Builds release binaries for the app and sync helper.
2. Creates the app bundle layout.
3. Optionally writes the private bootstrap resource with mode `0600`.
4. Builds the icon.
5. Locates and embeds `libduckdb.dylib`.
6. Patches install names and rpaths.
7. Writes Info.plist with client/release metadata.
8. Lints and ad-hoc signs the app/native binaries.
9. Verifies signatures.
10. Optionally tests the nginx/control path.
11. Creates and hashes the DMG.
12. Optionally runs the headless live soak.

### Production soak gate

The production contract requires proof tied to the exact DMG and release ID. The acceptance run covers:

- app installation from the DMG;
- signature/helper/DuckDB validation;
- managed Java and NeoForge;
- full manifest sync and checksum verification;
- managed defaults;
- exactly one server entry;
- live server login;
- at least 60 seconds connected;
- no fatal logs or crash reports.

The release pipeline rejects missing, stale, mismatched, too-short, or failed proof.

## 11. DuckDB architecture

### Canonical migration model

`pummelchen-duckdb migrate`:

- discovers numeric-prefix `.sql` files;
- rejects duplicate numeric versions;
- initializes `core.schema_migrations`;
- skips applied versions;
- computes migration checksums;
- applies each migration transactionally;
- records version/name/time/checksum.

### Runtime access

The server, client, and helper use `DuckDBDatabase` through the native C API. Normal runtime code should not shell out to the DuckDB CLI.

### Reporting model

Reporting views decouple website/API consumers from operational table layout. Health checks verify required reporting fields and print table/schema/database/settings summaries. Parquet export/verify covers a known list of reporting views and records audit rows.

### Concurrency assumptions

The scheduled scan stops the API service to avoid write contention. Future changes involving concurrent writers should be treated as an architectural change and tested against DuckDB locking/transaction behavior.

## 12. Website architecture

The tracked website is static HTML/CSS/JS, but its operational content is dynamic. `index.html` includes:

- live system/server statistics and charts;
- server-version cards;
- release/download actions;
- mod/update tables;
- operator guidance;
- links to release and failed-mod pages.

Tabulator is loaded from a CDN for data-grid rendering. The site theme is in tracked assets. API field changes can break JavaScript rendering even when server tests pass; inspect the page consumer.

## 13. World reset architecture

World reset is a durable job with database/audit state and a planned versus executed result.

### Dry-run

- validate configuration;
- resolve active world name/path;
- enumerate required datapacks;
- compute pregeneration chunks/segments;
- return a plan without service/filesystem mutation.

### Execute

- require confirmation;
- validate native service control;
- persist requested/running state;
- stop service;
- back up active world;
- update server properties;
- install/verify required datapacks;
- start service and wait for RCON;
- apply safety gamerules;
- pregenerate using forceload segments;
- verify forceload cleanup;
- optionally delete backup;
- persist completed/failed result.

Failure handling persists a failed job and rethrows. Never simplify this to ad-hoc directory deletion.

## 14. Security and trust boundaries

| Boundary | Primary controls | Main risks |
|---|---|---|
| Internet → nginx | TLS, local proxy target, body limit, cache/security headers | public exposure, stale/cache leakage, route misconfiguration |
| nginx → Swift API | localhost binding and proxy rules | accidentally exposing local service or bypassing headers |
| API → DuckDB/files | validators, safe paths, payload limits, typed stores | injection/path traversal, corrupt operational state |
| Release source → public downloads | immutable layout, SHA256, validation, live-only aliases | malicious/corrupt client files, wrong live version |
| Client download → filesystem | manifest validation, hash/size, temp + atomic replace | arbitrary file write, partial/corrupt install |
| DMG → executable app | hash, mount/bundle/signature/helper/native validation | executable replacement compromise |
| systemd root → Minecraft/RCON/firewall | hardening, local RCON firewall, explicit env config | privilege misuse, service outage, secret leakage |
| Operator → world reset/release/DB | dry-run, explicit confirmation, immutable releases, migrations | irreversible data loss or live outage |

See `.ai/SECURITY.md` for the detailed checklist.

## 15. Architectural conflicts and decision points

### Authentication is unresolved

Current route code accepts control/client writes without invoking the old authorization guard. Client control polling works without credentials, but client report upload still requires an optional token on the client side. Older contracts and README wording describe authenticated traffic. This is a real mismatch across trust boundaries.

A future fix must explicitly decide:

- which endpoints are public, operator-only, or client-authenticated;
- whether client ID alone has any trust meaning;
- token enrollment/rotation/revocation model;
- whether nginx contributes access control;
- migration/compatibility behavior for existing clients;
- updated status mode semantics and tests/docs.

### Production state is external

The repo defines desired service/configuration and retains backup artifacts, but it does not prove:

- deployed unit/config versions;
- current certificates/DNS/firewall;
- live DuckDB schema/data consistency;
- exact current mod/provider responses;
- available disk space and runtime artifacts;
- account state for live soak.

Treat these as operator-observed facts, not repository facts.

## Evidence

- `Server App/MCPummelchenModServer/Sources/MCPummelchenModServer/main.swift`
- `Server App/MCPummelchenModServer/Sources/MCPummelchenModServerCore/MCPummelchenModServerCore.swift`
- `Server App/MCPummelchenModServer/Sources/MCPummelchenModServerCore/ControlEventStore.swift`
- `Server App/MCPummelchenModServer/Sources/MCPummelchenModServerCore/ModAddPipeline.swift`
- `Server App/MCPummelchenModServer/Sources/MCPummelchenModServerCore/ModUpdateScanner.swift`
- `Server App/MCPummelchenModServer/Sources/MCPummelchenModServerCore/ModUpdateApplyPipeline.swift`
- `Server App/MCPummelchenModServer/Sources/MCPummelchenModServerCore/ServerVersionBootstrapPipeline.swift`
- `Server App/MCPummelchenModServer/Sources/MCPummelchenModServerCore/SwiftReleasePipeline.swift`
- `Server App/MCPummelchenModServer/Sources/MCPummelchenModServerCore/ClientDMGBuilder.swift`
- `Server App/MCPummelchenModServer/Sources/MCPummelchenModServerCore/SwiftWorldResetPipeline.swift`
- `Server App/MCPummelchenModServer/Sources/MCPummelchenModServerCore/MinecraftLiveServerSupervisor.swift`
- `Client App/MCPummelchenModClient/Sources/MCPummelchenModClientCore/ClientSyncEngine.swift`
- `Client App/MCPummelchenModClient/Sources/MCPummelchenModClientCore/ClientControlWatcher.swift`
- `Client App/MCPummelchenModClient/Sources/MCPummelchenModClientCore/JavaRuntimeManager.swift`
- `Client App/MCPummelchenModClient/Sources/MCPummelchenModClientCore/NeoForgeClientInstaller.swift`
- `Server App/MCPummelchenModShared/Sources/MCPummelchenModShared/CurrentRelease.swift`
- `Server App/MCPummelchenModShared/Sources/MCPummelchenModShared/ClientSyncManifest.swift`
- `Server App/MCPummelchenModShared/Sources/MCPummelchenModShared/APIModels.swift`
- `Server App/Database/duckdb/README.md`
- `Server App/Docs/contracts/PRODUCTION_CONTRACTS.md`
- `Server App/nginx/sites-available/pummelchen-swift.conf`
- `Server App/systemd/MCPummelchenModServer_26.1.2.service`
- `Server App/systemd/MCPummelchenModUpdateScan.service`
