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
# Component Cards

Each card identifies ownership, interfaces, dependencies, invariants, tests, and risks. Read the owning source before editing.

## 1. Server command router and local HTTP server

**Responsibility**

- Parse operator commands/options.
- Construct pipeline configuration.
- Start the local socket listener.
- Start optional Minecraft supervision.
- Print operator-facing result/error lines.

**Key files**

- `Server App/MCPummelchenModServer/Sources/MCPummelchenModServer/main.swift`

**Public interfaces**

- `MCPummelchenModServer` command catalogue in `.ai/COMMANDS.md`.
- Local HTTP bind host/port.

**Internal dependencies**

- `MCPummelchenModServerCore`
- `MCPummelchenModShared`
- pipeline configuration/result types

**Invariants**

- CLI usage must match actual parsing.
- Required options must fail clearly.
- Sensitive values should not be accepted in unsafe CLI positions when a safer environment/resource path exists.
- Business logic should remain in core modules where practical.

**Tests**

- Server-core tests cover constructed behavior, but command parsing coverage should be verified before changing flags.

**Risks**

- A flag default can switch a dry-run into mutation.
- Incorrect path construction can target live runtime directories.
- Error output may leak operator data if sensitive values are interpolated.

## 2. Server API core

**Responsibility**

- Route HTTP requests.
- Validate current release and manifests.
- Serve live site/reporting payloads.
- Accept control/client reports.
- Map typed failures to HTTP responses.

**Key files**

- `Server App/MCPummelchenModServer/Sources/MCPummelchenModServerCore/MCPummelchenModServerCore.swift`
- `Server App/MCPummelchenModShared/Sources/MCPummelchenModShared/APIModels.swift`

**Public interfaces**

- Routes listed in `AI_INDEX.md`.
- JSON and TSV response shapes.

**Dependencies**

- `ServerClientReportStore`
- `ControlEventStore`
- `LiveStatsProvider`
- `DuckDBDatabase`
- release/manifest validators and runtime files

**Invariants**

- Payload size limit remains enforced.
- Public operational data comes from DuckDB/Swift, not stale files.
- Current release and manifest must be validated before serving.
- Error codes remain stable for consumers.

**Tests**

- `MCPummelchenModServerCoreTests.swift` covers current release, manifest, status, live stats, site feeds, failed mods, and DB-backed behavior.

**Risks**

- API field changes can break website and client consumers.
- Current authentication behavior conflicts with docs.
- Large core file encourages accidental cross-domain edits; keep changes scoped.

## 3. Shared API models and contracts

**Responsibility**

- Define wire formats shared by server and client.
- Validate release and manifest inputs.
- Supply control event types.

**Key files**

- `APIModels.swift`
- `CurrentRelease.swift`
- `ClientSyncManifest.swift`
- `ReleaseIdentifier.swift`
- `ContractValidation.swift`

**Public interfaces**

- Codable JSON models.
- TSV manifest parser.
- release ID and URL/checksum rules.

**Dependencies**

- Foundation Codable/URL/Data.
- Used by both server and client packages.

**Invariants**

- JSON coding keys are part of the external contract.
- Manifest entries stay release-scoped and path-safe.
- Artifact checksums use 64-character SHA256 values.
- DMG URL/checksum fields appear together.

**Tests**

- `CurrentReleaseTests.swift`
- `ReleaseIdentifierTests.swift`
- `ClientSyncManifestTests.swift`
- server/client tests that encode/decode API payloads

**Risks**

- A seemingly local model edit is a cross-package breaking change.
- Weakening validation can become arbitrary-file-write or malicious-download exposure.

## 4. Control event store

**Responsibility**

- Initialize control tables.
- Create and validate events.
- Query pending global/client-targeted events.
- Record acknowledgements.

**Key files**

- `Server App/MCPummelchenModServer/Sources/MCPummelchenModServerCore/ControlEventStore.swift`
- shared control event models in `APIModels.swift`

**Public interfaces**

- `create`, `pendingEvents`, `acknowledge`.
- `/api/v1/control/events` and `/api/v1/control/acks` through API core.

**Dependencies**

