# Pummelchen DuckDB Foundation

This directory contains the Phase 1 DuckDB foundation. It is read-only with respect to current production: SQLite and the existing Python scripts remain the production writers until the Swift/DuckDB stack passes parity and cutover gates.

## Files

- `schema.sql`: canonical schema entrypoint for operators.
- `migrations/001_foundation.sql`: creates `raw`, `core`, `audit`, `reporting`, and `archive` schemas plus the first reporting views.
- `normalize_from_raw.sql`: rebuilds typed `core` tables from SQLite imports in `raw`.

## Build A Temporary Parity Database

On a host with Swift 6.3.2 and DuckDB installed:

```sh
swift run --package-path swift/PummelchenSwift pummelchen-duckdb phase1-build \
  --duckdb /tmp/pummelchen_phase1.duckdb \
  --sqlite /var/minecraft_mods/data/minecraft_mods.sqlite \
  --project-root /var/minecraft_mods
```

Check health:

```sh
swift run --package-path swift/PummelchenSwift pummelchen-duckdb health \
  --duckdb /tmp/pummelchen_phase1.duckdb
```

Export reporting views to Parquet:

```sh
swift run --package-path swift/PummelchenSwift pummelchen-duckdb export-parquet \
  --duckdb /tmp/pummelchen_phase1.duckdb \
  --output-dir /tmp/pummelchen_phase1_parquet
```

## Current Boundary

The Swift runner invokes the DuckDB CLI through `PATH`. Embedded DuckDB linking is intentionally deferred until the parity database, reporting views, and migration contracts stabilize.
