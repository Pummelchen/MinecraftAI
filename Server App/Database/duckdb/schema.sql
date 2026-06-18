-- Pummelchen DuckDB canonical schema entrypoint.
-- Apply all files in database/duckdb/migrations in lexical order.

.read database/duckdb/migrations/001_foundation.sql
.read database/duckdb/migrations/002_operational_schemas_and_indexes.sql
.read database/duckdb/migrations/003_minecraft_versions.sql
.read database/duckdb/migrations/004_client_inventory_by_version.sql