- `DuckDBDatabase`
- shared validation/API models

**Invariants**

- Maximum payload is 16 KiB.
- Priority is one of low/normal/high/critical.
- Title/message lengths are bounded.
- Payload must not include download URLs or downloadable artifact references.
- Client IDs are validated.
- Acknowledgements are idempotent.

**Tests**

- Server API/control tests in the main server test suite; inspect for exact coverage before modifying validation.

**Risks**

- Unauthenticated event creation/polling is currently possible according to route code.
- Event order/after-ID logic can cause duplicate or missed events if changed carelessly.

## 5. Client control channel and watcher

**Responsibility**

- Send control and client-report HTTP requests.
- Poll event batches.
- Apply release jitter.
- Trigger forced sync for relevant event types.
- Acknowledge events.

**Key files**

- `ClientControlChannel.swift`
- `ClientControlWatcher.swift`
- `ClientHTTPClient.swift`

**Public interfaces**

- control info/events/acks
- client register/status/inventory/diagnostics/default uploads
- `pummelchen-client-sync watch`

**Dependencies**

- shared API models
- `ClientSyncEngine`
- `ClientStatusStore`

**Invariants**

- Always send a sanitized client ID.
- Add Authorization only if an optional token is present.
- Limit long poll wait to 30 seconds.
- Only defined event types trigger sync.
- A self-update scheduled by sync exits watcher after acknowledgement.

**Tests**

- Client status/sync tests and server control/API tests; focused watcher tests should be added if event behavior changes.

**Risks**

- Authentication mismatch.
- Duplicate sync storms if event acknowledgement/jitter changes.
- Event errors are retried indefinitely with a delay.

## 6. Client sync engine

**Responsibility**

- Synchronize managed Minecraft client files to a validated release.
- Apply defaults and managed runtime setup.
- Record/report result and inventory.
- Trigger self-update evaluation.

**Key files**

- `ClientSyncEngine.swift`
- shared `CurrentRelease.swift`, `ClientSyncManifest.swift`, `FileInventory.swift`, `SafePath.swift`

**Public interfaces**

- `ClientSyncConfiguration`
- `ClientSyncResult`
- `sync(force:)`
- `pummelchen-client-sync sync`

**Dependencies**

- HTTP client
- local `ClientStatusStore`
- defaults writer/inspector
- Java/NeoForge managers
- control channel for reports
- self-updater

**Invariants**

- Do not mutate while Minecraft is running without explicit override.
- Verify size and SHA256 before installing.
- Use safe destination paths and atomic replacement.
- Remove only previously managed stale files.
- First install and repeat sync have different preference-preservation semantics.
- Local result is recorded even on failure.

**Tests**

- `ClientSyncEngineTests.swift`
- shared manifest/current-release tests
- server headless soak uses client core for acceptance

**Risks**

- Player data loss.
- Partial install or checksum bypass.
- Cross-platform path assumptions.
- Reporting silently skipped when optional token is absent.

## 7. Client status service/store and GUI model

**Responsibility**

- Aggregate remote release/server endpoint status, local release state, default health, and client identity.
- Persist local sync/status/version/control information in DuckDB.
- Drive the SwiftUI status display and automatic actions.

**Key files**

- `ClientStatusService.swift`
- `ClientStatusStore.swift`
- client app `main.swift`
- `DefaultsRetryTracker.swift`
- `ClientDefaultsRepairCoordinator.swift`

**Public interfaces**

- GUI Refresh, Sync Now, Force Update.
- `MCPummelchenModClient --once`.

**Dependencies**

- client HTTP/control/sync modules
- defaults inspector/repair
- local DuckDB

**Invariants**

- UI state mutations occur on the main actor.
- Status checks should not mutate unrelated player state.
- Retry tasks are cancelled on model deinit.
- Client ID and local state remain stable across sessions.

**Tests**

- `ClientStatusTests.swift`
- defaults tests

**Risks**

- UI displaying stale or misleading state.
- Background task leaks or duplicate watchers.
- Current auth mode labels are inconsistent across code/docs.

## 8. Client self-updater

**Responsibility**

