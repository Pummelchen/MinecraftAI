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
# Testing

Inspected tests use Swift Testing with `@Suite`, `@Test`, and `#expect`.

## Test locations

- `Server App/MCPummelchenModServer/Tests/MCPummelchenModServerTests/`: server API, site data, scanner, environment config, DuckDB-backed behavior.
- `Client App/MCPummelchenModClient/Tests/MCPummelchenModClientTests/`: client sync/status tests found by search.
- `Server App/MCPummelchenModShared/Tests/MCPummelchenModSharedTests/`: shared utilities and fixtures.

## Commands

```sh
swift test --package-path 'Server App/MCPummelchenModServer'
swift test --package-path 'Client App/MCPummelchenModClient'
swift test --package-path 'Server App/MCPummelchenModShared'
```

Focused-test examples:

```sh
swift test --package-path 'Server App/MCPummelchenModServer' --filter MCPummelchenModServerCoreTests
swift test --package-path 'Client App/MCPummelchenModClient' --filter ClientSyncEngineTests
```

## Environment-sensitive areas

DuckDB-backed tests require the DuckDB library. Release/DMG/headless-soak flows require runtime artifacts and operator context. Avoid live network dependence in ordinary tests; prefer fixtures, local servers, and dry-run behavior.
