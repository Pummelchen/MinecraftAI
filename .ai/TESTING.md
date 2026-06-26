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
# Testing and Validation

## Framework

Inspected tests use **Swift Testing**, not XCTest:

- `@Suite`
- `@Test`
- `#expect`
- `#require`

The package manifests define one test target per package. Server and shared test targets copy fixture directories.

## Test target map

| Package | Target | Path | Direct dependencies |
|---|---|---|---|
| Shared | `MCPummelchenModSharedTests` | `Server App/MCPummelchenModShared/Tests/MCPummelchenModSharedTests/` | shared library; copied fixtures |
| Client | `MCPummelchenModClientTests` | `Client App/MCPummelchenModClient/Tests/MCPummelchenModClientTests/` | client core and shared library |
| Server | `MCPummelchenModServerTests` | `Server App/MCPummelchenModServer/Tests/MCPummelchenModServerTests/` | server core, shared library, client core; copied fixtures |

## Discovered test files and coverage

### Shared tests

| File | Coverage |
|---|---|
| `CoreUtilityTests.swift` | Shared utility behavior such as hashing, path, timestamp, DB/native helpers as implemented. |
| `CurrentReleaseTests.swift` | JSON decode/validation, required fields, artifact URL scoping, checksum rules, DMG metadata. |
| `ReleaseIdentifierTests.swift` | Accepted/rejected release ID syntax and parsed representation. |
| `ClientSyncManifestTests.swift` | TSV parsing, allowed sections, filenames, duplicate detection, size/SHA/path validation. |
| `Fixtures/` | Contract fixtures copied by SwiftPM. |

### Client tests

| File | Coverage |
|---|---|
| `ClientSyncEngineTests.swift` | Sync decisions, file verification/download/install behavior, first/repeat install, stale/quarantine behavior, errors and local results. |
| `ClientStatusTests.swift` | Endpoint/status/default/client state and service/store behavior. |
| `ClientAppSelfUpdaterTests.swift` | Self-update eligibility and DMG/app validation behavior. |
| `MinecraftClientDefaultsTests.swift` | Default writing, inspection, server entries, and idempotency. |

### Server tests

| File | Coverage discovered |
|---|---|
| `MCPummelchenModServerCoreTests.swift` | API current release/manifest/status; environment-driven Minecraft config; live stats; nginx-published stats; DuckDB site feeds; failed mods; scanner seeding; version, release, pipeline, and other server-core behavior in the remainder of the suite. |
| `Fixtures/` | Project/release/manifest fixtures copied by SwiftPM. |

The large server test file covers several domains. Use focused filters and search within it before adding duplicate tests.

## Prerequisites

### Swift toolchain

- Package manifests require Swift tools 6.2 semantics.
- A compatible toolchain and platform SDK are required.
- The macOS GUI/DMG path requires macOS 26-compatible tooling.

### Native DuckDB

Many shared/server/client-store tests require the native DuckDB library. `PUMMELCHEN_DUCKDB_LIB_DIR` may point SwiftPM linking at a non-default library directory.

Symptoms of missing/mismatched DuckDB include linker errors or runtime load failures before test logic executes.

### External tools

Some pipeline code invokes external tools such as:

- `zip` / `unzip`
- `tar`
- `shasum` or `sha256sum`
- macOS `sips`, `iconutil`, `otool`, `install_name_tool`, `plutil`, `codesign`, and DMG tooling
- systemctl/iptables/RCON-related runtime commands

Ordinary unit tests should not require production service or live external-provider access. If a test begins depending on those, isolate it behind fixtures/injection or document it as acceptance testing.

## Running tests

```sh
swift test --package-path "Server App/MCPummelchenModShared"
swift test --package-path "Client App/MCPummelchenModClient"
swift test --package-path "Server App/MCPummelchenModServer"
```

Recommended order after a broad change:

1. shared tests;
2. client tests;
3. server tests.

This follows the local dependency direction.

## Focused test examples

```sh
swift test \
  --package-path "Server App/MCPummelchenModShared" \
  --filter CurrentReleaseTests

swift test \
  --package-path "Server App/MCPummelchenModShared" \
  --filter ClientSyncManifestTests

swift test \
  --package-path "Client App/MCPummelchenModClient" \
  --filter ClientSyncEngineTests

swift test \
  --package-path "Client App/MCPummelchenModClient" \
  --filter ClientAppSelfUpdaterTests

swift test \
  --package-path "Server App/MCPummelchenModServer" \
  --filter MCPummelchenModServerCoreTests
```

If a filtered command runs zero tests, list/discover current test names or use a more specific fully qualified filter. Do not interpret zero tests as a pass.

## Fixture and temporary-state conventions

Inspected server tests:

- create temporary project roots;
- remove them with `defer`;
- write release/public fixture files;
- create disposable DuckDB databases;
- seed test rows explicitly;
- use helper methods such as `makeProjectFixture()` and `requireDuckDB()`.

Follow these patterns. Avoid tests that point to:

- `/opt/pummelchen-swift/runtime`;
- a real player's Minecraft directory;
- `Live Backup/`;
- real `/etc/systemd` or nginx paths;
- a production DuckDB file.

## Validation by component

### Shared contracts

Minimum:

- focused contract test;
- full shared package tests;
- client/server builds when Codable/public API changes.

Test cases should include:

- valid and invalid release IDs;
- traversal/backslash/double-segment URLs;
- incorrect suffix/extension;
- missing or malformed SHA;
- duplicate manifest entries;
- hidden/path-containing filenames;
- paired optional fields.

### Server API

Minimum:

- server build;
- focused route tests;
- affected website/client consumer review.

Test:

- success payload and headers;
- not found;
- wrong method;
- bad payload;
- payload-too-large;
- DuckDB missing/empty/error behavior;
- cache headers for operational endpoints;
- field compatibility.

