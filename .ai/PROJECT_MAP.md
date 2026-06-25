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
# Project Map

Top-level areas:

- `Client App/MCPummelchenModClient/`: macOS client app, client core, sync/watch CLI, tests.
- `Server App/MCPummelchenModServer/`: server API/CLI, release/update pipelines, DuckDB helper, headless soak, tests.
- `Server App/MCPummelchenModShared/`: shared Swift models/utilities and DuckDB C shim.
- `Server App/Database/duckdb/`: schema and numbered migrations.
- `Server App/Docs/contracts/`: production contracts.
- `Server App/nginx/`: nginx edge config and website source.
- `Server App/systemd/`: Debian service and timer units.
- `Live Backup/`: production database backup/checksum area described by README.

Package products: client package exposes `MCPummelchenModClientCore`, `pummelchen-client-sync`, and the macOS app; server package exposes server core, server executable, DuckDB helper, headless soak runner, and contracts helper; shared package exposes `MCPummelchenModShared` and `CDuckDB`.

Entrypoints: server `main.swift`, server core API file, client app `main.swift`, client sync CLI `main.swift`, and `PummelchenDuckDB/main.swift`.
