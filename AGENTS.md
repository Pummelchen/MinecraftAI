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
# Instructions for AI Coding Agents

These instructions are vendor-neutral. They apply to any high-capability coding agent working in this repository.

## Start every new session

1. Read `AI_INDEX.md`.
2. Read `.ai/START_HERE.md`.
3. Read the task-specific sections in `.ai/PROJECT_MAP.md`, `.ai/ARCHITECTURE.md`, `.ai/COMPONENTS.md`, `.ai/COMMANDS.md`, `.ai/TESTING.md`, and `.ai/SECURITY.md`.
4. Inspect the current source/configuration files directly involved in the requested change.
5. Before editing, state:
   - verified facts
   - assumptions
   - inferences
   - unknowns/conflicts
6. Produce a concise plan naming the files to inspect/edit and the validation commands.
7. Make the smallest coherent change; do not broaden scope without evidence.

## Source-of-truth hierarchy

When facts disagree, use this order:

1. Current source code.
2. Build, runtime, deployment, and database configuration.
3. CI workflows, if present.
4. Package manifests and lockfiles.
5. Tests.
6. Current README and docs.
7. Older comments/contracts/historical notes.
8. Inference.

Do not “average” conflicting sources. Follow the higher-priority source and record the discrepancy, especially for security or deployment behavior.

## Required reasoning discipline

Use explicit labels in plans and reports:

- `verified`: demonstrated by a cited repository path or command result.
- `assumption`: needed to proceed but not verified.
- `inference`: reasoned from verified facts.
- `unknown`: unavailable from repository evidence.
- `conflicting`: sources disagree.
- `needs_human_review`: maintainer decision required.

Never invent a command, service, schema, route, environment variable, platform requirement, or ownership boundary. If it is not in source/config/docs/tests, mark it unknown or inferred.

## Repository-specific invariants

### Runtime and language boundary

- Production runtime duties belong to Swift, embedded DuckDB, nginx, and systemd.
- Shell commands and small Python tools are acceptable for build/test/operator workflows only; do not introduce a new always-on script-based service without an explicit architectural decision.
- The Swift packages use paths containing spaces. Quote every package path in commands.

### Release integrity

- Release directories are immutable. Never “fix” an existing release in place unless the operator explicitly requests forensic repair.
- A release must retain manifests, metadata, checksums, public client files, and DB records that agree.
- Only the Minecraft version marked live in DuckDB may publish the global current-release aliases.
- Do not bypass checksum, current-release, DMG, or headless-live-soak validation.
- Never fabricate a soak report or release-health record.

### Client file safety

- Preserve manifest path validation, SHA256/size verification, temporary-download verification, and atomic replacement.
- Preserve the distinction between first install and repeat sync. First install may quarantine unmanaged files and apply full defaults; repeat sync must avoid resetting unrelated player preferences.
- Do not add a new managed manifest section without updating the parser, destination mapping, release generation, tests, and contracts together.
- Do not allow sync while Minecraft is running unless the explicit override remains part of the intended behavior.

### Database changes

- Numbered files under `Server App/Database/duckdb/migrations/` are canonical.
- Add the next migration; do not rewrite an already deployed migration without explicit confirmation.
- Runtime table guards do not replace migrations.
- Update affected views, code queries, tests, and docs in the same change.
- Test migrations on a disposable DuckDB file. Never point development commands at the production DB by default.

### Mod update behavior

- Preserve provider throttling and discovery-rate limits.
- A scraped or discovered candidate is not automatically trusted; normal compatibility, smoke, release, and activation gates still apply.
- Preserve live/staging separation and protected statuses such as `Priority Mod` and `Admin Locked`.
- Prefer dry-run for mod add, scan, apply, and version bootstrap when investigating.

### Website and API data

- Operational website sections must use Swift API/DuckDB data.
- Do not add stale committed JSON fallbacks for release history, live stats, mod inventory, failed mods, release health, update activity, or server versions.
- Keep large downloads on nginx static paths, not the control API.
- If changing an API payload, inspect all website and client consumers before editing.

### Control channel

- Control-event payloads must not carry download URLs or downloadable file references.
- Event types that trigger sync are encoded in `ClientControlWatcher.requiresImmediateSync`.
- Current authentication behavior is conflicting across code and docs. Read `.ai/SECURITY.md` and `.ai/KNOWN_UNKNOWNS.md`; do not silently reintroduce or remove security checks.

### Deployment boundary

- The tracked server service is root-owned because it supervises Minecraft and installs local firewall rules.
- Preserve `NoNewPrivileges`, `PrivateTmp`, `ProtectHome`, `ProtectSystem`, `RestrictSUIDSGID`, and limited `ReadWritePaths` unless a maintainer approves a security redesign.
- Preserve the local Swift API bind/proxy boundary unless intentionally changing deployment.
- Understand `KillMode=process` before altering service stop/restart semantics; the daily scan relies on the intended process boundary.

### Destructive operations

- World reset, production migrations, release activation, RCON commands, service deployment, and live-version promotion require explicit operator intent.
- For world reset, use dry-run first and preserve explicit destructive confirmation.
- Never run production deployment/migration/reset commands merely to “validate” documentation.

## Planning changes

A good plan for this repository names:

1. The owning package/component.
2. The public interfaces affected (CLI/API/manifest/DB/web/service).
3. The invariants that must remain true.
4. The source and tests to update.
5. The safe validation sequence.
6. Any production-only validation that must remain manual.

