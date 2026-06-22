# Pummelchen DuckDB

This directory contains the canonical DuckDB schema for the Pummelchen Swift server.

DuckDB is the production database and the only supported project database.

## Files

- `schema.sql`: canonical schema entrypoint for operators.
- `migrations/001_foundation.sql`: creates `core`, `audit`, `reporting`, and `archive` schemas plus reporting views.
- `migrations/002_operational_schemas_and_indexes.sql`: creates the operational `client`, `control`, `release`, and `world` schemas and DuckDB ART indexes used by frequent status, release, control-event, and world-reset lookups.
- `migrations/003_minecraft_versions.sql`: adds supported Minecraft server versions plus version-aware mod source, scan, and client inventory columns/views.
- `migrations/004_client_inventory_by_version.sql`: creates the canonical version-keyed client inventory table used when clients report multiple supported Minecraft versions.
- `migrations/005_reporting_status_normalization.sql`: normalizes accepted mod states so reporting treats both `active` and `ok` as live accepted mods.
- `migrations/006_release_history_source_of_truth.sql`: makes `release.pack_releases` the DuckDB source of truth for release-history reporting and retires the old tested-updates feed table.
- `migrations/007_mod_source_links.sql`: stores multiple normalized provider links per mod source, such as primary, Modrinth, CurseForge, and official.
- `migrations/008_mod_source_discovery_results.sql`: records source-link discovery attempts and outcomes.
- `migrations/009_priority_mod_status.sql`: treats `Priority Mod` as an accepted active status for reporting and update-release accounting.
- `migrations/010_server_version_installer_metadata.sql`: adds per-version NeoForge installer name, URL, and SHA256 fields for server-driven macOS client setup.

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

## Versioned Mod Tracking

`core.minecraft_server_versions` is the source of truth for supported server versions, server addresses, live/staging state, and NeoForge installer requirements published to macOS clients. Clients fetch `/api/v1/minecraft/server-versions`, persist that list locally, and use the app-bundled versions only as a bootstrap fallback when the server cannot be reached.

`core.mod_sources`, `core.mod_source_links`, `core.mods`, `core.mod_files`, and `core.mod_server_files` are version-aware. `core.mod_sources` keeps the installed artifact/source row used by compatibility scans, while `core.mod_source_links` stores the normalized set of provider links for that source, including `primary`, `modrinth`, `curseforge`, and `official` link roles. The daily Swift update scan treats the live Minecraft version as the baseline and seeds missing staging-version candidates before crawling Modrinth and CurseForge. Seeded staging rows are marked as compatibility candidates, not deployed installs; scan results then record whether a real upstream file exists for that Minecraft/NeoForge version.

When enabled, source-link discovery fills missing redundant provider links through three ordered search paths: Modrinth/CurseForge APIs, direct provider-site HTML searches, and Google result pages filtered to accepted Modrinth/CurseForge result URLs only. Discovery is capped at 2 searches per second and records attempts in `core.mod_source_discovery_results`.

The scanner checks NeoForge loader compatibility for CurseForge and Modrinth mod projects. For non-mod project types such as shaders, resource packs, and data packs, it checks Minecraft-version compatibility without requiring a NeoForge loader marker, because those artifacts are not loaded the same way as server/client mod jars.

NeoForge itself is tracked from the official NeoForged download sources: the user-facing download page at `https://neoforged.net/` and Maven metadata at `https://maven.neoforged.net/releases/net/neoforged/neoforge/maven-metadata.xml`. The scanner resolves the latest build for each supported Minecraft line and records the direct official installer URL from Maven.