- Decide whether app replacement is needed.
- Download and hash the advertised DMG.
- Mount/inspect/validate the replacement app.
- Stage a replacement process and relaunch.

**Key files**

- `ClientAppSelfUpdater.swift`
- current-release contract
- GUI/sync call sites

**Public interfaces**

- automatic evaluation after sync
- Force Update action

**Dependencies**

- `ClientHTTPClient`
- macOS disk-image and app-bundle tooling
- release ID in Info.plist

**Invariants**

- Update only from validated current-release metadata.
- Verify DMG SHA256.
- Validate app/helper/native library before replacement.
- Do not replace current app while unsafe/incomplete.

**Tests**

- `ClientAppSelfUpdaterTests.swift`

**Risks**

- Executable supply-chain compromise.
- Broken app replacement/relaunch.
- Stable alias or release-ID mismatch.

## 9. Java runtime manager

**Responsibility**

- Provide a managed Java runtime for the Minecraft client.

**Key files**

- `JavaRuntimeManager.swift`

**Public interfaces**

- `ensureInstalled`
- `verify`

**Dependencies**

- pinned Temurin archive URL/name/SHA
- `/usr/bin/tar`
- filesystem and `java -version`

**Invariants**

- Archive SHA must match.
- Extracted Java must report the expected version.
- Only stale managed runtimes are removed.
- Current runtime marker accurately describes the executable.

**Tests**

- Client integration/default/status tests; add focused tests when changing pinned runtime or extraction logic.

**Risks**

- Native executable download and execution.
- Apple Silicon/macOS layout assumptions.
- Updating version without updating hash and tests.

## 10. NeoForge client installer and version resolver

**Responsibility**

- Resolve supported Minecraft/loader versions from the server/cache/fallback.
- Download, verify, and install NeoForge launcher profiles.

**Key files**

- `ClientSupportedVersionsResolver.swift`
- `NeoForgeClientInstaller.swift`
- shared Minecraft defaults/server model

**Public interfaces**

- `/api/v1/minecraft/server-versions`
- local cached version list
- `ensureSupportedInstalled`

**Dependencies**

- Java runtime
- pinned/server-provided installer metadata
- Minecraft launcher directory

**Invariants**

- Version list contains at least one live version.
- Duplicate Minecraft versions are removed/rejected.
- Installer URL/name/SHA must form a valid requirement.
- Installer hash is verified before executing Java.

**Tests**

- client status/default tests and server version API tests

**Risks**

- Executing a downloaded installer.
- Stale fallback metadata.
- Loader/version mismatch between server and client.

## 11. Mod add pipeline

**Responsibility**

- Turn a provider URL or local artifact into a validated package/release change.

**Key files**

- `ModAddPipeline.swift`
- `ModVersionPatcher.swift`
- release pipeline

**Public interfaces**

- `MCPummelchenModServer add-mod`

**Dependencies**

- Modrinth/CurseForge metadata and artifacts
- JAR inspection
- DuckDB source records
- smoke check, DMG builder, release pipeline

**Invariants**

- Dependency graph is bounded.
- Install scope reflects side metadata/explicit override.
- Dry-run does not copy/create a release.
- Non-dry-run records sources before release.
- Release gates remain intact.

**Tests**

- server pipeline tests in `MCPummelchenModServerCoreTests.swift`

**Risks**

- Pulling an incompatible or malicious artifact.
- Wrong server/client placement.
- Activating a release without intended validation.

## 12. Mod update scanner

**Responsibility**

- Discover and classify new artifacts for every supported live/staging version.

**Key files**

- `ModUpdateScanner.swift`
- DuckDB mod source/link/discovery/scan migrations

**Public interfaces**

- `MCPummelchenModServer mod-update-scan`
- `ModUpdateScanSummary`
- site update/failed-mod reporting

**Dependencies**

- Modrinth, CurseForge, NeoForged, generic web sources
- DuckDB
- release/project inventory

**Invariants**

- Fetch/discovery rates remain bounded.
- Version/loader compatibility rules differ by artifact/provider type.
- Cloudflare pages are blocked/unresolved, not valid metadata.
- Discovery evidence is persisted.
- A candidate is not auto-promoted.

