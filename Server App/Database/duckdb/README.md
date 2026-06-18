# Pummelchen DuckDB

This directory contains the canonical DuckDB schema for the Pummelchen Swift server.

DuckDB is the production database and the only supported project database.

## Files

- `schema.sql`: canonical schema entrypoint for operators.
- `migrations/001_foundation.sql`: creates `core`, `audit`, `reporting`, and `archive` schemas plus reporting views.
- `migrations/002_operational_schemas_and_indexes.sql`: creates the operational `client`, `control`, `release`, and `world` schemas and DuckDB ART indexes used by frequent status, release, control-event, and world-reset lookups.
- `migrations/003_minecraft_versions.sql`: adds supported Minecraft server versions plus version-aware mod source, scan, and client inventory columns/views.
- `migrations/004_client_inventory_by_version.sql`: creates the canonical version-keyed client inventory table used when clients report multiple supported Minecraft versions.

## Apply Migrations

Apply pending migrations before starting or upgrading the Swift server app:

```sh
swift run --package-path "Server App/MCPummelchenModServer" pummelchen-duckdb migrate \
  --duckdb /opt/pummelchen-swift/runtime/data/pummelchen.duckdb \
  --migrations-dir "Server App/Database/duckdb/migrations"
```

The migration command records applied files in `core.schema_migrations`. Runtime Swift write paths still keep minimal `CREATE TABLE IF NOT EXISTS` guards, but migrations are the canonical schema source.

## Health Check

On a host with Swift 6.3.2 and DuckDB installed:

```sh
swift run --package-path "Server App/MCPummelchenModServer" pummelchen-duckdb health \
  --duckdb /opt/pummelchen-swift/runtime/data/pummelchen.duckdb
```

Export reporting views to Parquet:

```sh
swift run --package-path "Server App/MCPummelchenModServer" pummelchen-duckdb export-parquet \
  --duckdb /opt/pummelchen-swift/runtime/data/pummelchen.duckdb \
  --output-dir /tmp/pummelchen_parquet
```

Verify the exported Parquet files can be read back by DuckDB:

```sh
swift run --package-path "Server App/MCPummelchenModServer" pummelchen-duckdb verify-parquet \
  --duckdb /opt/pummelchen-swift/runtime/data/pummelchen.duckdb \
  --input-dir /tmp/pummelchen_parquet
```

## Runtime Access

The Swift server app, client app, and database helper tools read and write DuckDB through the embedded DuckDB C API wrapper in `MCPummelchenModShared`. Runtime code should not shell out to the DuckDB CLI for normal database reads, writes, migrations, health checks, client reports, release state, world reset records, or Parquet exports.
