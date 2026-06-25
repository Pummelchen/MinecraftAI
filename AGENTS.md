<!--
AI onboarding file.
Mode: bootstrap
Indexed commit: 743356f85b0d4343cb8b1f71a92731eaf479bf47
Last generated: 2026-06-25T22:00:00+07:00
Generator: generic high-end AI coding agent
Purpose: Help future AI sessions understand this repository quickly.
Audience: Any high-capability AI coding agent, regardless of vendor or model family.
Human edits are allowed. Future refreshes should preserve valid human edits.
-->
# AGENTS.md

Generic instructions for high-capability AI coding agents working in this repository.

## Start every session

1. Read `AI_INDEX.md`.
2. Read `.ai/START_HERE.md` and task-relevant `.ai/` files.
3. Inspect current source/config files before editing.
4. Summarize verified facts, assumptions, inferences, and unknowns.
5. Plan the smallest safe change and validation commands.

Current source code, manifests, migrations, nginx/systemd configs, contracts, and tests outrank generated onboarding docs.

## Repository-specific rules

- Do not modify product/source code for documentation-only tasks.
- Do not edit generated release/download outputs unless explicitly asked.
- Do not write private runtime values, client identity material, or live environment values into commits, docs, logs, or public release metadata.
- Before changing client identity, control events, or client reporting, read `.ai/SECURITY.md`, `Server App/Docs/contracts/CLIENT_IDENTITY.md`, `ClientControlChannel.swift`, and `ClientSyncEngine.swift`.
- Before changing DuckDB schema/data access, read `Server App/Database/duckdb/README.md`, the latest migration, `PummelchenDuckDB/main.swift`, and affected query sites.
- Before changing deployment, read `Server App/nginx/README.md`, `Server App/systemd/README.md`, and `Server App/Docs/contracts/PRODUCTION_CONTRACTS.md`.

## Validation expectations

- Server API change: server build and server tests.
- Client sync/UI change: client build and client tests.
- DuckDB change: disposable migration, health check, relevant tests.
- Release/DMG change: read production contracts and do not invent proof artifacts.
- Docs-only onboarding change: validate manifest JSON, links, and generated-content scan.

## Visible conventions

SwiftPM package paths contain spaces, so quote paths. Inspected tests use Swift Testing. Runtime code uses Swift plus embedded DuckDB C API. Public operational website data should come from the Swift API backed by DuckDB, not committed static fallbacks.

Do not push directly to `main`. Report commands actually run and skipped.