**Tests**

- scanner parsing/seeding/site tests in server suite

**Risks**

- External HTML/API changes.
- False update candidate.
- Rate-limit/provider blocking.
- Runtime table guards drifting from canonical migrations.

## 13. Mod update apply pipeline

**Responsibility**

- Consume completed scan candidates and produce staged/active releases.

**Key files**

- `ModUpdateApplyPipeline.swift`
- `ModVersionPatcher.swift`
- `SwiftReleasePipeline.swift`

**Public interfaces**

- `MCPummelchenModServer mod-update-apply`

**Dependencies**

- DuckDB version/source/scan state
- server/client package directories
- artifact download and JAR inspection
- release and DMG pipelines

**Invariants**

- No completed scan means no apply.
- Package readiness blocks release creation.
- Protected/priority candidates are handled intentionally.
- Old files are removed only in the effective scope.
- Live/staging activation rules remain separate.
- Dry-run does not mutate package/DB/release.

**Tests**

- server apply/release tests

**Risks**

- Removing the wrong file.
- Incomplete package release.
- Incorrect live activation.

## 14. Server version bootstrap pipeline

**Responsibility**

- Prepare a new Minecraft version from a working reference version while preserving protected state.

**Key files**

- `ServerVersionBootstrapPipeline.swift`
- `ModUpdateScanner.swift`
- `ModUpdateApplyPipeline.swift`

**Public interfaces**

- `MCPummelchenModServer server-version-bootstrap`

**Dependencies**

- registered version rows/directories
- source/scan/mod/file tables
- client package section layout

**Invariants**

- Target and reference versions must be registered and have directories.
- Target-specific compatible artifacts take precedence over copied baseline.
- Banned/failed content is not carried forward as working state.
- `Priority Mod` and `Admin Locked` remain protected.
- Client sections and datapacks are copied to correct paths.

**Tests**

- server version-seeding/bootstrap tests

**Risks**

- Treating a baseline copy as proven compatibility.
- Mixing version-specific package state.
- Accidental live promotion.

## 15. Release pipeline

**Responsibility**

- Build, validate, persist, publish, activate, and retain immutable releases.

**Key files**

- `SwiftReleasePipeline.swift`
- shared current release/manifest/hash validators
- production contracts

**Public interfaces**

- `release-create`, `release-validate`
- downstream calls from add/apply pipelines
- public `current-release*.json`

**Dependencies**

- server/client package trees
- ZIP/MRPACK/DMG artifacts
- DuckDB release/audit state
- nginx public download root
- optional service restart/health monitor

**Invariants**

- Release ID is validated.
- Existing release dir is never overwritten.
- Required manifests/artifacts exist and hashes match.
- DMG requires valid soak proof.
- Only live version updates global aliases.
- Activation DB state and public files agree.
- Retention keeps active/latest releases.

**Tests**

- shared release contract tests and server release/API tests

**Risks**

- Publishing corrupt executable artifacts.
- Global pointer targeting staging/wrong release.
- Disk exhaustion or over-aggressive pruning.

## 16. DMG builder and headless soak

**Responsibility**

- Build a distributable macOS app/DMG and prove it works as a fresh player.

**Key files**

- `ClientDMGBuilder.swift`
- `Sources/PummelchenHeadlessSoak/main.swift`
- production contracts

**Public interfaces**

- `build-client-dmg`
- `pummelchen-headless-soak`
- DMG and `.headless-live-soak.json` artifacts

**Dependencies**

- macOS build/codesign/disk-image tools
- client/server packages
- DuckDB dylib
- live server and authenticated Minecraft account for complete soak

**Invariants**

- App and helper binaries are release builds.
- DuckDB dylib install names/rpaths are correct.
- Bundle/signature validation succeeds.
- Private resource, when used, has restrictive permissions and is not logged.
- Soak report matches exact DMG hash/release and duration.

**Tests**

- self-updater tests; server release tests; external live acceptance report

**Risks**

- Platform-specific build failures.
- Executable or credential leakage.
- False positive acceptance if proof validation weakens.

