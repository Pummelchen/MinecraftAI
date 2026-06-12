# Swift And DuckDB Production Plan

## Current State

Pummelchen is a Swift/DuckDB production system.

- The Debian VPS runs the Swift server service.
- The Swift server service starts and supervises the live Minecraft NeoForge runtime.
- nginx serves the public website and proxies API requests to the Swift server.
- DuckDB is the only project database.
- The macOS client app syncs against the Swift server APIs.

Legacy script runners, compatibility import paths, and old database parity tooling are retired.

## Server Responsibilities

- Own the live API on `127.0.0.1:8787`.
- Publish live site data for nginx every 5 seconds.
- Start and supervise the Minecraft server process.
- Record releases, client health, control events, world resets, and audit data in DuckDB.
- Produce immutable release payloads for nginx downloads.
- Run health checks directly against DuckDB reporting views.
- Export and verify Parquet snapshots from DuckDB reporting views when needed.

## Client Responsibilities

- Install as a macOS Swift app from the DMG.
- Maintain local sync status and package inventory.
- Apply mod, shader, resource-pack, and configuration updates from server manifests.
- Report health, inventory, diagnostics, and defaults-repair state to the Swift server APIs.
- Present sync status, release history, and manual repair actions in the GUI.

## Database Policy

- DuckDB is authoritative.
- The Swift server and tools access DuckDB directly through the project database path.
- Release artifacts include DuckDB snapshots and checksums.
- Reporting pages and API feeds must be generated from DuckDB-backed state.
- No compatibility import layer is part of production.

## Operational Checks

Use the DuckDB helper for direct database checks:

```sh
swift run --package-path "Server App/PummelchenServer" pummelchen-duckdb health \
  --duckdb /opt/pummelchen-swift/runtime/data/pummelchen.duckdb
```

Export reporting views:

```sh
swift run --package-path "Server App/PummelchenServer" pummelchen-duckdb export-parquet \
  --duckdb /opt/pummelchen-swift/runtime/data/pummelchen.duckdb \
  --output-dir /opt/pummelchen-swift/runtime/data/parquet
```

Verify exported reporting views:

```sh
swift run --package-path "Server App/PummelchenServer" pummelchen-duckdb verify-parquet \
  --duckdb /opt/pummelchen-swift/runtime/data/pummelchen.duckdb \
  --input-dir /opt/pummelchen-swift/runtime/data/parquet
```

## Go-Live Rule

New server features must write to DuckDB, expose API/site data from Swift, and include a build or test check before deployment.
