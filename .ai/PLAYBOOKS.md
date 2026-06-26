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
# Development Playbooks

These playbooks describe project-specific procedures. They are not permission to run production operations. Use current source and `.ai/COMMANDS.md` before executing commands.

## Playbook 1: Add or change a server API endpoint

### Read first

- `MCPummelchenModServerCore.swift`
- shared `APIModels.swift`
- relevant website/client consumer
- server tests
- `.ai/SECURITY.md`

### Procedure

1. Identify whether the endpoint is:
   - public operational read;
   - client/control read;
   - client write/report;
   - operator write.
2. Decide method/path and cache behavior.
3. Define or update a shared Codable model if the client consumes it.
4. Add route handling in `MCPummelchenModServerAPI.response(for:)`.
5. Keep heavy query/persistence logic in a store/provider rather than growing route code.
6. Bound request body and collection sizes.
7. Validate IDs, URLs, timestamps, and optional fields.
8. Decide authorization explicitly; do not copy current ambiguous behavior without analysis.
9. Add success and error tests.
10. Update website/client consumer.
11. Add nginx alias only if a compatibility JSON path is required.
12. Update contracts/onboarding if public behavior changes.

### Validation

```sh
swift build --package-path "Server App/MCPummelchenModServer"
swift test --package-path "Server App/MCPummelchenModServer" --filter MCPummelchenModServerCoreTests
```

Also build/test client or shared package if their model changed.

### Risks

- field-name breakage;
- stale browser code;
- accidental public write access;
- cache exposing stale/sensitive data;
- DB query failure returning misleading fallback.

## Playbook 2: Change a shared JSON or manifest contract

### Read first

- `CurrentRelease.swift`, `ClientSyncManifest.swift`, `APIModels.swift`
- all server/client call sites
- shared tests
- production contract docs

### Procedure

1. Search every use of the type/coding key.
2. Determine backward compatibility requirements.
3. Change the shared model/parser/validator.
4. Update release producer and API producer.
5. Update client/website consumers.
6. Add invalid-input tests, not only happy paths.
7. Keep path, checksum, and duplicate validation at least as strict.
8. Update schema examples/docs if externally visible.

### Validation

Run shared tests, then client and server builds/tests.

### Risks

- old clients unable to decode;
- weakened path safety;
- release producer and consumer disagree;
- optional field ambiguity.

## Playbook 3: Add a client status field or UI element

### Read first

- client `main.swift`
- `ClientStatusService.swift`
- `ClientStatusStore.swift`
- relevant shared models
- `ClientStatusTests.swift`

### Procedure

1. Identify whether the value is remote, local filesystem, local DB, or derived.
2. Add it to the snapshot/model at the owning layer.
3. Avoid doing network/filesystem work directly in a SwiftUI view.
4. Keep main-actor UI mutation isolated.
5. Decide refresh cadence and cancellation behavior.
6. Render unavailable/error state explicitly.
7. Avoid exposing sensitive local paths or client data.
8. Add status/service tests.

### Validation

```sh
swift build --package-path "Client App/MCPummelchenModClient"
swift test --package-path "Client App/MCPummelchenModClient" --filter ClientStatusTests
```

## Playbook 4: Change client sync behavior

### Read first

- `ClientSyncEngine.swift`
- shared manifest/current release/file inventory/safe path code
- `MinecraftClientDefaults.swift`
- `ClientSyncEngineTests.swift`
- `.ai/SECURITY.md`

### Procedure

1. Classify change as fetch, verification, destination, stale removal, quarantine, defaults, reporting, or self-update.
2. Preserve the Minecraft-running guard unless the requirement explicitly changes it.
3. Preserve first-install versus repeat-sync semantics.
4. Keep destination mapping closed over known sections.
5. Keep size/SHA verification before final installation.
6. Keep temporary download and atomic replacement.
7. Only remove files proven previously managed.
8. Record local failure/success state.
9. Decide whether reports should be attempted and how missing credentials behave.
10. Add tests for success, failure, and repeat execution.

### Validation

Use disposable directories:

```sh
swift test --package-path "Client App/MCPummelchenModClient" --filter ClientSyncEngineTests
swift test --package-path "Client App/MCPummelchenModShared" --filter ClientSyncManifestTests
```

### Risks

