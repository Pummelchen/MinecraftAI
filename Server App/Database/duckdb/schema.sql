-- Pummelchen DuckDB canonical schema entrypoint.
-- Apply all files in database/duckdb/migrations in lexical order.

.read database/duckdb/migrations/001_foundation.sql
.read database/duckdb/migrations/002_operational_schemas_and_indexes.sql
.read database/duckdb/migrations/003_minecraft_versions.sql
.read database/duckdb/migrations/004_client_inventory_by_version.sql
.read database/duckdb/migrations/005_reporting_status_normalization.sql
.read database/duckdb/migrations/006_release_history_source_of_truth.sql
.read database/duckdb/migrations/007_mod_source_links.sql
.read database/duckdb/migrations/008_mod_source_discovery_results.sql
.read database/duckdb/migrations/009_priority_mod_status.sql
.read database/duckdb/migrations/010_server_version_installer_metadata.sql
