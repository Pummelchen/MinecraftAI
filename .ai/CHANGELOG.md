<!--
AI onboarding file.
Mode: refresh
Indexed commit: dc4cf76f7f0a60ffba9c8681708432a75faed1f2
Last generated: 2026-07-18T22:16:29+07:00
Generator: generic high-end AI coding agent
Purpose: Help future AI sessions understand this repository quickly.
Audience: Any high-capability AI coding agent, regardless of vendor or model family.
Human edits are allowed. Future refreshes should preserve valid human edits.
-->
# AI Onboarding Changelog

## 2026-07-18T22:16:29+07:00 - Caddy public-edge migration

**Operation mode:** `caddy-edge-migration-and-refresh`
**Base commit inspected:** `dc4cf76f7f0a60ffba9c8681708432a75faed1f2`

### Change reason

Replaced the tracked nginx public edge with Caddy while preserving the existing public hostnames, version-scoped API routing, operational aliases, static downloads, cache behavior, and sensitive-file boundary. Swift-facing transport names and DMG validation controls are now vendor-neutral public-edge contracts.

### Source and operations changes

- Moved the tracked website to `Server App/caddy/site/public/`.
- Added `Caddyfile`, the reusable `PummelchenRoutes.caddy` production route contract, an official-service hardening drop-in, and deployment guidance.
- Added a real-Caddy integration suite and `Scripts/test-all.sh`.
- Renamed nginx-specific client/server symbols, environment variables, CLI options, logs, test names, and transport metadata to public-edge names.
- Made time-window server test fixtures relative to DuckDB `now()` so the 30-day API contract remains deterministic.
- Updated repository contracts, PM taxonomy, issue templates, and AI onboarding references for Caddy.

### Validation status

- Caddy v2.11.3 release archive verified against the publisher checksum.
- Caddy format, adaptation, and validation executed against the tracked production configuration.
- Caddy integration suite executed against the imported production route snippet.
- Shared, client, and server Swift test suites executed locally.
- No DMG, headless-soak, release activation, production database, world, or RCON operation was performed.

## 2026-07-09T05:25:00+02:00 — project-management control plane

**Operation mode:** `project-management-control-plane`  
**Base branch head inspected for PM setup:** `aa52bcab16cda5cfca5a8e146f4356842cc4bbcb`

### Change reason

Added repository-specific GitHub project-management rules so GitHub Issues, Milestones, Projects, labels, Codex-ready queues, human-review queues, and release-evidence work are discoverable from the AI onboarding entrypoints.

### Files added or updated

- Added `.ai/PROJECT_MANAGEMENT.md`.
- Updated `AI_INDEX.md` recommended read order and task map.
- Updated `.ai/START_HERE.md` task-specific reading order.
- Updated `.ai/MANIFEST.json` generated file list, recommended read order, source list, refresh reason, warnings, and relevant change paths.
- Added GitHub issue templates under `.github/ISSUE_TEMPLATE/`.

### Validation status

Performed through GitHub connector/API operations:

- PR created for the project-management control-plane files.
- Automated Codex review feedback was inspected.
- `.ai/PROJECT_MANAGEMENT.md` was registered in onboarding metadata/read order.

Not performed:

- Swift builds/tests;
- local JSON parsing in a checkout;
- GitHub label, milestone, or Project field/view creation through the connector;
- production deployment, migration, release, RCON, or live service validation.

## 2026-06-25T22:08:15+02:00 — full refresh and rewrite

**Operation mode:** `refresh`  
**Previous indexed commit:** `743356f85b0d4343cb8b1f71a92731eaf479bf47`  
**Current indexed commit:** `00e25e1a9584ca075e27b404305bda18157aa7f3`

### Refresh reason

The first generated onboarding set established the correct file structure but was too brief to onboard a new high-capability coding session. This refresh performs a full source-grounded rewrite and packages the complete files for upload/review.

### Source change analysis

The commit range from the previous index to current `main` contains the prior onboarding files and README onboarding block. No product-source architecture change was found in that range. The detailed content in this refresh therefore describes the same product source state at the current merge commit while replacing shallow generated documentation.

### Files fully rewritten

- `AI_INDEX.md`
- `AGENTS.md`
- `.ai/START_HERE.md`
- `.ai/PROJECT_MAP.md`
- `.ai/ARCHITECTURE.md`
- `.ai/COMPONENTS.md`
- `.ai/COMMANDS.md`
- `.ai/TESTING.md`
- `.ai/SECURITY.md`
- `.ai/PLAYBOOKS.md`
- `.ai/KNOWN_UNKNOWNS.md`
- `.ai/CHANGELOG.md`
- `.ai/MANIFEST.json`

### README

`README.md` retains the existing idempotent AI-agent onboarding block and the original project content. The ZIP includes the full README so the package can be overlaid on a checkout without reconstructing it.

### Detail added

- All three SwiftPM packages, products, targets, and dependency direction.
- Top-level and module-level project map.
- Server command catalogue and safety classification.
- Current API read/write route inventory.
- Shared release, manifest, API, path, and checksum contracts.
- Client GUI, sync, control, status, defaults, Java, NeoForge, and self-update flows.
- Mod add, scan, discovery, apply, and multi-version bootstrap workflows.
- Immutable release creation, activation, retention, and live-only global aliases.
- DMG build and 60-second headless live-soak gate.
- DuckDB schemas, migration sequence, helper commands, reporting and concurrency assumptions.
- nginx website/API/download boundary and systemd service/timer behavior.
- Minecraft supervisor, local RCON firewall, watchdog, and world-reset safety model.
- Test inventory, fixture conventions, native dependencies, focused commands, and validation matrix.
- Security trust boundaries, sensitive assets, supply-chain and filesystem controls.
- Project-specific playbooks for common code, database, release, deployment, and operational tasks.
- Generated/do-not-edit zones and context-management guidance.

### Stale or conflicting information recorded

- Current server/client code no longer requires a token for control polling/route dispatch, while older identity/README text requires authenticated control/write traffic.
- Client report upload still skips when no token exists, producing asymmetric behavior.
- `/api/v1/status` mode naming no longer reliably expresses write authorization.
- Package manifests use Swift tools 6.2 while a DB doc references a Swift 6.3.2 host.
- Live deployment, DB, provider, certificate, DNS, account, and release state remain unverifiable from source alone.

### Model-specific file migration

No model-specific files were found at checked standard paths. None were created, migrated, deprecated, preserved, or removed.

### Validation status for this refresh

Performed on generated files:

- required file-set check;
- metadata-header check;
- manifest JSON parsing;
- local-path/reference check;
- model-specific filename check;
- secret-pattern scan using redacted/pattern-based checks;
- ZIP content inventory and SHA256 generation.

Not performed:

- Swift builds/tests;
- native DuckDB tests;
- macOS DMG/codesign;
- nginx/systemd deployment validation;
- live provider scan;
- RCON/Minecraft/world operations;
- headless live soak.

## 2026-06-25T22:00:00+07:00 — initial bootstrap

The initial bootstrap added the vendor-neutral file set and README onboarding block at indexed commit `743356f85b0d4343cb8b1f71a92731eaf479bf47`, then merged it into current `main`. That version was structurally complete but intentionally superseded by the full refresh above.

## Evidence

- Git comparison between the previous and current indexed commits
- current repository source/configuration/test files listed in `.ai/MANIFEST.json`
- this generated ZIP's validation report/checksums
- `.ai/PROJECT_MANAGEMENT.md`