- player data loss;
- arbitrary writes;
- corrupt partial installs;
- unwanted preference reset;
- sync loops triggered by control events.

## Playbook 5: Add or change a control event

### Read first

- shared `ControlEventType` and models
- `ControlEventStore.swift`
- API routes
- `ClientControlWatcher.requiresImmediateSync`
- client channel
- authentication conflict notes

### Procedure

1. Add the event type to the shared enum.
2. Decide whether it is informational or sync-triggering.
3. Update watcher switch exhaustively.
4. Define allowed payload keys; never carry artifact URLs.
5. Add creation, polling, and watcher tests.
6. Consider older clients receiving an unknown event type (Codable enum decode failure).
7. Update docs/operator UI if event is operator-facing.
8. Resolve or explicitly retain current auth behavior through human review.

### Validation

Run shared, client, and server tests.

### Risks

- decode failure on older clients;
- sync storm;
- event replay/missed ack;
- public control-event injection.

## Playbook 6: Add a DuckDB migration

### Read first

- `Server App/Database/duckdb/README.md`
- latest migration
- `schema.sql`
- `PummelchenDuckDB/main.swift`
- every affected query/write site and reporting view

### Procedure

1. Choose the next unused numeric prefix.
2. Write an idempotent/upgrade-safe SQL migration appropriate to DuckDB.
3. Update `schema.sql` if it represents a complete canonical setup.
4. Update code that reads/writes the schema.
5. Update reporting views and API payloads as needed.
6. Add tests using a disposable DB.
7. Apply all migrations to an empty DB.
8. Apply to a representative prior-schema fixture if available.
9. Run health and affected queries.
10. Do not edit an applied migration without explicit deployment confirmation.

### Validation

```sh
DB="$(mktemp -d)/migration-test.duckdb"
swift run --package-path "Server App/MCPummelchenModServer" pummelchen-duckdb migrate \
  --duckdb "$DB" --migrations-dir "Server App/Database/duckdb/migrations"
swift run --package-path "Server App/MCPummelchenModServer" pummelchen-duckdb health --duckdb "$DB"
```

Then run affected package tests.

### Risks

- production data loss;
- migration/view/code mismatch;
- type/default/nullability assumptions;
- write-lock/concurrency behavior.

## Playbook 7: Add a mod through the pipeline

### Read first

- `ModAddPipeline.swift`
- server command usage
- release pipeline
- scanner/source tables
- production contracts

### Procedure

1. Use `add-mod --dry-run true` with exact target version/package paths.
2. Review resolved primary artifact and dependency graph.
3. Review side/scope classification.
4. Verify target Minecraft/NeoForge compatibility evidence.
5. Confirm source/provider URLs and expected file names.
6. Confirm target release ID and activation intent.
7. For real execution, ensure DB/release/public paths and backup/recovery are correct.
8. Run non-dry-run only with operator approval.
9. Review smoke/DMG/soak/release results.
10. Do not manually copy around a failed gate.

### Risks

- dependency explosion;
- provider metadata ambiguity;
- client/server mismatch;
- auto-activation of an unsafe package.

## Playbook 8: Change mod source discovery or scanner logic

### Read first

- `ModUpdateScanner.swift`
- source/link/discovery/scan migrations
- site failed/update activity APIs
- scanner tests

### Procedure

1. Identify provider/artifact type and compatibility semantics.
2. Keep API-first behavior and HTML fallback clearly separated.
3. Keep challenge/error page detection.
4. Preserve fetch and discovery throttles.
5. Store discovery attempts and per-source scan outcomes.
6. Never convert a weak parse into a trusted deployable candidate.
7. Add fixture-based parser tests.
8. Add DB seeding/progress/summary tests.
9. Run dry-run on a bounded source set if network validation is explicitly needed.

### Risks

- provider rate limiting;
- false positives/negatives;
- external HTML instability;
- misclassifying shaders/resource packs as loader-bound mods.

## Playbook 9: Change mod update application

### Read first

- `ModUpdateApplyPipeline.swift`
- scanner result schema
- `ModVersionPatcher.swift`
- release pipeline
- package readiness logic/tests

### Procedure

