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
# Components

## Server CLI/API package

Responsibility: operator commands, local HTTP API, release/mod/world workflows, client reports/control events, site JSON data. Key files: server package manifest, server `main.swift`, server core. Risks: production writes, release activation, RCON/world reset, public API compatibility.

## Client app and sync package

Responsibility: macOS status UI, file sync, defaults repair, control watcher, status reporting, DMG self-update. Key files: client package manifest, client `main.swift`, `ClientSyncEngine.swift`, sync CLI `main.swift`. Risks: player data preservation, checksum correctness, self-update staging, optional reporting behavior.

## Shared package

Responsibility: shared models, manifest/release validation, safe paths, file inventory, and DuckDB wrapper. Key files: shared package manifest, `Sources/MCPummelchenModShared/`, and `Sources/CDuckDB/`. Risks: server/client contract compatibility and DuckDB linker path issues.

## DuckDB schema/helper

Responsibility: canonical schema, migrations, health checks, reporting exports. Key files: `Server App/Database/duckdb/` and `PummelchenDuckDB/main.swift`. Risks: migration order, production data loss, stale reporting views.

## Deployment edge

Responsibility: public website/API/download edge and process management. Key files: `Server App/nginx/` and `Server App/systemd/`. Risks: cache mistakes, proxy limits, service hardening, generated artifact preservation.
