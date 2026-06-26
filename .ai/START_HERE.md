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
# Start Here: Fresh-Session Prompt

This file contains a compact, vendor-neutral prompt for a new AI coding session and a task-oriented reading strategy. It is designed to avoid loading the whole repository before the task is understood.

## Paste this into a fresh session

```text
You are working in the MinecraftAI repository, indexed at commit
00e25e1a9584ca075e27b404305bda18157aa7f3.

Before editing anything:

1. Read AI_INDEX.md and AGENTS.md.
2. Read the task-relevant files under .ai/:
   - PROJECT_MAP.md for navigation and module ownership
   - ARCHITECTURE.md for runtime/data/workflow flows
   - COMPONENTS.md for interfaces, invariants, dependencies, tests, and risks
   - COMMANDS.md for exact commands and safety classification
   - TESTING.md for test layout and validation expectations
   - SECURITY.md for trust boundaries and sensitive operations
   - PLAYBOOKS.md for repeatable change procedures
   - KNOWN_UNKNOWNS.md for conflicts and facts requiring human review
3. Inspect the current source/configuration files directly involved in the task.
   Treat onboarding files as a map, never as a substitute for current code.
4. Summarize your understanding before editing under these labels:
   - Verified facts
   - Assumptions
   - Inferences
   - Unknowns/conflicts
5. Produce a concise implementation plan that names:
   - files to inspect and edit
   - public contracts affected
   - invariants to preserve
   - tests/commands to run
   - any production-only validation that must be left to an operator
6. Make the smallest coherent, source-grounded change.
7. Report:
   - changed files
   - key decisions
   - tests/validation actually run
   - validation skipped and why
   - remaining risks or unknowns

Repository-specific safety rules:
- Never expose or commit credentials, private client resources, RCON passwords,
  server environment values, keys, or production database contents.
- Do not run production migrations, release activation, world reset, RCON,
  systemd deployment, or live-server commands merely to validate a change.
- Preserve checksum verification, atomic file replacement, release immutability,
  live/staging separation, migration numbering, and systemd/nginx hardening.
- Current source outranks older docs when they conflict. Explicitly flag conflicts.
- Do not create model-specific AI instruction files.
```

## First-pass understanding template

Use this before touching files:

```text
Goal:

Verified facts:
- ... Evidence: `path/to/file`

Assumptions:
- ...

Inferences:
- ...

Unknowns/conflicts:
- ...

Likely owning components:
- ...

Plan:
1. ...
2. ...

Validation:
- ...

Production-only checks not run:
- ...
```

## Task-specific reading order

### Server API or public site data

1. `AI_INDEX.md` API table.
2. `.ai/ARCHITECTURE.md` → request and website flows.
3. `.ai/COMPONENTS.md` → API core, shared contracts, web edge.
4. `Server App/MCPummelchenModServer/Sources/MCPummelchenModServerCore/MCPummelchenModServerCore.swift`.
5. `Server App/MCPummelchenModShared/Sources/MCPummelchenModShared/APIModels.swift`.
6. Relevant files in `Server App/nginx/site/public/`.
7. Server tests.

### Client sync, defaults, control, or self-update

1. `.ai/ARCHITECTURE.md` → client sync/control/DMG flows.
2. `.ai/SECURITY.md` → identity/auth conflict and client filesystem trust boundary.
3. `ClientSyncEngine.swift`.
4. `ClientControlChannel.swift` and `ClientControlWatcher.swift` if control traffic changes.
5. `ClientStatusService.swift` / `ClientStatusStore.swift` if status changes.
6. `ClientAppSelfUpdater.swift` for app update behavior.
7. Shared `CurrentRelease.swift`, `ClientSyncManifest.swift`, `MinecraftClientDefaults.swift`.
8. Client tests.

### Mod discovery, add, scan, apply, or version bootstrap

1. `.ai/ARCHITECTURE.md` → mod lifecycle.
2. `.ai/COMPONENTS.md` → corresponding pipeline card.
3. Server command router for flags.
4. `ModAddPipeline.swift`, `ModUpdateScanner.swift`, `ModUpdateApplyPipeline.swift`, or `ServerVersionBootstrapPipeline.swift`.
5. DuckDB migrations and related query code.
6. Release pipeline and server tests.

### Release or DMG behavior

1. `Server App/Docs/contracts/PRODUCTION_CONTRACTS.md`.
2. `.ai/ARCHITECTURE.md` → release and DMG gate.
3. `SwiftReleasePipeline.swift`.
4. `ClientDMGBuilder.swift`.
5. `PummelchenHeadlessSoak/main.swift`.
6. Shared release/manifest validators.
7. Release/server/client self-update tests.

### DuckDB schema or reporting

1. `Server App/Database/duckdb/README.md`.
2. `.ai/PROJECT_MAP.md` → migration and schema map.
3. Latest numbered migration and any migration being depended upon.
4. Every Swift query/write site affected.
5. Reporting API consumers and tests.
6. `.ai/COMMANDS.md` for disposable migrate/health commands.

### nginx, website, or systemd

1. `.ai/SECURITY.md`.
2. `Server App/nginx/README.md` or `Server App/systemd/README.md`.
3. Exact config/unit/drop-in files.
4. Public site source and API aliases if relevant.
5. Production contracts.
6. Leave host deployment/config validation to the operator unless a safe local host is explicitly provided.

### World reset, RCON, or Minecraft supervisor

1. `.ai/SECURITY.md` and `.ai/KNOWN_UNKNOWNS.md`.
2. `SwiftWorldResetPipeline.swift`.
3. `MinecraftRCONClient.swift`.
4. `MinecraftLiveServerSupervisor.swift`.
5. systemd service/drop-ins.
6. Production contracts and tests.
7. Use dry-run only unless the operator explicitly authorizes a real target.

## Context-loading discipline

Do not load every large file immediately. Use this sequence:

1. Read the relevant onboarding section.
2. Inspect public type/config declarations.
3. Inspect the owning method or route.
4. Inspect direct callers/consumers.
5. Inspect focused tests.
6. Expand only when the dependency graph requires it.

Avoid spending context on:

- generated release/download trees
- binary backups
- vendored DuckDB headers
- large website style blocks when only API parsing is relevant
- unrelated pipeline implementation details

## Plan quality checklist

A plan is ready to execute when it answers:

- Which package owns the behavior?
- Is this a CLI, API, DB, manifest, filesystem, web, or service contract change?
- Which downstream consumers read the changed data?
- Which invariant could be violated?
- Is dry-run available?
- Which tests are focused and which broader package tests are needed?
- Does this require operator-only acceptance or deployment validation?
- Should the onboarding files be refreshed afterward?

## Final report template

```text
Summary:

Files changed:
- ...

Behavior and contract impact:
- ...

Validation run:
- command — result

Validation skipped:
- reason

Risks/unknowns:
- ...

Onboarding update:
- updated / not required, with rationale
```

## Evidence

- `AI_INDEX.md`
- `AGENTS.md`
- `.ai/PROJECT_MAP.md`
- `.ai/ARCHITECTURE.md`
- `.ai/COMPONENTS.md`
- `.ai/SECURITY.md`