1. Verify how version targets and completed scans are selected.
2. Preserve priority/protected candidate behavior.
3. Keep package readiness blocking before mutation.
4. Group duplicate artifact URLs intentionally.
5. Confirm scope and old-file removal rules.
6. Verify replacement hash and metadata.
7. Keep dry-run side-effect free.
8. Preserve live/staging release behavior.
9. Add tests for current/no-candidate/blocked/dry-run/staged/active outcomes.

### Risks

- deleting a still-required artifact;
- applying only a subset of coupled updates;
- staging/live pointer confusion;
- DB source state disagreeing with package files.

## Playbook 10: Add or bootstrap a Minecraft server version

### Read first

- DuckDB version migrations/schema and rows
- `ServerVersionBootstrapPipeline.swift`
- scanner/apply pipelines
- client supported-version resolver
- NeoForge installer
- systemd README

### Procedure

1. Add/register target version, loader version, status, server directory/address, sort order, and installer metadata in DuckDB through the intended migration/operator path.
2. Ensure target server directory/package skeleton exists.
3. Run bootstrap dry-run against an explicit reference version.
4. Review seeded sources and copied baseline roles.
5. Verify protected mods and banned/failed exclusions.
6. Run target-version scan and inspect compatibility results.
7. Apply updates/release only after package readiness.
8. Keep target staging until validation passes.
9. Confirm clients can fetch/validate installer metadata and create the version-specific server entry.
10. Promote `is_live` only through an explicit operational decision.

### Risks

- assuming copied baseline is compatible;
- missing client sections/datapacks;
- installer hash mismatch;
- overwriting global current release from staging.

## Playbook 11: Change release creation or activation

### Read first

- `SwiftReleasePipeline.swift`
- shared current-release/manifest validators
- production contracts
- nginx downloads behavior
- DB release migrations/views

### Procedure

1. Identify whether change affects layout, metadata, artifacts, publication, activation, retention, cleanup, or restart.
2. Update producer and validators together.
3. Keep release directory immutable.
4. Keep version-scoped artifact naming.
5. Require ZIP/MRPACK and correct hashes.
6. Keep DMG/soak pair validation.
7. Preserve live-only global alias rule.
8. Update DB persistence/events and reporting views if fields change.
9. Add release validation tests.
10. Test with a disposable fixture root; do not publish to live downloads.

### Risks

- clients downloading wrong/corrupt release;
- current pointer and DB disagree;
- deleting active release during retention;
- service restart during incomplete publication.

## Playbook 12: Change DMG build or client self-update

### Read first

- `ClientDMGBuilder.swift`
- `ClientAppSelfUpdater.swift`
- headless soak runner
- current release contract
- production contracts
- self-updater tests

### Procedure

1. Map the exact app bundle/resource/native library changes.
2. Preserve release builds and helper inclusion.
3. Preserve DuckDB dylib install-name/rpath handling.
4. Preserve Info.plist release ID and client version.
5. Preserve signature verification.
6. Ensure optional private resource cannot leak.
7. Update DMG hash/metadata and self-update validation together.
8. Update soak validation/report schema if acceptance changes.
9. Run unit tests, local macOS build, and operator acceptance separately.
10. Never claim a live soak without the generated proof.

### Risks

- executable replacement compromise;
- unsigned/broken app;
- native library load failure;
- credential exposure;
- false acceptance proof.

## Playbook 13: Change Java or NeoForge requirements

### Read first

- `JavaRuntimeManager.swift`
- `NeoForgeClientInstaller.swift`
- supported-version resolver/model
- server version API/DB metadata
- defaults/client tests

### Procedure

1. Update version/name/URL and pinned hash as one atomic change.
2. Verify the archive/installer on a controlled host.
3. Keep server-driven metadata validation.
4. Update fallback only when necessary for offline/bootstrap behavior.
5. Confirm expected extracted/profile paths.
6. Add tests for requirement selection and malformed metadata.
7. Run a disposable client installation; never overwrite a player's environment.

### Risks

- supply-chain compromise;
- wrong architecture/platform;
- stale hash;
- server/client loader mismatch.

## Playbook 14: Change the website

### Read first

- `Server App/nginx/site/public/index.html` and relevant page
- API endpoint and response model
- nginx README/site config
- site theme assets

### Procedure

1. Identify data source for each displayed value.
2. Keep operational data API-backed; no static fallback.
3. Handle unavailable/error/empty states.
4. Escape/safely render API values and URLs.
5. Update table/grid field mapping.
6. Preserve download aliases and cache expectations.
7. Review mobile/responsive behavior.
8. Add/update server payload tests if API changes.
9. Perform browser integration on a safe environment.

