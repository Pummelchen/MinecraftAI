# Pummelchen DuckDB

This directory contains the canonical DuckDB schema for the Pummelchen Swift server.

DuckDB is the production database and the only supported project database.

## Files

- `schema.sql`: canonical schema entrypoint for operators.
- `migrations/001_foundation.sql`: creates `raw`, `core`, `audit`, `reporting`, and `archive` schemas plus reporting views.

## Health Check

On a host with Swift 6.3.2 and DuckDB installed:

```sh
swift run --package-path swift/PummelchenSwift pummelchen-duckdb health \
  --duckdb /opt/pummelchen-swift/runtime/data/pummelchen.duckdb
```

Export reporting views to Parquet:

```sh
swift run --package-path swift/PummelchenSwift pummelchen-duckdb export-parquet \
  --duckdb /opt/pummelchen-swift/runtime/data/pummelchen.duckdb \
  --output-dir /tmp/pummelchen_parquet
```

Verify the exported Parquet files can be read back by DuckDB:

```sh
swift run --package-path swift/PummelchenSwift pummelchen-duckdb verify-parquet \
  --duckdb /opt/pummelchen-swift/runtime/data/pummelchen.duckdb \
  --input-dir /tmp/pummelchen_parquet
```

## Current Boundary

The Swift server app and database tools read and write DuckDB directly. The helper executable invokes the DuckDB CLI through `PATH` for administrative checks and Parquet exports.