Example:

```text
Verified:
- The endpoint is routed in MCPummelchenModServerCore.swift.
- The website consumer is in Server App/nginx/site/public/index.html.

Conflict/unknown:
- Live nginx deployment cannot be inspected from Git.

Plan:
1. Update the shared response model.
2. Update the server route payload.
3. Update website parsing/rendering.
4. Add focused server tests.
5. Run server build/test; do not deploy nginx.
```

## File ownership and navigation

- Server CLI changes: `Server App/MCPummelchenModServer/Sources/MCPummelchenModServer/main.swift`.
- Server API/data changes: `.../MCPummelchenModServerCore/MCPummelchenModServerCore.swift` plus stores/providers.
- Shared API/release/manifest contracts: `Server App/MCPummelchenModShared/Sources/MCPummelchenModShared/`.
- Client sync/status/control changes: `Client App/MCPummelchenModClient/Sources/MCPummelchenModClientCore/`.
- Client UI changes: client app `main.swift`.
- DB changes: `Server App/Database/duckdb/migrations/`, `schema.sql`, query sites.
- Website changes: `Server App/nginx/site/public/`.
- Edge/process changes: `Server App/nginx/`, `Server App/systemd/`.
- Production behavior contract changes: `Server App/Docs/contracts/`.

Use `.ai/PROJECT_MAP.md` for a module-by-module map.

## Coding conventions visible in current source

- Prefer small value types (`struct`, `enum`) with explicit `Sendable` conformance.
- Use typed errors conforming to `CustomStringConvertible` for operator-facing failures.
- Keep filesystem paths as `URL` values and standardize/validate them.
- Validate external contracts centrally (`CurrentReleaseValidator`, `ClientSyncManifestParser`, `ContractValidation`, `SafePath`).
- Keep JSON encoding deterministic where release/public artifacts are produced.
- Preserve idempotency in defaults, client reports, control acknowledgements, and migrations.
- Use explicit environment-variable parsing and defaults.
- Keep operator output machine-readable where existing commands print `key=value` status lines.
- Tests use Swift Testing, fixtures, temporary directories, and disposable DuckDB files.

## Validation matrix

| Change type | Required minimum |
|---|---|
| Shared contract/utility | shared build and tests; server/client builds if public API changed |
| Server API | server build and focused API tests; inspect web/client consumers |
| Server pipeline | server build and focused pipeline tests; dry-run where available |
| Client core | client build and focused client tests |
| Client UI | client build and status/UI-adjacent tests |
| DuckDB migration | disposable migrate + health + affected tests |
| Release/manifest | server tests plus shared contract tests; no fake artifacts |
| nginx/site | review aliases/cache headers and API consumers; host-level config test is operator work |
| systemd | review service security and process semantics; deployment owner review |
| AI docs only | JSON validation, link/path validation, generated-file scan, secret-pattern scan |

Commands are in `.ai/COMMANDS.md`.

## Secrets and sensitive data

Never commit, print, echo, or include in generated docs:

- access tokens or bearer values
- private client bootstrap resources
- RCON passwords
- server environment-file contents
- private keys/certificates
- live database records containing user/client data
- production credentials embedded in DMGs

Use symbolic names such as `PUMMELCHEN_CLIENT_API_TOKEN` and placeholders such as `<secret>`; never use real values in examples.

## Generated and high-churn artifacts

Do not edit or review generated binary/release trees as if they were source. Avoid:

- runtime `/downloads/`
- release directories and current-release aliases
- DMG/MRPACK/ZIP/JAR/checksum/soak artifacts
- `.build/`
- Parquet exports
- client quarantine/temp directories
- production runtime files and database snapshots

If a task concerns one of these, first identify the source generator and contract.

## Tests and reporting

When finishing a task, report:

- files changed
- behavior changed
- validation commands actually run
- validation skipped and why
- generated artifacts not produced
- remaining risks/unknowns
- whether onboarding docs need refresh

Do not say a test passed unless it actually ran. Do not imply host-level nginx/systemd/DMG/live-server validation from static source review.

## Commit and PR expectations

- Never push directly to `main`.
- Prefer one coherent change per commit.
- Describe migration, deployment, security, and compatibility implications.
- Include exact validation performed.
- Do not commit local build output or private runtime data.
- Update these onboarding files when changing architecture, commands, schema, routes, deployment, security, tests, or major workflows.

## Onboarding refresh policy

Refresh `AI_INDEX.md`, `AGENTS.md`, and `.ai/` after relevant merges involving:

- package manifests or module layout
- server/client entrypoints
- API routes or shared contracts
- release/mod/version/client-sync workflows
- DuckDB migrations or reporting views
- nginx/systemd/deployment
- security/identity/control behavior
- test structure or commands

Trust current source over stale generated content, preserve valid human additions, and record the refresh in `.ai/CHANGELOG.md` and `.ai/MANIFEST.json`.

## Evidence

- `AI_INDEX.md`
- `.ai/ARCHITECTURE.md`
- `.ai/SECURITY.md`
- `Server App/Docs/contracts/PRODUCTION_CONTRACTS.md`
- `Server App/MCPummelchenModServer/Sources/MCPummelchenModServer/main.swift`
- `Client App/MCPummelchenModClient/Sources/MCPummelchenModClientCore/ClientSyncEngine.swift`
- `Server App/Database/duckdb/README.md`
- `Server App/nginx/README.md`
- `Server App/systemd/README.md`