### Risks

- stale/misleading operations dashboard;
- DOM injection;
- broken CDN/grid dependency;
- wrong release/download link.

## Playbook 15: Change nginx configuration

### Read first

- `Server App/nginx/README.md`
- `sites-available/pummelchen-swift.conf`
- `nginx.conf`
- `.ai/SECURITY.md`

### Procedure

1. Classify change: listener/TLS, proxy, alias, caching, upload limit, or security header.
2. Preserve ACME challenge and HTTPS redirect behavior.
3. Preserve local API upstream unless architecture changes.
4. Check path matching precedence (`=`, `^~`, regex, prefix).
5. Keep current-release no-cache handling.
6. Keep large downloads static and preserve runtime downloads on deployment.
7. Update README/contracts.
8. Have operator run host config validation and staged reload.

### Risks

- public outage;
- exposing local API or files;
- stale client pointer;
- certificate/HTTP3 regression.

## Playbook 16: Change systemd or Minecraft supervisor

### Read first

- `Server App/systemd/README.md`
- all affected unit/drop-in files
- `MinecraftLiveServerSupervisor.swift`
- `.ai/SECURITY.md`

### Procedure

1. Identify process, privilege, filesystem, and restart impact.
2. Preserve hardening unless minimal additional access is justified.
3. Review `KillMode=process` semantics.
4. Review environment-file and runtime paths.
5. Keep API localhost bind.
6. Keep RCON firewall local-only.
7. Test environment parsing/unit logic.
8. Have operator deploy units, daemon-reload, inspect, and stage restart.

### Risks

- root privilege expansion;
- Minecraft orphan/termination;
- service restart loop;
- DB contention;
- public RCON exposure.

## Playbook 17: World reset or RCON change

### Read first

- `SwiftWorldResetPipeline.swift`
- `MinecraftRCONClient.swift`
- supervisor/systemd files
- production contracts
- `.ai/SECURITY.md`

### Procedure

1. Keep pure planning/calculation separate from execution.
2. Keep explicit confirmation for destructive path.
3. Validate active world name/path.
4. Preserve backup-before-mutation.
5. Preserve service stop/start validation.
6. Preserve required datapack checks and safety gamerules.
7. Preserve RCON readiness and forceload cleanup verification.
8. Persist all job states/errors.
9. Add unit tests and dry-run fixture tests.
10. Leave real-world acceptance to an authorized operator.

### Risks

- irreversible world loss;
- wrong server/service target;
- leaked RCON credential;
- incomplete pregeneration/cleanup;
- backup deletion.

## Playbook 18: Debug local build or tests

1. Confirm Swift version.
2. Confirm native DuckDB library and `PUMMELCHEN_DUCKDB_LIB_DIR`.
3. Build shared package first.
4. Build client, then server.
5. Run the focused failing test without parallel unrelated operations.
6. Distinguish compile/link/load/environment failures from assertion failures.
7. Use a disposable DB and fixture root.
8. Do not “fix” test failures by pointing to live runtime files.
9. Capture exact command and error without secrets.
10. Expand to full package tests after the focused fix.

## Playbook 19: Refresh AI onboarding

### Trigger

Refresh after changes to architecture, package/module layout, routes, commands, migrations, release/client-sync/mod pipelines, deployment, security, or tests.

### Procedure

1. Read `.ai/MANIFEST.json` and previous indexed commit.
2. Compare previous commit to current HEAD.
3. Classify high-impact paths.
4. Inspect enough of the full repo to detect cross-cutting implications.
5. Preserve correct human additions.
6. Replace stale claims with current source-grounded facts.
7. Record conflicts rather than guessing.
8. Update metadata headers, `AI_INDEX.md`, `AGENTS.md`, affected `.ai/` files, changelog, and manifest.
9. Validate JSON, relative paths, file set, idempotent README block, model-neutral naming, and secret patterns.
10. Commit on a non-default branch.

## Evidence

- `.ai/ARCHITECTURE.md`
- `.ai/COMPONENTS.md`
- `.ai/COMMANDS.md`
- `.ai/TESTING.md`
- `.ai/SECURITY.md`
- source and configuration paths cited in each playbook
