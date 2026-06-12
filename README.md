# Pummelchen Swift

Pummelchen Swift is the replacement control plane for the private Pummelchen Minecraft server and macOS client. The repository now contains the Swift/DuckDB implementation only; the previous Python, shell, nginx-site-generator, DMG-script, cron, systemd, monitoring, datapack-build, and static-site project tree has been retired from git.

## Retired Legacy Backup

The retired legacy project was backed up on the VPS before removal:

```text
/var/minecraft_mods/retired/legacy_git_project_20260612T185935Z
```

That backup contains the full removed tree, including generated local artifacts that were not tracked by git at the time of retirement.

## Repository Layout

```text
.
├── database/duckdb/              # DuckDB schema and normalization SQL
├── docs/                         # Swift migration plan and API/data contracts
│   └── contracts/                # Client identity, production contracts, JSON schemas
├── swift/PummelchenSwift/        # SwiftPM package for server, client, sync, and shared core
├── .github/workflows/ci.yml      # Swift build/test quality gate
└── README.md
```

## Swift Package

The active code lives in:

```bash
swift/PummelchenSwift
```

Main products:

| Product | Purpose |
|---|---|
| `pummelchen-server` | Server-side control service foundation |
| `PummelchenClient` | macOS client GUI target, built on macOS only |
| `pummelchen-client-sync` | Client sync engine CLI/helper |
| `pummelchen-duckdb` | DuckDB migration and verification tool |
| `pummelchen-contracts` | Contract validation tool |
| `PummelchenCore` | Shared models, manifests, hashing, path safety, release identifiers |
| `PummelchenClientCore` | Client status, defaults inspection, sync engine, control channel |
| `PummelchenServerCore` | Server release/world reset/control event foundations |

## Build And Test

Run the Swift quality gate from the repository root:

```bash
swift test --package-path swift/PummelchenSwift
swift build --package-path swift/PummelchenSwift
```

On macOS, the GUI product is included automatically:

```bash
swift build --package-path swift/PummelchenSwift --product PummelchenClient
```

## Current Direction

The production target remains:

- one Swift server app/service on Debian with embedded DuckDB;
- one Swift macOS client app/helper with embedded DuckDB;
- HTTP/3 over QUIC for bidirectional server-client control traffic;
- nginx retained as the edge for public traffic, static downloads, TLS, caching, logs, and routing;
- no legacy Python, Bash updater, LaunchAgent script, or generated static-site helper code in this repository.

The detailed implementation plan is in [docs/SWIFT_DUCKDB_MIGRATION_PLAN.md](docs/SWIFT_DUCKDB_MIGRATION_PLAN.md).