### Control events

Test:

- valid global and targeted event;
- client ID validation;
- priority/title/message bounds;
- payload over 16 KiB;
- forbidden download keys/values;
- pending ordering and limits;
- acknowledgement idempotency;
- immediate-sync versus informational event switch;
- authentication behavior only after a deliberate security decision.

### Client sync

At minimum cover both first and repeat install.

Test:

- Minecraft-running guard;
- current-release download fallback;
- manifest parsing failure;
- valid existing file avoids download;
- checksum/size mismatch causes replacement;
- temporary file is verified before destination;
- stale managed file removal;
- first-install unmanaged quarantine;
- repeat-install non-mod preservation;
- full defaults first install versus server entries later;
- local result/inventory recording;
- report/no-report paths;
- self-update scheduling result.

### Client status/defaults

Test:

- offline/update/repair/synced states;
- endpoint latency status;
- supported-version server/cache/fallback order;
- default inspection statuses;
- idempotent repair;
- single server entry and preference preservation;
- local DuckDB state round trips.

### Java and NeoForge

Prefer tests around pure validation/path/requirement selection rather than live downloads.

Test:

- expected archive/installer hash handling;
- server-driven installer metadata validation;
- fallback requirement selection;
- existing installed profile detection;
- malformed version list and missing live version;
- extraction/install errors through controlled fixtures or process abstraction if available.

### Mod scanner

Test:

- provider detection;
- latest-version parsing;
- Cloudflare challenge classification;
- source link role;
- dry-run write behavior;
- scan progress/summary counts;
- seeding from manifests;
- live-to-staging candidate seeding;
- protected statuses;
- provider/artifact-type compatibility semantics;
- source discovery recording and limits.

Avoid live provider pages in unit tests. External APIs/HTML are unstable.

### Mod add/apply/bootstrap

Test:

- dry-run does not mutate;
- dependency graph dedup/bound;
- install scope;
- server/client path selection;
- old file replacement;
- target-version artifact preference;
- incomplete package blocking;
- protected candidate behavior;
- live versus staging release result;
- no completed scan behavior;
- release handoff configuration.

### Release pipeline

Test:

- release ID validation;
- existing directory rejection;
- required path errors;
- manifest generation and SHA values;
- required ZIP/MRPACK;
- optional DMG pair and soak proof;
- current release URL contract;
- live-only global aliases;
- staging version-scoped pointers;
- DB active/event state;
- retention without deleting active release;
- post-create validation.

### DMG and self-update

Unit tests cannot replace macOS/live acceptance.

Local tests should cover:

- update decision by installed release/app bundle metadata;
- invalid/missing DMG metadata;
- hash mismatch;
- validation errors;
- staging/replacement command construction where testable.

Acceptance must prove the exact DMG, app/helper/native library, Java, NeoForge, full sync/defaults, server entry, live login, duration, and log/crash conditions.

### DuckDB migration/reporting

Use a new temporary DB:

1. run all migrations;
2. run health;
3. exercise affected writes/queries;
4. run relevant package tests;
5. for reporting changes, export and verify Parquet if appropriate.

Also test migration idempotency (second migrate applies nothing) and upgrade from a representative prior schema when practical.

### nginx/website

Static source validation should include:

- API endpoint/field references;
- unavailable/error rendering;
- no fallback to stale operational JSON;
- current-release/download alias paths;
- safe rendering/escaping of API data;
- responsive/manual browser behavior.

Host-level nginx config validation is an operator acceptance step. It was not run as part of generating these docs.

### systemd/supervisor

Unit-test environment parsing and pure command/path logic where possible. Operator acceptance should verify:

- unit load and hardening;
- runtime/env paths;
- service start/restart/stop behavior;
- Minecraft child-process semantics;
- local RCON firewall rules;
- watchdog behavior;
- daily scan stop/lock/restart sequence.

### World reset

Unit tests should focus on:

- configuration validation;
- dry-run plan;
- world-name/path safety;
- pregeneration chunk/segment calculation;
- required datapack inventory;
- gamerule set;
- confirmation requirement;
- persistence status transitions.

A real world reset is never routine test validation.

## Slow or environment-sensitive validation

Known or likely slow/environment-dependent areas:

- DB-heavy scanner/version/release tests;
- Swift release builds;
- Java/NeoForge archive handling;
- DMG assembly and codesign;
- headless live soak;
- external provider discovery;
- live nginx/systemd/Minecraft/RCON checks.

Do not mark these flaky without evidence. Record exact environment failure separately from logic failure.

## No CI assumption

No `.github/workflows` CI configuration was found during the scan. Therefore:

- do not rely on a remote pipeline to catch build/test issues;
- state exactly what was run locally;
- consider all three package tests for cross-package changes;
- require operator acceptance for deployment and live-release paths.

## Minimum pre-PR checklist

- [ ] Relevant package builds.
- [ ] Focused tests pass.
- [ ] Broader owning-package tests pass.
- [ ] Shared/client/server downstream packages tested if a shared contract changed.
- [ ] Disposable migration/health run if schema changed.
- [ ] No production paths were used unintentionally.
- [ ] No generated/binary artifacts were added.
- [ ] No credentials/private runtime data appear in diff/logs.
- [ ] Docs/onboarding refreshed if architecture/commands/contracts changed.
- [ ] Skipped acceptance/deployment checks are clearly listed.

## Evidence

- all three `Package.swift` files
- `Server App/MCPummelchenModServer/Tests/MCPummelchenModServerTests/MCPummelchenModServerCoreTests.swift`
- test files listed above
- `Server App/Database/duckdb/README.md`
- `Server App/Docs/contracts/PRODUCTION_CONTRACTS.md`
