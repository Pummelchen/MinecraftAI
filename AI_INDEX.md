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
# AI Index: MinecraftAI

## Snapshot

Repository: `Pummelchen/MinecraftAI`.
Indexed commit: `743356f85b0d4343cb8b1f71a92731eaf479bf47`.
Mode: `bootstrap`.
Primary stack: SwiftPM, Swift, C DuckDB shim, SQL, HTML, nginx, systemd, DuckDB, Swift Testing.
Purpose: AI-assisted Minecraft server/client mod management, release publishing, macOS client sync, live update control, and DuckDB-backed reporting.

## Architecture summary

Verified from source/config: the repo has a Swift server package, Swift client package, shared Swift/DuckDB package, DuckDB schema/migrations, nginx public edge, and systemd runtime units. The server owns CLI/API workflows for serving status, creating/validating releases, adding/scanning/applying mods, bootstrapping Minecraft versions, building client DMGs, world reset, and RCON. The client owns the macOS status app and sync/watch helper.

## Directory map

- `Client App/MCPummelchenModClient/`: client SwiftPM package, GUI, sync core, sync/watch CLI, tests.
- `Server App/MCPummelchenModServer/`: server SwiftPM package, API/CLI, pipelines, DuckDB helper, headless soak, tests.
- `Server App/MCPummelchenModShared/`: shared models/utilities and `CDuckDB`.
- `Server App/Database/duckdb/`: canonical schema and numbered migrations.
- `Server App/Docs/contracts/`: production contracts and client identity docs.
- `Server App/nginx/`: public edge config and site source.
- `Server App/systemd/`: Debian services/timers.
- `Live Backup/`: production DB backup/checksum area referenced by README.

## Main entrypoints

- `Server App/MCPummelchenModServer/Sources/MCPummelchenModServer/main.swift`
- `Server App/MCPummelchenModServer/Sources/MCPummelchenModServerCore/MCPummelchenModServerCore.swift`
- `Client App/MCPummelchenModClient/Sources/MCPummelchenModClient/main.swift`
- `Client App/MCPummelchenModClient/Sources/MCPummelchenModClientSync/main.swift`
- `Server App/MCPummelchenModServer/Sources/PummelchenDuckDB/main.swift`

## Key commands

- `swift build --package-path 'Server App/MCPummelchenModServer'`
- `swift build --package-path 'Client App/MCPummelchenModClient'`
- `swift test --package-path 'Server App/MCPummelchenModServer'`
- `swift test --package-path 'Client App/MCPummelchenModClient'`
- `swift run --package-path 'Server App/MCPummelchenModServer' MCPummelchenModServer serve --project-root '$PWD' --host 127.0.0.1 --port 8787`

No dedicated CI, Docker, lint, or formatter command was found.

## Important cautions

Do not edit generated release/download artifacts, production DB snapshots, nginx/systemd hardening, client identity/reporting behavior, RCON/world reset paths, or DuckDB schema without targeted source inspection and human context.

## Recommended read order

1. `AI_INDEX.md`
2. `AGENTS.md`
3. `.ai/START_HERE.md`
4. `.ai/PROJECT_MAP.md`
5. `.ai/ARCHITECTURE.md`
6. `.ai/COMMANDS.md`
7. `.ai/TESTING.md`
8. `.ai/SECURITY.md`
9. `.ai/KNOWN_UNKNOWNS.md`

## Evidence

`README.md`; all three `Package.swift` files; server/client/shared entrypoints listed above; `Server App/Database/duckdb/README.md`; `Server App/Docs/contracts/PRODUCTION_CONTRACTS.md`; `Server App/Docs/contracts/CLIENT_IDENTITY.md`; `Server App/nginx/README.md`; `Server App/systemd/README.md`.