## 17. DuckDB helper and migration system

**Responsibility**

- Apply schema migrations and validate/export reporting state.

**Key files**

- `Sources/PummelchenDuckDB/main.swift`
- `Server App/Database/duckdb/`
- shared `DuckDBDatabase.swift`

**Public interfaces**

- `migrate`, `health`, `export-parquet`, `verify-parquet`

**Dependencies**

- native DuckDB dynamic library
- canonical migration directory

**Invariants**

- Numeric migration versions unique.
- Applied migration checksums recorded.
- Each migration transaction commits atomically.
- Health verifies required reporting fields.
- Parquet row counts can be compared to audit state.

**Tests**

- DB-backed server/shared tests; disposable command validation

**Risks**

- Production data loss.
- Native library path/version mismatch.
- Code/schema/view drift.

## 18. nginx website and public edge

**Responsibility**

- Terminate TLS, proxy APIs, serve website and immutable downloads, provide cache/security headers.

**Key files**

- `Server App/nginx/sites-available/pummelchen-swift.conf`
- `Server App/nginx/nginx.conf`
- `Server App/nginx/site/public/`

**Public interfaces**

- website pages
- `/api/`
- JSON aliases
- `/downloads/`

**Dependencies**

- local Swift API
- runtime site/download tree
- certificates and public DNS
- Tabulator CDN for current website grid UI

**Invariants**

- API proxy remains local.
- Current pointers/operational JSON are not stale-cached.
- Large downloads remain static.
- Runtime download artifacts are preserved during site deployments.
- No committed static operational fallback.

**Tests**

- Server endpoint tests; browser/manual integration; host `nginx -t` is deployment validation, not performed from source-only work.

**Risks**

- Public outage/security regression.
- Cache serving stale release pointers.
- Site/API field mismatch.

## 19. systemd units and live supervisor

**Responsibility**

- Run API/server supervisor, schedule daily scan, set environment and performance constraints.

**Key files**

- `MCPummelchenModServer_26.1.2.service`
- `MCPummelchenModServer_26.1.2.service.d/*.conf`
- `MCPummelchenModUpdateScan.service`
- `MCPummelchenModUpdateScan.timer`
- `MinecraftLiveServerSupervisor.swift`

**Public interfaces**

- systemd service/timer state
- runtime environment file
- Minecraft process and RCON/firewall behavior

**Dependencies**

- `/opt/pummelchen-swift` runtime/bin tree
- `/etc/pummelchen-swift/server.env`
- systemctl, flock, iptables/ip6tables

**Invariants**

- Hardening remains enabled.
- Write paths stay limited.
- API binds locally.
- Update scan receives exclusive write window and restarts service.
- RCON remains locally firewalled.

**Tests**

- environment parsing/supervisor unit tests; live service behavior requires operator acceptance

**Risks**

- Root privilege and firewall changes.
- Process leak/outage from kill-mode or restart changes.
- DB contention.

## 20. World reset pipeline

**Responsibility**

- Safely replace a live world and establish required datapacks/gamerules/pregeneration.

**Key files**

- `SwiftWorldResetPipeline.swift`
- `MinecraftRCONClient.swift`
- production contracts

**Public interfaces**

- `MCPummelchenModServer world-reset`
- persisted world reset job/result

**Dependencies**

- service control
- server.properties
- required datapack sources
- RCON
- filesystem backup and DuckDB

**Invariants**

- Dry-run plan is available.
- Mutation requires explicit confirmation.
- Backup occurs before replacement.
- Required datapacks are verified.
- Safety gamerules are applied.
- Forceloads are cleared/verified.
- Failure is persisted.

**Tests**

- world-reset algorithm/config tests in server suite; never infer live safety from unit tests alone

**Risks**

- Irreversible world loss or outage.
- Backup deletion.
- Incorrect service target/RCON credentials.

## Evidence

- Source files named in each component card
- Package manifests
- `Server App/Database/duckdb/README.md`
- `Server App/Docs/contracts/PRODUCTION_CONTRACTS.md`
- `Server App/nginx/README.md`
- `Server App/systemd/README.md`
