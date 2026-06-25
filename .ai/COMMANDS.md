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
# Commands

Run from the repository root and quote package paths because parent directories contain spaces.

## Build / typecheck

```sh
swift build --package-path 'Server App/MCPummelchenModShared'
swift build --package-path 'Server App/MCPummelchenModServer'
swift build --package-path 'Client App/MCPummelchenModClient'
```

## Local run

```sh
swift run --package-path 'Server App/MCPummelchenModServer' MCPummelchenModServer serve --project-root '$PWD' --host 127.0.0.1 --port 8787
swift run --package-path 'Server App/MCPummelchenModServer' MCPummelchenModServer smoke --project-root '$PWD'
swift run --package-path 'Client App/MCPummelchenModClient' MCPummelchenModClient --once
swift run --package-path 'Client App/MCPummelchenModClient' pummelchen-client-sync sync --force --server-url <server-url>
swift run --package-path 'Client App/MCPummelchenModClient' pummelchen-client-sync watch --server-url <server-url> --max-cycles <n>
```

## Tests

```sh
swift test --package-path 'Server App/MCPummelchenModServer'
swift test --package-path 'Client App/MCPummelchenModClient'
swift test --package-path 'Server App/MCPummelchenModShared'
```

## DuckDB

```sh
swift run --package-path 'Server App/MCPummelchenModServer' pummelchen-duckdb migrate --duckdb <duckdb-file> --migrations-dir 'Server App/Database/duckdb/migrations'
swift run --package-path 'Server App/MCPummelchenModServer' pummelchen-duckdb health --duckdb <duckdb-file>
```

## Release/mod operator examples

Use dry-run unless a human explicitly asks for live mutation.

```sh
swift run --package-path 'Server App/MCPummelchenModServer' MCPummelchenModServer mod-update-scan --project-root <repo> --duckdb <duckdb-file> --all-supported true --dry-run true
swift run --package-path 'Server App/MCPummelchenModServer' MCPummelchenModServer server-version-bootstrap --project-root <repo> --duckdb <duckdb-file> --minecraft-version <target> --dry-run true
```

No dedicated lint, format, Docker, compose, or CI workflow command was found in inspected files.
